// swiftlint:disable file_length
// Compatibility command support stays in this worker-owned source file; splitting it requires separate file ownership.
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
    .graphql: [""]
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
        "title": .string(session.title)
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
      let loggedIn = cursorOperationBoolValue(readiness["ready"]) ?? false
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
          "organizationName": .string(account.organizationName)
        ])
      ]))
    case "token":
      let configDir = context.configDir ?? defaultCursorCLIAgentConfigDir()
      return Result(data: (try? cursorOperationJSONValue(CursorCLITokenPersistence.listMetadata(configDir: configDir))) ?? .array([]))
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
    switch parsed.family {
    case .queue:
      applyQueueLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    case .group:
      applyGroupLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    case .bookmark:
      applyBookmarkLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    case .session:
      applySessionLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    case .activity:
      applyActivityLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    case .token:
      applyTokenLegacyValues(action: parsed.action, flags: flags, positional: positional, values: &values)
    default:
      break
    }
    applyMiscLegacyValues(family: parsed.family, action: parsed.action, positional: positional, values: &values)
    return values
  }

  private static func applyQueueLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "create":
      applyCreateName(flags: flags, positional: positional, values: &values)
      if values["projectPath"] == nil, let project = flags.value("--project") {
        values["projectPath"] = .string(project)
      }
    case "add":
      applyQueueAddLegacyValues(flags: flags, positional: positional, values: &values)
    case "move":
      applyQueueMoveLegacyValues(flags: flags, positional: positional, values: &values)
    case "update", "remove", "mode":
      applyQueuePromptEditValues(action: action, flags: flags, positional: positional, values: &values)
    default:
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    }
  }

  private static func applyQueueAddLegacyValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
    if values["prompt"] == nil, positional.count > 1 { values["prompt"] = .string(positional[1]) }
  }

  private static func applyQueueMoveLegacyValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["from"] == nil, let from = flags.value("--from").flatMap(Int.init) { values["from"] = .number(Double(from)) }
    if values["to"] == nil, let to = flags.value("--to").flatMap(Int.init) { values["to"] = .number(Double(to)) }
    if values["from"] == nil, positional.count > 1 { values["from"] = .number(Double(Int(positional[1]) ?? 0)) }
    if values["to"] == nil, positional.count > 2 { values["to"] = .number(Double(Int(positional[2]) ?? 0)) }
  }

  private static func applyQueuePromptEditValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
    if values["index"] == nil, positional.count > 1, let index = Int(positional[1]) { values["index"] = .number(Double(index)) }
    if values["commandId"] == nil, values["index"] == nil, positional.count > 1 { values["commandId"] = .string(positional[1]) }
    guard action != "remove" else {
      return
    }
    if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
    if values["status"] == nil, let status = flags.value("--status") { values["status"] = .string(status) }
    if action == "mode", values["mode"] == nil, let mode = flags.value("--mode") { values["mode"] = .string(mode) }
    if action == "mode", values["mode"] == nil, positional.count > 2 { values["mode"] = .string(positional[2]) }
  }

  private static func applyGroupLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "create":
      applyCreateName(flags: flags, positional: positional, values: &values)
      if values["description"] == nil, let description = flags.value("--description") {
        values["description"] = .string(description)
      }
    case "add", "remove":
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["sessionId"] == nil, positional.count > 1 { values["sessionId"] = .string(positional[1]) }
    case "run":
      if values["id"] == nil, positional.count > 0 { values["id"] = .string(positional[0]) }
      if values["prompt"] == nil, let prompt = flags.value("--prompt") { values["prompt"] = .string(prompt) }
      if values["maxConcurrent"] == nil, let maxConcurrent = flags.value("--max-concurrent").flatMap(Int.init) {
        values["maxConcurrent"] = .number(Double(maxConcurrent))
      }
    default:
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    }
  }

  private static func applyCreateName(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["name"] == nil, let name = flags.value("--name") {
      values["name"] = .string(name)
    }
    if values["name"] == nil, let first = positional.first {
      values["name"] = .string(first)
    }
  }

  private static func applyBookmarkLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "add":
      applyBookmarkAddValues(flags: flags, positional: positional, values: &values)
    case "list":
      applyBookmarkListValues(flags: flags, values: &values)
    case "get", "show", "content", "delete":
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    case "search":
      if values["query"] == nil, let first = positional.first {
        values["query"] = .string(first)
      }
    default:
      break
    }
  }

  private static func applyBookmarkAddValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
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
      values["tags"] = .array(csvTags.split(separator: ",").map { rawTag in
        JSONValue.string(rawTag.trimmingCharacters(in: .whitespacesAndNewlines))
      }.filter {
        if case let .string(text) = $0 {
          return !text.isEmpty
        }
        return false
      })
    }
  }

  private static func applyBookmarkListValues(flags: CLIFlagArguments, values: inout JSONObject) {
    if values["sessionId"] == nil, let session = flags.value("--session") ?? flags.value("--session-id") {
      values["sessionId"] = .string(session)
    }
    if values["type"] == nil, let type = flags.value("--type") {
      values["type"] = .string(type)
    }
    if values["tag"] == nil, let tag = flags.value("--tag") {
      values["tag"] = .string(tag)
    }
  }

  private static func applySessionLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "searchTranscript":
      if values["id"] == nil, positional.count > 1 {
        values["id"] = .string(positional[0])
      }
      if values["query"] == nil {
        values["query"] = .string(positional.count > 1 ? positional[1] : (positional.first ?? ""))
      }
    case "search":
      if values["query"] == nil, let first = positional.first {
        values["query"] = .string(first)
      }
    case "show", "get", "messages", "watch", "cancel", "pause":
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    case "create", "run":
      applyPromptValue(flags: flags, positional: positional, values: &values)
    case "resume":
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
      applyPromptValue(flags: flags, positional: Array(positional.dropFirst()), values: &values)
    case "fork":
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
      if values["nthMessage"] == nil, let nthMessage = flags.value("--nth-message").flatMap(Int.init) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
      if values["nthMessage"] == nil, positional.count > 1, let nthMessage = Int(positional[1]) {
        values["nthMessage"] = .number(Double(nthMessage))
      }
    default:
      break
    }
  }

  private static func applyPromptValue(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    if values["prompt"] == nil, let prompt = flags.value("--prompt") {
      values["prompt"] = .string(prompt)
    }
    if values["prompt"] == nil {
      values["prompt"] = .string(positional.joined(separator: " "))
    }
  }

  private static func applyActivityLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "get", "status":
      if values["sessionId"] == nil, let first = positional.first { values["sessionId"] = .string(first) }
      if values["id"] == nil, let first = positional.first { values["id"] = .string(first) }
    case "update":
      applyActivityUpdateValues(flags: flags, positional: positional, values: &values)
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

  private static func applyActivityUpdateValues(flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
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
  }

  private static func applyTokenLegacyValues(action: String?, flags: CLIFlagArguments, positional: [String], values: inout JSONObject) {
    switch action {
    case "create":
      if values["name"] == nil, let name = flags.value("--name") { values["name"] = .string(name) }
      if values["permissions"] == nil, let permissions = flags.value("--permissions") { values["permissions"] = .string(permissions) }
      if values["expiresAt"] == nil, let expiresAt = flags.value("--expires-at") { values["expiresAt"] = .string(expiresAt) }
      if values["expiresIn"] == nil, let expiresIn = flags.value("--expires") { values["expiresIn"] = .string(expiresIn) }
    case "revoke", "rotate":
      if values["id"] == nil, let first = positional.first {
        values["id"] = .string(first)
      }
    default:
      break
    }
  }

  private static func applyMiscLegacyValues(
    family: CursorCLICLICompatibility.CommandFamily,
    action: String?,
    positional: [String],
    values: inout JSONObject
  ) {
    switch (family, action) {
    case (.model, "check"):
      if values["model"] == nil, let first = positional.first {
        values["model"] = .string(first)
      }
    case (.files, "list"), (.files, "patches"):
      if values["sessionId"] == nil, let first = positional.first {
        values["sessionId"] = .string(first)
      }
    case (.files, "find"):
      if values["path"] == nil, let first = positional.first {
        values["path"] = .string(first)
      }
    default:
      break
    }
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
    "yolo"
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
      ("--worktree-base", "worktreeBase")
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
      guard let sessionId = cursorOperationStringValue(payload["session_id"]) ?? cursorOperationStringValue(payload["sessionId"]), !sessionId.isEmpty else {
        return CursorCLIAgentCLIApplicationResult(exitCode: 0)
      }
      let hookEventName = cursorOperationStringValue(payload["hook_event_name"]) ?? cursorOperationStringValue(payload["hookEventName"]) ?? ""
      let transcriptPath = cursorOperationStringValue(payload["transcript_path"]) ?? cursorOperationStringValue(payload["transcriptPath"])
      let transcriptTail = transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
      let entry = CursorCLIStoredActivityEntry(
        sessionId: sessionId,
        status: CursorCLIActivityAnalyzer.status(hookEventName: hookEventName, transcriptTail: transcriptTail),
        updatedAt: cursorOperationISOString(Date()),
        projectPath: cursorOperationStringValue(payload["cwd"]) ?? cursorOperationStringValue(payload["projectPath"])
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
      if argument == "--format" || argument == "-f", index + 1 < arguments.count {
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
      guard let object = try? cursorOperationJSONObjectValue(value) else {
        return nil
      }
      let version = cursorOperationStringValue(object["version"]) ?? "unknown"
      let cursor = (try? cursorOperationJSONObjectValue(object["cursorCLI"] ?? .null)).flatMap { cursorOperationStringValue($0["version"]) } ?? "unavailable"
      let git = (try? cursorOperationJSONObjectValue(object["git"] ?? .null)).flatMap { cursorOperationStringValue($0["version"]) } ?? "unavailable"
      return "Tool\tversion\nagent\t\(version)\ncursor\t\(cursor)\ngit\t\(git)\n"
    case ("queue", "list"), ("group", "list"):
      guard case let .array(items) = value else {
        return nil
      }
      let rows = items.compactMap { try? cursorOperationJSONObjectValue($0) }.map { object in
        "\(cursorOperationStringValue(object["id"]) ?? "")\t\(cursorOperationStringValue(object["name"]) ?? "")"
      }
      return "ID\tName\n" + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    case ("queue", "show"), ("queue", "get"), ("group", "show"), ("group", "get"):
      guard let object = try? cursorOperationJSONObjectValue(value) else {
        return nil
      }
      return "ID\tName\n\(cursorOperationStringValue(object["id"]) ?? "")\t\(cursorOperationStringValue(object["name"]) ?? "")\n"
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
      guard let payload = cursorOperationFileChangeObject(line.payload) else {
        continue
      }
      if let callId = cursorOperationFileChangeString(payload["call_id"]) ?? cursorOperationFileChangeString(payload["callId"]) ?? cursorOperationFileChangeString(payload["id"]) {
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
    guard let payload = cursorOperationFileChangeObject(line.payload) else {
      return []
    }
    if let exitCode = cursorOperationNumberValue(payload["exit_code"]), exitCode != 0 {
      return []
    }
    if let changes = fileChangeArray(payload["file_changes"]) {
      return changes
    }
    if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
      return commandChanges
    }
    if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["aggregated_output"]) {
      return parsePatchFileChanges(patch)
    }
    return []
  }
}

