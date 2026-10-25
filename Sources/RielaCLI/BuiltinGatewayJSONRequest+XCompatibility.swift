import Foundation
import RielaAddonSupport
import RielaCore

// 2026-10-25 R3 outcome B: X 0.1.26 exposes SDL through its public in-process
// read CLI, while GatewaySDKKit 0.1.1 has no SDL-to-catalog parser. A bounded
// Query-name scanner checks operation names; this serializer stays the SDK's
// type authority, and the reader accepts no variables. Nested `select` remains
// a compatibility alias for `selection`.
/// JSON mode never interprets argument strings as query source or templates a
/// second time. The SDK schema remains the authority for operations and types.
func builtinGatewayXJSONDocument(_ input: WorkflowAddonExecutionInput) throws -> String? {
  let config = input.addon.config ?? [:]
  guard try xGatewayJSONShape(config: config, addonName: input.addon.name) != nil else { return nil }
  return try xGatewayJSONDocument(
    config: config, variables: addonVariables(for: input), addonName: input.addon.name
  )
}

struct XGatewayJSONShape {
  var operation: String
  var selection: JSONObject
}

func xGatewayJSONShape(config: JSONObject, addonName: String) throws -> XGatewayJSONShape? {
  guard config["operation"] != nil else {
    guard config["arguments"] == nil, config["select"] == nil, config["selection"] == nil else {
      throw xJSONError("X JSON arguments and select require operation")
    }
    return nil
  }
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["nowVariables"] == nil else {
    throw xJSONError("X JSON operation cannot be combined with query templates")
  }
  guard case let .string(operation)? = config["operation"] else {
    throw xJSONError("X JSON operation must be literal")
  }
  let name = try xGraphQLName(operation)
  guard config["select"] == nil || config["selection"] == nil else {
    throw xJSONError("X JSON select and selection cannot be combined")
  }
  let selection: JSONObject
  if case let .object(fields)? = config["select"] {
    selection = fields
  } else if case let .array(values)? = config["selection"] {
    var root: JSONObject = [:]
    for path in try BuiltinGatewayJSONRequest.fieldPaths(values, addonName: addonName) {
      let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      guard parts.count <= xMaximumDepth else { throw xJSONError("X JSON selection exceeds its depth limit") }
      try insertXSelection(parts[...], into: &root)
    }
    selection = root
  } else {
    // X has no catalog default selection.
    throw xJSONError("X JSON mode requires select or selection field paths")
  }
  return XGatewayJSONShape(operation: name, selection: selection)
}

func xGatewayJSONDocument(config: JSONObject, variables: JSONObject, addonName: String) throws -> String? {
  guard let shape = try xGatewayJSONShape(config: config, addonName: addonName) else { return nil }
  let arguments = try renderGatewayJSONArguments(config["arguments"], variables: variables, addonName: addonName)
  let args = try arguments.keys.sorted().map { key in
    try "\(xGraphQLName(key)): \(xGraphQLLiteral(arguments[key]!, depth: 0))"
  }.joined(separator: ", ")
  let fields = try xGraphQLSelection(shape.selection, depth: 0)
  let document = "query { \(shape.operation)\(args.isEmpty ? "" : "(\(args))") { \(fields) } }"
  guard document.utf8.count <= 1_000_000 else {
    throw xJSONError("X JSON query exceeds the size limit")
  }
  return document
}

private let xMaximumDepth = 16

private func xJSONError(_ message: String) -> AdapterExecutionError {
  AdapterExecutionError(.policyBlocked, message)
}

private func xGraphQLName(_ name: String) throws -> String {
  guard name.range(of: #"^[_A-Za-z][_0-9A-Za-z]*$"#, options: .regularExpression) != nil,
        !name.hasPrefix("__"), name.utf8.count <= 128 else {
    throw xJSONError("X JSON contains an invalid field name")
  }
  return name
}

private func xGraphQLSelection(_ fields: JSONObject, depth: Int) throws -> String {
  guard depth < xMaximumDepth, !fields.isEmpty, fields.count <= 256 else {
    throw xJSONError("X JSON select is empty or exceeds its limits")
  }
  return try fields.keys.sorted().map { key in
    let name = try xGraphQLName(key)
    switch fields[key]! {
    case .bool(true): return name
    case let .object(nested): return try "\(name) { \(xGraphQLSelection(nested, depth: depth + 1)) }"
    default: throw xJSONError("X JSON select expects true or a nested object")
    }
  }.joined(separator: " ")
}

/// Numbers render through the Swift standard library formatter (identical on
/// macOS and Linux): an integral double such as `25.0` renders as `25`, which
/// GraphQL accepts for both `Int` and `Float` arguments. Non-finite numbers are
/// rejected earlier by `renderGatewayJSONArguments`.
private func xGraphQLLiteral(_ value: JSONValue, depth: Int) throws -> String {
  guard depth < xMaximumDepth else { throw xJSONError("X JSON arguments exceed the depth limit") }
  switch value {
  case let .array(items):
    return try "[" + items.map { try xGraphQLLiteral($0, depth: depth + 1) }.joined(separator: ", ") + "]"
  case let .object(fields):
    return try "{" + fields.keys.sorted().map {
      try "\(xGraphQLName($0)): \(xGraphQLLiteral(fields[$0]!, depth: depth + 1))"
    }.joined(separator: ", ") + "}"
  default: return try value.compactJSONString()
  }
}

private func insertXSelection(_ parts: ArraySlice<String>, into root: inout JSONObject) throws {
  guard let first = parts.first else { return }
  let name = try xGraphQLName(first)
  if parts.count == 1 {
    guard root[name] == nil || root[name] == .bool(true) else {
      throw xJSONError("X JSON selection has conflicting field paths")
    }
    root[name] = .bool(true)
  } else {
    guard root[name] != .bool(true) else {
      throw xJSONError("X JSON selection has conflicting field paths")
    }
    var nested: JSONObject = [:]
    if case let .object(existing)? = root[name] { nested = existing }
    try insertXSelection(parts.dropFirst(), into: &nested)
    root[name] = .object(nested)
  }
}
