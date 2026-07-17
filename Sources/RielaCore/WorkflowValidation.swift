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
    validateUniqueIds(
      workflow.nodeRegistry.map(\.id),
      collectionPath: "workflow.nodes",
      diagnostics: &diagnostics
    )
    validateUniqueIds(
      workflow.steps.map(\.id),
      collectionPath: "workflow.steps",
      diagnostics: &diagnostics
    )
    let registryIds = Set(workflow.nodeRegistry.map(\.id))
    let stepIds = Set(workflow.steps.map(\.id))

    if !stepIds.contains(workflow.entryStepId) {
      diagnostics.append(error("workflow.entryStepId", "must reference workflow.steps[] entry '\(workflow.entryStepId)'"))
    }
    if let managerStepId = workflow.managerStepId, !stepIds.contains(managerStepId) {
      diagnostics.append(error("workflow.managerStepId", "must reference workflow.steps[] entry '\(managerStepId)'"))
    }
    validateTypedLoopMetadata(workflow.loop, stepIds: stepIds, diagnostics: &diagnostics)

    let workflowMemoryIds = Set((workflow.memories ?? []).map(\.id))
    let gateIds = Set(workflow.loop?.gates.map(\.id) ?? [])
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
      validateTypedStepLoop(
        step.loop,
        path: "workflow.steps.\(step.id).loop",
        gateIds: gateIds,
        diagnostics: &diagnostics
      )
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

  public func validate(
    _ workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload]
  ) -> [WorkflowValidationDiagnostic] {
    var diagnostics = validate(workflow)
    let stepIds = Set(workflow.steps.map(\.id))
    for step in workflow.steps {
      let effectivePolicy = step.sessionPolicy ?? nodePayloads[step.nodeId]?.sessionPolicy
      validateEffectiveSessionPolicy(
        effectivePolicy,
        path: "workflow.steps.\(step.id).sessionPolicy",
        stepIds: stepIds,
        diagnostics: &diagnostics
      )
    }
    return diagnostics
  }
}

private func validateEffectiveSessionPolicy(
  _ policy: WorkflowStepSessionPolicy?,
  path: String,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let policy, let inheritedStepId = policy.inheritFromStepId else {
    return
  }
  let trimmedStepId = inheritedStepId.trimmingCharacters(in: .whitespacesAndNewlines)
  if policy.mode != .reuse {
    diagnostics.append(error("\(path).inheritFromStepId", "is allowed only when sessionPolicy.mode is 'reuse'"))
  }
  if trimmedStepId.isEmpty {
    diagnostics.append(error("\(path).inheritFromStepId", "must be a non-empty string"))
  } else if !stepIds.contains(trimmedStepId) {
    diagnostics.append(error("\(path).inheritFromStepId", "must reference a step in the same workflow"))
  }
}

private func validateUniqueIds(
  _ ids: [String],
  collectionPath: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  var seen: Set<String> = []
  var duplicateIds: Set<String> = []
  for id in ids where !id.isEmpty {
    if !seen.insert(id).inserted {
      duplicateIds.insert(id)
    }
  }
  guard !duplicateIds.isEmpty else {
    return
  }
  for (index, id) in ids.enumerated() where duplicateIds.contains(id) {
    diagnostics.append(error("\(collectionPath)[\(index)].id", "must be unique across \(collectionPath)[]"))
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
    validateNodeSource(
      nodeFile: node.nodeFile,
      nodeRef: node.nodeRef,
      addon: node.addon,
      path: path,
      diagnostics: &diagnostics
    )
    if let nodeFile = node.nodeFile {
      validateWorkflowRelativePath(nodeFile, fieldName: "nodeFile", path: "\(path).nodeFile", diagnostics: &diagnostics)
    }
    validateNodeReference(node.nodeRef, path: "\(path).nodeRef", diagnostics: &diagnostics)
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
  let gateIds = Set(workflow.loop?.gates.map(\.id) ?? [])
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
    validateEffectiveSessionPolicy(
      step.sessionPolicy,
      path: "\(path).sessionPolicy",
      stepIds: stepIds,
      diagnostics: &diagnostics
    )
    validateTypedStepLoop(step.loop, path: "\(path).loop", gateIds: gateIds, diagnostics: &diagnostics)
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

  validateTypedLoopMetadata(workflow.loop, stepIds: stepIds, diagnostics: &diagnostics)

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
    let defaultNodeFile = registryNode.addon == nil && registryNode.nodeRef == nil
      ? "nodes/\(step.nodeId).json"
      : nil
    return WorkflowNodeRef(
      id: step.id,
      nodeFile: registryNode.nodeFile ?? defaultNodeFile,
      nodeRef: registryNode.nodeRef,
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
    nodes: runtimeNodes,
    loop: workflow.loop
  )
}
