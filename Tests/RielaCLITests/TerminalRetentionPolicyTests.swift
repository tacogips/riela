import Foundation
import XCTest
import RielaCore
import RielaSQLite
@testable import RielaCLI

final class TerminalRetentionPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private struct Fixture {
    var root: URL
    var paths: TerminalRetentionPaths
    var db: SQLiteDatabase
  }

  private func fixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/terminal-retention-policy-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = try TerminalRetentionPaths(sessionRoot: root.appendingPathComponent("sessions").path,
      artifactRoot: nil, memoryRoot: nil)
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(), withIntermediateDirectories: true)
    let db = try SQLiteDatabase.open(path: databasePath)
    try db.execute("""
      CREATE TABLE workflow_runtime_snapshots(
        workflow_execution_id TEXT PRIMARY KEY, workflow_id TEXT, session_status TEXT,
        parent_session_id TEXT, root_session_id TEXT, updated_at TEXT, session_json BLOB,
        root_output_json BLOB, diagnostics_json BLOB, loop_evidence_json BLOB, loop_summary_json BLOB)
      """)
    try db.execute("""
      CREATE TABLE cli_workflow_sessions(
        session_id TEXT PRIMARY KEY, record_json BLOB NOT NULL, updated_at TEXT NOT NULL,
        workflow_name TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.workflowName')) STORED,
        workflow_id TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.session.workflowId')) STORED,
        status TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.session.status')) STORED)
      """)
    try db.execute("""
      CREATE TABLE workflow_messages(
        workflow_execution_id TEXT NOT NULL, communication_id TEXT NOT NULL, payload_json BLOB NOT NULL,
        artifact_refs_json BLOB NOT NULL, created_at TEXT NOT NULL,
        PRIMARY KEY(workflow_execution_id, communication_id))
      """)
    try db.execute("""
      CREATE TABLE workflow_message_payload_index(
        workflow_execution_id TEXT NOT NULL, communication_id TEXT NOT NULL, key TEXT NOT NULL)
      """)
    return Fixture(root: root, paths: paths, db: db)
  }

  private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func insert(
    _ fixture: Fixture,
    _ id: String,
    status: String = "completed",
    workflow: String = "news",
    age: TimeInterval = 3 * 86_400,
    messageAge: TimeInterval? = nil,
    messageBody: String = "message"
  ) throws {
    let updated = stamp(now.addingTimeInterval(-age))
    let record = "{\"workflowName\":\"\(workflow)\",\"session\":{\"workflowId\":\"\(workflow)\",\"status\":\"\(status)\",\"rootSessionId\":\"\(id)\"}}"
    try fixture.db.execute("""
      INSERT INTO workflow_runtime_snapshots VALUES(?,?,?,NULL,?,?,jsonb('{}'),jsonb('{}'),jsonb('[]'),NULL,NULL)
      """, bindings: [.text(id), .text(workflow), .text(status), .text(id), .text(updated)])
    try fixture.db.execute("INSERT INTO cli_workflow_sessions(session_id,record_json,updated_at) VALUES(?,jsonb(?),?)",
      bindings: [.text(id), .text(record), .text(updated)])
    try message(fixture, id, createdAt: now.addingTimeInterval(-(messageAge ?? age)), body: messageBody)
  }

  private func message(_ fixture: Fixture, _ id: String, createdAt: Date, body: String = "message") throws {
    try fixture.db.execute("INSERT INTO workflow_messages VALUES(?,?,jsonb(?),jsonb('[]'),?)",
      bindings: [.text(id), .text(UUID().uuidString), .text("{\"body\":\"\(body)\"}"), .text(stamp(createdAt))])
  }

  private func run(_ fixture: Fixture, results: TerminalRetentionCategoryPolicy? = nil,
                   resultsState: RielaRetentionCategoryState = .notConfigured,
                   messages: TerminalRetentionMessageMode = .followResults,
                   messagesState: RielaRetentionCategoryState = .notConfigured,
                   dryRun: Bool = false, familyLimit: Int = 500,
                   keep: Set<String> = []) throws -> TerminalRetentionPolicyReport {
    return try TerminalRetentionExecutor(clock: { self.now }).runPolicy(paths: fixture.paths,
      keepWorkflowIds: keep, results: results, resultsState: resultsState, messages: messages,
      messagesState: messagesState, dryRun: dryRun, familyLimit: familyLimit)
  }

  func testPendingRecoverySharesResultBudgetAndDryRunDoesNotAdmitNewFamilies() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    for id in ["a", "b", "c"] { try insert(fixture, id) }
    var interrupted = TerminalRetentionExecutor(clock: { self.now })
    interrupted.beforeSecondaryCleanup = { throw TerminalRetentionError.reclamationBusy }
    let initial = try interrupted.runPolicy(paths: fixture.paths, keepWorkflowIds: [],
      results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      messages: .followResults, messagesState: .notConfigured, dryRun: false, familyLimit: 1)
    XCTAssertEqual(initial.results.removedCount, 1)
    XCTAssertEqual(initial.results.pendingCleanupCount, 1)
    let preview = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      dryRun: true, familyLimit: 1)
    XCTAssertEqual(preview.results.selectedCount, 0)
    XCTAssertTrue(preview.results.workLimitReached)
    let resumed = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active, familyLimit: 1)
    XCTAssertEqual(resumed.results.removedCount, 0)
    XCTAssertEqual(resumed.results.selectedCount, 0)
    XCTAssertEqual(resumed.results.pendingCleanupCount, 0)
    XCTAssertTrue(resumed.results.workLimitReached)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 2)
  }

  func testSecondaryOwnershipFailureKeepsPendingAndContinuesWithSiblingFamilies() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    for id in ["a", "b"] { try insert(fixture, id) }
    var calls = 0
    var executor = TerminalRetentionExecutor(clock: { self.now })
    executor.beforeSecondaryCleanup = {
      calls += 1
      if calls == 1 { throw TerminalRetentionError.secondaryProtected("injected ownership change") }
    }
    let result = try executor.runPolicy(paths: fixture.paths, keepWorkflowIds: [],
      results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      messages: .followResults, messagesState: .notConfigured, dryRun: false)
    XCTAssertEqual(result.results.removedCount, 2)
    XCTAssertEqual(result.results.pendingCleanupCount, 1)
    XCTAssertEqual(result.results.protected["secondaryOwnershipChanged"], 1)
    XCTAssertEqual(calls, 2)
  }

  func testFreshNestedInvocationCanWriteBeforeRetentionAndRejectsRetiredParents() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.db.execute("CREATE TABLE workflow_nested_invocations(reservation_json BLOB)")
    try ensureSessionRetentionTriggers(fixture.db)
    try fixture.db.execute("INSERT INTO workflow_nested_invocations VALUES(jsonb(?))",
      bindings: [.text(#"{"parentSessionId":"parent"}"#)])
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_nested_invocations").count, 1)
    try fixture.db.execute("CREATE TABLE session_retention_tombstones(session_id TEXT PRIMARY KEY)")
    try fixture.db.execute("INSERT INTO session_retention_tombstones VALUES('parent')")
    try ensureSessionRetentionTriggers(fixture.db)
    for json in [#"{"parentSessionId":"parent"}"#,
                 #"{"childSnapshot":{"session":{"sessionId":"parent"}}}"#] {
      XCTAssertThrowsError(try fixture.db.execute("INSERT INTO workflow_nested_invocations VALUES(jsonb(?))",
        bindings: [.text(json)]))
    }
    XCTAssertThrowsError(try fixture.db.execute("UPDATE workflow_nested_invocations SET reservation_json=jsonb(?)",
      bindings: [.text(#"{"parentSessionId":"parent"}"#)]))
  }

  func testResultsFollowResultsDeletesMessagesAndReportsTheirBytes() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active)
    XCTAssertEqual(report.results.removedCount, 1)
    XCTAssertEqual(report.messages.state, .notConfigured)
    XCTAssertGreaterThan(report.messages.removedBytes, 0)
    XCTAssertTrue(try fixture.db.query("SELECT * FROM workflow_messages").isEmpty)
  }

  func testMessagesKeepForeverWhileResultsAreRemoved() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      messages: .keepForever, messagesState: .keepForever)
    XCTAssertEqual(report.results.removedCount, 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_messages").count, 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 0)
  }

  func testMessagesOnlyTombstoneLeavesSnapshotAndRejectsRecreation() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    let report = try run(fixture, messages: .independent(.init(maxAge: 86_400, maxBytes: nil)), messagesState: .active)
    XCTAssertEqual(report.messages.removedCount, 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM session_message_retention_tombstones").count, 1)
    XCTAssertThrowsError(try message(fixture, "old", createdAt: now)) { error in
      XCTAssertTrue(String(describing: error).contains("workflow messages expired under retention"))
    }
  }

  func testResultsCanPruneMessageRetiredFamilyWithoutExecutionLockProtection() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    _ = try run(fixture, messages: .independent(.init(maxAge: 86_400, maxBytes: nil)), messagesState: .active)
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active)
    XCTAssertEqual(report.results.removedCount, 1)
    XCTAssertNotEqual(report.results.protected["executionLocked"], 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM session_message_retention_tombstones").count, 1)
  }

  func testSecondMessagesPassSkipsRetiredAndHonorsOneFamilyBound() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "retired", age: 4 * 86_400)
    try insert(fixture, "newer", age: 3 * 86_400)
    _ = try run(fixture, messages: .independent(.init(maxAge: 86_400, maxBytes: nil)), messagesState: .active, familyLimit: 1)
    let report = try run(fixture, messages: .independent(.init(maxAge: 86_400, maxBytes: nil)), messagesState: .active, familyLimit: 1)
    XCTAssertEqual(report.messages.selectedCount, 1)
    XCTAssertFalse(report.messages.workLimitReached)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_messages WHERE workflow_execution_id='retired'").count, 0)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_messages WHERE workflow_execution_id='newer'").count, 0)
  }

  func testOrphanMessagesArePrunedIndependently() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "orphan")
    let resultPass = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      messages: .keepForever, messagesState: .keepForever)
    XCTAssertEqual(resultPass.results.removedCount, 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_messages").count, 1)
    XCTAssertEqual(try fixture.db.query("SELECT cleanup_pending FROM session_retention_tombstones").first?["cleanup_pending"], "0")
    let report = try run(fixture, messages: .independent(.init(maxAge: 86_400, maxBytes: nil)), messagesState: .active)
    XCTAssertEqual(report.messages.orphanSessionCount, 1)
    XCTAssertTrue(try fixture.db.query("SELECT * FROM workflow_messages").isEmpty)
  }

  func testMessageCapIncludesOrphanAndFamilyBytesAndRechecksEligibleFamily() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "to-prune", age: 4 * 86_400, messageBody: String(repeating: "a", count: 30))
    try insert(fixture, "result-orphan", age: 4 * 86_400, messageAge: 3_600, messageBody: String(repeating: "b", count: 40))
    _ = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active,
      messages: .keepForever, messagesState: .keepForever, familyLimit: 1)
    let report = try run(fixture, messages: .independent(.init(maxAge: nil, maxBytes: 70)), messagesState: .active)
    XCTAssertEqual(report.messages.removedCount, 1)
    XCTAssertNotEqual(report.messages.protected["changedDuringAdmission"], 1)
    XCTAssertEqual(report.messages.capAchieved, true)
  }

  func testKeepWorkflowIdsProtectsMatchingFamily() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "kept", workflow: "news")
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active, keep: ["news"])
    XCTAssertEqual(report.results.protected["keptWorkflow"], 1)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testResultsKeepForeverLeavesOldSessionRowsUntouched() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "forever")
    let report = try run(fixture, resultsState: .keepForever, messages: .keepForever, messagesState: .keepForever)
    XCTAssertEqual(report.results.removedCount, 0)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testNonterminalAndAmbiguousFamiliesRemainProtectedUnderCap() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "running", status: "running")
    try insert(fixture, "suspended", status: "suspended")
    try insert(fixture, "created", status: "created")
    try insert(fixture, "lineage", status: "completed")
    try fixture.db.execute("UPDATE workflow_runtime_snapshots SET root_session_id='missing' WHERE workflow_execution_id='lineage'")
    try fixture.db.execute("""
      UPDATE cli_workflow_sessions
      SET record_json=jsonb('{"workflowName":"news","session":{"workflowId":"news","status":"completed","rootSessionId":"missing"}}')
      WHERE session_id='lineage'
      """)
    let report = try run(fixture, results: .init(maxAge: nil, maxBytes: 1), resultsState: .active)
    XCTAssertFalse(report.results.capAchieved ?? true)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 4)
  }

  func testExecutionLockedFamilyRemainsProtectedUnderCap() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "locked")
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: fixture.paths.sessionRoot)
    try registry.acquire(sessionId: "locked")
    defer { registry.release(sessionId: "locked") }
    let report = try run(fixture, results: .init(maxAge: nil, maxBytes: 1), resultsState: .active)
    XCTAssertEqual(report.results.protected["executionLocked"], 1)
    XCTAssertEqual(report.results.capAchieved, false)
    XCTAssertEqual(try fixture.db.query("SELECT * FROM workflow_runtime_snapshots").count, 1)
  }

  func testDryRunDoesNotWriteTombstonesOrLockFiles() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active, dryRun: true)
    XCTAssertGreaterThan(report.results.selectedCount, 0)
    XCTAssertEqual(report.results.removedCount, 0)
    XCTAssertFalse(try fixture.db.tableExists("session_retention_tombstones"))
    XCTAssertFalse(try fixture.db.tableExists("session_message_retention_tombstones"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.paths.sessionRoot).appendingPathComponent("runtime-records/execution-locks").path))
  }

  func testFamilyLimitReportsDeferredSelection() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "one", age: 5 * 86_400); try insert(fixture, "two", age: 4 * 86_400); try insert(fixture, "three", age: 3 * 86_400)
    let report = try run(fixture, results: .init(maxAge: 86_400, maxBytes: nil), resultsState: .active, familyLimit: 1)
    XCTAssertEqual(report.results.removedCount, 1)
    XCTAssertTrue(report.results.workLimitReached)
  }

  func testFinalizeRemovesOnlyOrphanLocksAndReportsReclamation() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "present")
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: fixture.paths.sessionRoot)
    try registry.acquire(sessionId: "present")
    try registry.release(sessionId: "present")
    try registry.acquire(sessionId: "absent")
    registry.release(sessionId: "absent")
    let resultLock = URL(fileURLWithPath: fixture.paths.sessionRoot).appendingPathComponent("runtime-records/execution-locks/absent.lock")
    XCTAssertTrue(FileManager.default.fileExists(atPath: resultLock.path))
    var report = TerminalRetentionPolicyReport(results: .inactive(.notConfigured), messages: .inactive(.notConfigured), orphanLocks: nil, reclamation: [])
    TerminalRetentionExecutor(clock: { self.now }).finalize(paths: fixture.paths, report: &report, mode: .manual, dryRun: false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: resultLock.path))
    XCTAssertEqual(report.orphanLocks?.removedCount, 1)
    XCTAssertTrue(report.reclamation.contains { $0.database.hasSuffix("runtime-message-log.sqlite") })
  }

  func testPendingRootsMismatchProtectsOneFamilyAndContinuesPruning() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "pending"); try insert(fixture, "eligible")
    try fixture.db.execute("""
      CREATE TABLE session_retention_tombstones(session_id TEXT PRIMARY KEY,workflow_id TEXT,root_id TEXT,pruned_at TEXT,
        artifact_root TEXT,memory_root TEXT,payload_bytes INTEGER,cleanup_pending INTEGER)
      """)
    try fixture.db.execute("INSERT INTO session_retention_tombstones VALUES('pending','news','pending',?,'/wrong','',1,1)", bindings: [.text(stamp(now))])
    let report = try TerminalRetentionExecutor(clock: { self.now }).run(paths: try TerminalRetentionPaths(
      sessionRoot: fixture.paths.sessionRoot, artifactRoot: nil, memoryRoot: nil), workflows: ["news"],
      retentionHours: 24, maxPayloadBytes: 256 * 1024 * 1024, dryRun: false)
    XCTAssertEqual(report.protectedFamilies["pending"], "pendingRootsMismatch")
    XCTAssertEqual(report.removedSessionCount, 1)
    XCTAssertEqual(try fixture.db.query("SELECT count(*) AS count FROM workflow_runtime_snapshots").first?["count"], "1")
  }

  func testSessionPruneJSONIncludesReclamationResults() throws {
    let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    try insert(fixture, "old")
    let runner = SessionPruneCommandRunner()
    let output = runner.run(["--session-store", fixture.paths.sessionRoot,
      "--artifact-root", fixture.root.appendingPathComponent("artifacts").path,
      "--memory-root", fixture.root.appendingPathComponent("memory").path,
      "--workflow-id", "news"])
    XCTAssertEqual(output.exitCode, .success, output.stdout)
    XCTAssertTrue(output.stdout.contains("\"reclamation\""), output.stdout)
    XCTAssertFalse(output.stdout.contains("\"action\":\"failed\""), output.stdout)
  }
}
