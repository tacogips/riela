import Foundation
import RielaCore

public struct CodexAgentCompatibilityContext: Equatable, Sendable {
  public var codexHome: String?
  public var configDir: String?

  public init(codexHome: String? = nil, configDir: String? = nil) {
    self.codexHome = codexHome
    self.configDir = configDir
  }
}

public struct CodexCLIProcessOptions: Equatable, Sendable {
  public var model: String?
  public var sandbox: String?
  public var fullAuto: Bool
  public var streamGranularity: String?

  public init(model: String? = nil, sandbox: String? = nil, fullAuto: Bool = false, streamGranularity: String? = nil) {
    self.model = model
    self.sandbox = sandbox
    self.fullAuto = fullAuto
    self.streamGranularity = streamGranularity
  }
}

public enum CodexCLICompatibility {
  public enum CommandFamily: String, Equatable, Sendable {
    case session
    case group
    case queue
    case bookmark
    case token
    case files
    case model
    case version
    case graphql
  }

  public struct ParsedCommand: Equatable, Sendable {
    public var family: CommandFamily
    public var action: String?
    public var arguments: [String]
  }

  public static let supportedCommands: [CommandFamily: Set<String>] = [
    .session: ["list", "show", "watch", "run", "resume", "fork", "search", "searchTranscript"],
    .group: ["create", "list", "show", "add", "remove", "pause", "resume", "delete", "run"],
    .queue: ["create", "add", "show", "list", "pause", "resume", "delete", "update", "remove", "move", "mode", "run"],
    .bookmark: ["add", "list", "get", "delete", "search"],
    .token: ["create", "list", "revoke", "rotate"],
    .files: ["list", "patches", "find", "rebuild"],
    .model: ["check"],
    .version: [""],
    .graphql: [""],
  ]

  public static func parseCommand(_ arguments: [String]) throws -> ParsedCommand {
    guard let rawFamily = arguments.first, let family = CommandFamily(rawValue: rawFamily) else {
      throw CodexCLIError.unknownCommand(arguments.first ?? "")
    }
    if family == .version || family == .graphql {
      return ParsedCommand(family: family, action: nil, arguments: Array(arguments.dropFirst()))
    }
    guard arguments.count >= 2 else {
      throw CodexCLIError.missingAction(rawFamily)
    }
    let action = arguments[1]
    guard supportedCommands[family]?.contains(action) == true else {
      throw CodexCLIError.unsupportedAction(rawFamily, action)
    }
    return ParsedCommand(family: family, action: action, arguments: Array(arguments.dropFirst(2)))
  }

  public static func parseProcessOptions(_ arguments: [String]) -> CodexCLIProcessOptions {
    var options = CodexCLIProcessOptions()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--model", "-m":
        index += 1
        options.model = index < arguments.count ? arguments[index] : nil
      case "--sandbox":
        index += 1
        options.sandbox = index < arguments.count ? arguments[index] : nil
      case "--full-auto", "--dangerously-bypass-approvals-and-sandbox":
        options.fullAuto = true
      case "--stream-granularity":
        index += 1
        options.streamGranularity = index < arguments.count ? arguments[index] : nil
      default:
        break
      }
      index += 1
    }
    return options
  }

  public static func formatSessionsJSON(_ sessions: [CodexSession]) throws -> String {
    let values = sessions.map { session -> JSONObject in
      [
        "id": .string(session.id),
        "rolloutPath": .string(session.rolloutPath),
        "source": .string(session.source.rawValue),
        "cwd": .string(session.cwd),
        "title": .string(session.title),
      ]
    }
    let data = try JSONEncoder().encode(JSONValue.array(values.map(JSONValue.object)))
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  public static func usage() -> String {
    "session|group|queue|bookmark|token|files|model|version|graphql"
  }
}

public enum CodexCLIError: Error, Equatable {
  case unknownCommand(String)
  case missingAction(String)
  case unsupportedAction(String, String)
}

public final class CodexSessionWatchSubscription: @unchecked Sendable {
  private let lock = NSLock()
  private let watcher = CodexRolloutWatcher()
  private var queued: [CodexRolloutLine] = []
  private var cancelled = false

  public init(rolloutPath: String, startOffset: UInt64? = nil) {
    watcher.watchFile(path: rolloutPath, startOffset: startOffset)
  }

