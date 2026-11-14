import Foundation
import RielaCore

struct WorkflowSharedNodeActivationPolicy: Sendable {
  private var catalogOriginsByLocator: [String: [WorkflowOriginIdentity]]
  private var deactivatedOriginIds: Set<String>

  static let includeDeactivated = WorkflowSharedNodeActivationPolicy(
    catalogOrigins: [],
    deactivatedOrigins: [],
    includeDeactivated: true
  )

  init(
    catalogOrigins: [WorkflowOriginIdentity],
    deactivatedOrigins: [WorkflowOriginIdentity],
    includeDeactivated: Bool
  ) {
    catalogOriginsByLocator = Dictionary(
      grouping: catalogOrigins,
      by: \.canonicalLocator
    )
    deactivatedOriginIds = includeDeactivated
      ? []
      : Set(deactivatedOrigins.map(\.originId))
  }

  func requireActive(
    name: String,
    workflowId: String,
    directory: URL,
    scope: WorkflowScope,
    provenance: WorkflowProvenance
  ) throws {
    let canonicalLocator = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let matchingOrigins = (catalogOriginsByLocator[canonicalLocator] ?? [])
      .filter { $0.workflowId == workflowId }
    let origin: WorkflowOriginIdentity
    if matchingOrigins.count == 1, let exact = matchingOrigins.first {
      origin = exact
    } else if let named = matchingOrigins.filter({ $0.name == name }).only {
      origin = named
    } else if matchingOrigins.isEmpty {
      origin = workflowOriginIdentity(
        name: name,
        workflowId: workflowId,
        scope: scope,
        sourceKind: .workflow,
        provenance: provenance,
        locator: canonicalLocator
      )
    } else {
      throw WorkflowRegistryError(
        code: .invalidOrigin,
        message: "shared workflow '\(name)' resolves to multiple catalog origins",
        workflowId: workflowId
      )
    }
    guard deactivatedOriginIds.contains(origin.originId) else { return }
    throw WorkflowRegistryError(
      code: .workflowDeactivated,
      message: "shared workflow '\(workflowId)' is deactivated",
      workflowId: workflowId,
      originId: origin.originId
    )
  }

  func requireActiveCandidate(
    name: String,
    directory: URL
  ) throws {
    let canonicalLocator = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let matchingOrigins = catalogOriginsByLocator[canonicalLocator] ?? []
    let origin: WorkflowOriginIdentity?
    if matchingOrigins.count == 1 {
      origin = matchingOrigins.first
    } else {
      origin = matchingOrigins.filter { $0.name == name }.only
    }
    guard let origin, deactivatedOriginIds.contains(origin.originId) else { return }
    throw WorkflowRegistryError(
      code: .workflowDeactivated,
      message: "workflow '\(origin.workflowId)' is deactivated",
      workflowId: origin.workflowId,
      originId: origin.originId
    )
  }
}

private extension Collection {
  var only: Element? {
    count == 1 ? first : nil
  }
}

extension FileSystemWorkflowBundleResolver {
  func materializeSharedNodeReferences(
    in workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    rootDirectory: URL,
    activationRootDirectory: URL,
    scope: WorkflowScope,
    provenance: WorkflowProvenance,
    promptTemplateLoader: PromptTemplateAssetLoader,
    activationPolicy: WorkflowSharedNodeActivationPolicy
  ) throws -> (workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) {
    var workflow = workflow
    var nodePayloads = nodePayloads
    for index in workflow.nodeRegistry.indices {
      guard let nodeRef = workflow.nodeRegistry[index].nodeRef else {
        continue
      }
      let localNodeId = workflow.nodeRegistry[index].id
      let resolved = try resolveSharedNode(
        nodeRef,
        currentWorkflowId: workflow.workflowId,
        rootDirectory: rootDirectory,
        activationRootDirectory: activationRootDirectory,
        scope: scope,
        provenance: provenance,
        promptTemplateLoader: promptTemplateLoader,
        activationPolicy: activationPolicy,
        resolutionStack: [WorkflowSharedNodeRef(workflowId: workflow.workflowId, nodeId: localNodeId)]
      )
      workflow.nodeRegistry[index] = mergeSharedNodeReference(local: workflow.nodeRegistry[index], shared: resolved.node)
      if var payload = resolved.payload {
        payload.id = localNodeId
        nodePayloads[localNodeId] = payload
      }
    }
    workflow.nodes = materializedRuntimeNodes(for: workflow)
    return (workflow, nodePayloads)
  }

