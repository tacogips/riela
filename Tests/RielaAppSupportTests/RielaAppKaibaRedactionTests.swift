#if os(macOS)
import Foundation
import XCTest
@testable import RielaAppSupport
@testable import RielaKaibaSupport

final class RielaAppKaibaRedactionTests: XCTestCase {
  func testAppSupportCatalogStateContainsOnlyBearerEnvironmentReference() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = "kaiba-redaction-sentinel-token"
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = RielaAppKaibaInstanceController(homeURL: root, bindingScanRoots: roots)
    _ = try controller.add(.init(
      name: "Remote",
      endpoint: "https://kaiba.example.test",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN")
    ))

    XCTAssertFalse(String(reflecting: try controller.list()).contains(token))
    XCTAssertFalse(try String(contentsOf: controller.store.fileURL).contains(token))
  }
}
#endif