func isToolInvocationPayload(_ payload: JSONObject) -> Bool {
  guard let type = cursorOperationFileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type)
}

func isToolResultPayload(_ payload: JSONObject) -> Bool {
  guard let type = cursorOperationFileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call_output", "custom_tool_call_output", "local_shell_call_output", "ExecCommandEnd"].contains(type)
}

func isSuccessfulToolResult(_ payload: JSONObject) -> Bool {
  if cursorOperationBoolValue(payload["is_error"]) == true || cursorOperationBoolValue(payload["isError"]) == true {
    return false
  }
  if let exitCode = cursorOperationNumberValue(payload["exit_code"]) ?? cursorOperationNumberValue(payload["exitCode"]) {
    return exitCode == 0
  }
  if let status = cursorOperationFileChangeString(payload["status"])?.lowercased() {
    return isSuccessfulToolStatus(status)
  }
  if let output = cursorOperationFileChangeObject(payload["output"]) ?? cursorOperationFileChangeString(payload["output"]).flatMap(parseFileChangeArguments) {
    if cursorOperationBoolValue(output["is_error"]) == true || cursorOperationBoolValue(output["isError"]) == true {
      return false
    }
    if let metadata = cursorOperationFileChangeObject(output["metadata"]) {
      if cursorOperationBoolValue(metadata["is_error"]) == true || cursorOperationBoolValue(metadata["isError"]) == true {
        return false
      }
      if let exitCode = cursorOperationNumberValue(metadata["exit_code"]) ?? cursorOperationNumberValue(metadata["exitCode"]), exitCode != 0 {
        return false
      }
      if let status = cursorOperationFileChangeString(metadata["status"])?.lowercased() {
        return isSuccessfulToolStatus(status)
      }
    }
    if let exitCode = cursorOperationNumberValue(output["exit_code"]) ?? cursorOperationNumberValue(output["exitCode"]), exitCode != 0 {
      return false
    }
    if let status = cursorOperationFileChangeString(output["status"])?.lowercased() {
      return isSuccessfulToolStatus(status)
    }
  }
  return true
}

func isSuccessfulToolStatus(_ status: String) -> Bool {
  ["completed", "success", "succeeded", "ok"].contains(status)
}

func extractDirectChanges(from payload: JSONObject) -> [CursorCLIFileChange] {
  if let changes = fileChangeArray(payload["file_changes"]) {
    return changes
  }
  if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
    return commandChanges
  }
  if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["aggregated_output"]) ?? cursorOperationFileChangeString(payload["output"]) {
    return parsePatchFileChanges(patch)
  }
  return []
}

func commandLikeFileChanges(payload: JSONObject) -> [CursorCLIFileChange]? {
  let type = cursorOperationFileChangeString(payload["type"])
  guard ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type) else {
    return nil
  }
  if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["input"]) {
    let changes = parsePatchFileChanges(patch)
    if !changes.isEmpty {
      return changes
    }
  }
  let argumentObject = cursorOperationFileChangeObject(payload["arguments"]) ?? cursorOperationFileChangeString(payload["arguments"]).flatMap(parseFileChangeArguments)
  let command = cursorOperationFileChangeString(argumentObject?["command"])
    ?? cursorOperationFileChangeString(argumentObject?["cmd"])
    ?? cursorOperationFileChangeString(argumentObject?["script"])
    ?? cursorOperationStringArrayValue(argumentObject?["command"]).map { $0.joined(separator: " ") }
    ?? cursorOperationStringArrayValue(payload["command"]).map { $0.joined(separator: " ") }
  guard let command else {
    return nil
  }
  return parseShellFileChanges(command)
}

