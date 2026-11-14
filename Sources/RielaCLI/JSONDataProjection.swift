import Foundation
import RielaCore

/// Declarative metadata projection; source strings are never evaluated.
struct JSONDataProjection: Sendable {
  indirect enum Selection: Sendable {
    case value(String)
    case fields(String, JSONDataProjection)
    case values(String, JSONDataProjection)
    case nonEmpty(String)
  }
  let fields: [String: Selection]

  init(_ raw: JSONValue, depth: Int = 0) throws {
    guard depth <= 16, case let .object(fields) = raw, fields.count <= 256 else { throw invalidProjection() }
    self.fields = try fields.mapValues { spec in
      if case let .string(path) = spec { try validateProjectionPath(path); return .value(path) }
      guard case let .object(object) = spec else { throw invalidProjection() }
      if Set(object.keys) == ["nonEmpty"], case let .string(path)? = object["nonEmpty"] {
        try validateProjectionPath(path); return .nonEmpty(path)
      }
      guard object.count == 2, case let .string(path)? = object["from"] else { throw invalidProjection() }
      try validateProjectionPath(path)
      if let fields = object["fields"] { return .fields(path, try .init(fields, depth: depth + 1)) }
      if let values = object["mapValues"] { return .values(path, try .init(values, depth: depth + 1)) }
      throw invalidProjection()
    }
  }

  func run(_ input: JSONValue) throws -> JSONValue {
    var budget = 100_000
    return try project(input, budget: &budget)
  }

  private func project(_ input: JSONValue, budget: inout Int) throws -> JSONValue {
    budget -= 1
    guard budget >= 0, case .object = input else { throw invalidProjection() }
    var output: JSONObject = [:]
    for (key, selection) in fields {
      budget -= 1; guard budget >= 0 else { throw invalidProjection() }
      let path: String
      switch selection {
      case let .value(value), let .fields(value, _), let .values(value, _), let .nonEmpty(value): path = value
      }
      let value = try JSONDataTransform.lookup(input, pointer: .string(path))
      if case .nonEmpty = selection {
        switch value {
        case nil, .null?: output[key] = .bool(false)
        case let .array(items)?: output[key] = .bool(!items.isEmpty)
        case let .object(items)?: output[key] = .bool(!items.isEmpty)
        default: throw invalidProjection()
        }
        continue
      }
      guard let value else { continue }
      if value == .null { output[key] = .null; continue }
      switch selection {
      case .value: output[key] = value
      case let .fields(_, plan): output[key] = try plan.project(value, budget: &budget)
      case let .values(_, plan):
        guard case let .object(values) = value, values.count <= 10_000 else { throw invalidProjection() }
        output[key] = .object(try values.mapValues { try plan.project($0, budget: &budget) })
      case .nonEmpty: break
      }
    }
    return .object(output)
  }
}

private func validateProjectionPath(_ path: String) throws {
  _ = try JSONDataTransform.lookup(.null, pointer: .string(path))
}
private func invalidProjection() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded JSON metadata projection") }
