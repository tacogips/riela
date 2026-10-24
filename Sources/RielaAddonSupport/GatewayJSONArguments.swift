import Foundation
import RielaCore

/// Shared JSON size bound for gateway request arguments and finite JSON
/// transforms (postprocess and `riela/json-transform`): 8 MiB of encoded JSON.
public enum GatewayJSONLimits {
  public static let maximumEncodedBytes = 8 * 1_024 * 1_024
}

/// Shared bounded argument rendering. Substituted source strings are data;
/// callers must not template the returned object a second time. A missing
/// `arguments` value is an empty object; any other non-object is rejected.
public func renderGatewayJSONArguments(
  _ raw: JSONValue?, variables: JSONObject, addonName: String, alreadyRendered: Bool = false
) throws -> JSONObject {
  guard case let .object(arguments) = raw ?? .object([:]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
  }
  let rendered = try alreadyRendered ? JSONValue.object(arguments) : renderAddonConfig(.object(arguments), variables: variables)
  // A non-finite number cannot be encoded; report it like any other invalid argument.
  guard let encoded = try? JSONEncoder().encode(rendered) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments are not valid JSON")
  }
  guard encoded.count <= GatewayJSONLimits.maximumEncodedBytes, case let .object(values) = rendered else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments exceed the JSON size limit")
  }
  return values
}
