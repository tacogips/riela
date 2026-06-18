import Foundation
import RielaCore

public enum ClaudeCodeGraphQLCommandExecutor {
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
    "session.searchTranscript", "session.run", "session.create", "session.cancel", "session.pause",
    "session.resume", "session.fork", "session.watch",
    "activity.list", "activity.get", "activity.status", "activity.update", "activity.cleanup", "activity.setup",
    "group.create", "group.list", "group.show", "group.get", "group.watch", "group.add", "group.addSession", "group.remove", "group.removeSession", "group.pause", "group.resume", "group.delete", "group.run",
    "queue.create", "queue.add", "queue.addCommand", "queue.show", "queue.get", "queue.list",
    "queue.pause", "queue.resume", "queue.stop", "queue.delete", "queue.update", "queue.updateCommand",
    "queue.remove", "queue.removeCommand", "queue.move", "queue.mode", "queue.run",
    "bookmark.add", "bookmark.list", "bookmark.get", "bookmark.show", "bookmark.content", "bookmark.delete", "bookmark.search",
    "token.create", "token.list", "token.revoke", "token.rotate",
    "files.list", "files.patches", "files.find", "files.rebuild",
    "model.check"
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
      throw ClaudeCodeGraphQLError.variablesMustBeObject
    }
    return object
  }

  public static func parseParams(_ values: [String]) throws -> JSONObject {
    var params: JSONObject = [:]
    for value in values {
      let pieces = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard pieces.count == 2 else {
        throw ClaudeCodeGraphQLError.invalidParam(value)
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
      throw ClaudeCodeGraphQLError.variablesMustBeObject
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

  public static func watchSession(id: String, startOffset: UInt64? = nil, claudeCodeHome: String? = nil) throws -> ClaudeCodeSessionWatchSubscription {
    guard let session = findSession(id: id, claudeCodeHome: claudeCodeHome) else {
      throw ClaudeCodeGraphQLError.missingVariable("Session not found")
    }
    return ClaudeCodeSessionWatchSubscription(rolloutPath: session.rolloutPath, startOffset: startOffset)
  }

  public static func execute(command: String, variables: JSONObject = [:], context: ClaudeCodeAgentCompatibilityContext = ClaudeCodeAgentCompatibilityContext()) -> Result {
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
      let explicitConfigDir = claudeCodeStringValue(effectiveVariables["configDir"]) ?? context.configDir
      let configDir = explicitConfigDir ?? defaultClaudeCodeAgentConfigDir()
      let dataDir = explicitConfigDir ?? defaultClaudeCodeAgentDataDir()
      let activityDataDir = explicitConfigDir ?? ClaudeCodeActivityStore.defaultDataDir()
      let claudeCodeHome = claudeCodeStringValue(effectiveVariables["claudeCodeHome"]) ?? context.claudeCodeHome
      let authToken = claudeCodeStringValue(effectiveVariables["authToken"]) ?? claudeCodeStringValue(effectiveVariables["token"]) ?? context.authToken
      if let authError = try authorizationError(commandName: commandName, rawToken: authToken, configDir: configDir) {
        return Result(errors: [authError])
      }
      let executionContext = GraphQLExecutionContext(
        configDir: configDir,
        dataDir: dataDir,
        activityDataDir: activityDataDir,
        claudeCodeHome: claudeCodeHome
      )
      return try executeSupportedCommand(commandName, variables: effectiveVariables, context: executionContext)
    } catch {
      return Result(errors: [String(describing: error)])
    }
  }

  private struct GraphQLExecutionContext {
    var configDir: String
    var dataDir: String
    var activityDataDir: String
    var claudeCodeHome: String?
  }

  private static func executeSupportedCommand(
    _ commandName: String,
    variables: JSONObject,
    context: GraphQLExecutionContext
  ) throws -> Result {
    if commandName == "version.get" {
      return Result(data: .object(toolVersionsJSON(variables: variables)))
    }
    if commandName == "model.check" {
      return try executeModelCheck(variables: variables, claudeCodeHome: context.claudeCodeHome)
    }
    if commandName.hasPrefix("session.") {
      return try executeSessionCommand(commandName, variables: variables, claudeCodeHome: context.claudeCodeHome)
    }
    if commandName.hasPrefix("activity.") {
      return try executeActivityCommand(commandName, variables: variables, dataDir: context.activityDataDir)
    }
    if commandName.hasPrefix("group.") {
      return try executeGroupCommand(commandName, variables: variables, configDir: context.dataDir, claudeCodeHome: context.claudeCodeHome)
    }
    if commandName.hasPrefix("queue.") {
      return try executeQueueCommand(commandName, variables: variables, configDir: context.dataDir, claudeCodeHome: context.claudeCodeHome)
    }
    if commandName.hasPrefix("bookmark.") {
      return try executeBookmarkCommand(commandName, variables: variables, configDir: context.dataDir, claudeCodeHome: context.claudeCodeHome)
    }
    if commandName.hasPrefix("token.") {
      return try executeTokenCommand(commandName, variables: variables, configDir: context.configDir)
    }
    if commandName.hasPrefix("files.") {
      return try executeFilesCommand(commandName, variables: variables, configDir: context.dataDir, claudeCodeHome: context.claudeCodeHome)
    }
    return Result(errors: ["Unhandled command: \(commandName)"])
  }

  private static func executeModelCheck(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let model = try requiredString(variables, "model")
    var options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
    options.model = model
    if options.additionalArguments.isEmpty {
      options.additionalArguments = ["--skip-git-repo-check", "--ephemeral"]
    }
    let manager = ClaudeCodeProcessManager(executableName: executableName(from: variables))
    let result = manager.spawnExec(prompt: claudeCodeStringValue(variables["prompt"]) ?? "Reply with exactly OK.", options: options)
    return Result(data: .object([
      "model": .string(model),
      "ok": .bool(result.result.exitCode == 0),
      "exitCode": .number(Double(result.result.exitCode)),
      "stdout": .string(result.result.stdout),
      "stderr": .string(result.result.stderr)
    ]))
  }

  private static func executeSessionCommand(
    _ commandName: String,
    variables: JSONObject,
    claudeCodeHome: String?
  ) throws -> Result {
    switch commandName {
    case "session.list":
      let options = sessionListOptions(from: variables, claudeCodeHome: claudeCodeHome)
      let result = ClaudeCodeSessionIndex.listSessions(options: options)
      return Result(data: .array(result.sessions.map(sessionJSON)))
    case "session.show":
      return try executeSessionShow(variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.messages":
      return try executeSessionMessages(variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.search", "session.searchTranscript":
      return try executeSessionSearch(commandName, variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.run", "session.create":
      return try executeSessionStart(variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.resume":
      return try executeSessionResume(variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.cancel", "session.pause":
      return try executeSessionKill(variables: variables)
    case "session.fork":
      return try executeSessionFork(variables: variables, claudeCodeHome: claudeCodeHome)
    case "session.watch":
      return try executeSessionWatch(variables: variables, claudeCodeHome: claudeCodeHome)
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeSessionShow(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let id = try requiredString(variables, "id")
    guard let session = ClaudeCodeSessionCommands.show(sessionId: id, claudeCodeHome: claudeCodeHome) else {
      return Result(errors: ["Session not found"])
    }
    return Result(data: sessionJSON(session))
  }

  private static func executeSessionMessages(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let id = try requiredString(variables, "id", fallback: "sessionId")
    guard let session = ClaudeCodeSessionIndex.findSession(id: id, claudeCodeHome: claudeCodeHome) else {
      return Result(errors: ["Session not found"])
    }
    let lines = try ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath)
    return Result(data: .object([
      "sessionId": .string(session.id),
      "messages": .array(lines.map(rolloutLineJSON))
    ]))
  }

  private static func executeSessionSearch(
    _ commandName: String,
    variables: JSONObject,
    claudeCodeHome: String?
  ) throws -> Result {
    let query = try requiredString(variables, "query")
    if commandName == "session.searchTranscript", let id = claudeCodeStringValue(variables["id"]) {
      return try executeSingleSessionTranscriptSearch(id: id, query: query, variables: variables, claudeCodeHome: claudeCodeHome)
    }
    let result = try ClaudeCodeSessionIndex.searchSessions(
      query: query,
      options: sessionListOptions(from: variables, claudeCodeHome: claudeCodeHome),
      searchOptions: transcriptSearchOptions(from: variables)
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

  private static func executeSingleSessionTranscriptSearch(
    id: String,
    query: String,
    variables: JSONObject,
    claudeCodeHome: String?
  ) throws -> Result {
    guard let session = ClaudeCodeSessionIndex.findSession(id: id, claudeCodeHome: claudeCodeHome) else {
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
    let search = try ClaudeCodeSessionIndex.searchSessionTranscriptDetailed(
      session: session,
      query: query,
      options: transcriptSearchOptions(from: variables)
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

  private static func executeSessionStart(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let prompt = try requiredNonBlankString(variables, "prompt")
    let manager = ClaudeCodeProcessManager(executableName: executableName(from: variables))
    let options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
    let result = manager.spawnExec(prompt: prompt, options: options)
    return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
  }

  private static func executeSessionResume(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let id = try requiredString(variables, "id")
    let manager = ClaudeCodeProcessManager(executableName: executableName(from: variables))
    let options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
    let result = manager.spawnResume(sessionId: id, prompt: claudeCodeStringValue(variables["prompt"]), options: options)
    return Result(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
  }

  private static func executeSessionKill(variables: JSONObject) throws -> Result {
    let id = try requiredString(variables, "id")
    let manager = ClaudeCodeProcessManager(executableName: executableName(from: variables))
    let killed = manager.kill(id: id)
    return Result(data: .object([
      "id": .string(id),
      "success": .bool(killed),
      "ok": .bool(killed),
      "status": .string(killed ? "cancelled" : "not_found"),
      "degraded": .bool(!killed)
    ]))
  }

  private static func executeSessionFork(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let id = try requiredString(variables, "id")
    let manager = ClaudeCodeProcessManager(executableName: executableName(from: variables))
    let options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
    let process = manager.spawnForkProcess(sessionId: id, nthMessage: claudeCodeIntValue(variables["nthMessage"]), options: options)
    return Result(data: .object(processHandleJSON(process)))
  }

  private static func executeSessionWatch(variables: JSONObject, claudeCodeHome: String?) throws -> Result {
    let id = try requiredString(variables, "id")
    let subscription = try watchSession(
      id: id,
      startOffset: claudeCodeNonNegativeUInt64Value(variables["startOffset"]) ?? 0,
      claudeCodeHome: claudeCodeHome
    )
    let lines = subscription.drainAvailable()
    subscription.cancel()
    return Result(data: .object(["events": .array(lines.map(rolloutLineJSON))]))
  }

  private static func executeActivityCommand(_ commandName: String, variables: JSONObject, dataDir: String) throws -> Result {
    switch commandName {
    case "activity.list":
      let store = ClaudeCodeActivityStore(dataDir: dataDir)
      var entries = try store.load()
      if let status = claudeCodeStringValue(variables["status"]).flatMap(ClaudeCodeActivityStatusValue.init(rawValue:)) {
        entries = entries.filter { $0.status == status }
      }
      return Result(data: .object(["entries": .array(entries.map(activityEntryJSON))]))
    case "activity.get":
      let id = try requiredString(variables, "sessionId", fallback: "id")
      guard let entry = try ClaudeCodeActivityStore(dataDir: dataDir).load().first(where: { $0.sessionId == id }) else {
        return Result(errors: ["Activity not found"])
      }
      return Result(data: activityEntryJSON(entry))
    case "activity.update":
      return try executeActivityUpdate(variables: variables, dataDir: dataDir)
    case "activity.cleanup":
      guard let cutoff = activityCleanupCutoff(from: claudeCodeStringValue(variables["olderThan"])) else {
        return Result(errors: ["Invalid cleanup cutoff"])
      }
      let retained = try ClaudeCodeActivityStore(dataDir: dataDir).cleanup(olderThan: cutoff)
      return Result(data: .object(["entries": .array(retained.map(activityEntryJSON))]))
    case "activity.setup":
      return Result(data: .object(try activitySetupJSON(variables: variables)))
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeActivityUpdate(variables: JSONObject, dataDir: String) throws -> Result {
    let sessionId = try requiredString(variables, "sessionId", fallback: "id")
    guard let status = ClaudeCodeActivityStatusValue(rawValue: try requiredString(variables, "status")) else {
      return Result(errors: ["Invalid activity status"])
    }
    let store = ClaudeCodeActivityStore(dataDir: dataDir)
    let entry = ClaudeCodeStoredActivityEntry(
      sessionId: sessionId,
      status: status,
      updatedAt: claudeCodeStringValue(variables["updatedAt"]) ?? isoString(Date()),
      projectPath: claudeCodeStringValue(variables["projectPath"]) ?? claudeCodeStringValue(variables["cwd"])
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

  private static func executeGroupCommand(
    _ commandName: String,
    variables: JSONObject,
    configDir: String,
    claudeCodeHome: String?
  ) throws -> Result {
    switch commandName {
    case "group.create":
      return Result(data: try claudeCodeJSONValue(ClaudeCodeGroupPersistence.createGroup(
        name: try requiredString(variables, "name"),
        description: claudeCodeStringValue(variables["description"]),
        configDir: configDir
      )))
    case "group.list":
      return Result(data: try claudeCodeJSONValue(ClaudeCodeGroupPersistence.listGroups(configDir: configDir)))
    case "group.show":
      guard let group = try ClaudeCodeGroupPersistence.findGroup(try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Group not found"])
      }
      return Result(data: try claudeCodeJSONValue(group))
    case "group.add", "group.remove", "group.pause", "group.resume", "group.delete":
      return try executeGroupMutation(commandName, variables: variables, configDir: configDir)
    case "group.run":
      guard let group = try ClaudeCodeGroupPersistence.findGroup(try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Group not found"])
      }
      return Result(data: try .array(runGroupEvents(
        group: group,
        prompt: try requiredString(variables, "prompt"),
        variables: variables,
        claudeCodeHome: claudeCodeHome
      ).map(JSONValue.object)))
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeGroupMutation(_ commandName: String, variables: JSONObject, configDir: String) throws -> Result {
    let groupId = try resolveExistingGroupId(try requiredString(variables, "id"), configDir: configDir)
    switch commandName {
    case "group.add":
      let ok = try ClaudeCodeGroupPersistence.addSession(groupId: groupId, session: try groupSession(from: variables), configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
    case "group.remove":
      let sessionId = try requiredString(variables, "sessionId")
      let ok = try ClaudeCodeGroupPersistence.removeSession(groupId: groupId, sessionId: sessionId, configDir: configDir)
      return ok ? Result(data: .object(["ok": .bool(true), "success": .bool(true), "id": .string(groupId)])) : Result(errors: ["Group session not found"])
    case "group.pause":
      let ok = try ClaudeCodeGroupPersistence.setPaused(groupId: groupId, paused: true, configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
    case "group.resume":
      let ok = try ClaudeCodeGroupPersistence.setPaused(groupId: groupId, paused: false, configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
    case "group.delete":
      let ok = try ClaudeCodeGroupPersistence.deleteGroup(id: groupId, configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "success": .bool(ok), "id": .string(groupId)]))
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeQueueCommand(
    _ commandName: String,
    variables: JSONObject,
    configDir: String,
    claudeCodeHome: String?
  ) throws -> Result {
    switch commandName {
    case "queue.create":
      let projectPath = try requiredString(variables, "projectPath")
      let name = claudeCodeStringValue(variables["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackName = URL(fileURLWithPath: projectPath).lastPathComponent
      let resolvedName = (name?.isEmpty == false ? name : nil) ?? (fallbackName.isEmpty ? projectPath : fallbackName)
      return Result(data: try claudeCodeJSONValue(ClaudeCodeQueuePersistence.createQueue(
        name: resolvedName,
        projectPath: projectPath,
        configDir: configDir
      )))
    case "queue.add":
      let images = claudeCodeStringArray(variables["images"]).isEmpty ? claudeCodeStringArray(variables["imagePaths"]) : claudeCodeStringArray(variables["images"])
      return Result(data: try claudeCodeJSONValue(addQueuePromptLegacy(variables: variables, imagePaths: images, configDir: configDir)))
    case "queue.show":
      guard let queue = try ClaudeCodeQueuePersistence.findQueue(try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Queue not found"])
      }
      return Result(data: try claudeCodeJSONValue(queue))
    case "queue.list":
      var queues = try ClaudeCodeQueuePersistence.listQueues(configDir: configDir)
      if let projectPath = claudeCodeStringValue(variables["projectPath"]) {
        queues = queues.filter { $0.projectPath == projectPath }
      }
      if let rawStatus = claudeCodeStringValue(variables["status"]), let status = ClaudeCodeQueueStatus(rawValue: rawStatus) {
        queues = queues.filter { $0.status == status }
      }
      return Result(data: try claudeCodeJSONValue(queues))
    case "queue.delete":
      let id = try resolveExistingQueueId(try requiredString(variables, "id"), configDir: configDir)
      let ok = try ClaudeCodeQueuePersistence.removeQueue(id, configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
    case "queue.pause", "queue.resume", "queue.stop", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run":
      return executeQueueMutation(commandName: commandName, variables: variables, configDir: configDir, claudeCodeHome: claudeCodeHome)
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeBookmarkCommand(
    _ commandName: String,
    variables: JSONObject,
    configDir: String,
    claudeCodeHome: String?
  ) throws -> Result {
    switch commandName {
    case "bookmark.add":
      guard let type = inferredBookmarkType(from: variables) else {
        return Result(errors: ["Invalid bookmark type"])
      }
      let bookmark = try ClaudeCodeBookmarkPersistence.addBookmark(
        type: type,
        sessionId: try requiredString(variables, "sessionId"),
        messageId: claudeCodeStringValue(variables["messageId"]),
        name: claudeCodeStringValue(variables["name"]),
        description: claudeCodeStringValue(variables["description"]) ?? claudeCodeStringValue(variables["text"]),
        tags: claudeCodeStringArray(variables["tags"]),
        fromMessageId: claudeCodeStringValue(variables["fromMessageId"]),
        toMessageId: claudeCodeStringValue(variables["toMessageId"]),
        configDir: configDir
      )
      return Result(data: try claudeCodeJSONValue(bookmark))
    case "bookmark.list":
      let bookmarks = try ClaudeCodeBookmarkPersistence.listBookmarks(
        sessionId: claudeCodeStringValue(variables["sessionId"]),
        type: claudeCodeStringValue(variables["type"]).flatMap(ClaudeCodeBookmarkType.init(rawValue:)),
        tag: claudeCodeStringValue(variables["tag"]),
        configDir: configDir
      )
      return Result(data: try claudeCodeJSONValue(bookmarks))
    case "bookmark.get":
      guard let bookmark = try ClaudeCodeBookmarkPersistence.getBookmark(id: try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Bookmark not found"])
      }
      return Result(data: try claudeCodeJSONValue(bookmark))
    case "bookmark.content":
      guard let bookmark = try ClaudeCodeBookmarkPersistence.getBookmark(id: try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Bookmark not found"])
      }
      return Result(data: try bookmarkContentJSON(bookmark, claudeCodeHome: claudeCodeHome))
    case "bookmark.delete":
      let ok = try ClaudeCodeBookmarkPersistence.deleteBookmark(id: try requiredString(variables, "id"), configDir: configDir)
      return Result(data: .object(["ok": .bool(ok), "deleted": .bool(ok)]))
    case "bookmark.search":
      return try executeBookmarkSearch(variables: variables, configDir: configDir)
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeBookmarkSearch(variables: JSONObject, configDir: String) throws -> Result {
    let limit = max(0, claudeCodeIntValue(variables["limit"]) ?? 50)
    let scored = try ClaudeCodeBookmarkPersistence.searchBookmarkResults(
      try requiredString(variables, "query", fallback: "q"),
      limit: limit,
      configDir: configDir
    )
    return Result(data: .array(try scored.map { result in
      .object([
        "bookmark": try claudeCodeJSONValue(result.bookmark),
        "score": .number(result.score)
      ])
    }))
  }

  private static func executeTokenCommand(_ commandName: String, variables: JSONObject, configDir: String) throws -> Result {
    switch commandName {
    case "token.create":
      let name = try requiredString(variables, "name")
      let permissionValues = claudeCodeStringArray(variables["permissions"])
      let permissions = permissionValues.isEmpty
        ? ClaudeCodeTokenManager.parsePermissionsCSV(claudeCodeStringValue(variables["permissions"]) ?? "session:read,session:create")
        : ClaudeCodeTokenManager.normalizePermissions(permissionValues)
      guard !permissions.isEmpty else {
        return Result(errors: ["No valid permissions provided"])
      }
      let rawToken = try ClaudeCodeTokenPersistence.createRawToken(
        name: name,
        permissions: permissions,
        expiresAt: try tokenExpiresAt(from: variables),
        configDir: configDir
      )
      return Result(data: .string(rawToken))
    case "token.list":
      return Result(data: try claudeCodeJSONValue(ClaudeCodeTokenPersistence.listMetadata(configDir: configDir)))
    case "token.revoke":
      return Result(data: .bool(try ClaudeCodeTokenPersistence.revoke(id: try requiredString(variables, "id"), configDir: configDir)))
    case "token.rotate":
      guard let token = try ClaudeCodeTokenPersistence.rotate(id: try requiredString(variables, "id"), configDir: configDir) else {
        return Result(errors: ["Token not found"])
      }
      return Result(data: .string(token))
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func executeFilesCommand(
    _ commandName: String,
    variables: JSONObject,
    configDir: String,
    claudeCodeHome: String?
  ) throws -> Result {
    switch commandName {
    case "files.rebuild":
      return Result(data: .object(try rebuildPersistentFileIndex(configDir: configDir, claudeCodeHome: claudeCodeHome)))
    case "files.list":
      let session = try requiredSessionForFileCommand(variables: variables, claudeCodeHome: claudeCodeHome)
      return Result(data: .object(try fileChangeSummaryJSON(for: session)))
    case "files.patches":
      let session = try requiredSessionForFileCommand(variables: variables, claudeCodeHome: claudeCodeHome)
      return Result(data: .object(try filePatchHistoryJSON(for: session)))
    case "files.find":
      return Result(data: .object(try findPersistentSessionsByFile(
        path: try requiredString(variables, "path"),
        configDir: configDir,
        claudeCodeHome: claudeCodeHome
      )))
    default:
      return Result(errors: ["Unhandled command: \(commandName)"])
    }
  }

  private static func requiredSessionForFileCommand(
    variables: JSONObject,
    claudeCodeHome: String?
  ) throws -> ClaudeCodeSession {
    let sessionId = try requiredString(variables, "sessionId")
    guard let session = ClaudeCodeSessionIndex.findSession(id: sessionId, claudeCodeHome: claudeCodeHome) else {
      throw ClaudeCodeGraphQLError.missingVariable("session not found: \(sessionId)")
    }
    return session
  }
}
