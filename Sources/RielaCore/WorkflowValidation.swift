import Foundation
import CoreFoundation

public enum WorkflowValidationSeverity: String, Codable, Sendable {
  case error
  case warning
}

public struct WorkflowValidationDiagnostic: Codable, Equatable, Sendable {
  public var severity: WorkflowValidationSeverity
  public var path: String
  public var message: String

  public init(severity: WorkflowValidationSeverity, path: String, message: String) {
    self.severity = severity
    self.path = path
    self.message = message
  }
}

public protocol WorkflowValidating: Sendable {
  func validate(_ workflow: WorkflowDefinition) -> [WorkflowValidationDiagnostic]
}

public struct AuthoredWorkflowValidationResult: Equatable, Sendable {
  public var workflow: WorkflowDefinition?
  public var diagnostics: [WorkflowValidationDiagnostic]

  public init(workflow: WorkflowDefinition?, diagnostics: [WorkflowValidationDiagnostic]) {
    self.workflow = workflow
    self.diagnostics = diagnostics
  }
}

public struct DefaultWorkflowValidator: WorkflowValidating {
  public init() {}

  public func validate(_ workflow: WorkflowDefinition) -> [WorkflowValidationDiagnostic] {
    var diagnostics: [WorkflowValidationDiagnostic] = []
    let registryIds = Set(workflow.nodeRegistry.map(\.id))
    let stepIds = Set(workflow.steps.map(\.id))

    if !stepIds.contains(workflow.entryStepId) {
      diagnostics.append(error("workflow.entryStepId", "must reference workflow.steps[] entry '\(workflow.entryStepId)'"))
    }
    if let managerStepId = workflow.managerStepId, !stepIds.contains(managerStepId) {
      diagnostics.append(error("workflow.managerStepId", "must reference workflow.steps[] entry '\(managerStepId)'"))
    }

    let workflowMemoryIds = Set((workflow.memories ?? []).map(\.id))
    for (index, node) in workflow.nodeRegistry.enumerated() {
      validateMemoryAddonDeclarations(
        node,
        path: "workflow.nodes[\(index)]",
        workflowMemoryIds: workflowMemoryIds,
        diagnostics: &diagnostics
      )
    }

    for step in workflow.steps {
      if !registryIds.contains(step.nodeId) {
        diagnostics.append(error("workflow.steps.\(step.id).nodeId", "must reference workflow.nodes[] entry '\(step.nodeId)'"))
      }
      for transition in step.transitions ?? [] {
        if transition.toWorkflowId == nil && !stepIds.contains(transition.toStepId) {
          diagnostics.append(
            error("workflow.steps.\(step.id).transitions.toStepId", "must reference workflow.steps[] entry '\(transition.toStepId)'")
          )
        }
        if let joinStepId = transition.fanout?.joinStepId, !stepIds.contains(joinStepId) {
          diagnostics.append(
            error("workflow.steps.\(step.id).transitions.fanout.joinStepId", "must reference workflow.steps[] entry '\(joinStepId)'")
          )
        }
      }
    }

    return diagnostics
  }
}

public func validateAuthoredWorkflowData(
  _ data: Data,
  validator: any WorkflowValidating = DefaultWorkflowValidator()
) -> AuthoredWorkflowValidationResult {
  var diagnostics: [WorkflowValidationDiagnostic] = []

  let jsonObject: Any
  do {
    jsonObject = try JSONSerialization.jsonObject(with: data)
  } catch {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [WorkflowValidationDiagnostic(severity: .error, path: "workflow", message: "must be valid JSON")]
    )
  }

  guard let raw = jsonObject as? [String: Any] else {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [WorkflowValidationDiagnostic(severity: .error, path: "workflow", message: "must be an object")]
    )
  }

  diagnostics.append(contentsOf: validateRawAuthoredWorkflow(raw))

  let decoded: AuthoredWorkflowJSON?
  do {
    decoded = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)
  } catch let decodeError {
    diagnostics.append(error("workflow", "failed to decode authored workflow JSON: \(decodeError.localizedDescription)"))
    return AuthoredWorkflowValidationResult(workflow: nil, diagnostics: diagnostics)
  }

  guard let authoredWorkflow = decoded else {
    return AuthoredWorkflowValidationResult(workflow: nil, diagnostics: diagnostics)
  }

  let hasBlockingErrors = diagnostics.contains { $0.severity == .error }
  guard !hasBlockingErrors, let workflow = materializeWorkflowDefinition(from: authoredWorkflow) else {
    return AuthoredWorkflowValidationResult(workflow: nil, diagnostics: diagnostics)
  }

  diagnostics.append(contentsOf: validator.validate(workflow))
  return AuthoredWorkflowValidationResult(
    workflow: diagnostics.contains { $0.severity == .error } ? nil : workflow,
    diagnostics: diagnostics
  )
}