  public func next(timeout: TimeInterval? = nil) -> CodexRolloutLine? {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    while true {
      if let line = popQueued() {
        return line
      }
      guard !isCancelled else {
        return nil
      }
      appendFlushedLines()
      if let line = popQueued() {
        return line
      }
      if let deadline, Date() >= deadline {
        return nil
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  public func drainAvailable() -> [CodexRolloutLine] {
    appendFlushedLines()
    lock.lock()
    let lines = queued
    queued = []
    lock.unlock()
    return lines
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    queued = []
    lock.unlock()
    watcher.stop()
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  private func popQueued() -> CodexRolloutLine? {
    lock.lock()
    defer { lock.unlock() }
    guard !queued.isEmpty else {
      return nil
    }
    return queued.removeFirst()
  }

  private func appendFlushedLines() {
    let lines = watcher.flush().compactMap { event -> CodexRolloutLine? in
      if case let .line(_, line) = event {
        return line
      }
      return nil
    }
    guard !lines.isEmpty else {
      return
    }
    lock.lock()
    queued.append(contentsOf: lines)
    lock.unlock()
  }
}

public enum CodexCLICommandExecutor {
  public struct Result: Equatable, Sendable {
    public var data: JSONValue?
    public var errors: [String]

    public init(data: JSONValue? = nil, errors: [String] = []) {
      self.data = data
      self.errors = errors
    }
  }

  public static func execute(arguments: [String], context: CodexAgentCompatibilityContext = CodexAgentCompatibilityContext()) -> Result {
    do {
      let parsed = try CodexCLICompatibility.parseCommand(arguments)
      if parsed.family == .graphql {
        let graphQL = try parseGraphQLCLIArguments(parsed.arguments)
        let result = CodexGraphQLCommandExecutor.execute(command: graphQL.document, variables: graphQL.variables, context: context)
        return Result(data: result.data, errors: result.errors)
      }
      let commandName = parsed.family == .version ? "version.get" : "\(parsed.family.rawValue).\(parsed.action ?? "")"
      let variables = try variablesForCLI(parsed)
      let result = CodexGraphQLCommandExecutor.execute(command: commandName, variables: variables, context: context)
      return Result(data: result.data, errors: result.errors)
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }

  private static func variablesForCLI(_ parsed: CodexCLICompatibility.ParsedCommand) throws -> JSONObject {
    let parameterArguments = parsed.arguments.filter(isKnownInlineParameter)
    var values = try CodexGraphQLCommandExecutor.parseParams(parameterArguments)
    let flags = CLIFlagArguments(arguments: parsed.arguments.filter { !isKnownInlineParameter($0) })
    let positional = flags.positionals
    applyCommonLegacyFlags(flags, to: &values)
    switch (parsed.family, parsed.action) {
    case (.queue, "create"), (.group, "create"):
      if values["name"] == nil, let first = positional.first {
        values["name"] = .string(first)
      }
      if parsed.family == .queue, values["projectPath"] == nil, let project = flags.value("--project") {
        values["projectPath"] = .string(project)
      }
      if parsed.family == .group, values["description"] == nil, let description = flags.value("--description") {
        values["description"] = .string(description)
      }
    case (.queue, "add"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["prompt"] == nil, positional.count > 1 { values["prompt"] = .string(positional[1]) }
    case (.queue, "move"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["from"] == nil, let from = flags.value("--from").flatMap(Int.init) { values["from"] = .number(Double(from)) }
      if values["to"] == nil, let to = flags.value("--to").flatMap(Int.init) { values["to"] = .number(Double(to)) }
      if values["from"] == nil, positional.count > 1 { values["from"] = .number(Double(Int(positional[1]) ?? 0)) }
      if values["to"] == nil, positional.count > 2 { values["to"] = .number(Double(Int(positional[2]) ?? 0)) }
    case (.queue, "update"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["commandId"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["status"] == nil, let status = flags.value("--status") { values["status"] = .string(status) }
    case (.queue, "remove"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["commandId"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
    case (.queue, "mode"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["commandId"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
      if values["mode"] == nil, let mode = flags.value("--mode") { values["mode"] = .string(mode) }
      if values["mode"] == nil, positional.count > 2 { values["mode"] = .string(positional[2]) }
    case (.token, "create"):
      if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
      if values["permissions"] == nil, let permissions = flags.value("--permissions") { values["permissions"] = .string(permissions) }
      if values["expiresAt"] == nil, let expiresAt = flags.value("--expires-at") { values["expiresAt"] = .string(expiresAt) }
    case (.group, "add"), (.group, "remove"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
    case (.group, "run"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["maxConcurrent"] == nil, let maxConcurrent = flags.value("--max-concurrent").flatMap(Int.init) {
        values["maxConcurrent"] = .number(Double(maxConcurrent))
      }
    case (.queue, _), (.group, _), (.bookmark, "get"), (.bookmark, "delete"), (.token, "revoke"), (.token, "rotate"):
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    case (.bookmark, "add"):
      if values["type"] == nil, let type = flags.value("--type") { values["type"] = .string(type) }
      if values["type"] == nil, positional.count > 0 { values["type"] = .string(positional[0]) }
      if values["sessionId"] == nil, let session = flags.value("--session") ?? flags.value("--session-id") { values["sessionId"] = .string(session) }
      if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
      if values["messageId"] == nil, let message = flags.value("--message") ?? flags.value("--message-id") { values["messageId"] = .string(message) }
      if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
      if values["description"] == nil, let description = flags.value("--description") { values["description"] = .string(description) }
      if values["tags"] == nil {
        let tags = flags.values("--tag")
        if !tags.isEmpty {
          values["tags"] = .array(tags.map(JSONValue.string))
        }
      }
      if values["fromMessageId"] == nil, let fromMessageId = flags.value("--from") ?? flags.value("--from-message") ?? flags.value("--from-message-id") {
        values["fromMessageId"] = .string(fromMessageId)
      }
      if values["toMessageId"] == nil, let toMessageId = flags.value("--to") ?? flags.value("--to-message") ?? flags.value("--to-message-id") {
        values["toMessageId"] = .string(toMessageId)
      }
    case (.bookmark, "list"):
      if values["sessionId"] == nil, let session = flags.value("--session") ?? flags.value("--session-id") {
        values["sessionId"] = .string(session)
      }
      if values["type"] == nil, let type = flags.value("--type") {
        values["type"] = .string(type)
      }
      if values["tag"] == nil, let tag = flags.value("--tag") {
        values["tag"] = .string(tag)
      }
    case (.session, "searchTranscript"):
      if values["id"] == nil, positional.count > 1 {
        values["id"] = .string(positional[0])
      }
      if values["query"] == nil {
        values["query"] = .string(positional.count > 1 ? positional[1] : (positional.first ?? ""))
      }
    case (.bookmark, "search"), (.session, "search"):
      if values["query"] == nil, let first = positional.first {
        values["query"] = .string(first)
      }
    case (.model, "check"):
      if values["model"] == nil, let first = positional.first {
        values["model"] = .string(first)
      }
    case (.session, "show"), (.session, "watch"):
      if values["id"] == nil, parsed.family == .session, let first = positional.first {
        values["id"] = .string(first)
      }
    case (.session, "resume"):
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") {
        values["prompt"] = .string(prompt)
      }
      if values["prompt"] == nil, positional.count > 1 {
        values["prompt"] = .string(positional.dropFirst().joined(separator: " "))
      }
    case (.session, "fork"):
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
      if values["nthMessage"] == nil, let nthMessage = flags.value("--nth-message").flatMap(Int.init) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
      if values["nthMessage"] == nil, positional.count > 1, let nthMessage = Int(positional[1]) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
    case (.files, "list"), (.files, "patches"):
      if values["sessionId"] == nil, let first = positional.first {
        values["sessionId"] = .string(first)
      }
    case (.files, "find"):
      if values["path"] == nil, let first = positional.first {
        values["path"] = .string(first)
      }
    case (.session, "run"):
      if values["prompt"] == nil, let prompt = flags.value("--prompt") {
        values["prompt"] = .string(prompt)
      }
      if values["prompt"] == nil {
        values["prompt"] = .string(positional.joined(separator: " "))
      }
    default:
      break
    }
    return values
  }

  private static let knownInlineParameterNames: Set<String> = [
    "additionalArgs",
    "additionalArguments",
    "approvalMode",
    "branch",
    "caseSensitive",
    "codexBinary",
    "codexHome",
    "commandId",
    "configDir",
    "cwd",
    "description",
    "environment",
    "environmentVariables",
    "executableName",
    "expiresAt",
    "from",
    "fromMessageId",
    "fullAuto",
    "gitBinary",
    "id",
    "imagePaths",
    "images",
    "includeGit",
    "limit",
    "maxBytes",
    "maxConcurrent",
    "maxEvents",
    "maxSessions",
    "messageId",
    "mode",
    "model",
    "name",
    "nthMessage",
    "offset",
    "path",
    "permissions",
    "projectPath",
    "prompt",
    "promptId",
    "query",
    "resultExitCode",
    "role",
    "sandbox",
    "sessionId",
    "source",
    "startOffset",
    "status",
    "streamGranularity",
    "systemPrompt",
    "tag",
    "tags",
    "timeoutMs",
    "to",
    "toIndex",
    "toMessageId",
    "type",
  ]

  private static func isKnownInlineParameter(_ argument: String) -> Bool {
    guard let equals = argument.firstIndex(of: "="), equals > argument.startIndex else {
      return false
    }
    return knownInlineParameterNames.contains(String(argument[..<equals]))
  }

  private static func applyCommonLegacyFlags(_ flags: CLIFlagArguments, to values: inout JSONObject) {
    let stringFlags: [(String, String)] = [
      ("--model", "model"),
      ("--sandbox", "sandbox"),
      ("--approval-mode", "approvalMode"),
      ("--stream-granularity", "streamGranularity"),
      ("--source", "source"),
      ("--cwd", "cwd"),
      ("--branch", "branch"),
      ("--role", "role"),
      ("--codex-binary", "codexBinary"),
      ("--executable-name", "executableName"),
    ]
    for (flag, key) in stringFlags where values[key] == nil {
      if let value = flags.value(flag) {
        values[key] = .string(value)
      }
    }
    let intFlags: [(String, String)] = [
      ("--limit", "limit"),
      ("--offset", "offset"),
      ("--max-bytes", "maxBytes"),
      ("--max-events", "maxEvents"),
      ("--timeout-ms", "timeoutMs"),
    ]
    for (flag, key) in intFlags where values[key] == nil {
      if let value = flags.value(flag).flatMap(Int.init) {
        values[key] = .number(Double(value))
      }
    }
    if values["fullAuto"] == nil, flags.has("--full-auto") || flags.has("--dangerously-bypass-approvals-and-sandbox") {
      values["fullAuto"] = .bool(true)
    }
    if values["caseSensitive"] == nil, flags.has("--case-sensitive") {
      values["caseSensitive"] = .bool(true)
    }
    if values["images"] == nil {
      let images = flags.values("--image")
      if !images.isEmpty {
        values["images"] = .array(images.map(JSONValue.string))
      }
    }
  }

  private struct GraphQLCLIArguments {
    var document: String
    var variables: JSONObject
  }

  private struct CLIFlagArguments {
    private static let valueFlags: Set<String> = [
      "--prompt",
      "--project",
      "--image",
      "--model",
      "--sandbox",
      "--approval-mode",
      "--stream-granularity",
      "--source",
      "--cwd",
      "--branch",
      "--limit",
      "--offset",
      "--role",
      "--max-bytes",
      "--max-events",
      "--timeout-ms",
      "--codex-binary",
      "--executable-name",
      "--from",
      "--to",
      "--mode",
      "--status",
      "--name",
      "--permissions",
      "--expires-at",
      "--max-concurrent",
      "--format",
      "--char-delay-ms",
      "--type",
      "--session",
      "--session-id",
      "--message",
      "--message-id",
      "--description",
      "--tag",
      "--from-message",
      "--from-message-id",
      "--to-message",
      "--to-message-id",
      "--nth-message",
    ]

    private var flagValues: [String: [String]] = [:]
    private var booleanFlags: Set<String> = []
    var positionals: [String] = []

    init(arguments: [String]) {
      var index = 0
      while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
          if Self.valueFlags.contains(argument), index + 1 < arguments.count {
            flagValues[argument, default: []].append(arguments[index + 1])
            index += 2
            continue
          }
          booleanFlags.insert(argument)
          index += 1
          continue
        }
        positionals.append(argument)
        index += 1
      }
    }

    func value(_ flag: String) -> String? {
      flagValues[flag]?.last
    }

    func values(_ flag: String) -> [String] {
      flagValues[flag] ?? []
    }

    func has(_ flag: String) -> Bool {
      booleanFlags.contains(flag) || flagValues[flag] != nil
    }
  }

  private static func parseGraphQLCLIArguments(_ arguments: [String]) throws -> GraphQLCLIArguments {
    guard let document = arguments.first, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CodexGraphQLError.missingDocument
    }
    var variables: JSONObject = [:]
    var inlineParams: [String] = []
    var index = 1
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--variables":
        index += 1
        guard index < arguments.count else {
          throw CodexGraphQLError.missingFlagValue(argument)
        }
        let loaded = try CodexGraphQLCommandExecutor.loadVariablesSource(arguments[index])
        for (key, value) in loaded {
          variables[key] = value
        }
      case "--param", "--arg":
        index += 1
        guard index < arguments.count else {
          throw CodexGraphQLError.missingFlagValue(argument)
        }
        variables["param"] = try CodexGraphQLCommandExecutor.loadJSONSource(arguments[index])
      default:
        if argument.contains("=") {
          inlineParams.append(argument)
        } else {
          throw CodexGraphQLError.invalidParam(argument)
        }
      }
      index += 1
    }
    if !inlineParams.isEmpty {
      for (key, value) in try CodexGraphQLCommandExecutor.parseParams(inlineParams) {
        if variables["param"] == nil {
          variables[key] = value
        } else if case var .object(paramObject)? = variables["param"] {
          paramObject[key] = value
          variables["param"] = .object(paramObject)
        }
      }
    }
    return GraphQLCLIArguments(document: CodexGraphQLCommandExecutor.normalizeDocument(document), variables: variables)
  }
}

public struct CodexAgentCLIApplicationResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public enum CodexAgentCLIApplication {
  public static func run(
    arguments: [String],
    context: CodexAgentCompatibilityContext = CodexAgentCompatibilityContext()
  ) -> CodexAgentCLIApplicationResult {
    let result = CodexCLICommandExecutor.execute(arguments: arguments, context: context)
    if !result.errors.isEmpty {
      return CodexAgentCLIApplicationResult(
        stderr: encodeCLIJSON(.object(["errors": .array(result.errors.map(JSONValue.string))])),
        exitCode: 1
      )
    }
    return CodexAgentCLIApplicationResult(stdout: encodeCLIJSON(result.data ?? .null), exitCode: 0)
  }

  private static func encodeCLIJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
      return "null\n"
    }
    return text + "\n"
  }
}

public enum CodexGraphQLCommandExecutor {
  public struct Result: Equatable, Sendable {
    public var data: JSONValue?
    public var errors: [String]

    public init(data: JSONValue? = nil, errors: [String] = []) {
      self.data = data
      self.errors = errors
    }
  }

  public static let supportedCommandNames: Set<String> = [
    "version.get",
    "session.list", "session.show", "session.search", "session.searchTranscript", "session.run", "session.resume", "session.fork", "session.watch",
    "group.create", "group.list", "group.show", "group.add", "group.remove", "group.pause", "group.resume", "group.delete", "group.run",
    "queue.create", "queue.add", "queue.show", "queue.list", "queue.pause", "queue.resume", "queue.delete", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run",
    "bookmark.add", "bookmark.list", "bookmark.get", "bookmark.delete", "bookmark.search",
    "token.create", "token.list", "token.revoke", "token.rotate",
    "files.list", "files.patches", "files.find", "files.rebuild",
    "model.check",
  ]

  public static func normalizeDocument(_ command: String) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("query") || trimmed.hasPrefix("mutation") || trimmed.hasPrefix("subscription") || trimmed.hasPrefix("{") || trimmed.hasPrefix("#") {
      return trimmed
    }
    if supportedCommandNames.contains(trimmed) {
      return "\(shorthandOperation(for: trimmed)) ($param: JSON) { command(name: \"\(escapeGraphQLString(trimmed))\", params: $param) }"
    }
    return trimmed
  }

  public static func parseVariables(_ text: String?) throws -> JSONObject {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return [:]
    }
    let data = Data(text.utf8)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case let .object(object) = decoded else {
      throw CodexGraphQLError.variablesMustBeObject
    }
    return object
  }

  public static func parseParams(_ values: [String]) throws -> JSONObject {
    var params: JSONObject = [:]
    for value in values {
      let pieces = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard pieces.count == 2 else {
        throw CodexGraphQLError.invalidParam(value)
      }
      params[pieces[0]] = try parseLooseJSONValue(pieces[1])
    }
    return params
  }

  public static func loadVariables(_ textOrPath: String?) throws -> JSONObject {
    guard let textOrPath else {
      return [:]
    }
    return try loadVariablesSource(textOrPath)
  }

  public static func loadVariablesSource(_ textOrPath: String) throws -> JSONObject {
    let value = try loadJSONSource(textOrPath)
    guard case let .object(object) = value else {
      throw CodexGraphQLError.variablesMustBeObject
    }
    return object
  }

  public static func loadJSONSource(_ textOrPath: String) throws -> JSONValue {
    let path = textOrPath.hasPrefix("@") ? String(textOrPath.dropFirst()) : textOrPath
    let source: String
    if FileManager.default.isReadableFile(atPath: path) {
      source = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      source = textOrPath
    }
    return try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
  }

  public static func watchSession(id: String, startOffset: UInt64? = nil, codexHome: String? = nil) throws -> CodexSessionWatchSubscription {
    guard let session = findSession(id: id, codexHome: codexHome) else {
      throw CodexGraphQLError.missingVariable("Session not found")
    }
    return CodexSessionWatchSubscription(rolloutPath: session.rolloutPath, startOffset: startOffset)
  }

  public static func execute(command: String, variables: JSONObject = [:], context: CodexAgentCompatibilityContext = CodexAgentCompatibilityContext()) -> Result {
    let normalized = normalizeDocument(command)
    if isPingDocument(normalized) {
      return Result(data: .object(["ping": .bool(true)]))
    }
    let legacyInvocation = extractLegacyCommandInvocation(from: normalized, variables: variables)
    let effectiveVariables = legacyInvocation.variables
    guard let commandName = legacyInvocation.commandName ?? extractCommandName(from: normalized) else {
      return Result(errors: ["Unable to extract command name"])
    }
    if normalized.hasPrefix("subscription"), commandName != "session.watch" {
      return Result(errors: ["Unsupported subscription command: \(commandName)"])
    }
    guard supportedCommandNames.contains(commandName) else {
      return Result(errors: ["Unknown command: \(commandName)"])
    }
    do {
      let configDir = stringValue(effectiveVariables["configDir"]) ?? context.configDir ?? defaultCodexAgentConfigDir()
      let codexHome = stringValue(effectiveVariables["codexHome"]) ?? context.codexHome
      switch commandName {
      case "version.get":
        return Result(data: .object(toolVersionsJSON(variables: effectiveVariables)))
      case "model.check":
        let model = try requiredString(effectiveVariables, "model")
        var options = try processOptions(from: effectiveVariables, codexHome: codexHome)
        options.model = model
        if options.additionalArguments.isEmpty {
          options.additionalArguments = ["--skip-git-repo-check", "--ephemeral"]
        }
        let manager = CodexProcessManager(executableName: executableName(from: effectiveVariables))
        let result = manager.spawnExec(prompt: stringValue(effectiveVariables["prompt"]) ?? "Reply with exactly OK.", options: options)
        return Result(data: .object([
          "model": .string(model),
          "ok": .bool(result.result.exitCode == 0),
          "exitCode": .number(Double(result.result.exitCode)),
          "stdout": .string(result.result.stdout),
          "stderr": .string(result.result.stderr),
        ]))
      case "session.list":
        let options = sessionListOptions(from: effectiveVariables, codexHome: codexHome)
        let result = CodexSessionIndex.listSessions(options: options)
        return Result(data: .object(["sessions": .array(result.sessions.map(sessionJSON)), "total": .number(Double(result.total)), "offset": .number(Double(result.offset)), "limit": .number(Double(result.limit))]))
      case "session.show":
        let id = try requiredString(effectiveVariables, "id")
        guard let session = CodexSessionCommands.show(sessionId: id, codexHome: codexHome) else {
          return Result(errors: ["Session not found"])
        }
        return Result(data: sessionJSON(session))
      case "session.search", "session.searchTranscript":
        let query = try requiredString(effectiveVariables, "query")
        if commandName == "session.searchTranscript", let id = stringValue(effectiveVariables["id"]) {
          guard let session = CodexSessionIndex.findSession(id: id, codexHome: codexHome) else {
            return Result(data: .object([
              "sessionId": .string(id),
              "matched": .bool(false),
              "matchCount": .number(0),
              "scannedBytes": .number(0),
              "scannedEvents": .number(0),
              "truncated": .bool(false),
              "timedOut": .bool(false),
              "durationMs": .number(0),
            ]))
          }
          let search = try CodexSessionIndex.searchSessionTranscriptDetailed(session: session, query: query, options: transcriptSearchOptions(from: effectiveVariables))
          return Result(data: .object([
            "matched": .bool(search.matched),
            "sessionId": .string(id),
            "matchCount": .number(Double(search.matchCount)),
            "scannedBytes": .number(Double(search.scannedBytes)),
            "scannedEvents": .number(Double(search.scannedEvents)),
            "truncated": .bool(search.truncated),
            "timedOut": .bool(search.timedOut),
            "durationMs": .number(search.durationMs),
          ]))
        }
        let result = try CodexSessionIndex.searchSessions(query: query, options: sessionListOptions(from: effectiveVariables, codexHome: codexHome), searchOptions: transcriptSearchOptions(from: effectiveVariables))
        return Result(data: .object([
          "sessionIds": .array(result.sessionIds.map(JSONValue.string)),
          "total": .number(Double(result.total)),
          "offset": .number(Double(result.offset)),
          "limit": .number(Double(result.limit)),
          "scannedSessions": .number(Double(result.scannedSessions)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut),
          "durationMs": .number(result.durationMs),
        ]))
      case "session.run":
        let prompt = try requiredNonBlankString(effectiveVariables, "prompt")
        let manager = CodexProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, codexHome: codexHome)
        let result = manager.spawnExec(prompt: prompt, options: options)
        return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
      case "session.resume":
        let id = try requiredString(effectiveVariables, "id")
        let manager = CodexProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, codexHome: codexHome)
        let process = manager.spawnResumeProcess(sessionId: id, prompt: stringValue(effectiveVariables["prompt"]), options: options)
        return Result(data: .object(processHandleJSON(process)))
      case "session.fork":
        let id = try requiredString(effectiveVariables, "id")
        let manager = CodexProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, codexHome: codexHome)
        let process = manager.spawnForkProcess(sessionId: id, nthMessage: intValue(effectiveVariables["nthMessage"]), options: options)
        return Result(data: .object(processHandleJSON(process)))
      case "session.watch":
        let id = try requiredString(effectiveVariables, "id")
        let subscription = try watchSession(id: id, startOffset: nonNegativeUInt64Value(effectiveVariables["startOffset"]) ?? 0, codexHome: codexHome)
        let lines = subscription.drainAvailable()
        subscription.cancel()
        return Result(data: .object(["events": .array(lines.map(rolloutLineJSON))]))

      case "group.create":
        return Result(data: try jsonValue(CodexGroupPersistence.createGroup(name: try requiredString(effectiveVariables, "name"), description: stringValue(effectiveVariables["description"]), configDir: configDir)))
      case "group.list":
        return Result(data: try jsonValue(CodexGroupPersistence.listGroups(configDir: configDir)))
      case "group.show":
        guard let group = try CodexGroupPersistence.findGroup(try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Group not found"])
        }
        return Result(data: try jsonValue(group))
      case "group.add":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: configDir)
        return Result(data: .object(["ok": .bool(try CodexGroupPersistence.addSession(groupId: groupId, sessionId: try requiredString(effectiveVariables, "sessionId"), configDir: configDir))]))
      case "group.remove":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: configDir)
        let ok = try CodexGroupPersistence.removeSession(groupId: groupId, sessionId: try requiredString(effectiveVariables, "sessionId"), configDir: configDir)
        return ok ? Result(data: .object(["ok": .bool(true)])) : Result(errors: ["Group session not found"])
      case "group.pause":
        return Result(data: .object(["ok": .bool(try CodexGroupPersistence.setPaused(groupId: resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: configDir), paused: true, configDir: configDir))]))
      case "group.resume":
        return Result(data: .object(["ok": .bool(try CodexGroupPersistence.setPaused(groupId: resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: configDir), paused: false, configDir: configDir))]))
      case "group.delete":
        return Result(data: .object(["ok": .bool(try CodexGroupPersistence.deleteGroup(id: resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: configDir), configDir: configDir))]))
      case "group.run":
        guard let group = try CodexGroupPersistence.findGroup(try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Group not found"])
        }
        return Result(data: try .array(runGroupEvents(group: group, prompt: try requiredString(effectiveVariables, "prompt"), variables: effectiveVariables, codexHome: codexHome).map(JSONValue.object)))