  private func resolveSharedNode(
    _ nodeRef: WorkflowSharedNodeRef,
    currentWorkflowId: String,
    rootDirectory: URL,
    activationRootDirectory: URL,
    scope: WorkflowScope,
    provenance: WorkflowProvenance,
    promptTemplateLoader: PromptTemplateAssetLoader,
    activationPolicy: WorkflowSharedNodeActivationPolicy,
    resolutionStack: [WorkflowSharedNodeRef]
  ) throws -> (node: WorkflowNodeRegistryRef, payload: AgentNodePayload?) {
    try validateSharedNodeReference(nodeRef, resolutionStack: resolutionStack)

    let activationDirectory = activationRootDirectory
      .appendingPathComponent(nodeRef.workflowId, isDirectory: true)
      .standardizedFileURL
    let referencedDirectory = rootDirectory
      .appendingPathComponent(nodeRef.workflowId, isDirectory: true)
      .standardizedFileURL
    guard isContained(referencedDirectory.resolvingSymlinksInPath(), in: rootDirectory.resolvingSymlinksInPath()) else {
      throw WorkflowResolutionError.invalidJSONReference(
        "nodeRef \(nodeRef.workflowId):\(nodeRef.nodeId) escapes \(rootDirectory.path)"
      )
    }

    let workflowURL = referencedDirectory.appendingPathComponent("workflow.json")
    guard FileManager.default.fileExists(atPath: workflowURL.path) else {
      throw invalidSharedNodeWorkflow("shared node workflow '\(nodeRef.workflowId)' not found from workflow '\(currentWorkflowId)'")
    }
    let validation = validateAuthoredWorkflowData(try Data(contentsOf: workflowURL))
    guard let referencedWorkflow = validation.workflow else {
      throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
    }
    try activationPolicy.requireActive(
      name: nodeRef.workflowId,
      workflowId: referencedWorkflow.workflowId,
      directory: activationDirectory,
      scope: scope,
      provenance: provenance
    )
    guard let referencedNode = referencedWorkflow.nodeRegistry.first(where: { $0.id == nodeRef.nodeId }) else {
      throw WorkflowResolutionError.invalidWorkflow([
        WorkflowValidationDiagnostic(
          severity: .error,
          path: "workflow.nodes.nodeRef.nodeId",
          message: "shared node '\(nodeRef.nodeId)' not found in workflow '\(nodeRef.workflowId)'"
        )
      ])
    }
    if let nestedRef = referencedNode.nodeRef {
      let resolved = try resolveSharedNode(
        nestedRef,
        currentWorkflowId: nodeRef.workflowId,
        rootDirectory: rootDirectory,
        activationRootDirectory: activationRootDirectory,
        scope: scope,
        provenance: provenance,
        promptTemplateLoader: promptTemplateLoader,
        activationPolicy: activationPolicy,
        resolutionStack: resolutionStack + [nodeRef]
      )
      return (mergeSharedNodeReference(local: referencedNode, shared: resolved.node), resolved.payload)
    }
    guard let nodeFile = referencedNode.nodeFile else {
      return (referencedNode, nil)
    }
    return (
      referencedNode,
      try loadSharedNodePayload(
        nodeFile: nodeFile,
        referencedDirectory: referencedDirectory,
        scope: scope,
        promptTemplateLoader: promptTemplateLoader
      )
    )
  }

