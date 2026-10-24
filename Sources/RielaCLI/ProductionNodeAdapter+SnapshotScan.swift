import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  static let snapshotScanRegistration = BuiltinAddonHandlerRegistration(name: "riela/snapshot-scan", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try snapshotWorkResult { try resolver.executeSnapshotScan(input, context: context) }
  }

  func executeSnapshotScan(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["storage", "valueFrom", "whereAny", "sortBy", "maxDatabases", "maxPayloadBytes", "presence", "valueSchema", "cacheReconciliation", "valueProjection"]),
      case let .object(storage)? = config["storage"],
      Set(storage.keys).isSubset(of: ["memoryPrefix", "memoryIds", "workflowId", "nodeId", "tag", "memoryRoot"]),
      case let .integer(maximum) = config["maxDatabases"] ?? .integer(4096), (1...4096).contains(maximum),
      case let .integer(limit) = config["maxPayloadBytes"] ?? .integer(7_990_000), (1...64 * 1024 * 1024).contains(limit),
      try JSONEncoder().encode(config).count <= 8_000_000 else { throw snapshotScanInvalid() }
    func text(_ key: String, fallback: String) throws -> String {
      guard let value = storage[key] else { return fallback }
      guard case let .string(text) = value, !text.isEmpty else { throw snapshotScanInvalid() }; return text
    }
    try checkSnapshotWork(context)
    let workflow = try text("workflowId", fallback: input.workflowId), tag = try text("tag", fallback: "checkpoint")
    let node = storage["nodeId"] == .null ? nil : try text("nodeId", fallback: input.nodeId)
    guard !workflow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw snapshotScanInvalid() }
    let rawRoot = try text("memoryRoot", fallback: environment["RIELA_MEMORY_ROOT"] ?? RielaMemoryStore.defaultRootDirectory(workingDirectory: workingDirectory.path))
    let directory = URL(fileURLWithPath: rawRoot, relativeTo: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
    let store = RielaMemoryStore(rootDirectory: directory.path)
    let selection = try SnapshotScanSelection(config)
    var paths: [URL] = []
    // Validate the complete request before a legacy read can install baselines.
    if case let .array(ids)? = storage["memoryIds"], storage["memoryPrefix"] == nil {
      guard ids.count <= maximum else { throw snapshotScanInvalid() }
      var seen = Set<Data>()
      paths = try ids.map { id in
        guard case let .string(memory) = id, seen.insert(Data(memory.utf8)).inserted else { throw snapshotScanInvalid() }
        return URL(fileURLWithPath: try store.databasePath(memoryId: memory))
      }
    } else if case let .string(prefix)? = storage["memoryPrefix"], storage["memoryIds"] == nil,
      prefix.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$"#, options: .regularExpression) != nil {
      _ = try store.databasePath(memoryId: prefix)
      if try snapshotDirectoryExists(directory) {
        let failure = SnapshotScanEnumerationFailure()
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
          options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failure.mark(); return false }) else { throw snapshotScanInvalid() }
        var visited = 0
        for case let path as URL in iterator {
          try checkSnapshotWork(context)
          visited += 1; guard visited <= 100_000 else { throw snapshotScanInvalid() }
          guard path.lastPathComponent.hasPrefix(prefix), path.pathExtension == "sqlite" else { continue }
          paths.append(path); guard paths.count <= maximum else { throw snapshotScanInvalid() }
          _ = try store.databasePath(memoryId: path.deletingPathExtension().lastPathComponent)
        }
        guard !failure.failed else { throw snapshotScanInvalid() }
      }
    } else { throw snapshotScanInvalid() }
    _ = try snapshotDirectoryExists(directory)
    var files = Set<String>()
    for path in paths {
      try checkSnapshotWork(context); try preflightSnapshotFiles(path)
      if let identity = try snapshotDatabaseIdentity(path), !files.insert(identity).inserted { throw snapshotScanInvalid() }
    }
    let reconciliation: SnapshotCacheReconciliation?
    if let raw = config["cacheReconciliation"] {
      guard storage["memoryIds"] != nil else { throw snapshotScanInvalid() }
      reconciliation = try .init(raw, memoryIds: Set(paths.map { $0.deletingPathExtension().lastPathComponent }), resolver: self, workflowId: input.workflowId)
      for binding in reconciliation!.bindings.values { _ = try selection.project(binding.initialValue) }
    } else { reconciliation = nil }
    var rows: [SnapshotScanRow] = [], bytes = 2
    for path in paths.sorted(by: { Data($0.lastPathComponent.utf8).lexicographicallyPrecedes(Data($1.lastPathComponent.utf8)) }) {
      try checkSnapshotWork(context)
      let memory = path.deletingPathExtension().lastPathComponent
      func read(_ binding: SnapshotCacheReconciliation.Binding?) throws -> (MemorySnapshot?, JSONValue)? {
        let snapshot = try store.loadSnapshot(memoryId: memory, workflowId: workflow, nodeId: node, tag: tag, maxPayloadBytes: Int(limit))
        guard let raw = snapshot.map({ jsonValue(from: $0.record.payload) }) ?? binding?.initialValue else { return nil }
        let selected = try selection.project(raw)
        if let binding { try SnapshotCacheReconciliation.reconcile(raw, binding: binding, context: context) }
        return (snapshot, selected)
      }
      let result = try reconciliation.map { try $0.read(memoryId: memory, context: context) { try read($0) } } ?? read(nil)
      guard let (snapshot, value) = result else { continue }
      guard try selection.accepts(value) else { continue }
      let row: JSONValue = .object(["memoryId": .string(memory), "head": snapshot.map { .object(["recordId": .integer($0.head.recordId),
        "version": .integer($0.head.version), "scope": .string($0.head.scope)]) } ?? .null, "value": value])
      bytes += try JSONEncoder().encode(row).count + 1
      guard bytes <= 7_990_000 else { throw snapshotScanInvalid() }
      rows.append(.init(value: row, keys: try selection.keys(value), index: rows.count))
    }
    rows.sort { left, right in
      for (first, second) in zip(left.keys, right.keys) where first != second { return first.lexicographicallyPrecedes(second) }
      return left.index < right.index
    }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      payload: ["items": .array(rows.map(\.value)), "scannedCount": .integer(Int64(paths.count))])
  }
}

