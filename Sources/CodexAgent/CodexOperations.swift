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
    .graphql: [""]
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
        "title": .string(session.title)
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

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
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
    applyCommonLegacyFlags(flags, to: &values)
    applyCLIArguments(parsed, flags: flags, to: &values)
    return values
  }

  private static func applyCLIArguments(
    _ parsed: CodexCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    to values: inout JSONObject
  ) {
    switch parsed.family {
    case .queue:
      applyQueueCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .group:
      applyGroupCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .bookmark:
      applyBookmarkCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .token:
      applyTokenCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .session:
      applySessionCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .files:
      applyFilesCLIArguments(action: parsed.action, flags: flags, to: &values)
    case .model:
      setString("model", flags.positionals.first, to: &values)
    default:
      break
    }
  }

  private static func applyQueueCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    let positional = flags.positionals
    switch action {
    case "create":
      setString("name", positional.first, to: &values)
      setString("projectPath", flags.value("--project"), to: &values)
    case "add":
      setString("id", positional.first, to: &values)
      setString("prompt", flags.value("--prompt") ?? positional[safe: 1], to: &values)
    case "move":
      setString("id", positional.first, to: &values)
      setNumber("from", flags.value("--from").flatMap(Int.init) ?? positional[safe: 1].map { Int($0) ?? 0 }, to: &values)
      setNumber("to", flags.value("--to").flatMap(Int.init) ?? positional[safe: 2].map { Int($0) ?? 0 }, to: &values)
    case "update":
      setString("id", positional.first, to: &values)
      setString("commandId", positional[safe: 1], to: &values)
      setString("prompt", flags.value("--prompt"), to: &values)
      setString("status", flags.value("--status"), to: &values)
    case "remove":
      setString("id", positional.first, to: &values)
      setString("commandId", positional[safe: 1], to: &values)
    case "mode":
      setString("id", positional.first, to: &values)
      setString("commandId", positional[safe: 1], to: &values)
      setString("mode", flags.value("--mode") ?? positional[safe: 2], to: &values)
    default:
      setString("id", positional.first, to: &values)
    }
  }

  private static func applyGroupCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    let positional = flags.positionals
    switch action {
    case "create":
      setString("name", positional.first, to: &values)
      setString("description", flags.value("--description"), to: &values)
    case "add", "remove":
      setString("id", positional.first, to: &values)
      setString("sessionId", positional[safe: 1], to: &values)
    case "run":
      setString("id", positional.first, to: &values)
      setString("prompt", flags.value("--prompt"), to: &values)
      setNumber("maxConcurrent", flags.value("--max-concurrent").flatMap(Int.init), to: &values)
    default:
      setString("id", positional.first, to: &values)
    }
  }

  private static func applyBookmarkCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    let positional = flags.positionals
    switch action {
    case "add":
      setString("type", flags.value("--type") ?? positional.first, to: &values)
      setString("sessionId", flags.value("--session") ?? flags.value("--session-id") ?? positional[safe: 1], to: &values)
      setString("messageId", flags.value("--message") ?? flags.value("--message-id"), to: &values)
      setString("name", flags.value("--name"), to: &values)
      setString("description", flags.value("--description"), to: &values)
      setString("fromMessageId", flags.value("--from") ?? flags.value("--from-message") ?? flags.value("--from-message-id"), to: &values)
      setString("toMessageId", flags.value("--to") ?? flags.value("--to-message") ?? flags.value("--to-message-id"), to: &values)
      let tags = flags.values("--tag")
      if values["tags"] == nil, !tags.isEmpty {
        values["tags"] = .array(tags.map(JSONValue.string))
      }
    case "list":
      setString("sessionId", flags.value("--session") ?? flags.value("--session-id"), to: &values)
      setString("type", flags.value("--type"), to: &values)
      setString("tag", flags.value("--tag"), to: &values)
    case "search":
      setString("query", positional.first, to: &values)
    default:
      setString("id", positional.first, to: &values)
    }
  }

  private static func applyTokenCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    switch action {
    case "create":
      setString("name", flags.value("--name"), to: &values)
      setString("permissions", flags.value("--permissions"), to: &values)
      setString("expiresAt", flags.value("--expires-at"), to: &values)
    case "revoke", "rotate":
      setString("id", flags.positionals.first, to: &values)
    default:
      break
    }
  }

  private static func applySessionCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    let positional = flags.positionals
    switch action {
    case "searchTranscript":
      if positional.count > 1 {
        setString("id", positional.first, to: &values)
      }
      if values["query"] == nil {
        values["query"] = .string(positional.count > 1 ? positional[1] : (positional.first ?? ""))
      }
    case "search":
      setString("query", positional.first, to: &values)
    case "show", "watch":
      setString("id", positional.first, to: &values)
    case "resume":
      setString("id", positional.first, to: &values)
      let positionalPrompt = positional.count > 1 ? positional.dropFirst().joined(separator: " ") : nil
      setString("prompt", flags.value("--prompt") ?? positionalPrompt, to: &values)
    case "fork":
      setString("id", positional.first, to: &values)
      setNumber("nthMessage", flags.value("--nth-message").flatMap(Int.init) ?? positional[safe: 1].flatMap(Int.init), to: &values)
    case "run":
      setString("prompt", flags.value("--prompt") ?? positional.joined(separator: " "), to: &values)
    default:
      break
    }
  }

  private static func applyFilesCLIArguments(action: String?, flags: CLIFlagArguments, to values: inout JSONObject) {
    switch action {
    case "list", "patches":
      setString("sessionId", flags.positionals.first, to: &values)
    case "find":
      setString("path", flags.positionals.first, to: &values)
    default:
      break
    }
  }

  private static func setString(_ key: String, _ value: String?, to values: inout JSONObject) {
    if values[key] == nil, let value {
      values[key] = .string(value)
    }
  }

  private static func setNumber(_ key: String, _ value: Int?, to values: inout JSONObject) {
    if values[key] == nil, let value {
      values[key] = .number(Double(value))
    }
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
    "type"
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
      ("--executable-name", "executableName")
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
      ("--timeout-ms", "timeoutMs")
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
      "--nth-message"
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
