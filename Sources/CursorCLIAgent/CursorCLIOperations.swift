import Foundation
import RielaCore

public struct CursorCLIAgentCompatibilityContext: Equatable, Sendable {
  public var cursorCLIHome: String?
  public var configDir: String?
  public var authToken: String?

  public init(cursorCLIHome: String? = nil, configDir: String? = nil, authToken: String? = nil) {
    self.cursorCLIHome = cursorCLIHome
    self.configDir = configDir
    self.authToken = authToken
  }
}

public struct CursorCLICLIProcessOptions: Equatable, Sendable {
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

public enum CursorCLICLICompatibility {
  public enum CommandFamily: String, Equatable, Sendable {
    case auth
    case activity
    case session
    case group
    case queue
    case bookmark
    case token
    case files
    case model
    case skill
    case daemon
    case server
    case usage
    case markdown
    case repo
    case version
    case graphql
  }

  public struct ParsedCommand: Equatable, Sendable {
    public var family: CommandFamily
    public var action: String?
    public var arguments: [String]
  }

  public static let supportedCommands: [CommandFamily: Set<String>] = [
    .auth: ["status", "verify", "info", "token"],
    .activity: ["list", "get", "status", "update", "cleanup", "setup"],
    .session: ["list", "show", "get", "messages", "watch", "run", "create", "cancel", "pause", "resume", "fork", "search", "searchTranscript"],
    .group: ["create", "list", "show", "get", "watch", "add", "remove", "pause", "resume", "delete", "run"],
    .queue: ["create", "add", "show", "get", "list", "pause", "resume", "stop", "delete", "update", "remove", "move", "mode", "run"],
    .bookmark: ["add", "list", "get", "show", "content", "delete", "search"],
    .token: ["create", "list", "revoke", "rotate"],
    .files: ["list", "patches", "find", "rebuild"],
    .model: ["check"],
    .skill: ["list", "show"],
    .daemon: ["status", "start", "stop", "restart"],
    .server: ["status", "events"],
    .usage: ["list", "stats", "summary"],
    .markdown: ["tasks", "parse"],
    .repo: ["status", "files", "analytics", "summary"],
    .version: [""],
    .graphql: [""],
  ]

  public static func parseCommand(_ arguments: [String]) throws -> ParsedCommand {
    let stripped = try stripRootOptions(arguments)
    guard let rawFamily = stripped.first, let family = CommandFamily(rawValue: rawFamily) else {
      throw CursorCLICLIError.unknownCommand(stripped.first ?? "")
    }
    if family == .version || family == .graphql {
      return ParsedCommand(family: family, action: nil, arguments: Array(arguments.dropFirst()))
    }
    guard arguments.count >= 2 else {
      throw CursorCLICLIError.missingAction(rawFamily)
    }
    if family == .queue, arguments.count >= 3, arguments[1] == "command" {
      let legacyAction = arguments[2]
      let action: String
      switch legacyAction {
      case "add":
        action = "add"
      case "edit":
        action = "update"
      case "toggle-mode":
        action = "mode"
      case "remove":
        action = "remove"
      case "move":
        action = "move"
      default:
        throw CursorCLICLIError.unsupportedAction("queue command", legacyAction)
      }
      return ParsedCommand(family: family, action: action, arguments: Array(arguments.dropFirst(3)))
    }
    let action = arguments[1]
    guard supportedCommands[family]?.contains(action) == true else {
      throw CursorCLICLIError.unsupportedAction(rawFamily, action)
    }
    return ParsedCommand(family: family, action: action, arguments: Array(arguments.dropFirst(2)))
  }

  public static func parseProcessOptions(_ arguments: [String]) -> CursorCLICLIProcessOptions {
    var options = CursorCLICLIProcessOptions()
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

  public static func formatSessionsJSON(_ sessions: [CursorCLISession]) throws -> String {
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
    "auth|activity|session|group|queue|bookmark|token|files|model|skill|daemon|server|usage|markdown|repo|version|graphql"
  }

  public static func stripRootOptions(_ arguments: [String]) throws -> [String] {
    var stripped: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--format" || argument == "-f" {
        guard index + 1 < arguments.count else {
          throw CursorCLIGraphQLError.missingFlagValue(argument)
        }
        let format = arguments[index + 1]
        guard format == "table" || format == "json" else {
          throw CursorCLICLIError.invalidFormat(format)
        }
        index += 2
        continue
      }
      if argument == "--json" {
        index += 1
        continue
      }
      stripped.append(argument)
      index += 1
    }
    return stripped
  }
}

public enum CursorCLICLIError: Error, Equatable {
  case unknownCommand(String)
  case missingAction(String)
  case unsupportedAction(String, String)
  case invalidFormat(String)
}

public final class CursorCLISessionWatchSubscription: @unchecked Sendable {
  private let lock = NSLock()
  private let watcher = CursorCLIRolloutWatcher()
  private var queued: [CursorCLIRolloutLine] = []
  private var cancelled = false

  public init(rolloutPath: String, startOffset: UInt64? = nil) {
    watcher.watchFile(path: rolloutPath, startOffset: startOffset)
  }

