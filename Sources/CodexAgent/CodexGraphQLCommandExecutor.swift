import Foundation
import RielaCore

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
      let configDir = codexJSONString(effectiveVariables["configDir"]) ?? context.configDir ?? defaultCodexAgentConfigDir()
      let codexHome = codexJSONString(effectiveVariables["codexHome"]) ?? context.codexHome
      let request = CodexGraphQLExecutionRequest(
        commandName: commandName,
        variables: effectiveVariables,
        configDir: configDir,
        codexHome: codexHome
      )
      return try executeGraphQLCommand(request)
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

private typealias GraphQLResult = CodexGraphQLCommandExecutor.Result

private struct CodexGraphQLExecutionRequest {
  var commandName: String
  var variables: JSONObject
  var configDir: String
  var codexHome: String?
}

private func executeGraphQLCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let family = request.commandName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? request.commandName
  switch family {
  case "version":
    return GraphQLResult(data: .object(toolVersionsJSON(variables: request.variables)))
  case "model":
    return try executeModelCommand(request)
  case "session":
    return try executeSessionCommand(request)
  case "group":
    return try executeGroupCommand(request)
  case "queue":
    return try executeQueueCommand(request)
  case "bookmark":
    return try executeBookmarkCommand(request)
  case "token":
    return try executeTokenCommand(request)
  case "files":
    return try executeFilesCommand(request)
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func executeModelCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  let model = try requiredString(variables, "model")
  var options = try processOptions(from: variables, codexHome: request.codexHome)
  options.model = model
  if options.additionalArguments.isEmpty {
    options.additionalArguments = ["--skip-git-repo-check", "--ephemeral"]
  }
  let manager = CodexProcessManager(executableName: executableName(from: variables))
  let result = manager.spawnExec(
    prompt: codexJSONString(variables["prompt"]) ?? "Reply with exactly OK.",
    options: options
  )
  return GraphQLResult(data: .object([
    "model": .string(model),
    "ok": .bool(result.result.exitCode == 0),
    "exitCode": .number(Double(result.result.exitCode)),
    "stdout": .string(result.result.stdout),
    "stderr": .string(result.result.stderr)
  ]))
}

private func executeSessionCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  switch request.commandName {
  case "session.list":
    return sessionListResult(request)
  case "session.show":
    return try sessionShowResult(request)
  case "session.search", "session.searchTranscript":
    return try sessionSearchResult(request)
  case "session.run":
    return try sessionRunResult(request)
  case "session.resume":
    return try sessionResumeResult(request)
  case "session.fork":
    return try sessionForkResult(request)
  case "session.watch":
    return try sessionWatchResult(request)
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func sessionListResult(_ request: CodexGraphQLExecutionRequest) -> GraphQLResult {
  let options = sessionListOptions(from: request.variables, codexHome: request.codexHome)
  let result = CodexSessionIndex.listSessions(options: options)
  return GraphQLResult(data: .object([
    "sessions": .array(result.sessions.map(sessionJSON)),
    "total": .number(Double(result.total)),
    "offset": .number(Double(result.offset)),
    "limit": .number(Double(result.limit))
  ]))
}

private func sessionShowResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let id = try requiredString(request.variables, "id")
  guard let session = CodexSessionCommands.show(sessionId: id, codexHome: request.codexHome) else {
    return GraphQLResult(errors: ["Session not found"])
  }
  return GraphQLResult(data: sessionJSON(session))
}

