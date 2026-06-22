import Foundation
import RielaMemory

extension DeterministicWorkflowRunner {
  func effectiveNodeMemories(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?
  ) -> [WorkflowMemoryDeclaration] {
    let candidates = (
      workflow.nodeRegistry.first { $0.id == step.nodeId }?.memories ?? []
    ) + (
      workflow.nodes.first { $0.id == step.id || $0.id == step.nodeId }?.memories ?? []
    ) + (payload?.memories ?? [])
    return deduplicatedMemories(candidates)
  }

  func memoryJSON(_ memory: WorkflowMemoryDeclaration) -> JSONValue {
    var object: JSONObject = ["id": .string(memory.id)]
    if let description = memory.description {
      object["description"] = .string(description)
    }
    if let purpose = memory.purpose {
      object["purpose"] = .string(purpose)
    }
    if let dataSchema = memory.dataSchema {
      object["dataSchema"] = dataSchema
    }
    if let scope = memory.scope {
      object["scope"] = .string(scope.rawValue)
    }
    if let defaultLimit = memory.defaultLimit {
      object["defaultLimit"] = .number(Double(defaultLimit))
    }
    return .object(object)
  }

  func memoryCommandHelp(
    workflowId: String,
    nodeId: String,
    workflowMemories: [WorkflowMemoryDeclaration],
    nodeMemories: [WorkflowMemoryDeclaration]
  ) -> String {
    let memoryIds = Array(Set((workflowMemories + nodeMemories).map(\.id))).sorted()
    guard !memoryIds.isEmpty else {
      return ""
    }
    let memoryList = memoryIds.joined(separator: ", ")
    let crossWorkflowIds = nodeMemories
      .filter { $0.scope == .crossWorkflow }
      .map(\.id)
      .sorted()
      .joined(separator: ", ")
    let crossWorkflowHelp = crossWorkflowIds.isEmpty
      ? ""
      : "\nCross-workflow memory ids (\(crossWorkflowIds)) may be loaded or searched with --all-workflows when this node should share memory across Discord, Telegram, Matrix, container, or other workflow entrypoints."
    return """
      Available Riela memory ids for this node: \(memoryList).
      Save JSON memory: riela memory save <memory-id> --workflow-id \(workflowId) --node-id \(nodeId) --payload-json '<json>'.
      Load recent memory: riela memory load <memory-id> --workflow-id \(workflowId) --node-id \(nodeId) --limit 30.
      Search memory with grep-style regular expressions: riela memory search <memory-id> --workflow-id \(workflowId) --match '<regex>' --limit 30.
      Inspect memory metadata before searching: riela memory metadata <memory-id>.
      List unique tags or related record ids with pagination: riela memory tags <memory-id> --limit 30 --offset 0; riela memory related-ids <memory-id> --limit 30 --offset 0.
      Save/search can include up to 10 tags with repeated --tag and up to 10 same-database related record ids with repeated --related-id.
      Memory root for command/container nodes is available as $RIELA_MEMORY_ROOT and can be passed to riela memory commands with --memory-root "$RIELA_MEMORY_ROOT".\(crossWorkflowHelp)
      """
  }

  func memoryGuidance(variables: JSONObject) -> String? {
    guard case let .string(help)? = variables["memoryCommandHelp"], !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return help
  }

