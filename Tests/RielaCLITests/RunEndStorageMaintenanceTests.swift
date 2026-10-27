import Foundation
import XCTest
import RielaSQLite
@testable import RielaCLI

final class RunEndStorageMaintenanceTests: XCTestCase {
  func testAutomaticHookVacuumRunsWithoutRetentionConfig() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("run-end-hook-no-config")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let store = root.appendingPathComponent("store", isDirectory: true)
    for directory in [home, project, store] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path)
    let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
    try db.execute("CREATE TABLE sample(value BLOB)")
    try db.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try db.execute("DELETE FROM sample")
    let before = Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0
    XCTAssertGreaterThan(before, 0)

    let commandResult = await RielaCLIApplication().run([
      "workflow", "run", "missing-workflow", "--working-dir", project.path, "--session-store", store.path
    ])
    let completion = RielaCLIMain.runEndMaintenance(
      result: commandResult,
      arguments: ["workflow", "run", "missing-workflow", "--working-dir", project.path, "--session-store", store.path],
      cancelled: false, environment: ["HOME": home.path])

    XCTAssertTrue(completion.warnings.isEmpty)
    XCTAssertEqual(completion.result.stdout, commandResult.stdout)
    XCTAssertEqual(completion.result.stderr, commandResult.stderr)
    XCTAssertEqual(completion.result.exitCode, commandResult.exitCode)
    XCTAssertLessThan(Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? before, before)
  }

  func testIncrementalStoreReclaimsFreelistAndNoneStoreIsIgnored() throws {
    let root = try makeRielaCLITestTemporaryDirectory("run-end-maintenance")
    defer { try? FileManager.default.removeItem(at: root) }
    let incrementalRoot = root.appendingPathComponent("incremental", isDirectory: true)
    try FileManager.default.createDirectory(at: incrementalRoot, withIntermediateDirectories: true)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: incrementalRoot.path)
    let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
    try db.execute("CREATE TABLE sample(value BLOB)")
    try db.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try db.execute("DELETE FROM sample")
    let before = Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0
    XCTAssertGreaterThan(before, 0)

    XCTAssertTrue(RunEndStorageMaintenance.run(sessionStoreRoots: [incrementalRoot.path]).isEmpty)

    let reopened = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertLessThan(Int(try reopened.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, before)
    let noneRoot = root.appendingPathComponent("none", isDirectory: true)
    try FileManager.default.createDirectory(at: noneRoot, withIntermediateDirectories: true)
    let nonePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: noneRoot.path)
    let none = try SQLiteDatabase.open(path: nonePath, options: .init(enableWAL: false, requireJSONB: false))
    try none.execute("CREATE TABLE sample(value TEXT)")
    XCTAssertTrue(RunEndStorageMaintenance.run(sessionStoreRoots: [noneRoot.path]).isEmpty)
  }

  func testRunEndMaintenanceSkipsBusyWriterPromptlyWithoutChangingFreelist() throws {
    let root = try makeRielaCLITestTemporaryDirectory("run-end-maintenance-busy")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let writer = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try writer.execute("PRAGMA auto_vacuum=INCREMENTAL")
    try writer.execute("CREATE TABLE sample(value BLOB)")
    try writer.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try writer.execute("DELETE FROM sample")
    let before = try XCTUnwrap(Int(try writer.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0"))
    let journalMode = try writer.query("PRAGMA journal_mode").first?["journal_mode"]
    try writer.execute("BEGIN IMMEDIATE")
    defer { try? writer.execute("ROLLBACK") }

    let start = Date()
    let warnings = RunEndStorageMaintenance.run(sessionStoreRoots: [root.path])
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertLessThan(elapsed, 1.0)
    XCTAssertTrue(warnings.isEmpty)
    XCTAssertEqual(try writer.query("PRAGMA freelist_count").first?["freelist_count"], String(before))
    XCTAssertEqual(try writer.query("PRAGMA journal_mode").first?["journal_mode"], journalMode)
  }
}
