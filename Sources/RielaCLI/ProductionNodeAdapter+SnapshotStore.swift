import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  static let snapshotStoreRegistration = BuiltinAddonHandlerRegistration(name: "riela/snapshot-store", bindsCLIVariablesAsInputs: false) { resolver, input, _ in
    try resolver.executeSnapshotStore(input)
  }

  func executeSnapshotStore(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["action", "storage", "expectedHead", "value", "context", "maxPayloadBytes", "label", "expiresInSeconds"]),
      case let .string(action)? = config["action"], ["load", "commit", "retain", "load-retained", "release"].contains(action),
      case let .object(storage)? = config["storage"],
      Set(storage.keys).isSubset(of: ["memoryId", "workflowId", "nodeId", "tag", "memoryRoot"]),
      let memory = nonEmptyString(storage["memoryId"]),
      case let .integer(limit) = config["maxPayloadBytes"] ?? .integer(7_990_000), (1...64 * 1024 * 1024 - 4096).contains(limit) else { throw snapshotInvalid() }
    let frameLimit = min(64 * 1024 * 1024, Int(limit) + 10_000)
    guard try JSONEncoder().encode(config).count <= frameLimit else { throw snapshotInvalid() }
    func string(_ name: String, default fallback: String) throws -> String {
      guard let value = storage[name] else { return fallback }
      guard let text = nonEmptyString(value) else { throw snapshotInvalid() }; return text
    }
    let workflow = try string("workflowId", default: input.workflowId)
    let tag = try string("tag", default: "checkpoint")
    let root = try string("memoryRoot", default: environment["RIELA_MEMORY_ROOT"]
      ?? RielaMemoryStore.defaultRootDirectory(workingDirectory: workingDirectory.path))
    let node: String?
    if storage["nodeId"] == .null { node = nil } else { node = try string("nodeId", default: input.nodeId) }
    let store = RielaMemoryStore(rootDirectory: root)
    let snapshot: MemorySnapshot?
    var released: Bool?
    do {
      if action == "load" || action == "load-retained" {
        guard config["value"] == nil, config["expectedHead"] == nil, config["expiresInSeconds"] == nil else { throw snapshotInvalid() }
        if action == "load" {
          guard config["label"] == nil else { throw snapshotInvalid() }
          snapshot = try store.loadSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag, maxPayloadBytes: Int(limit))
        } else {
          guard let label = nonEmptyString(config["label"]) else { throw snapshotInvalid() }
          snapshot = try store.loadRetainedSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag,
            label: label, maxPayloadBytes: Int(limit))
        }
      } else {
        guard let expected = config["expectedHead"] else { throw snapshotInvalid() }
        let head: MemorySnapshotHead?
        switch expected {
        case .null: head = nil
        case let .object(object):
          guard Set(object.keys) == ["recordId", "version", "scope"], case let .integer(id)? = object["recordId"], id > 0,
            case let .integer(version)? = object["version"], version > 0,
            case let .string(scope)? = object["scope"], scope.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw snapshotInvalid() }
          head = .init(recordId: id, version: version, scope: scope)
        default: throw snapshotInvalid()
        }
        if action != "commit" {
          guard config["value"] == nil, let label = nonEmptyString(config["label"]), let head else { throw snapshotInvalid() }
          if action == "retain" {
            guard case let .integer(ttl) = config["expiresInSeconds"] ?? .integer(86_400), (60...604_800).contains(ttl) else { throw snapshotInvalid() }
            let responseBudget = min(Int(limit), frameLimit - (try JSONEncoder().encode(config["context"] ?? .null).count) - 512)
            guard responseBudget > 0 else { throw snapshotInvalid() }
            snapshot = try store.retainSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag,
              label: label, expectedHead: head, expiresInSeconds: Int(ttl), maxPayloadBytes: responseBudget)
          } else {
            guard config["expiresInSeconds"] == nil else { throw snapshotInvalid() }
            released = try store.releaseSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag, label: label, expectedHead: head)
            snapshot = nil
          }
        } else {
          guard let value = config["value"], config["label"] == nil, config["expiresInSeconds"] == nil else { throw snapshotInvalid() }
          // Validate the eventual response before mutating persistent state.
          guard try JSONEncoder().encode(value).count + JSONEncoder().encode(config["context"] ?? .null).count + 512 <= frameLimit else {
            throw snapshotInvalid()
          }
          snapshot = try store.commitSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag,
            expectedHead: head, payload: memoryJSONValue(from: value), maxPayloadBytes: Int(limit))
        }
      }
    } catch MemorySnapshotError.conflict {
      throw AdapterExecutionError(.invalidInput, "snapshot head changed; reload before committing")
    } catch let error as AdapterExecutionError {
      throw error
    } catch { throw AdapterExecutionError(.invalidInput, "snapshot storage operation failed") }
    let head: JSONValue = snapshot.map { .object(["recordId": .integer($0.head.recordId), "version": .integer($0.head.version), "scope": .string($0.head.scope)]) } ?? .null
    var payload: JSONObject = ["found": .bool(snapshot != nil), "head": head,
      "value": snapshot.map { jsonValue(from: $0.record.payload) } ?? .null, "context": config["context"] ?? .null]
    if let released { payload["released"] = .bool(released) }
    guard try JSONEncoder().encode(payload).count <= frameLimit else { throw snapshotInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      when: ["always": true, "found": snapshot != nil, "missing": snapshot == nil], payload: payload)
  }
}

private func snapshotInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid snapshot-store configuration or payload") }