public func validateAuthoredWorkflowJSON(
  _ workflow: AuthoredWorkflowJSON,
  validator: any WorkflowValidating = DefaultWorkflowValidator()
) -> AuthoredWorkflowValidationResult {
  let typedDiagnostics = validateTypedAuthoredWorkflow(workflow)
  if typedDiagnostics.contains(where: { $0.severity == .error }) {
    return AuthoredWorkflowValidationResult(workflow: nil, diagnostics: typedDiagnostics)
  }

  guard let definition = materializeWorkflowDefinition(from: workflow) else {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [error("workflow.entryStepId", "must be a non-empty string")]
    )
  }

  let diagnostics = validator.validate(definition)
  return AuthoredWorkflowValidationResult(
    workflow: diagnostics.contains { $0.severity == .error } ? nil : definition,
    diagnostics: diagnostics
  )
}

private func validateTypedAuthoredWorkflow(_ workflow: AuthoredWorkflowJSON) -> [WorkflowValidationDiagnostic] {
  var diagnostics: [WorkflowValidationDiagnostic] = []
  validateNonEmptyString(workflow.workflowId, path: "workflow.workflowId", diagnostics: &diagnostics)
  if !workflow.workflowId.isEmpty, !isSafeWorkflowId(workflow.workflowId) {
    diagnostics.append(
      error(
        "workflow.workflowId",
        "must start with an alphanumeric character and contain only letters, digits, hyphens, or underscores"
      )
    )
  }
  validateMemoryDeclarations(workflow.memories, path: "workflow.memories", diagnostics: &diagnostics)
  let workflowMemoryIds = Set((workflow.memories ?? []).map(\.id))

  var nodeIds: Set<String> = []
  for (index, node) in workflow.nodes.enumerated() {
    let path = "workflow.nodes[\(index)]"
    guard !node.id.isEmpty else {
      diagnostics.append(error("\(path).id", "must be a non-empty string"))
      continue
    }
    if !isSafeNodeId(node.id) {
      diagnostics.append(error("\(path).id", "must match ^[a-z0-9][a-z0-9-]{1,63}$"))
    }
    if nodeIds.contains(node.id) {
      diagnostics.append(error("\(path).id", "must be unique across workflow.nodes[]"))
    }
    nodeIds.insert(node.id)
    if node.nodeFile == nil && node.addon == nil {
      diagnostics.append(error(path, "must define nodeFile, inline node, or addon"))
    }
    if let nodeFile = node.nodeFile {
      validateWorkflowRelativePath(nodeFile, fieldName: "nodeFile", path: "\(path).nodeFile", diagnostics: &diagnostics)
    }
    validateInputFilters(node.inputFilters, path: "\(path).inputFilters", diagnostics: &diagnostics)
    validateMemoryDeclarations(node.memories, path: "\(path).memories", diagnostics: &diagnostics)
    validateMemoryAddonDeclarations(
      node,
      path: path,
      workflowMemoryIds: workflowMemoryIds,
      diagnostics: &diagnostics
    )
  }

  let effectiveSteps = workflow.steps ?? workflow.nodes.map { WorkflowStepRef(id: $0.id, nodeId: $0.id) }
  var stepIds: Set<String> = []
  var duplicateStepIds: Set<String> = []
  for step in effectiveSteps where !step.id.isEmpty {
    if stepIds.contains(step.id) {
      duplicateStepIds.insert(step.id)
    }
    stepIds.insert(step.id)
  }

  for (index, step) in effectiveSteps.enumerated() {
    let path = "workflow.steps[\(index)]"
    guard !step.id.isEmpty else {
      diagnostics.append(error("\(path).id", "must be a non-empty string"))
      continue
    }
    if duplicateStepIds.contains(step.id) {
      diagnostics.append(error("\(path).id", "must be unique across workflow.steps[]"))
    }
    if let stepFile = step.stepFile {
      validateWorkflowRelativePath(stepFile, fieldName: "stepFile", path: "\(path).stepFile", diagnostics: &diagnostics)
    }
    if step.nodeId.isEmpty {
      diagnostics.append(error("\(path).nodeId", "must be a non-empty string after step files are resolved"))
    } else if !nodeIds.contains(step.nodeId) {
      diagnostics.append(error("workflow.steps.\(step.id).nodeId", "must reference workflow.nodes[] entry '\(step.nodeId)'"))
    }
    if let transitions = step.transitions {
      validateTypedTransitions(transitions, path: "\(path).transitions", stepIds: stepIds, diagnostics: &diagnostics)
    }
  }

  let effectiveEntryStepId = workflow.entryStepId ?? effectiveSteps.first?.id
  if effectiveEntryStepId == nil || effectiveEntryStepId?.isEmpty == true {
    diagnostics.append(error("workflow.entryStepId", "must be a non-empty string"))
  } else if let entryStepId = effectiveEntryStepId, !stepIds.contains(entryStepId) {
    diagnostics.append(error("workflow.entryStepId", "must reference workflow.steps[] entry '\(entryStepId)'"))
  }

  if let managerStepId = workflow.managerStepId {
    if managerStepId.isEmpty {
      diagnostics.append(error("workflow.managerStepId", "must be a non-empty string"))
    } else if !stepIds.contains(managerStepId) {
      diagnostics.append(error("workflow.managerStepId", "must reference workflow.steps[] entry '\(managerStepId)'"))
    }
  }

  return diagnostics
}