      case "queue.create":
        return Result(data: try jsonValue(CodexQueuePersistence.createQueue(name: try requiredString(effectiveVariables, "name"), projectPath: try requiredString(effectiveVariables, "projectPath"), configDir: configDir)))
      case "queue.add":
        let images = stringArray(effectiveVariables["images"]).isEmpty ? stringArray(effectiveVariables["imagePaths"]) : stringArray(effectiveVariables["images"])
        return Result(data: try jsonValue(CodexQueuePersistence.addPrompt(queueId: resolveExistingQueueId(try requiredString(effectiveVariables, "id"), configDir: configDir), prompt: try requiredString(effectiveVariables, "prompt"), imagePaths: images, configDir: configDir)))
      case "queue.show":
        guard let queue = try CodexQueuePersistence.findQueue(try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Queue not found"])
        }
        return Result(data: try jsonValue(queue))
      case "queue.list":
        return Result(data: try jsonValue(CodexQueuePersistence.listQueues(configDir: configDir)))
      case "queue.delete":
        let ok = try CodexQueuePersistence.removeQueue(resolveExistingQueueId(try requiredString(effectiveVariables, "id"), configDir: configDir), configDir: configDir)
        return ok ? Result(data: .object(["ok": .bool(true)])) : Result(errors: ["Queue not found"])
      case "queue.pause", "queue.resume", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run":
        return executeQueueMutation(commandName: commandName, variables: effectiveVariables, configDir: configDir, codexHome: codexHome)

