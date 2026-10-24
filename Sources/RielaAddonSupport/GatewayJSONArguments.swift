import Foundation
import RielaCore

/// Shared bounded argument rendering. Substituted source strings are data;
/// callers must not template the returned object a second time.
public func renderGatewayJSONArguments(
  _ raw: JSONValue?, variables: JSONObject, addonName: String, alreadyRendered: Bool = false
) throws -> JSONObject {
  let value = raw ?? .object([:])
  let rendered = try alreadyRendered ? value : renderAddonConfig(value, variables: variables)
  guard case .object = rendered else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
  }
  let encoded = try JSONEncoder().encode(rendered)
  guard encoded.count <= 8 * 1_024 * 1_024, case let .object(values) = rendered else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments exceed the JSON size limit")
  }
  return values
}