private func validateTypedTransitions(
  _ transitions: [WorkflowStepTransition],
  path: String,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  for (index, transition) in transitions.enumerated() {
    let transitionPath = "\(path)[\(index)]"
    if transition.toStepId.isEmpty {
      diagnostics.append(error("\(transitionPath).toStepId", "must be a non-empty string"))
    } else if transition.toWorkflowId == nil && !stepIds.contains(transition.toStepId) {
      diagnostics.append(error("\(transitionPath).toStepId", "must reference workflow.steps[] entry '\(transition.toStepId)'"))
    }
    if let toWorkflowId = transition.toWorkflowId {
      validateNonEmptyString(toWorkflowId, path: "\(transitionPath).toWorkflowId", diagnostics: &diagnostics)
    }
    if let resumeStepId = transition.resumeStepId {
      validateNonEmptyString(resumeStepId, path: "\(transitionPath).resumeStepId", diagnostics: &diagnostics)
    }
    if let label = transition.label {
      validateNonEmptyString(label, path: "\(transitionPath).label", diagnostics: &diagnostics)
    }
    if let fanout = transition.fanout {
      validateTypedFanout(fanout, path: "\(transitionPath).fanout", diagnostics: &diagnostics)
    }
  }
}

private func validateTypedFanout(
  _ fanout: WorkflowStepFanout,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  validateNonEmptyString(fanout.groupId, path: "\(path).groupId", diagnostics: &diagnostics)
  validateNonEmptyString(fanout.itemsFrom, path: "\(path).itemsFrom", diagnostics: &diagnostics)
  validateNonEmptyString(fanout.joinStepId, path: "\(path).joinStepId", diagnostics: &diagnostics)
  if !fanout.itemsFrom.isEmpty, !fanout.itemsFrom.hasPrefix("/") {
    diagnostics.append(error("\(path).itemsFrom", "must be a JSON Pointer"))
  }
  if let concurrency = fanout.concurrency, concurrency <= 0 {
    diagnostics.append(error("\(path).concurrency", "must be a positive integer"))
  }
}

private let rejectedTopLevelFieldMessages: [String: String] = [
  "managerRuntimeId": "is not part of the step-addressed workflow schema",
  "managerNodeId": "is not part of the step-addressed workflow schema",
  "entryNodeId": "is not part of the step-addressed workflow schema",
  "subWorkflows": "is not part of the step-addressed workflow schema",
  "workflowCalls": "is not part of the step-addressed workflow schema",
  "subWorkflowConversations": "is not part of the step-addressed workflow schema",
  "edges": "is not part of the step-addressed workflow schema; local step-to-step routing must be authored on workflow.steps[].transitions",
  "loops": "is not part of the step-addressed workflow schema",
  "branching": "is not part of the step-addressed workflow schema"
]

