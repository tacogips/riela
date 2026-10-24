import Foundation
import GatewaySDKKit
import RielaAddonSupport
import RielaCore

/// One typed request contract for linked gateway catalogs. Render inputs once;
/// source strings containing template syntax remain data in the SDK variables.
enum BuiltinGatewayJSONRequest {
  static func document(
    config: JSONObject,
    variables: JSONObject,
    catalog: GatewaySchemaCatalog,
    addonName: String,
    argumentsAlreadyRendered: Bool = false
  ) throws -> GatewayBuiltDocument {
    let request = try request(config: config, variables: variables, addonName: addonName, argumentsAlreadyRendered: argumentsAlreadyRendered)
    do {
      let built = try GatewayDocumentBuilder(catalog: catalog).build(request)
      let parsed = try GatewayGraphQLParser.parse(built.document)
      let validated = try GatewayGraphQLValidator(catalog: catalog).validate(parsed, variables: built.variables)
      guard validated.rootFields.count == 1,
            validated.rootFields.first?.name == request.operation else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) selection must address only the requested operation")
      }
      return built
    } catch {
      // Catalog errors can include argument values; avoid echoing source data.
      throw AdapterExecutionError(.policyBlocked, "\(addonName) JSON operation does not match its gateway tier catalog")
    }
  }

  static func request(
    config: JSONObject, variables: JSONObject, addonName: String, commandOperation: Bool = false, argumentsAlreadyRendered: Bool = false
  ) throws -> GatewayOperationRequest {
    let namePattern = commandOperation ? #"^[A-Za-z][A-Za-z0-9_-]*( [A-Za-z][A-Za-z0-9_-]*)*$"# : #"^[_A-Za-z][_0-9A-Za-z]*$"#
    guard let operation = nonEmptyString(config["operation"]), operation.utf8.count <= 256,
          operation.range(of: namePattern, options: .regularExpression) != nil,
          !operation.contains("{{"),
          config["queryTemplate"] == nil, config["variablesTemplate"] == nil,
          config["command"] == nil, config["argsTemplate"] == nil, config["select"] == nil else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) requires one literal operation without legacy query or command fields")
    }
    let rendered = try renderedArguments(config: config, variables: variables, addonName: addonName,
                                         alreadyRendered: argumentsAlreadyRendered)
    let values = try JSONDecoder().decode([String: GatewayJSONValue].self, from: JSONEncoder().encode(rendered))
    let selection: GatewaySelection
    switch config["selection"] {
    case nil:
      selection = .default
    case let .array(fields):
      selection = .fields(try fieldPaths(fields, addonName: addonName))
    case let .string(text):
      guard !text.isEmpty, text.utf8.count <= 65_536, !text.contains("{{") else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) selection must be a bounded literal selection set")
      }
      selection = .raw(text)
    default:
      throw AdapterExecutionError(.policyBlocked, "\(addonName) selection must be field paths or a literal selection set")
    }
    return GatewayOperationRequest(operation: operation, variables: values, selection: selection)
  }

  /// Shared literal field-path selection (`["posts.id", "pageInfo.nextToken"]`),
  /// used by catalog-backed gateways and the X SDL codec.
  static func fieldPaths(_ fields: [JSONValue], addonName: String) throws -> [String] {
    guard !fields.isEmpty, fields.count <= 256 else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) selection requires 1 to 256 field paths")
    }
    return try fields.map { value -> String in
      guard case let .string(path) = value, path.utf8.count <= 4_096,
            path.range(of: #"^[_A-Za-z][_0-9A-Za-z]*(\.[_A-Za-z][_0-9A-Za-z]*)*$"#, options: .regularExpression) != nil else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) selection requires literal field paths")
      }
      return path
    }
  }

  static func renderedArguments(
    config: JSONObject, variables: JSONObject, addonName: String, alreadyRendered: Bool = false
  ) throws -> JSONObject {
    try renderGatewayJSONArguments(config["arguments"], variables: variables, addonName: addonName, alreadyRendered: alreadyRendered)
  }

}