private struct SnapshotScanRow {
  let value: JSONValue
  let keys: [Data]
  let index: Int
}

private struct SnapshotScanSelection {
  var pointer: JSONValue
  var conditions: [JSONObject]
  var sort: [JSONObject]
  var presence: JSONObject?
  var schema: JSONObject?
  var projection: JSONDataProjection?
  init(_ config: JSONObject) throws {
    if let raw = config["valueProjection"] { projection = try JSONDataProjection(raw) }
    if let raw = config["valueSchema"] {
      guard case let .object(value) = raw, DefaultWorkflowOutputValidator().validateContractSchema(value) == nil else { throw snapshotScanInvalid() }
      schema = value
    }
    if let raw = config["presence"] {
      guard case let .object(fields) = raw, !fields.isEmpty, fields.count <= 64, config["valueFrom"] == nil, config["valueProjection"] == nil,
        fields.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw snapshotScanInvalid() }
      for path in fields.values { _ = try JSONDataTransform.lookup(.null, pointer: path) }
      presence = fields
    }
    pointer = config["valueFrom"] ?? .string("")
    _ = try JSONDataTransform.lookup(.null, pointer: pointer)
    func specs(_ key: String) throws -> [JSONObject] {
      guard case let .array(values) = config[key] ?? .array([]), values.count <= 8 else { throw snapshotScanInvalid() }
      return try values.map { guard case let .object(row) = $0 else { throw snapshotScanInvalid() }; return row }
    }
    conditions = try specs("whereAny"); sort = try specs("sortBy")
    for row in conditions {
      guard Set(row.keys) == ["path", "equals"], let path = row["path"], let value = row["equals"] else { throw snapshotScanInvalid() }
      switch value {
      case .bool, .string, .null: break
      case let .integer(value):
        // Memory JSON uses Double for numbers. Refuse predicates whose exact
        // integer identity cannot survive that representation.
        guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) else { throw snapshotScanInvalid() }
      default: throw snapshotScanInvalid()
      }
      _ = try JSONDataTransform.lookup(.null, pointer: path)
    }
    for row in sort {
      guard Set(row.keys).isSubset(of: ["path", "default"]), let path = row["path"] else { throw snapshotScanInvalid() }
      if let value = row["default"], case .string = value {} else if row["default"] != nil { throw snapshotScanInvalid() }
      _ = try JSONDataTransform.lookup(.null, pointer: path)
    }
  }
  func project(_ raw: JSONValue) throws -> JSONValue {
    if let schema {
      guard case let .object(value) = raw,
        try DefaultWorkflowOutputValidator().validate(.init(source: .inlineCandidate, payload: value, completionPassed: true),
          contract: .init(schema: schema, requiredObject: true)).status == .accepted else { throw snapshotScanInvalid() }
    }
    if let presence {
      return .object(try presence.mapValues { pointer in
        let value = try JSONDataTransform.lookup(raw, pointer: pointer)
        return .bool(value != nil && value != .null)
      })
    }
    guard let value = try JSONDataTransform.lookup(raw, pointer: pointer) else { throw snapshotScanInvalid() }
    return try projection?.run(value) ?? value
  }
  func accepts(_ value: JSONValue) throws -> Bool {
    var matched = conditions.isEmpty
    for row in conditions {
      guard let actual = try JSONDataTransform.lookup(value, pointer: row["path"]!) else { continue }
      let expected = row["equals"]!
      switch (actual, expected) {
      case let (.number(number), .integer(integer)):
        guard number.isFinite else { throw snapshotScanInvalid() }
        if number == Double(integer) { matched = true }
        continue
      case (.bool, .bool), (.string, .string), (.integer, .integer), (.null, .null): break
      default: throw snapshotScanInvalid()
      }
      if actual == expected { matched = true }
    }
    return matched
  }
  func keys(_ value: JSONValue) throws -> [Data] {
    try sort.map { row in
      guard case let .string(text)? = try JSONDataTransform.lookup(value, pointer: row["path"]!) ?? row["default"] else { throw snapshotScanInvalid() }
      return Data(text.utf8)
    }
  }
}

private func snapshotScanInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded snapshot scan or metadata") }
