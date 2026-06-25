import Foundation

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

func validateRawAuthoredWorkflow(_ raw: [String: Any]) -> [WorkflowValidationDiagnostic] {
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
  let stepIds = Set(stepEntries.compactMap { entry -> String? in
    guard let entry = entry as? [String: Any], let id = entry["id"] as? String, !id.isEmpty else {
      return nil
    }
    return id
  })
  validateRawLoopMetadata(raw["loop"], stepIds: stepIds, diagnostics: &diagnostics)

  return diagnostics
}

private func validateNodeRegistry(_ entries: [Any], diagnostics: inout [WorkflowValidationDiagnostic]) {
  var seenIds: Set<String> = []
  let allowedKeys: Set<String> = ["id", "nodeFile", "nodeRef", "addon", "execution", "kind", "repeat", "inputFilters", "memories"]

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

    validateRawNodeSource(entry, path: path, diagnostics: &diagnostics)
    if let nodeFile = entry["nodeFile"] {
      validateWorkflowRelativePath(nodeFile, fieldName: "nodeFile", path: "\(path).nodeFile", diagnostics: &diagnostics)
    }
    validateRawNodeReference(entry["nodeRef"], path: "\(path).nodeRef", diagnostics: &diagnostics)
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
    "transitions",
    "loop"
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
  let gateIds = rawLoopGateIds(raw["loop"])

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
    validateRawStepLoop(entry["loop"], path: "\(path).loop", gateIds: gateIds, diagnostics: &diagnostics)
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
