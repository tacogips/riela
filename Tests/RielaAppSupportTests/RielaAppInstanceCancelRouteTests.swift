import RielaAppSupport
import XCTest

final class RielaAppInstanceCancelRouteTests: XCTestCase {
  func testCancelRoutesAreDesktopOnlyAndPreserveExistingRoutes() {
    let paths = ["/api/v1/instances/{identity}/executions/{sessionId}/cancel", "/api/v1/instances/{identity}/cancel"]
    for path in paths {
      let matches = RielaWebAPIRouteTable.desktopOnly.filter { $0.path == path }
      XCTAssertEqual(matches.count, 1)
      XCTAssertEqual(matches.first?.method, "POST")
      XCTAssertFalse(RielaWebAPIRouteTable.sharedProjection.contains { $0.path == path })
      XCTAssertFalse(RielaWebAPIRouteTable.instanceWrites.contains { $0.path == path })
    }
    for suffix in ["reload", "runs"] {
      let matches = RielaWebAPIRouteTable.desktopOnly.filter { $0.path == "/api/v1/instances/{identity}/\(suffix)" }
      XCTAssertEqual(matches.count, 1)
      XCTAssertEqual(matches.first?.method, "POST")
    }
  }
}