      case "bookmark.add":
        guard let type = CodexBookmarkType(rawValue: try requiredString(effectiveVariables, "type")) else {
          return Result(errors: ["Invalid bookmark type"])
        }
        return Result(data: try jsonValue(CodexBookmarkPersistence.addBookmark(type: type, sessionId: try requiredString(effectiveVariables, "sessionId"), messageId: stringValue(effectiveVariables["messageId"]), name: stringValue(effectiveVariables["name"]), description: stringValue(effectiveVariables["description"]) ?? stringValue(effectiveVariables["text"]), tags: stringArray(effectiveVariables["tags"]), fromMessageId: stringValue(effectiveVariables["fromMessageId"]), toMessageId: stringValue(effectiveVariables["toMessageId"]), configDir: configDir)))
      case "bookmark.list":
        return Result(data: try jsonValue(CodexBookmarkPersistence.listBookmarks(sessionId: stringValue(effectiveVariables["sessionId"]), type: stringValue(effectiveVariables["type"]).flatMap(CodexBookmarkType.init(rawValue:)), tag: stringValue(effectiveVariables["tag"]), configDir: configDir)))
      case "bookmark.get":
        guard let bookmark = try CodexBookmarkPersistence.getBookmark(id: try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Bookmark not found"])
        }
        return Result(data: try jsonValue(bookmark))
      case "bookmark.delete":
        let ok = try CodexBookmarkPersistence.deleteBookmark(id: try requiredString(effectiveVariables, "id"), configDir: configDir)
        return ok ? Result(data: .object(["ok": .bool(true)])) : Result(errors: ["Bookmark not found"])
      case "bookmark.search":
        let limit = max(0, intValue(effectiveVariables["limit"]) ?? 50)
        let scored = try CodexBookmarkPersistence.searchBookmarkResults(try requiredString(effectiveVariables, "query"), limit: limit, configDir: configDir)
        return Result(data: .array(scored.map { result in
          .object([
            "bookmark": try! jsonValue(result.bookmark),
            "score": .number(result.score),
          ])
        }))

      case "token.create":
        let name = try requiredString(effectiveVariables, "name")
        let permissionValues = stringArray(effectiveVariables["permissions"])
        let permissions = permissionValues.isEmpty ? CodexTokenManager.parsePermissionsCSV(stringValue(effectiveVariables["permissions"]) ?? "session:read") : CodexTokenManager.normalizePermissions(permissionValues)
        guard !permissions.isEmpty else {
          return Result(errors: ["No valid permissions provided"])
        }
        let rawToken = try CodexTokenPersistence.createRawToken(name: name, permissions: permissions, expiresAt: stringValue(effectiveVariables["expiresAt"]), configDir: configDir)
        return Result(data: .string(rawToken))
      case "token.list":
        return Result(data: try jsonValue(CodexTokenPersistence.listMetadata(configDir: configDir)))
      case "token.revoke":
        return Result(data: .bool(try CodexTokenPersistence.revoke(id: try requiredString(effectiveVariables, "id"), configDir: configDir)))
      case "token.rotate":
        guard let token = try CodexTokenPersistence.rotate(id: try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Token not found"])
        }
        return Result(data: .string(token))

      case "files.rebuild":
        return Result(data: .object(try rebuildPersistentFileIndex(configDir: configDir, codexHome: codexHome)))
      case "files.list":
        let sessionId = try requiredString(effectiveVariables, "sessionId")
        guard let session = CodexSessionIndex.findSession(id: sessionId, codexHome: codexHome) else {
          return Result(errors: ["session not found: \(sessionId)"])
        }
        return Result(data: .object(try fileChangeSummaryJSON(for: session)))
      case "files.patches":
        let sessionId = try requiredString(effectiveVariables, "sessionId")
        guard let session = CodexSessionIndex.findSession(id: sessionId, codexHome: codexHome) else {
          return Result(errors: ["session not found: \(sessionId)"])
        }
        return Result(data: .object(try filePatchHistoryJSON(for: session)))
      case "files.find":
        return Result(data: .object(try findPersistentSessionsByFile(path: try requiredString(effectiveVariables, "path"), configDir: configDir, codexHome: codexHome)))
      default:
        return Result(errors: ["Unhandled command: \(commandName)"])
      }
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }
}

public enum CodexGraphQLError: Error, Equatable {
  case missingDocument
  case missingFlagValue(String)
  case variablesMustBeObject
  case invalidParam(String)
  case missingVariable(String)
}