private func validateRawAuthoredWorkflow(_ raw: [String: Any]) -> [WorkflowValidationDiagnostic] {
  var diagnostics: [WorkflowValidationDiagnostic] = []

  for (field, message) in rejectedTopLevelFieldMessages where raw[field] != nil {
    diagnostics.append(error("workflow.\(field)", message))
  }

  validateNonEmptyString(raw["workflowId"], path: "workflow.workflowId", diagnostics: &diagnostics)
  if let workflowId = raw["workflowId"] as? String, !workflowId.isEmpty, !isSafeWorkflowId(workflowId) {
    diagnostics.append(
      error(
        "workflow.workflowId",
        "must start with an alphanumeric character and contain only letters, digits, hyphens, or underscores"
      )
    )
  }

  if raw["defaults"] == nil {
    diagnostics.append(error("workflow.defaults", "must be an object"))
  } else if let defaults = raw["defaults"] as? [String: Any] {
    if let nodeTimeoutMs = defaults["nodeTimeoutMs"] {
      validateNumberField(nodeTimeoutMs, path: "workflow.defaults.nodeTimeoutMs", diagnostics: &diagnostics)
    }
    if let maxLoopIterations = defaults["maxLoopIterations"] {
      validateNumberField(maxLoopIterations, path: "workflow.defaults.maxLoopIterations", diagnostics: &diagnostics)
    }
    if let fanoutConcurrency = defaults["fanoutConcurrency"] {
      validatePositiveInteger(fanoutConcurrency, path: "workflow.defaults.fanoutConcurrency", diagnostics: &diagnostics)
    }
  } else {
    diagnostics.append(error("workflow.defaults", "must be an object"))
  }
  validateRawMemoryDeclarations(raw["memories"], path: "workflow.memories", diagnostics: &diagnostics)

  guard let nodeEntries = raw["nodes"] as? [Any] else {
    diagnostics.append(error("workflow.nodes", "must be an array"))
    return diagnostics
  }
  validateNodeRegistry(nodeEntries, diagnostics: &diagnostics)
  if let entryStepId = raw["entryStepId"] {
    validateNonEmptyString(entryStepId, path: "workflow.entryStepId", diagnostics: &diagnostics)
  }
  if let managerStepId = raw["managerStepId"] {
    validateNonEmptyString(managerStepId, path: "workflow.managerStepId", diagnostics: &diagnostics)
  }

  let stepEntries = raw["steps"] as? [Any] ?? nodeEntries.compactMap { node -> [String: Any]? in
    guard let node = node as? [String: Any], let id = node["id"] as? String else {
      return nil
    }
    return ["id": id, "nodeId": id]
  }
  validateSteps(stepEntries, nodeEntries: nodeEntries, raw: raw, diagnostics: &diagnostics)

  return diagnostics
}

private func validateNodeRegistry(_ entries: [Any], diagnostics: inout [WorkflowValidationDiagnostic]) {
  var seenIds: Set<String> = []
  let allowedKeys: Set<String> = ["id", "nodeFile", "addon", "execution", "kind", "repeat", "inputFilters", "memories"]

  for (index, rawEntry) in entries.enumerated() {
    let path = "workflow.nodes[\(index)]"
    guard let entry = rawEntry as? [String: Any] else {
      diagnostics.append(error(path, "must be an object"))
      continue
    }

    for key in entry.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(path).\(key)", "uses an unsupported step-addressed node registry field"))
    }

    guard let id = entry["id"] as? String, !id.isEmpty else {
      diagnostics.append(error("\(path).id", "must be a non-empty string"))
      continue
    }
    if !isSafeNodeId(id) {
      diagnostics.append(error("\(path).id", "must match ^[a-z0-9][a-z0-9-]{1,63}$"))
    }
    if seenIds.contains(id) {
      diagnostics.append(error("\(path).id", "must be unique across workflow.nodes[]"))
    }
    seenIds.insert(id)

    if entry["nodeFile"] == nil && entry["addon"] == nil {
      diagnostics.append(error(path, "must define nodeFile, inline node, or addon"))
    }
    if let nodeFile = entry["nodeFile"] {
      validateWorkflowRelativePath(nodeFile, fieldName: "nodeFile", path: "\(path).nodeFile", diagnostics: &diagnostics)
    }
    validateRawInputFilters(entry["inputFilters"], path: "\(path).inputFilters", diagnostics: &diagnostics)
    validateRawMemoryDeclarations(entry["memories"], path: "\(path).memories", diagnostics: &diagnostics)
  }
}

