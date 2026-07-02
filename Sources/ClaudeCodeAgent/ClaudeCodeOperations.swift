import Foundation
import RielaCore

public struct ClaudeCodeAgentCompatibilityContext: Equatable, Sendable {
  public var claudeCodeHome: String?
  public var configDir: String?
  public var authToken: String?

  public init(claudeCodeHome: String? = nil, configDir: String? = nil, authToken: String? = nil) {
    self.claudeCodeHome = claudeCodeHome
    self.configDir = configDir
    self.authToken = authToken
  }
}

public struct ClaudeCodeCLIProcessOptions: Equatable, Sendable {
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

public enum ClaudeCodeCLICompatibility {
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
    .version: [""],
    .graphql: [""]
  ]

  public static func parseCommand(_ arguments: [String]) throws -> ParsedCommand {
    let stripped = try stripRootOptions(arguments)
    guard let rawFamily = stripped.first, let family = CommandFamily(rawValue: rawFamily) else {
      throw ClaudeCodeCLIError.unknownCommand(stripped.first ?? "")
    }
    if family == .version || family == .graphql {
      return ParsedCommand(family: family, action: nil, arguments: Array(arguments.dropFirst()))
    }
    guard arguments.count >= 2 else {
      throw ClaudeCodeCLIError.missingAction(rawFamily)
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
        throw ClaudeCodeCLIError.unsupportedAction("queue command", legacyAction)
      }
      return ParsedCommand(family: family, action: action, arguments: Array(arguments.dropFirst(3)))
    }
    let action = arguments[1]
    guard supportedCommands[family]?.contains(action) == true else {
      throw ClaudeCodeCLIError.unsupportedAction(rawFamily, action)
    }
    return ParsedCommand(family: family, action: action, arguments: Array(arguments.dropFirst(2)))
  }

  public static func parseProcessOptions(_ arguments: [String]) -> ClaudeCodeCLIProcessOptions {
    var options = ClaudeCodeCLIProcessOptions()
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

  public static func formatSessionsJSON(_ sessions: [ClaudeCodeSession]) throws -> String {
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
    "auth|activity|session|group|queue|bookmark|token|files|model|version|graphql"
  }

  public static func stripRootOptions(_ arguments: [String]) throws -> [String] {
    var stripped: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--format" || argument == "-f" {
        guard index + 1 < arguments.count else {
          throw ClaudeCodeGraphQLError.missingFlagValue(argument)
        }
        let format = arguments[index + 1]
        guard format == "table" || format == "json" else {
          throw ClaudeCodeCLIError.invalidFormat(format)
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

public enum ClaudeCodeCLIError: Error, Equatable {
  case unknownCommand(String)
  case missingAction(String)
  case unsupportedAction(String, String)
  case invalidFormat(String)
}

public final class ClaudeCodeSessionWatchSubscription: @unchecked Sendable {
  private let lock = NSLock()
  private let watcher = ClaudeCodeRolloutWatcher()
  private var queued: [ClaudeCodeRolloutLine] = []
  private var cancelled = false

  public init(rolloutPath: String, startOffset: UInt64? = nil) {
    watcher.watchFile(path: rolloutPath, startOffset: startOffset)
  }

  public func next(timeout: TimeInterval? = nil) -> ClaudeCodeRolloutLine? {
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

  public func drainAvailable() -> [ClaudeCodeRolloutLine] {
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

  private func popQueued() -> ClaudeCodeRolloutLine? {
    lock.lock()
    defer { lock.unlock() }
    guard !queued.isEmpty else {
      return nil
    }
    return queued.removeFirst()
  }

  private func appendFlushedLines() {
    let lines = watcher.flush().compactMap { event -> ClaudeCodeRolloutLine? in
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

public enum ClaudeCodeCLICommandExecutor {
  public struct Result: Equatable, Sendable {
    public var data: JSONValue?
    public var errors: [String]

    public init(data: JSONValue? = nil, errors: [String] = []) {
      self.data = data
      self.errors = errors
    }
  }

  public static func execute(arguments: [String], context: ClaudeCodeAgentCompatibilityContext = ClaudeCodeAgentCompatibilityContext()) -> Result {
    do {
      if arguments.first == "--version" || arguments.first == "-v" {
        return Result(data: .object(toolVersionsJSON(variables: ["includeGit": .bool(false)])))
      }
      let strippedArguments = try ClaudeCodeCLICompatibility.stripRootOptions(arguments)
      let parsed = try ClaudeCodeCLICompatibility.parseCommand(strippedArguments)
      if parsed.family == .auth {
        return executeAuthCommand(action: parsed.action ?? "status", arguments: parsed.arguments, context: context)
      }
      if parsed.family == .graphql {
        let graphQL = try parseGraphQLCLIArguments(parsed.arguments)
        let result = ClaudeCodeGraphQLCommandExecutor.execute(command: graphQL.document, variables: graphQL.variables, context: context)
        return Result(data: result.data, errors: result.errors)
      }
      let commandName = parsed.family == .version ? "version.get" : "\(parsed.family.rawValue).\(parsed.action ?? "")"
      let variables = try variablesForCLI(parsed)
      let result = ClaudeCodeGraphQLCommandExecutor.execute(command: commandName, variables: variables, context: context)
      return Result(data: result.data, errors: result.errors)
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }

  private static func executeAuthCommand(action: String, arguments: [String], context: ClaudeCodeAgentCompatibilityContext) -> Result {
    switch action {
    case "status", "verify":
      let account = try? ClaudeCodeConfigReader.account(path: claudeConfigPath(for: context))
      let readiness = claudeReadiness(context: context, model: action == "verify" ? CLIFlagArguments(arguments: arguments).value("--model") : nil)
      let loggedIn = claudeCodeBoolValue(readiness["ready"]) ?? false
      var payload: JSONObject = [
        "loggedIn": .bool(loggedIn),
        "authenticated": .bool(loggedIn)
      ]
      for (key, value) in readiness {
        payload[key] = value
      }
      if let account {
        payload["account"] = .object([
          "accountUuid": .string(account.accountUuid),
          "emailAddress": .string(account.emailAddress),
          "displayName": .string(account.displayName),
          "organizationName": .string(account.organizationName)
        ])
      }
      guard loggedIn else {
        return Result(data: .object(payload), errors: ["claude-code-agent authentication is unavailable: credentials are missing or expired"])
      }
      return Result(data: .object(payload))
    case "info":
      let account = try? ClaudeCodeConfigReader.account(path: claudeConfigPath(for: context))
      guard let account else {
        return Result(errors: ["claude-code-agent authentication is unavailable: not logged in"])
      }
      return Result(data: .object([
        "account": .object([
          "accountUuid": .string(account.accountUuid),
          "emailAddress": .string(account.emailAddress),
          "displayName": .string(account.displayName),
          "organizationName": .string(account.organizationName)
        ])
      ]))
    case "token":
      let configDir = context.configDir ?? defaultClaudeCodeAgentConfigDir()
      return Result(data: (try? claudeCodeJSONValue(ClaudeCodeTokenPersistence.listMetadata(configDir: configDir))) ?? .array([]))
    default:
      return Result(errors: ["Unsupported auth action: \(action)"])
    }
  }

  private static func variablesForCLI(_ parsed: ClaudeCodeCLICompatibility.ParsedCommand) throws -> JSONObject {
    let parameterArguments = parsed.arguments.filter(isKnownInlineParameter)
    var values = try ClaudeCodeGraphQLCommandExecutor.parseParams(parameterArguments)
    let flags = CLIFlagArguments(arguments: parsed.arguments.filter { !isKnownInlineParameter($0) })
    let positional = flags.positionals
    applyCommonLegacyFlags(flags, to: &values)
    applyCreationCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applyQueueCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applyGroupCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applyTokenCLIValues(parsed, flags: flags, values: &values)
    applyBookmarkCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applySessionCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applyActivityCLIValues(parsed, flags: flags, positional: positional, values: &values)
    applyFilesCLIValues(parsed, positional: positional, values: &values)
    applyModelCLIValues(parsed, positional: positional, values: &values)
    applySimpleIdCLIValues(parsed, positional: positional, values: &values)
    return values
  }

  private static func applyCreationCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.action == "create", parsed.family == .queue || parsed.family == .group else {
      return
    }
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
  }

  private static func applyQueueCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .queue else {
      return
    }
    switch parsed.action {
    case "add":
      assignQueuePromptValues(flags: flags, positional: positional, values: &values)
    case "move":
      assignQueueMoveValues(flags: flags, positional: positional, values: &values)
    case "update":
      assignQueueCommandReference(positional: positional, values: &values)
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["status"] == nil, let status = flags.value("--status") { values["status"] = .string(status) }
    case "remove":
      assignQueueCommandReference(positional: positional, values: &values)
    case "mode":
      assignQueueCommandReference(positional: positional, values: &values)
      if values["mode"] == nil, let mode = flags.value("--mode") { values["mode"] = .string(mode) }
      if values["mode"] == nil, positional.count > 2 { values["mode"] = .string(positional[2]) }
    default:
      break
    }
  }

  private static func assignQueuePromptValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
    if values["prompt"] == nil, positional.count > 1 { values["prompt"] = .string(positional[1]) }
    if values["position"] == nil, let position = flags.value("--position").flatMap(Int.init) {
      values["position"] = .number(Double(position))
    }
    if values["position"] == nil, let position = inlineIntValue(name: "position", in: positional) {
      values["position"] = .number(Double(position))
    }
  }

  private static func inlineIntValue(name: String, in arguments: [String]) -> Int? {
    let prefix = "\(name)="
    return arguments
      .first { $0.hasPrefix(prefix) }
      .flatMap { Int($0.dropFirst(prefix.count)) }
  }

  private static func assignQueueMoveValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["from"] == nil, let from = flags.value("--from").flatMap(Int.init) { values["from"] = .number(Double(from)) }
    if values["to"] == nil, let to = flags.value("--to").flatMap(Int.init) { values["to"] = .number(Double(to)) }
    if values["from"] == nil, positional.count > 1 { values["from"] = .number(Double(Int(positional[1]) ?? 0)) }
    if values["to"] == nil, positional.count > 2 { values["to"] = .number(Double(Int(positional[2]) ?? 0)) }
  }

  private static func assignQueueCommandReference(positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["index"] == nil, positional.count > 1, let index = Int(positional[1]) { values["index"] = .number(Double(index)) }
    if values["commandId"] == nil, values["index"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
  }

  private static func applyTokenCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    values: inout JSONObject
  ) {
    guard parsed.family == .token, parsed.action == "create" else {
      return
    }
    if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
    if values["permissions"] == nil, let permissions = flags.value("--permissions") { values["permissions"] = .string(permissions) }
    if values["expiresAt"] == nil, let expiresAt = flags.value("--expires-at") { values["expiresAt"] = .string(expiresAt) }
    if values["expiresIn"] == nil, let expiresIn = flags.value("--expires") { values["expiresIn"] = .string(expiresIn) }
  }

  private static func applyGroupCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .group else {
      return
    }
    if parsed.action == "add" || parsed.action == "remove" {
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
    }
    if parsed.action == "run" {
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["maxConcurrent"] == nil, let maxConcurrent = flags.value("--max-concurrent").flatMap(Int.init) {
        values["maxConcurrent"] = .number(Double(maxConcurrent))
      }
    }
  }

  private static func applyBookmarkCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .bookmark else {
      return
    }
    switch parsed.action {
    case "add":
      applyBookmarkAddCLIValues(flags: flags, positional: positional, values: &values)
    case "list":
      if values["sessionId"] == nil, let session = flags.value("--session") ?? flags.value("--session-id") {
        values["sessionId"] = .string(session)
      }
      if values["type"] == nil, let type = flags.value("--type") { values["type"] = .string(type) }
      if values["tag"] == nil, let tag = flags.value("--tag") { values["tag"] = .string(tag) }
    case "search":
      if values["query"] == nil, let first = positional.first { values["query"] = .string(first) }
    default:
      break
    }
  }

  private static func applyBookmarkAddCLIValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["type"] == nil, let type = flags.value("--type") { values["type"] = .string(type) }
    if values["type"] == nil, positional.count > 0 { values["type"] = .string(positional[0]) }
    if values["sessionId"] == nil, let session = flags.value("--session") ?? flags.value("--session-id") { values["sessionId"] = .string(session) }
    if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
    if values["messageId"] == nil, let message = flags.value("--message") ?? flags.value("--message-id") { values["messageId"] = .string(message) }
    if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
    if values["description"] == nil, let description = flags.value("--description") { values["description"] = .string(description) }
    applyBookmarkTags(flags: flags, values: &values)
    if values["fromMessageId"] == nil, let fromMessageId = flags.value("--from") ?? flags.value("--from-message") ?? flags.value("--from-message-id") {
      values["fromMessageId"] = .string(fromMessageId)
    }
    if values["toMessageId"] == nil, let toMessageId = flags.value("--to") ?? flags.value("--to-message") ?? flags.value("--to-message-id") {
      values["toMessageId"] = .string(toMessageId)
    }
  }

  private static func applyBookmarkTags(flags: CLIFlagArguments, values: inout JSONObject) {
    guard values["tags"] == nil else {
      return
    }
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

  private static func applySessionCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .session else {
      return
    }
    switch parsed.action {
    case "searchTranscript":
      if values["id"] == nil, positional.count > 1 { values["id"] = .string(positional[0]) }
      if values["query"] == nil { values["query"] = .string(positional.count > 1 ? positional[1] : (positional.first ?? "")) }
    case "search":
      if values["query"] == nil, let first = positional.first { values["query"] = .string(first) }
    case "show", "get", "messages", "watch":
      if values["id"] == nil, let first = positional.first { values["id"] = .string(first) }
    case "resume":
      if values["id"] == nil, let first = positional.first { values["id"] = .string(first) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["prompt"] == nil, positional.count > 1 { values["prompt"] = .string(positional.dropFirst().joined(separator: " ")) }
    case "fork":
      if values["id"] == nil, let first = positional.first { values["id"] = .string(first) }
      if values["nthMessage"] == nil, let nthMessage = flags.value("--nth-message").flatMap(Int.init) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
      if values["nthMessage"] == nil, positional.count > 1, let nthMessage = Int(positional[1]) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
    case "run":
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["prompt"] == nil { values["prompt"] = .string(positional.joined(separator: " ")) }
    default:
      break
    }
  }

  private static func applyActivityCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    flags: CLIFlagArguments,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .activity else {
      return
    }
    switch parsed.action {
    case "get", "status":
      if values["sessionId"] == nil, let first = positional.first { values["sessionId"] = .string(first) }
      if values["id"] == nil, let first = positional.first { values["id"] = .string(first) }
    case "update":
      applyActivityUpdateCLIValues(flags: flags, positional: positional, values: &values)
    case "setup":
      if values["global"] == nil, flags.has("--global") { values["global"] = .bool(true) }
      if values["project"] == nil, flags.has("--project") { values["project"] = .bool(true) }
      if values["dryRun"] == nil, flags.has("--dry-run") { values["dryRun"] = .bool(true) }
    case "cleanup":
      if values["olderThan"] == nil, let olderThan = flags.value("--older-than") ?? positional.first {
        values["olderThan"] = .string(olderThan)
      }
    default:
      break
    }
  }

  private static func applyActivityUpdateCLIValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["sessionId"] == nil, let first = positional.first { values["sessionId"] = .string(first) }
    if values["status"] == nil, positional.count > 1 { values["status"] = .string(positional[1]) }
    if values["status"] == nil, let status = flags.value("--status") { values["status"] = .string(status) }
    if values["updatedAt"] == nil, let updatedAt = flags.value("--updated-at") { values["updatedAt"] = .string(updatedAt) }
    if values["projectPath"] == nil, let projectPath = flags.value("--project") ?? flags.value("--cwd") {
      values["projectPath"] = .string(projectPath)
    }
  }

  private static func applyFilesCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .files else {
      return
    }
    if parsed.action == "list" || parsed.action == "patches" {
      if values["sessionId"] == nil, let first = positional.first { values["sessionId"] = .string(first) }
    }
    if parsed.action == "find", values["path"] == nil, let first = positional.first {
      values["path"] = .string(first)
    }
  }

  private static func applyModelCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    positional: [String],
    values: inout JSONObject
  ) {
    guard parsed.family == .model, parsed.action == "check" else {
      return
    }
    if values["model"] == nil, let first = positional.first {
      values["model"] = .string(first)
    }
  }

  private static func applySimpleIdCLIValues(
    _ parsed: ClaudeCodeCLICompatibility.ParsedCommand,
    positional: [String],
    values: inout JSONObject
  ) {
    let bookmarkIdActions = ["get", "show", "content", "delete"]
    let tokenIdActions = ["revoke", "rotate"]
    guard
      parsed.family == .queue
        || parsed.family == .group
        || (parsed.family == .bookmark && bookmarkIdActions.contains(parsed.action ?? ""))
        || (parsed.family == .token && tokenIdActions.contains(parsed.action ?? ""))
    else {
      return
    }
    if values["id"] == nil, let first = positional.first {
      values["id"] = .string(first)
    }
  }

  private static let knownInlineParameterNames: Set<String> = [
    "additionalArgs",
    "additionalArguments",
    "approvalMode",
    "authToken",
    "branch",
    "caseSensitive",
    "claudeBinary",
    "claudeCodeBinary",
    "claudeCodeHome",
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
    "systemPrompt",
    "tag",
    "tags",
    "timeoutMs",
    "token",
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
      ("--session-mode", "sessionMode"),
      ("--stream-granularity", "streamGranularity"),
      ("--source", "source"),
      ("--cwd", "cwd"),
      ("--branch", "branch"),
      ("--role", "role"),
      ("--claude-binary", "claudeBinary"),
      ("--claudeCode-binary", "claudeCodeBinary"),
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
      "--claudeCode-binary",
      "--executable-name",
      "--from",
      "--to",
      "--position",
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
      throw ClaudeCodeGraphQLError.missingDocument
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
          throw ClaudeCodeGraphQLError.missingFlagValue(argument)
        }
        let loaded = try ClaudeCodeGraphQLCommandExecutor.loadVariablesSource(arguments[index])
        for (key, value) in loaded {
          variables[key] = value
        }
      case "--param", "--arg":
        index += 1
        guard index < arguments.count else {
          throw ClaudeCodeGraphQLError.missingFlagValue(argument)
        }
        variables["param"] = try ClaudeCodeGraphQLCommandExecutor.loadJSONSource(arguments[index])
      default:
        if argument.contains("=") {
          inlineParams.append(argument)
        } else {
          throw ClaudeCodeGraphQLError.invalidParam(argument)
        }
      }
      index += 1
    }
    if !inlineParams.isEmpty {
      for (key, value) in try ClaudeCodeGraphQLCommandExecutor.parseParams(inlineParams) {
        if variables["param"] == nil {
          variables[key] = value
        } else if case var .object(paramObject)? = variables["param"] {
          paramObject[key] = value
          variables["param"] = .object(paramObject)
        }
      }
    }
    return GraphQLCLIArguments(document: ClaudeCodeGraphQLCommandExecutor.normalizeDocument(document), variables: variables)
  }
}
