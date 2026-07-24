#if os(macOS)
import Foundation
import RielaCore
import RielaServer

final class RielaAppWebRouter: RielaHTTPRouteHandling, @unchecked Sendable {
  private weak var app: RielaApp?
  private let assetResolver: RielaStaticAssetResolver
  private let deterministicAdapter: DeterministicServerHTTPAdapter
  private let lock = NSLock()
  private var configuredPort: Int
  let csrfToken: String

  init(app: RielaApp, assetRoot: URL, configuredPort: Int) {
    self.app = app
    assetResolver = RielaStaticAssetResolver(rootURL: assetRoot)
    deterministicAdapter = DeterministicServerHTTPAdapter(
      context: ServerRequestContext(serviceName: "riela-app")
    )
    self.configuredPort = configuredPort
    csrfToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  func updateConfiguredPort(_ port: Int) {
    lock.lock()
    configuredPort = port
    lock.unlock()
  }

  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    if request.path.hasPrefix("/api/v1") {
      if let rejection = securityRejection(for: request) {
        return rejection
      }
      guard let app else {
        return .json(status: 503, .object(["error": .string("RielaApp is unavailable")]))
      }
      return await app.webAPIResponse(for: request, csrfToken: csrfToken)
    }
    if request.path == "/" || isFrontendNavigation(request.path),
       let response = assetResolver.response(for: request) {
      return response
    }
    if request.path == "/graphql", let rejection = securityRejection(for: request) {
      return rejection
    }
    let deterministic = await deterministicAdapter.response(for: request)
    if deterministic.status != 404 {
      return deterministic
    }
    return assetResolver.response(for: request) ?? deterministic
  }

  private func securityRejection(for request: RielaHTTPRequest) -> RielaHTTPResponse? {
    let expectedHost: String
    lock.lock()
    expectedHost = "127.0.0.1:\(configuredPort)"
    lock.unlock()
    guard request.headers["host"] == expectedHost else {
      return .json(status: 403, .object(["error": .string("invalid_host")]))
    }
    guard request.method == "POST" || request.method == "PUT" || request.method == "DELETE" else {
      return nil
    }
    guard request.headers["origin"] == "http://\(expectedHost)" else {
      return .json(status: 403, .object(["error": .string("invalid_origin")]))
    }
    guard request.headers["x-riela-csrf"] == csrfToken else {
      return .json(status: 403, .object(["error": .string("invalid_csrf")]))
    }
    guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
      return .json(status: 415, .object(["error": .string("json_content_type_required")]))
    }
    return nil
  }

  private func isFrontendNavigation(_ path: String) -> Bool {
    guard !path.hasPrefix("/api/"), !path.hasPrefix("/note/") else {
      return false
    }
    return !path.split(separator: "/").last.map { $0.contains(".") }!
  }
}
#endif