private func validateSteps(
  _ entries: [Any],
  nodeEntries: [Any],
  raw: [String: Any],
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  var nodeIds: Set<String> = []
  for node in nodeEntries {
    if let node = node as? [String: Any], let id = node["id"] as? String {
      nodeIds.insert(id)
    }
  }

  var stepIds: Set<String> = []
  var duplicateStepIds: Set<String> = []
  let allowedKeys: Set<String> = [
    "id",
    "stepFile",
    "nodeId",
    "description",
    "role",
    "promptVariant",
    "timeoutMs",
    "stallTimeoutMs",
    "sessionPolicy",
    "transitions"
  ]

  for rawEntry in entries {
    guard let entry = rawEntry as? [String: Any], let id = entry["id"] as? String, !id.isEmpty else {
      continue
    }
    if stepIds.contains(id) {
      duplicateStepIds.insert(id)
    }
    stepIds.insert(id)
  }

  for (index, rawEntry) in entries.enumerated() {
    let path = "workflow.steps[\(index)]"
    guard let entry = rawEntry as? [String: Any] else {
      diagnostics.append(error(path, "must be an object"))
      continue
    }

    for key in entry.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(path).\(key)", "uses an unsupported step field"))
    }

    guard let id = entry["id"] as? String, !id.isEmpty else {
      diagnostics.append(error("\(path).id", "must be a non-empty string"))
      continue
    }
    if duplicateStepIds.contains(id) {
      diagnostics.append(error("\(path).id", "must be unique across workflow.steps[]"))
    }
    if let stepFile = entry["stepFile"] {
      validateWorkflowRelativePath(stepFile, fieldName: "stepFile", path: "\(path).stepFile", diagnostics: &diagnostics)
    }

    guard let nodeId = entry["nodeId"] as? String, !nodeId.isEmpty else {
      diagnostics.append(error("\(path).nodeId", "must be a non-empty string after step files are resolved"))
      continue
    }
    if !nodeIds.contains(nodeId) {
      diagnostics.append(error("workflow.steps.\(id).nodeId", "must reference workflow.nodes[] entry '\(nodeId)'"))
    }

    if let role = entry["role"], (role as? String) != "manager" && (role as? String) != "worker" {
      diagnostics.append(error("\(path).role", "must be 'manager' or 'worker' when provided"))
    }
    if let timeoutMs = entry["timeoutMs"] {
      validateNumberField(timeoutMs, path: "\(path).timeoutMs", diagnostics: &diagnostics)
    }
    if let stallTimeoutMs = entry["stallTimeoutMs"] {
      validateNumberField(stallTimeoutMs, path: "\(path).stallTimeoutMs", diagnostics: &diagnostics)
    }
    if let transitions = entry["transitions"] {
      validateTransitions(transitions, path: "\(path).transitions", stepIds: stepIds, diagnostics: &diagnostics)
    }
  }

  let effectiveEntryStepId = raw["entryStepId"] as? String ?? entries.compactMap { entry -> String? in
    guard let entry = entry as? [String: Any] else {
      return nil
    }
    return entry["id"] as? String
  }.first
  if effectiveEntryStepId == nil || effectiveEntryStepId?.isEmpty == true {
    diagnostics.append(error("workflow.entryStepId", "must be a non-empty string"))
  } else if let entryStepId = effectiveEntryStepId, !stepIds.contains(entryStepId) {
    diagnostics.append(error("workflow.entryStepId", "must reference workflow.steps[] entry '\(entryStepId)'"))
  }

  if let managerStepId = raw["managerStepId"] as? String, !managerStepId.isEmpty, !stepIds.contains(managerStepId) {
    diagnostics.append(error("workflow.managerStepId", "must reference workflow.steps[] entry '\(managerStepId)'"))
  }
}

private func validateTransitions(
  _ raw: Any,
  path: String,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let entries = raw as? [Any] else {
    diagnostics.append(error(path, "must be an array when provided"))
    return
  }

  for (index, rawEntry) in entries.enumerated() {
    let transitionPath = "\(path)[\(index)]"
    guard let entry = rawEntry as? [String: Any] else {
      diagnostics.append(error(transitionPath, "must be an object"))
      continue
    }

    guard let toStepId = entry["toStepId"] as? String, !toStepId.isEmpty else {
      diagnostics.append(error("\(transitionPath).toStepId", "must be a non-empty string"))
      continue
    }
    if entry["toWorkflowId"] == nil && !stepIds.contains(toStepId) {
      diagnostics.append(error("\(transitionPath).toStepId", "must reference workflow.steps[] entry '\(toStepId)'"))
    }
    if let toWorkflowId = entry["toWorkflowId"] {
      validateNonEmptyString(toWorkflowId, path: "\(transitionPath).toWorkflowId", diagnostics: &diagnostics)
    }
    if let resumeStepId = entry["resumeStepId"] {
      validateNonEmptyString(resumeStepId, path: "\(transitionPath).resumeStepId", diagnostics: &diagnostics)
    }
    if let label = entry["label"] {
      validateNonEmptyString(label, path: "\(transitionPath).label", diagnostics: &diagnostics)
    }
    if let fanout = entry["fanout"] {
      validateFanout(fanout, path: "\(transitionPath).fanout", diagnostics: &diagnostics)
    }
  }
}