private func executeQueueMutation(commandName: String, variables: JSONObject, configDir: String, codexHome: String?) -> CodexGraphQLCommandExecutor.Result {
  do {
    var config = try CodexQueuePersistence.load(configDir: configDir)
    var repository = CodexQueueRepository()
    repository.replaceQueues(config.queues)
    let requestedId = try requiredString(variables, "id")
    guard let requestedQueue = repository.findQueue(requestedId) else {
      return CodexGraphQLCommandExecutor.Result(errors: ["Queue not found"])
    }
    let id = requestedQueue.id
    let ok: Bool
    switch commandName {
    case "queue.pause":
      ok = repository.pauseQueue(id: id)
    case "queue.resume":
      ok = repository.resumeQueue(id: id)
    case "queue.update":
      let commandId = try requiredString(variables, "commandId", fallback: "promptId")
      let status: CodexQueuePromptStatus?
      if let rawStatus = stringValue(variables["status"]) {
        guard let parsedStatus = CodexQueuePromptStatus(rawValue: rawStatus) else {
          return CodexGraphQLCommandExecutor.Result(errors: ["status must be one of: pending, running, completed, failed"])
        }
        status = parsedStatus
      } else {
        status = nil
      }
      ok = repository.updatePrompt(queueId: id, promptId: commandId, prompt: stringValue(variables["prompt"]), status: status, resultExitCode: intValue(variables["resultExitCode"]))
    case "queue.remove":
      ok = repository.removePrompt(queueId: id, promptId: try requiredString(variables, "commandId", fallback: "promptId"))
    case "queue.move":
      if let from = intValue(variables["from"]), let to = intValue(variables["to"]) {
        ok = repository.movePrompt(queueId: id, from: from, to: to)
      } else {
        ok = repository.movePrompt(queueId: id, promptId: try requiredString(variables, "promptId"), toIndex: intValue(variables["toIndex"]) ?? 0)
      }
    case "queue.mode":
      guard let mode = CodexQueueCommandMode(rawValue: try requiredString(variables, "mode")) else {
        return CodexGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
      }
      if let commandId = stringValue(variables["commandId"]) ?? stringValue(variables["promptId"]) {
        ok = repository.updatePrompt(queueId: id, promptId: commandId, mode: mode)
      } else {
        ok = repository.setMode(queueId: id, mode: mode)
      }
    case "queue.run":
      let executableName = executableName(from: variables)
      let manager = CodexProcessManager(executableName: executableName)
      var events: [JSONObject] = []
      let queueProjectPath = repository.findQueue(id)?.projectPath
      if repository.findQueue(id)?.paused == true {
        let pending = repository.findQueue(id)?.prompts.filter { $0.status == .pending }.map(\.id) ?? []
        return CodexGraphQLCommandExecutor.Result(data: .array([.object(queueEvent(type: "queue_stopped", queueId: id, pending: pending))]))
      }
      var pendingIds = repository.findQueue(id)?.prompts.filter { $0.status == .pending }.map(\.id) ?? []
      let prompts = try repository.runQueue(id: id, afterPrompt: { queues in
        config.queues = queues
        try CodexQueuePersistence.save(config, configDir: configDir)
      }) { prompt in
        pendingIds.removeAll { $0 == prompt.id }
        events.append(queueEvent(type: "prompt_started", queueId: id, promptId: prompt.id, current: prompt.id, pending: pendingIds))
        var options = try processOptions(from: variables, codexHome: codexHome)
        options.cwd = queueProjectPath
        options.images = Array(Set(prompt.imagePaths + options.images)).sorted()
        let result = manager.spawnExec(prompt: prompt.prompt, options: options).result
        events.append(queueEvent(type: result.exitCode == 0 ? "prompt_completed" : "prompt_failed", queueId: id, promptId: prompt.id, exitCode: Int(result.exitCode), pending: pendingIds))
        return Int(result.exitCode)
      }
      let completed = prompts.filter { $0.status == .completed }.map(\.id)
      let failed = prompts.filter { $0.status == .failed }.map(\.id)
      let pending = repository.findQueue(id)?.prompts.filter { $0.status == .pending }.map(\.id) ?? []
      events.append(queueEvent(type: "queue_completed", queueId: id, completed: completed, pending: pending, failed: failed))
      config.queues = repository.listQueues()
      try CodexQueuePersistence.save(config, configDir: configDir)
      return CodexGraphQLCommandExecutor.Result(data: .array(events.map(JSONValue.object)))
    default:
      return CodexGraphQLCommandExecutor.Result(errors: ["Unhandled queue mutation: \(commandName)"])
    }
    guard ok else {
      return CodexGraphQLCommandExecutor.Result(errors: ["Queue command not found"])
    }
    config.queues = repository.listQueues()
    try CodexQueuePersistence.save(config, configDir: configDir)
    return CodexGraphQLCommandExecutor.Result(data: .object(["ok": .bool(ok)]))
  } catch {
    return CodexGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

private func runGroupEvents(group: CodexGroup, prompt: String, variables: JSONObject, codexHome: String?) throws -> [JSONObject] {
  guard !group.paused else {
    throw CodexGraphQLError.missingVariable("group is paused: \(group.id)")
  }
  var events: [JSONObject] = []
  var completed: [String] = []
  var failed: [String] = []
  var pending = group.sessionIds
  var running: [String] = []
  let maxConcurrent = max(1, intValue(variables["maxConcurrent"]) ?? 3)
  let executableName = executableName(from: variables)
  let options = try processOptions(from: variables, codexHome: codexHome)
  while !pending.isEmpty {
    let batch = Array(pending.prefix(maxConcurrent))
    pending.removeFirst(batch.count)
    running.append(contentsOf: batch)
    for sessionId in batch {
      events.append(groupEvent(type: "session_started", groupId: group.id, sessionId: sessionId, running: running, completed: completed, failed: failed, pending: pending))
    }

    let resultStore = GroupRunResultStore()
    let dispatchGroup = DispatchGroup()
    for sessionId in batch {
      dispatchGroup.enter()
      DispatchQueue.global(qos: .utility).async {
        let manager = CodexProcessManager(executableName: executableName)
        let result = manager.spawnResume(sessionId: sessionId, prompt: prompt, options: options).result
        resultStore.append(sessionId: sessionId, exitCode: result.exitCode)
        dispatchGroup.leave()
      }
    }
    dispatchGroup.wait()

    for (sessionId, exitCode) in resultStore.sorted() {
      running.removeAll { $0 == sessionId }
      if exitCode == 0 {
        completed.append(sessionId)
        events.append(groupEvent(type: "session_completed", groupId: group.id, sessionId: sessionId, exitCode: Int(exitCode), running: running, completed: completed, failed: failed, pending: pending))
      } else {
        failed.append(sessionId)
        events.append(groupEvent(type: "session_failed", groupId: group.id, sessionId: sessionId, exitCode: Int(exitCode), running: running, completed: completed, failed: failed, pending: pending))
      }
    }
  }
  events.append(groupEvent(type: "group_completed", groupId: group.id, running: running, completed: completed, failed: failed, pending: pending))
  return events
}

private func queueEvent(type: String, queueId: String, promptId: String? = nil, exitCode: Int? = nil, current: String? = nil, completed: [String] = [], pending: [String] = [], failed: [String] = []) -> JSONObject {
  var event: JSONObject = [
    "type": .string(type),
    "queueId": .string(queueId),
    "completed": .array(completed.map(JSONValue.string)),
    "pending": .array(pending.map(JSONValue.string)),
    "failed": .array(failed.map(JSONValue.string)),
  ]
  if let promptId {
    event["promptId"] = .string(promptId)
  }
  if let exitCode {
    event["exitCode"] = .number(Double(exitCode))
  }
  if let current {
    event["current"] = .string(current)
  }
  return event
}

private func groupEvent(type: String, groupId: String, sessionId: String? = nil, exitCode: Int? = nil, running: [String] = [], completed: [String] = [], failed: [String] = [], pending: [String] = []) -> JSONObject {
  var event: JSONObject = [
    "type": .string(type),
    "groupId": .string(groupId),
    "running": .array(running.map(JSONValue.string)),
    "completed": .array(completed.map(JSONValue.string)),
    "failed": .array(failed.map(JSONValue.string)),
    "pending": .array(pending.map(JSONValue.string)),
  ]
  if let sessionId {
    event["sessionId"] = .string(sessionId)
  }
  if let exitCode {
    event["exitCode"] = .number(Double(exitCode))
  }
  return event
}

private final class GroupRunResultStore: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [(String, Int32)] = []

  func append(sessionId: String, exitCode: Int32) {
    lock.lock()
    results.append((sessionId, exitCode))
    lock.unlock()
  }

  func sorted() -> [(String, Int32)] {
    lock.lock()
    defer { lock.unlock() }
    return results.sorted { $0.0 < $1.0 }
  }
}

private func sessionListOptions(from variables: JSONObject, codexHome: String?) -> CodexSessionListOptions {
  CodexSessionListOptions(
    codexHome: codexHome,
    source: stringValue(variables["source"]).flatMap(CodexSessionSource.init(rawValue:)),
    cwd: stringValue(variables["cwd"]),
    branch: stringValue(variables["branch"]),
    limit: intValue(variables["limit"]) ?? 50,
    offset: intValue(variables["offset"]) ?? 0,
    sortBy: stringValue(variables["sortBy"]) ?? "createdAt",
    sortOrder: stringValue(variables["sortOrder"]) ?? "desc"
  )
}

private func transcriptSearchOptions(from variables: JSONObject) -> CodexSessionTranscriptSearchOptions {
  CodexSessionTranscriptSearchOptions(
    caseSensitive: boolValue(variables["caseSensitive"]) ?? false,
    role: stringValue(variables["role"]) ?? "both",
    maxBytes: intValue(variables["maxBytes"]).map { max(0, $0) },
    maxEvents: intValue(variables["maxEvents"]).map { max(0, $0) },
    maxSessions: intValue(variables["maxSessions"]).map { max(0, $0) },
    timeoutMs: intValue(variables["timeoutMs"]).map { max(0, $0) },
    limit: max(0, intValue(variables["limit"]) ?? 50),
    offset: max(0, intValue(variables["offset"]) ?? 0)
  )
}

private func rebuildFileIndex(codexHome: String?) throws -> CodexFileChangeIndex {
  let lines = discoverRolloutPaths(codexHome: codexHome).flatMap { path in
    (try? CodexRolloutReader.readRollout(path: path)) ?? []
  }
  return CodexFileChangeIndex.rebuild(from: lines)
}

private struct PersistentChangedFile: Codable {
  var path: String
  var operation: String
  var changeCount: Int
  var lastModified: String
}

private struct PersistentSessionFileIndexEntry: Codable {
  var sessionId: String
  var files: [PersistentChangedFile]
  var indexedAt: String
}

private struct PersistentFileChangeIndex: Codable {
  var sessions: [PersistentSessionFileIndexEntry]
  var updatedAt: String
}

private func persistentFileIndexURL(configDir: String) -> URL {
  URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("file-changes-index.json")
}

private func rebuildPersistentFileIndex(configDir: String, codexHome: String?) throws -> JSONObject {
  let indexedAt = ISO8601DateFormatter().string(from: Date())
  let entries = discoverRolloutPaths(codexHome: codexHome).compactMap { path -> PersistentSessionFileIndexEntry? in
    guard let lines = try? CodexRolloutReader.readRollout(path: path) else {
      return nil
    }
    let sessionId = rolloutSessionId(lines: lines, path: path)
    let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let parsedFiles = changedFilesSummary(from: lines)
    let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges(raw), timestamp: indexedAt) : parsedFiles
    return PersistentSessionFileIndexEntry(sessionId: sessionId, files: files, indexedAt: indexedAt)
  }
  let index = PersistentFileChangeIndex(sessions: entries, updatedAt: indexedAt)
  let url = persistentFileIndexURL(configDir: configDir)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let data = try JSONEncoder().encode(index)
  try data.write(to: url, options: .atomic)
  return [
    "indexedSessions": .number(Double(entries.count)),
    "indexedFiles": .number(Double(entries.reduce(0) { $0 + $1.files.count })),
    "updatedAt": .string(indexedAt),
  ]
}

private func findPersistentSessionsByFile(path: String, configDir: String, codexHome: String?) throws -> JSONObject {
  let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !target.isEmpty else {
    throw CodexGraphQLError.missingVariable("path")
  }
  let url = persistentFileIndexURL(configDir: configDir)
  if !FileManager.default.isReadableFile(atPath: url.path) {
    _ = try rebuildPersistentFileIndex(configDir: configDir, codexHome: codexHome)
  }
  let index = try JSONDecoder().decode(PersistentFileChangeIndex.self, from: Data(contentsOf: url))
  let sessions = index.sessions.flatMap { entry in
    entry.files.filter { $0.path == target }.map { file in
      [
        "sessionId": .string(entry.sessionId),
        "operation": .string(file.operation),
        "lastModified": .string(file.lastModified),
      ] as JSONObject
    }
  }.sorted { lhs, rhs in
    (stringValue(lhs["lastModified"]) ?? "") > (stringValue(rhs["lastModified"]) ?? "")
  }
  return [
    "path": .string(target),
    "sessions": .array(sessions.map(JSONValue.object)),
  ]
}

