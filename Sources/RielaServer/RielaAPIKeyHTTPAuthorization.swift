import Foundation

/// API keys authorize native clients, never browser sessions or key administration.
public enum RielaAPIKeyHTTPAuthorization {
  public static func bearerToken(in request: RielaHTTPRequest) -> String? {
    guard let value = request.headers["authorization"], value.hasPrefix("Bearer "),
          value.utf8.count <= 256 else { return nil }
    return String(value.dropFirst(7))
  }

  public static func rejection(for request: RielaHTTPRequest, store: RielaAPIKeyStore) -> RielaHTTPResponse? {
    guard request.method == "POST", request.headers["origin"] == nil,
          request.headers["x-riela-csrf"] == nil,
          request.headers["content-type"]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
      return failure(status: 403, code: "invalid_api_request")
    }
    do {
      let token = bearerToken(in: request)
      // Malformed credentials must not silently become anonymous access.
      guard request.headers["authorization"] == nil || token != nil,
            try store.authorizeClient(token: token) else {
        return failure(status: 401, code: "invalid_api_key")
      }
      return nil
    } catch {
      return failure(status: 503, code: "api_auth_unavailable")
    }
  }

  private static func failure(status: Int, code: String) -> RielaHTTPResponse {
    var response = RielaHTTPResponse.json(status: status, .object(["error": .string(code)]))
    response.headers["Cache-Control"] = "no-store"
    return response
  }
}
