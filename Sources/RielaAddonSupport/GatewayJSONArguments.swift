import Foundation
import RielaCore

/// Shared bounded argument rendering. Substituted source strings are data;
/// callers must not template the returned object a second time.
public func renderGatewayJSONArguments(
  _ raw: JSONValue?, variables: JSONObject, addonName: String, alreadyRendered: Bool = false
) throws -> JSONObject {
  guard case let .object(arguments) = raw ?? .object([:]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
  }
  let rendered = try alreadyRendered ? JSONValue.object(arguments) : renderAddonConfig(.object(arguments), variables: variables)
  let encoded = try JSONEncoder().encode(rendered)
  guard encoded.count <= 8 * 1_024 * 1_024, case let .object(values) = rendered else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments exceed the JSON size limit")
  }
  return values
}