private func rolloutSessionId(lines: [CodexRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = fileChangeObject(line.payload), let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

private func changedFilesSummary(from lines: [CodexRolloutLine]) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for line in lines {
    for change in CodexFileChanges.extract(from: line) {
      let paths = [change.previousPath, change.path].compactMap { $0 }.filter { !$0.isEmpty }
      for path in paths {
        var file = files[path] ?? PersistentChangedFile(path: path, operation: change.operation.rawValue, changeCount: 0, lastModified: line.timestamp)
        file.operation = change.operation.rawValue
        file.changeCount += 1
        file.lastModified = max(file.lastModified, line.timestamp)
        files[path] = file
      }
    }
  }
  return files.values.sorted { $0.path < $1.path }
}

private func changedFilesSummary(changes: [CodexFileChange], timestamp: String) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for change in changes {
    let paths = [change.previousPath, change.path].compactMap { $0 }.filter { !$0.isEmpty }
    for path in paths {
      var file = files[path] ?? PersistentChangedFile(path: path, operation: change.operation.rawValue, changeCount: 0, lastModified: timestamp)
      file.operation = change.operation.rawValue
      file.changeCount += 1
      file.lastModified = timestamp
      files[path] = file
    }
  }
  return files.values.sorted { $0.path < $1.path }
}

private func fileChangeIndex(for session: CodexSession) throws -> CodexFileChangeIndex {
  let index = try CodexFileChangeIndex.rebuild(from: CodexRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return CodexFileChangeIndex(changes: parseRawPatchFileChanges(raw))
}

private struct FileChangeDetailDTO {
  var path: String
  var timestamp: String
  var operation: String
  var source: String
  var previousPath: String?
  var command: String?
  var patch: String?
}

private func fileChangeSummaryJSON(for session: CodexSession) throws -> JSONObject {
  let lines = try CodexRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count)),
  ]
}

private func filePatchHistoryJSON(for session: CodexSession) throws -> JSONObject {
  let lines = try CodexRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  var details = fileChangeDetails(from: lines)
  if details.isEmpty {
    details = parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? "").map {
      FileChangeDetailDTO(path: $0.path, timestamp: timestamp, operation: $0.operation.rawValue, source: $0.source.rawValue, previousPath: $0.previousPath, command: $0.command, patch: $0.patch)
    }
  }
  var grouped: [String: [FileChangeDetailDTO]] = [:]
  for detail in details {
    grouped[detail.path, default: []].append(detail)
    if let previousPath = detail.previousPath, previousPath != detail.path {
      grouped[previousPath, default: []].append(FileChangeDetailDTO(path: previousPath, timestamp: detail.timestamp, operation: "deleted", source: detail.source, previousPath: detail.previousPath, command: detail.command, patch: detail.patch))
    }
  }
  let files = grouped.keys.sorted().map { path -> JSONObject in
    let entries = (grouped[path] ?? []).sorted { lhs, rhs in lhs.timestamp < rhs.timestamp }
    let last = entries.last
    return [
      "path": .string(path),
      "operation": .string(last?.operation ?? "modified"),
      "changeCount": .number(Double(entries.count)),
      "lastModified": .string(last?.timestamp ?? timestamp),
      "changes": .array(entries.map { .object(fileChangeDetailJSON($0)) }),
    ]
  }
  let totalChanges = files.reduce(0) { partial, file in
    partial + (intValue(file["changeCount"]) ?? 0)
  }
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(JSONValue.object)),
    "totalFiles": .number(Double(files.count)),
    "totalChanges": .number(Double(totalChanges)),
  ]
}

private func persistentChangedFileJSON(_ file: PersistentChangedFile) -> JSONValue {
  .object([
    "path": .string(file.path),
    "operation": .string(file.operation),
    "changeCount": .number(Double(file.changeCount)),
    "lastModified": .string(file.lastModified),
  ])
}

private func fileChangeDetails(from lines: [CodexRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    CodexFileChanges.extract(from: line).map { change in
      FileChangeDetailDTO(path: change.path, timestamp: line.timestamp, operation: change.operation.rawValue, source: change.source.rawValue, previousPath: change.previousPath, command: change.command, patch: change.patch)
    }
  }
}

private func fileChangeDetailJSON(_ detail: FileChangeDetailDTO) -> JSONObject {
  var object: JSONObject = [
    "path": .string(detail.path),
    "timestamp": .string(detail.timestamp),
    "operation": .string(detail.operation),
    "source": .string(detail.source),
    "previousPath": detail.previousPath.map(JSONValue.string) ?? .null,
  ]
  if let command = detail.command {
    object["command"] = .string(command)
  }
  if let patch = detail.patch {
    object["patch"] = .string(patch)
  }
  return object
}

private func parseRawPatchFileChanges(_ text: String) -> [CodexFileChange] {
  text.split(separator: "\n").compactMap { rawLine in
    let line = String(rawLine)
    if let range = line.range(of: "*** Add File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .created, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Delete File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .deleted, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Update File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .modified, source: .applyPatch, patch: text)
    }
    return nil
  }
}

private func sessionJSON(_ session: CodexSession) -> JSONValue {
  var object: JSONObject = [
    "id": .string(session.id),
    "rolloutPath": .string(session.rolloutPath),
    "createdAt": .string(isoString(session.createdAt)),
    "updatedAt": .string(isoString(session.updatedAt)),
    "source": .string(session.source.rawValue),
    "modelProvider": session.modelProvider.map(JSONValue.string) ?? .null,
    "cwd": .string(session.cwd),
    "cliVersion": .string(session.cliVersion),
    "title": .string(session.title),
    "firstUserMessage": session.firstUserMessage.map(JSONValue.string) ?? .null,
    "archivedAt": session.archivedAt.map { .string(isoString($0)) } ?? .null,
    "forkedFromId": session.forkedFromId.map(JSONValue.string) ?? .null,
  ]
  if let git = session.git {
    object["git"] = .object([
      "branch": git.branch.map(JSONValue.string) ?? .null,
      "sha": git.sha.map(JSONValue.string) ?? .null,
      "originURL": git.originURL.map(JSONValue.string) ?? .null,
    ])
  } else {
    object["git"] = .null
  }
  return .object(object)
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

private func extractLegacyCommandInvocation(from document: String, variables: JSONObject) -> (commandName: String?, variables: JSONObject) {
  guard document.contains("command(") else {
    return (nil, variables)
  }
  let commandName = extractGraphQLStringArgument(named: "name", from: document, variables: variables)
  if case let .object(params)? = variables["param"] {
    return (commandName, params)
  }
  if case let .object(params)? = variables["params"] {
    return (commandName, params)
  }
  if let params = extractInlineGraphQLParams(from: document) {
    return (commandName, params)
  }
  return (commandName, variables)
}

private func extractGraphQLStringArgument(named argumentName: String, from document: String, variables: JSONObject) -> String? {
  let escapedName = NSRegularExpression.escapedPattern(for: argumentName)
  if let literal = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*"([^"]+)""#) {
    return literal
  }
  guard let variableName = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#) else {
    return nil
  }
  return stringValue(variables[variableName])
}

private func isPingDocument(_ document: String) -> Bool {
  let stripped = document
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stripped == "query { ping }" || stripped == "{ ping }"
}

private func extractInlineGraphQLParams(from document: String) -> JSONObject? {
  guard let paramsRange = document.range(of: "params") else {
    return nil
  }
  guard let colon = document[paramsRange.upperBound...].firstIndex(of: ":") else {
    return nil
  }
  guard let open = document[colon...].firstIndex(of: "{") else {
    return nil
  }
  guard let close = matchingBrace(in: document, open: open) else {
    return nil
  }
  let literal = String(document[open...close])
  let jsonText = quoteGraphQLObjectKeys(literal)
  guard
    let data = jsonText.data(using: .utf8),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value
  else {
    return nil
  }
  return object
}

private func matchingBrace(in text: String, open: String.Index) -> String.Index? {
  var depth = 0
  var inString = false
  var escaped = false
  var index = open
  while index < text.endIndex {
    let character = text[index]
    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
    } else if character == "\"" {
      inString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return index
      }
    }
    index = text.index(after: index)
  }
  return nil
}

private func quoteGraphQLObjectKeys(_ literal: String) -> String {
  literal.replacingOccurrences(
    of: #"([,{]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
    with: #"$1"$2":"#,
    options: .regularExpression
  )
}

private func firstRegexCapture(in text: String, pattern: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
    return nil
  }
  return String(text[capture])
}

private func shorthandOperation(for command: String) -> String {
  if command == "session.watch" {
    return "subscription"
  }
  return mutationCommandNames.contains(command) ? "mutation" : "query"
}

private func escapeGraphQLString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

private let mutationCommandNames: Set<String> = [
  "session.run",
  "session.resume",
  "session.fork",
  "group.create",
  "group.add",
  "group.remove",
  "group.pause",
  "group.resume",
  "group.delete",
  "group.run",
  "queue.create",
  "queue.add",
  "queue.pause",
  "queue.resume",
  "queue.delete",
  "queue.update",
  "queue.remove",
  "queue.move",
  "queue.mode",
  "queue.run",
  "bookmark.add",
  "bookmark.delete",
  "token.create",
  "token.revoke",
  "token.rotate",
  "files.rebuild",
]

private func rolloutLineJSON(_ line: CodexRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload,
  ])
}

private func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let codex = probeToolVersion(executableName(from: variables), arguments: ["--version"])
  let includeGit = boolValue(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "codex": .object(codex),
    "git": includeGit ? .object(probeToolVersion(stringValue(variables["gitBinary"]) ?? "git", arguments: ["--version"])) : .null,
  ]
}

