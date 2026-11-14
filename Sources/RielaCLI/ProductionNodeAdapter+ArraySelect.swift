import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let arraySelectRegistration = BuiltinAddonHandlerRegistration(name: "riela/array-select", bindsCLIVariablesAsInputs: false) { _, input, context in
    try snapshotWorkResult {
      try checkSnapshotWork(context)
      guard input.addon.version == nil || input.addon.version == "1",
        case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)) else { throw arraySelectInvalid() }
      let payload = try ArrayMetadataSelection.select(config, context: context)
      return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
    }
  }
}

/// A finite string-metadata query, not a query language or executable program.
enum ArrayMetadataSelection {
  static func select(_ config: JSONObject, context: AdapterExecutionContext = .init()) throws -> JSONObject {
    guard Set(config.keys).isSubset(of: ["items", "whereAll", "sortBy", "limit"]),
      case let .array(items)? = config["items"], items.count <= 10_000,
      case let .integer(limit) = config["limit"] ?? .integer(10_000), (0...10_000).contains(limit),
      try JSONEncoder().encode(config).count <= 8_000_000 else { throw arraySelectInvalid() }
    func specs(_ key: String) throws -> [JSONObject] {
      guard case let .array(values) = config[key] ?? .array([]), values.count <= 16 else { throw arraySelectInvalid() }
      return try values.map { guard case let .object(row) = $0 else { throw arraySelectInvalid() }; return row }
    }
    let conditions = try specs("whereAll").map(MetadataCondition.init)
    let order = try specs("sortBy").map(MetadataOrder.init)
    var rows: [SelectedMetadataRow] = []
    for (index, item) in items.enumerated() {
      try checkSnapshotWork(context)
      // Check every configured field even when an earlier condition excludes
      // the row, so malformed required metadata cannot disappear silently.
      let tests = try conditions.map { try $0.accepts(item) }
      let keys = try order.map { try $0.key(item) }
      if tests.allSatisfy({ $0 }) { rows.append(.init(value: item, keys: keys, index: index)) }
    }
    rows.sort { left, right in
      for (first, second) in zip(left.keys, right.keys) where first != second { return first.lexicographicallyPrecedes(second) }
      return left.index < right.index
    }
    try checkSnapshotWork(context)
    let payload: JSONObject = ["items": .array(rows.prefix(Int(limit)).map(\.value)),
      "matchedCount": .integer(Int64(rows.count)), "inputCount": .integer(Int64(items.count))]
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw arraySelectInvalid() }
    return payload
  }
}

private struct SelectedMetadataRow {
  let value: JSONValue
  let keys: [Data]
  let index: Int
}

private struct MetadataCondition {
  let path: JSONValue
  let allowed: Set<Data>
  let exclude: Bool
  init(_ row: JSONObject) throws {
    guard let pointer = row["path"], row.count == 2 else { throw arraySelectInvalid() }
    _ = try JSONDataTransform.lookup(.null, pointer: pointer); path = pointer
    if case let .string(value)? = row["equals"] { allowed = [Data(value.utf8)]; exclude = false
    } else {
      guard let key = row["in"] != nil ? "in" : row["notIn"] != nil ? "notIn" : nil,
        case let .array(values)? = row[key], values.count <= 10_000 else { throw arraySelectInvalid() }
      allowed = Set(try values.map { guard case let .string(value) = $0 else { throw arraySelectInvalid() }; return Data(value.utf8) })
      exclude = key == "notIn"
    }
  }
  func accepts(_ item: JSONValue) throws -> Bool {
    guard case let .string(value)? = try JSONDataTransform.lookup(item, pointer: path) else { throw arraySelectInvalid() }
    return allowed.contains(Data(value.utf8)) != exclude
  }
}

private struct MetadataOrder {
  let path: JSONValue
  let fallback: JSONValue?
  let rank: [Data: Int]?
  init(_ row: JSONObject) throws {
    guard Set(row.keys).isSubset(of: ["path", "default", "rank"]), let pointer = row["path"] else { throw arraySelectInvalid() }
    _ = try JSONDataTransform.lookup(.null, pointer: pointer); path = pointer
    if let value = row["default"], case .string = value {} else if row["default"] != nil { throw arraySelectInvalid() }
    fallback = row["default"]
    if let raw = row["rank"] {
      guard case let .array(values) = raw, values.count <= 256 else { throw arraySelectInvalid() }
      var positions: [Data: Int] = [:]
      for (index, item) in values.enumerated() {
        guard case let .string(value) = item, positions.updateValue(index, forKey: Data(value.utf8)) == nil else { throw arraySelectInvalid() }
      }
      rank = positions
    } else { rank = nil }
  }
  func key(_ item: JSONValue) throws -> Data {
    guard case let .string(value)? = try JSONDataTransform.lookup(item, pointer: path) ?? fallback else { throw arraySelectInvalid() }
    let bytes = Data(value.utf8)
    if let rank { let index = rank[bytes] ?? rank.count; return Data([UInt8(index >> 8), UInt8(index & 255)]) }
    return bytes
  }
}

private func arraySelectInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded metadata selection or required string field") }
