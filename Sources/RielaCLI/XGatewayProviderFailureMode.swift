import RielaAddonSupport
import RielaCore

enum XGatewayProviderFailureMode: String, Equatable, Sendable {
  case fail
  case output

  static func parse(_ config: JSONObject) throws -> XGatewayProviderFailureMode {
    guard let value = config["providerFailure"] else { return .fail }
    guard case let .string(rawValue) = value, let mode = XGatewayProviderFailureMode(rawValue: rawValue) else {
      throw AdapterExecutionError(.policyBlocked, "config.providerFailure must be \"fail\" or \"output\"")
    }
    return mode
  }
}
