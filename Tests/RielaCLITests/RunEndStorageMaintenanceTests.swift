import Foundation
import XCTest
import RielaCore
import RielaSQLite
@testable import RielaCLI

final class RunEndStorageMaintenanceTests: XCTestCase {
  func testAutomaticHookRunsMaintenanceWithoutRetentionConfig() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("run-end-hook-no-config")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let store = root.appendingPathComponent("store", isDirectory: true)
    for directory in [home, project, store] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var environment = ["HOME": home.path]
    for key in ["PATH", "TMPDIR"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
    }
    let isolation = RielaCLIIsolatedEnvironment(root: root, home: home, project: project, environment: environment)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))
    let session = WorkflowSession(workflowId: "flow", sessionId: "seed", status: .completed,
      entryStepId: "start", createdAt: Date(), updatedAt: Date())
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path)
    let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
    try db.execute("CREATE TABLE sample(value BLOB)")
    try db.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try db.execute("DELETE FROM sample")
    let before = Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0
    XCTAssertGreaterThan(before, 0)

    let sizeBefore = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
    let commandResult = await isolation.run { await RielaCLIApplication().run([
      "workflow", "run", "missing-workflow", "--working-dir", project.path, "--session-store", store.path
    ]) }
    let completion = isolation.run { RielaCLIMain.runEndMaintenance(
      result: commandResult,
      arguments: ["workflow", "run", "missing-workflow", "--working-dir", project.path, "--session-store", store.path],
      cancelled: false, environment: environment) }

    XCTAssertTrue(completion.warnings.isEmpty)
    XCTAssertEqual(completion.result.stdout, commandResult.stdout)
    XCTAssertEqual(completion.result.stderr, commandResult.stderr)
    XCTAssertEqual(completion.result.exitCode, commandResult.exitCode)
    XCTAssertLessThan(Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, before)
    XCTAssertLessThan(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0, sizeBefore)
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

    XCTAssertTrue(RunEndStorageMaintenance.run(targets: [target(incrementalRoot)], profile: .runEnd).isEmpty)

    let reopened = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertLessThan(Int(try reopened.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, before)
    let noneRoot = root.appendingPathComponent("none", isDirectory: true)
    try FileManager.default.createDirectory(at: noneRoot, withIntermediateDirectories: true)
    let nonePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: noneRoot.path)
    let none = try SQLiteDatabase.open(path: nonePath, options: .init(enableWAL: false, requireJSONB: false))
    try none.execute("CREATE TABLE sample(value BLOB)")
    try none.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try none.execute("DELETE FROM sample")
    let noneBefore = try none.query("PRAGMA freelist_count").first?["freelist_count"]
    XCTAssertGreaterThan(Int(noneBefore ?? "0") ?? 0, 128)
    XCTAssertTrue(RunEndStorageMaintenance.run(targets: [target(noneRoot)], profile: .runEnd).isEmpty)
    XCTAssertEqual(try none.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")
    XCTAssertEqual(try none.query("PRAGMA freelist_count").first?["freelist_count"], noneBefore)
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
    let warnings = RunEndStorageMaintenance.run(targets: [target(root)], profile: .runEnd)
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertLessThan(elapsed, 1.0)
    XCTAssertTrue(warnings.isEmpty)
    XCTAssertEqual(try writer.query("PRAGMA freelist_count").first?["freelist_count"], String(before))
    XCTAssertEqual(try writer.query("PRAGMA journal_mode").first?["journal_mode"], journalMode)
  }
  func testProfileCapsAndHeldAutomaticLock() throws {
    let root = try makeRielaCLITestTemporaryDirectory("maintenance-caps")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
    try db.execute("CREATE TABLE sample(value BLOB)")
    try db.execute("INSERT INTO sample VALUES(zeroblob(24000000))")
    try db.execute("DELETE FROM sample")
    let before = try XCTUnwrap(Int(db.query("PRAGMA freelist_count").first?["freelist_count"] ?? ""))
    XCTAssertGreaterThan(before, 4096)
    let selected = target(root)
    do {
      let lock = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: selected.stateDirectory))
      XCTAssertTrue(RunEndStorageMaintenance.run(targets: [selected], profile: .runEnd).isEmpty)
      XCTAssertEqual(try db.query("PRAGMA freelist_count").first?["freelist_count"], String(before))
      withExtendedLifetime(lock) {}
    }
    XCTAssertTrue(RunEndStorageMaintenance.run(targets: [selected], profile: .runEnd).isEmpty)
    let remaining = try XCTUnwrap(Int(db.query("PRAGMA freelist_count").first?["freelist_count"] ?? ""))
    XCTAssertEqual(before - remaining, 4096)
    XCTAssertTrue(RunEndStorageMaintenance.run(targets: [selected], profile: .scheduled).isEmpty)
    XCTAssertEqual(try db.query("PRAGMA freelist_count").first?["freelist_count"], "0")
  }

  func testRunEndConvertsLegacyAndHonorsAutomaticDisable() throws {
    let root = try makeRielaCLITestTemporaryDirectory("run-end-legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    let store = root.appendingPathComponent("store")
    for directory in [home, project, store] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var environment = ["HOME": home.path]
    for key in ["PATH", "TMPDIR"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
    }
    let isolation = RielaCLIIsolatedEnvironment(root: root, home: home, project: project, environment: environment)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))
    let session = WorkflowSession(workflowId: "flow", sessionId: "legacy", status: .completed,
      entryStepId: "start", createdAt: Date(), updatedAt: Date())
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path)
    let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
    try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(session.sessionId)])
    try db.execute("CREATE TABLE sample(value BLOB)")
    try db.execute("INSERT INTO sample VALUES(zeroblob(4194304))")
    try db.execute("DELETE FROM sample")
    let before = try db.query("PRAGMA freelist_count").first?["freelist_count"]
    XCTAssertGreaterThan(Int(before ?? "0") ?? 0, 128)
    let arguments = ["session", "resume", "legacy", "--session-store", store.path]
    do {
      let lock = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: store.appendingPathComponent("retention").path))
      XCTAssertTrue(isolation.run { AutomaticRetentionHook.runIfApplicable(arguments: arguments, exitCode: .success,
        cancelled: false, environment: isolation.environment, currentDirectory: project.path) }.isEmpty)
      XCTAssertEqual(try db.query("PRAGMA freelist_count").first?["freelist_count"], before)
      XCTAssertEqual(try runtime.legacyInlineSessionIds(limit: 10), [session.sessionId])
      withExtendedLifetime(lock) {}
    }
    var disabled = isolation.environment
    disabled["RIELA_RETENTION_AUTOMATIC"] = "0"
    XCTAssertTrue(isolation.run { AutomaticRetentionHook.runIfApplicable(arguments: arguments, exitCode: .success,
      cancelled: false, environment: disabled, currentDirectory: project.path) }.isEmpty)
    XCTAssertEqual(try db.query("PRAGMA freelist_count").first?["freelist_count"], before)
    XCTAssertEqual(try runtime.legacyInlineSessionIds(limit: 10), [session.sessionId])
    XCTAssertTrue(isolation.run { AutomaticRetentionHook.runIfApplicable(arguments: arguments, exitCode: .success,
      cancelled: false, environment: isolation.environment, currentDirectory: project.path) }.isEmpty)
    XCTAssertTrue(try runtime.legacyInlineSessionIds(limit: 10).isEmpty)
    XCTAssertLessThan(Int(try db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0,
      Int(before ?? "0") ?? 0)
  }

  private func target(_ root: URL) -> RetentionTarget {
    RetentionTarget(kind: .explicit, root: root.path, sessionStoreRoot: root.path, memoryRoot: nil,
      logsRoot: nil, stateDirectory: root.appendingPathComponent("retention").path, unsafeReason: nil)
  }

}
