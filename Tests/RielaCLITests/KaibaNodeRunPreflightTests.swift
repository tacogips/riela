import Foundation
import XCTest
@testable import RielaCLI

final class KaibaNodeRunPreflightTests: XCTestCase {
  func testDirectKaibaNodeFailsClosedBeforeBusinessExecutionWithoutDefaultInstance() async throws {
    let home = try makeRielaCLITestTemporaryDirectory("kaiba-node-preflight")
    defer { try? FileManager.default.removeItem(at: home) }

    let result = await RielaCLIApplication().run([
      "node", "run", "kaiba/note-search", "--output", "json"
    ], environment: ["HOME": home.path])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("missing_kaiba_instance"), result.stdout)
  }
}
