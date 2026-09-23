import Foundation
import XCTest
@testable import RielaCLI

final class KaibaInstanceCommandRedactionTests: XCTestCase {
  func testBearerValueIsAbsentFromAddAndListOutput() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let token = "kaiba-redaction-sentinel-token"
    let app = RielaCLIApplication()
    let added = await app.run(
      [
        "kaiba", "instance", "add", "Remote", "--endpoint", "https://kaiba.example.test",
        "--api-key-env", "KAIBA_TOKEN", "--output", "json"
      ],
      environment: ["HOME": home.path, "KAIBA_TOKEN": token]
    )
    XCTAssertEqual(added.exitCode, .success, added.stderr)
    let listed = await app.run(
      ["kaiba", "instance", "list", "--output", "json"],
      environment: ["HOME": home.path, "KAIBA_TOKEN": token]
    )

    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    XCTAssertFalse(added.stdout.contains(token))
    XCTAssertFalse(added.stderr.contains(token))
    XCTAssertFalse(listed.stdout.contains(token))
    XCTAssertFalse(listed.stderr.contains(token))
  }
}