  public func next(timeout: TimeInterval? = nil) -> CursorCLIRolloutLine? {
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

  public func drainAvailable() -> [CursorCLIRolloutLine] {
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

  private func popQueued() -> CursorCLIRolloutLine? {
    lock.lock()
    defer { lock.unlock() }
    guard !queued.isEmpty else {
      return nil
    }
    return queued.removeFirst()
  }

  private func appendFlushedLines() {
    let lines = watcher.flush().compactMap { event -> CursorCLIRolloutLine? in
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

public enum CursorCLICLICommandExecutor {
  public struct Result: Equatable, Sendable {
    public var data: JSONValue?
    public var errors: [String]

    public init(data: JSONValue? = nil, errors: [String] = []) {
      self.data = data
      self.errors = errors
    }
  }

  public static func execute(arguments: [String], context: CursorCLIAgentCompatibilityContext = CursorCLIAgentCompatibilityContext()) -> Result {
    do {
      if arguments.first == "--version" || arguments.first == "-v" {
        return Result(data: .object(toolVersionsJSON(variables: ["includeGit": .bool(false)])))
      }
      let strippedArguments = try CursorCLICLICompatibility.stripRootOptions(arguments)
      let parsed = try CursorCLICLICompatibility.parseCommand(strippedArguments)
      if parsed.family == .auth {
        return executeAuthCommand(action: parsed.action ?? "status", arguments: parsed.arguments, context: context)
      }
      if parsed.family == .graphql {
        let graphQL = try parseGraphQLCLIArguments(parsed.arguments)
        let result = CursorCLIGraphQLCommandExecutor.execute(command: graphQL.document, variables: graphQL.variables, context: context)
        return Result(data: result.data, errors: result.errors)
      }
      let commandName = parsed.family == .version ? "version.get" : "\(parsed.family.rawValue).\(parsed.action ?? "")"
      let variables = try variablesForCLI(parsed)
      let result = CursorCLIGraphQLCommandExecutor.execute(command: commandName, variables: variables, context: context)
      return Result(data: result.data, errors: result.errors)
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }

  private static func executeAuthCommand(action: String, arguments: [String], context: CursorCLIAgentCompatibilityContext) -> Result {
    switch action {
    case "status", "verify":
      let account = try? CursorCLIConfigReader.account(path: cursorConfigPath(for: context))
      let readiness = cursorReadiness(context: context, model: action == "verify" ? CLIFlagArguments(arguments: arguments).value("--model") : nil)
      let loggedIn = boolValue(readiness["ready"]) ?? false
      var payload: JSONObject = [
        "loggedIn": .bool(loggedIn),
        "authenticated": .bool(loggedIn),
      ]
      for (key, value) in readiness {
        payload[key] = value
      }
      if let account {
        payload["account"] = .object([
          "accountUuid": .string(account.accountUuid),
          "emailAddress": .string(account.emailAddress),
          "displayName": .string(account.displayName),
          "organizationName": .string(account.organizationName),
        ])
      }
      if action == "status" {
        return Result(data: .object(payload))
      }
      guard loggedIn else {
        return Result(data: .object(payload), errors: ["cursor-cli-agent authentication is unavailable: credentials are missing or expired"])
      }
      return Result(data: .object(payload))
    case "info":
      let account = try? CursorCLIConfigReader.account(path: cursorConfigPath(for: context))
      guard let account else {
        return Result(errors: ["cursor-cli-agent authentication is unavailable: not logged in"])
      }
      return Result(data: .object([
        "account": .object([
          "accountUuid": .string(account.accountUuid),
          "emailAddress": .string(account.emailAddress),
          "displayName": .string(account.displayName),
          "organizationName": .string(account.organizationName),
        ])
      ]))
    case "token":
      let configDir = context.configDir ?? defaultCursorCLIAgentConfigDir()
      return Result(data: (try? jsonValue(CursorCLITokenPersistence.listMetadata(configDir: configDir))) ?? .array([]))
    default:
      return Result(errors: ["Unsupported auth action: \(action)"])
    }
  }

  private static func variablesForCLI(_ parsed: CursorCLICLICompatibility.ParsedCommand) throws -> JSONObject {
    let parameterArguments = parsed.arguments.filter(isKnownInlineParameter)
    var values = try CursorCLIGraphQLCommandExecutor.parseParams(parameterArguments)
    let flags = CLIFlagArguments(arguments: parsed.arguments.filter { !isKnownInlineParameter($0) })
    let positional = flags.positionals
    applyCommonLegacyFlags(flags, to: &values)
    switch (parsed.family, parsed.action) {
    case (.queue, "create"), (.group, "create"):
      if values["name"] == nil, let name = flags.value("--name") {
        values["name"] = .string(name)
      }
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
      if values["index"] == nil, positional.count > 1, let index = Int(positional[1]) { values["index"] = .number(Double(index)) }
      if values["commandId"] == nil, values["index"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["status"] == nil, let status = flags.value("--status") { values["status"] = .string(status) }
    case (.queue, "remove"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["index"] == nil, positional.count > 1, let index = Int(positional[1]) { values["index"] = .number(Double(index)) }
      if values["commandId"] == nil, values["index"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
    case (.queue, "mode"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["index"] == nil, positional.count > 1, let index = Int(positional[1]) { values["index"] = .number(Double(index)) }
      if values["commandId"] == nil, values["index"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
      if values["mode"] == nil, let mode = flags.value("--mode") { values["mode"] = .string(mode) }
      if values["mode"] == nil, positional.count > 2 { values["mode"] = .string(positional[2]) }
    case (.token, "create"):
      if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
      if values["permissions"] == nil, let permissions = flags.value("--permissions") { values["permissions"] = .string(permissions) }
      if values["expiresAt"] == nil, let expiresAt = flags.value("--expires-at") { values["expiresAt"] = .string(expiresAt) }
      if values["expiresIn"] == nil, let expiresIn = flags.value("--expires") { values["expiresIn"] = .string(expiresIn) }
    case (.group, "add"), (.group, "remove"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
    case (.group, "run"):
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["maxConcurrent"] == nil, let maxConcurrent = flags.value("--max-concurrent").flatMap(Int.init) {
        values["maxConcurrent"] = .number(Double(maxConcurrent))
      }
    case (.queue, _), (.group, _), (.bookmark, "get"), (.bookmark, "show"), (.bookmark, "content"), (.bookmark, "delete"), (.token, "revoke"), (.token, "rotate"):
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
        } else if let csvTags = flags.value("--tags") {
          values["tags"] = .array(csvTags.split(separator: ",").map { JSONValue.string($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter {
            if case let .string(text) = $0 {
              return !text.isEmpty
            }
            return false
          })
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
    case (.session, "show"), (.session, "get"), (.session, "messages"), (.session, "watch"):
      if values["id"] == nil, parsed.family == .session, let first = positional.first {
        values["id"] = .string(first)
      }
    case (.activity, "get"), (.activity, "status"):
      if values["sessionId"] == nil, let first = positional.first {
        values["sessionId"] = .string(first)
      }
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    case (.activity, "update"):
      if values["sessionId"] == nil, let first = positional.first {
        values["sessionId"] = .string(first)
      }
      if values["status"] == nil, positional.count > 1 {
        values["status"] = .string(positional[1])
      }
      if values["status"] == nil, let status = flags.value("--status") {
        values["status"] = .string(status)
      }
      if values["updatedAt"] == nil, let updatedAt = flags.value("--updated-at") {
        values["updatedAt"] = .string(updatedAt)
      }
      if values["projectPath"] == nil, let projectPath = flags.value("--project") ?? flags.value("--cwd") {
        values["projectPath"] = .string(projectPath)
      }
    case (.activity, "setup"):
      if values["global"] == nil, flags.has("--global") {
        values["global"] = .bool(true)
      }
      if values["project"] == nil, flags.has("--project") {
        values["project"] = .bool(true)
      }
      if values["dryRun"] == nil, flags.has("--dry-run") {
        values["dryRun"] = .bool(true)
      }
    case (.activity, "cleanup"):
      if values["olderThan"] == nil, let olderThan = flags.value("--older-than") ?? positional.first {
        values["olderThan"] = .string(olderThan)
      }
    case (.session, "create"):
      if values["prompt"] == nil, let prompt = flags.value("--prompt") {
        values["prompt"] = .string(prompt)
      }
      if values["prompt"] == nil {
        values["prompt"] = .string(positional.joined(separator: " "))
      }
    case (.session, "cancel"), (.session, "pause"):
      if values["id"] == nil, let first = positional.first {
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
    "approveMcps",
    "authToken",
    "branch",
    "caseSensitive",
    "cursorCLIBinary",
    "cursorCLIHome",
    "commandId",
    "configDir",
    "cwd",
    "description",
    "dryRun",
    "environment",
    "environmentVariables",
    "executableName",
    "expiresAt",
    "expiresIn",
    "from",
    "fromMessageId",
    "fullAuto",
    "force",
    "global",
    "gitBinary",
    "id",
    "imagePaths",
    "images",
    "includeGit",
    "index",
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
    "project",
    "projectPath",
    "prompt",
    "promptId",
    "position",
    "q",
    "query",
    "resultExitCode",
    "role",
    "sandbox",
    "sessionId",
    "sessionMode",
    "source",
    "startOffset",
    "status",
    "streamGranularity",
    "streamPartialOutput",
    "systemPrompt",
    "tag",
    "tags",
    "timeoutMs",
    "token",
    "to",
    "toIndex",
    "toMessageId",
    "trust",
    "type",
    "worktree",
    "worktreeBase",
    "yolo",
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
      ("--session-mode", "sessionMode"),
      ("--stream-granularity", "streamGranularity"),
      ("--source", "source"),
      ("--cwd", "cwd"),
      ("--branch", "branch"),
      ("--role", "role"),
      ("--cursor-binary", "cursorBinary"),
      ("--cursorCLI-binary", "cursorCLIBinary"),
      ("--executable-name", "executableName"),
      ("--worktree", "worktree"),
      ("--worktree-base", "worktreeBase"),
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
    if values["trust"] == nil, flags.has("--trust") {
      values["trust"] = .bool(true)
    }
    if values["force"] == nil, flags.has("--force") {
      values["force"] = .bool(true)
    }
    if values["yolo"] == nil, flags.has("--yolo") {
      values["yolo"] = .bool(true)
    }
    if values["streamPartialOutput"] == nil, flags.has("--stream-partial-output") {
      values["streamPartialOutput"] = .bool(true)
    }
    if values["approveMcps"] == nil, flags.has("--approve-mcps") {
      values["approveMcps"] = .bool(true)
    }
    if values["worktree"] == nil, flags.has("--worktree") {
      values["worktree"] = .string(flags.value("--worktree") ?? "true")
    }
    if values["skipWorktreeSetup"] == nil, flags.has("--skip-worktree-setup") {
      values["skipWorktreeSetup"] = .bool(true)
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
      "--worktree",
      "--worktree-base",
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
      "--cursor-binary",
      "--cursorCLI-binary",
      "--executable-name",
      "--from",
      "--to",
      "--mode",
      "--status",
      "--name",
      "--permissions",
      "--session-mode",
      "--expires-at",
      "--expires",
      "--updated-at",
      "--older-than",
      "--max-concurrent",
      "--model",
      "--format",
      "--char-delay-ms",
      "--type",
      "--session",
      "--session-id",
      "--message",
      "--message-id",
      "--description",
      "--tags",
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
          if Self.valueFlags.contains(argument), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
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
      throw CursorCLIGraphQLError.missingDocument
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
          throw CursorCLIGraphQLError.missingFlagValue(argument)
        }
        let loaded = try CursorCLIGraphQLCommandExecutor.loadVariablesSource(arguments[index])
        for (key, value) in loaded {
          variables[key] = value
        }
      case "--param", "--arg":
        index += 1
        guard index < arguments.count else {
          throw CursorCLIGraphQLError.missingFlagValue(argument)
        }
        variables["param"] = try CursorCLIGraphQLCommandExecutor.loadJSONSource(arguments[index])
      default:
        if argument.contains("=") {
          inlineParams.append(argument)
        } else {
          throw CursorCLIGraphQLError.invalidParam(argument)
        }
      }
      index += 1
    }
    if !inlineParams.isEmpty {
      for (key, value) in try CursorCLIGraphQLCommandExecutor.parseParams(inlineParams) {
        if variables["param"] == nil {
          variables[key] = value
        } else if case var .object(paramObject)? = variables["param"] {
          paramObject[key] = value
          variables["param"] = .object(paramObject)
        }
      }
    }
    return GraphQLCLIArguments(document: CursorCLIGraphQLCommandExecutor.normalizeDocument(document), variables: variables)
  }
}

public struct CursorCLIAgentCLIApplicationResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public enum CursorCLIAgentCLIApplication {
  public static func runActivityHookUpdate(
    stdin: Data,
    context: CursorCLIAgentCompatibilityContext = CursorCLIAgentCompatibilityContext()
  ) -> CursorCLIAgentCLIApplicationResult {
    do {
      guard !stdin.isEmpty,
        let payload = try JSONSerialization.jsonObject(with: stdin) as? [String: Any]
      else {
        return CursorCLIAgentCLIApplicationResult(exitCode: 0)
      }
      guard let sessionId = stringValue(payload["session_id"]) ?? stringValue(payload["sessionId"]), !sessionId.isEmpty else {
        return CursorCLIAgentCLIApplicationResult(exitCode: 0)
      }
      let hookEventName = stringValue(payload["hook_event_name"]) ?? stringValue(payload["hookEventName"]) ?? ""
      let transcriptPath = stringValue(payload["transcript_path"]) ?? stringValue(payload["transcriptPath"])
      let transcriptTail = transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
      let entry = CursorCLIStoredActivityEntry(
        sessionId: sessionId,
        status: CursorCLIActivityAnalyzer.status(hookEventName: hookEventName, transcriptTail: transcriptTail),
        updatedAt: isoString(Date()),
        projectPath: stringValue(payload["cwd"]) ?? stringValue(payload["projectPath"])
      )
      let store = CursorCLIActivityStore(dataDir: context.configDir ?? CursorCLIActivityStore.defaultDataDir())
      try store.mutate { entries in
        if let index = entries.firstIndex(where: { $0.sessionId == sessionId }) {
          entries[index] = entry
        } else {
          entries.append(entry)
        }
      }
    } catch {
      return CursorCLIAgentCLIApplicationResult(exitCode: 0)
    }
    return CursorCLIAgentCLIApplicationResult(exitCode: 0)
  }

  public static func run(
    arguments: [String],
    context: CursorCLIAgentCompatibilityContext = CursorCLIAgentCompatibilityContext()
  ) -> CursorCLIAgentCLIApplicationResult {
    let result = CursorCLICLICommandExecutor.execute(arguments: arguments, context: context)
    if !result.errors.isEmpty {
      let exitCode: Int32 = result.errors.contains { $0.contains("invalidFormat") || $0.contains("Invalid format") } ? 2 : 1
      return CursorCLIAgentCLIApplicationResult(
        stderr: encodeCLIJSON(.object(["errors": .array(result.errors.map(JSONValue.string))])),
        exitCode: exitCode
      )
    }
    if requestedFormat(arguments) == "table", let text = legacyTableOutput(arguments: arguments, value: result.data ?? .null) {
      return CursorCLIAgentCLIApplicationResult(stdout: text, exitCode: 0)
    }
    return CursorCLIAgentCLIApplicationResult(stdout: encodeCLIJSON(result.data ?? .null), exitCode: 0)
  }

  private static func requestedFormat(_ arguments: [String]) -> String {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--json" {
        return "json"
      }
      if (argument == "--format" || argument == "-f"), index + 1 < arguments.count {
        return arguments[index + 1] == "json" ? "json" : "table"
      }
      index += 1
    }
    return "table"
  }

  private static func legacyTableOutput(arguments: [String], value: JSONValue) -> String? {
    let stripped = (try? CursorCLICLICompatibility.stripRootOptions(arguments)) ?? arguments
    guard let family = stripped.first else {
      return nil
    }
    let action = stripped.dropFirst().first
    switch (family, action) {
    case ("version", _):
      guard let object = try? jsonObjectValue(value) else {
        return nil
      }
      let version = stringValue(object["version"]) ?? "unknown"
      let cursor = (try? jsonObjectValue(object["cursorCLI"] ?? .null)).flatMap { stringValue($0["version"]) } ?? "unavailable"
      let git = (try? jsonObjectValue(object["git"] ?? .null)).flatMap { stringValue($0["version"]) } ?? "unavailable"
      return "Tool\tversion\nagent\t\(version)\ncursor\t\(cursor)\ngit\t\(git)\n"
    case ("queue", "list"), ("group", "list"):
      guard case let .array(items) = value else {
        return nil
      }
      let rows = items.compactMap { try? jsonObjectValue($0) }.map { object in
        "\(stringValue(object["id"]) ?? "")\t\(stringValue(object["name"]) ?? "")"
      }
      return "ID\tName\n" + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    case ("queue", "show"), ("queue", "get"), ("group", "show"), ("group", "get"):
      guard let object = try? jsonObjectValue(value) else {
        return nil
      }
      return "ID\tName\n\(stringValue(object["id"]) ?? "")\t\(stringValue(object["name"]) ?? "")\n"
    default:
      return nil
    }
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

public enum CursorCLIGraphQLCommandExecutor {
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
    "session.list", "session.show", "session.get", "session.messages", "session.search", "session.searchTranscript", "session.run", "session.create", "session.cancel", "session.pause", "session.resume", "session.fork", "session.watch",
    "activity.list", "activity.get", "activity.status", "activity.update", "activity.cleanup", "activity.setup",
    "group.create", "group.list", "group.show", "group.get", "group.watch", "group.add", "group.addSession", "group.remove", "group.removeSession", "group.pause", "group.resume", "group.delete", "group.run",
    "queue.create", "queue.add", "queue.addCommand", "queue.show", "queue.get", "queue.list", "queue.pause", "queue.resume", "queue.stop", "queue.delete", "queue.update", "queue.updateCommand", "queue.remove", "queue.removeCommand", "queue.move", "queue.mode", "queue.run",
    "bookmark.add", "bookmark.list", "bookmark.get", "bookmark.show", "bookmark.content", "bookmark.delete", "bookmark.search",
    "token.create", "token.list", "token.revoke", "token.rotate",
    "files.list", "files.patches", "files.find", "files.rebuild",
    "model.check",
    "skill.list", "skill.show",
    "daemon.status", "daemon.start", "daemon.stop", "daemon.restart",
    "server.status", "server.events",
    "usage.list", "usage.stats", "usage.summary",
    "markdown.tasks", "markdown.parse",
    "repo.status", "repo.files", "repo.analytics", "repo.summary",
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

  private static func canonicalCommandName(_ commandName: String) -> String {
    switch commandName {
    case "queue.addCommand":
      return "queue.add"
    case "queue.updateCommand":
      return "queue.update"
    case "queue.removeCommand":
      return "queue.remove"
    case "group.addSession":
      return "group.add"
    case "group.removeSession":
      return "group.remove"
    case "group.watch":
      return "group.show"
    case "group.get":
      return "group.show"
    case "queue.get":
      return "queue.show"
    case "bookmark.show":
      return "bookmark.get"
    case "session.get":
      return "session.show"
    case "activity.status":
      return "activity.get"
    default:
      return commandName
    }
  }

  public static func parseVariables(_ text: String?) throws -> JSONObject {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return [:]
    }
    let data = Data(text.utf8)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case let .object(object) = decoded else {
      throw CursorCLIGraphQLError.variablesMustBeObject
    }
    return object
  }

  public static func parseParams(_ values: [String]) throws -> JSONObject {
    var params: JSONObject = [:]
    for value in values {
      let pieces = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard pieces.count == 2 else {
        throw CursorCLIGraphQLError.invalidParam(value)
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
      throw CursorCLIGraphQLError.variablesMustBeObject
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

  public static func watchSession(id: String, startOffset: UInt64? = nil, cursorCLIHome: String? = nil) throws -> CursorCLISessionWatchSubscription {
    guard let session = findSession(id: id, cursorCLIHome: cursorCLIHome) else {
      throw CursorCLIGraphQLError.missingVariable("Session not found")
    }
    return CursorCLISessionWatchSubscription(rolloutPath: session.rolloutPath, startOffset: startOffset)
  }

  public static func execute(command: String, variables: JSONObject = [:], context: CursorCLIAgentCompatibilityContext = CursorCLIAgentCompatibilityContext()) -> Result {
    let normalized = normalizeDocument(command)
    if isPingDocument(normalized) {
      return Result(data: .object(["ping": .bool(true)]))
    }
    if let typedResult = executeTypedSessionGraphQLDocument(normalized, variables: variables, context: context) {
      return typedResult
    }
    let legacyInvocation = extractLegacyCommandInvocation(from: normalized, variables: variables)
    let effectiveVariables = legacyInvocation.variables
    guard var commandName = legacyInvocation.commandName ?? extractCommandName(from: normalized) else {
      return Result(errors: ["Unable to extract command name"])
    }
    commandName = canonicalCommandName(commandName)
    if normalized.hasPrefix("subscription"), commandName != "session.watch" {
      return Result(errors: ["Unsupported subscription command: \(commandName)"])
    }
    guard supportedCommandNames.contains(commandName) else {
      return Result(errors: ["Unknown command: \(commandName)"])
    }
    do {
      let explicitConfigDir = stringValue(effectiveVariables["configDir"]) ?? context.configDir
      let configDir = explicitConfigDir ?? defaultCursorCLIAgentConfigDir()
      let dataDir = explicitConfigDir ?? defaultCursorCLIAgentDataDir()
      let activityDataDir = explicitConfigDir ?? CursorCLIActivityStore.defaultDataDir()
      let cursorCLIHome = stringValue(effectiveVariables["cursorCLIHome"]) ?? context.cursorCLIHome
      let authToken = stringValue(effectiveVariables["authToken"]) ?? stringValue(effectiveVariables["token"]) ?? context.authToken
      if let authError = try authorizationError(commandName: commandName, rawToken: authToken, configDir: configDir) {
        return Result(errors: [authError])
      }
      switch commandName {
      case "version.get":
        return Result(data: .object(toolVersionsJSON(variables: effectiveVariables)))
      case "model.check":
        let model = try requiredString(effectiveVariables, "model")
        var options = try processOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        options.model = model
        if options.additionalArguments.isEmpty {
          options.additionalArguments = ["--skip-git-repo-check", "--ephemeral"]
        }
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let result = manager.spawnExec(prompt: stringValue(effectiveVariables["prompt"]) ?? "Reply with exactly OK.", options: options)
        return Result(data: .object([
          "model": .string(model),
          "ok": .bool(result.result.exitCode == 0),
          "exitCode": .number(Double(result.result.exitCode)),
          "stdout": .string(result.result.stdout),
          "stderr": .string(result.result.stderr),
        ]))
      case "session.list":
        let options = sessionListOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let result = CursorCLISessionIndex.listSessions(options: options)
        return Result(data: .array(result.sessions.map(sessionJSON)))
      case "session.show":
        let id = try requiredString(effectiveVariables, "id")
        guard let session = CursorCLISessionCommands.show(sessionId: id, cursorCLIHome: cursorCLIHome) else {
          return Result(errors: ["Session not found"])
        }
        return Result(data: sessionJSON(session))
      case "session.messages":
        let id = try requiredString(effectiveVariables, "id", fallback: "sessionId")
        guard let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome) else {
          return Result(errors: ["Session not found"])
        }
        let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
        return Result(data: .object([
          "sessionId": .string(session.id),
          "messages": .array(lines.map(rolloutLineJSON)),
        ]))
      case "session.search", "session.searchTranscript":
        let query = try requiredString(effectiveVariables, "query")
        if commandName == "session.searchTranscript", let id = stringValue(effectiveVariables["id"]) {
          guard let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome) else {
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
          let search = try CursorCLISessionIndex.searchSessionTranscriptDetailed(session: session, query: query, options: transcriptSearchOptions(from: effectiveVariables))
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
        let result = try CursorCLISessionIndex.searchSessions(query: query, options: sessionListOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome), searchOptions: transcriptSearchOptions(from: effectiveVariables))
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
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let result = manager.spawnExec(prompt: prompt, options: options)
        return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
      case "session.create":
        let prompt = try requiredNonBlankString(effectiveVariables, "prompt")
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let result = manager.spawnExec(prompt: prompt, options: options)
        return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
      case "session.resume":
        let id = try requiredString(effectiveVariables, "id")
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let result = manager.spawnResume(sessionId: id, prompt: stringValue(effectiveVariables["prompt"]), options: options)
        return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
      case "session.cancel", "session.pause":
        let id = try requiredString(effectiveVariables, "id")
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let killed = manager.kill(id: id)
        return Result(data: .object([
          "id": .string(id),
          "success": .bool(killed),
          "ok": .bool(killed),
          "status": .string(killed ? "cancelled" : "not_found"),
          "degraded": .bool(!killed),
          "limitation": .string("process control is available only for active processes owned by this Swift runtime"),
        ]))
      case "session.fork":
        let id = try requiredString(effectiveVariables, "id")
        let manager = CursorCLIProcessManager(executableName: executableName(from: effectiveVariables))
        let options = try processOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let process = manager.spawnForkProcess(sessionId: id, nthMessage: intValue(effectiveVariables["nthMessage"]), options: options)
        return Result(data: .object(processHandleJSON(process)))
      case "session.watch":
        let id = try requiredString(effectiveVariables, "id")
        let subscription = try watchSession(id: id, startOffset: nonNegativeUInt64Value(effectiveVariables["startOffset"]) ?? 0, cursorCLIHome: cursorCLIHome)
        let lines = subscription.drainAvailable()
        subscription.cancel()
        return Result(data: .object(["events": .array(lines.map(rolloutLineJSON))]))

      case "activity.list":
        let store = CursorCLIActivityStore(dataDir: activityDataDir)
        var entries = try store.load()
        if let status = stringValue(effectiveVariables["status"]).flatMap(CursorCLIActivityStatusValue.init(rawValue:)) {
          entries = entries.filter { $0.status == status }
        }
        return Result(data: .object(["entries": .array(entries.map(activityEntryJSON))]))
      case "activity.get":
        let id = try requiredString(effectiveVariables, "sessionId", fallback: "id")
        guard let entry = try CursorCLIActivityStore(dataDir: activityDataDir).load().first(where: { $0.sessionId == id }) else {
          return Result(errors: ["Activity not found"])
        }
        return Result(data: activityEntryJSON(entry))
      case "activity.update":
        let sessionId = try requiredString(effectiveVariables, "sessionId", fallback: "id")
        guard let status = CursorCLIActivityStatusValue(rawValue: try requiredString(effectiveVariables, "status")) else {
          return Result(errors: ["Invalid activity status"])
        }
        let store = CursorCLIActivityStore(dataDir: activityDataDir)
        let entry = CursorCLIStoredActivityEntry(
          sessionId: sessionId,
          status: status,
          updatedAt: stringValue(effectiveVariables["updatedAt"]) ?? isoString(Date()),
          projectPath: stringValue(effectiveVariables["projectPath"]) ?? stringValue(effectiveVariables["cwd"])
        )
        try store.mutate { entries in
          if let index = entries.firstIndex(where: { $0.sessionId == sessionId }) {
            entries[index] = entry
          } else {
            entries.append(entry)
          }
        }
        return Result(data: activityEntryJSON(entry))
      case "activity.cleanup":
        guard let cutoff = activityCleanupCutoff(from: stringValue(effectiveVariables["olderThan"])) else {
          return Result(errors: ["Invalid cleanup cutoff"])
        }
        let retained = try CursorCLIActivityStore(dataDir: activityDataDir).cleanup(olderThan: cutoff)
        return Result(data: .object(["entries": .array(retained.map(activityEntryJSON))]))
      case "activity.setup":
        return Result(data: .object(try activitySetupJSON(variables: effectiveVariables)))

      case "group.create":
        return Result(data: try jsonValue(CursorCLIGroupPersistence.createGroup(name: try requiredString(effectiveVariables, "name"), description: stringValue(effectiveVariables["description"]), configDir: dataDir)))
      case "group.list":
        return Result(data: try jsonValue(CursorCLIGroupPersistence.listGroups(configDir: dataDir)))
      case "group.show":
        guard let group = try CursorCLIGroupPersistence.findGroup(try requiredString(effectiveVariables, "id"), configDir: dataDir) else {
          return Result(errors: ["Group not found"])
        }
        return Result(data: try jsonValue(group))
      case "group.add":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: dataDir)
        let ok = try CursorCLIGroupPersistence.addSession(groupId: groupId, session: try groupSession(from: effectiveVariables), configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
      case "group.remove":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: dataDir)
        let ok = try CursorCLIGroupPersistence.removeSession(groupId: groupId, sessionId: try requiredString(effectiveVariables, "sessionId"), configDir: dataDir)
        return ok ? Result(data: .object(["ok": .bool(true), "success": .bool(true), "id": .string(groupId)])) : Result(errors: ["Group session not found"])
      case "group.pause":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: dataDir)
        let ok = try CursorCLIGroupPersistence.setPaused(groupId: groupId, paused: true, configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
      case "group.resume":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: dataDir)
        let ok = try CursorCLIGroupPersistence.setPaused(groupId: groupId, paused: false, configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
      case "group.delete":
        let groupId = try resolveExistingGroupId(try requiredString(effectiveVariables, "id"), configDir: dataDir)
        let ok = try CursorCLIGroupPersistence.deleteGroup(id: groupId, configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
      case "group.run":
        guard let group = try CursorCLIGroupPersistence.findGroup(try requiredString(effectiveVariables, "id"), configDir: dataDir) else {
          return Result(errors: ["Group not found"])
        }
        return Result(data: try .array(runGroupEvents(group: group, prompt: try requiredString(effectiveVariables, "prompt"), variables: effectiveVariables, cursorCLIHome: cursorCLIHome).map(JSONValue.object)))

      case "queue.create":
        let projectPath = try requiredString(effectiveVariables, "projectPath")
        let name = stringValue(effectiveVariables["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = URL(fileURLWithPath: projectPath).lastPathComponent
        let resolvedName = (name?.isEmpty == false ? name : nil) ?? (fallbackName.isEmpty ? projectPath : fallbackName)
        return Result(data: try jsonValue(CursorCLIQueuePersistence.createQueue(name: resolvedName, projectPath: projectPath, configDir: dataDir)))
      case "queue.add":
        let images = stringArray(effectiveVariables["images"]).isEmpty ? stringArray(effectiveVariables["imagePaths"]) : stringArray(effectiveVariables["images"])
        return Result(data: try jsonValue(addQueuePromptLegacy(variables: effectiveVariables, imagePaths: images, configDir: dataDir)))
      case "queue.show":
        guard let queue = try CursorCLIQueuePersistence.findQueue(try requiredString(effectiveVariables, "id"), configDir: dataDir) else {
          return Result(errors: ["Queue not found"])
        }
        return Result(data: try jsonValue(queue))
      case "queue.list":
        var queues = try CursorCLIQueuePersistence.listQueues(configDir: dataDir)
        if let projectPath = stringValue(effectiveVariables["projectPath"]) {
          queues = queues.filter { $0.projectPath == projectPath }
        }
        if let rawStatus = stringValue(effectiveVariables["status"]), let status = CursorCLIQueueStatus(rawValue: rawStatus) {
          queues = queues.filter { $0.status == status }
        }
        return Result(data: try jsonValue(queues))
      case "queue.delete":
        let ok = try CursorCLIQueuePersistence.removeQueue(resolveExistingQueueId(try requiredString(effectiveVariables, "id"), configDir: dataDir), configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
      case "queue.pause", "queue.resume", "queue.stop", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run":
        return executeQueueMutation(commandName: commandName, variables: effectiveVariables, configDir: dataDir, cursorCLIHome: cursorCLIHome)

      case "bookmark.add":
        guard let type = inferredBookmarkType(from: effectiveVariables) else {
          return Result(errors: ["Invalid bookmark type"])
        }
        return Result(data: try jsonValue(CursorCLIBookmarkPersistence.addBookmark(type: type, sessionId: try requiredString(effectiveVariables, "sessionId"), messageId: stringValue(effectiveVariables["messageId"]), name: stringValue(effectiveVariables["name"]), description: stringValue(effectiveVariables["description"]) ?? stringValue(effectiveVariables["text"]), tags: stringArray(effectiveVariables["tags"]), fromMessageId: stringValue(effectiveVariables["fromMessageId"]), toMessageId: stringValue(effectiveVariables["toMessageId"]), configDir: dataDir)))
      case "bookmark.list":
        return Result(data: try jsonValue(CursorCLIBookmarkPersistence.listBookmarks(sessionId: stringValue(effectiveVariables["sessionId"]), type: stringValue(effectiveVariables["type"]).flatMap(CursorCLIBookmarkType.init(rawValue:)), tag: stringValue(effectiveVariables["tag"]), configDir: dataDir)))
      case "bookmark.get":
        guard let bookmark = try CursorCLIBookmarkPersistence.getBookmark(id: try requiredString(effectiveVariables, "id"), configDir: dataDir) else {
          return Result(errors: ["Bookmark not found"])
        }
        return Result(data: try jsonValue(bookmark))
      case "bookmark.content":
        guard let bookmark = try CursorCLIBookmarkPersistence.getBookmark(id: try requiredString(effectiveVariables, "id"), configDir: dataDir) else {
          return Result(errors: ["Bookmark not found"])
        }
        return Result(data: try bookmarkContentJSON(bookmark, cursorCLIHome: cursorCLIHome))
      case "bookmark.delete":
        let ok = try CursorCLIBookmarkPersistence.deleteBookmark(id: try requiredString(effectiveVariables, "id"), configDir: dataDir)
        return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
      case "bookmark.search":
        let limit = max(0, intValue(effectiveVariables["limit"]) ?? 50)
        let scored = try CursorCLIBookmarkPersistence.searchBookmarkResults(try requiredString(effectiveVariables, "query", fallback: "q"), limit: limit, configDir: dataDir)
        return Result(data: .array(scored.map { result in
          .object([
            "bookmark": try! jsonValue(result.bookmark),
            "score": .number(result.score),
          ])
        }))

      case "token.create":
        let name = try requiredString(effectiveVariables, "name")
        let permissionValues = stringArray(effectiveVariables["permissions"])
        let permissions = permissionValues.isEmpty ? CursorCLITokenManager.parsePermissionsCSV(stringValue(effectiveVariables["permissions"]) ?? "session:read,session:create") : CursorCLITokenManager.normalizePermissions(permissionValues)
        guard !permissions.isEmpty else {
          return Result(errors: ["No valid permissions provided"])
        }
        let rawToken = try CursorCLITokenPersistence.createRawToken(name: name, permissions: permissions, expiresAt: try tokenExpiresAt(from: effectiveVariables), configDir: configDir)
        return Result(data: .string(rawToken))
      case "token.list":
        return Result(data: try jsonValue(CursorCLITokenPersistence.listMetadata(configDir: configDir)))
      case "token.revoke":
        return Result(data: .bool(try CursorCLITokenPersistence.revoke(id: try requiredString(effectiveVariables, "id"), configDir: configDir)))
      case "token.rotate":
        guard let token = try CursorCLITokenPersistence.rotate(id: try requiredString(effectiveVariables, "id"), configDir: configDir) else {
          return Result(errors: ["Token not found"])
        }
        return Result(data: .string(token))

      case "files.rebuild":
        return Result(data: .object(try rebuildPersistentFileIndex(configDir: dataDir, cursorCLIHome: cursorCLIHome)))
      case "files.list":
        let sessionId = try requiredString(effectiveVariables, "sessionId")
        guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome) else {
          return Result(errors: ["session not found: \(sessionId)"])
        }
        return Result(data: .object(try fileChangeSummaryJSON(for: session)))
      case "files.patches":
        let sessionId = try requiredString(effectiveVariables, "sessionId")
        guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome) else {
          return Result(errors: ["session not found: \(sessionId)"])
        }
        return Result(data: .object(try filePatchHistoryJSON(for: session)))
      case "files.find":
        return Result(data: .object(try findPersistentSessionsByFile(path: try requiredString(effectiveVariables, "path"), configDir: dataDir, cursorCLIHome: cursorCLIHome)))
      case "usage.list", "usage.stats", "usage.summary":
        let sessionsDir = URL(fileURLWithPath: cursorCLIHome ?? resolveCursorCLIHome(), isDirectory: true)
          .appendingPathComponent("sessions", isDirectory: true)
          .path
        let stats = CursorCLIUsageStatsCollector.getCursorCLIUsageStats(options: CursorCLIUsageStatsOptions(cursorCLISessionsDir: sessionsDir, recentDays: intValue(effectiveVariables["recentDays"]) ?? CursorCLIUsageStatsCollector.defaultRecentDays))
        return Result(data: stats.map { try! jsonValue($0) } ?? .null)
      case "markdown.tasks":
        let text = stringValue(effectiveVariables["markdown"]) ?? stringValue(effectiveVariables["text"]) ?? ""
        return Result(data: try jsonValue(CursorCLIMarkdown.parseTasks(text)))
      case "markdown.parse":
        let text = stringValue(effectiveVariables["markdown"]) ?? stringValue(effectiveVariables["text"]) ?? ""
        return Result(data: try jsonValue(CursorCLIMarkdown.parseSections(text)))
      case "repo.status", "repo.summary", "repo.analytics":
        let options = sessionListOptions(from: effectiveVariables, cursorCLIHome: cursorCLIHome)
        let sessions = CursorCLISessionIndex.listSessions(options: options).sessions
        return Result(data: .object([
          "sessions": .number(Double(sessions.count)),
          "projectPath": stringValue(effectiveVariables["projectPath"]).map(JSONValue.string) ?? .null,
          "branch": stringValue(effectiveVariables["branch"]).map(JSONValue.string) ?? .null,
        ]))
      case "repo.files":
        return Result(data: .object(try rebuildPersistentFileIndex(configDir: dataDir, cursorCLIHome: cursorCLIHome)))
      case "skill.list":
        return Result(data: .object([
          "skills": .array([]),
          "status": .string("degraded"),
          "message": .string("Cursor-managed skills are discoverable only when Cursor exposes them locally."),
        ]))
      case "skill.show":
        return Result(errors: ["Skill not found"])
      case "daemon.status", "daemon.start", "daemon.stop", "daemon.restart":
        return Result(data: .object([
          "running": .bool(false),
          "status": .string("unsupported"),
          "message": .string("Cursor daemon supervision is not available in the Swift runtime."),
        ]))
      case "server.status":
        return Result(data: .object([
          "ok": .bool(true),
          "runtime": .string("swift"),
          "agent": .string("cursor-cli-agent"),
        ]))
      case "server.events":
        return Result(data: .object(["events": .array([])]))
      default:
        return Result(errors: ["Unhandled command: \(commandName)"])
      }
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }
}

public enum CursorCLIGraphQLError: Error, Equatable {
  case missingDocument
  case missingFlagValue(String)
  case variablesMustBeObject
  case invalidParam(String)
  case missingVariable(String)
}

private func executeQueueMutation(commandName: String, variables: JSONObject, configDir: String, cursorCLIHome: String?) -> CursorCLIGraphQLCommandExecutor.Result {
  do {
    var config = try CursorCLIQueuePersistence.load(configDir: configDir)
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(config.queues)
    let requestedId = try requiredString(variables, "id")
    guard let requestedQueue = repository.findQueue(requestedId) else {
      return CursorCLIGraphQLCommandExecutor.Result(errors: ["Queue not found"])
    }
    let id = requestedQueue.id
    let ok: Bool
    switch commandName {
    case "queue.pause":
      ok = repository.pauseQueue(id: id)
    case "queue.resume":
      ok = repository.resumeQueue(id: id)
    case "queue.stop":
      ok = repository.stopQueue(id: id)
    case "queue.update":
      let commandId = try resolveQueuePromptId(variables: variables, queue: requestedQueue)
      let status: CursorCLIQueuePromptStatus?
      if let rawStatus = stringValue(variables["status"]) {
        guard let parsedStatus = CursorCLIQueuePromptStatus(rawValue: rawStatus) else {
          return CursorCLIGraphQLCommandExecutor.Result(errors: ["status must be one of: pending, running, completed, failed"])
        }
        status = parsedStatus
      } else {
        status = nil
      }
      let mode = (stringValue(variables["sessionMode"]) ?? stringValue(variables["mode"])).flatMap(CursorCLIQueueCommandMode.legacy)
      ok = repository.updatePrompt(queueId: id, promptId: commandId, prompt: stringValue(variables["prompt"]), status: status, mode: mode, resultExitCode: intValue(variables["resultExitCode"]))
    case "queue.remove":
      ok = repository.removePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue))
    case "queue.move":
      if let from = intValue(variables["from"]), let to = intValue(variables["to"]) {
        ok = repository.movePrompt(queueId: id, from: from, to: to)
      } else {
        ok = repository.movePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue), toIndex: intValue(variables["toIndex"]) ?? 0)
      }
    case "queue.mode":
      if let rawMode = stringValue(variables["mode"]) {
        guard let mode = CursorCLIQueueCommandMode.legacy(rawMode) else {
          return CursorCLIGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
        }
        if let commandId = try? resolveQueuePromptId(variables: variables, queue: requestedQueue) {
          ok = repository.updatePrompt(queueId: id, promptId: commandId, mode: mode)
        } else {
          ok = repository.setMode(queueId: id, mode: mode)
        }
      } else if let commandId = try? resolveQueuePromptId(variables: variables, queue: requestedQueue), let current = requestedQueue.prompts.first(where: { $0.id == commandId }) {
        let currentMode = current.mode ?? .continueMode
        let toggled: CursorCLIQueueCommandMode = currentMode == .new ? .continueMode : .new
        ok = repository.updatePrompt(queueId: id, promptId: commandId, mode: toggled)
      } else {
        return CursorCLIGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
      }
    case "queue.run":
      let executableName = executableName(from: variables)
      let manager = CursorCLIProcessManager(executableName: executableName)
      var events: [JSONObject] = []
      guard let queueIndex = config.queues.firstIndex(where: { $0.id == id }) else {
        return CursorCLIGraphQLCommandExecutor.Result(errors: ["Queue not found"])
      }
      let queueProjectPath = config.queues[queueIndex].projectPath
      if config.queues[queueIndex].status == .paused || config.queues[queueIndex].status == .stopped || config.queues[queueIndex].paused {
        let pending = config.queues[queueIndex].prompts.filter { $0.status == .pending }.map(\.id)
        return CursorCLIGraphQLCommandExecutor.Result(data: .array([.object(queueEvent(type: "queue_stopped", queueId: id, pending: pending))]))
      }
      guard config.queues[queueIndex].status == .pending else {
        return CursorCLIGraphQLCommandExecutor.Result(errors: ["Queue is not runnable"])
      }
      let startedAt = isoString(Date())
      config.queues[queueIndex].status = .running
      config.queues[queueIndex].paused = false
      config.queues[queueIndex].startedAt = config.queues[queueIndex].startedAt ?? startedAt
      config.queues[queueIndex].updatedAt = startedAt
      try CursorCLIQueuePersistence.save(config, configDir: configDir)

      var completed: [String] = []
      var failed: [String] = []
      var skipped: [String] = []
      while let promptIndex = config.queues[queueIndex].prompts.firstIndex(where: { $0.status == .pending }) {
        let prompt = config.queues[queueIndex].prompts[promptIndex]
        var pendingIds = config.queues[queueIndex].prompts.filter { $0.status == .pending && $0.id != prompt.id }.map(\.id)
        let promptStartedAt = isoString(Date())
        config.queues[queueIndex].currentIndex = promptIndex
        config.queues[queueIndex].prompts[promptIndex].status = .running
        config.queues[queueIndex].prompts[promptIndex].startedAt = promptStartedAt
        config.queues[queueIndex].prompts[promptIndex].updatedAt = promptStartedAt
        config.queues[queueIndex].updatedAt = promptStartedAt
        try CursorCLIQueuePersistence.save(config, configDir: configDir)
        pendingIds.removeAll { $0 == prompt.id }
        events.append(queueEvent(type: "prompt_started", queueId: id, promptId: prompt.id, current: prompt.id, pending: pendingIds))
        var options = try processOptions(from: variables, cursorCLIHome: cursorCLIHome)
        options.cwd = queueProjectPath
        options.images = Array(Set(prompt.imagePaths + options.images)).sorted()
        let shouldResume = (prompt.mode ?? .continueMode) != .new && config.queues[queueIndex].currentSessionId != nil
        let execution = shouldResume
          ? manager.spawnResume(sessionId: config.queues[queueIndex].currentSessionId!, prompt: prompt.prompt, options: options)
          : manager.spawnExec(prompt: prompt.prompt, options: options)
        let result = execution.result
        let lines = result.stdout.split(separator: "\n").compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
        let sessionId = extractSessionId(from: lines) ?? config.queues[queueIndex].currentSessionId ?? execution.process.id
        let completedAt = isoString(Date())
        config.queues[queueIndex].prompts[promptIndex].sessionId = sessionId
        config.queues[queueIndex].prompts[promptIndex].resultExitCode = Int(result.exitCode)
        config.queues[queueIndex].prompts[promptIndex].completedAt = completedAt
        config.queues[queueIndex].prompts[promptIndex].updatedAt = completedAt
        config.queues[queueIndex].updatedAt = completedAt
        if result.exitCode == 0 {
          config.queues[queueIndex].prompts[promptIndex].status = .completed
          config.queues[queueIndex].currentSessionId = sessionId
          completed.append(prompt.id)
          events.append(queueEvent(type: "prompt_completed", queueId: id, promptId: prompt.id, exitCode: Int(result.exitCode), pending: pendingIds))
        } else {
          config.queues[queueIndex].prompts[promptIndex].status = .failed
          config.queues[queueIndex].prompts[promptIndex].error = result.stderr.isEmpty ? nil : result.stderr
          config.queues[queueIndex].status = .failed
          config.queues[queueIndex].completedAt = completedAt
          failed.append(prompt.id)
          events.append(queueEvent(type: "prompt_failed", queueId: id, promptId: prompt.id, exitCode: Int(result.exitCode), pending: pendingIds))
          for index in config.queues[queueIndex].prompts.indices where config.queues[queueIndex].prompts[index].status == .pending {
            config.queues[queueIndex].prompts[index].status = .skipped
            config.queues[queueIndex].prompts[index].updatedAt = completedAt
            skipped.append(config.queues[queueIndex].prompts[index].id)
          }
          try CursorCLIQueuePersistence.save(config, configDir: configDir)
          events.append(queueEvent(type: "queue_failed", queueId: id, completed: completed, pending: [], failed: failed + skipped))
          return CursorCLIGraphQLCommandExecutor.Result(data: .array(events.map(JSONValue.object)))
        }
        try CursorCLIQueuePersistence.save(config, configDir: configDir)
      }
      let finishedAt = isoString(Date())
      config.queues[queueIndex].status = .completed
      config.queues[queueIndex].completedAt = finishedAt
      config.queues[queueIndex].updatedAt = finishedAt
      events.append(queueEvent(type: "queue_completed", queueId: id, completed: completed, pending: [], failed: failed))
      try CursorCLIQueuePersistence.save(config, configDir: configDir)
      return CursorCLIGraphQLCommandExecutor.Result(data: .array(events.map(JSONValue.object)))
    default:
      return CursorCLIGraphQLCommandExecutor.Result(errors: ["Unhandled queue mutation: \(commandName)"])
    }
    guard ok else {
      return CursorCLIGraphQLCommandExecutor.Result(errors: ["Queue command not found"])
    }
    config.queues = repository.listQueues()
    try CursorCLIQueuePersistence.save(config, configDir: configDir)
    return CursorCLIGraphQLCommandExecutor.Result(data: .object(["ok": .bool(ok), "success": .bool(ok)]))
  } catch {
    return CursorCLIGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

private func addQueuePromptLegacy(variables: JSONObject, imagePaths: [String], configDir: String) throws -> CursorCLIQueuePrompt {
  var config = try CursorCLIQueuePersistence.load(configDir: configDir)
  let idOrName = try requiredString(variables, "id")
  guard let queueIndex = config.queues.firstIndex(where: { $0.id == idOrName || $0.name == idOrName }) else {
    throw CursorCLIGraphQLError.missingVariable("Queue not found")
  }
  guard config.queues[queueIndex].status == .pending || config.queues[queueIndex].status == .paused else {
    throw CursorCLIGraphQLError.missingVariable("Queue is not editable")
  }
  let mode = stringValue(variables["sessionMode"]) ?? stringValue(variables["mode"])
  let item = CursorCLIQueuePrompt(
    id: UUID().uuidString,
    prompt: try requiredString(variables, "prompt"),
    status: .pending,
    mode: mode.flatMap(CursorCLIQueueCommandMode.legacy) ?? .continueMode,
    imagePaths: imagePaths,
    createdAt: ISO8601DateFormatter().string(from: Date())
  )
  let insertionIndex: Int
  if let position = intValue(variables["position"]) {
    insertionIndex = min(max(position, 0), config.queues[queueIndex].prompts.count)
  } else {
    insertionIndex = config.queues[queueIndex].prompts.count
  }
  config.queues[queueIndex].prompts.insert(item, at: insertionIndex)
  try CursorCLIQueuePersistence.save(config, configDir: configDir)
  return item
}

private func resolveQueuePromptId(variables: JSONObject, queue: CursorCLIQueue) throws -> String {
  if let commandId = stringValue(variables["commandId"]) ?? stringValue(variables["promptId"]) {
    return commandId
  }
  if let index = intValue(variables["index"]), queue.prompts.indices.contains(index) {
    return queue.prompts[index].id
  }
  throw CursorCLIGraphQLError.missingVariable("commandId")
}

private func runGroupEvents(group: CursorCLIGroup, prompt: String, variables: JSONObject, cursorCLIHome: String?) throws -> [JSONObject] {
  guard !group.paused else {
    throw CursorCLIGraphQLError.missingVariable("group is paused: \(group.id)")
  }
  var events: [JSONObject] = []
  var completed: [String] = []
  var failed: [String] = []
  var pending = group.sessionIds
  var running: [String] = []
  let maxConcurrent = max(1, intValue(variables["maxConcurrent"]) ?? 3)
  let executableName = executableName(from: variables)
  let options = try processOptions(from: variables, cursorCLIHome: cursorCLIHome)
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
        let manager = CursorCLIProcessManager(executableName: executableName)
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

private func sessionListOptions(from variables: JSONObject, cursorCLIHome: String?) -> CursorCLISessionListOptions {
  CursorCLISessionListOptions(
    cursorCLIHome: cursorCLIHome,
    source: stringValue(variables["source"]).flatMap(CursorCLISessionSource.init(rawValue:)),
    cwd: stringValue(variables["cwd"]) ?? stringValue(variables["projectPath"]),
    branch: stringValue(variables["branch"]),
    limit: intValue(variables["limit"]) ?? 50,
    offset: intValue(variables["offset"]) ?? 0,
    sortBy: stringValue(variables["sortBy"]) ?? "createdAt",
    sortOrder: stringValue(variables["sortOrder"]) ?? "desc"
  )
}

private func transcriptSearchOptions(from variables: JSONObject) -> CursorCLISessionTranscriptSearchOptions {
  CursorCLISessionTranscriptSearchOptions(
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

private func rebuildFileIndex(cursorCLIHome: String?) throws -> CursorCLIFileChangeIndex {
  let lines = discoverRolloutPaths(cursorCLIHome: cursorCLIHome).flatMap { path in
    (try? CursorCLIRolloutReader.readRollout(path: path)) ?? []
  }
  return CursorCLIFileChangeIndex.rebuild(from: lines)
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

private func rebuildPersistentFileIndex(configDir: String, cursorCLIHome: String?) throws -> JSONObject {
  let indexedAt = ISO8601DateFormatter().string(from: Date())
  let entries = discoverRolloutPaths(cursorCLIHome: cursorCLIHome).compactMap { path -> PersistentSessionFileIndexEntry? in
    guard let lines = try? CursorCLIRolloutReader.readRollout(path: path) else {
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

private func findPersistentSessionsByFile(path: String, configDir: String, cursorCLIHome: String?) throws -> JSONObject {
  let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !target.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable("path")
  }
  let url = persistentFileIndexURL(configDir: configDir)
  if !FileManager.default.isReadableFile(atPath: url.path) {
    _ = try rebuildPersistentFileIndex(configDir: configDir, cursorCLIHome: cursorCLIHome)
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

private func rolloutSessionId(lines: [CursorCLIRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = fileChangeObject(line.payload), let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

private func changedFilesSummary(from lines: [CursorCLIRolloutLine]) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for line in lines {
    for change in CursorCLIFileChanges.extract(from: line) {
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

private func changedFilesSummary(changes: [CursorCLIFileChange], timestamp: String) -> [PersistentChangedFile] {
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

private func fileChangeIndex(for session: CursorCLISession) throws -> CursorCLIFileChangeIndex {
  let index = try CursorCLIFileChangeIndex.rebuild(from: CursorCLIRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return CursorCLIFileChangeIndex(changes: parseRawPatchFileChanges(raw))
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

private func fileChangeSummaryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count)),
  ]
}

private func filePatchHistoryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
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

private func fileChangeDetails(from lines: [CursorCLIRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    CursorCLIFileChanges.extract(from: line).map { change in
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

private func parseRawPatchFileChanges(_ text: String) -> [CursorCLIFileChange] {
  text.split(separator: "\n").compactMap { rawLine in
    let line = String(rawLine)
    if let range = line.range(of: "*** Add File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .created, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Delete File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .deleted, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Update File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .modified, source: .applyPatch, patch: text)
    }
    return nil
  }
}

private func sessionJSON(_ session: CursorCLISession) -> JSONValue {
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

private func activityEntryJSON(_ entry: CursorCLIStoredActivityEntry) -> JSONValue {
  var object: JSONObject = [
    "sessionId": .string(entry.sessionId),
    "status": .string(entry.status.rawValue),
    "updatedAt": .string(entry.updatedAt),
    "lastUpdated": .string(entry.updatedAt),
  ]
  if let projectPath = entry.projectPath {
    object["projectPath"] = .string(projectPath)
  }
  return .object(object)
}

private let activityHookEvents = ["UserPromptSubmit", "PermissionRequest", "Stop"]
private let activityHookCommand = "cursor-cli-agent activity update"

private func activityCleanupCutoff(from text: String?) -> Date? {
  guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return Date().addingTimeInterval(-24 * 60 * 60)
  }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if let hours = Double(trimmed), hours >= 0 {
    return Date().addingTimeInterval(-hours * 60 * 60)
  }
  return parseLegacyTimestamp(trimmed)
}

private func activitySetupJSON(variables: JSONObject) throws -> JSONObject {
  let settingsURL = activitySettingsURL(variables: variables)
  let dryRun = boolValue(variables["dryRun"]) ?? false
  var settings = try readActivitySettingsObject(from: settingsURL)
  var hooks = settings["hooks"] as? [String: Any] ?? [:]
  for event in activityHookEvents {
    var entries = hooks[event] as? [Any] ?? []
    if !activityHookEntries(entries, containCommand: activityHookCommand) {
      entries.append([
        "matcher": "",
        "hooks": [
          [
            "type": "command",
            "command": activityHookCommand,
          ],
        ],
      ])
    }
    hooks[event] = entries
  }
  settings["hooks"] = hooks
  if !dryRun {
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL, options: .atomic)
  }
  return [
    "ok": .bool(true),
    "dryRun": .bool(dryRun),
    "settingsPath": .string(settingsURL.path),
    "hooks": .array(activityHookEvents.map(JSONValue.string)),
    "settings": try jsonValue(fromFoundation: settings),
  ]
}

private func activitySettingsURL(variables: JSONObject) -> URL {
  if boolValue(variables["global"]) == true {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".cursor", isDirectory: true)
      .appendingPathComponent("settings.json")
  }
  let projectPath = stringValue(variables["projectPath"]) ?? stringValue(variables["cwd"]) ?? FileManager.default.currentDirectoryPath
  return URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".cursor", isDirectory: true)
    .appendingPathComponent("settings.json")
}

private func readActivitySettingsObject(from url: URL) throws -> [String: Any] {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return [:]
  }
  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw CursorCLIGraphQLError.invalidParam("settings.json must contain a JSON object")
  }
  return object
}

private func activityHookEntries(_ entries: [Any], containCommand command: String) -> Bool {
  entries.contains { entry in
    guard let object = entry as? [String: Any], let hooks = object["hooks"] as? [Any] else {
      return false
    }
    return hooks.contains { hook in
      guard let hookObject = hook as? [String: Any] else {
        return false
      }
      return hookObject["type"] as? String == "command" && hookObject["command"] as? String == command
    }
  }
}

private func bookmarkContentJSON(_ bookmark: CursorCLIBookmark, cursorCLIHome: String?) throws -> JSONValue {
  var object = try jsonObjectValue(jsonValue(bookmark))
  object["bookmark"] = try jsonValue(bookmark)
  object["content"] = .string(bookmark.text ?? bookmark.description ?? bookmark.name ?? "")
  if let session = CursorCLISessionIndex.findSession(id: bookmark.sessionId, cursorCLIHome: cursorCLIHome) {
    object["session"] = sessionJSON(session)
  }
  return .object(object)
}

private func inferredBookmarkType(from variables: JSONObject) -> CursorCLIBookmarkType? {
  if let rawType = stringValue(variables["type"]) {
    return CursorCLIBookmarkType(rawValue: rawType)
  }
  if stringValue(variables["messageId"]) != nil {
    return .message
  }
  if stringValue(variables["fromMessageId"]) != nil, stringValue(variables["toMessageId"]) != nil {
    return .range
  }
  return .session
}

private func jsonObjectValue(_ value: JSONValue) throws -> JSONObject {
  guard case let .object(object) = value else {
    throw CursorCLIGraphQLError.invalidParam("object")
  }
  return object
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

private func extractLegacyCommandInvocation(from document: String, variables: JSONObject) -> (commandName: String?, variables: JSONObject) {
  guard document.contains("command(") else {
    return (nil, variables)
  }
  let commandName = extractGraphQLStringArgument(named: "name", from: document, variables: variables)
  if
    let variableName = firstRegexCapture(in: document, pattern: #"\bparams\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#),
    case let .object(params)? = variables[variableName]
  {
    return (commandName, params)
  }
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

private func executeTypedSessionGraphQLDocument(_ document: String, variables: JSONObject, context: CursorCLIAgentCompatibilityContext) -> CursorCLIGraphQLCommandExecutor.Result? {
  guard document.contains("sessions") || document.contains("session(") || document.contains("searchSessions") else {
    return nil
  }
  guard !document.contains("command(") else {
    return nil
  }
  let explicitConfigDir = stringValue(variables["configDir"]) ?? context.configDir
  let configDir = explicitConfigDir ?? defaultCursorCLIAgentConfigDir()
  let cursorCLIHome = stringValue(variables["cursorCLIHome"]) ?? context.cursorCLIHome
  let authToken = stringValue(variables["authToken"]) ?? stringValue(variables["token"]) ?? context.authToken
  do {
    if let authError = try authorizationError(commandName: "session.list", rawToken: authToken, configDir: configDir) {
      return CursorCLIGraphQLCommandExecutor.Result(errors: [authError])
    }
    if document.contains("searchSessions") {
      let args = graphQLArguments(field: "searchSessions", document: document, variables: variables)
      let query = stringValue(args["query"]) ?? ""
      let listOptions = CursorCLISessionListOptions(
        cursorCLIHome: cursorCLIHome,
        source: stringValue(args["source"]).flatMap { source in
          switch source.lowercased() {
          case "uuid", "cli":
            return .cli
          case "vscode":
            return .vscode
          case "exec":
            return .exec
          default:
            return CursorCLISessionSource(rawValue: source.lowercased())
          }
        },
        cwd: stringValue(args["projectPath"]) ?? stringValue(args["cwd"]),
        branch: stringValue(args["branch"]),
        limit: Int.max,
        offset: 0,
        sortBy: "createdAt",
        sortOrder: "desc"
      )
      let searchOptions = CursorCLISessionTranscriptSearchOptions(
        caseSensitive: boolValue(args["caseSensitive"]) ?? false,
        role: stringValue(args["role"])?.lowercased() ?? "both",
        maxBytes: intValue(args["maxBytes"]),
        maxEvents: nil,
        maxSessions: intValue(args["maxSessions"]),
        timeoutMs: intValue(args["timeoutMs"]),
        limit: intValue(args["limit"]) ?? 50,
        offset: intValue(args["offset"]) ?? 0
      )
      let result = try CursorCLISessionIndex.searchSessions(query: query, options: listOptions, searchOptions: searchOptions)
      return CursorCLIGraphQLCommandExecutor.Result(data: .object([
        "searchSessions": .object([
          "sessionIds": .array(result.sessionIds.map(JSONValue.string)),
          "total": .number(Double(result.total)),
          "offset": .number(Double(result.offset)),
          "limit": .number(Double(result.limit)),
          "scannedSessions": .number(Double(result.scannedSessions)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut),
        ])
      ]))
    }
    if document.contains("session(") {
      let args = graphQLArguments(field: "session", document: document, variables: variables)
      guard let id = stringValue(args["id"]), let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome) else {
        return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .null]))
      }
      var sessionObject = typedSessionJSON(session)
      if document.contains("history") {
        sessionObject["history"] = typedSessionHistoryJSON(session: session, args: graphQLArguments(field: "history", document: document, variables: variables))
      }
      if document.contains("grep") {
        let grepArgs = graphQLArguments(field: "grep", document: document, variables: variables)
        let query = stringValue(grepArgs["query"]) ?? ""
        let searchOptions = CursorCLISessionTranscriptSearchOptions(
          caseSensitive: boolValue(grepArgs["caseSensitive"]) ?? false,
          role: stringValue(grepArgs["role"])?.lowercased() ?? "both",
          maxBytes: intValue(grepArgs["maxBytes"]),
          timeoutMs: intValue(grepArgs["timeoutMs"]),
          limit: intValue(grepArgs["maxMatches"]) ?? 50
        )
        let result = try CursorCLISessionIndex.searchSessionTranscriptDetailed(session: session, query: query, options: searchOptions)
        sessionObject["grep"] = .object([
          "sessionId": .string(session.id),
          "matched": .bool(result.matched),
          "matchCount": .number(Double(result.matchCount)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedLines": .number(Double(result.scannedEvents)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut),
        ])
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .object(sessionObject)]))
    }
    if document.contains("sessions") {
      let args = graphQLArguments(field: "sessions", document: document, variables: variables)
      let options = sessionListOptions(from: args, cursorCLIHome: cursorCLIHome)
      var sessions = CursorCLISessionIndex.listSessions(options: options).sessions
      if let status = stringValue(args["status"]), status != "completed" {
        sessions = []
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object([
        "sessions": .object([
          "total": .number(Double(sessions.count)),
          "nodes": .array(sessions.map { .object(typedSessionJSON($0)) }),
        ])
      ]))
    }
    return nil
  } catch {
    return CursorCLIGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

private func typedSessionJSON(_ session: CursorCLISession) -> JSONObject {
  [
    "id": .string(session.id),
    "projectPath": .string(session.cwd),
    "cwd": .string(session.cwd),
    "status": .string("completed"),
    "createdAt": .string(isoString(session.createdAt)),
    "updatedAt": .string(isoString(session.updatedAt)),
    "messageCount": .number(Double((try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath).count) ?? 0)),
  ]
}

private func typedSessionHistoryJSON(session: CursorCLISession, args: JSONObject) -> JSONValue {
  let offset = max(0, intValue(args["offset"]) ?? 0)
  let limit = max(0, intValue(args["limit"]) ?? 50)
  let messages = (try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath)) ?? []
  let start = min(offset, messages.count)
  let end = min(start + limit, messages.count)
  let events = messages[start..<end].map { message -> JSONValue in
    .object([
      "type": .string(message.role),
      "uuid": .null,
      "timestamp": .string(message.timestamp),
      "content": message.text.map(JSONValue.string) ?? .null,
      "raw": message.line.payload,
    ])
  }
  return .object([
    "total": .number(Double(messages.count)),
    "offset": .number(Double(offset)),
    "limit": .number(Double(limit)),
    "events": .array(Array(events)),
    "tokenUsage": .object(["input": .number(0), "output": .number(0)]),
  ])
}

private func graphQLArguments(field: String, document: String, variables: JSONObject) -> JSONObject {
  let escapedField = NSRegularExpression.escapedPattern(for: field)
  guard let argumentText = firstRegexCapture(in: document, pattern: #"\b"# + escapedField + #"\s*\(([^)]*)\)"#) else {
    return [:]
  }
  var result: JSONObject = [:]
  let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*("[^"]*"|\$[A-Za-z_][A-Za-z0-9_]*|-?[0-9]+|true|false|[A-Za-z_][A-Za-z0-9_]*)"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return result
  }
  let nsRange = NSRange(argumentText.startIndex..<argumentText.endIndex, in: argumentText)
  for match in regex.matches(in: argumentText, range: nsRange) {
    guard
      let nameRange = Range(match.range(at: 1), in: argumentText),
      let valueRange = Range(match.range(at: 2), in: argumentText)
    else {
      continue
    }
    let name = String(argumentText[nameRange])
    let rawValue = String(argumentText[valueRange])
    if rawValue.hasPrefix("$") {
      result[name] = variables[String(rawValue.dropFirst())] ?? .null
    } else if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
      result[name] = .string(String(rawValue.dropFirst().dropLast()))
    } else if rawValue == "true" || rawValue == "false" {
      result[name] = .bool(rawValue == "true")
    } else if let intValue = Int(rawValue) {
      result[name] = .number(Double(intValue))
    } else {
      result[name] = .string(rawValue.lowercased())
    }
  }
  return result
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

private func rolloutLineJSON(_ line: CursorCLIRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload,
  ])
}

private func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let cursorCLI = probeToolVersion(executableName(from: variables), arguments: ["--version"])
  let includeGit = boolValue(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "cursorCLI": .object(cursorCLI),
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

private func processExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
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

private func processHandleJSON(_ process: CursorCLIProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string)),
  ]
}

private func sessionExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

private func extractSessionId(from lines: [CursorCLIRolloutLine]) -> String? {
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

private func jsonValue(fromFoundation value: Any) throws -> JSONValue {
  let data = try JSONSerialization.data(withJSONObject: value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func requiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = stringValue(object[key]), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
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
  throw CursorCLIGraphQLError.missingVariable(key)
}

private func requiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = stringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
  }
  return value
}

private func tokenExpiresAt(from object: JSONObject) throws -> String? {
  if let expiresAt = stringValue(object["expiresAt"]), !expiresAt.isEmpty {
    return expiresAt
  }
  guard let expiresIn = stringValue(object["expiresIn"]) ?? stringValue(object["expires"]) else {
    return nil
  }
  do {
    let seconds = try CursorCLIDurationParser.seconds(expiresIn)
    return legacyTokenTimestamp(Date().addingTimeInterval(TimeInterval(seconds)))
  } catch {
    throw CursorCLIGraphQLError.invalidParam("--expires=\(expiresIn)")
  }
}

private func legacyTokenTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

private func parseLegacyTimestamp(_ text: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: text) {
    return date
  }
  return ISO8601DateFormatter().date(from: text)
}

private func resolveQueueId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

private func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw CursorCLIGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

private func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

private func groupSession(from variables: JSONObject) throws -> CursorCLIGroupSession {
  if let sessionObject = objectValue(variables["session"]) {
    return CursorCLIGroupSession(
      id: try requiredString(sessionObject, "id"),
      projectPath: stringValue(sessionObject["projectPath"]),
      prompt: stringValue(sessionObject["prompt"]),
      status: stringValue(sessionObject["status"]),
      dependsOn: stringArray(sessionObject["dependsOn"]),
      createdAt: stringValue(sessionObject["createdAt"])
    )
  }
  return CursorCLIGroupSession(
    id: try requiredString(variables, "sessionId"),
    projectPath: stringValue(variables["projectPath"]),
    prompt: stringValue(variables["prompt"]),
    status: stringValue(variables["status"]),
    dependsOn: stringArray(variables["dependsOn"]),
    createdAt: stringValue(variables["createdAt"])
  )
}

private func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
  guard let group = try CursorCLIGroupPersistence.findGroup(idOrName, configDir: configDir) else {
    throw CursorCLIGraphQLError.missingVariable("Group not found")
  }
  return group.id
}

func defaultCursorCLIAgentConfigDir() -> String {
  if let override = ProcessInfo.processInfo.environment["CURSOR_CLI_AGENT_CONFIG_DIR"], !override.isEmpty {
    return expandHomePath(override)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cursor-cli-agent", isDirectory: true).path
}

func defaultCursorCLIAgentDataDir() -> String {
  if let override = ProcessInfo.processInfo.environment["CURSOR_CLI_AGENT_DATA_DIR"], !override.isEmpty {
    return expandHomePath(override)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/cursor-cli-agent", isDirectory: true).path
}

private func expandHomePath(_ path: String) -> String {
  if path == "~" {
    return FileManager.default.homeDirectoryForCurrentUser.path
  }
  if path.hasPrefix("~/") {
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
  }
  return path
}

private func cursorConfigPath(for context: CursorCLIAgentCompatibilityContext) -> String? {
  guard let cursorCLIHome = context.cursorCLIHome else {
    return nil
  }
  return URL(fileURLWithPath: cursorCLIHome, isDirectory: true)
    .appendingPathComponent("account.json")
    .path
}

private func cursorCredentialsPath(for context: CursorCLIAgentCompatibilityContext) -> String {
  let home = context.cursorCLIHome ?? resolveCursorCLIHome()
  return URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("credentials.json")
    .path
}

private func cursorReadiness(context: CursorCLIAgentCompatibilityContext, model: String?) -> JSONObject {
  let credentialsPath = cursorCredentialsPath(for: context)
  let credentials = readCursorCredentials(path: credentialsPath)
  let hasEnvToken = !(ProcessInfo.processInfo.environment["CURSOR_API_KEY"] ?? "").isEmpty || !(ProcessInfo.processInfo.environment["CURSOR_AUTH_TOKEN"] ?? "").isEmpty
  let now = Date()
  let state: String
  let available: Bool
  let message: String
  if hasEnvToken {
    available = true
    state = "configured"
    message = "Cursor API credentials are configured in the environment."
  } else if let credentials {
    available = credentials.expiresAt > now
    state = available ? "configured" : "expired"
    message = available ? "Stored credentials are configured." : "Stored credentials are expired."
  } else {
    available = false
    state = "missing"
    message = "No Cursor API credentials were found."
  }
  var auth: JSONObject = [
    "state": .string(state),
    "available": .bool(available),
    "storageLocation": .string(credentialsPath),
    "message": .string(message),
  ]
  if let credentials {
    auth["expiresAt"] = .string(isoString(credentials.expiresAt))
    auth["subscriptionType"] = credentials.subscriptionType.map(JSONValue.string) ?? .null
    auth["scopes"] = .array(credentials.scopes.map(JSONValue.string))
    auth["rateLimitTier"] = credentials.rateLimitTier.map(JSONValue.string) ?? .null
  }
  return [
    "ready": .bool(available),
    "auth": .object(auth),
    "cli": .object([
      "checked": .bool(false),
      "available": .bool(false),
      "command": .string("cursor-agent"),
    ]),
    "model": .object([
      "requested": model.map(JSONValue.string) ?? .null,
      "checked": .bool(false),
      "available": .bool(false),
      "timedOut": .bool(false),
      "stdout": .string(""),
      "stderr": .string(""),
      "commandArgs": .array(model.map { ["--print", "--model", $0] }?.map(JSONValue.string) ?? []),
      "message": .string(model != nil && !available ? "Skipping model probe because credentials are unavailable." : ""),
    ]),
  ]
}

private struct CursorCredentialsReadiness {
  var expiresAt: Date
  var subscriptionType: String?
  var scopes: [String]
  var rateLimitTier: String?
}

private func readCursorCredentials(path: String) -> CursorCredentialsReadiness? {
  guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value,
    let oauth = objectValue(object["cursorOauth"]),
    let expiresMs = numberValue(oauth["expiresAt"])
  else {
    return nil
  }
  return CursorCredentialsReadiness(
    expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
    subscriptionType: stringValue(oauth["subscriptionType"]),
    scopes: stringArray(oauth["scopes"]),
    rateLimitTier: stringValue(oauth["rateLimitTier"])
  )
}

private func authorizationError(commandName: String, rawToken: String?, configDir: String) throws -> String? {
  if commandName.hasPrefix("token."), let rawToken, !rawToken.isEmpty {
    return "Token management commands are not available in token-authenticated GraphQL contexts"
  }
  guard let rawToken, !rawToken.isEmpty, let permission = requiredPermission(for: commandName) else {
    return nil
  }
  guard try CursorCLITokenPersistence.verify(rawToken: rawToken, permission: permission, configDir: configDir) != nil else {
    return "Missing permission: \(permission)"
  }
  return nil
}

private func requiredPermission(for commandName: String) -> String? {
  switch commandName {
  case "session.run", "session.fork", "session.create", "session.pause", "session.resume":
    return "session:create"
  case "session.cancel":
    return "session:cancel"
  case let command where command.hasPrefix("session.") || command.hasPrefix("activity."):
    return "session:read"
  case "group.run":
    return "group:run"
  case let command where command.hasPrefix("group."):
    return "group:*"
  case let command where command.hasPrefix("queue."):
    return "queue:*"
  case let command where command.hasPrefix("bookmark."):
    return "bookmark:*"
  case let command where command.hasPrefix("files."):
    return "files:*"
  case let command where command.hasPrefix("skill.") || command.hasPrefix("server.") || command.hasPrefix("daemon."):
    return "server:read"
  default:
    return nil
  }
}

public enum CursorCLIMarkdown {
  public struct Section: Equatable, Codable, Sendable {
    public var level: Int
    public var heading: String
    public var body: String
  }

  public struct Task: Equatable, Codable, Sendable {
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

public enum CursorCLIFileChangeSource: String, Equatable, Codable, Sendable {
  case applyPatch = "apply_patch"
  case shell
  case execCommand = "exec_command"
  case localShell = "local_shell"
}

public enum CursorCLIFileOperation: String, Equatable, Codable, Sendable {
  case created
  case modified
  case deleted
  case moved
}

public struct CursorCLIFileChange: Equatable, Codable, Sendable {
  public var path: String
  public var operation: CursorCLIFileOperation
  public var source: CursorCLIFileChangeSource
  public var previousPath: String?
  public var command: String?
  public var patch: String?

  public init(path: String, operation: CursorCLIFileOperation, source: CursorCLIFileChangeSource, previousPath: String? = nil, command: String? = nil, patch: String? = nil) {
    self.path = path
    self.operation = operation
    self.source = source
    self.previousPath = previousPath
    self.command = command
    self.patch = patch
  }
}

public enum CursorCLIFileChanges {
  public static func extract(from lines: [CursorCLIRolloutLine]) -> [CursorCLIFileChange] {
    var pending: [String: [CursorCLIFileChange]] = [:]
    var changes: [CursorCLIFileChange] = []
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

  public static func extract(from line: CursorCLIRolloutLine) -> [CursorCLIFileChange] {
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

private func extractDirectChanges(from payload: JSONObject) -> [CursorCLIFileChange] {
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

private func commandLikeFileChanges(payload: JSONObject) -> [CursorCLIFileChange]? {
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

private func parsePatchFileChanges(_ patch: String) -> [CursorCLIFileChange] {
  var pendingUpdatePath: String?
  var pendingUpdateIndex: Int?
  var changes: [CursorCLIFileChange] = []
  for rawLine in patch.split(separator: "\n") {
    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("*** Add File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CursorCLIFileChange(path: String(line.dropFirst("*** Add File: ".count)), operation: .created, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Delete File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CursorCLIFileChange(path: String(line.dropFirst("*** Delete File: ".count)), operation: .deleted, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Update File: ") {
      pendingUpdatePath = String(line.dropFirst("*** Update File: ".count))
      pendingUpdateIndex = changes.count
      changes.append(CursorCLIFileChange(path: pendingUpdatePath ?? "", operation: .modified, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Move to: "), let from = pendingUpdatePath {
      let to = String(line.dropFirst("*** Move to: ".count))
      if let pendingUpdateIndex {
        changes[pendingUpdateIndex] = CursorCLIFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch)
      } else {
        changes.append(CursorCLIFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch))
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

private func parseShellFileChanges(_ command: String) -> [CursorCLIFileChange] {
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
  var changes: [CursorCLIFileChange] = []
  let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
  guard !tokens.isEmpty else {
    return []
  }
  if tokens.prefix(2) == ["git", "mv"], tokens.count >= 4 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[3]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[2])))
  } else if tokens.prefix(2) == ["git", "rm"], tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .deleted, source: .shell))
  } else if tokens[0] == "mv", tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[1])))
  } else if tokens[0] == "cp", tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .created, source: .shell))
  } else if tokens[0] == "rm", tokens.count >= 2 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[1]), operation: .deleted, source: .shell))
  } else if tokens[0] == "touch", tokens.count >= 2 {
    for path in tokens.dropFirst() {
      changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: .created, source: .shell))
    }
  } else if ["sed", "perl"].contains(tokens[0]), tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), let path = tokens.last {
    changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: .modified, source: .shell))
  } else if tokens[0] == "tee", tokens.count >= 2 {
    let paths = tokens.dropFirst().filter { !$0.hasPrefix("-") && $0 != ">" && $0 != ">>" }
    for path in paths {
      changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: tokens.contains("-a") ? .modified : .created, source: .shell))
    }
  }
  for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[index + 1]), operation: token == ">" ? .created : .modified, source: .shell))
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

public struct CursorCLIFileChangeIndex: Equatable, Sendable {
  private var changes: [CursorCLIFileChange] = []

