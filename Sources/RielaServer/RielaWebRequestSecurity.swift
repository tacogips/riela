import Foundation
import RielaCore

/// Same-origin boundary for browser APIs that carry local process authority.
/// Native inherited-pipe requests do not pass through this HTTP policy.
public struct RielaWebRequestSecurity: Sendable {
  public let authority: String
  public let csrfToken: String
  public let origin: String

  public init(authority: String, csrfToken: String, origin: String? = nil) {
    self.authority = authority
    self.csrfToken = csrfToken
    self.origin = origin ?? "http://\(authority)"
  }

  public func rejection(for request: RielaHTTPRequest) -> RielaHTTPResponse? {
    guard request.headers["host"] == authority else {
      return rejected("invalid_host")
    }
    guard request.method != "GET" && request.method != "HEAD" else { return nil }
    guard request.headers["origin"] == origin else {
      return rejected("invalid_origin")
    }
    guard request.headers["x-riela-csrf"] == csrfToken else {
      return rejected("invalid_csrf")
    }
    guard request.headers["content-type"]?.lowercased().split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces) == "application/json" else {
      return rejected("json_content_type_required", status: 415)
    }
    return nil
  }

  private func rejected(_ code: String, status: Int = 403) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .string(code)]))
  }
}
