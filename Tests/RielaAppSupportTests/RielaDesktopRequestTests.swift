#if os(macOS)
import Foundation
@testable import RielaApp
import RielaAppSupport
import XCTest

@MainActor
final class RielaDesktopRequestTests: XCTestCase {
  func testDesktopBootstrapUsesLiveProfileWithoutCreatingHTTPServer() async throws {
    let app = RielaApp()
    app.daemonProfileName = RielaAppProfileName("desktop-test")
    let response = await app.desktopAPIResponse(
      for: RielaDesktopRequest(method: "GET", path: "/api/v1/bootstrap", headers: [:], body: ""),
      csrfToken: "desktop-only-token"
    )
    XCTAssertEqual(response.status, 200)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(object["profile"] as? String, "desktop-test")
    XCTAssertEqual(object["csrfToken"] as? String, "desktop-only-token")
    XCTAssertNil(app.webServerController)
  }

  func testNativeGraphQLStillRequiresCurrentProfile() async {
    let app = RielaApp()
    app.daemonProfileName = RielaAppProfileName("current")
    let response = await app.desktopAPIResponse(
      for: RielaDesktopRequest(
        method: "POST", path: "/graphql",
        headers: ["X-Riela-Profile": "stale", "Content-Type": "application/json"],
        body: "{\"query\":\"{ workflows { workflowId } }\"}"
      ),
      csrfToken: ""
    )
    XCTAssertEqual(response.status, 409)
  }

  func testEncodedIdentityIsDecodedExactlyOnce() throws {
    let request = try XCTUnwrap(RielaDesktopRequest(
      method: "GET", path: "/api/v1/instances/a%252Fb%2Fc?revision=2",
      headers: ["X-Riela-Profile": "work"], body: ""
    ).apiRequest)
    XCTAssertEqual(request.path, "/api/v1/instances/a%2Fb/c")
    XCTAssertEqual(request.percentEncodedPath, "/api/v1/instances/a%252Fb%2Fc")
    XCTAssertEqual(request.query, "revision=2")
    XCTAssertEqual(request.headers["x-riela-profile"], "work")
  }

  func testRejectsExternalAndNonAPIRoutes() {
    for path in ["https://example.com/api/v1/bootstrap", "//example.com/graphql", "/etc/passwd", "/graphql#x"] {
      XCTAssertNil(RielaDesktopRequest(method: "GET", path: path, headers: [:], body: "").apiRequest)
    }
    XCTAssertNil(RielaDesktopRequest(method: "CONNECT", path: "/graphql", headers: [:], body: "").apiRequest)
  }
}
#endif
