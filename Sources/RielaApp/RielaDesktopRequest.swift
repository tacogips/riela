#if os(macOS)
import Foundation
import RielaServer

struct RielaDesktopRequest: Decodable {
  let method: String
  let path: String
  let headers: [String: String]
  let body: String

  var apiRequest: RielaHTTPRequest? {
    guard let components = URLComponents(string: path),
          components.scheme == nil, components.host == nil,
          components.fragment == nil,
          components.path.hasPrefix("/api/v1/") || components.path == "/graphql",
          ["GET", "POST", "PUT", "DELETE", "HEAD"].contains(method),
          body.utf8.count <= 8 * 1024 * 1024 else { return nil }
    return RielaHTTPRequest(
      method: method,
      path: components.path,
      percentEncodedPath: components.percentEncodedPath,
      query: components.percentEncodedQuery,
      headers: headers,
      body: Data(body.utf8)
    )
  }
}

extension RielaApp {
  /// Only the inherited desktop pipe enters here. HTTP origin/CSRF validation
  /// stays in RielaAppWebRouter; profile/revision checks remain in shared handlers.
  func desktopAPIResponse(for request: RielaDesktopRequest, csrfToken: String) async -> RielaHTTPResponse {
    guard let apiRequest = request.apiRequest else {
      return .text(status: 400, "Invalid desktop API request")
    }
    if apiRequest.path == "/graphql" {
      return await webGraphQLResponse(for: apiRequest)
    }
    return await webAPIResponse(for: apiRequest, csrfToken: csrfToken)
  }
}
#endif
