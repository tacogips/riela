import Foundation
import XCTest
import CryptoKit
import RielaCore
import RielaSQLite
@testable import RielaCLI

final class SessionAbandonedInvocationTests: XCTestCase {
  func testOldUnsettledAbsentChildCanBeAbandonedAndRecentRowIsLeftUntouched() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "parent", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    let recentParent = makeSession(id: "recent-parent", status: .completed)
    try save(recentParent, to: store)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let db = try SQLiteDatabase.open(path: path)
    try insertInvocation("old", parent: parent.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    try insertInvocation("recent", parent: recentParent.sessionId,
      updated: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 - 3600)), db: db)
    let reconciler = SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path), now: { Date(timeIntervalSince1970: 1_800_000_000) })

    let verdicts = try reconciler.run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)

    XCTAssertEqual(verdicts.first(where: { $0.invocationKey == "old" })?.verdict, "abandoned")
    XCTAssertEqual(verdicts.first(where: { $0.invocationKey == "old" })?.applied, true)
    XCTAssertEqual(verdicts.first(where: { $0.invocationKey == "recent" })?.verdict, "recent")
    XCTAssertNotNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old'").first?["abandoned_at"])
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='recent'").first?["abandoned_at"])
    let sessions = try TerminalRetentionMetadata.sessions(db)
    XCTAssertNil(sessions.first(where: { $0.id == parent.sessionId })?.protection)
    XCTAssertEqual(sessions.first(where: { $0.id == recentParent.sessionId })?.protection, "unsettledNestedInvocation")
  }

  func testAbandonThenApplyPruneDeletesAbsentChildRowAndReportsDeletedPayload() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-prune")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    for directory in [sessions, artifacts, memory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let store = CLIWorkflowSessionStore(rootDirectory: sessions.path)
    var parent = makeSession(id: "parent", status: .failed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessions.path))
    try insertInvocation("absent-child", parent: parent.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    try db.execute("INSERT INTO workflow_nested_invocation_refs(invocation_key,role,ordinal,root_session_id,digest) VALUES('absent-child','parent',0,'parent','digest')")
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let reconciled = try SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: sessions.path), now: { fixedNow }
    ).run(sessionStoreRoot: sessions.path, abandonedAfter: 24 * 3600, apply: true)
    XCTAssertEqual(reconciled.first?.verdict, "abandoned")
    let rowBytes = try db.query("SELECT length(CAST(reservation_json AS BLOB)) AS bytes FROM workflow_nested_invocations WHERE invocation_key='absent-child'")
      .first?["bytes"].flatMap(Int64.init) ?? 0
    let familyPayloadBytes = try XCTUnwrap(TerminalRetentionMetadata.sessions(db).first(where: { $0.id == parent.sessionId })?.payloadBytes)
    XCTAssertGreaterThan(familyPayloadBytes, rowBytes)
    let paths = try TerminalRetentionPaths(sessionRoot: sessions.path, artifactRoot: artifacts.path, memoryRoot: memory.path)

    let report = try TerminalRetentionExecutor(clock: { fixedNow }).run(paths: paths, workflows: [parent.workflowId],
      retentionHours: 24, maxPayloadBytes: 68_719_476_736, dryRun: false)

    XCTAssertEqual(report.removedSessionCount, 1)
    XCTAssertEqual(report.beforePayloadBytes - report.remainingPayloadBytes, familyPayloadBytes)
    XCTAssertTrue(try db.query("SELECT * FROM workflow_nested_invocations WHERE invocation_key='absent-child'").isEmpty)
    XCTAssertTrue(try db.query("SELECT * FROM workflow_nested_invocation_refs WHERE invocation_key='absent-child'").isEmpty)
  }

  func testDryRunDoesNotWriteAbandonedTimestamp() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-dry")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "parent", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertInvocation("old", parent: parent.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    let checksum = try databaseChecksum(root: root)
    let before = try db.query("SELECT hex(reservation_json) AS reservation, updated_at, abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old'").first

    let verdict = try SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path), now: { Date(timeIntervalSince1970: 1_800_000_000) })
      .run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: false).first

    XCTAssertEqual(verdict?.verdict, "abandoned")
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old'").first?["abandoned_at"])
    XCTAssertEqual(try db.query("SELECT hex(reservation_json) AS reservation, updated_at, abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old'").first,
      before)
    XCTAssertEqual(try databaseChecksum(root: root), checksum)
  }

  func testRetiredAndMessageRetiredParentsAreSkippedAndMalformedRowsHaveVerdicts() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-retired")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "message-retired", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    var retired = makeSession(id: "retired", status: .completed)
    retired.updatedAt = parent.updatedAt
    try save(retired, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertInvocation("messages", parent: parent.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    try insertInvocation("retired", parent: retired.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    try db.execute("CREATE TABLE session_message_retention_tombstones(session_id TEXT PRIMARY KEY)")
    try db.execute("INSERT INTO session_message_retention_tombstones VALUES('message-retired')")
    try db.execute("CREATE TABLE session_retention_tombstones(session_id TEXT PRIMARY KEY)")
    try db.execute("INSERT INTO session_retention_tombstones VALUES('retired')")
    try db.execute("INSERT INTO workflow_nested_invocations(invocation_key,reservation_json,created_at,updated_at) VALUES('no-parent',jsonb('{}'),'2023-01-01T00:00:00Z','2023-01-01T00:00:00Z')")
    try db.execute("INSERT INTO workflow_nested_invocations(invocation_key,reservation_json,created_at,updated_at) VALUES('bad-date',jsonb('{\"parentSessionId\":\"message-retired\"}'),'not-a-date','not-a-date')")

    let results = try SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path), now: { Date(timeIntervalSince1970: 1_800_000_000) }
    ).run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)

    XCTAssertEqual(results.first(where: { $0.invocationKey == "messages" })?.verdict, "abandoned")
    XCTAssertEqual(results.first(where: { $0.invocationKey == "retired" })?.verdict, "skipped")
    XCTAssertTrue(results.contains { $0.invocationKey == "no-parent" && $0.verdict == "skipped" })
    XCTAssertTrue(results.contains { $0.invocationKey == "bad-date" && $0.verdict == "skipped" })
  }

  func testCreatedChildRemainsCreatedWhenTransactionRecheckFails() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-recheck")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "parent", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    var child = makeSession(id: "created-child", status: .created)
    child.parentSessionId = parent.sessionId
    try save(child, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertInvocation("changed", parent: parent.sessionId, child: child.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    let reconciler = SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      beforeTransaction: { try db.execute("UPDATE workflow_nested_invocations SET updated_at='2023-01-02T00:00:00Z' WHERE invocation_key='changed'") }
    )

    let result = try reconciler.run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)

    XCTAssertEqual(result.first?.verdict, "skipped")
    XCTAssertEqual(try store.load(sessionId: child.sessionId).session.status, .created)
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='changed'").first?["abandoned_at"])
  }

  func testHeldParentLockIsLiveAndCreatedReservationIsCancelled() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "parent", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    var child = makeSession(id: "reserved-child", status: .created)
    child.parentSessionId = parent.sessionId
    try save(child, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertInvocation("held", parent: parent.sessionId, child: child.sessionId, updated: "2023-01-01T00:00:00Z", db: db)
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: parent.sessionId)
    let held = try SessionAbandonedInvocationReconciler(registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      now: { Date(timeIntervalSince1970: 1_800_000_000) })
      .run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)
    XCTAssertEqual(held.first?.verdict, "live")
    owner.release(sessionId: parent.sessionId)

    let applied = try SessionAbandonedInvocationReconciler(registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      now: { Date(timeIntervalSince1970: 1_800_000_000) })
      .run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)

    XCTAssertEqual(applied.first?.verdict, "abandoned")
    let cancelled = try store.load(sessionId: child.sessionId).session
    XCTAssertEqual(cancelled.status, .cancelled)
    XCTAssertEqual(cancelled.failureReason, "reservation abandoned; reconciled by riela session reconcile")
  }

  func testSuspendedChildIsSkipped() throws {
    let root = try makeRielaCLITestTemporaryDirectory("abandoned-invocation-suspended")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var parent = makeSession(id: "parent", status: .completed)
    parent.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try save(parent, to: store)
    var child = makeSession(id: "suspended-child", status: .suspended)
    child.parentSessionId = parent.sessionId
    try save(child, to: store)
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertInvocation("suspended", parent: parent.sessionId, child: child.sessionId, updated: "2023-01-01T00:00:00Z", db: db)

    let result = try SessionAbandonedInvocationReconciler(registry: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      now: { Date(timeIntervalSince1970: 1_800_000_000) })
      .run(sessionStoreRoot: root.path, abandonedAfter: 24 * 3600, apply: true)

    XCTAssertEqual(result.first?.verdict, "skipped")
    XCTAssertEqual(try store.load(sessionId: child.sessionId).session.status, .suspended)
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='suspended'").first?["abandoned_at"])
  }

  private func save(_ session: WorkflowSession, to store: CLIWorkflowSessionStore) throws {
    try store.save(PersistedCLIWorkflowSession(workflowName: session.workflowId, session: session,
      resolution: WorkflowResolutionOptions(workflowName: session.workflowId)),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func insertInvocation(_ key: String, parent: String, child: String? = nil, updated: String, db: SQLiteDatabase) throws {
    let childId = child ?? "missing-\(key)"
    let json = "{\"parentSessionId\":\"\(parent)\",\"childSnapshot\":{\"session\":{\"sessionId\":\"\(childId)\"}}}"
    try db.execute("""
      INSERT INTO workflow_nested_invocations(invocation_key,reservation_json,created_at,updated_at)
      VALUES(?,jsonb(?),?,?)
      """, bindings: [.text(key), .text(json), .text(updated), .text(updated)])
  }

  private func makeSession(id: String, status: WorkflowSessionStatus) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowSession(workflowId: "workflow", sessionId: id, status: status, entryStepId: "entry",
      currentStepId: nil, createdAt: date, updatedAt: date, executions: [], rootSessionId: id)
  }

  private func databaseChecksum(root: URL) throws -> [String: String] {
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
    let tables = try db.query("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name")
    var checksums: [String: String] = [:]
    for table in tables {
      guard let name = table["name"] else { continue }
      var data = Data((table["sql"] ?? "").utf8)
      let columns = try db.tableColumnNames(name)
      let projections = columns.enumerated().map { index, column in
        let quotedColumn = "\"\(column.replacingOccurrences(of: "\"", with: "\"\""))\""
        return "CASE WHEN \(quotedColumn) IS NULL THEN '<null>' ELSE typeof(\(quotedColumn)) || ':' || quote(\(quotedColumn)) END AS c\(index)"
      }
      let query = "SELECT \(projections.joined(separator: ",")) FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
      let rows = try db.query(query)
        .map { row in
          columns.indices.map { row["c\($0)"] ?? "<null>" }.joined(separator: "|")
        }.sorted()
      rows.forEach { data.append(Data($0.utf8)) }
      checksums[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return checksums
  }
}