private func validateFanout(_ raw: Any, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let fanout = raw as? [String: Any] else {
    diagnostics.append(error(path, "must be an object when provided"))
    return
  }

  validateNonEmptyString(fanout["groupId"], path: "\(path).groupId", diagnostics: &diagnostics)
  validateNonEmptyString(fanout["itemsFrom"], path: "\(path).itemsFrom", diagnostics: &diagnostics)
  validateNonEmptyString(fanout["joinStepId"], path: "\(path).joinStepId", diagnostics: &diagnostics)
  if let itemsFrom = fanout["itemsFrom"] as? String, !itemsFrom.isEmpty, !itemsFrom.hasPrefix("/") {
    diagnostics.append(error("\(path).itemsFrom", "must be a JSON Pointer"))
  }
  if let concurrency = fanout["concurrency"] {
    validatePositiveInteger(concurrency, path: "\(path).concurrency", diagnostics: &diagnostics)
  }
}

private func materializeWorkflowDefinition(from workflow: AuthoredWorkflowJSON) -> WorkflowDefinition? {
  let steps = workflow.steps ?? workflow.nodes.map { WorkflowStepRef(id: $0.id, nodeId: $0.id) }
  guard let entryStepId = workflow.entryStepId ?? steps.first?.id else {
    return nil
  }

  var registryById: [String: WorkflowNodeRegistryRef] = [:]
  for node in workflow.nodes where registryById[node.id] == nil {
    registryById[node.id] = node
  }
  let runtimeNodes = steps.compactMap { step -> WorkflowNodeRef? in
    guard let registryNode = registryById[step.nodeId] else {
      return nil
    }
    return WorkflowNodeRef(
      id: step.id,
      nodeFile: registryNode.nodeFile ?? (registryNode.addon == nil ? "nodes/\(step.nodeId).json" : nil),
      addon: registryNode.addon,
      kind: registryNode.kind,
      role: step.role,
      execution: registryNode.execution,
      repeatPolicy: registryNode.repeatPolicy,
      inputFilters: registryNode.inputFilters,
      memories: registryNode.memories
    )
  }

  return WorkflowDefinition(
    workflowId: workflow.workflowId,
    description: workflow.description ?? "",
    defaults: workflow.defaults,
    prompts: workflow.prompts,
    memories: workflow.memories,
    managerStepId: workflow.managerStepId,
    entryStepId: entryStepId,
    nodeRegistry: workflow.nodes,
    steps: steps,
    nodes: runtimeNodes
  )
}

private func validateInputFilters(
  _ filters: [WorkflowInputFilter]?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let filters else {
    return
  }
  if filters.isEmpty {
    diagnostics.append(error(path, "must contain at least one filter when present"))
  }
  for (index, filter) in filters.enumerated() {
    let filterPath = "\(path)[\(index)]"
    if filter.kind.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      diagnostics.append(error("\(filterPath).kind", "must be a non-empty string"))
    } else if filter.kind != .telegram {
      diagnostics.append(error("\(filterPath).kind", "must be 'telegram'"))
    }
    let hasExpression = filter.expression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasBuiltin = filter.builtin != nil
    if hasExpression == hasBuiltin {
      diagnostics.append(error(filterPath, "must specify exactly one of expression or builtin"))
    }
  }
}

private func validateMemoryDeclarations(
  _ memories: [WorkflowMemoryDeclaration]?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let memories else {
    return
  }
  if memories.isEmpty {
    diagnostics.append(error(path, "must contain at least one memory when present"))
  }
  var seenIds: Set<String> = []
  for (index, memory) in memories.enumerated() {
    let memoryPath = "\(path)[\(index)]"
    validateMemoryId(memory.id, path: "\(memoryPath).id", diagnostics: &diagnostics)
    if !memory.id.isEmpty {
      if seenIds.contains(memory.id) {
        diagnostics.append(error("\(memoryPath).id", "must be unique within this memory declaration list"))
      }
      seenIds.insert(memory.id)
    }
    if let defaultLimit = memory.defaultLimit, defaultLimit <= 0 {
      diagnostics.append(error("\(memoryPath).defaultLimit", "must be a positive integer"))
    }
  }
}

