import Foundation
import RielaCore

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
