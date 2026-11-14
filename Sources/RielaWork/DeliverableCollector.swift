import Foundation
import RielaCore

public struct DeliverableCollector: Sendable {
  private let workflow: WorkflowDefinition
  private let nodePayloads: [String: AgentNodePayload]

  public init(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
  }

  public func collect(snapshot: WorkflowRuntimePersistenceSnapshot) -> [DeliverableRef] {
    let stepsById = Dictionary(workflow.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let nodesById = Dictionary(workflow.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var documents: [DocumentKey: DocumentAccumulator] = [:]
    var localOnly = Set<LocalOnlyKey>()

    for execution in snapshot.session.executions where execution.status == .completed {
      guard let payload = execution.acceptedOutput?.payload,
            let step = stepsById[execution.stepId],
            let node = nodesById[step.nodeId] else { continue }
      let addon = node.addon

      if let addon, addon.name.hasPrefix("kaiba/") {
        let ids = identifiers(in: payload, fields: ["noteId", "notebookId"])
        addDocument(
          ids: ids,
          store: "kaiba",
          instance: stringValue(addon.config?["kaibaInstanceId"]),
          stepId: execution.stepId,
          to: &documents
        )
      }

      if let projection = nodePayloads[step.nodeId]?.output?.deliverables {
        let ids = identifiers(in: payload, fields: projection.idFields)
        let instance = projection.instanceField.flatMap { stringValue(payload[$0]) }
        addDocument(ids: ids, store: projection.store, instance: instance, stepId: execution.stepId, to: &documents)
      }

      if let addon, addon.name.hasPrefix("riela/memory-") {
        let path = localPath(payload: payload, config: addon.config, configKey: "memoryRoot")
        localOnly.insert(LocalOnlyKey(kind: "memory", path: path))
      } else if let addon, addon.name.hasPrefix("riela/kv-") {
        let path = localPath(payload: payload, config: addon.config, configKey: "kvRoot")
        localOnly.insert(LocalOnlyKey(kind: "kv", path: path))
      }
    }

    let documentRefs = documents.keys.sorted().compactMap { key -> DeliverableRef? in
      guard let value = documents[key], !value.ids.isEmpty else { return nil }
      return .document(DocumentDeliverable(
        store: key.store,
        instance: key.instance,
        ids: value.ids.sorted(),
        producedByStepIds: value.stepIds.sorted()
      ))
    }
    let localRefs = localOnly.sorted().map { key in
      DeliverableRef.localOnly(LocalOnlyDeliverable(kind: key.kind, path: key.path))
    }
    return documentRefs + localRefs
  }

  private func identifiers(in payload: JSONObject, fields: [String]) -> Set<String> {
    Set(fields.flatMap { field -> [String] in
      guard let value = payload[field] else { return [] }
      switch value {
      case let .string(id): return [id]
      case let .array(values): return values.compactMap(stringValue)
      default: return []
      }
    })
  }

  private func addDocument(
    ids: Set<String>,
    store: String,
    instance: String?,
    stepId: String,
    to documents: inout [DocumentKey: DocumentAccumulator]
  ) {
    guard !ids.isEmpty else { return }
    let key = DocumentKey(store: store, instance: instance)
    var value = documents[key, default: DocumentAccumulator()]
    value.ids.formUnion(ids)
    value.stepIds.insert(stepId)
    documents[key] = value
  }

  private func localPath(payload: JSONObject, config: JSONObject?, configKey: String) -> String {
    stringValue(payload["databasePath"])
      ?? stringValue(config?[configKey])
      ?? "cwd-local store"
  }

  private func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(string)? = value else { return nil }
    return string
  }
}

private struct DocumentKey: Hashable, Comparable {
  let store: String
  let instance: String?

  static func < (lhs: DocumentKey, rhs: DocumentKey) -> Bool {
    if lhs.store != rhs.store { return lhs.store < rhs.store }
    return (lhs.instance ?? "") < (rhs.instance ?? "")
  }
}

private struct DocumentAccumulator {
  var ids = Set<String>()
  var stepIds = Set<String>()
}

private struct LocalOnlyKey: Hashable, Comparable {
  let kind: String
  let path: String

  static func < (lhs: LocalOnlyKey, rhs: LocalOnlyKey) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
    return lhs.path < rhs.path
  }
}
