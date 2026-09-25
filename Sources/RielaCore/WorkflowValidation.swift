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
  public var defectDiagnostics: [WorkflowDefectDiagnostic]

  public init(
    workflow: WorkflowDefinition?,
    diagnostics: [WorkflowValidationDiagnostic],
    sourceDigest: String? = nil,
    stepIds: [String] = [],
    nodeIds: [String] = []
  ) {
    self.workflow = workflow
    self.diagnostics = diagnostics
    self.defectDiagnostics = sourceDigest.map {
      WorkflowDefectDiagnostic.project(diagnostics, sourceDigest: $0, stepIds: stepIds, nodeIds: nodeIds)
    } ?? []
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
      if let placement = step.placement {
        validateDistributedPlacement(placement, path: "workflow.steps.\(step.id).placement", diagnostics: &diagnostics)
      }
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
    nodePayloads: [String: AgentNodePayload],
    addonEvidence: [String: WorkflowAddonRouteEvidence] = [:]
  ) -> [WorkflowValidationDiagnostic] {
    var diagnostics = validate(workflow)
    for nodeId in nodePayloads.keys.sorted() {
      guard let payload = nodePayloads[nodeId] else { continue }
      diagnostics += validateAgentNodePayload(payload, path: "workflow.nodes.\(nodeId)")
      if let index = payload.output?.invalidGuaranteedWhenIndex {
        diagnostics.append(error(
          "workflow.nodes.\(nodeId).output.guaranteedWhen[\(index)]",
          "must be a non-empty unique control name and cannot be a reserved Boolean constant"
        ))
      }
      validateAgentSandbox(payload, nodeId: nodeId, diagnostics: &diagnostics)
      if let schema = payload.output?.jsonSchema,
         let reason = DefaultWorkflowOutputValidator().validateContractSchema(schema) {
        diagnostics.append(error("workflow.nodes.\(nodeId).output.jsonSchema", reason))
      }
    }
    validateAgentOutputDependencies(workflow, nodePayloads: nodePayloads, diagnostics: &diagnostics)
    validateRouteControlGuarantees(
      workflow, nodePayloads: nodePayloads, addonEvidence: addonEvidence, diagnostics: &diagnostics
    )
    let stepIds = Set(workflow.steps.map(\.id))
    for step in workflow.steps {
      if step.placement != nil, nodePayloads[step.nodeId]?.output?.projection != nil {
        diagnostics.append(error("workflow.steps.\(step.id).placement", "output projection steps execute on the controller and cannot specify worker placement"))
      }
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

private func validateRouteControlGuarantees(
  _ workflow: WorkflowDefinition,
  nodePayloads: [String: AgentNodePayload],
  addonEvidence: [String: WorkflowAddonRouteEvidence],
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let routeContract = WorkflowRouteContract()
  let registry = Dictionary(grouping: workflow.nodeRegistry, by: \.id).mapValues { $0[0] }
  let steps = Dictionary(grouping: workflow.steps, by: \.id).mapValues { $0[0] }
  let predecessors = Dictionary(grouping: workflow.steps.flatMap { source in
    (source.transitions ?? []).map { ($0.toStepId, source.id) }
  }, by: { $0.0 }).mapValues { $0.map(\.1) }

  func provePayload(_ identifier: String, at stepId: String, visited: Set<String>) -> WorkflowBooleanGuarantee {
    guard visited.count < 4_096, !visited.contains(stepId), let step = steps[stepId] else {
      return .analysisIncomplete(pointer: "", reason: "producer walk is cyclic, exhausted or unresolved")
    }
    if let payload = nodePayloads[step.nodeId] {
      guard let schema = payload.output?.jsonSchema else {
        return .analysisIncomplete(pointer: "", reason: "producer schema is absent")
      }
      return routeContract.provePayloadBoolean(identifier: identifier, schema: schema)
    }
    guard let addon = registry[step.nodeId]?.addon,
          let selected = addonEvidence[step.nodeId],
          let version = addon.version,
          selected.name == addon.name, selected.version == version else {
      return .analysisIncomplete(pointer: "", reason: "exact add-on catalog identity is unavailable")
    }
    let output = selected.output
    if output.guaranteedPayload.contains(identifier) || output.booleanOverwrites.contains(identifier) {
      return .proven
    }
    guard output.forwardsPayload == true,
          !output.removedPayload.contains(identifier),
          !output.overwrittenPayload.contains(identifier),
          let upstream = predecessors[stepId], !upstream.isEmpty else {
      return .analysisIncomplete(pointer: "", reason: "add-on forwarding or overwrite proof is unavailable")
    }
    for source in Set(upstream).sorted() {
      let proof = provePayload(identifier, at: source, visited: visited.union([stepId]))
      guard proof == .proven else { return proof }
    }
    return .proven
  }

  for step in workflow.steps {
    for (index, transition) in (step.transitions ?? []).enumerated() {
      guard let label = transition.label else { continue }
      let condition: ParsedWorkflowCondition
      do {
        condition = try ParsedWorkflowCondition(label)
      } catch let WorkflowConditionError.syntax(span) {
        diagnostics.append(error(
          "workflow.steps.\(step.id).transitions[\(index)].label",
          "route.invalidCondition characters[\(span.start)..<\(span.end)]"
        ))
        continue
      } catch {
        continue
      }
      for identifier in Set(condition.identifiers.map(\.name)).sorted() {
        if nodePayloads[step.nodeId]?.output?.guaranteedWhen?.contains(identifier) == true {
          continue
        }
        if let addon = registry[step.nodeId]?.addon,
           let selected = addonEvidence[step.nodeId],
           selected.name == addon.name, selected.version == addon.version,
           selected.output.guaranteedWhen.contains(identifier) {
          continue
        }
        switch provePayload(identifier, at: step.id, visited: []) {
        case .proven:
          break
        case let .analysisIncomplete(pointer, reason):
          let path = nodePayloads[step.nodeId] != nil
            ? "workflow.nodes.\(step.nodeId).output.jsonSchema\(pointer)"
            : "workflow.steps.\(step.id).transitions[\(index)].label"
          diagnostics.append(WorkflowValidationDiagnostic(
            severity: .warning,
            path: path,
            message: "analysis_incomplete: route control '\(identifier)' at step '\(step.id)' transition \(index): \(reason)"
          ))
        }
      }
    }
  }
}

private func validateAgentSandbox(
  _ payload: AgentNodePayload,
  nodeId: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let backend = payload.executionBackend else { return }
  let path = "workflow.nodes.\(nodeId).agentSandbox"
  if backend.cliAgentBackend != nil, payload.agentSandbox == nil {
    diagnostics.append(error(
      path,
      "agent nodes on \(backend.rawValue) must declare agentSandbox (readOnly | workspaceWrite | dangerFullAccess); omitting it launches the agent with no permission flag and silently denies writes"
    ))
  } else if backend.cliAgentBackend == nil, payload.agentSandbox != nil {
    diagnostics.append(error(path, "agentSandbox is not supported by \(backend.rawValue) and would be ignored"))
  }
}

private struct PayloadDependency: Hashable {
  var consumerStepId: String
  var field: String
  var path: String
}

private func validateAgentOutputDependencies(
  _ workflow: WorkflowDefinition,
  nodePayloads: [String: AgentNodePayload],
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let registryById = Dictionary(uniqueKeysWithValues: workflow.nodeRegistry.map { ($0.id, $0) })
  var incoming: [String: [WorkflowStepRef]] = [:]
  for step in workflow.steps {
    for transition in step.transitions ?? [] where transition.toWorkflowId == nil {
      incoming[transition.toStepId, default: []].append(step)
    }
  }

  var dependenciesByProducer: [String: Set<PayloadDependency>] = [:]
  for consumer in workflow.steps {
    guard let addon = registryById[consumer.nodeId]?.addon else { continue }
    let inputKeys = Set(addon.inputs?.keys.map { $0 } ?? [])
    let surfaces: [(JSONValue?, TemplateSurface)] = [
      (addon.config.map(JSONValue.object), .addonConfig(addonInputKeys: inputKeys)),
      (addon.inputs.map(JSONValue.object), .addonInputs)
    ]
    let references = surfaces.flatMap { value, surface in
      (value.map(templateReferencePaths) ?? []).compactMap { path -> (String, String)? in
        payloadField(inTemplatePath: path, surface: surface).map { ($0, path) }
      }
    }
    guard !references.isEmpty else { continue }
    let producerNodeIds = requiredProducerNodeIds(
      before: consumer.id,
      incoming: incoming,
      registryById: registryById,
      nodePayloads: nodePayloads
    )
    for producerNodeId in producerNodeIds {
      for (field, path) in references {
        dependenciesByProducer[producerNodeId, default: []].insert(PayloadDependency(
          consumerStepId: consumer.id,
          field: field,
          path: path
        ))
      }
    }
  }

  for step in workflow.steps where (step.transitions ?? []).contains(where: { transition in
    guard let label = transition.label else { return false }
    return label != "always"
  }) {
    guard let payload = nodePayloads[step.nodeId], payload.output?.jsonSchema == nil else { continue }
    if let output = payload.output, output.invalidGuaranteedWhenIndex == nil {
      let declared = Set(output.guaranteedWhen ?? [])
      let coversRoutes = (step.transitions ?? []).allSatisfy { transition in
        guard let label = transition.label else { return true }
        guard let condition = try? ParsedWorkflowCondition(label) else { return false }
        return condition.identifiers.allSatisfy { declared.contains($0.name) }
      }
      if coversRoutes { continue }
    }
    diagnostics.append(error(
      "workflow.nodes.\(step.nodeId).output.jsonSchema",
      "agent node '\(step.nodeId)' drives conditional transition labels from step '\(step.id)' and must declare output.jsonSchema"
    ))
  }

  for producerNodeId in dependenciesByProducer.keys.sorted() {
    guard let payload = nodePayloads[producerNodeId] else { continue }
    let dependencies = dependenciesByProducer[producerNodeId, default: []].sorted {
      ($0.consumerStepId, $0.path) < ($1.consumerStepId, $1.path)
    }
    guard let schema = payload.output?.jsonSchema else {
      for dependency in dependencies {
        diagnostics.append(error(
          "workflow.nodes.\(producerNodeId).output.jsonSchema",
          "agent node '\(producerNodeId)' payload field '\(dependency.field)' is referenced by step '\(dependency.consumerStepId)' template '{{\(dependency.path)}}' and must declare output.jsonSchema"
        ))
      }
      continue
    }
    let properties: JSONObject = if case let .object(value)? = schema["properties"] { value } else { [:] }
    for dependency in dependencies where properties[dependency.field] == nil {
      diagnostics.append(error(
        "workflow.nodes.\(producerNodeId).output.jsonSchema.properties.\(dependency.field)",
        "referenced payload field '\(dependency.field)' used by step '\(dependency.consumerStepId)' must be declared in schema.properties"
      ))
    }
  }
}

private func requiredProducerNodeIds(
  before consumerStepId: String,
  incoming: [String: [WorkflowStepRef]],
  registryById: [String: WorkflowNodeRegistryRef],
  nodePayloads: [String: AgentNodePayload]
) -> Set<String> {
  var producers: Set<String> = []
  var visited: Set<String> = []
  var pending = incoming[consumerStepId] ?? []
  while let step = pending.popLast() {
    guard visited.insert(step.id).inserted else { continue }
    if nodePayloads[step.nodeId] != nil {
      producers.insert(step.nodeId)
    } else if registryById[step.nodeId]?.addon != nil {
      pending.append(contentsOf: incoming[step.id] ?? [])
    }
  }
  return producers
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
  let sourceDigest = WorkflowHistoryCanonicalCoding.sha256(data)

  let jsonObject: Any
  do {
    jsonObject = try JSONSerialization.jsonObject(with: data)
  } catch {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [WorkflowValidationDiagnostic(severity: .error, path: "workflow", message: "must be valid JSON")],
      sourceDigest: sourceDigest
    )
  }

  guard let raw = jsonObject as? [String: Any] else {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [WorkflowValidationDiagnostic(severity: .error, path: "workflow", message: "must be an object")],
      sourceDigest: sourceDigest
    )
  }

  diagnostics.append(contentsOf: validateRawAuthoredWorkflow(raw))
  let sourceStepIds = (raw["steps"] as? [Any] ?? []).map { ($0 as? [String: Any])?["id"] as? String ?? "" }
  let sourceNodeIds = (raw["nodes"] as? [Any] ?? []).map { ($0 as? [String: Any])?["id"] as? String ?? "" }

  let decoded: AuthoredWorkflowJSON?
  do {
    decoded = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)
  } catch let decodeError {
    diagnostics.append(error("workflow", "failed to decode authored workflow JSON: \(decodeError.localizedDescription)"))
    return AuthoredWorkflowValidationResult(
      workflow: nil, diagnostics: diagnostics, sourceDigest: sourceDigest,
      stepIds: sourceStepIds, nodeIds: sourceNodeIds
    )
  }

  guard let authoredWorkflow = decoded else {
    return AuthoredWorkflowValidationResult(
      workflow: nil, diagnostics: diagnostics, sourceDigest: sourceDigest,
      stepIds: sourceStepIds, nodeIds: sourceNodeIds
    )
  }

  let hasBlockingErrors = diagnostics.contains { $0.severity == .error }
  guard !hasBlockingErrors, let workflow = materializeWorkflowDefinition(from: authoredWorkflow) else {
    return AuthoredWorkflowValidationResult(
      workflow: nil, diagnostics: diagnostics, sourceDigest: sourceDigest,
      stepIds: sourceStepIds, nodeIds: sourceNodeIds
    )
  }

  diagnostics.append(contentsOf: validator.validate(workflow))
  return AuthoredWorkflowValidationResult(
    workflow: diagnostics.contains { $0.severity == .error } ? nil : workflow,
    diagnostics: diagnostics,
    sourceDigest: sourceDigest,
    stepIds: sourceStepIds,
    nodeIds: sourceNodeIds
  )
}

