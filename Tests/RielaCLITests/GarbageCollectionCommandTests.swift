import Foundation
import XCTest
@testable import RielaCLI

final class GarbageCollectionCommandTests: XCTestCase {
  func testManualGarbageCollectionUsesTypedArguments() async throws {
    let home = try makeRoot()
    let log = home.appendingPathComponent(".riela/logs/old-run.jsonl")
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("test".utf8).write(to: log)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: log.path
    )

    let result = await RielaCLIApplication().run(
      ["gc", "--retention-days", "1", "--scope", "user", "--output", "json"],
      environment: ["HOME": home.path]
    )

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    // Runtime logs are retained by gc; scoped session prune owns payload retention.
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    XCTAssertTrue(result.stdout.contains("logs preserved"), result.stdout)
    XCTAssertTrue(result.stdout.contains(#""enabled":true"#), result.stdout)
  }

  func testManualGarbageCollectionRemovesAgedEventReceiptsAndKeepsRecentOnes() async throws {
    let home = try makeRoot()
    let receipts = home.appendingPathComponent(".riela/events/receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let aged = receipts.appendingPathComponent("event-cron-aged.json")
    let recent = receipts.appendingPathComponent("event-cron-recent.json")
    try Data("{}".utf8).write(to: aged)
    try Data("{}".utf8).write(to: recent)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: aged.path
    )

    let result = await RielaCLIApplication().run(
      ["gc", "--retention-days", "1", "--scope", "user", "--output", "json"],
      environment: ["HOME": home.path]
    )

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: aged.path), result.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), result.stdout)
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
