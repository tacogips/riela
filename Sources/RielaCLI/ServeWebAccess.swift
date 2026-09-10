import Foundation
import RielaServer

/// Browser operator credentials are independent of scoped manager credentials.
enum ServeWebAccess {
  static let tokenEnvironmentName = "RIELA_WEB_TOKEN"
  static let originEnvironmentName = "RIELA_WEB_ORIGIN"

  case local
  case authenticated(token: String, origin: String, authority: String)
  case unavailable

  init(host: String, environment: [String: String]) {
    let token = environment[Self.tokenEnvironmentName]
    let origin = environment[Self.originEnvironmentName]
    if token == nil, origin == nil, ["127.0.0.1", "::1", "localhost"].contains(host) {
      self = .local
      return
    }
    guard let token, !token.isEmpty,
          token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
          let origin, let components = URLComponents(string: origin),
          ["http", "https"].contains(components.scheme),
          components.host?.isEmpty == false,
          components.user == nil, components.password == nil,
          components.path.isEmpty, components.query == nil, components.fragment == nil,
          let scheme = components.scheme,
          origin.hasPrefix("\(scheme)://") else {
      self = .unavailable
      return
    }
    self = .authenticated(token: token, origin: origin, authority: String(origin.dropFirst(scheme.count + 3)))
  }

  func rejection(for request: RielaHTTPRequest, localAuthority: String, csrfToken: String) -> RielaHTTPResponse? {
    switch self {
    case .local:
      return RielaWebRequestSecurity(authority: localAuthority, csrfToken: csrfToken).rejection(for: request)
    case let .authenticated(token, origin, authority):
      guard let header = request.headers["authorization"], header.hasPrefix("Bearer "),
            Self.matches(String(header.dropFirst(7)), token) else {
        return .json(status: 401, .object(["error": .object([
          "code": .string("web_authentication_required"),
          "message": .string("Enter the server access token to connect.")
        ])]))
      }
      return RielaWebRequestSecurity(authority: authority, csrfToken: csrfToken, origin: origin).rejection(for: request)
    case .unavailable:
      return .json(status: 503, .object(["error": .object([
        "code": .string("web_access_not_configured"),
        "message": .string("Set RIELA_WEB_TOKEN and RIELA_WEB_ORIGIN on the server to enable browser access.")
      ])]))
    }
  }

  private static func matches(_ supplied: String, _ expected: String) -> Bool {
    let lhs = Array(supplied.utf8)
    let rhs = Array(expected.utf8)
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