private func validateMemoryAddonDeclarations(
  _ node: WorkflowNodeRegistryRef,
  path: String,
  workflowMemoryIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let addon = node.addon else {
    return
  }
  validateMemoryAddonConfig(addon, path: path, diagnostics: &diagnostics)
  let memoryIds = addonMemoryIds(addon)
  guard !memoryIds.isEmpty else {
    return
  }
  let nodeMemoryIds = Set((node.memories ?? []).map(\.id))
  for memoryId in memoryIds {
    if !workflowMemoryIds.contains(memoryId) {
      diagnostics.append(
        error(
          "\(path).addon.config.memoryId",
          "memory addon uses '\(memoryId)' but workflow.memories does not declare it"
        )
      )
    }
    if !nodeMemoryIds.contains(memoryId) {
      diagnostics.append(
        error(
          "\(path).memories",
          "memory addon uses '\(memoryId)' but node memories do not declare it"
        )
      )
    }
  }
}

private func validateMemoryAddonConfig(
  _ addon: WorkflowNodeAddonRef,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard addon.name == "riela/chat-memory-raw-daily-summary" else {
    return
  }
  let rawMemoryId = stringValue(addon.config?["rawMemoryId"]) ?? defaultRawMemoryId
  let summaryMemoryId = stringValue(addon.config?["summaryMemoryId"]) ?? defaultSummaryMemoryId
  if rawMemoryId == summaryMemoryId {
    diagnostics.append(
      error(
        "\(path).addon.config.summaryMemoryId",
        "rawMemoryId and summaryMemoryId must be distinct memory ids"
      )
    )
  }
}

private func validateRawMemoryDeclarations(
  _ rawMemories: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let rawMemories else {
    return
  }
  guard let memories = rawMemories as? [Any] else {
    diagnostics.append(error(path, "must be an array"))
    return
  }
  if memories.isEmpty {
    diagnostics.append(error(path, "must contain at least one memory when present"))
  }
  var seenIds: Set<String> = []
  for (index, rawMemory) in memories.enumerated() {
    let memoryPath = "\(path)[\(index)]"
    guard let memory = rawMemory as? [String: Any] else {
      diagnostics.append(error(memoryPath, "must be an object"))
      continue
    }
    let allowedKeys: Set<String> = ["id", "description", "purpose", "dataSchema", "scope", "defaultLimit"]
    for key in memory.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(memoryPath).\(key)", "uses an unsupported memory declaration field"))
    }
    if let id = memory["id"] as? String {
      validateMemoryId(id, path: "\(memoryPath).id", diagnostics: &diagnostics)
      if !id.isEmpty {
        if seenIds.contains(id) {
          diagnostics.append(error("\(memoryPath).id", "must be unique within this memory declaration list"))
        }
        seenIds.insert(id)
      }
    } else {
      diagnostics.append(error("\(memoryPath).id", "must be a non-empty string"))
    }
    if let scope = memory["scope"] as? String, WorkflowMemoryScope(rawValue: scope) == nil {
      diagnostics.append(error("\(memoryPath).scope", "must be workflow, node, or cross-workflow"))
    }
    if let defaultLimit = memory["defaultLimit"] {
      validatePositiveInteger(defaultLimit, path: "\(memoryPath).defaultLimit", diagnostics: &diagnostics)
    }
  }
}

private let simpleMemoryAddonNames: Set<String> = [
  "riela/memory-save",
  "riela/memory-update",
  "riela/memory-load",
  "riela/memory-search"
]

private let personaMemoryAddonNames: Set<String> = [
  "riela/chat-persona-memory-read",
  "riela/chat-persona-memory-write"
]

private let defaultMemoryId = "chat-memory"
private let defaultPersonaMemoryId = "persona-chat-memory"
private let defaultRawMemoryId = "raw-chat-log"
private let defaultSummaryMemoryId = "daily-chat-summary"

private func addonMemoryIds(_ addon: WorkflowNodeAddonRef) -> [String] {
  if simpleMemoryAddonNames.contains(addon.name) {
    return [stringValue(addon.config?["memoryId"]) ?? defaultMemoryId]
  }
  if personaMemoryAddonNames.contains(addon.name) {
    return [stringValue(addon.config?["memoryId"]) ?? defaultPersonaMemoryId]
  }
  if addon.name == "riela/chat-memory-raw-daily-summary" {
    return [
      stringValue(addon.config?["rawMemoryId"]) ?? defaultRawMemoryId,
      stringValue(addon.config?["summaryMemoryId"]) ?? defaultSummaryMemoryId
    ]
  }
  return []
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(value) = value, !value.isEmpty else {
    return nil
  }
  return value
}

