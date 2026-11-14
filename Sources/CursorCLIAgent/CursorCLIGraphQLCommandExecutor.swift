import Foundation
import RielaCore

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
