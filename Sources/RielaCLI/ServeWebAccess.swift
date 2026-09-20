import Foundation
import RielaServer

/// Browser operator credentials are independent of scoped manager credentials.
enum ServeWebAccess {
  case local
  case passkey(RielaPasskeyConfiguration)
  case unavailable

  init(host: String, environment: [String: String]) {
    let token = environment["RIELA_WEB_TOKEN"]
    let origin = environment[RielaPasskeyConfiguration.originEnvironmentKey]
    if token == nil, origin == nil, ["127.0.0.1", "::1", "localhost"].contains(host) {
      self = .local
      return
    }
    guard let origin, let configuration = try? RielaPasskeyConfiguration(origin: origin) else {
      self = .unavailable
      return
    }
    self = .passkey(configuration)
  }

  func rejection(for request: RielaHTTPRequest, localAuthority: String, csrfToken: String, authenticated: Bool = false) -> RielaHTTPResponse? {
    switch self {
    case .local:
      return RielaWebRequestSecurity(authority: localAuthority, csrfToken: csrfToken).rejection(for: request)
    case let .passkey(configuration):
      guard authenticated else {
        return .json(status: 401, .object(["error": .object([
          "code": .string("web_authentication_required"),
          "message": .string("Sign in with your Passkey to connect.")
        ])]))
      }
      return RielaWebRequestSecurity(authority: configuration.authority, csrfToken: csrfToken, origin: configuration.origin).rejection(for: request)
    case .unavailable:
      return .json(status: 503, .object(["error": .object([
        "code": .string("web_access_not_configured"),
        "message": .string("Set RIELA_WEB_ORIGIN to the public HTTPS origin and register a Passkey using `riela auth invite <user>`.")
      ])]))
    }
  }

}
