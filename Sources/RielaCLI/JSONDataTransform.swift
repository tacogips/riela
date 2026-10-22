import Foundation
import RielaCore

/// Small, finite JSON operations. Paths are RFC 6901 pointers, never programs.
/// Neither strings in source data nor mapped values are template evaluated.
enum JSONDataTransform {
  static func run(_ input: JSONValue, steps: JSONValue) throws -> JSONValue {
    guard case let .array(operations) = steps, operations.count <= 32 else { throw invalid() }
    var value = input
    try checkSize(value)
    for operation in operations {
      guard case let .object(spec) = operation, spec.count == 1, let (name, argument) = spec.first else {
        throw invalid()
      }
      if name == "pick" {
        guard let found = try lookup(value, pointer: argument) else { throw invalid() }
        value = found
      } else {
        guard case let .array(items) = value, items.count <= 10_000 else { throw invalid() }
        value = .array(try apply(name, argument: argument, items: items))
      }
      try checkSize(value)
    }
    return value
  }

  private static func apply(_ name: String, argument: JSONValue, items: [JSONValue]) throws -> [JSONValue] {
    switch name {
    case "map":
      guard case let .object(fields) = argument, fields.count <= 256 else { throw invalid() }
      // Validate even for an empty input array.
      for source in fields.values { _ = try mapped(.null, source: source) }
      return try items.map { item in .object(try fields.mapValues { try mapped(item, source: $0) }) }
    case "filter":
      guard case let .object(condition) = argument, Set(condition.keys) == ["path", "equals"],
            let path = condition["path"], let expected = condition["equals"] else { throw invalid() }
      _ = try lookup(.null, pointer: path)
      return try items.filter { try lookup($0, pointer: path) == expected }
    case "unique":
      _ = try lookup(.null, pointer: argument)
      var seen = Set<String>()
      return try items.filter { item in
        guard let key = try lookup(item, pointer: argument) else { throw invalid() }
        switch key {
        case .string, .integer: return try seen.insert(key.compactJSONString()).inserted
        default: throw invalid()
        }
      }
    case "take":
      guard case let .integer(count) = argument, (0...10_000).contains(count) else { throw invalid() }
      return Array(items.prefix(Int(count)))
    default: throw invalid()
    }
  }

  private static func mapped(_ item: JSONValue, source: JSONValue) throws -> JSONValue {
    if case .string = source { return try lookup(item, pointer: source) ?? .null }
    guard case let .object(spec) = source else { throw invalid() }
    if Set(spec.keys) == ["literal"], let literal = spec["literal"] { return literal }
    guard Set(spec.keys).isSubset(of: ["path", "default"]), let path = spec["path"] else { throw invalid() }
    return try lookup(item, pointer: path) ?? spec["default"] ?? .null
  }

  private static func lookup(_ root: JSONValue, pointer: JSONValue) throws -> JSONValue? {
    guard case let .string(path) = pointer, path.utf8.count <= 4096,
          path.isEmpty || path.hasPrefix("/") else { throw invalid() }
    if path.isEmpty { return root }
    let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 64 else { throw invalid() }
    var value: JSONValue? = root
    for raw in parts {
      // Reject malformed RFC 6901 escapes, including when the path is missing.
      let text = String(raw)
      guard text.range(of: #"~(?![01])"#, options: .regularExpression) == nil else { throw invalid() }
      let key = text.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
      switch value {
      case let .object(fields): value = fields[key]
      case let .array(items):
        if let index = Int(key), index >= 0, String(index) == key, index < items.count {
          value = items[index]
        } else { value = nil }
      default: value = nil
      }
    }
    return value
  }

  private static func checkSize(_ value: JSONValue) throws {
    guard try JSONEncoder().encode(value).count <= 8_000_000 else { throw invalid() }
  }

  private static func invalid() -> AdapterExecutionError {
    AdapterExecutionError(.invalidInput, "JSON transform specification or input is invalid or exceeds its limits")
  }
}
