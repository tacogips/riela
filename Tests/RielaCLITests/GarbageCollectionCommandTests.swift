import Foundation
import XCTest
@testable import RielaCLI

final class GarbageCollectionCommandTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDown() {
    roots.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
    roots = []
    super.tearDown()
  }

  func testResultsAgeStillCollectsOnlyAgedEventReceipts() async throws {
    let home = try makeHome()
    let receipts = home.appendingPathComponent(".riela/events/receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let aged = receipts.appendingPathComponent("event-cron-aged.json")
    let recent = receipts.appendingPathComponent("event-cron-recent.json")
    try Data("{}".utf8).write(to: aged)
    try Data("{}".utf8).write(to: recent)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: aged.path
    )
    let result = await run(home: home, args: ["gc", "--scope", "user", "--results-max-age-days", "1", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: aged.path), result.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), result.stdout)
  }

  func testMissingPolicyPreservesAgedLogsAndReceipts() async throws {
    let home = try makeHome()
    for relative in ["logs/old.jsonl", "events/receipts/old.json"] {
      let file = home.appendingPathComponent(".riela/" + relative)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path
      )
    }
    let result = await run(home: home, args: ["gc", "--scope", "user", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/logs/old.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/events/receipts/old.json").path))
  }

  func testDryRunJSONReportsCategoriesWithoutChangingLog() async throws {
    let (home, log) = try makeConfiguredHome(policy: #"{"logs":{"maxAgeDays":14,"maxTotalBytes":1}}"#)
    let before = try FileManager.default.attributesOfItem(atPath: log.path)
    let result = await run(home: home, args: ["gc", "--scope", "user", "--dry-run", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains(#""selectedCount":1"#), result.stdout)
    XCTAssertTrue(result.stdout.contains(#""capAchieved""#), result.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: log.path))[.size] as? NSNumber,
      before[.size] as? NSNumber)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/retention").path))
  }

  func testResultsMaxAgePolicyCompletesWithoutInformationalFailure() async throws {
    let (home, _) = try makeConfiguredHome(policy: #"{"results":{"maxAgeDays":30}}"#)
    let result = await run(home: home, args: ["gc", "--scope", "user", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    XCTAssertTrue(result.stdout.contains(#""status":"completed""#), result.stdout)
    XCTAssertFalse(result.stdout.contains(#""status":"failed""#), result.stdout)
  }

  func testRemovedRetentionDaysFlagIsRejected() async throws {
    let home = try makeHome()
    let result = await run(home: home, args: ["gc", "--retention-days", "1"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("--retention-days"), result.stderr)
  }

  func testKeepForeverOverrideIsUsageError() async throws {
    let (home, _) = try makeConfiguredHome(policy: #"{"results":{"keepForever":true}}"#)
    let result = await run(home: home, args: ["gc", "--scope", "user", "--results-max-age-days", "1"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("keepForever"), result.stderr)
  }

  func testRemovedConfigurationKeyIsUsageError() async throws {
    let home = try makeHome()
    try writeConfig(home: home, json: #"{"gc":{"retentionDays":30}}"#)
    let result = await run(home: home, args: ["gc", "--scope", "user"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("gc.retentionDays was removed"), result.stderr)
  }

  func testHelpListsNewFlagsAndOmitsRemovedFlag() async throws {
    let result = await RielaCLIApplication().run(["gc", "--help"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("--results-max-age-days"), result.stdout)
    XCTAssertTrue(result.stdout.contains("--logs-max-total-bytes"), result.stdout)
    XCTAssertFalse(result.stdout.contains("--retention-days"), result.stdout)
  }

  func testTextOutputIncludesCategoryLines() async throws {
    let (home, _) = try makeConfiguredHome(policy: #"{"logs":{"maxAgeDays":14}}"#)
    let result = await run(home: home, args: ["gc", "--scope", "user"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("results:"), result.stdout)
    XCTAssertTrue(result.stdout.contains("logs:"), result.stdout)
  }

  func testByteSizeOverrideAcceptsHumanUnits() async throws {
    let home = try makeHome()
    let result = await run(home: home, args: ["gc", "--scope", "user", "--logs-max-total-bytes", "1GB", "--dry-run"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
  }

  func testUnknownOutputFormatIsUsageError() async throws {
    let home = try makeHome()
    let result = await run(home: home, args: ["gc", "--scope", "user", "--output", "xml"])
    XCTAssertEqual(result.exitCode, .usage)

    let jsonlResult = await run(home: home, args: ["gc", "--scope", "user", "--output", "jsonl"])
    XCTAssertEqual(jsonlResult.exitCode, .usage)
  }

  private func run(home: URL, args: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(args, environment: ["HOME": home.path])
  }

  private func makeConfiguredHome(policy: String) throws -> (URL, URL) {
    let home = try makeHome()
    let logs = home.appendingPathComponent(".riela/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("expired.jsonl")
    try Data("expired".utf8).write(to: log)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: log.path)
    try writeConfig(home: home, json: "{\"retention\":\(policy)}")
    return (home, log)
  }

  private func writeConfig(home: URL, json: String) throws {
    let directory = home.appendingPathComponent(".riela", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))
  }

  private func makeHome() throws -> URL {
    let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-gc-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    roots.append(home)
    return home
  }
}