private func validateMemoryId(_ value: String, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard !value.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
  if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil {
    diagnostics.append(error(path, "must start with an alphanumeric character and contain only letters, digits, hyphens, underscores, or dots"))
  }
}

private func validateRawInputFilters(
  _ rawFilters: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let rawFilters else {
    return
  }
  guard let filters = rawFilters as? [Any] else {
    diagnostics.append(error(path, "must be an array"))
    return
  }
  if filters.isEmpty {
    diagnostics.append(error(path, "must contain at least one filter when present"))
  }
  for (index, rawFilter) in filters.enumerated() {
    let filterPath = "\(path)[\(index)]"
    guard let filter = rawFilter as? [String: Any] else {
      diagnostics.append(error(filterPath, "must be an object"))
      continue
    }
    let allowedKeys: Set<String> = ["kind", "language", "expression", "builtin", "config"]
    for key in filter.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(filterPath).\(key)", "uses an unsupported input filter field"))
    }
    validateNonEmptyString(filter["kind"], path: "\(filterPath).kind", diagnostics: &diagnostics)
    if let kind = filter["kind"] as? String, !kind.isEmpty, kind != WorkflowInputFilterKind.telegram.rawValue {
      diagnostics.append(error("\(filterPath).kind", "must be 'telegram'"))
    }
    let hasExpression = nonEmptyString(filter["expression"]) != nil
    let hasBuiltin = nonEmptyString(filter["builtin"]) != nil
    if hasExpression == hasBuiltin {
      diagnostics.append(error(filterPath, "must specify exactly one of expression or builtin"))
    }
    if hasExpression {
      validateNonEmptyString(filter["language"], path: "\(filterPath).language", diagnostics: &diagnostics)
    }
    if let language = filter["language"] as? String, language != WorkflowInputFilterLanguage.javascript.rawValue {
      diagnostics.append(error("\(filterPath).language", "must be 'javascript'"))
    }
    if let builtin = filter["builtin"] as? String,
      !WorkflowInputFilterBuiltin.allCases.map(\.rawValue).contains(builtin) {
      diagnostics.append(error("\(filterPath).builtin", "uses an unsupported builtin input filter"))
    }
    if let config = filter["config"], !(config is [String: Any]) {
      diagnostics.append(error("\(filterPath).config", "must be an object"))
    }
  }
}

private func error(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
  WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
}

private func validateNonEmptyString(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
}

private func nonEmptyString(_ value: Any?) -> String? {
  guard let string = value as? String else {
    return nil
  }
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func validateWorkflowRelativePath(
  _ value: Any?,
  fieldName: String,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
  guard isSafeWorkflowRelativePath(string) else {
    diagnostics.append(error(path, "\(fieldName) '\(string)' must be a workflow-relative path without '.' or '..' segments"))
    return
  }
}

private func validateNumberField(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let value, isFiniteNumber(value) else {
    diagnostics.append(error(path, "must be a finite number"))
    return
  }
}

private func validatePositiveInteger(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let number = value as? NSNumber,
    !isBooleanNumber(number),
    number.doubleValue > 0,
    floor(number.doubleValue) == number.doubleValue
  else {
    diagnostics.append(error(path, "must be a positive integer"))
    return
  }
}

private func isFiniteNumber(_ value: Any) -> Bool {
  if let number = value as? NSNumber {
    return !isBooleanNumber(number) && number.doubleValue.isFinite
  }
  switch value {
  case let int as Int:
    return Double(int).isFinite
  case let int as Int64:
    return Double(int).isFinite
  case let int as UInt64:
    return Double(int).isFinite
  case let double as Double:
    return double.isFinite
  case let float as Float:
    return float.isFinite
  default:
    return false
  }
}

private func isBooleanNumber(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func isSafeWorkflowId(_ value: String) -> Bool {
  matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#)
}

private func isSafeNodeId(_ value: String) -> Bool {
  matches(value, pattern: #"^[a-z0-9][a-z0-9-]{1,63}$"#)
}

private func isSafeWorkflowRelativePath(_ value: String) -> Bool {
  if value.isEmpty || value.hasPrefix("/") || value.hasPrefix("\\") || matches(value, pattern: #"^[A-Za-z]:[\\/]"#) {
    return false
  }
  let segments = value.split { character in
    character == "/" || character == "\\"
  }
  if segments.isEmpty {
    return false
  }
  return !segments.contains { segment in
    segment == "." || segment == ".."
  }
}

private func matches(_ value: String, pattern: String) -> Bool {
  value.range(of: pattern, options: .regularExpression) != nil
}