public func validateAuthoredWorkflowJSON(
  _ workflow: AuthoredWorkflowJSON,
  validator: any WorkflowValidating = DefaultWorkflowValidator()
) -> AuthoredWorkflowValidationResult {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let sourceDigest = (try? encoder.encode(workflow)).map(WorkflowHistoryCanonicalCoding.sha256)
  let sourceStepIds = (workflow.steps ?? workflow.nodes.map { WorkflowStepRef(id: $0.id, nodeId: $0.id) }).map(\.id)
  let sourceNodeIds = workflow.nodes.map(\.id)
  let typedDiagnostics = validateTypedAuthoredWorkflow(workflow)
  if typedDiagnostics.contains(where: { $0.severity == .error }) {
    return AuthoredWorkflowValidationResult(
      workflow: nil, diagnostics: typedDiagnostics, sourceDigest: sourceDigest,
      stepIds: sourceStepIds, nodeIds: sourceNodeIds
    )
  }

  guard let definition = materializeWorkflowDefinition(from: workflow) else {
    return AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [error("workflow.entryStepId", "must be a non-empty string")],
      sourceDigest: sourceDigest,
      stepIds: sourceStepIds,
      nodeIds: sourceNodeIds
    )
  }

  let diagnostics = validator.validate(definition)
  return AuthoredWorkflowValidationResult(
    workflow: diagnostics.contains { $0.severity == .error } ? nil : definition,
    diagnostics: diagnostics,
    sourceDigest: sourceDigest,
    stepIds: sourceStepIds,
    nodeIds: sourceNodeIds
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