func parsePatchFileChanges(_ patch: String) -> [CursorCLIFileChange] {
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

func parseFileChangeArguments(_ text: String) -> JSONObject? {
  guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value else {
    return nil
  }
  return object
}

func parseShellFileChanges(_ command: String) -> [CursorCLIFileChange] {
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

func unwrapBashLoginCommand(_ command: String) -> String? {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  for prefix in ["bash -lc ", "sh -lc ", "zsh -lc "] where trimmed.hasPrefix(prefix) {
    return stripShellQuotes(String(trimmed.dropFirst(prefix.count)))
  }
  return nil
}

func cleanShellPath(_ path: String) -> String {
  stripShellQuotes(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`; "))
}

func stripShellQuotes(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let isSingleQuoted = value.hasPrefix("'") && value.hasSuffix("'")
  let isDoubleQuoted = value.hasPrefix("\"") && value.hasSuffix("\"")
  if isSingleQuoted || isDoubleQuoted {
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
            "previousPath": change.previousPath.map(JSONValue.string) ?? .null
          ]
          if let command = change.command {
            object["command"] = .string(command)
          }
          if let patch = change.patch {
            object["patch"] = .string(patch)
          }
          return .object(object)
        })
      ]
    }
  }
}

struct PersistentChangedFile: Codable {
  var path: String
  var operation: String
  var changeCount: Int
  var lastModified: String
}

struct PersistentSessionFileIndexEntry: Codable {
  var sessionId: String
  var files: [PersistentChangedFile]
  var indexedAt: String
}

struct PersistentFileChangeIndex: Codable {
  var sessions: [PersistentSessionFileIndexEntry]
  var updatedAt: String
}

func persistentFileIndexURL(configDir: String) -> URL {
  URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("file-changes-index.json")
}

func rebuildPersistentFileIndex(configDir: String, cursorCLIHome: String?) throws -> JSONObject {
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
    "updatedAt": .string(indexedAt)
  ]
}

func findPersistentSessionsByFile(path: String, configDir: String, cursorCLIHome: String?) throws -> JSONObject {
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
        "lastModified": .string(file.lastModified)
      ] as JSONObject
    }
  }.sorted { lhs, rhs in
    (cursorOperationStringValue(lhs["lastModified"]) ?? "") > (cursorOperationStringValue(rhs["lastModified"]) ?? "")
  }
  return [
    "path": .string(target),
    "sessions": .array(sessions.map(JSONValue.object))
  ]
}

func rolloutSessionId(lines: [CursorCLIRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = cursorOperationFileChangeObject(line.payload), let meta = cursorOperationFileChangeObject(payload["meta"]), let id = cursorOperationFileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

func changedFilesSummary(from lines: [CursorCLIRolloutLine]) -> [PersistentChangedFile] {
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

func changedFilesSummary(changes: [CursorCLIFileChange], timestamp: String) -> [PersistentChangedFile] {
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

func fileChangeIndex(for session: CursorCLISession) throws -> CursorCLIFileChangeIndex {
  let index = try CursorCLIFileChangeIndex.rebuild(from: CursorCLIRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return CursorCLIFileChangeIndex(changes: parseRawPatchFileChanges(raw))
}

struct FileChangeDetailDTO {
  var path: String
  var timestamp: String
  var operation: String
  var source: String
  var previousPath: String?
  var command: String?
  var patch: String?
}

func fileChangeSummaryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = cursorOperationISOString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count))
  ]
}

func filePatchHistoryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = cursorOperationISOString(session.updatedAt)
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
      grouped[previousPath, default: []].append(FileChangeDetailDTO(
        path: previousPath,
        timestamp: detail.timestamp,
        operation: "deleted",
        source: detail.source,
        previousPath: detail.previousPath,
        command: detail.command,
        patch: detail.patch
      ))
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
      "changes": .array(entries.map { .object(fileChangeDetailJSON($0)) })
    ]
  }
  let totalChanges = files.reduce(0) { partial, file in
    partial + (cursorOperationIntValue(file["changeCount"]) ?? 0)
  }
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(JSONValue.object)),
    "totalFiles": .number(Double(files.count)),
    "totalChanges": .number(Double(totalChanges))
  ]
}

func persistentChangedFileJSON(_ file: PersistentChangedFile) -> JSONValue {
  .object([
    "path": .string(file.path),
    "operation": .string(file.operation),
    "changeCount": .number(Double(file.changeCount)),
    "lastModified": .string(file.lastModified)
  ])
}

func fileChangeDetails(from lines: [CursorCLIRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    CursorCLIFileChanges.extract(from: line).map { change in
      FileChangeDetailDTO(
        path: change.path,
        timestamp: line.timestamp,
        operation: change.operation.rawValue,
        source: change.source.rawValue,
        previousPath: change.previousPath,
        command: change.command,
        patch: change.patch
      )
    }
  }
}
func fileChangeDetailJSON(_ detail: FileChangeDetailDTO) -> JSONObject {
  var object: JSONObject = [
    "path": .string(detail.path),
    "timestamp": .string(detail.timestamp),
    "operation": .string(detail.operation),
    "source": .string(detail.source),
    "previousPath": detail.previousPath.map(JSONValue.string) ?? .null
  ]
  if let command = detail.command {
    object["command"] = .string(command)
  }
  if let patch = detail.patch {
    object["patch"] = .string(patch)
  }
  return object
}

func parseRawPatchFileChanges(_ text: String) -> [CursorCLIFileChange] {
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
    "session.list", "session.show", "session.get", "session.messages", "session.search",
    "session.searchTranscript", "session.run", "session.create", "session.cancel", "session.pause", "session.resume",
    "session.fork", "session.watch",
    "activity.list", "activity.get", "activity.status", "activity.update", "activity.cleanup", "activity.setup",
    "group.create", "group.list", "group.show", "group.get", "group.watch", "group.add", "group.addSession", "group.remove", "group.removeSession", "group.pause", "group.resume", "group.delete", "group.run",
    "queue.create", "queue.add", "queue.addCommand", "queue.show", "queue.get", "queue.list", "queue.pause",
    "queue.resume", "queue.stop", "queue.delete", "queue.update", "queue.updateCommand", "queue.remove",
    "queue.removeCommand", "queue.move", "queue.mode", "queue.run",
    "bookmark.add", "bookmark.list", "bookmark.get", "bookmark.show", "bookmark.content", "bookmark.delete", "bookmark.search",
    "token.create", "token.list", "token.revoke", "token.rotate",
    "files.list", "files.patches", "files.find", "files.rebuild",
    "model.check",
    "skill.list", "skill.show",
    "daemon.status", "daemon.start", "daemon.stop", "daemon.restart",
    "server.status", "server.events",
    "usage.list", "usage.stats", "usage.summary",
    "markdown.tasks", "markdown.parse",
    "repo.status", "repo.files", "repo.analytics", "repo.summary"
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
      params[pieces[0]] = try cursorOperationParseLooseJSONValue(pieces[1])
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
      let execution = makeExecutionContext(commandName: commandName, variables: effectiveVariables, context: context)
      if let authError = try authorizationError(commandName: commandName, rawToken: execution.authToken, configDir: execution.configDir) {
        return Result(errors: [authError])
      }
      return try executeResolvedCommand(execution)
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }

  private struct ExecutionContext {
    var commandName: String
    var variables: JSONObject
    var configDir: String
    var dataDir: String
    var activityDataDir: String
    var cursorCLIHome: String?
    var authToken: String?
  }

  private static func makeExecutionContext(
    commandName: String,
    variables: JSONObject,
    context: CursorCLIAgentCompatibilityContext
  ) -> ExecutionContext {
    let explicitConfigDir = cursorOperationStringValue(variables["configDir"]) ?? context.configDir
    return ExecutionContext(
      commandName: commandName,
      variables: variables,
      configDir: explicitConfigDir ?? defaultCursorCLIAgentConfigDir(),
      dataDir: explicitConfigDir ?? defaultCursorCLIAgentDataDir(),
      activityDataDir: explicitConfigDir ?? CursorCLIActivityStore.defaultDataDir(),
      cursorCLIHome: cursorOperationStringValue(variables["cursorCLIHome"]) ?? context.cursorCLIHome,
      authToken: cursorOperationStringValue(variables["authToken"]) ?? cursorOperationStringValue(variables["token"]) ?? context.authToken
    )
  }

  private static func executeResolvedCommand(_ context: ExecutionContext) throws -> Result {
    if let result = try executeVersionOrModelCommand(context) { return result }
    if let result = try executeSessionCommand(context) { return result }
    if let result = try executeActivityCommand(context) { return result }
    if let result = try executeGroupCommand(context) { return result }
    if let result = try executeQueueCommand(context) { return result }
    if let result = try executeBookmarkCommand(context) { return result }
    if let result = try executeTokenCommand(context) { return result }
    if let result = try executeFileCommand(context) { return result }
    if let result = try executeUtilityCommand(context) { return result }
    return Result(errors: ["Unhandled command: \(context.commandName)"])
  }

  private static func executeVersionOrModelCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "version.get":
      return Result(data: .object(toolVersionsJSON(variables: context.variables)))
    case "model.check":
      let model = try cursorOperationRequiredString(context.variables, "model")
      var options = try cursorOperationProcessOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
      options.model = model
      if options.additionalArguments.isEmpty {
        options.additionalArguments = ["--skip-git-repo-check", "--ephemeral"]
      }
      let manager = CursorCLIProcessManager(executableName: cursorOperationExecutableName(from: context.variables))
      let result = manager.spawnExec(prompt: cursorOperationStringValue(context.variables["prompt"]) ?? "Reply with exactly OK.", options: options)
      return Result(data: .object([
        "model": .string(model),
        "ok": .bool(result.result.exitCode == 0),
        "exitCode": .number(Double(result.result.exitCode)),
        "stdout": .string(result.result.stdout),
        "stderr": .string(result.result.stderr)
      ]))
    default:
      return nil
    }
  }

  private static func executeSessionCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "session.list":
      let options = sessionListOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
      let result = CursorCLISessionIndex.listSessions(options: options)
      return Result(data: .array(result.sessions.map(sessionJSON)))
    case "session.show":
      return try executeSessionShowCommand(context)
    case "session.messages":
      return try executeSessionMessagesCommand(context)
    case "session.search", "session.searchTranscript":
      return try executeSessionSearchCommand(context)
    case "session.run", "session.create":
      return try executeSessionRunCommand(context)
    case "session.resume":
      return try executeSessionResumeCommand(context)
    case "session.cancel", "session.pause":
      return try executeSessionControlCommand(context)
    case "session.fork":
      return try executeSessionForkCommand(context)
    case "session.watch":
      return try executeSessionWatchCommand(context)
    default:
      return nil
    }
  }

  private static func executeSessionShowCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id")
    guard let session = CursorCLISessionCommands.show(sessionId: id, cursorCLIHome: context.cursorCLIHome) else {
      return Result(errors: ["Session not found"])
    }
    return Result(data: sessionJSON(session))
  }

  private static func executeSessionMessagesCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id", fallback: "sessionId")
    guard let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: context.cursorCLIHome) else {
      return Result(errors: ["Session not found"])
    }
    let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
    return Result(data: .object([
      "sessionId": .string(session.id),
      "messages": .array(lines.map(rolloutLineJSON))
    ]))
  }

  private static func executeSessionSearchCommand(_ context: ExecutionContext) throws -> Result {
    let query = try cursorOperationRequiredString(context.variables, "query")
    if context.commandName == "session.searchTranscript", let id = cursorOperationStringValue(context.variables["id"]) {
      return try executeSessionTranscriptSearch(id: id, query: query, context: context)
    }
    let result = try CursorCLISessionIndex.searchSessions(
      query: query,
      options: sessionListOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome),
      searchOptions: transcriptSearchOptions(from: context.variables)
    )
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
      "durationMs": .number(result.durationMs)
    ]))
  }

  private static func executeSessionTranscriptSearch(id: String, query: String, context: ExecutionContext) throws -> Result {
    guard let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: context.cursorCLIHome) else {
      return Result(data: .object([
        "sessionId": .string(id),
        "matched": .bool(false),
        "matchCount": .number(0),
        "scannedBytes": .number(0),
        "scannedEvents": .number(0),
        "truncated": .bool(false),
        "timedOut": .bool(false),
        "durationMs": .number(0)
      ]))
    }
    let search = try CursorCLISessionIndex.searchSessionTranscriptDetailed(
      session: session,
      query: query,
      options: transcriptSearchOptions(from: context.variables)
    )
    return Result(data: .object([
      "matched": .bool(search.matched),
      "sessionId": .string(id),
      "matchCount": .number(Double(search.matchCount)),
      "scannedBytes": .number(Double(search.scannedBytes)),
      "scannedEvents": .number(Double(search.scannedEvents)),
      "truncated": .bool(search.truncated),
      "timedOut": .bool(search.timedOut),
      "durationMs": .number(search.durationMs)
    ]))
  }

  private static func executeSessionRunCommand(_ context: ExecutionContext) throws -> Result {
    let prompt = try cursorOperationRequiredNonBlankString(context.variables, "prompt")
    let manager = CursorCLIProcessManager(executableName: cursorOperationExecutableName(from: context.variables))
    let options = try cursorOperationProcessOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
    let result = manager.spawnExec(prompt: prompt, options: options)
    return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
  }

  private static func executeSessionResumeCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id")
    let manager = CursorCLIProcessManager(executableName: cursorOperationExecutableName(from: context.variables))
    let options = try cursorOperationProcessOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
    let result = manager.spawnResume(sessionId: id, prompt: cursorOperationStringValue(context.variables["prompt"]), options: options)
    return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
  }

  private static func executeSessionControlCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id")
    let manager = CursorCLIProcessManager(executableName: cursorOperationExecutableName(from: context.variables))
    let killed = manager.kill(id: id)
    return Result(data: .object([
      "id": .string(id),
      "success": .bool(killed),
      "ok": .bool(killed),
      "status": .string(killed ? "cancelled" : "not_found"),
      "degraded": .bool(!killed),
      "limitation": .string("process control is available only for active processes owned by this Swift runtime")
    ]))
  }

  private static func executeSessionForkCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id")
    let manager = CursorCLIProcessManager(executableName: cursorOperationExecutableName(from: context.variables))
    let options = try cursorOperationProcessOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
    let process = manager.spawnForkProcess(sessionId: id, nthMessage: cursorOperationIntValue(context.variables["nthMessage"]), options: options)
    return Result(data: .object(processHandleJSON(process)))
  }

  private static func executeSessionWatchCommand(_ context: ExecutionContext) throws -> Result {
    let id = try cursorOperationRequiredString(context.variables, "id")
    let subscription = try watchSession(
      id: id,
      startOffset: cursorOperationNonNegativeUInt64Value(context.variables["startOffset"]) ?? 0,
      cursorCLIHome: context.cursorCLIHome
    )
    let lines = subscription.drainAvailable()
    subscription.cancel()
    return Result(data: .object(["events": .array(lines.map(rolloutLineJSON))]))
  }

  private static func executeActivityCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "activity.list":
      let store = CursorCLIActivityStore(dataDir: context.activityDataDir)
      var entries = try store.load()
      if let status = cursorOperationStringValue(context.variables["status"]).flatMap(CursorCLIActivityStatusValue.init(rawValue:)) {
        entries = entries.filter { $0.status == status }
      }
      return Result(data: .object(["entries": .array(entries.map(activityEntryJSON))]))
    case "activity.get":
      let id = try cursorOperationRequiredString(context.variables, "sessionId", fallback: "id")
      guard let entry = try CursorCLIActivityStore(dataDir: context.activityDataDir).load().first(where: { $0.sessionId == id }) else {
        return Result(errors: ["Activity not found"])
      }
      return Result(data: activityEntryJSON(entry))
    case "activity.update":
      return try executeActivityUpdateCommand(context)
    case "activity.cleanup":
      guard let cutoff = activityCleanupCutoff(from: cursorOperationStringValue(context.variables["olderThan"])) else {
        return Result(errors: ["Invalid cleanup cutoff"])
      }
      let retained = try CursorCLIActivityStore(dataDir: context.activityDataDir).cleanup(olderThan: cutoff)
      return Result(data: .object(["entries": .array(retained.map(activityEntryJSON))]))
    case "activity.setup":
      return Result(data: .object(try activitySetupJSON(variables: context.variables)))
    default:
      return nil
    }
  }

  private static func executeActivityUpdateCommand(_ context: ExecutionContext) throws -> Result {
    let sessionId = try cursorOperationRequiredString(context.variables, "sessionId", fallback: "id")
    guard let status = CursorCLIActivityStatusValue(rawValue: try cursorOperationRequiredString(context.variables, "status")) else {
      return Result(errors: ["Invalid activity status"])
    }
    let store = CursorCLIActivityStore(dataDir: context.activityDataDir)
    let entry = CursorCLIStoredActivityEntry(
      sessionId: sessionId,
      status: status,
      updatedAt: cursorOperationStringValue(context.variables["updatedAt"]) ?? cursorOperationISOString(Date()),
      projectPath: cursorOperationStringValue(context.variables["projectPath"]) ?? cursorOperationStringValue(context.variables["cwd"])
    )
    try store.mutate { entries in
      if let index = entries.firstIndex(where: { $0.sessionId == sessionId }) {
        entries[index] = entry
      } else {
        entries.append(entry)
      }
    }
    return Result(data: activityEntryJSON(entry))
  }

  private static func executeGroupCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "group.create":
      let group = try CursorCLIGroupPersistence.createGroup(
        name: try cursorOperationRequiredString(context.variables, "name"),
        description: cursorOperationStringValue(context.variables["description"]),
        configDir: context.dataDir
      )
      return Result(data: try cursorOperationJSONValue(group))
    case "group.list":
      return Result(data: try cursorOperationJSONValue(CursorCLIGroupPersistence.listGroups(configDir: context.dataDir)))
    case "group.show":
      guard let group = try CursorCLIGroupPersistence.findGroup(try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir) else {
        return Result(errors: ["Group not found"])
      }
      return Result(data: try cursorOperationJSONValue(group))
    case "group.add", "group.remove", "group.pause", "group.resume", "group.delete":
      return try executeGroupMutationCommand(context)
    case "group.run":
      guard let group = try CursorCLIGroupPersistence.findGroup(try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir) else {
        return Result(errors: ["Group not found"])
      }
      let events = try runGroupEvents(
        group: group,
        prompt: try cursorOperationRequiredString(context.variables, "prompt"),
        variables: context.variables,
        cursorCLIHome: context.cursorCLIHome
      )
      return Result(data: .array(events.map(JSONValue.object)))
    default:
      return nil
    }
  }

  private static func executeGroupMutationCommand(_ context: ExecutionContext) throws -> Result {
    let groupId = try resolveExistingGroupId(try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir)
    let ok: Bool
    switch context.commandName {
    case "group.add":
      ok = try CursorCLIGroupPersistence.addSession(groupId: groupId, session: try groupSession(from: context.variables), configDir: context.dataDir)
    case "group.remove":
      ok = try CursorCLIGroupPersistence.removeSession(
        groupId: groupId,
        sessionId: try cursorOperationRequiredString(context.variables, "sessionId"),
        configDir: context.dataDir
      )
      if !ok {
        return Result(errors: ["Group session not found"])
      }
    case "group.pause":
      ok = try CursorCLIGroupPersistence.setPaused(groupId: groupId, paused: true, configDir: context.dataDir)
    case "group.resume":
      ok = try CursorCLIGroupPersistence.setPaused(groupId: groupId, paused: false, configDir: context.dataDir)
    case "group.delete":
      ok = try CursorCLIGroupPersistence.deleteGroup(id: groupId, configDir: context.dataDir)
    default:
      return Result(errors: ["Unhandled group mutation: \(context.commandName)"])
    }
    return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
  }

  private static func executeQueueCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "queue.create":
      return try executeQueueCreateCommand(context)
    case "queue.add":
      let imageValues = cursorOperationStringArray(context.variables["images"])
      let images = imageValues.isEmpty ? cursorOperationStringArray(context.variables["imagePaths"]) : imageValues
      return Result(data: try cursorOperationJSONValue(addQueuePromptLegacy(variables: context.variables, imagePaths: images, configDir: context.dataDir)))
    case "queue.show":
      guard let queue = try CursorCLIQueuePersistence.findQueue(try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir) else {
        return Result(errors: ["Queue not found"])
      }
      return Result(data: try cursorOperationJSONValue(queue))
    case "queue.list":
      return try executeQueueListCommand(context)
    case "queue.delete":
      let id = try resolveExistingQueueId(try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir)
      let ok = try CursorCLIQueuePersistence.removeQueue(id, configDir: context.dataDir)
      return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
    case "queue.pause", "queue.resume", "queue.stop", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run":
      return executeQueueMutation(
        commandName: context.commandName,
        variables: context.variables,
        configDir: context.dataDir,
        cursorCLIHome: context.cursorCLIHome
      )
    default:
      return nil
    }
  }

  private static func executeQueueCreateCommand(_ context: ExecutionContext) throws -> Result {
    let projectPath = try cursorOperationRequiredString(context.variables, "projectPath")
    let name = cursorOperationStringValue(context.variables["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackName = URL(fileURLWithPath: projectPath).lastPathComponent
    let resolvedName = (name?.isEmpty == false ? name : nil) ?? (fallbackName.isEmpty ? projectPath : fallbackName)
    return Result(data: try cursorOperationJSONValue(CursorCLIQueuePersistence.createQueue(
      name: resolvedName,
      projectPath: projectPath,
      configDir: context.dataDir
    )))
  }

  private static func executeQueueListCommand(_ context: ExecutionContext) throws -> Result {
    var queues = try CursorCLIQueuePersistence.listQueues(configDir: context.dataDir)
    if let projectPath = cursorOperationStringValue(context.variables["projectPath"]) {
      queues = queues.filter { $0.projectPath == projectPath }
    }
    if let rawStatus = cursorOperationStringValue(context.variables["status"]), let status = CursorCLIQueueStatus(rawValue: rawStatus) {
      queues = queues.filter { $0.status == status }
    }
    return Result(data: try cursorOperationJSONValue(queues))
  }

  private static func executeBookmarkCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "bookmark.add":
      return try executeBookmarkAddCommand(context)
    case "bookmark.list":
      return try executeBookmarkListCommand(context)
    case "bookmark.get":
      guard let bookmark = try CursorCLIBookmarkPersistence.getBookmark(id: try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir) else {
        return Result(errors: ["Bookmark not found"])
      }
      return Result(data: try cursorOperationJSONValue(bookmark))
    case "bookmark.content":
      guard let bookmark = try CursorCLIBookmarkPersistence.getBookmark(id: try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir) else {
        return Result(errors: ["Bookmark not found"])
      }
      return Result(data: try bookmarkContentJSON(bookmark, cursorCLIHome: context.cursorCLIHome))
    case "bookmark.delete":
      let ok = try CursorCLIBookmarkPersistence.deleteBookmark(id: try cursorOperationRequiredString(context.variables, "id"), configDir: context.dataDir)
      return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
    case "bookmark.search":
      let limit = max(0, cursorOperationIntValue(context.variables["limit"]) ?? 50)
      let query = try cursorOperationRequiredString(context.variables, "query", fallback: "q")
      let scored = try CursorCLIBookmarkPersistence.searchBookmarkResults(query, limit: limit, configDir: context.dataDir)
      let values = try scored.map { result -> JSONValue in
        .object(["bookmark": try cursorOperationJSONValue(result.bookmark), "score": .number(result.score)])
      }
      return Result(data: .array(values))
    default:
      return nil
    }
  }

  private static func executeBookmarkAddCommand(_ context: ExecutionContext) throws -> Result {
    guard let type = inferredBookmarkType(from: context.variables) else {
      return Result(errors: ["Invalid bookmark type"])
    }
    let bookmark = try CursorCLIBookmarkPersistence.addBookmark(
      type: type,
      sessionId: try cursorOperationRequiredString(context.variables, "sessionId"),
      messageId: cursorOperationStringValue(context.variables["messageId"]),
      name: cursorOperationStringValue(context.variables["name"]),
      description: cursorOperationStringValue(context.variables["description"]) ?? cursorOperationStringValue(context.variables["text"]),
      tags: cursorOperationStringArray(context.variables["tags"]),
      fromMessageId: cursorOperationStringValue(context.variables["fromMessageId"]),
      toMessageId: cursorOperationStringValue(context.variables["toMessageId"]),
      configDir: context.dataDir
    )
    return Result(data: try cursorOperationJSONValue(bookmark))
  }

  private static func executeBookmarkListCommand(_ context: ExecutionContext) throws -> Result {
    let bookmarks = try CursorCLIBookmarkPersistence.listBookmarks(
      sessionId: cursorOperationStringValue(context.variables["sessionId"]),
      type: cursorOperationStringValue(context.variables["type"]).flatMap(CursorCLIBookmarkType.init(rawValue:)),
      tag: cursorOperationStringValue(context.variables["tag"]),
      configDir: context.dataDir
    )
    return Result(data: try cursorOperationJSONValue(bookmarks))
  }

  private static func executeTokenCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "token.create":
      let name = try cursorOperationRequiredString(context.variables, "name")
      let permissionValues = cursorOperationStringArray(context.variables["permissions"])
      let permissions = permissionValues.isEmpty
        ? CursorCLITokenManager.parsePermissionsCSV(cursorOperationStringValue(context.variables["permissions"]) ?? "session:read,session:create")
        : CursorCLITokenManager.normalizePermissions(permissionValues)
      guard !permissions.isEmpty else {
        return Result(errors: ["No valid permissions provided"])
      }
      let rawToken = try CursorCLITokenPersistence.createRawToken(
        name: name,
        permissions: permissions,
        expiresAt: try tokenExpiresAt(from: context.variables),
        configDir: context.configDir
      )
      return Result(data: .string(rawToken))
    case "token.list":
      return Result(data: try cursorOperationJSONValue(CursorCLITokenPersistence.listMetadata(configDir: context.configDir)))
    case "token.revoke":
      return Result(data: .bool(try CursorCLITokenPersistence.revoke(
        id: try cursorOperationRequiredString(context.variables, "id"),
        configDir: context.configDir
      )))
    case "token.rotate":
      guard let token = try CursorCLITokenPersistence.rotate(id: try cursorOperationRequiredString(context.variables, "id"), configDir: context.configDir) else {
        return Result(errors: ["Token not found"])
      }
      return Result(data: .string(token))
    default:
      return nil
    }
  }

  private static func executeFileCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "files.rebuild":
      return Result(data: .object(try rebuildPersistentFileIndex(configDir: context.dataDir, cursorCLIHome: context.cursorCLIHome)))
    case "files.list":
      let sessionId = try cursorOperationRequiredString(context.variables, "sessionId")
      guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: context.cursorCLIHome) else {
        return Result(errors: ["session not found: \(sessionId)"])
      }
      return Result(data: .object(try fileChangeSummaryJSON(for: session)))
    case "files.patches":
      let sessionId = try cursorOperationRequiredString(context.variables, "sessionId")
      guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: context.cursorCLIHome) else {
        return Result(errors: ["session not found: \(sessionId)"])
      }
      return Result(data: .object(try filePatchHistoryJSON(for: session)))
    case "files.find":
      return Result(data: .object(try findPersistentSessionsByFile(
        path: try cursorOperationRequiredString(context.variables, "path"),
        configDir: context.dataDir,
        cursorCLIHome: context.cursorCLIHome
      )))
    default:
      return nil
    }
  }

  private static func executeUtilityCommand(_ context: ExecutionContext) throws -> Result? {
    switch context.commandName {
    case "usage.list", "usage.stats", "usage.summary":
      let sessionsDir = URL(fileURLWithPath: context.cursorCLIHome ?? resolveCursorCLIHome(), isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .path
      let options = CursorCLIUsageStatsOptions(
        cursorCLISessionsDir: sessionsDir,
        recentDays: cursorOperationIntValue(context.variables["recentDays"]) ?? CursorCLIUsageStatsCollector.defaultRecentDays
      )
      let stats = CursorCLIUsageStatsCollector.getCursorCLIUsageStats(options: options)
      return Result(data: try stats.map { try cursorOperationJSONValue($0) } ?? .null)
    case "markdown.tasks":
      let text = cursorOperationStringValue(context.variables["markdown"]) ?? cursorOperationStringValue(context.variables["text"]) ?? ""
      return Result(data: try cursorOperationJSONValue(CursorCLIMarkdown.parseTasks(text)))
    case "markdown.parse":
      let text = cursorOperationStringValue(context.variables["markdown"]) ?? cursorOperationStringValue(context.variables["text"]) ?? ""
      return Result(data: try cursorOperationJSONValue(CursorCLIMarkdown.parseSections(text)))
    case "repo.status", "repo.summary", "repo.analytics":
      let options = sessionListOptions(from: context.variables, cursorCLIHome: context.cursorCLIHome)
      let sessions = CursorCLISessionIndex.listSessions(options: options).sessions
      return Result(data: .object([
        "sessions": .number(Double(sessions.count)),
        "projectPath": cursorOperationStringValue(context.variables["projectPath"]).map(JSONValue.string) ?? .null,
        "branch": cursorOperationStringValue(context.variables["branch"]).map(JSONValue.string) ?? .null
      ]))
    case "repo.files":
      return Result(data: .object(try rebuildPersistentFileIndex(configDir: context.dataDir, cursorCLIHome: context.cursorCLIHome)))
    case "skill.list":
      return Result(data: .object([
        "skills": .array([]),
        "status": .string("degraded"),
        "message": .string("Cursor-managed skills are discoverable only when Cursor exposes them locally.")
      ]))
    case "skill.show":
      return Result(errors: ["Skill not found"])
    case "daemon.status", "daemon.start", "daemon.stop", "daemon.restart":
      return Result(data: .object([
        "running": .bool(false),
        "status": .string("unsupported"),
        "message": .string("Cursor daemon supervision is not available in the Swift runtime.")
      ]))
    case "server.status":
      return Result(data: .object([
        "ok": .bool(true),
        "runtime": .string("swift"),
        "agent": .string("cursor-cli-agent")
      ]))
    case "server.events":
      return Result(data: .object(["events": .array([])]))
    default:
      return nil
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

func sessionJSON(_ session: CursorCLISession) -> JSONValue {
  var object: JSONObject = [
    "id": .string(session.id),
    "rolloutPath": .string(session.rolloutPath),
    "createdAt": .string(cursorOperationISOString(session.createdAt)),
    "updatedAt": .string(cursorOperationISOString(session.updatedAt)),
    "source": .string(session.source.rawValue),
    "modelProvider": session.modelProvider.map(JSONValue.string) ?? .null,
    "cwd": .string(session.cwd),
    "cliVersion": .string(session.cliVersion),
    "title": .string(session.title),
    "firstUserMessage": session.firstUserMessage.map(JSONValue.string) ?? .null,
    "archivedAt": session.archivedAt.map { .string(cursorOperationISOString($0)) } ?? .null,
    "forkedFromId": session.forkedFromId.map(JSONValue.string) ?? .null
  ]
  if let git = session.git {
    object["git"] = .object([
      "branch": git.branch.map(JSONValue.string) ?? .null,
      "sha": git.sha.map(JSONValue.string) ?? .null,
      "originURL": git.originURL.map(JSONValue.string) ?? .null
    ])
  } else {
    object["git"] = .null
  }
  return .object(object)
}

func activityEntryJSON(_ entry: CursorCLIStoredActivityEntry) -> JSONValue {
  var object: JSONObject = [
    "sessionId": .string(entry.sessionId),
    "status": .string(entry.status.rawValue),
    "updatedAt": .string(entry.updatedAt),
    "lastUpdated": .string(entry.updatedAt)
  ]
  if let projectPath = entry.projectPath {
    object["projectPath"] = .string(projectPath)
  }
  return .object(object)
}

let activityHookEvents = ["UserPromptSubmit", "PermissionRequest", "Stop"]
let activityHookCommand = "cursor-cli-agent activity update"

func activityCleanupCutoff(from text: String?) -> Date? {
  guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return Date().addingTimeInterval(-24 * 60 * 60)
  }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if let hours = Double(trimmed), hours >= 0 {
    return Date().addingTimeInterval(-hours * 60 * 60)
  }
  return parseLegacyTimestamp(trimmed)
}

func activitySetupJSON(variables: JSONObject) throws -> JSONObject {
  let settingsURL = activitySettingsURL(variables: variables)
  let dryRun = cursorOperationBoolValue(variables["dryRun"]) ?? false
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
            "command": activityHookCommand
          ]
        ]
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
    "settings": try cursorOperationJSONValue(fromFoundation: settings)
  ]
}

func activitySettingsURL(variables: JSONObject) -> URL {
  if cursorOperationBoolValue(variables["global"]) == true {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".cursor", isDirectory: true)
      .appendingPathComponent("settings.json")
  }
  let projectPath = cursorOperationStringValue(variables["projectPath"]) ?? cursorOperationStringValue(variables["cwd"]) ?? FileManager.default.currentDirectoryPath
  return URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".cursor", isDirectory: true)
    .appendingPathComponent("settings.json")
}

func readActivitySettingsObject(from url: URL) throws -> [String: Any] {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return [:]
  }
  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw CursorCLIGraphQLError.invalidParam("settings.json must contain a JSON object")
  }
  return object
}

func activityHookEntries(_ entries: [Any], containCommand command: String) -> Bool {
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

func bookmarkContentJSON(_ bookmark: CursorCLIBookmark, cursorCLIHome: String?) throws -> JSONValue {
  var object = try cursorOperationJSONObjectValue(cursorOperationJSONValue(bookmark))
  object["bookmark"] = try cursorOperationJSONValue(bookmark)
  object["content"] = .string(bookmark.text ?? bookmark.description ?? bookmark.name ?? "")
  if let session = CursorCLISessionIndex.findSession(id: bookmark.sessionId, cursorCLIHome: cursorCLIHome) {
    object["session"] = sessionJSON(session)
  }
  return .object(object)
}

func inferredBookmarkType(from variables: JSONObject) -> CursorCLIBookmarkType? {
  if let rawType = cursorOperationStringValue(variables["type"]) {
    return CursorCLIBookmarkType(rawValue: rawType)
  }
  if cursorOperationStringValue(variables["messageId"]) != nil {
    return .message
  }
  if cursorOperationStringValue(variables["fromMessageId"]) != nil, cursorOperationStringValue(variables["toMessageId"]) != nil {
    return .range
  }
  return .session
}

func cursorOperationJSONObjectValue(_ value: JSONValue) throws -> JSONObject {
  guard case let .object(object) = value else {
    throw CursorCLIGraphQLError.invalidParam("object")
  }
  return object
}

func cursorOperationISOString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

func extractLegacyCommandInvocation(from document: String, variables: JSONObject) -> (commandName: String?, variables: JSONObject) {
  guard document.contains("command(") else {
    return (nil, variables)
  }
  let commandName = extractGraphQLStringArgument(named: "name", from: document, variables: variables)
  if
    let variableName = firstRegexCapture(in: document, pattern: #"\bparams\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#),
    case let .object(params)? = variables[variableName] {
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

func extractGraphQLStringArgument(named argumentName: String, from document: String, variables: JSONObject) -> String? {
  let escapedName = NSRegularExpression.escapedPattern(for: argumentName)
  if let literal = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*"([^"]+)""#) {
    return literal
  }
  guard let variableName = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#) else {
    return nil
  }
  return cursorOperationStringValue(variables[variableName])
}

func isPingDocument(_ document: String) -> Bool {
  let stripped = document
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stripped == "query { ping }" || stripped == "{ ping }"
}

func executeTypedSessionGraphQLDocument(_ document: String, variables: JSONObject, context: CursorCLIAgentCompatibilityContext) -> CursorCLIGraphQLCommandExecutor.Result? {
  guard document.contains("sessions") || document.contains("session(") || document.contains("searchSessions") else {
    return nil
  }
  guard !document.contains("command(") else {
    return nil
  }
  let explicitConfigDir = cursorOperationStringValue(variables["configDir"]) ?? context.configDir
  let configDir = explicitConfigDir ?? defaultCursorCLIAgentConfigDir()
  let cursorCLIHome = cursorOperationStringValue(variables["cursorCLIHome"]) ?? context.cursorCLIHome
  let authToken = cursorOperationStringValue(variables["authToken"]) ?? cursorOperationStringValue(variables["token"]) ?? context.authToken
  do {
    if let authError = try authorizationError(commandName: "session.list", rawToken: authToken, configDir: configDir) {
      return CursorCLIGraphQLCommandExecutor.Result(errors: [authError])
    }
    if document.contains("searchSessions") {
      let args = graphQLArguments(field: "searchSessions", document: document, variables: variables)
      let query = cursorOperationStringValue(args["query"]) ?? ""
      let listOptions = CursorCLISessionListOptions(
        cursorCLIHome: cursorCLIHome,
        source: cursorOperationStringValue(args["source"]).flatMap { source in
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
        cwd: cursorOperationStringValue(args["projectPath"]) ?? cursorOperationStringValue(args["cwd"]),
        branch: cursorOperationStringValue(args["branch"]),
        limit: Int.max,
        offset: 0,
        sortBy: "createdAt",
        sortOrder: "desc"
      )
      let searchOptions = CursorCLISessionTranscriptSearchOptions(
        caseSensitive: cursorOperationBoolValue(args["caseSensitive"]) ?? false,
        role: cursorOperationStringValue(args["role"])?.lowercased() ?? "both",
        maxBytes: cursorOperationIntValue(args["maxBytes"]),
        maxEvents: nil,
        maxSessions: cursorOperationIntValue(args["maxSessions"]),
        timeoutMs: cursorOperationIntValue(args["timeoutMs"]),
        limit: cursorOperationIntValue(args["limit"]) ?? 50,
        offset: cursorOperationIntValue(args["offset"]) ?? 0
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
          "timedOut": .bool(result.timedOut)
        ])
      ]))
    }
    if document.contains("session(") {
      let args = graphQLArguments(field: "session", document: document, variables: variables)
      guard let id = cursorOperationStringValue(args["id"]), let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome) else {
        return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .null]))
      }
      var sessionObject = typedSessionJSON(session)
      if document.contains("history") {
        sessionObject["history"] = typedSessionHistoryJSON(session: session, args: graphQLArguments(field: "history", document: document, variables: variables))
      }
      if document.contains("grep") {
        let grepArgs = graphQLArguments(field: "grep", document: document, variables: variables)
        let query = cursorOperationStringValue(grepArgs["query"]) ?? ""
        let searchOptions = CursorCLISessionTranscriptSearchOptions(
          caseSensitive: cursorOperationBoolValue(grepArgs["caseSensitive"]) ?? false,
          role: cursorOperationStringValue(grepArgs["role"])?.lowercased() ?? "both",
          maxBytes: cursorOperationIntValue(grepArgs["maxBytes"]),
          timeoutMs: cursorOperationIntValue(grepArgs["timeoutMs"]),
          limit: cursorOperationIntValue(grepArgs["maxMatches"]) ?? 50
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
          "timedOut": .bool(result.timedOut)
        ])
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .object(sessionObject)]))
    }
    if document.contains("sessions") {
      let args = graphQLArguments(field: "sessions", document: document, variables: variables)
      let options = sessionListOptions(from: args, cursorCLIHome: cursorCLIHome)
      var sessions = CursorCLISessionIndex.listSessions(options: options).sessions
      if let status = cursorOperationStringValue(args["status"]), status != "completed" {
        sessions = []
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object([
        "sessions": .object([
          "total": .number(Double(sessions.count)),
          "nodes": .array(sessions.map { .object(typedSessionJSON($0)) })
        ])
      ]))
    }
    return nil
  } catch {
    return CursorCLIGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

func typedSessionJSON(_ session: CursorCLISession) -> JSONObject {
  [
    "id": .string(session.id),
    "projectPath": .string(session.cwd),
    "cwd": .string(session.cwd),
    "status": .string("completed"),
    "createdAt": .string(cursorOperationISOString(session.createdAt)),
    "updatedAt": .string(cursorOperationISOString(session.updatedAt)),
    "messageCount": .number(Double((try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath).count) ?? 0))
  ]
}

func typedSessionHistoryJSON(session: CursorCLISession, args: JSONObject) -> JSONValue {
  let offset = max(0, cursorOperationIntValue(args["offset"]) ?? 0)
  let limit = max(0, cursorOperationIntValue(args["limit"]) ?? 50)
  let messages = (try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath)) ?? []
  let start = min(offset, messages.count)
  let end = min(start + limit, messages.count)
  let events = messages[start..<end].map { message -> JSONValue in
    .object([
      "type": .string(message.role),
      "uuid": .null,
      "timestamp": .string(message.timestamp),
      "content": message.text.map(JSONValue.string) ?? .null,
      "raw": message.line.payload
    ])
  }
  return .object([
    "total": .number(Double(messages.count)),
    "offset": .number(Double(offset)),
    "limit": .number(Double(limit)),
    "events": .array(Array(events)),
    "tokenUsage": .object(["input": .number(0), "output": .number(0)])
  ])
}

func graphQLArguments(field: String, document: String, variables: JSONObject) -> JSONObject {
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
    } else if let cursorOperationIntValue = Int(rawValue) {
      result[name] = .number(Double(cursorOperationIntValue))
    } else {
      result[name] = .string(rawValue.lowercased())
    }
  }
  return result
}

func extractInlineGraphQLParams(from document: String) -> JSONObject? {
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

func matchingBrace(in text: String, open: String.Index) -> String.Index? {
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

func quoteGraphQLObjectKeys(_ literal: String) -> String {
  literal.replacingOccurrences(
    of: #"([,{]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
    with: #"$1"$2":"#,
    options: .regularExpression
  )
}

func firstRegexCapture(in text: String, pattern: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
    return nil
  }
  return String(text[capture])
}

func shorthandOperation(for command: String) -> String {
  if command == "session.watch" {
    return "subscription"
  }
  return mutationCommandNames.contains(command) ? "mutation" : "query"
}

func escapeGraphQLString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

let mutationCommandNames: Set<String> = [
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
  "files.rebuild"
]

func rolloutLineJSON(_ line: CursorCLIRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload
  ])
}

func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let cursorCLI = probeToolVersion(cursorOperationExecutableName(from: variables), arguments: ["--version"])
  let includeGit = cursorOperationBoolValue(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "cursorCLI": .object(cursorCLI),
    "git": includeGit ? .object(probeToolVersion(cursorOperationStringValue(variables["gitBinary"]) ?? "git", arguments: ["--version"])) : .null
  ]
}

func probeToolVersion(_ executable: String, arguments: [String]) -> JSONObject {
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
      "stderr": .string(err.trimmingCharacters(in: .whitespacesAndNewlines))
    ]
  } catch {
    return [
      "available": .bool(false),
      "version": .null,
      "error": .string(String(describing: error))
    ]
  }
}

func resolveExecutableURL(_ executable: String) -> URL {
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

func processExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "stdout": .string(result.stdout),
    "stderr": .string(result.stderr),
    "exitCode": .number(Double(result.exitCode)),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func processHandleJSON(_ process: CursorCLIProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func sessionExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

func extractSessionId(from lines: [CursorCLIRolloutLine]) -> String? {
  for line in lines {
    guard let payload = cursorOperationFileChangeObject(line.payload) else {
      continue
    }
    if let sessionId = cursorOperationFileChangeString(payload["session_id"]) ?? cursorOperationFileChangeString(payload["sessionId"]) {
      return sessionId
    }
    if let meta = cursorOperationFileChangeObject(payload["meta"]), let id = cursorOperationFileChangeString(meta["id"]) {
      return id
    }
  }
  return nil
}

func cursorOperationJSONValue<Value: Encodable>(_ value: Value?) throws -> JSONValue {
  guard let value else {
    return .null
  }
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationJSONValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationJSONValue(fromFoundation value: Any) throws -> JSONValue {
  let data = try JSONSerialization.data(withJSONObject: value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationRequiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = cursorOperationStringValue(object[key]), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
  }
  return value
}

func cursorOperationRequiredString(_ object: JSONObject, _ key: String, fallback: String) throws -> String {
  if let value = cursorOperationStringValue(object[key]), !value.isEmpty {
    return value
  }
  if let value = cursorOperationStringValue(object[fallback]), !value.isEmpty {
    return value
  }
  throw CursorCLIGraphQLError.missingVariable(key)
}

func cursorOperationRequiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = cursorOperationStringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
  }
  return value
}

func tokenExpiresAt(from object: JSONObject) throws -> String? {
  if let expiresAt = cursorOperationStringValue(object["expiresAt"]), !expiresAt.isEmpty {
    return expiresAt
  }
  guard let expiresIn = cursorOperationStringValue(object["expiresIn"]) ?? cursorOperationStringValue(object["expires"]) else {
    return nil
  }
  do {
    let seconds = try CursorCLIDurationParser.seconds(expiresIn)
    return legacyTokenTimestamp(Date().addingTimeInterval(TimeInterval(seconds)))
  } catch {
    throw CursorCLIGraphQLError.invalidParam("--expires=\(expiresIn)")
  }
}

func legacyTokenTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

func parseLegacyTimestamp(_ text: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: text) {
    return date
  }
  return ISO8601DateFormatter().date(from: text)
}

func resolveQueueId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw CursorCLIGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

func groupSession(from variables: JSONObject) throws -> CursorCLIGroupSession {
  if let sessionObject = cursorOperationObjectValue(variables["session"]) {
    return CursorCLIGroupSession(
      id: try cursorOperationRequiredString(sessionObject, "id"),
      projectPath: cursorOperationStringValue(sessionObject["projectPath"]),
      prompt: cursorOperationStringValue(sessionObject["prompt"]),
      status: cursorOperationStringValue(sessionObject["status"]),
      dependsOn: cursorOperationStringArray(sessionObject["dependsOn"]),
      createdAt: cursorOperationStringValue(sessionObject["createdAt"])
    )
  }
  return CursorCLIGroupSession(
    id: try cursorOperationRequiredString(variables, "sessionId"),
    projectPath: cursorOperationStringValue(variables["projectPath"]),
    prompt: cursorOperationStringValue(variables["prompt"]),
    status: cursorOperationStringValue(variables["status"]),
    dependsOn: cursorOperationStringArray(variables["dependsOn"]),
    createdAt: cursorOperationStringValue(variables["createdAt"])
  )
}

func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
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

func expandHomePath(_ path: String) -> String {
  if path == "~" {
    return FileManager.default.homeDirectoryForCurrentUser.path
  }
  if path.hasPrefix("~/") {
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
  }
  return path
}

func cursorConfigPath(for context: CursorCLIAgentCompatibilityContext) -> String? {
  guard let cursorCLIHome = context.cursorCLIHome else {
    return nil
  }
  return URL(fileURLWithPath: cursorCLIHome, isDirectory: true)
    .appendingPathComponent("account.json")
    .path
}

func cursorCredentialsPath(for context: CursorCLIAgentCompatibilityContext) -> String {
  let home = context.cursorCLIHome ?? resolveCursorCLIHome()
  return URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("credentials.json")
    .path
}

func cursorReadiness(context: CursorCLIAgentCompatibilityContext, model: String?) -> JSONObject {
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
    "message": .string(message)
  ]
  if let credentials {
    auth["expiresAt"] = .string(cursorOperationISOString(credentials.expiresAt))
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
      "command": .string("cursor-agent")
    ]),
    "model": .object([
      "requested": model.map(JSONValue.string) ?? .null,
      "checked": .bool(false),
      "available": .bool(false),
      "timedOut": .bool(false),
      "stdout": .string(""),
      "stderr": .string(""),
      "commandArgs": .array(model.map { ["--print", "--model", $0] }?.map(JSONValue.string) ?? []),
      "message": .string(model != nil && !available ? "Skipping model probe because credentials are unavailable." : "")
    ])
  ]
}

struct CursorCredentialsReadiness {
  var expiresAt: Date
  var subscriptionType: String?
  var scopes: [String]
  var rateLimitTier: String?
}

func readCursorCredentials(path: String) -> CursorCredentialsReadiness? {
  guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value,
    let oauth = cursorOperationObjectValue(object["cursorOauth"]),
    let expiresMs = cursorOperationNumberValue(oauth["expiresAt"])
  else {
    return nil
  }
  return CursorCredentialsReadiness(
    expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
    subscriptionType: cursorOperationStringValue(oauth["subscriptionType"]),
    scopes: cursorOperationStringArray(oauth["scopes"]),
    rateLimitTier: cursorOperationStringValue(oauth["rateLimitTier"])
  )
}

func authorizationError(commandName: String, rawToken: String?, configDir: String) throws -> String? {
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

func requiredPermission(for commandName: String) -> String? {
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

func executeQueueMutation(commandName: String, variables: JSONObject, configDir: String, cursorCLIHome: String?) -> CursorCLIGraphQLCommandExecutor.Result {
  do {
    var config = try CursorCLIQueuePersistence.load(configDir: configDir)
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(config.queues)
    let requestedId = try cursorOperationRequiredString(variables, "id")
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
      if let rawStatus = cursorOperationStringValue(variables["status"]) {
        guard let parsedStatus = CursorCLIQueuePromptStatus(rawValue: rawStatus) else {
          return CursorCLIGraphQLCommandExecutor.Result(errors: ["status must be one of: pending, running, completed, failed"])
        }
        status = parsedStatus
      } else {
        status = nil
      }
      let mode = (cursorOperationStringValue(variables["sessionMode"]) ?? cursorOperationStringValue(variables["mode"])).flatMap(CursorCLIQueueCommandMode.legacy)
      ok = repository.updatePrompt(
        queueId: id,
        promptId: commandId,
        prompt: cursorOperationStringValue(variables["prompt"]),
        status: status,
        mode: mode,
        resultExitCode: cursorOperationIntValue(variables["resultExitCode"])
      )
    case "queue.remove":
      ok = repository.removePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue))
    case "queue.move":
      if let from = cursorOperationIntValue(variables["from"]), let to = cursorOperationIntValue(variables["to"]) {
        ok = repository.movePrompt(queueId: id, from: from, to: to)
      } else {
        ok = repository.movePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue), toIndex: cursorOperationIntValue(variables["toIndex"]) ?? 0)
      }
    case "queue.mode":
      if let rawMode = cursorOperationStringValue(variables["mode"]) {
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
      let executableName = cursorOperationExecutableName(from: variables)
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
      let startedAt = cursorOperationISOString(Date())
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
        let promptStartedAt = cursorOperationISOString(Date())
        config.queues[queueIndex].currentIndex = promptIndex
        config.queues[queueIndex].prompts[promptIndex].status = .running
        config.queues[queueIndex].prompts[promptIndex].startedAt = promptStartedAt
        config.queues[queueIndex].prompts[promptIndex].updatedAt = promptStartedAt
        config.queues[queueIndex].updatedAt = promptStartedAt
        try CursorCLIQueuePersistence.save(config, configDir: configDir)
        pendingIds.removeAll { $0 == prompt.id }
        events.append(queueEvent(type: "prompt_started", queueId: id, promptId: prompt.id, current: prompt.id, pending: pendingIds))
        var options = try cursorOperationProcessOptions(from: variables, cursorCLIHome: cursorCLIHome)
        options.cwd = queueProjectPath
        options.images = Array(Set(prompt.imagePaths + options.images)).sorted()
        let shouldResume = (prompt.mode ?? .continueMode) != .new && config.queues[queueIndex].currentSessionId != nil
        let execution = shouldResume
          ? manager.spawnResume(sessionId: config.queues[queueIndex].currentSessionId!, prompt: prompt.prompt, options: options)
          : manager.spawnExec(prompt: prompt.prompt, options: options)
        let result = execution.result
        let lines = result.stdout.split(separator: "\n").compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
        let sessionId = extractSessionId(from: lines) ?? config.queues[queueIndex].currentSessionId ?? execution.process.id
        let completedAt = cursorOperationISOString(Date())
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
      let finishedAt = cursorOperationISOString(Date())
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

func addQueuePromptLegacy(variables: JSONObject, imagePaths: [String], configDir: String) throws -> CursorCLIQueuePrompt {
  var config = try CursorCLIQueuePersistence.load(configDir: configDir)
  let idOrName = try cursorOperationRequiredString(variables, "id")
  guard let queueIndex = config.queues.firstIndex(where: { $0.id == idOrName || $0.name == idOrName }) else {
    throw CursorCLIGraphQLError.missingVariable("Queue not found")
  }
  guard config.queues[queueIndex].status == .pending || config.queues[queueIndex].status == .paused else {
    throw CursorCLIGraphQLError.missingVariable("Queue is not editable")
  }
  let mode = cursorOperationStringValue(variables["sessionMode"]) ?? cursorOperationStringValue(variables["mode"])
  let item = CursorCLIQueuePrompt(
    id: UUID().uuidString,
    prompt: try cursorOperationRequiredString(variables, "prompt"),
    status: .pending,
    mode: mode.flatMap(CursorCLIQueueCommandMode.legacy) ?? .continueMode,
    imagePaths: imagePaths,
    createdAt: ISO8601DateFormatter().string(from: Date())
  )
  let insertionIndex: Int
  if let position = cursorOperationIntValue(variables["position"]) {
    insertionIndex = min(max(position, 0), config.queues[queueIndex].prompts.count)
  } else {
    insertionIndex = config.queues[queueIndex].prompts.count
  }
  config.queues[queueIndex].prompts.insert(item, at: insertionIndex)
  try CursorCLIQueuePersistence.save(config, configDir: configDir)
  return item
}

func resolveQueuePromptId(variables: JSONObject, queue: CursorCLIQueue) throws -> String {
  if let commandId = cursorOperationStringValue(variables["commandId"]) ?? cursorOperationStringValue(variables["promptId"]) {
    return commandId
  }
  if let index = cursorOperationIntValue(variables["index"]), queue.prompts.indices.contains(index) {
    return queue.prompts[index].id
  }
  throw CursorCLIGraphQLError.missingVariable("commandId")
}

func runGroupEvents(group: CursorCLIGroup, prompt: String, variables: JSONObject, cursorCLIHome: String?) throws -> [JSONObject] {
  guard !group.paused else {
    throw CursorCLIGraphQLError.missingVariable("group is paused: \(group.id)")
  }
  var events: [JSONObject] = []
  var completed: [String] = []
  var failed: [String] = []
  var pending = group.sessionIds
  var running: [String] = []
  let maxConcurrent = max(1, cursorOperationIntValue(variables["maxConcurrent"]) ?? 3)
  let executableName = cursorOperationExecutableName(from: variables)
  let options = try cursorOperationProcessOptions(from: variables, cursorCLIHome: cursorCLIHome)
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

func queueEvent(type: String, queueId: String, promptId: String? = nil, exitCode: Int? = nil, current: String? = nil, completed: [String] = [], pending: [String] = [], failed: [String] = []) -> JSONObject {
  var event: JSONObject = [
    "type": .string(type),
    "queueId": .string(queueId),
    "completed": .array(completed.map(JSONValue.string)),
    "pending": .array(pending.map(JSONValue.string)),
    "failed": .array(failed.map(JSONValue.string))
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

func groupEvent(type: String, groupId: String, sessionId: String? = nil, exitCode: Int? = nil, running: [String] = [], completed: [String] = [], failed: [String] = [], pending: [String] = []) -> JSONObject {
  var event: JSONObject = [
    "type": .string(type),
    "groupId": .string(groupId),
    "running": .array(running.map(JSONValue.string)),
    "completed": .array(completed.map(JSONValue.string)),
    "failed": .array(failed.map(JSONValue.string)),
    "pending": .array(pending.map(JSONValue.string))
  ]
  if let sessionId {
    event["sessionId"] = .string(sessionId)
  }
  if let exitCode {
    event["exitCode"] = .number(Double(exitCode))
  }
  return event
}

final class GroupRunResultStore: @unchecked Sendable {
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

func sessionListOptions(from variables: JSONObject, cursorCLIHome: String?) -> CursorCLISessionListOptions {
  CursorCLISessionListOptions(
    cursorCLIHome: cursorCLIHome,
    source: cursorOperationStringValue(variables["source"]).flatMap(CursorCLISessionSource.init(rawValue:)),
    cwd: cursorOperationStringValue(variables["cwd"]) ?? cursorOperationStringValue(variables["projectPath"]),
    branch: cursorOperationStringValue(variables["branch"]),
    limit: cursorOperationIntValue(variables["limit"]) ?? 50,
    offset: cursorOperationIntValue(variables["offset"]) ?? 0,
    sortBy: cursorOperationStringValue(variables["sortBy"]) ?? "createdAt",
    sortOrder: cursorOperationStringValue(variables["sortOrder"]) ?? "desc"
  )
}

func transcriptSearchOptions(from variables: JSONObject) -> CursorCLISessionTranscriptSearchOptions {
  CursorCLISessionTranscriptSearchOptions(
    caseSensitive: cursorOperationBoolValue(variables["caseSensitive"]) ?? false,
    role: cursorOperationStringValue(variables["role"]) ?? "both",
    maxBytes: cursorOperationIntValue(variables["maxBytes"]).map { max(0, $0) },
    maxEvents: cursorOperationIntValue(variables["maxEvents"]).map { max(0, $0) },
    maxSessions: cursorOperationIntValue(variables["maxSessions"]).map { max(0, $0) },
    timeoutMs: cursorOperationIntValue(variables["timeoutMs"]).map { max(0, $0) },
    limit: max(0, cursorOperationIntValue(variables["limit"]) ?? 50),
    offset: max(0, cursorOperationIntValue(variables["offset"]) ?? 0)
  )
}

func rebuildFileIndex(cursorCLIHome: String?) throws -> CursorCLIFileChangeIndex {
  let lines = discoverRolloutPaths(cursorCLIHome: cursorCLIHome).flatMap { path in
    (try? CursorCLIRolloutReader.readRollout(path: path)) ?? []
  }
  return CursorCLIFileChangeIndex.rebuild(from: lines)
}

func fileChangeArray(_ value: JSONValue?) -> [CursorCLIFileChange]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap { entry in
    guard let object = cursorOperationFileChangeObject(entry), let path = cursorOperationFileChangeString(object["path"]) else {
      return nil
    }
    return CursorCLIFileChange(
      path: path,
      operation: CursorCLIFileOperation(rawValue: cursorOperationFileChangeString(object["operation"]) ?? "") ?? .modified,
      source: CursorCLIFileChangeSource(rawValue: cursorOperationFileChangeString(object["source"]) ?? "") ?? .shell,
      previousPath: cursorOperationFileChangeString(object["previousPath"] ?? object["previous_path"] ?? object["oldPath"] ?? object["from"]),
      command: cursorOperationFileChangeString(object["command"]),
      patch: cursorOperationFileChangeString(object["patch"])
    )
  }
}

func cursorOperationFileChangeObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

func cursorOperationFileChangeString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func cursorOperationStringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values)? = value else {
    return nil
  }
  return values.compactMap(cursorOperationFileChangeString)
}

func cursorOperationNumberValue(_ value: JSONValue?) -> Double? {
  guard case let .number(number) = value else {
    return nil
  }
  return number
}

func cursorOperationIntValue(_ value: JSONValue?) -> Int? {
  guard let number = cursorOperationNumberValue(value) else {
    return nil
  }
  return Int(number)
}

func cursorOperationNonNegativeUInt64Value(_ value: JSONValue?) -> UInt64? {
  guard let int = cursorOperationIntValue(value) else {
    return nil
  }
  return UInt64(max(0, int))
}

func cursorOperationStringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func cursorOperationStringValue(_ value: Any?) -> String? {
  value as? String
}

func cursorOperationObjectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

func cursorOperationStringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values) = value else {
    return []
  }
  return values.compactMap(cursorOperationStringValue)
}

func cursorOperationParseLooseJSONValue(_ text: String) throws -> JSONValue {
  if let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
    return value
  }
  return .string(text)
}

func cursorOperationProcessOptions(from object: JSONObject, cursorCLIHome defaultCursorCLIHome: String? = nil) throws -> CursorCLIProcessOptions {
  if let sandbox = cursorOperationStringValue(object["sandbox"]) {
    try cursorOperationValidateStringUnion(sandbox, key: "sandbox", allowed: ["enabled", "disabled", "read-only", "workspace-write", "danger-full-access"])
  }
  if let streamGranularity = cursorOperationStringValue(object["streamGranularity"]) {
    try cursorOperationValidateStringUnion(streamGranularity, key: "streamGranularity", allowed: ["event", "char"])
  }
  let images = try cursorOperationStrictStringArray(object["images"], key: "images")
  let imagePaths = try cursorOperationStrictStringArray(object["imagePaths"], key: "imagePaths")
  let additionalArguments = try cursorOperationStrictStringArray(object["additionalArguments"], key: "additionalArguments")
  let additionalArgs = try cursorOperationStrictStringArray(object["additionalArgs"], key: "additionalArgs")
  let environment = try cursorOperationStrictStringDictionary(object["environment"], key: "environment")
  let environmentVariables = try cursorOperationStrictStringDictionary(object["environmentVariables"], key: "environmentVariables")
  return CursorCLIProcessOptions(
    model: cursorOperationStringValue(object["model"]),
    cwd: cursorOperationStringValue(object["cwd"]),
    sandbox: cursorOperationStringValue(object["sandbox"]),
    approvalMode: cursorOperationStringValue(object["approvalMode"]),
    mode: cursorOperationStringValue(object["mode"]).flatMap(CursorCLIMode.init(rawValue:)),
    fullAuto: cursorOperationBoolValue(object["fullAuto"]) ?? false,
    trust: cursorOperationBoolValue(object["trust"]) ?? false,
    force: cursorOperationBoolValue(object["force"]) ?? false,
    yolo: cursorOperationBoolValue(object["yolo"]) ?? false,
    streamPartialOutput: cursorOperationBoolValue(object["streamPartialOutput"]) ?? false,
    approveMcps: cursorOperationBoolValue(object["approveMcps"]) ?? false,
    worktree: cursorOperationStringValue(object["worktree"]),
    worktreeBase: cursorOperationStringValue(object["worktreeBase"]),
    skipWorktreeSetup: cursorOperationBoolValue(object["skipWorktreeSetup"]) ?? false,
    images: images.isEmpty ? imagePaths : images,
    configOverrides: try cursorOperationStrictStringArray(object["configOverrides"], key: "configOverrides"),
    additionalArguments: additionalArguments.isEmpty ? additionalArgs : additionalArguments,
    environmentVariables: environment.isEmpty ? environmentVariables : environment,
    systemPrompt: cursorOperationStringValue(object["systemPrompt"]),
    cursorCLIHome: cursorOperationStringValue(object["cursorCLIHome"]) ?? defaultCursorCLIHome,
    streamGranularity: cursorOperationStringValue(object["streamGranularity"]),
    forwardApprovalMode: false
  )
}

func cursorOperationValidateStringUnion(_ value: String, key: String, allowed: Set<String>) throws {
  guard allowed.contains(value) else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
  }
}

func cursorOperationStrictStringArray(_ value: JSONValue?, key: String) throws -> [String] {
  guard let value else {
    return []
  }
  guard case let .array(values) = value else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be an array of strings")
  }
  return try values.enumerated().map { index, item in
    guard let string = cursorOperationStringValue(item) else {
      throw CursorCLIGraphQLError.invalidParam("\(key)[\(index)] must be a string")
    }
    return string
  }
}

func cursorOperationExecutableName(from object: JSONObject) -> String {
  cursorOperationStringValue(object["executableName"])
    ?? cursorOperationStringValue(object["cursorBinary"])
    ?? cursorOperationStringValue(object["cursorCLIBinary"])
    ?? "cursor-agent"
}

func cursorOperationStrictStringDictionary(_ value: JSONValue?, key: String) throws -> [String: String] {
  guard let value else {
    return [:]
  }
  guard case let .object(object) = value else {
    throw CursorCLIGraphQLError.invalidParam("\(key) must be an object with string values")
  }
  var result: [String: String] = [:]
  for (key, value) in object {
    guard let string = cursorOperationStringValue(value) else {
      throw CursorCLIGraphQLError.invalidParam("\(key) must be a string")
    }
    result[key] = string
  }
  return result
}

func cursorOperationBoolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

func extractCommandName(from document: String) -> String? {
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