private func sessionSearchResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let query = try requiredString(request.variables, "query")
  if request.commandName == "session.searchTranscript", let id = codexJSONString(request.variables["id"]) {
    return try sessionTranscriptSearchResult(id: id, query: query, request: request)
  }
  let result = try CodexSessionIndex.searchSessions(
    query: query,
    options: sessionListOptions(from: request.variables, codexHome: request.codexHome),
    searchOptions: transcriptSearchOptions(from: request.variables)
  )
  return GraphQLResult(data: .object([
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

private func sessionTranscriptSearchResult(
  id: String,
  query: String,
  request: CodexGraphQLExecutionRequest
) throws -> GraphQLResult {
  guard let session = CodexSessionIndex.findSession(id: id, codexHome: request.codexHome) else {
    return emptySessionTranscriptSearchResult(id: id)
  }
  guard FileManager.default.isReadableFile(atPath: session.rolloutPath) else {
    return emptySessionTranscriptSearchResult(id: id)
  }
  let search = try CodexSessionIndex.searchSessionTranscriptDetailed(
    session: session,
    query: query,
    options: transcriptSearchOptions(from: request.variables)
  )
  return GraphQLResult(data: .object([
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

private func emptySessionTranscriptSearchResult(id: String) -> GraphQLResult {
  GraphQLResult(data: .object([
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

private func sessionRunResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let prompt = try requiredNonBlankString(request.variables, "prompt")
  let manager = CodexProcessManager(executableName: executableName(from: request.variables))
  let options = try processOptions(from: request.variables, codexHome: request.codexHome)
  let result = manager.spawnExec(prompt: prompt, options: options)
  return GraphQLResult(data: .object(sessionExecutionJSON(process: result.process, result: result.result)))
}

private func sessionResumeResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let id = try requiredString(request.variables, "id")
  let manager = CodexProcessManager(executableName: executableName(from: request.variables))
  let options = try processOptions(from: request.variables, codexHome: request.codexHome)
  let process = manager.spawnResumeProcess(
    sessionId: id,
    prompt: codexJSONString(request.variables["prompt"]),
    options: options
  )
  return GraphQLResult(data: .object(processHandleJSON(process)))
}

private func sessionForkResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let id = try requiredString(request.variables, "id")
  let manager = CodexProcessManager(executableName: executableName(from: request.variables))
  let options = try processOptions(from: request.variables, codexHome: request.codexHome)
  let process = manager.spawnForkProcess(
    sessionId: id,
    nthMessage: codexJSONInt(request.variables["nthMessage"]),
    options: options
  )
  return GraphQLResult(data: .object(processHandleJSON(process)))
}

private func sessionWatchResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let id = try requiredString(request.variables, "id")
  let subscription = try CodexGraphQLCommandExecutor.watchSession(
    id: id,
    startOffset: nonNegativeUInt64Value(request.variables["startOffset"]) ?? 0,
    codexHome: request.codexHome
  )
  let lines = subscription.drainAvailable()
  subscription.cancel()
  return GraphQLResult(data: .object(["events": .array(lines.map(rolloutLineJSON))]))
}

private func executeGroupCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  switch request.commandName {
  case "group.create":
    let group = try CodexGroupPersistence.createGroup(
      name: try requiredString(variables, "name"),
      description: codexJSONString(variables["description"]),
      configDir: request.configDir
    )
    return GraphQLResult(data: try jsonValue(group))
  case "group.list":
    return GraphQLResult(data: try jsonValue(CodexGroupPersistence.listGroups(configDir: request.configDir)))
  case "group.show":
    guard let group = try CodexGroupPersistence.findGroup(
      try requiredString(variables, "id"),
      configDir: request.configDir
    ) else {
      return GraphQLResult(errors: ["Group not found"])
    }
    return GraphQLResult(data: try jsonValue(group))
  case "group.add":
    let groupId = try resolveExistingGroupId(try requiredString(variables, "id"), configDir: request.configDir)
    let ok = try CodexGroupPersistence.addSession(
      groupId: groupId,
      sessionId: try requiredString(variables, "sessionId"),
      configDir: request.configDir
    )
    return GraphQLResult(data: .object(["ok": .bool(ok)]))
  case "group.remove":
    return try groupRemoveResult(request)
  case "group.pause", "group.resume":
    return try groupPauseResult(request)
  case "group.delete":
    let id = try resolveExistingGroupId(try requiredString(variables, "id"), configDir: request.configDir)
    let ok = try CodexGroupPersistence.deleteGroup(id: id, configDir: request.configDir)
    return GraphQLResult(data: .object(["ok": .bool(ok)]))
  case "group.run":
    return try groupRunResult(request)
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func groupRemoveResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let groupId = try resolveExistingGroupId(try requiredString(request.variables, "id"), configDir: request.configDir)
  let ok = try CodexGroupPersistence.removeSession(
    groupId: groupId,
    sessionId: try requiredString(request.variables, "sessionId"),
    configDir: request.configDir
  )
  return ok ? GraphQLResult(data: .object(["ok": .bool(true)])) : GraphQLResult(errors: ["Group session not found"])
}

private func groupPauseResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let paused = request.commandName == "group.pause"
  let id = try resolveExistingGroupId(try requiredString(request.variables, "id"), configDir: request.configDir)
  let ok = try CodexGroupPersistence.setPaused(groupId: id, paused: paused, configDir: request.configDir)
  return GraphQLResult(data: .object(["ok": .bool(ok)]))
}

private func groupRunResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  guard let group = try CodexGroupPersistence.findGroup(
    try requiredString(request.variables, "id"),
    configDir: request.configDir
  ) else {
    return GraphQLResult(errors: ["Group not found"])
  }
  let events = try runGroupEvents(
    group: group,
    prompt: try requiredString(request.variables, "prompt"),
    variables: request.variables,
    codexHome: request.codexHome
  )
  return GraphQLResult(data: .array(events.map(JSONValue.object)))
}

private func executeQueueCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  switch request.commandName {
  case "queue.create":
    let queue = try CodexQueuePersistence.createQueue(
      name: try requiredString(variables, "name"),
      projectPath: try requiredString(variables, "projectPath"),
      configDir: request.configDir
    )
    return GraphQLResult(data: try jsonValue(queue))
  case "queue.add":
    return try queueAddResult(request)
  case "queue.show":
    guard let queue = try CodexQueuePersistence.findQueue(
      try requiredString(variables, "id"),
      configDir: request.configDir
    ) else {
      return GraphQLResult(errors: ["Queue not found"])
    }
    return GraphQLResult(data: try jsonValue(queue))
  case "queue.list":
    return GraphQLResult(data: try jsonValue(CodexQueuePersistence.listQueues(configDir: request.configDir)))
  case "queue.delete":
    let id = try resolveExistingQueueId(try requiredString(variables, "id"), configDir: request.configDir)
    let ok = try CodexQueuePersistence.removeQueue(id, configDir: request.configDir)
    return ok ? GraphQLResult(data: .object(["ok": .bool(true)])) : GraphQLResult(errors: ["Queue not found"])
  case "queue.pause", "queue.resume", "queue.update", "queue.remove", "queue.move", "queue.mode", "queue.run":
    return executeQueueMutation(
      commandName: request.commandName,
      variables: variables,
      configDir: request.configDir,
      codexHome: request.codexHome
    )
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func queueAddResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  let images = codexJSONStringArray(variables["images"]).isEmpty ? codexJSONStringArray(variables["imagePaths"]) : codexJSONStringArray(variables["images"])
  let prompt = try CodexQueuePersistence.addPrompt(
    queueId: resolveExistingQueueId(try requiredString(variables, "id"), configDir: request.configDir),
    prompt: try requiredString(variables, "prompt"),
    imagePaths: images,
    configDir: request.configDir
  )
  return GraphQLResult(data: try jsonValue(prompt))
}

private func executeBookmarkCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  switch request.commandName {
  case "bookmark.add":
    return try bookmarkAddResult(request)
  case "bookmark.list":
    return try bookmarkListResult(request)
  case "bookmark.get":
    guard let bookmark = try CodexBookmarkPersistence.getBookmark(
      id: try requiredString(request.variables, "id"),
      configDir: request.configDir
    ) else {
      return GraphQLResult(errors: ["Bookmark not found"])
    }
    return GraphQLResult(data: try jsonValue(bookmark))
  case "bookmark.delete":
    let ok = try CodexBookmarkPersistence.deleteBookmark(
      id: try requiredString(request.variables, "id"),
      configDir: request.configDir
    )
    return ok ? GraphQLResult(data: .object(["ok": .bool(true)])) : GraphQLResult(errors: ["Bookmark not found"])
  case "bookmark.search":
    return try bookmarkSearchResult(request)
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func bookmarkAddResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  guard let type = CodexBookmarkType(rawValue: try requiredString(variables, "type")) else {
    return GraphQLResult(errors: ["Invalid bookmark type"])
  }
  let bookmark = try CodexBookmarkPersistence.addBookmark(
    type: type,
    sessionId: try requiredString(variables, "sessionId"),
    messageId: codexJSONString(variables["messageId"]),
    name: codexJSONString(variables["name"]),
    description: codexJSONString(variables["description"]) ?? codexJSONString(variables["text"]),
    tags: codexJSONStringArray(variables["tags"]),
    fromMessageId: codexJSONString(variables["fromMessageId"]),
    toMessageId: codexJSONString(variables["toMessageId"]),
    configDir: request.configDir
  )
  return GraphQLResult(data: try jsonValue(bookmark))
}

private func bookmarkListResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  let bookmarks = try CodexBookmarkPersistence.listBookmarks(
    sessionId: codexJSONString(variables["sessionId"]),
    type: codexJSONString(variables["type"]).flatMap(CodexBookmarkType.init(rawValue:)),
    tag: codexJSONString(variables["tag"]),
    configDir: request.configDir
  )
  return GraphQLResult(data: try jsonValue(bookmarks))
}

private func bookmarkSearchResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let limit = max(0, codexJSONInt(request.variables["limit"]) ?? 50)
  let scored = try CodexBookmarkPersistence.searchBookmarkResults(
    try requiredString(request.variables, "query"),
    limit: limit,
    configDir: request.configDir
  )
  let values = try scored.map { result -> JSONValue in
    .object([
      "bookmark": try jsonValue(result.bookmark),
      "score": .number(result.score)
    ])
  }
  return GraphQLResult(data: .array(values))
}

private func executeTokenCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  switch request.commandName {
  case "token.create":
    return try tokenCreateResult(request)
  case "token.list":
    return GraphQLResult(data: try jsonValue(CodexTokenPersistence.listMetadata(configDir: request.configDir)))
  case "token.revoke":
    let ok = try CodexTokenPersistence.revoke(
      id: try requiredString(request.variables, "id"),
      configDir: request.configDir
    )
    return GraphQLResult(data: .bool(ok))
  case "token.rotate":
    guard let token = try CodexTokenPersistence.rotate(
      id: try requiredString(request.variables, "id"),
      configDir: request.configDir
    ) else {
      return GraphQLResult(errors: ["Token not found"])
    }
    return GraphQLResult(data: .string(token))
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
}

private func tokenCreateResult(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  let variables = request.variables
  let name = try requiredString(variables, "name")
  let permissionValues = codexJSONStringArray(variables["permissions"])
  let permissions = permissionValues.isEmpty
    ? CodexTokenManager.parsePermissionsCSV(codexJSONString(variables["permissions"]) ?? "session:read")
    : CodexTokenManager.normalizePermissions(permissionValues)
  guard !permissions.isEmpty else {
    return GraphQLResult(errors: ["No valid permissions provided"])
  }
  let rawToken = try CodexTokenPersistence.createRawToken(
    name: name,
    permissions: permissions,
    expiresAt: codexJSONString(variables["expiresAt"]),
    configDir: request.configDir
  )
  return GraphQLResult(data: .string(rawToken))
}

private func executeFilesCommand(_ request: CodexGraphQLExecutionRequest) throws -> GraphQLResult {
  switch request.commandName {
  case "files.rebuild":
    return GraphQLResult(
      data: .object(try rebuildPersistentFileIndex(configDir: request.configDir, codexHome: request.codexHome))
    )
  case "files.list", "files.patches":
    let sessionId = try requiredString(request.variables, "sessionId")
    guard let session = CodexSessionIndex.findSession(id: sessionId, codexHome: request.codexHome) else {
      return GraphQLResult(errors: ["session not found: \(sessionId)"])
    }
    if request.commandName == "files.list" {
      return GraphQLResult(data: .object(try fileChangeSummaryJSON(for: session)))
    }
    return GraphQLResult(data: .object(try filePatchHistoryJSON(for: session)))
  case "files.find":
    let result = try findPersistentSessionsByFile(
      path: try requiredString(request.variables, "path"),
      configDir: request.configDir,
      codexHome: request.codexHome
    )
    return GraphQLResult(data: .object(result))
  default:
    return GraphQLResult(errors: ["Unhandled command: \(request.commandName)"])
  }
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
      if let rawStatus = codexJSONString(variables["status"]) {
        guard let parsedStatus = CodexQueuePromptStatus(rawValue: rawStatus) else {
          return CodexGraphQLCommandExecutor.Result(errors: ["status must be one of: pending, running, completed, failed"])
        }
        status = parsedStatus
      } else {
        status = nil
      }
      ok = repository.updatePrompt(queueId: id, promptId: commandId, prompt: codexJSONString(variables["prompt"]), status: status, resultExitCode: codexJSONInt(variables["resultExitCode"]))
    case "queue.remove":
      ok = repository.removePrompt(queueId: id, promptId: try requiredString(variables, "commandId", fallback: "promptId"))
    case "queue.move":
      if let from = codexJSONInt(variables["from"]), let to = codexJSONInt(variables["to"]) {
        ok = repository.movePrompt(queueId: id, from: from, to: to)
      } else {
        ok = repository.movePrompt(queueId: id, promptId: try requiredString(variables, "promptId"), toIndex: codexJSONInt(variables["toIndex"]) ?? 0)
      }
    case "queue.mode":
      guard let mode = CodexQueueCommandMode(rawValue: try requiredString(variables, "mode")) else {
        return CodexGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
      }
      if let commandId = codexJSONString(variables["commandId"]) ?? codexJSONString(variables["promptId"]) {
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
      let prompts = try repository.runQueue(
        id: id,
        afterPrompt: { queues in
          config.queues = queues
          try CodexQueuePersistence.save(config, configDir: configDir)
        },
        runner: { prompt in
          pendingIds.removeAll { $0 == prompt.id }
          events.append(
            queueEvent(type: "prompt_started", queueId: id, promptId: prompt.id, current: prompt.id, pending: pendingIds)
          )
          var options = try processOptions(from: variables, codexHome: codexHome)
          options.cwd = queueProjectPath
          options.images = Array(Set(prompt.imagePaths + options.images)).sorted()
          let result = manager.spawnExec(prompt: prompt.prompt, options: options).result
          events.append(
            queueEvent(
              type: result.exitCode == 0 ? "prompt_completed" : "prompt_failed",
              queueId: id,
              promptId: prompt.id,
              exitCode: Int(result.exitCode),
              pending: pendingIds
            )
          )
          return Int(result.exitCode)
        }
      )
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
  let maxConcurrent = max(1, codexJSONInt(variables["maxConcurrent"]) ?? 3)
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

private func groupEvent(type: String, groupId: String, sessionId: String? = nil, exitCode: Int? = nil, running: [String] = [], completed: [String] = [], failed: [String] = [], pending: [String] = []) -> JSONObject {
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