  private func loadSharedNodePayload(
    nodeFile: String,
    referencedDirectory: URL,
    scope: WorkflowScope,
    promptTemplateLoader: PromptTemplateAssetLoader
  ) throws -> AgentNodePayload {
    let payloadURL = try containedFile(
      referencedDirectory.appendingPathComponent(nodeFile),
      in: referencedDirectory,
      scope: scope,
      label: "shared nodeFile \(nodeFile)"
    )
    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(contentsOf: payloadURL))
    do {
      return try absolutizedStdioPaths(
        in: promptTemplateLoader.hydrate(payload, workflowDirectory: referencedDirectory),
        workflowDirectory: referencedDirectory
      )
    } catch let error as PromptTemplateAssetLoadingError {
      throw WorkflowResolutionError.invalidWorkflow([error.diagnostic])
    }
  }

  private func materializedRuntimeNodes(for workflow: WorkflowDefinition) -> [WorkflowNodeRef] {
    var registryById: [String: WorkflowNodeRegistryRef] = [:]
    for node in workflow.nodeRegistry where registryById[node.id] == nil {
      registryById[node.id] = node
    }
    return workflow.steps.compactMap { step -> WorkflowNodeRef? in
      guard let registryNode = registryById[step.nodeId] else {
        return nil
      }
      return WorkflowNodeRef(
        id: step.id,
        nodeFile: registryNode.nodeFile,
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
  }

  private func mergeSharedNodeReference(
    local: WorkflowNodeRegistryRef,
    shared: WorkflowNodeRegistryRef
  ) -> WorkflowNodeRegistryRef {
    var node = local
    node.addon = node.addon ?? shared.addon
    if node.addon != nil {
      node.nodeRef = nil
    }
    node.execution = node.execution ?? shared.execution
    node.kind = node.kind ?? shared.kind
    node.repeatPolicy = node.repeatPolicy ?? shared.repeatPolicy
    node.inputFilters = node.inputFilters ?? shared.inputFilters
    node.memories = node.memories ?? shared.memories
    return node
  }

  private func validateSharedNodeReference(
    _ nodeRef: WorkflowSharedNodeRef,
    resolutionStack: [WorkflowSharedNodeRef]
  ) throws {
    guard isSafeScopedWorkflowName(nodeRef.workflowId) else {
      throw WorkflowResolutionError.invalidWorkflow([
        WorkflowValidationDiagnostic(
          severity: .error,
          path: "workflow.nodes.nodeRef.workflowId",
          message: "invalid shared workflow id '\(nodeRef.workflowId)'"
        )
      ])
    }
    guard isSafeSharedNodeId(nodeRef.nodeId) else {
      throw WorkflowResolutionError.invalidWorkflow([
        WorkflowValidationDiagnostic(
          severity: .error,
          path: "workflow.nodes.nodeRef.nodeId",
          message: "invalid shared node id '\(nodeRef.nodeId)'"
        )
      ])
    }
    guard !resolutionStack.contains(nodeRef) else {
      let cycle = (resolutionStack + [nodeRef]).map { "\($0.workflowId):\($0.nodeId)" }.joined(separator: " -> ")
      throw WorkflowResolutionError.invalidWorkflow([
        WorkflowValidationDiagnostic(
          severity: .error,
          path: "workflow.nodes.nodeRef",
          message: "cyclic shared node reference: \(cycle)"
        )
      ])
    }
  }

  private func invalidSharedNodeWorkflow(_ message: String) -> WorkflowResolutionError {
    .invalidWorkflow([
      WorkflowValidationDiagnostic(
        severity: .error,
        path: "workflow.nodes.nodeRef",
        message: message
      )
    ])
  }

  private func isSafeSharedNodeId(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9][a-z0-9-]{1,63}$"#, options: .regularExpression) != nil
  }
}
