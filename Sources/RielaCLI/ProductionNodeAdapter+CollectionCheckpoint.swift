import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

/// Metadata only. One authored key identifies one provider/account/query/window.
/// Acquisition can continue while earlier items await independent processing.
extension BuiltinWorkflowAddonResolver {
  func executeCollectionCheckpoint(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw collectionInputError()
    }
    let variables = try addonVariables(for: input)
    guard case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: variables),
      Set(config.keys).isSubset(of: ["action", "key", "storeId", "scope", "kvRoot", "expectedRevision",
                                    "items", "cursor", "acquisitionComplete"]),
      let action = nonEmptyString(config["action"]), ["load", "record", "acknowledge"].contains(action),
      let key = nonEmptyString(config["key"])
    else { throw collectionInputError() }
    func text(_ name: String, fallback: String) throws -> String {
      guard let value = config[name] else { return fallback }
      guard let value = nonEmptyString(value) else { throw collectionInputError() }
      return value
    }
    let root = try text("kvRoot", fallback: RielaKeyValueStore.defaultRootDirectory(workingDirectory: workingDirectory.path))
    let storeId = try text("storeId", fallback: "collection-checkpoints")
    let scope = try text("scope", fallback: input.workflowId)
    let store = RielaKeyValueStore(rootDirectory: root)
    let previous = try store.get(storeId: storeId, scope: scope, key: key)
    var state = CollectionCheckpointState()
    if let previous {
      do { state = try JSONDecoder().decode(CollectionCheckpointState.self, from: JSONEncoder().encode(previous.value)) } catch {
        throw AdapterExecutionError(.invalidInput, "collection checkpoint state is invalid")
      }
      try state.validate()
    }
    if action == "load" {
      guard Set(config.keys).isDisjoint(with: ["expectedRevision", "items", "cursor", "acquisitionComplete"]) else {
        throw collectionInputError()
      }
    } else {
      guard case let .integer(revision)? = config["expectedRevision"], revision >= 0,
        case let .array(rawItems)? = config["items"], rawItems.count <= 10_000
      else { throw collectionInputError() }
      guard revision == state.revision else {
        throw AdapterExecutionError(.invalidInput, "collection checkpoint revision conflict; reload before continuing")
      }
      let items: [CollectionCheckpointItem]
      do { items = try rawItems.map(CollectionCheckpointItem.init) } catch { throw collectionInputError() }
      guard Set(items).count == items.count else { throw collectionInputError() }
      if action == "record" {
        guard let cursor = config["cursor"],
          cursor == .null || nonEmptyString(cursor) != nil,
          (try JSONEncoder().encode(cursor)).count <= 16_384
        else { throw collectionInputError() }
        let complete: Bool
        switch config["acquisitionComplete"] {
        case nil: complete = cursor == .null
        case let .bool(value)?: complete = value
        default: throw collectionInputError()
        }
        let known = Set(state.pending + state.acknowledged)
        state.pending += items.filter { !known.contains($0) }
        state.cursor = cursor
        state.acquisitionComplete = complete
      } else {
        guard config["cursor"] == nil, config["acquisitionComplete"] == nil else { throw collectionInputError() }
        let known = Set(state.pending + state.acknowledged)
        guard items.allSatisfy(known.contains) else {
          throw AdapterExecutionError(.invalidInput, "collection checkpoint cannot acknowledge an unknown item version")
        }
        let completed = Set(items)
        state.pending.removeAll { completed.contains($0) }
        let prior = Set(state.acknowledged)
        state.acknowledged += items.filter { !prior.contains($0) }
      }
      guard state.revision < Int64.max else { throw collectionInputError() }
      state.revision += 1
      try state.trimAcknowledgements()
      try state.validate()
      let value = try JSONDecoder().decode(MemoryJSONValue.self, from: JSONEncoder().encode(state))
      guard try store.compareExchange(storeId: storeId, scope: scope, key: key,
        expectedValue: previous?.value, value: value) else {
        throw AdapterExecutionError(.invalidInput, "collection checkpoint revision conflict; reload before continuing")
      }
    }
    var payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(state))
    payload["pendingCount"] = .integer(Int64(state.pending.count))
    payload["processingComplete"] = .bool(state.pending.isEmpty)
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true,
      when: ["always": true, "acquire": !state.acquisitionComplete, "process": !state.pending.isEmpty], payload: payload)
  }
}

private func collectionInputError() -> AdapterExecutionError {
  AdapterExecutionError(.invalidInput, "invalid collection checkpoint configuration or metadata")
}

private struct CollectionCheckpointItem: Codable, Hashable {
  var id: String
  var version: String

  init(_ value: JSONValue) throws {
    guard case let .object(object) = value, Set(object.keys) == ["id", "version"],
      let id = nonEmptyString(object["id"]), let version = nonEmptyString(object["version"]),
      id.utf8.count <= 1024, version.utf8.count <= 1024 else { throw collectionInputError() }
    self.id = id
    self.version = version
  }

  func validate() throws {
    guard !id.isEmpty, !version.isEmpty, id.utf8.count <= 1024, version.utf8.count <= 1024 else {
      throw collectionInputError()
    }
  }
}

private struct CollectionCheckpointState: Codable {
  // Leave space for the output's pendingCount/processingComplete fields within
  // the common 8 MB node payload boundary.
  static let maximumBytes = 8_000_000 - 128
  var format = 1
  var revision: Int64 = 0
  var cursor: JSONValue = .null
  var acquisitionComplete = false
  var pending: [CollectionCheckpointItem] = []
  var acknowledged: [CollectionCheckpointItem] = []

  mutating func trimAcknowledgements() throws {
    // Seen versions are an optimization. Both record and acknowledgement must
    // leave room for pending work, including long URL/version identities.
    // Never trim a pending pair or wait for an arbitrary batch size.
    acknowledged = Array(acknowledged.suffix(10_000))
    var base = self
    base.acknowledged = []
    let encoder = JSONEncoder()
    let baseBytes = try encoder.encode(base).count
    guard baseBytes <= Self.maximumBytes else { throw collectionInputError() }
    let sizes = try acknowledged.map { try encoder.encode($0).count }
    var bytes = baseBytes + sizes.reduce(0, +) + max(0, sizes.count - 1)
    var dropped = 0
    while bytes > Self.maximumBytes, dropped < sizes.count {
      bytes -= sizes[dropped] + (sizes.count - dropped > 1 ? 1 : 0)
      dropped += 1
    }
    if dropped > 0 { acknowledged.removeFirst(dropped) }
  }

  func validate() throws {
    guard format == 1, revision >= 0, pending.count <= 10_000, acknowledged.count <= 10_000,
      Set(pending).count == pending.count, Set(acknowledged).count == acknowledged.count,
      Set(pending).isDisjoint(with: acknowledged), cursor == .null || nonEmptyString(cursor) != nil,
      (try JSONEncoder().encode(cursor)).count <= 16_384,
      (try JSONEncoder().encode(self)).count <= Self.maximumBytes
    else { throw collectionInputError() }
    try (pending + acknowledged).forEach { try $0.validate() }
  }
}
