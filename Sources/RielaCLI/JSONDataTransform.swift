import Foundation
import RielaAddonSupport
import RielaCore

/// Small, finite JSON operations. Paths are RFC 6901 pointers, never programs.
/// Neither strings in source data nor mapped values are template evaluated.
enum JSONDataTransform {
  fileprivate enum Operation: Sendable {
    case pick(JSONValue)
    case map(JSONObject)
    case filter(path: JSONValue, equals: JSONValue)
    case unique(JSONValue)
    case take(Int)
  }

  struct Program: Sendable {
    fileprivate let operations: [Operation]

    /// `checkInputSize: false` is for runtime-owned inputs that are already in
    /// memory, such as a provider payload that repeats its response (container
    /// readers keep both `data` and `response`). Every intermediate value and the
    /// result stay bounded; a program without operations returns its input, so the
    /// input is then still checked.
    func run(_ input: JSONValue, checkInputSize: Bool = true) throws -> JSONValue {
      var value = input
      if checkInputSize || operations.isEmpty {
        try checkSize(value)
      }
      for operation in operations {
        if case let .pick(pointer) = operation {
          guard let found = try lookup(value, pointer: pointer) else { throw invalid() }
          value = found
        } else {
          guard case let .array(items) = value, items.count <= 10_000 else { throw invalid() }
          value = .array(try apply(operation, items: items))
        }
        try checkSize(value)
      }
      return value
    }
  }

  static func run(_ input: JSONValue, steps: JSONValue) throws -> JSONValue {
    try compile(steps).run(input)
  }

  /// Validate the entire finite program before a gateway performs any effect.
  /// This does not inspect provider data or require paths to exist yet.
  static func compile(_ steps: JSONValue) throws -> Program {
    guard case let .array(operations) = steps, operations.count <= 32 else { throw invalid() }
    try checkSize(steps)
    return Program(operations: try operations.map { operation in
      guard case let .object(spec) = operation, spec.count == 1, let (name, argument) = spec.first else {
        throw invalid()
      }
      switch name {
      case "pick":
        _ = try lookup(.null, pointer: argument)
        return .pick(argument)
      case "map":
        guard case let .object(fields) = argument, fields.count <= 256 else { throw invalid() }
        for source in fields.values { _ = try mapped(.null, source: source) }
        return .map(fields)
      case "filter":
        guard case let .object(condition) = argument, Set(condition.keys) == ["path", "equals"],
          let path = condition["path"], let expected = condition["equals"] else { throw invalid() }
        _ = try lookup(.null, pointer: path)
        return .filter(path: path, equals: expected)
      case "unique":
        _ = try lookup(.null, pointer: argument)
        return .unique(argument)
      case "take":
        guard case let .integer(count) = argument, (0...10_000).contains(count) else { throw invalid() }
        return .take(Int(count))
      default: throw invalid()
      }
    })
  }

  private static func apply(_ operation: Operation, items: [JSONValue]) throws -> [JSONValue] {
    switch operation {
    case let .map(fields):
      return try items.map { item in .object(try fields.mapValues { try mapped(item, source: $0) }) }
    case let .filter(path, expected):
      return try items.filter { try lookup($0, pointer: path) == expected }
    case let .unique(pointer):
      var seen = Set<String>()
      return try items.filter { item in
        guard let key = try lookup(item, pointer: pointer) else { throw invalid() }
        switch key {
        case .string, .integer: return try seen.insert(key.compactJSONString()).inserted
        default: throw invalid()
        }
      }
    case let .take(count): return Array(items.prefix(count))
    case .pick: throw invalid()
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
    guard try JSONEncoder().encode(value).count <= GatewayJSONLimits.maximumEncodedBytes else { throw invalid() }
  }

  private static func invalid() -> AdapterExecutionError {
    AdapterExecutionError(.invalidInput, "JSON transform specification or input is invalid or exceeds its limits")
  }
}