  public init(changes: [CursorCLIFileChange] = []) {
    self.changes = changes
  }

  public static func rebuild(from lines: [CursorCLIRolloutLine]) -> CursorCLIFileChangeIndex {
    CursorCLIFileChangeIndex(changes: CursorCLIFileChanges.extract(from: lines))
  }

  public func listChangedFiles() -> [String] {
    Array(Set(changes.flatMap { change in
      [change.path, change.previousPath].compactMap { $0 }
    })).sorted()
  }

  public func patches(for path: String) -> [CursorCLIFileChange] {
    changes.filter { $0.path == path || $0.previousPath == path }
  }

  public func find(_ path: String) -> CursorCLIFileChange? {
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

private func fileChangeArray(_ value: JSONValue?) -> [CursorCLIFileChange]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap { entry in
    guard let object = fileChangeObject(entry), let path = fileChangeString(object["path"]) else {
      return nil
    }
    return CursorCLIFileChange(
      path: path,
      operation: CursorCLIFileOperation(rawValue: fileChangeString(object["operation"]) ?? "") ?? .modified,
      source: CursorCLIFileChangeSource(rawValue: fileChangeString(object["source"]) ?? "") ?? .shell,
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

private func stringValue(_ value: Any?) -> String? {
  value as? String
}

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
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

private func processOptions(from object: JSONObject, cursorCLIHome defaultCursorCLIHome: String? = nil) throws -> CursorCLIProcessOptions {
  if let sandbox = stringValue(object["sandbox"]) {
    try validateStringUnion(sandbox, key: "sandbox", allowed: ["enabled", "disabled", "read-only", "workspace-write", "danger-full-access"])
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
  return CursorCLIProcessOptions(
    model: stringValue(object["model"]),
    cwd: stringValue(object["cwd"]),
    sandbox: stringValue(object["sandbox"]),
    approvalMode: stringValue(object["approvalMode"]),
    mode: stringValue(object["mode"]).flatMap(CursorCLIMode.init(rawValue:)),
    fullAuto: boolValue(object["fullAuto"]) ?? false,
    trust: boolValue(object["trust"]) ?? false,
    force: boolValue(object["force"]) ?? false,
    yolo: boolValue(object["yolo"]) ?? false,
    streamPartialOutput: boolValue(object["streamPartialOutput"]) ?? false,
    approveMcps: boolValue(object["approveMcps"]) ?? false,
    worktree: stringValue(object["worktree"]),
    worktreeBase: stringValue(object["worktreeBase"]),
    skipWorktreeSetup: boolValue(object["skipWorktreeSetup"]) ?? false,
    images: images.isEmpty ? imagePaths : images,
    configOverrides: try strictStringArray(object["configOverrides"], key: "configOverrides"),
    additionalArguments: additionalArguments.isEmpty ? additionalArgs : additionalArguments,
    environmentVariables: environment.isEmpty ? environmentVariables : environment,
    systemPrompt: stringValue(object["systemPrompt"]),
    cursorCLIHome: stringValue(object["cursorCLIHome"]) ?? defaultCursorCLIHome,
    streamGranularity: stringValue(object["streamGranularity"]),
    forwardApprovalMode: false
  )
}

private func validateStringUnion(_ value: String, key: String, allowed: Set<String>) throws {
  guard allowed.contains(value) else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
  }
}

private func strictStringArray(_ value: JSONValue?, key: String) throws -> [String] {
  guard let value else {
    return []
  }
  guard case let .array(values) = value else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be an array of strings")
  }
  return try values.enumerated().map { index, item in
    guard let string = stringValue(item) else {
      throw CursorCLIGraphQLError.invalidParam("\(key)[\(index)] must be a string")
    }
    return string
  }
}

private func executableName(from object: JSONObject) -> String {
  stringValue(object["executableName"]) ?? stringValue(object["cursorBinary"]) ?? stringValue(object["cursorCLIBinary"]) ?? "cursor-agent"
}

private func strictStringDictionary(_ value: JSONValue?, key: String) throws -> [String: String] {
  guard let value else {
    return [:]
  }
  guard case let .object(object) = value else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be an object with string values")
  }
  var result: [String: String] = [:]
  for (key, value) in object {
    guard let string = stringValue(value) else {
      throw CursorCLIGraphQLError.invalidParam("\(key) must be a string")
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
  if CursorCLIGraphQLCommandExecutor.supportedCommandNames.contains(trimmed) || trimmed.contains(".") {
    return trimmed
  }
  return nil
}