  func resolvedMemoryRootDirectory(request: DeterministicWorkflowRunRequest) -> String {
    if let memoryRootDirectory = request.memoryRootDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
      !memoryRootDirectory.isEmpty {
      return memoryRootDirectory
    }
    if let memoryRoot = stringValue(at: ["workflowInput", "memoryRoot"], in: request.variables)
      ?? stringValue(at: ["memoryRoot"], in: request.variables) {
      return memoryRoot
    }
    if let environmentRoot = ProcessInfo.processInfo.environment["RIELA_MEMORY_ROOT"],
      !environmentRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return environmentRoot
    }
    return RielaMemoryStore.defaultRootDirectory()
  }

  func registerMemoryMetadata(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?,
    request: DeterministicWorkflowRunRequest
  ) throws {
    let memories = deduplicatedMemories((workflow.memories ?? []) + effectiveNodeMemories(
      workflow: workflow,
      step: step,
      payload: payload
    ))
    guard !memories.isEmpty else {
      return
    }
    let store = RielaMemoryStore(rootDirectory: resolvedMemoryRootDirectory(request: request))
    for memory in memories {
      _ = try store.registerMetadata(
        memoryId: memory.id,
        description: memory.description,
        purpose: memory.purpose,
        dataSchema: memory.dataSchema.map(memoryJSONValue)
      )
    }
  }

  func shouldRecordAutomaticMemory(for registryNode: WorkflowNodeRegistryRef) -> Bool {
    guard let addon = registryNode.addon else {
      return true
    }
    return !builtinMemoryAddonNames.contains(addon.name)
  }

  func recordNodeMemoryInbox(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?,
    request: DeterministicWorkflowRunRequest,
    session: WorkflowSession,
    executionIndex: Int,
    resolvedInput: WorkflowResolvedMessageInput
  ) throws {
    try recordNodeMemoryInbox(
      workflow: workflow,
      step: step,
      payload: payload,
      request: request,
      sessionId: session.sessionId,
      executionIndex: executionIndex,
      resolvedInputPayload: resolvedInput.payload
    )
  }

  func recordNodeMemoryInbox(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?,
    request: DeterministicWorkflowRunRequest,
    sessionId: String,
    executionIndex: Int,
    resolvedInputPayload: JSONObject
  ) throws {
    let memories = effectiveNodeMemories(workflow: workflow, step: step, payload: payload)
    guard !memories.isEmpty else {
      return
    }
    let store = RielaMemoryStore(rootDirectory: resolvedMemoryRootDirectory(request: request))
    let memoryPayload = nodeMemoryPayload(
      direction: "inbox",
      workflowId: workflow.workflowId,
      sessionId: sessionId,
      stepId: step.id,
      nodeId: step.nodeId,
      executionIndex: executionIndex,
      valueKey: "input",
      value: .object(resolvedInputPayload)
    )
    try save(memoryPayload, to: memories, store: store, workflowId: workflow.workflowId, nodeId: step.nodeId)
  }

  func recordNodeMemoryOutbox(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?,
    request: DeterministicWorkflowRunRequest,
    publishResult: WorkflowPublicationResult,
    executionIndex: Int
  ) throws {
    let memories = effectiveNodeMemories(workflow: workflow, step: step, payload: payload)
    guard !memories.isEmpty else {
      return
    }
    let acceptedOutput = publishResult.stepExecution.acceptedOutput
    let outputValue = acceptedOutput.map { JSONValue.object($0.payload) } ?? .null
    var extra: JSONObject = [
      "executionId": .string(publishResult.stepExecution.executionId),
      "status": .string(publishResult.stepExecution.status.rawValue),
      "publishedMessages": .number(Double(publishResult.publishedMessages.count))
    ]
    if let acceptedOutput {
      extra["when"] = .object(acceptedOutput.when.mapValues(JSONValue.bool))
      extra["isRootOutput"] = .bool(acceptedOutput.isRootOutput)
    }
    let memoryPayload = nodeMemoryPayload(
      direction: "outbox",
      workflowId: workflow.workflowId,
      sessionId: publishResult.session.sessionId,
      stepId: step.id,
      nodeId: step.nodeId,
      executionIndex: executionIndex,
      valueKey: "output",
      value: outputValue,
      extra: extra
    )
    let store = RielaMemoryStore(rootDirectory: resolvedMemoryRootDirectory(request: request))
    try save(memoryPayload, to: memories, store: store, workflowId: workflow.workflowId, nodeId: step.nodeId)
  }

  func recordNodeMemoryFailureOutbox(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload?,
    request: DeterministicWorkflowRunRequest,
    sessionId: String,
    executionIndex: Int,
    error: Error
  ) throws {
    let memories = effectiveNodeMemories(workflow: workflow, step: step, payload: payload)
    guard !memories.isEmpty else {
      return
    }
    let memoryPayload = nodeMemoryPayload(
      direction: "outbox",
      workflowId: workflow.workflowId,
      sessionId: sessionId,
      stepId: step.id,
      nodeId: step.nodeId,
      executionIndex: executionIndex,
      valueKey: "output",
      value: .null,
      extra: [
        "status": .string(WorkflowStepExecutionStatus.failed.rawValue),
        "failureReason": .string(nodeMemoryFailureReason(error))
      ]
    )
    let store = RielaMemoryStore(rootDirectory: resolvedMemoryRootDirectory(request: request))
    try save(memoryPayload, to: memories, store: store, workflowId: workflow.workflowId, nodeId: step.nodeId)
  }

  func memoryEnvironmentVariables(request: DeterministicWorkflowRunRequest) -> JSONObject {
    ["memoryRoot": .string(resolvedMemoryRootDirectory(request: request))]
  }

  private func save(
    _ payload: MemoryJSONValue,
    to memories: [WorkflowMemoryDeclaration],
    store: RielaMemoryStore,
    workflowId: String,
    nodeId: String
  ) throws {
    for memory in memories {
      try store.save(memoryId: memory.id, workflowId: workflowId, nodeId: nodeId, payload: payload)
    }
  }

  private func nodeMemoryPayload(
    direction: String,
    workflowId: String,
    sessionId: String,
    stepId: String,
    nodeId: String,
    executionIndex: Int,
    valueKey: String,
    value: JSONValue,
    extra: JSONObject = [:]
  ) -> MemoryJSONValue {
    var object: JSONObject = [
      "source": .string("riela-node-manager"),
      "direction": .string(direction),
      "workflowId": .string(workflowId),
      "sessionId": .string(sessionId),
      "stepId": .string(stepId),
      "nodeId": .string(nodeId),
      "executionIndex": .number(Double(executionIndex)),
      valueKey: sanitizedNodeMemoryValue(value)
    ]
    for (key, value) in extra {
      object[key] = value
    }
    return memoryJSONValue(from: .object(object))
  }

  private func deduplicatedMemories(_ memories: [WorkflowMemoryDeclaration]) -> [WorkflowMemoryDeclaration] {
    var indexesById: [String: Int] = [:]
    var result: [WorkflowMemoryDeclaration] = []
    for memory in memories {
      if let index = indexesById[memory.id] {
        result[index] = result[index].fillingMissingFields(from: memory)
      } else {
        indexesById[memory.id] = result.count
        result.append(memory)
      }
    }
    return result
  }

  private func stringValue(at path: [String], in object: JSONObject) -> String? {
    guard let first = path.first else {
      return nil
    }
    guard let value = object[first] else {
      return nil
    }
    if path.count == 1, case let .string(string) = value {
      return string
    }
    guard case let .object(child) = value else {
      return nil
    }
    return stringValue(at: Array(path.dropFirst()), in: child)
  }

  private func nodeMemoryFailureReason(_ error: Error) -> String {
    if let adapterError = error as? AdapterExecutionError {
      return "\(adapterError.code.rawValue): \(adapterError.message)"
    }
    return String(describing: error)
  }
}

