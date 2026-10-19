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
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot!)
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
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot!)
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
    let memory = RielaMemoryStore(rootDirectory: paths.memoryRoot!)
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

  func testMetadataIndexesPreserveLegacyPlansAndOlderWriterUpdates() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try insert("parent", db: f.db)
    try insert("child", parent: "parent", root: "parent", db: f.db)
    try insert("running", status: "running", db: f.db)
    try insert("interrupted", status: "interrupted", db: f.db)
    try f.db.execute("""
      CREATE TABLE cli_workflow_sessions(session_id TEXT PRIMARY KEY,workflow_id TEXT,status TEXT,updated_at TEXT,record_json BLOB)
      """)
    try f.db.execute("""
      INSERT INTO cli_workflow_sessions VALUES('legacy','news','completed',?,jsonb(?))
      """, bindings: [.text(ISO8601DateFormatter().string(from: now.addingTimeInterval(-90_000))),
        .text("{\"session\":{\"rootSessionId\":\"legacy\"},\"output\":\"" + String(repeating: "研究", count: 2000) + "\"}")])
    try f.db.execute("""
      CREATE TABLE workflow_nested_invocations(reservation_json BLOB,child_terminal_json BLOB,parent_message_json BLOB,recovery_reason TEXT)
      """)
    try f.db.execute("""
      INSERT INTO workflow_nested_invocations VALUES(
        jsonb('{"parentSessionId":"parent","childSnapshot":{"session":{"sessionId":"child"}}}'),jsonb('{}'),jsonb('{}'),NULL)
      """)
    let before = try TerminalRetentionMetadata.sessions(f.db)
    let plan = try TerminalRetentionPlan.make(sessions: before, workflows: ["news"], now: now,
      retentionHours: 24, maxPayloadBytes: 268_435_456)
    try TerminalRetentionIndexes.prepare(f.db)
    XCTAssertEqual(try TerminalRetentionMetadata.sessions(f.db), before)
    XCTAssertEqual(try TerminalRetentionPlan.make(sessions: TerminalRetentionMetadata.sessions(f.db),
      workflows: ["news"], now: now, retentionHours: 24, maxPayloadBytes: 268_435_456), plan)
    // No typed save or projection cache: SQL writes by older binaries must update immediately.
    try f.db.execute("UPDATE cli_workflow_sessions SET record_json=jsonb('{\"session\":{\"parentSessionId\":\"parent\",\"rootSessionId\":\"parent\"}}')")
    try f.db.execute("UPDATE workflow_nested_invocations SET recovery_reason='unsettled'")
    let changed = try TerminalRetentionMetadata.sessions(f.db)
    XCTAssertEqual(changed.first { $0.id == "legacy" }?.parentId, "parent")
    XCTAssertEqual(changed.first { $0.id == "child" }?.protection, "unsettledNestedInvocation")
    XCTAssertNotEqual(changed, before)
  }

  func testIndexedAdmissionStillProtectsNewRunningDescendant() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try insert("parent", db: f.db)
    let executor = TerminalRetentionExecutor(clock: { self.now }, beforeTransaction: {
      try self.insert("new-child", status: "running", parent: "parent", root: "parent", db: f.db)
    })
    let report = try execute(f.paths, executor: executor)
    XCTAssertEqual(report.protectedFamilies["parent"], "changedDuringAdmission")
    XCTAssertEqual(try f.db.query("SELECT count(*) AS count FROM workflow_runtime_snapshots").first?["count"], "2")
  }

  func testLegacyDryRunDoesNotInstallIndexesOrChangeDatabaseBytes() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try insert("old", db: f.db)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: f.paths.sessionRoot)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let schema = try f.db.query("SELECT name,sql FROM sqlite_master ORDER BY name")
    _ = try execute(f.paths, dryRun: true)
    XCTAssertEqual(try f.db.query("SELECT name,sql FROM sqlite_master ORDER BY name"), schema)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    XCTAssertEqual(try TerminalRetentionIndexes.source("workflow_runtime_snapshots", in: f.db), "workflow_runtime_snapshots")
  }

  func testFreshPathChecksRejectNewAndDanglingSymlinks() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let child = f.root.appendingPathComponent("managed/new/database.sqlite")
    XCTAssertEqual(try TerminalRetentionPaths.checkedDatabase(child.path), child.path)
    let managed = f.root.appendingPathComponent("managed")
    try FileManager.default.createSymbolicLink(at: managed,
      withDestinationURL: f.root.appendingPathComponent("missing-target"))
    XCTAssertThrowsError(try TerminalRetentionPaths.checkedDatabase(child.path)) {
      XCTAssertEqual($0 as? TerminalRetentionError, .unsafePath)
    }
    try FileManager.default.removeItem(at: managed)
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    XCTAssertEqual(try TerminalRetentionPaths.checkedDatabase(child.path), child.path)
    XCTAssertThrowsError(try TerminalRetentionPaths.checked(f.root.path + "/nul\0/escape")) {
      XCTAssertEqual($0 as? TerminalRetentionError, .unsafePath)
    }
    XCTAssertThrowsError(try TerminalRetentionPaths.checked("relative/path"))
    XCTAssertThrowsError(try TerminalRetentionPaths.checked(f.root.path + "/../escape"))
  }

  func testPathCheckFailsClosedOnSearchPermissionError() throws {
    #if canImport(Darwin) || canImport(Glibc)
    guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory search permissions") }
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let denied = f.root.appendingPathComponent("denied")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
    XCTAssertThrowsError(try TerminalRetentionPaths.checked(denied.appendingPathComponent("missing").path)) {
      XCTAssertEqual(($0 as? POSIXError)?.code, .EACCES)
    }
    #endif
  }

  func testArtifactCleanupCheckpointAndZeroFamilyRetryReclaimsWithoutDeletingRunningRows() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let path = SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: try XCTUnwrap(f.paths.artifactRoot))
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
    let artifact = try SQLiteDatabase.open(path: path)
    try artifact.execute("CREATE TABLE workflow_messages(workflow_execution_id TEXT,payload_json BLOB,artifact_refs_json BLOB)")
    let sentinel = "private-synthetic-deleted-marker-" + String(repeating: "z", count: 200_000)
    try artifact.execute("INSERT INTO workflow_messages VALUES('done',?, '[]')", bindings: [.text(sentinel)])
    try artifact.execute("INSERT INTO workflow_messages VALUES('running','preserve-running','[]')")
    _ = try TerminalRetentionSecondary.clean(ids: ["done"], workflows: ["done": "news"], paths: f.paths, mode: .manual)
    // Simulated interruption after per-family cleanup, before final compaction.
    XCTAssertFalse(try Data(contentsOf: URL(fileURLWithPath: path)).contains(Data("private-synthetic-deleted-marker-".utf8)))
    let before = Int(try artifact.query("PRAGMA page_count").first?["page_count"] ?? "0") ?? 0
    XCTAssertGreaterThan(Int(try artifact.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, 0)
    XCTAssertEqual(try execute(f.paths).removedSessionCount, 0)
    XCTAssertLessThan(Int(try artifact.query("PRAGMA page_count").first?["page_count"] ?? "0") ?? 0, before)
    XCTAssertEqual(try artifact.query("SELECT payload_json FROM workflow_messages").first?["payload_json"], "preserve-running")
  }

  func testFinalArtifactReclaimRechecksSymlink() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let path = SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: try XCTUnwrap(f.paths.artifactRoot))
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
    let foreign = f.root.appendingPathComponent("foreign")
    try Data("unchanged".utf8).write(to: foreign)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: foreign.path)
    XCTAssertThrowsError(try TerminalRetentionSecondary.reclaimArtifacts(f.paths, mode: .manual, reclaimer: RetentionSQLiteReclaimer()))
    XCTAssertEqual(try Data(contentsOf: foreign), Data("unchanged".utf8))
  }

  func testInvocationLocalDateDecodingPreservesFractionalFallbackAndInvalidProtection() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let values = ["2026-01-02T03:04:05.123456Z", "2026-01-02T03:04:05Z",
      "2026-01-02T12:04:05+09:00", "invalid"]
    for (index, value) in values.enumerated() {
      try insert("date-\(index)", db: f.db)
      try f.db.execute("UPDATE workflow_runtime_snapshots SET updated_at=? WHERE workflow_execution_id=?",
        bindings: [.text(value), .text("date-\(index)")])
    }
    for row in try TerminalRetentionMetadata.sessions(f.db) {
      let index = try XCTUnwrap(Int(row.id.replacingOccurrences(of: "date-", with: "")))
      let old = ISO8601DateFormatter()
      old.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var expected = old.date(from: values[index])
      if expected == nil {
        old.formatOptions = [.withInternetDateTime]
        expected = old.date(from: values[index])
      }
      XCTAssertEqual(row.updatedAt, expected)
    }
  }

  func testBoundedFamiliesProgressAcrossFreshInvocationsPreservesProtectedFamily() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for id in ["a", "b", "c"] { try insert(id, db: f.db) }
    try insert("live", status: "running", db: f.db)
    for remaining in [2, 1, 0] {
      let result = try TerminalRetentionExecutor(clock: { self.now }).run(paths: f.paths,
        workflows: ["news"], retentionHours: 24, maxPayloadBytes: 1, dryRun: false, maxFamilies: 1)
      XCTAssertEqual(result.removedSessionCount, 1)
      XCTAssertEqual(result.selectedFamilies.count, 1)
      XCTAssertEqual(result.deferredFamilyCount, remaining)
      XCTAssertFalse(result.capAchieved)
      XCTAssertEqual(result.pendingCleanupCount, 0)
      XCTAssertEqual(try f.db.query("SELECT workflow_execution_id FROM workflow_runtime_snapshots WHERE session_status='running'").first?["workflow_execution_id"], "live")
    }
    XCTAssertEqual(try f.db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testPendingRecoveryConsumesSameBoundAndDoesNotAdmitNewFamily() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for id in ["a", "b", "c"] { try insert(id, db: f.db) }
    var interrupted = TerminalRetentionExecutor(clock: { self.now })
    interrupted.beforeSecondaryCleanup = { throw TerminalRetentionError.reclamationBusy }
    XCTAssertThrowsError(try interrupted.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
      maxPayloadBytes: 1, dryRun: false, maxFamilies: 1))
    let result = try TerminalRetentionExecutor(clock: { self.now }).run(paths: f.paths,
      workflows: ["news"], retentionHours: 24, maxPayloadBytes: 1, dryRun: false, maxFamilies: 1)
    XCTAssertEqual(result.removedSessionCount, 0)
    XCTAssertTrue(result.selectedFamilies.isEmpty)
    XCTAssertEqual(result.pendingCleanupCount, 0)
    XCTAssertEqual(result.deferredFamilyCount, 2)
    XCTAssertEqual(try f.db.query("SELECT * FROM workflow_runtime_snapshots").count, 2)
  }

  func testBoundedDryRunAndInvalidFamilyLimitNeverWrite() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for id in ["a", "b"] { try insert(id, db: f.db) }
    let executor = TerminalRetentionExecutor(clock: { self.now })
    let result = try executor.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
      maxPayloadBytes: 1, dryRun: true, maxFamilies: 1)
    XCTAssertEqual(result.selectedFamilies, ["a"])
    XCTAssertEqual(result.deferredFamilyCount, 1)
    XCTAssertGreaterThan(result.remainingPayloadBytes, 0)
    for limit in [0, -1, 10_001] {
      XCTAssertThrowsError(try executor.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
        maxPayloadBytes: 1, dryRun: false, maxFamilies: limit))
    }
    XCTAssertFalse(try f.db.tableExists("session_retention_tombstones"))
  }

  func testBoundedCompactionDeferralSecurelyCheckpointsAndZeroSelectionRetryCompacts() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for id in ["a", "b"] { try insert(id, db: f.db) }
    let sentinel = "synthetic-secure-delete-sentinel"
    try f.db.execute("UPDATE workflow_runtime_snapshots SET root_output_json=jsonb(?) WHERE workflow_execution_id='a'",
      bindings: [.text("{\"body\":\"" + sentinel + String(repeating: "z", count: 200_000) + "\"}")])
    let executor = TerminalRetentionExecutor(clock: { self.now })
    let first = try executor.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
      maxPayloadBytes: 10_000_000, dryRun: false, maxFamilies: 1)
    XCTAssertTrue(first.deferredCompaction)
    XCTAssertTrue(first.capAchieved) // Logical cap is unchanged; deferral is independently partial.
    XCTAssertNotNil(first.remainingDatabaseBytes)
    let database = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: f.paths.sessionRoot)
    XCTAssertFalse(try Data(contentsOf: URL(fileURLWithPath: database)).contains(Data(sentinel.utf8)))
    XCTAssertGreaterThan(Int(try f.db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, 0)
    var interrupted = executor
    interrupted.beforeFinalCompaction = { throw TerminalRetentionError.reclamationBusy }
    XCTAssertThrowsError(try interrupted.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
      maxPayloadBytes: 10_000_000, dryRun: false, maxFamilies: 1))
    let retry = try executor.run(paths: f.paths, workflows: ["news"], retentionHours: 24,
      maxPayloadBytes: 10_000_000, dryRun: false, maxFamilies: 1)
    XCTAssertEqual(retry.removedSessionCount, 0)
    XCTAssertFalse(retry.deferredCompaction)
    XCTAssertEqual(Int(try f.db.query("PRAGMA freelist_count").first?["freelist_count"] ?? "-1"), 0)
  }

  func testPruneCLIValidationAndHelp() throws {
    let runner = SessionPruneCommandRunner()
    XCTAssertEqual(runner.run(["--help"]).exitCode, .success)
    XCTAssertEqual(runner.run([]).exitCode, .usage)
    let fixture = try fixture()
    let root = fixture.root, paths = fixture.paths, db = fixture.db
    defer { try? FileManager.default.removeItem(at: root) }
    try insert("old", db: db)
    let arguments = ["--session-store", paths.sessionRoot, "--artifact-root", paths.artifactRoot!,
      "--memory-root", paths.memoryRoot!, "--workflow-id", "news", "--dry-run"]
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
    try FileManager.default.createDirectory(atPath: paths.artifactRoot!, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: paths.artifactRoot!).appendingPathComponent("old").path,
      withDestinationPath: root.path)
    XCTAssertThrowsError(try execute(paths))
    XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
    XCTAssertThrowsError(try TerminalRetentionPaths(sessionRoot: paths.sessionRoot,
      artifactRoot: paths.sessionRoot + "/artifacts", memoryRoot: paths.memoryRoot!))
  }
}
