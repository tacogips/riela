import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  static let writeIntentStoreRegistration = BuiltinAddonHandlerRegistration(name: "riela/write-intent-store", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try resolver.executeWriteIntentStore(input, context: context)
  }

  func executeWriteIntentStore(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      case let .string(action)? = config["action"],
      case let .object(storage)? = config["storage"], Set(storage.keys) == ["rootDirectory", "storeId", "scope"],
      let root = nonEmptyString(storage["rootDirectory"]), let id = nonEmptyString(storage["storeId"]),
      let scope = nonEmptyString(storage["scope"]), root.hasPrefix("/") else { throw writeIntentInvalid() }
    let store = RielaWriteIntentStore(rootDirectory: root, storeId: id, scope: scope)
    func reference(_ value: JSONValue) throws -> WriteIntentReference {
      guard case let .object(object) = value, Set(object.keys) == ["version", "ownerSHA256", "slot", "key", "sha256"] else { throw writeIntentInvalid() }
      return try JSONDecoder().decode(WriteIntentReference.self, from: JSONEncoder().encode(value))
    }
    let payload: JSONObject
    do {
      try checkSnapshotWork(context)
      switch action {
      case "stage":
        guard Set(config.keys) == ["action", "storage", "key", "serializedJSON", "selectedReference"],
          let key = nonEmptyString(config["key"]), case let .string(value)? = config["serializedJSON"],
          let selected = config["selectedReference"] else { throw writeIntentInvalid() }
        let ref = try store.stage(key: key, serializedJSON: value, selected: selected == .null ? nil : reference(selected))
        payload = ["reference": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ref))]
      case "load":
        guard Set(config.keys) == ["action", "storage", "reference"], let raw = config["reference"] else { throw writeIntentInvalid() }
        let value = try store.load(reference(raw))
        payload = ["found": .bool(value != nil), "serializedJSON": value.map(JSONValue.string) ?? .null]
      case "clear":
        guard Set(config.keys) == ["action", "storage", "released"], config["released"] == .bool(true) else { throw writeIntentInvalid() }
        try store.clear(); payload = ["cleared": .bool(true)]
      default: throw writeIntentInvalid()
      }
    } catch is CancellationError { throw CancellationError()
    } catch { throw writeIntentInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
  }
}

private func writeIntentInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "write intent storage failed; retain the journal-selected target")
}
