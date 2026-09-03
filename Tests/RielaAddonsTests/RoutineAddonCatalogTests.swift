import XCTest
@testable import RielaAddons

final class RoutineAddonCatalogTests: XCTestCase {
  func testRoutineAddonsAreCataloged() {
    let expected = [
      "riela/routine-create",
      "riela/routine-complete",
      "riela/routine-get",
      "riela/routine-list",
      "riela/routine-update-status",
      "riela/routine-delete"
    ]
    XCTAssertEqual(RielaBuiltinAddonCatalog.routineAddons.map(\.name), expected)
    for name in expected {
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: "1"), name)
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: nil), name)
      XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: name, version: "2"), name)
    }
  }
}
