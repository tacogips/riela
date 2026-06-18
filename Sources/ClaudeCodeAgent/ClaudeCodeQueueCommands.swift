import Foundation
import RielaCore

public enum ClaudeCodeGraphQLError: Error, Equatable {
  case missingDocument
  case missingFlagValue(String)
  case variablesMustBeObject
  case invalidParam(String)
  case missingVariable(String)
}

func executeQueueMutation(commandName: String, variables: JSONObject, configDir: String, claudeCodeHome: String?) -> ClaudeCodeGraphQLCommandExecutor.Result {
  do {
    var config = try ClaudeCodeQueuePersistence.load(configDir: configDir)
    var repository = ClaudeCodeQueueRepository()
    repository.replaceQueues(config.queues)
    let requestedId = try requiredString(variables, "id")
    guard let requestedQueue = repository.findQueue(requestedId) else {
      return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Queue not found"])
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
      let status: ClaudeCodeQueuePromptStatus?
      if let rawStatus = claudeCodeStringValue(variables["status"]) {
        guard let parsedStatus = ClaudeCodeQueuePromptStatus(rawValue: rawStatus) else {
          return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["status must be one of: pending, running, completed, failed"])
        }
        status = parsedStatus
      } else {
        status = nil
      }
      let mode = (claudeCodeStringValue(variables["sessionMode"]) ?? claudeCodeStringValue(variables["mode"])).flatMap(ClaudeCodeQueueCommandMode.legacy)
      ok = repository.updatePrompt(queueId: id, promptId: commandId, prompt: claudeCodeStringValue(variables["prompt"]), status: status, mode: mode, resultExitCode: claudeCodeIntValue(variables["resultExitCode"]))
    case "queue.remove":
      ok = repository.removePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue))
    case "queue.move":
      if let from = claudeCodeIntValue(variables["from"]), let to = claudeCodeIntValue(variables["to"]) {
        ok = repository.movePrompt(queueId: id, from: from, to: to)
      } else {
        ok = repository.movePrompt(queueId: id, promptId: try resolveQueuePromptId(variables: variables, queue: requestedQueue), toIndex: claudeCodeIntValue(variables["toIndex"]) ?? 0)
      }
    case "queue.mode":
      if let rawMode = claudeCodeStringValue(variables["mode"]) {
        guard let mode = ClaudeCodeQueueCommandMode.legacy(rawMode) else {
          return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
        }
        if let commandId = try? resolveQueuePromptId(variables: variables, queue: requestedQueue) {
          ok = repository.updatePrompt(queueId: id, promptId: commandId, mode: mode)
        } else {
          ok = repository.setMode(queueId: id, mode: mode)
        }
      } else if let commandId = try? resolveQueuePromptId(variables: variables, queue: requestedQueue), let current = requestedQueue.prompts.first(where: { $0.id == commandId }) {
        let currentMode = current.mode ?? .continueMode
        let toggled: ClaudeCodeQueueCommandMode = currentMode == .new ? .continueMode : .new
        ok = repository.updatePrompt(queueId: id, promptId: commandId, mode: toggled)
      } else {
        return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Invalid queue mode"])
      }
    case "queue.run":
      let executableName = executableName(from: variables)
      let manager = ClaudeCodeProcessManager(executableName: executableName)
      var events: [JSONObject] = []
      guard let queueIndex = config.queues.firstIndex(where: { $0.id == id }) else {
        return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Queue not found"])
      }
      let queueProjectPath = config.queues[queueIndex].projectPath
      if config.queues[queueIndex].status == .paused || config.queues[queueIndex].status == .stopped || config.queues[queueIndex].paused {
        let pending = config.queues[queueIndex].prompts.filter { $0.status == .pending }.map(\.id)
        return ClaudeCodeGraphQLCommandExecutor.Result(data: .array([.object(queueEvent(type: "queue_stopped", queueId: id, pending: pending))]))
      }
      guard config.queues[queueIndex].status == .pending else {
        return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Queue is not runnable"])
      }
      let startedAt = isoString(Date())
      config.queues[queueIndex].status = .running
      config.queues[queueIndex].paused = false
      config.queues[queueIndex].startedAt = config.queues[queueIndex].startedAt ?? startedAt
      config.queues[queueIndex].updatedAt = startedAt
      try ClaudeCodeQueuePersistence.save(config, configDir: configDir)

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
        try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
        pendingIds.removeAll { $0 == prompt.id }
        events.append(queueEvent(type: "prompt_started", queueId: id, promptId: prompt.id, current: prompt.id, pending: pendingIds))
        var options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
        options.cwd = queueProjectPath
        options.images = Array(Set(prompt.imagePaths + options.images)).sorted()
        let shouldResume = (prompt.mode ?? .continueMode) != .new && config.queues[queueIndex].currentSessionId != nil
        let execution = shouldResume
          ? manager.spawnResume(sessionId: config.queues[queueIndex].currentSessionId!, prompt: prompt.prompt, options: options)
          : manager.spawnExec(prompt: prompt.prompt, options: options)
        let result = execution.result
        let lines = result.stdout.split(separator: "\n").compactMap { ClaudeCodeRolloutReader.parseRolloutLine(String($0)) }
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
          try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
          events.append(queueEvent(type: "queue_failed", queueId: id, completed: completed, pending: [], failed: failed + skipped))
          return ClaudeCodeGraphQLCommandExecutor.Result(data: .array(events.map(JSONValue.object)))
        }
        try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
      }
      let finishedAt = isoString(Date())
      config.queues[queueIndex].status = .completed
      config.queues[queueIndex].completedAt = finishedAt
      config.queues[queueIndex].updatedAt = finishedAt
      events.append(queueEvent(type: "queue_completed", queueId: id, completed: completed, pending: [], failed: failed))
      try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
      return ClaudeCodeGraphQLCommandExecutor.Result(data: .array(events.map(JSONValue.object)))
    default:
      return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Unhandled queue mutation: \(commandName)"])
    }
    guard ok else {
      return ClaudeCodeGraphQLCommandExecutor.Result(errors: ["Queue command not found"])
    }
    config.queues = repository.listQueues()
    try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
    return ClaudeCodeGraphQLCommandExecutor.Result(data: .object(["ok": .bool(ok), "success": .bool(ok)]))
  } catch {
    return ClaudeCodeGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

func addQueuePromptLegacy(variables: JSONObject, imagePaths: [String], configDir: String) throws -> ClaudeCodeQueuePrompt {
  var config = try ClaudeCodeQueuePersistence.load(configDir: configDir)
  let idOrName = try requiredString(variables, "id")
  guard let queueIndex = config.queues.firstIndex(where: { $0.id == idOrName || $0.name == idOrName }) else {
    throw ClaudeCodeGraphQLError.missingVariable("Queue not found")
  }
  guard config.queues[queueIndex].status == .pending || config.queues[queueIndex].status == .paused else {
    throw ClaudeCodeGraphQLError.missingVariable("Queue is not editable")
  }
  let mode = claudeCodeStringValue(variables["sessionMode"]) ?? claudeCodeStringValue(variables["mode"])
  let item = ClaudeCodeQueuePrompt(
    id: UUID().uuidString,
    prompt: try requiredString(variables, "prompt"),
    status: .pending,
    mode: mode.flatMap(ClaudeCodeQueueCommandMode.legacy) ?? .continueMode,
    imagePaths: imagePaths,
    createdAt: ISO8601DateFormatter().string(from: Date())
  )
  let insertionIndex: Int
  if let position = claudeCodeIntValue(variables["position"]) {
    insertionIndex = min(max(position, 0), config.queues[queueIndex].prompts.count)
  } else {
    insertionIndex = config.queues[queueIndex].prompts.count
  }
  config.queues[queueIndex].prompts.insert(item, at: insertionIndex)
  try ClaudeCodeQueuePersistence.save(config, configDir: configDir)
  return item
}

func resolveQueuePromptId(variables: JSONObject, queue: ClaudeCodeQueue) throws -> String {
  if let commandId = claudeCodeStringValue(variables["commandId"]) ?? claudeCodeStringValue(variables["promptId"]) {
    return commandId
  }
  if let index = claudeCodeIntValue(variables["index"]), queue.prompts.indices.contains(index) {
    return queue.prompts[index].id
  }
  throw ClaudeCodeGraphQLError.missingVariable("commandId")
}

func runGroupEvents(group: ClaudeCodeGroup, prompt: String, variables: JSONObject, claudeCodeHome: String?) throws -> [JSONObject] {
  guard !group.paused else {
    throw ClaudeCodeGraphQLError.missingVariable("group is paused: \(group.id)")
  }
  var events: [JSONObject] = []
  var completed: [String] = []
  var failed: [String] = []
  var pending = group.sessionIds
  var running: [String] = []
  let maxConcurrent = max(1, claudeCodeIntValue(variables["maxConcurrent"]) ?? 3)
  let executableName = executableName(from: variables)
  let options = try processOptions(from: variables, claudeCodeHome: claudeCodeHome)
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
        let manager = ClaudeCodeProcessManager(executableName: executableName)
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
