import Foundation

public struct WorkflowInheritanceTransformationResult: Sendable {
  public var workflow: WorkflowDefinition
  public var nodePayloads: [String: AgentNodePayload]
  public var diagnostics: [WorkflowValidationDiagnostic]
}

public struct WorkflowInheritanceTransformation: Sendable {
  public init() {}

  public func apply(
    _ declaration: WorkflowInheritanceDeclaration,
    to workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload]
  ) throws -> WorkflowInheritanceTransformationResult {
    let originalFileBackedNodeIds = Set(workflow.nodeRegistry.compactMap { $0.nodeFile == nil ? nil : $0.id })
    var transformedWorkflow: WorkflowDefinition = try transformed(workflow, replacements: declaration.stringReplacements)
    var transformedPayloads: [String: AgentNodePayload] = [:]
    for nodeId in nodePayloads.keys.sorted() {
      guard let payload = nodePayloads[nodeId] else { continue }
      let transformedPayload: AgentNodePayload = try transformed(payload, replacements: declaration.stringReplacements)
      let transformedId = replace(nodeId, using: declaration.stringReplacements)
      guard transformedPayloads[transformedId] == nil else {
        throw transformation("workflow.nodes", "string replacements create duplicate node id '\(transformedId)'")
      }
      transformedPayloads[transformedId] = transformedPayload
    }
    let transformedFileBackedIds = Set(originalFileBackedNodeIds.map { replace($0, using: declaration.stringReplacements) })
    transformedWorkflow.workflowId = declaration.derivedWorkflowId
    if let description = declaration.description { transformedWorkflow.description = description }

    var effectivePatches: [String: WorkflowInstanceNodePatch] = [:]
    if let convenience = declaration.agentNodePatch {
      for node in transformedWorkflow.nodeRegistry where transformedFileBackedIds.contains(node.id) {
        guard let payload = transformedPayloads[node.id], payload.command == nil, payload.container == nil,
              payload.nodeType == nil || payload.nodeType == .agent else { continue }
        effectivePatches[node.id] = convenience
      }
    }
    for (nodeId, patch) in declaration.nodePatches {
      effectivePatches[nodeId] = (effectivePatches[nodeId] ?? WorkflowInstanceNodePatch()).merging(patch)
    }
    do {
      transformedPayloads = try WorkflowInstanceResolver.applyNodePatches(effectivePatches, to: transformedPayloads)
    } catch {
      throw transformation("workflow.extends.nodePatch", "could not apply inheritance patch: \(error)")
    }
    let diagnostics = DefaultWorkflowValidator().validate(transformedWorkflow, nodePayloads: transformedPayloads)
      + transformedPayloads.keys.sorted().flatMap { nodeId in
        transformedPayloads[nodeId].map { validateAgentNodePayload($0, path: "nodes.\(nodeId)") } ?? []
      }
    if diagnostics.contains(where: { $0.severity == .error }) {
      throw WorkflowInheritanceError.transformation(diagnostics)
    }
    return WorkflowInheritanceTransformationResult(
      workflow: transformedWorkflow,
      nodePayloads: transformedPayloads,
      diagnostics: diagnostics
    )
  }
}

private extension WorkflowInheritanceTransformation {
  static let preservedResourceKeys: Set<String> = [
    "nodeFile", "stepFile", "promptTemplateFile", "systemPromptTemplateFile",
    "sessionStartPromptTemplateFile", "executable", "workingDirectory"
  ]

  func transformed<T: Codable>(_ value: T, replacements: [String: String]) throws -> T {
    guard !replacements.isEmpty else { return value }
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    let changed = transformJSON(object, key: nil, replacements: replacements)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: changed))
  }

  func transformJSON(_ value: Any, key: String?, replacements: [String: String]) -> Any {
    if let dictionary = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (dictionaryKey, dictionaryValue) in dictionary {
        result[dictionaryKey] = transformJSON(dictionaryValue, key: dictionaryKey, replacements: replacements)
      }
      return result
    }
    if let array = value as? [Any] {
      return array.map { transformJSON($0, key: key, replacements: replacements) }
    }
    if let string = value as? String, !Self.preservedResourceKeys.contains(key ?? "") {
      return replace(string, using: replacements)
    }
    return value
  }

  func replace(_ value: String, using replacements: [String: String]) -> String {
    replacements.keys.sorted {
      let lhs = Array($0.utf8)
      let rhs = Array($1.utf8)
      return lhs.count == rhs.count ? lhs.lexicographicallyPrecedes(rhs) : lhs.count > rhs.count
    }.reduce(value) { partial, source in
      partial.replacingOccurrences(of: source, with: replacements[source] ?? "")
    }
  }

  func transformation(_ path: String, _ message: String) -> WorkflowInheritanceError {
    .transformation([WorkflowValidationDiagnostic(severity: .error, path: path, message: message)])
  }
}
