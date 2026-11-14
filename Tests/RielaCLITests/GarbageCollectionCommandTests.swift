import Foundation
import XCTest
@testable import RielaCLI

final class GarbageCollectionCommandTests: XCTestCase {
  func testManualGarbageCollectionUsesTypedArguments() async throws {
    let home = try makeRoot()
    let session = home.appendingPathComponent(".riela/sessions/old-session.json")
    try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("test".utf8).write(to: session)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: session.path
    )

    let result = await RielaCLIApplication().run(
      ["gc", "--retention-days", "1", "--scope", "user", "--output", "json"],
      environment: ["HOME": home.path]
    )

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    XCTAssertTrue(result.stdout.contains(#""enabled":true"#), result.stdout)
  }

  func testManualGarbageCollectionDefaultsToOff() async throws {
    let home = try makeRoot()

    let result = await RielaCLIApplication().run(
      ["gc", "--scope", "user", "--output", "json"],
      environment: ["HOME": home.path]
    )

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains(#""enabled":false"#), result.stdout)
  }

  func testGarbageCollectionHelpComesFromArgumentParser() async {
    let result = await RielaCLIApplication().run(["gc", "--help"])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("--retention-days"), result.stdout)
    XCTAssertTrue(result.stdout.contains("--dry-run"), result.stdout)
  }

  private var roots: [URL] = []

  override func tearDown() {
    for root in roots.reversed() {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-gc-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
}