private func probeToolVersion(_ executable: String, arguments: [String]) -> JSONObject {
  let process = Process()
  process.executableURL = resolveExecutableURL(executable)
  process.arguments = arguments
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  do {
    try process.run()
    process.waitUntilExit()
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return [
      "available": .bool(process.terminationStatus == 0),
      "version": .string(out.trimmingCharacters(in: .whitespacesAndNewlines)),
      "exitCode": .number(Double(process.terminationStatus)),
      "stderr": .string(err.trimmingCharacters(in: .whitespacesAndNewlines)),
    ]
  } catch {
    return [
      "available": .bool(false),
      "version": .null,
      "error": .string(String(describing: error)),
    ]
  }
}

private func resolveExecutableURL(_ executable: String) -> URL {
  if executable.contains("/") {
    return URL(fileURLWithPath: executable)
  }
  let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  for directory in environmentPath.split(separator: ":").map(String.init) {
    let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  return URL(fileURLWithPath: executable)
}

private func processExecutionJSON(process: CodexProcessRecord, result: CodexProcessExecution) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "stdout": .string(result.stdout),
    "stderr": .string(result.stderr),
    "exitCode": .number(Double(result.exitCode)),
    "arguments": .array(process.arguments.map(JSONValue.string)),
  ]
}

private func processHandleJSON(_ process: CodexProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string)),
  ]
}

private func sessionExecutionJSON(process: CodexProcessRecord, result: CodexProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { CodexRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

private func extractSessionId(from lines: [CodexRolloutLine]) -> String? {
  for line in lines {
    guard let payload = fileChangeObject(line.payload) else {
      continue
    }
    if let sessionId = fileChangeString(payload["session_id"]) ?? fileChangeString(payload["sessionId"]) {
      return sessionId
    }
    if let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  return nil
}

private func jsonValue<Value: Encodable>(_ value: Value?) throws -> JSONValue {
  guard let value else {
    return .null
  }
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func requiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = stringValue(object[key]), !value.isEmpty else {
    throw CodexGraphQLError.missingVariable(key)
  }
  return value
}

private func requiredString(_ object: JSONObject, _ key: String, fallback: String) throws -> String {
  if let value = stringValue(object[key]), !value.isEmpty {
    return value
  }
  if let value = stringValue(object[fallback]), !value.isEmpty {
    return value
  }
  throw CodexGraphQLError.missingVariable(key)
}

private func requiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = stringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw CodexGraphQLError.missingVariable(key)
  }
  return value
}

private func resolveQueueId(_ idOrName: String, configDir: String) throws -> String {
  try CodexQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

private func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try CodexQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw CodexGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

private func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try CodexGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

private func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
  guard let group = try CodexGroupPersistence.findGroup(idOrName, configDir: configDir) else {
    throw CodexGraphQLError.missingVariable("Group not found")
  }
  return group.id
}

private func defaultCodexAgentConfigDir() -> String {
  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex-agent", isDirectory: true).path
}

public enum CodexMarkdown {
  public struct Section: Equatable, Sendable {
    public var level: Int
    public var heading: String
    public var body: String
  }

  public struct Task: Equatable, Sendable {
    public var sectionHeading: String
    public var text: String
    public var checked: Bool
  }

  public static func parseTasks(_ markdown: String) -> [Task] {
    var heading = ""
    var tasks: [Task] = []
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("#") {
        heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# " ))
      } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
        let checked = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
        tasks.append(Task(sectionHeading: heading, text: String(line.dropFirst(6)), checked: checked))
      }
    }
    return tasks
  }

  public static func parseSections(_ markdown: String) -> [Section] {
    var sections: [Section] = []
    var currentLevel = 0
    var currentHeading = ""
    var body: [String] = []
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let heading = parseHeading(line) {
        if !currentHeading.isEmpty || !body.isEmpty {
          sections.append(Section(level: currentLevel, heading: currentHeading, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        currentLevel = heading.level
        currentHeading = heading.text
        body = []
      } else {
        body.append(line)
      }
    }
    if !currentHeading.isEmpty || !body.isEmpty {
      sections.append(Section(level: currentLevel, heading: currentHeading, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return sections
  }

  private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes > 0, hashes < line.count, line.dropFirst(hashes).first == " " else {
      return nil
    }
    return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public enum CodexFileChangeSource: String, Equatable, Codable, Sendable {
  case applyPatch = "apply_patch"
  case shell
  case execCommand = "exec_command"
  case localShell = "local_shell"
}

public enum CodexFileOperation: String, Equatable, Codable, Sendable {
  case created
  case modified
  case deleted
  case moved
}

public struct CodexFileChange: Equatable, Codable, Sendable {
  public var path: String
  public var operation: CodexFileOperation
  public var source: CodexFileChangeSource
  public var previousPath: String?
  public var command: String?
  public var patch: String?

  public init(path: String, operation: CodexFileOperation, source: CodexFileChangeSource, previousPath: String? = nil, command: String? = nil, patch: String? = nil) {
    self.path = path
    self.operation = operation
    self.source = source
    self.previousPath = previousPath
    self.command = command
    self.patch = patch
  }
}

public enum CodexFileChanges {
  public static func extract(from lines: [CodexRolloutLine]) -> [CodexFileChange] {
    var pending: [String: [CodexFileChange]] = [:]
    var changes: [CodexFileChange] = []
    for line in lines {
      guard let payload = fileChangeObject(line.payload) else {
        continue
      }
      if let callId = fileChangeString(payload["call_id"]) ?? fileChangeString(payload["callId"]) ?? fileChangeString(payload["id"]) {
        if isToolResultPayload(payload) {
          if isSuccessfulToolResult(payload), let pendingChanges = pending.removeValue(forKey: callId) {
            changes.append(contentsOf: pendingChanges)
          } else {
            pending.removeValue(forKey: callId)
          }
          changes.append(contentsOf: extractDirectChanges(from: payload))
          continue
        }
        if isToolInvocationPayload(payload) {
          let invocationChanges = extractDirectChanges(from: payload)
          if !invocationChanges.isEmpty {
            pending[callId] = invocationChanges
            continue
          }
        }
      }
      changes.append(contentsOf: extract(from: line))
    }
    return changes
  }

  public static func extract(from line: CodexRolloutLine) -> [CodexFileChange] {
    guard let payload = fileChangeObject(line.payload) else {
      return []
    }
    if let exitCode = numberValue(payload["exit_code"]), exitCode != 0 {
      return []
    }
    if let changes = fileChangeArray(payload["file_changes"]) {
      return changes
    }
    if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
      return commandChanges
    }
    if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["aggregated_output"]) {
      return parsePatchFileChanges(patch)
    }
    return []
  }
}

private func isToolInvocationPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type)
}

private func isToolResultPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call_output", "custom_tool_call_output", "local_shell_call_output", "ExecCommandEnd"].contains(type)
}

private func isSuccessfulToolResult(_ payload: JSONObject) -> Bool {
  if boolValue(payload["is_error"]) == true || boolValue(payload["isError"]) == true {
    return false
  }
  if let exitCode = numberValue(payload["exit_code"]) ?? numberValue(payload["exitCode"]) {
    return exitCode == 0
  }
  if let status = fileChangeString(payload["status"])?.lowercased() {
    return isSuccessfulToolStatus(status)
  }
  if let output = fileChangeObject(payload["output"]) ?? fileChangeString(payload["output"]).flatMap(parseFileChangeArguments) {
    if boolValue(output["is_error"]) == true || boolValue(output["isError"]) == true {
      return false
    }
    if let metadata = fileChangeObject(output["metadata"]) {
      if boolValue(metadata["is_error"]) == true || boolValue(metadata["isError"]) == true {
        return false
      }
      if let exitCode = numberValue(metadata["exit_code"]) ?? numberValue(metadata["exitCode"]), exitCode != 0 {
        return false
      }
      if let status = fileChangeString(metadata["status"])?.lowercased() {
        return isSuccessfulToolStatus(status)
      }
    }
    if let exitCode = numberValue(output["exit_code"]) ?? numberValue(output["exitCode"]), exitCode != 0 {
      return false
    }
    if let status = fileChangeString(output["status"])?.lowercased() {
      return isSuccessfulToolStatus(status)
    }
  }
  return true
}

private func isSuccessfulToolStatus(_ status: String) -> Bool {
  ["completed", "success", "succeeded", "ok"].contains(status)
}

private func extractDirectChanges(from payload: JSONObject) -> [CodexFileChange] {
  if let changes = fileChangeArray(payload["file_changes"]) {
    return changes
  }
  if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
    return commandChanges
  }
  if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["aggregated_output"]) ?? fileChangeString(payload["output"]) {
    return parsePatchFileChanges(patch)
  }
  return []
}

private func commandLikeFileChanges(payload: JSONObject) -> [CodexFileChange]? {
  let type = fileChangeString(payload["type"])
  guard ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type) else {
    return nil
  }
  if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["input"]) {
    let changes = parsePatchFileChanges(patch)
    if !changes.isEmpty {
      return changes
    }
  }
  let argumentObject = fileChangeObject(payload["arguments"]) ?? fileChangeString(payload["arguments"]).flatMap(parseFileChangeArguments)
  let command = fileChangeString(argumentObject?["command"])
    ?? fileChangeString(argumentObject?["cmd"])
    ?? fileChangeString(argumentObject?["script"])
    ?? stringArrayValue(argumentObject?["command"]).map { $0.joined(separator: " ") }
    ?? stringArrayValue(payload["command"]).map { $0.joined(separator: " ") }
  guard let command else {
    return nil
  }
  return parseShellFileChanges(command)
}

private func parsePatchFileChanges(_ patch: String) -> [CodexFileChange] {
  var pendingUpdatePath: String?
  var pendingUpdateIndex: Int?
  var changes: [CodexFileChange] = []
  for rawLine in patch.split(separator: "\n") {
    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("*** Add File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CodexFileChange(path: String(line.dropFirst("*** Add File: ".count)), operation: .created, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Delete File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CodexFileChange(path: String(line.dropFirst("*** Delete File: ".count)), operation: .deleted, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Update File: ") {
      pendingUpdatePath = String(line.dropFirst("*** Update File: ".count))
      pendingUpdateIndex = changes.count
      changes.append(CodexFileChange(path: pendingUpdatePath ?? "", operation: .modified, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Move to: "), let from = pendingUpdatePath {
      let to = String(line.dropFirst("*** Move to: ".count))
      if let pendingUpdateIndex {
        changes[pendingUpdateIndex] = CodexFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch)
      } else {
        changes.append(CodexFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch))
      }
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      continue
    }
  }
  return changes
}

