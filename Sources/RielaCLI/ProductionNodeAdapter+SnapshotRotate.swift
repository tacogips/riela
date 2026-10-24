import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  static let snapshotRotateRegistration = BuiltinAddonHandlerRegistration(name: "riela/snapshot-rotate", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try snapshotWorkResult { try resolver.executeSnapshotRotate(input, context: context) }
  }

  /// Reserve one attempted prefix using CAS. This never acknowledges the items.
  func executeSnapshotRotate(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["storage", "items", "maximum", "cursorPointer", "initialValue", "context"]),
      case let .object(storage)? = config["storage"],
      Set(storage.keys).isSubset(of: ["memoryId", "workflowId", "nodeId", "tag", "memoryRoot"]),
      case let .array(items)? = config["items"], !items.isEmpty, items.count <= 10_000,
      case let .integer(maximum)? = config["maximum"], (1...10_000).contains(maximum),
      let pointer = config["cursorPointer"], let initial = config["initialValue"],
      try JSONEncoder().encode(config).count <= 7_990_000 else { throw snapshotRotateInvalid() }
    // Validate both pointer syntax and writable object parents before IO.
    let probe = try replacingSnapshotCursor(initial, pointer: pointer, cursor: "")
    guard case .object = probe else { throw snapshotRotateInvalid() }
    let ids = try items.map { item -> Data in
      guard case let .string(id) = item, !id.isEmpty, id.utf8.count <= 1024 else { throw snapshotRotateInvalid() }
      return Data(id.utf8)
    }.sorted { $0.lexicographicallyPrecedes($1) }
    guard Set(ids).count == ids.count else { throw snapshotRotateInvalid() }
    func text(_ key: String, fallback: String? = nil) throws -> String {
      guard case let .string(value) = storage[key] ?? fallback.map(JSONValue.string) ?? .null, !value.isEmpty else { throw snapshotRotateInvalid() }
      return value
    }
    let memory = try text("memoryId"), workflow = try text("workflowId", fallback: input.workflowId)
    let node = storage["nodeId"] == .null ? nil : try text("nodeId", fallback: input.nodeId)
    let tag = try text("tag", fallback: "checkpoint")
    guard !workflow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw snapshotRotateInvalid() }
    let root = try text("memoryRoot", fallback: environment["RIELA_MEMORY_ROOT"] ?? RielaMemoryStore.defaultRootDirectory(workingDirectory: workingDirectory.path))
    let directory = URL(fileURLWithPath: root, relativeTo: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
    let store = RielaMemoryStore(rootDirectory: directory.path)
    let path = try store.databasePath(memoryId: memory)
    try preflightSnapshotFiles(URL(fileURLWithPath: path))
    for _ in 0..<8 {
      try checkSnapshotWork(context)
      let before = try store.loadSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag, maxPayloadBytes: 7_990_000)
      let value = before.map { jsonValue(from: $0.record.payload) } ?? initial
      let cursor = try JSONDataTransform.lookup(value, pointer: pointer) ?? .string("")
      guard case let .string(after) = cursor else { throw snapshotRotateInvalid() }
      let offset = ids.firstIndex(where: { Data(after.utf8).lexicographicallyPrecedes($0) }) ?? 0
      let selected = (0..<min(Int(maximum), ids.count)).map { ids[(offset + $0) % ids.count] }
      guard let last = selected.last, let next = String(data: last, encoding: .utf8) else { throw snapshotRotateInvalid() }
      let updated = try replacingSnapshotCursor(value, pointer: pointer, cursor: next)
      let payload: JSONObject = ["items": .array(selected.map { .string(String(data: $0, encoding: .utf8)!) }),
        "after": .string(next), "context": config["context"] ?? .null]
      guard try JSONEncoder().encode(payload).count <= 7_990_000,
        try JSONEncoder().encode(updated).count <= 7_990_000 else { throw snapshotRotateInvalid() }
      try checkSnapshotWork(context)
      do {
        _ = try store.commitSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag,
          expectedHead: before?.head, payload: memoryJSONValue(from: updated), maxPayloadBytes: 7_990_000)
        return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
      } catch MemorySnapshotError.conflict { continue }
    }
    throw AdapterExecutionError(.invalidInput, "snapshot selection contended; retry the operation")
  }
}

private func replacingSnapshotCursor(_ value: JSONValue, pointer: JSONValue, cursor: String) throws -> JSONValue {
  _ = try JSONDataTransform.lookup(.null, pointer: pointer)
  guard case let .string(path) = pointer, !path.isEmpty else { throw snapshotRotateInvalid() }
  let segments = path.dropFirst().components(separatedBy: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
  func replace(_ current: JSONValue, index: Int) throws -> JSONValue {
    guard case var .object(object) = current else { throw snapshotRotateInvalid() }
    let key = segments[index]
    object[key] = index == segments.count - 1 ? .string(cursor) : try replace(object[key] ?? .object([:]), index: index + 1)
    return .object(object)
  }
  return try replace(value, index: 0)
}

private func snapshotRotateInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded snapshot selection or cursor") }
