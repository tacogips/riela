import Foundation
import RielaCore

struct SessionInstanceResolution {
  var effectiveInstance: EffectiveWorkflowInstance?
  var nodePayloads: [String: AgentNodePayload]
  var warning: String?

  init(
    effectiveInstance: EffectiveWorkflowInstance? = nil,
    nodePayloads: [String: AgentNodePayload],
    warning: String? = nil
  ) {
    self.effectiveInstance = effectiveInstance
    self.nodePayloads = nodePayloads
    self.warning = warning
  }
}

func resolvePersistedSessionInstance(
  persisted: PersistedCLIWorkflowSession,
  workflowId: String,
  workingDirectory: String,
  nodePayloads: [String: AgentNodePayload],
  commandName: String
) throws -> SessionInstanceResolution {
  guard let identity = persisted.session.instanceIdentity else {
    return SessionInstanceResolution(nodePayloads: nodePayloads)
  }
  let snapshot = try persisted.session.instanceConfiguration.map(decodeWorkflowInstanceConfiguration)
  if identity == WorkflowInstanceIdentity.defaultIdentity {
    let configuration = snapshot ?? WorkflowInstanceConfiguration()
    let patchedPayloads = try WorkflowInstanceResolver.applyNodePatches(configuration.nodePatches, to: nodePayloads)
    return SessionInstanceResolution(
      effectiveInstance: EffectiveWorkflowInstance(identity: identity, kind: .default, configuration: configuration),
      nodePayloads: patchedPayloads
    )
  }

  let stores = ScopedWorkflowInstanceStore(workingDirectory: workingDirectory)
  let stored = try stores.find(identity: identity, workflowId: workflowId)?.1
  if let stored, snapshot.map({ stored.configuration == $0 }) ?? true {
    let resolved = try WorkflowInstanceResolver.resolve(
      workflowId: workflowId,
      base: stored,
      nodePayloads: nodePayloads
    )
    return SessionInstanceResolution(
      effectiveInstance: resolved.instance,
      nodePayloads: resolved.nodePayloads
    )
  }
  guard let snapshot else {
    throw WorkflowInstanceStoreError.notFound(identity)
  }
  let kind = WorkflowInstanceKind(rawValue: persisted.session.instanceKind ?? "") ?? .named
  let patchedPayloads = try WorkflowInstanceResolver.applyNodePatches(snapshot.nodePatches, to: nodePayloads)
  let effective = EffectiveWorkflowInstance(
    identity: identity,
    kind: kind,
    baseIdentity: persisted.session.instanceBaseIdentity,
    configuration: snapshot
  )
  let reason = stored == nil ? "not found" : "changed since the source session"
  return SessionInstanceResolution(
    effectiveInstance: effective,
    nodePayloads: patchedPayloads,
    warning: "workflow instance '\(identity)' \(reason); \(commandName) used the source session snapshot"
  )
}

private func decodeWorkflowInstanceConfiguration(_ object: JSONObject) throws -> WorkflowInstanceConfiguration {
  let data = try JSONEncoder().encode(object)
  return try JSONDecoder().decode(WorkflowInstanceConfiguration.self, from: data)
}
