import Foundation
import XCTest
import RielaCore
import RielaSQLite
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

  func testReadOnlySnapshotsAndUnremovableWarning() async throws {
    let home = try makeHome()
    let manager = FileManager.default
    let parent = home.appendingPathComponent(".riela/workflow-history/one/snapshots")
    let blocked = parent.appendingPathComponent("blocked")
    let removable = home.appendingPathComponent(".riela/workflow-history/two/snapshots/read-only")
    for path in [blocked, removable] {
      try manager.createDirectory(at: path, withIntermediateDirectories: true)
      try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: path.path)
      try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path.path)
    }
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer {
      try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
      try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
    }
    let result = await run(home: home, args: ["gc", "--scope", "user", "--results-max-age-days", "1", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains(#""status":"completed""#), result.stdout)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
    XCTAssertTrue((targets.first?["warnings"] as? [String])?.contains(where: { $0.contains(blocked.path) }) == true, result.stdout)
    XCTAssertFalse(manager.fileExists(atPath: removable.path))
  }

  func testMissingPolicyPrunesAgedLogsButPreservesGeneratedReceipts() async throws {
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
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/logs/old.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/events/receipts/old.json").path))
  }

  func testDefaultDryRunReportsSourcesAndText() async throws {
    let home = try makeHome()
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".riela"), withIntermediateDirectories: true)
    let json = await run(home: home, args: ["gc", "--scope", "user", "--dry-run", "--output", "json"])
    XCTAssertEqual(json.exitCode, .success, json.stderr)
    XCTAssertTrue(json.stdout.contains(#""maxAgeDays":30"#), json.stdout)
    XCTAssertTrue(json.stdout.contains(#""policySource":"default""#), json.stdout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/retention").path))
    let overridden = await run(home: home, args: ["gc", "--scope", "user", "--dry-run", "--output", "json", "--results-max-age-days", "5"])
    XCTAssertTrue(overridden.stdout.contains(#""policySource":"override""#), overridden.stdout)
    let text = await run(home: home, args: ["gc", "--scope", "user", "--dry-run"])
    XCTAssertTrue(text.stdout.contains("(built-in default)"), text.stdout)
    XCTAssertFalse(text.stdout.contains("no cap"), text.stdout)
  }

  func testDefaultGCDryRunAndApplyOldFamily() async throws {
    let home = try makeHome().resolvingSymlinksInPath()
    let root = home.appendingPathComponent(".riela/sessions", isDirectory: true)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    let database = try SQLiteDatabase.open(path: path)
    try database.execute("""
      CREATE TABLE workflow_runtime_snapshots(workflow_execution_id TEXT PRIMARY KEY, workflow_id TEXT,
        session_status TEXT, parent_session_id TEXT, root_session_id TEXT, updated_at TEXT, session_json BLOB,
        root_output_json BLOB, diagnostics_json BLOB, loop_evidence_json BLOB, loop_summary_json BLOB)
      """)
    try database.execute("CREATE TABLE workflow_messages(workflow_execution_id TEXT,payload_json BLOB,artifact_refs_json BLOB)")
    try database.execute("""
      INSERT INTO workflow_runtime_snapshots VALUES('old', 'sample', 'completed', NULL, 'old',
        '1970-01-01T00:16:40Z', jsonb('{}'), jsonb('{}'), jsonb('[]'), NULL, NULL)
      """)
    try database.execute("INSERT INTO workflow_messages VALUES('old', jsonb('{}'), jsonb('[]'))")

    let preview = await run(home: home, args: ["gc", "--scope", "user", "--dry-run", "--output", "json"])
    XCTAssertEqual(preview.exitCode, .success, preview.stderr)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.stdout.utf8)) as? [String: Any])
    let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
    let results = try XCTUnwrap(targets.first?["results"] as? [String: Any])
    XCTAssertEqual(results["selectedCount"] as? Int, 1)
    XCTAssertEqual(results["policySource"] as? String, "default")
    XCTAssertEqual((results["policy"] as? [String: Any])?["maxAgeDays"] as? Int, 30)
    XCTAssertFalse(try database.tableExists("session_retention_tombstones"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".riela/retention").path))
    XCTAssertEqual(try database.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
    XCTAssertEqual(try database.query("SELECT * FROM workflow_messages").count, 1)

    let applied = await run(home: home, args: ["gc", "--scope", "user", "--output", "json"])
    XCTAssertEqual(applied.exitCode, .success, applied.stderr + applied.stdout)
    XCTAssertTrue(try database.query("SELECT * FROM workflow_runtime_snapshots").isEmpty)
    XCTAssertTrue(try database.query("SELECT * FROM workflow_messages").isEmpty)
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
    let home = try makeHome()
    let result = await run(home: home, args: ["gc", "--help"])
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
    let process = ProcessInfo.processInfo.environment
    var environment = ["HOME": home.path]
    for key in ["PATH", "TMPDIR"] {
      if let value = process[key] { environment[key] = value }
    }
    let isolation = RielaCLIIsolatedEnvironment(root: home, home: home, project: home, environment: environment)
    return await isolation.run { await RielaCLIApplication().run(args, environment: environment) }
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
