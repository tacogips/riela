import Foundation
import GatewaySDKKit
import RielaCore

extension BuiltinGatewayJSONRequest {
  /// Older reader executables accept documents but not variable dictionaries.
  /// Serialize the validated AST, substituting typed values rather than doing
  /// text replacement (which could change strings or variable declarations).
  static func inlineReaderDocument(_ built: GatewayBuiltDocument, catalog: GatewaySchemaCatalog) throws -> String {
    do {
      let parsed = try GatewayGraphQLParser.parse(built.document)
      let checked = try GatewayGraphQLValidator(catalog: catalog).validate(parsed, variables: built.variables)
      guard parsed.operationType == .query, checked.rootFields.count == 1 else { throw inlineFailure() }
      let types = Dictionary(uniqueKeysWithValues: parsed.variableDefinitions.map { ($0.name, $0.type) })
      let renderer = InlineReaderRenderer(variables: built.variables, types: types, catalog: catalog)
      let document = try "query { " + parsed.selectionSet.map { try renderer.selection($0, depth: 0) }.joined(separator: " ") + " }"
      guard document.utf8.count <= 120_000 else { throw inlineFailure() }
      _ = try GatewayGraphQLValidator(catalog: catalog).validate(GatewayGraphQLParser.parse(document))
      return document
    } catch {
      throw inlineFailure()
    }
  }
}

private func inlineFailure() -> AdapterExecutionError {
  .init(.policyBlocked, "gateway JSON request cannot be represented by the legacy reader document contract")
}

private struct InlineReaderRenderer {
  var variables: [String: GatewayJSONValue]
  var types: [String: GatewayTypeRef]
  var catalog: GatewaySchemaCatalog

  func selection(_ field: GatewayGraphQLDocument.Selection, depth: Int) throws -> String {
    guard depth < 64 else { throw inlineFailure() }
    let name = field.alias.map { $0 + ": " } ?? ""
    let args = try field.arguments.map { try $0.name + ": " + literal($0.value, depth: depth + 1) }.joined(separator: ", ")
    let children = try field.selectionSet.map { try selection($0, depth: depth + 1) }.joined(separator: " ")
    return name + field.name + (args.isEmpty ? "" : "(\(args))") + (children.isEmpty ? "" : " { \(children) }")
  }

  private func literal(_ value: GraphQLValue, depth: Int) throws -> String {
    guard depth < 64 else { throw inlineFailure() }
    switch value {
    case let .variable(name):
      guard let value = variables[name], let type = types[name] else { throw inlineFailure() }
      return try typed(value, type: type, depth: depth + 1)
    case let .enumValue(name): return name
    case let .string(text): return try GatewayJSONValue.string(text).jsonString()
    case let .int(number): return String(number)
    case let .float(number): return try GatewayJSONValue.double(number).jsonString()
    case let .bool(value): return value ? "true" : "false"
    case .null: return "null"
    case let .list(values): return try "[" + values.map { try literal($0, depth: depth + 1) }.joined(separator: ", ") + "]"
    case let .object(fields):
      return try "{" + fields.map { try $0.name + ": " + literal($0.value, depth: depth + 1) }.joined(separator: ", ") + "}"
    }
  }

  private func typed(_ value: GatewayJSONValue, type: GatewayTypeRef, depth: Int) throws -> String {
    guard depth < 64 else { throw inlineFailure() }
    if value == .null { return "null" }
    switch type {
    case let .nonNull(inner): return try typed(value, type: inner, depth: depth + 1)
    case let .list(inner):
      let values: [GatewayJSONValue]
      if case let .array(items) = value { values = items } else { values = [value] }
      return try "[" + values.map { try typed($0, type: inner, depth: depth + 1) }.joined(separator: ", ") + "]"
    case let .named(name):
      let definition = catalog.namedType(name)
      if let allowed = definition?.enumValues {
        guard case let .string(text) = value, allowed.contains(text) else { throw inlineFailure() }
        return text
      }
      if case let .object(fields) = value {
        let inputs = definition?.inputFields ?? []
        return try "{" + fields.keys.sorted().map { key in
          guard key.range(of: #"^[_A-Za-z][_0-9A-Za-z]*$"#, options: .regularExpression) != nil else { throw inlineFailure() }
          let fieldType = inputs.first { $0.name == key }?.type ?? .named("JSON")
          return try key + ": " + typed(fields[key]!, type: fieldType, depth: depth + 1)
        }.joined(separator: ", ") + "}"
      }
      if case let .array(values) = value {
        return try "[" + values.map { try typed($0, type: .named("JSON"), depth: depth + 1) }.joined(separator: ", ") + "]"
      }
      return try value.jsonString()
    }
  }
}
