import Foundation
import RielaAddonSupport
import RielaCore

// X exposes SDL rather than a GatewaySDKKit catalog. Keep its bounded literal
// codec here until its SDK exports a catalog, under the same request boundary.
/// JSON mode never interprets argument strings as query source or templates a
/// second time. The SDK schema remains the authority for operations and types.
func builtinGatewayXJSONDocument(_ input: WorkflowAddonExecutionInput) throws -> String? {
  let config = input.addon.config ?? [:]
  guard config["operation"] != nil else {
    guard config["arguments"] == nil, config["select"] == nil, config["selection"] == nil else {
      throw AdapterExecutionError(.invalidInput, "X JSON arguments and select require operation")
    }
    return nil
  }
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["nowVariables"] == nil else {
    throw AdapterExecutionError(.invalidInput, "X JSON operation cannot be combined with query templates")
  }
  guard case let .string(operation)? = config["operation"] else {
    throw AdapterExecutionError(.invalidInput, "X JSON operation must be literal")
  }
  _ = try xGraphQLName(operation)
  let variables = try addonVariables(for: input)
  let arguments: JSONObject
  if let supplied = config["arguments"] {
    guard case let .object(object) = try renderAddonConfig(supplied, variables: variables) else {
      throw AdapterExecutionError(.invalidInput, "X JSON arguments must be an object")
    }
    arguments = object
  } else { arguments = [:] }
  guard config["select"] == nil || config["selection"] == nil else {
    throw AdapterExecutionError(.invalidInput, "X JSON select and selection cannot be combined")
  }
  let selection: JSONObject
  if case let .object(fields)? = config["select"] {
    selection = fields
  } else if case let .array(paths)? = config["selection"] {
    guard !paths.isEmpty, paths.count <= 256 else {
      throw AdapterExecutionError(.invalidInput, "X JSON selection exceeds its limits")
    }
    var root: JSONObject = [:]
    for value in paths {
      guard case let .string(path) = value, path.utf8.count <= 4096 else {
        throw AdapterExecutionError(.invalidInput, "X JSON selection requires field paths")
      }
      let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      guard parts.count <= 16 else { throw AdapterExecutionError(.invalidInput, "X JSON selection exceeds its depth limit") }
      try insertXSelection(parts[...], into: &root)
    }
    selection = root
  } else {
    throw AdapterExecutionError(.invalidInput, "X JSON mode requires select or selection field paths")
  }
  let name = try xGraphQLName(operation)
  let args = try arguments.keys.sorted().map { key in
    try "\(xGraphQLName(key)): \(xGraphQLLiteral(arguments[key]!, depth: 0))"
  }.joined(separator: ", ")
  let fields = try xGraphQLSelection(selection, depth: 0)
  let document = "query { \(name)\(args.isEmpty ? "" : "(\(args))") { \(fields) } }"
  guard document.utf8.count <= 1_000_000 else {
    throw AdapterExecutionError(.invalidInput, "X JSON query exceeds the size limit")
  }
  return document
}

private func xGraphQLName(_ name: String) throws -> String {
  guard name.range(of: #"^[_A-Za-z][_0-9A-Za-z]*$"#, options: .regularExpression) != nil,
        !name.hasPrefix("__"), name.utf8.count <= 128 else {
    throw AdapterExecutionError(.invalidInput, "X JSON contains an invalid field name")
  }
  return name
}

private func xGraphQLSelection(_ fields: JSONObject, depth: Int) throws -> String {
  guard depth < 16, !fields.isEmpty, fields.count <= 256 else {
    throw AdapterExecutionError(.invalidInput, "X JSON select is empty or exceeds its limits")
  }
  return try fields.keys.sorted().map { key in
    let name = try xGraphQLName(key)
    switch fields[key]! {
    case .bool(true): return name
    case let .object(nested): return try "\(name) { \(xGraphQLSelection(nested, depth: depth + 1)) }"
    default: throw AdapterExecutionError(.invalidInput, "X JSON select expects true or a nested object")
    }
  }.joined(separator: " ")
}

private func xGraphQLLiteral(_ value: JSONValue, depth: Int) throws -> String {
  guard depth < 16 else { throw AdapterExecutionError(.invalidInput, "X JSON arguments exceed the depth limit") }
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
      throw AdapterExecutionError(.invalidInput, "X JSON selection has conflicting field paths")
    }
    root[name] = .bool(true)
  } else {
    guard root[name] != .bool(true) else {
      throw AdapterExecutionError(.invalidInput, "X JSON selection has conflicting field paths")
    }
    var nested: JSONObject = [:]
    if case let .object(existing)? = root[name] { nested = existing }
    try insertXSelection(parts.dropFirst(), into: &nested)
    root[name] = .object(nested)
  }
}