private func sanitizedNodeMemoryValue(_ value: JSONValue, depth: Int = 0) -> JSONValue {
  if depth >= 6 {
    return .string("[omitted: nested value]")
  }
  switch value {
  case let .string(text):
    return .string(text.truncatedForNodeMemory())
  case let .array(values):
    let prefix = values.prefix(20).map { sanitizedNodeMemoryValue($0, depth: depth + 1) }
    if values.count > prefix.count {
      return .array(prefix + [.string("[omitted: \(values.count - prefix.count) more items]")])
    }
    return .array(prefix)
  case let .object(object):
    var sanitized: JSONObject = [:]
    for (key, child) in object {
      if key == "records", object["recordsText"] != nil {
        sanitized[key] = .string("[omitted: records are available as recordsText]")
      } else {
        sanitized[key] = sanitizedNodeMemoryValue(child, depth: depth + 1)
      }
    }
    return .object(sanitized)
  case .null, .bool, .number:
    return value
  }
}

private extension WorkflowMemoryDeclaration {
  func fillingMissingFields(from other: WorkflowMemoryDeclaration) -> WorkflowMemoryDeclaration {
    WorkflowMemoryDeclaration(
      id: id,
      description: description ?? other.description,
      purpose: purpose ?? other.purpose,
      dataSchema: dataSchema ?? other.dataSchema,
      scope: scope ?? other.scope,
      defaultLimit: defaultLimit ?? other.defaultLimit
    )
  }
}

private let builtinMemoryAddonNames: Set<String> = [
  "riela/memory-save",
  "riela/memory-load",
  "riela/memory-search"
]

private func memoryJSONValue(from value: JSONValue) -> MemoryJSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(value):
    return .bool(value)
  case let .number(value):
    return .number(value)
  case let .string(value):
    return .string(value)
  case let .array(values):
    return .array(values.map(memoryJSONValue))
  case let .object(object):
    return .object(object.mapValues(memoryJSONValue))
  }
}

private extension String {
  func truncatedForNodeMemory(_ maxLength: Int = 2_000) -> String {
    guard count > maxLength else {
      return self
    }
    let endIndex = index(startIndex, offsetBy: maxLength)
    return String(self[..<endIndex]) + "..."
  }
}