private func parseFileChangeArguments(_ text: String) -> JSONObject? {
  guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value else {
    return nil
  }
  return object
}

private func parseShellFileChanges(_ command: String) -> [CodexFileChange] {
  if command.contains("*** Begin Patch") || command.contains("*** Add File:") || command.contains("*** Update File:") || command.contains("*** Delete File:") {
    let changes = parsePatchFileChanges(command)
    if !changes.isEmpty {
      return changes.map { change in
        var annotated = change
        annotated.command = command
        return annotated
      }
    }
  }
  if let inner = unwrapBashLoginCommand(command) {
    return parseShellFileChanges(inner).map { change in
      var annotated = change
      annotated.command = annotated.command ?? command
      return annotated
    }
  }
  var changes: [CodexFileChange] = []
  let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
  guard !tokens.isEmpty else {
    return []
  }
  if tokens.prefix(2) == ["git", "mv"], tokens.count >= 4 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[3]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[2])))
  } else if tokens.prefix(2) == ["git", "rm"], tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .deleted, source: .shell))
  } else if tokens[0] == "mv", tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[1])))
  } else if tokens[0] == "cp", tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .created, source: .shell))
  } else if tokens[0] == "rm", tokens.count >= 2 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[1]), operation: .deleted, source: .shell))
  } else if tokens[0] == "touch", tokens.count >= 2 {
    for path in tokens.dropFirst() {
      changes.append(CodexFileChange(path: cleanShellPath(path), operation: .created, source: .shell))
    }
  } else if ["sed", "perl"].contains(tokens[0]), tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), let path = tokens.last {
    changes.append(CodexFileChange(path: cleanShellPath(path), operation: .modified, source: .shell))
  } else if tokens[0] == "tee", tokens.count >= 2 {
    let paths = tokens.dropFirst().filter { !$0.hasPrefix("-") && $0 != ">" && $0 != ">>" }
    for path in paths {
      changes.append(CodexFileChange(path: cleanShellPath(path), operation: tokens.contains("-a") ? .modified : .created, source: .shell))
    }
  }
  for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[index + 1]), operation: token == ">" ? .created : .modified, source: .shell))
  }
  return changes.map { change in
    var annotated = change
    annotated.command = command
    return annotated
  }
}

private func unwrapBashLoginCommand(_ command: String) -> String? {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  for prefix in ["bash -lc ", "sh -lc ", "zsh -lc "] where trimmed.hasPrefix(prefix) {
    return stripShellQuotes(String(trimmed.dropFirst(prefix.count)))
  }
  return nil
}

private func cleanShellPath(_ path: String) -> String {
  stripShellQuotes(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`; "))
}

private func stripShellQuotes(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
    value = String(value.dropFirst().dropLast())
  }
  return value
}

public struct CodexFileChangeIndex: Equatable, Sendable {
  private var changes: [CodexFileChange] = []

  public init(changes: [CodexFileChange] = []) {
    self.changes = changes
  }

  public static func rebuild(from lines: [CodexRolloutLine]) -> CodexFileChangeIndex {
    CodexFileChangeIndex(changes: CodexFileChanges.extract(from: lines))
  }

  public func listChangedFiles() -> [String] {
    Array(Set(changes.flatMap { change in
      [change.path, change.previousPath].compactMap { $0 }
    })).sorted()
  }

  public func patches(for path: String) -> [CodexFileChange] {
    changes.filter { $0.path == path || $0.previousPath == path }
  }

  public func find(_ path: String) -> CodexFileChange? {
    patches(for: path).last
  }

  public func fileHistories() -> [JSONObject] {
    listChangedFiles().map { path in
      let history = patches(for: path)
      return [
        "path": .string(path),
        "changeCount": .number(Double(history.count)),
        "changes": .array(history.map { change in
          var object: JSONObject = [
            "path": .string(change.path),
            "operation": .string(change.operation.rawValue),
            "source": .string(change.source.rawValue),
            "previousPath": change.previousPath.map(JSONValue.string) ?? .null,
          ]
          if let command = change.command {
            object["command"] = .string(command)
          }
          if let patch = change.patch {
            object["patch"] = .string(patch)
          }
          return .object(object)
        }),
      ]
    }
  }
}

private func fileChangeArray(_ value: JSONValue?) -> [CodexFileChange]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap { entry in
    guard let object = fileChangeObject(entry), let path = fileChangeString(object["path"]) else {
      return nil
    }
    return CodexFileChange(
      path: path,
      operation: CodexFileOperation(rawValue: fileChangeString(object["operation"]) ?? "") ?? .modified,
      source: CodexFileChangeSource(rawValue: fileChangeString(object["source"]) ?? "") ?? .shell,
      previousPath: fileChangeString(object["previousPath"] ?? object["previous_path"] ?? object["oldPath"] ?? object["from"]),
      command: fileChangeString(object["command"]),
      patch: fileChangeString(object["patch"])
    )
  }
}

private func fileChangeObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

private func fileChangeString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

private func stringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values)? = value else {
    return nil
  }
  return values.compactMap(fileChangeString)
}

private func numberValue(_ value: JSONValue?) -> Double? {
  guard case let .number(number) = value else {
    return nil
  }
  return number
}

private func intValue(_ value: JSONValue?) -> Int? {
  guard let number = numberValue(value) else {
    return nil
  }
  return Int(number)
}

private func nonNegativeUInt64Value(_ value: JSONValue?) -> UInt64? {
  guard let int = intValue(value) else {
    return nil
  }
  return UInt64(max(0, int))
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

private func stringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values) = value else {
    return []
  }
  return values.compactMap(stringValue)
}

private func parseLooseJSONValue(_ text: String) throws -> JSONValue {
  if let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
    return value
  }
  return .string(text)
}

private func processOptions(from object: JSONObject, codexHome defaultCodexHome: String? = nil) throws -> CodexProcessOptions {
  if let sandbox = stringValue(object["sandbox"]) {
    try validateStringUnion(sandbox, key: "sandbox", allowed: ["read-only", "workspace-write", "danger-full-access"])
  }
  if let approvalMode = stringValue(object["approvalMode"]) {
    try validateStringUnion(approvalMode, key: "approvalMode", allowed: ["always", "unless-allow-listed", "untrusted", "on-request", "on-failure", "never"])
  }
  if let streamGranularity = stringValue(object["streamGranularity"]) {
    try validateStringUnion(streamGranularity, key: "streamGranularity", allowed: ["event", "char"])
  }
  let images = try strictStringArray(object["images"], key: "images")
  let imagePaths = try strictStringArray(object["imagePaths"], key: "imagePaths")
  let additionalArguments = try strictStringArray(object["additionalArguments"], key: "additionalArguments")
  let additionalArgs = try strictStringArray(object["additionalArgs"], key: "additionalArgs")
  let environment = try strictStringDictionary(object["environment"], key: "environment")
  let environmentVariables = try strictStringDictionary(object["environmentVariables"], key: "environmentVariables")
  return CodexProcessOptions(
    model: stringValue(object["model"]),
    cwd: stringValue(object["cwd"]),
    sandbox: stringValue(object["sandbox"]),
    approvalMode: stringValue(object["approvalMode"]),
    fullAuto: boolValue(object["fullAuto"]) ?? false,
    images: images.isEmpty ? imagePaths : images,
    configOverrides: try strictStringArray(object["configOverrides"], key: "configOverrides"),
    additionalArguments: additionalArguments.isEmpty ? additionalArgs : additionalArguments,
    environmentVariables: environment.isEmpty ? environmentVariables : environment,
    systemPrompt: stringValue(object["systemPrompt"]),
    codexHome: stringValue(object["codexHome"]) ?? defaultCodexHome,
    streamGranularity: stringValue(object["streamGranularity"]),
    forwardApprovalMode: false
  )
}

private func validateStringUnion(_ value: String, key: String, allowed: Set<String>) throws {
  guard allowed.contains(value) else {
    throw CodexGraphQLError.invalidParam("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
  }
}

private func strictStringArray(_ value: JSONValue?, key: String) throws -> [String] {
  guard let value else {
    return []
  }
  guard case let .array(values) = value else {
    throw CodexGraphQLError.invalidParam("\(key) must be an array of strings")
  }
  return try values.enumerated().map { index, item in
    guard let string = stringValue(item) else {
      throw CodexGraphQLError.invalidParam("\(key)[\(index)] must be a string")
    }
    return string
  }
}

private func executableName(from object: JSONObject) -> String {
  stringValue(object["executableName"]) ?? stringValue(object["codexBinary"]) ?? "codex"
}

private func strictStringDictionary(_ value: JSONValue?, key: String) throws -> [String: String] {
  guard let value else {
    return [:]
  }
  guard case let .object(object) = value else {
    throw CodexGraphQLError.invalidParam("\(key) must be an object with string values")
  }
  var result: [String: String] = [:]
  for (key, value) in object {
    guard let string = stringValue(value) else {
      throw CodexGraphQLError.invalidParam("\(key) must be a string")
    }
    result[key] = string
  }
  return result
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

private func extractCommandName(from document: String) -> String? {
  let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
  if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}") {
    let inside = trimmed[trimmed.index(after: open)..<close]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return inside.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).first.map(String.init)
  }
  if CodexGraphQLCommandExecutor.supportedCommandNames.contains(trimmed) || trimmed.contains(".") {
    return trimmed
  }
  return nil
}
