import Foundation
import XCTest
import RielaCore
import RielaMemory
import RielaSQLite
@testable import RielaCLI

final class TerminalRetentionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private struct Fixture {
    var root: URL
    var paths: TerminalRetentionPaths
    var db: SQLiteDatabase
  }

  private func fixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/terminal-retention-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = try TerminalRetentionPaths(sessionRoot: root.appendingPathComponent("sessions").path,
      artifactRoot: root.appendingPathComponent("artifacts").path, memoryRoot: root.appendingPathComponent("memory").path)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot)
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
    let db = try SQLiteDatabase.open(path: path)
    try db.execute("""
      CREATE TABLE workflow_runtime_snapshots(workflow_execution_id TEXT PRIMARY KEY,workflow_id TEXT,session_status TEXT,
        parent_session_id TEXT,root_session_id TEXT,updated_at TEXT,session_json BLOB,root_output_json BLOB,
        diagnostics_json BLOB,loop_evidence_json BLOB,loop_summary_json BLOB)
      """)
    try db.execute("CREATE TABLE workflow_messages(workflow_execution_id TEXT,payload_json BLOB,artifact_refs_json BLOB)")
    return Fixture(root: root, paths: paths, db: db)
  }

  private func insert(_ id: String, status: String = "completed", parent: String? = nil,
                      root: String? = nil, db: SQLiteDatabase) throws {
    try db.execute("""
      INSERT INTO workflow_runtime_snapshots VALUES(?,?,?,?,?,?,jsonb(?),jsonb(?),jsonb('[]'),NULL,NULL)
      """, bindings: [.text(id), .text("news"), .text(status), .optionalText(parent), .text(root ?? id),
        .text(ISO8601DateFormatter().string(from: now.addingTimeInterval(-90_000))),
        .text("{}"), .text("{\"body\":\"" + String(repeating: "x", count: 100_000) + "\"}")])
    try db.execute("INSERT INTO workflow_messages VALUES(?,jsonb(?),jsonb('[]'))",
      bindings: [.text(id), .text("{\"body\":\"synthetic payload\"}")])
  }

  private func execute(_ paths: TerminalRetentionPaths, dryRun: Bool = false,
                       executor: TerminalRetentionExecutor? = nil) throws -> TerminalRetentionReport {
    try (executor ?? .init(clock: { self.now })).run(paths: paths, workflows: ["news"],
      retentionHours: 24, maxPayloadBytes: 268_435_456, dryRun: dryRun)
  }

  func testTerminalCleanupPreservesDurableMemoryAndReservesIdentity() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot)
    try memory.save(memoryId: "mixed", workflowId: "news", payload: .object([
      "source": .string("riela-node-manager"), "direction": .string("outbox"),
      "workflowId": .string("news"), "sessionId": .string("old"), "output": .string("temporary body")]))
    try memory.save(memoryId: "mixed", workflowId: "news", payload: .object([
      "kind": .string("export-receipt"), "sessionId": .string("old"), "noteId": .string("durable")]))
    let artifact = try paths.artifactSnapshot("old")
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: artifact).deletingLastPathComponent().path, withIntermediateDirectories: true)
    try Data("synthetic runtime snapshot".utf8).write(to: URL(fileURLWithPath: artifact))
    let beforePages = Int(try db.query("PRAGMA page_count").first?["page_count"] ?? "0") ?? 0
    let result = try execute(paths)
    let afterPages = Int(try db.query("PRAGMA page_count").first?["page_count"] ?? "0") ?? 0
    XCTAssertLessThan(afterPages, beforePages)
    XCTAssertEqual(result.removedSessionCount, 1, String(describing: result))
    XCTAssertEqual(result.remainingPayloadBytes, 0)
    XCTAssertTrue(result.capAchieved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifact))
    XCTAssertTrue(try db.query("SELECT * FROM workflow_messages").isEmpty)
    let memoryDB = try SQLiteDatabase.open(path: memory.databasePath(memoryId: "mixed"), mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertEqual(try memoryDB.query("SELECT json_extract(payload_json,'$.kind') AS kind FROM memory_entries").first?["kind"], "export-receipt")
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: paths.sessionRoot)
    XCTAssertThrowsError(try locks.acquire(sessionId: "old")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .retiredSession("old"))
    }
    let sessionStore = CLIWorkflowSessionStore(rootDirectory: paths.sessionRoot)
    XCTAssertTrue(sessionStore.sessionRecordExists(sessionId: "old"))
    XCTAssertEqual(try sessionStore.loadRawSessionIdentities().map(\.sessionId), ["old"])
    XCTAssertThrowsError(try insert("old", db: db))
    XCTAssertThrowsError(try db.execute("INSERT INTO workflow_messages VALUES('old',jsonb('{}'),jsonb('[]'))"))
    XCTAssertEqual(try execute(paths).removedSessionCount, 0)
  }

  func testDryRunAndPausedChildNeverDelete() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("parent", db: db); try insert("child", status: "suspended", parent: "parent", root: "parent", db: db)
    let dry = try execute(paths, dryRun: true)
    XCTAssertTrue(dry.selectedFamilies.isEmpty)
    XCTAssertFalse(try db.tableExists("session_retention_tombstones"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: paths.sessionRoot).appendingPathComponent("runtime-records/execution-locks").path))
    let result = try execute(paths)
    XCTAssertEqual(result.protectedFamilies["parent"], "nonterminalOrConflictingStatus")
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 2)
  }

  func testExecutionLockAndTransactionRecheckProtectSession() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: paths.sessionRoot)
    try locks.acquire(sessionId: "old")
    XCTAssertEqual(try execute(paths).protectedFamilies["old"], "executionLocked")
    locks.release(sessionId: "old")
    let executor = TerminalRetentionExecutor(clock: { self.now }, beforeTransaction: {
      try db.execute("UPDATE workflow_runtime_snapshots SET session_status='running' WHERE workflow_execution_id='old'")
    })
    XCTAssertEqual(try execute(paths, executor: executor).protectedFamilies["old"], "changedDuringAdmission")
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testInterruptedCleanupIsRecoveredWithoutResuming() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let artifact = try paths.artifactSnapshot("old")
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: artifact).deletingLastPathComponent().path, withIntermediateDirectories: true)
    try Data("temporary body".utf8).write(to: URL(fileURLWithPath: artifact))
    let executor = TerminalRetentionExecutor(clock: { self.now }, beforeSecondaryCleanup: { throw TerminalRetentionError.changedFamily })
    XCTAssertThrowsError(try execute(paths, executor: executor))
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact))
    XCTAssertEqual(try db.query("SELECT cleanup_pending FROM session_retention_tombstones").first?["cleanup_pending"], "1")
    XCTAssertTrue(try db.query("SELECT * FROM workflow_runtime_snapshots").isEmpty)
    let recovered = try execute(paths)
    XCTAssertEqual(recovered.pendingCleanupCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifact))
  }

  func testPendingCleanupRecoversDescendantOutsideRootWorkflowAllowlist() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("parent", db: db); try insert("child", parent: "parent", root: "parent", db: db)
    try db.execute("UPDATE workflow_runtime_snapshots SET workflow_id='child-workflow' WHERE workflow_execution_id='child'")
    try db.execute("CREATE TABLE workflow_nested_invocations(reservation_json BLOB,child_terminal_json BLOB,parent_message_json BLOB,recovery_reason TEXT)")
    try db.execute("""
      INSERT INTO workflow_nested_invocations VALUES(
        jsonb('{"parentSessionId":"parent","childSnapshot":{"session":{"sessionId":"child"}}}'),
        jsonb('{}'),jsonb('{}'),NULL)
      """)
    let executor = TerminalRetentionExecutor(clock: { self.now }, beforeSecondaryCleanup: { throw TerminalRetentionError.changedFamily })
    XCTAssertThrowsError(try execute(paths, executor: executor))
    XCTAssertEqual(try db.query("SELECT * FROM session_retention_tombstones WHERE cleanup_pending=1").count, 2)
    let dry = try execute(paths, dryRun: true)
    XCTAssertEqual(dry.pendingCleanupCount, 2)
    XCTAssertFalse(dry.capAchieved)
    XCTAssertEqual(try execute(paths).pendingCleanupCount, 0)
    XCTAssertTrue(try db.query("SELECT * FROM workflow_nested_invocations").isEmpty)
  }

  func testDurableReferenceAndUnknownArtifactProtectPayload() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("referenced", db: db); try insert("artifact", db: db)
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot)
    let journal = try memory.save(memoryId: "mixed", workflowId: "news", payload: .object([
      "source": .string("riela-node-manager"), "direction": .string("outbox"),
      "workflowId": .string("news"), "sessionId": .string("referenced"), "output": .string("body")]))
    try memory.save(memoryId: "mixed", workflowId: "news", relatedRecordIds: [journal.recordId],
      payload: .object(["kind": .string("durable-reference")]))
    let directory = URL(fileURLWithPath: try paths.artifactSnapshot("artifact")).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("unmanaged".utf8).write(to: directory.appendingPathComponent("custom-output.txt"))
    let report = try execute(paths)
    XCTAssertEqual(report.protectedFamilies["referenced"], "journalHasDurableReferences")
    XCTAssertEqual(report.protectedFamilies["artifact"], "unmanagedSessionArtifacts")
    XCTAssertEqual(report.removedSessionCount, 0)
  }

  func testPendingCleanupPreservesJournalReferencedAfterTombstoneCommit() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot)
    let journal = try memory.save(memoryId: "mixed", workflowId: "news", payload: .object([
      "source": .string("riela-node-manager"), "direction": .string("outbox"),
      "workflowId": .string("news"), "sessionId": .string("old"), "output": .string("body")]))
    let interrupted = TerminalRetentionExecutor(clock: { self.now }, beforeSecondaryCleanup: { throw TerminalRetentionError.changedFamily })
    XCTAssertThrowsError(try execute(paths, executor: interrupted))
    try memory.save(memoryId: "mixed", workflowId: "news", relatedRecordIds: [journal.recordId],
      payload: .object(["kind": .string("durable-reference")]))
    let report = try execute(paths)
    XCTAssertEqual(report.pendingCleanupCount, 1)
    XCTAssertFalse(report.capAchieved)
    XCTAssertEqual(report.protectedFamilies["old"], "secondaryOwnershipChanged")
    let memoryDB = try SQLiteDatabase.open(path: memory.databasePath(memoryId: "mixed"), mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertEqual(try memoryDB.query("SELECT * FROM memory_entries").count, 2)
    XCTAssertEqual(try db.query("SELECT cleanup_pending FROM session_retention_tombstones").first?["cleanup_pending"], "1")
  }

  func testTextBackedMultibytePayloadCountsUTF8BytesForCap() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("recent", db: db)
    let body = "{\"body\":\"" + String(repeating: "研究", count: 100) + "\"}"
    try db.execute("UPDATE workflow_runtime_snapshots SET root_output_json=?,updated_at=?",
      bindings: [.text(body), .text(ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600)))])
    let result = try TerminalRetentionExecutor(clock: { self.now }).run(paths: paths, workflows: ["news"],
      retentionHours: 24, maxPayloadBytes: 400, dryRun: true)
    XCTAssertEqual(result.selectedFamilies, ["recent"])
    XCTAssertGreaterThanOrEqual(result.beforePayloadBytes, Int64(body.utf8.count))
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testPruneCLIValidationAndHelp() throws {
    let runner = SessionPruneCommandRunner()
    XCTAssertEqual(runner.run(["--help"]).exitCode, .success)
    XCTAssertEqual(runner.run([]).exitCode, .usage)
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let arguments = ["--session-store", paths.sessionRoot, "--artifact-root", paths.artifactRoot,
      "--memory-root", paths.memoryRoot, "--workflow-id", "news", "--dry-run"]
    XCTAssertEqual(runner.run(arguments + ["--retention-hours", "0"]).exitCode, .failure)
    XCTAssertFalse(try db.tableExists("session_retention_tombstones"))
  }

  func testSQLiteSidecarSymlinkIsRejectedBeforeOpeningStore() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let destination = root.appendingPathComponent("unrelated.txt")
    try Data("preserve".utf8).write(to: destination)
    try FileManager.default.createSymbolicLink(
      atPath: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot) + "-journal",
      withDestinationPath: destination.path)
    XCTAssertThrowsError(try execute(paths))
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "preserve")
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testSymlinkAndOverlappingRootsRejected() throws {
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    try FileManager.default.createDirectory(atPath: paths.artifactRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: paths.artifactRoot).appendingPathComponent("old").path,
      withDestinationPath: root.path)
    XCTAssertThrowsError(try execute(paths))
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
    XCTAssertThrowsError(try TerminalRetentionPaths(sessionRoot: paths.sessionRoot,
      artifactRoot: paths.sessionRoot + "/artifacts", memoryRoot: paths.memoryRoot))
  }
}
