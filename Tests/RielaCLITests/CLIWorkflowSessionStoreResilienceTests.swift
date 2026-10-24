import Foundation
import RielaSQLite
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class CLIWorkflowSessionStoreResilienceTests: XCTestCase {
  func testStrictReadDistinguishesValidCorruptAndAbsentRecordsWithoutWrites() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-strict-records")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let valid = makeRecord(sessionId: "valid-session", updatedAt: Date(timeIntervalSince1970: 2))
    let database = try fixtureDatabase(rootDirectory: root.path, createTable: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let validJSON = try XCTUnwrap(String(data: encoder.encode(valid), encoding: .utf8))
    try insertFixture(database, id: valid.session.sessionId, json: validJSON)
    try insertFixture(database, id: "shape-session", json: "{}")
    var mismatched = valid
    mismatched.session.sessionId = "different-session"
    let mismatchJSON = try XCTUnwrap(String(data: encoder.encode(mismatched), encoding: .utf8))
    try insertFixture(database, id: "mismatch-session", json: mismatchJSON)
    let before = try storedRows(database)

    XCTAssertEqual(try store.loadStrictReadOnly(sessionId: valid.session.sessionId), valid)
    assertStoreError(.notFound("session not found: absent-session")) {
      try store.loadStrictReadOnly(sessionId: "absent-session")
    }
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "shape-session") }
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "mismatch-session") }
    assertStoreError(.invalidSessionId("../invalid")) {
      try store.loadStrictReadOnly(sessionId: "../invalid")
    }
    XCTAssertEqual(try storedRows(database), before)
  }

  func testStrictReadTreatsNullAndMalformedJSONAsStorageFailure() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-strict-sql")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let database = try fixtureDatabase(rootDirectory: root.path, createTable: true)
    try database.execute(
      "INSERT INTO cli_workflow_sessions (session_id, record_json) VALUES (?, ?), (?, ?)",
      bindings: [.text("null-session"), .null, .text("malformed-session"), .text("{invalid")]
    )
    let before = try storedRows(database)
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "null-session") }
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "malformed-session") }
    XCTAssertEqual(try storedRows(database), before)
  }

  func testStrictReadDoesNotCreateMissingStoreOrTable() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-strict-absent")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    assertStoreError(.notFound("session not found: absent-session")) {
      try store.loadStrictReadOnly(sessionId: "absent-session")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    _ = try fixtureDatabase(rootDirectory: root.path, createTable: false)
    assertStoreError(.notFound("session not found: absent-session")) {
      try store.loadStrictReadOnly(sessionId: "absent-session")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testStrictReadPropagatesDatabaseAndQueryFailures() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-strict-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a SQLite database".utf8).write(to: URL(fileURLWithPath: path))
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "failure-session") }
    try FileManager.default.removeItem(atPath: path)
    let database = try fixtureDatabase(rootDirectory: root.path, createTable: true)
    try database.execute("DROP TABLE cli_workflow_sessions")
    try database.execute("CREATE TABLE cli_workflow_sessions (session_id TEXT PRIMARY KEY)")
    assertStorageFailure { try store.loadStrictReadOnly(sessionId: "failure-session") }
  }

  func testUnreadableRecordsAreSkippedWarnedAndPreserved() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-store-resilience")
    defer { try? FileManager.default.removeItem(at: root) }

    let warnings = CLIWorkflowSessionWarningRecorder()
    let store = CLIWorkflowSessionStore(
      rootDirectory: root.path,
      warningSink: warnings.record
    )
    let validRecord = makeRecord(
      sessionId: "resilient-workflow-session-2",
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    let unreadableRecord = makeRecord(
      sessionId: "resilient-workflow-session-7",
      updatedAt: Date(timeIntervalSince1970: 7)
    )
    try store.save(validRecord)
    try insertRecordMissingIncludeDeactivated(
      unreadableRecord,
      rootDirectory: root.path
    )

    let expectedWarning = "warning: skipped 1 unreadable CLI session record(s)"

    let allRecords = try store.loadAll()
    XCTAssertEqual(allRecords.map(\.session.sessionId), [validRecord.session.sessionId])
    XCTAssertEqual(warnings.take(), [expectedWarning])
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)

    let listedRecords = try store.list(limit: 10)
    XCTAssertEqual(listedRecords.map(\.session.sessionId), [validRecord.session.sessionId])
    XCTAssertEqual(warnings.take(), [expectedWarning])
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)

    do {
      _ = try store.load(sessionId: unreadableRecord.session.sessionId)
      XCTFail("an unreadable targeted record should be treated as not found")
    } catch let error as CLIWorkflowSessionStoreError {
      XCTAssertEqual(
        error,
        .notFound("session not found: \(unreadableRecord.session.sessionId)")
      )
    }
    XCTAssertEqual(warnings.take(), [expectedWarning])
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)

    assertStoreError(.notFound("session not found: \(unreadableRecord.session.sessionId)")) {
      try store.load(sessionId: unreadableRecord.session.sessionId, strictReadOnly: true)
    }
    XCTAssertEqual(warnings.take(), [expectedWarning])
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)

    XCTAssertEqual(
      try store.load(sessionId: validRecord.session.sessionId),
      validRecord
    )
    XCTAssertTrue(warnings.take().isEmpty)
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)

    let persistenceStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    let persistenceDatabase = try store.openPersistenceDatabase()
    try store.prepareRuntimePersistenceSchemas(
      in: persistenceDatabase,
      runtimeStore: persistenceStore
    )
    let runtimeStore = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydration: .family(of: validRecord.session.sessionId)
    )
    let seededValidSession = try await runtimeStore.loadSession(
      id: validRecord.session.sessionId
    )
    let skippedUnreadableSession = try await runtimeStore.loadSession(
      id: unreadableRecord.session.sessionId
    )
    XCTAssertNotNil(seededValidSession)
    XCTAssertNil(skippedUnreadableSession)
    let nextSession = try await runtimeStore.createSession(
      WorkflowSessionCreateInput(
        workflowId: "resilient-workflow",
        entryStepId: "start"
      )
    )
    XCTAssertEqual(nextSession.sessionId, "resilient-workflow-session-8")
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)
  }

  func testFreshRuntimeFailsClosedForUnreadableDatabase() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("fresh-runtime-corruption")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a SQLite database".utf8).write(to: URL(fileURLWithPath: path))
    do {
      _ = try await makeSeededProductionRuntimeStore(
        sessionStoreRoot: root.path,
        executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
        hydration: .none
      )
      XCTFail("corrupt store must prevent fresh execution")
    } catch {
      XCTAssertTrue(error is CLIWorkflowSessionStoreError)
    }
  }

  func testFreshRuntimeReadsOnlyIdentitiesAndPreservesHighWaterMarks() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("fresh-runtime-identities")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let canonical = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    let now = Date(timeIntervalSince1970: 2)
    var record = makeRecord(sessionId: "resilient-workflow-session-40", updatedAt: now)
    record.session.executions = [WorkflowStepExecution(
      executionId: "start-attempt-1-exec-80", stepId: "start", nodeId: "worker", attempt: 1,
      inputSnapshot: ["large": .string(String(repeating: "x", count: 512 * 1024))],
      createdAt: now, updatedAt: now
    )]
    try store.save(record)
    var reserved = record.session
    reserved.sessionId = "resilient-workflow-session-50"
    reserved.executions[0].executionId = "start-attempt-1-exec-90"
    let messages = (1...200).map { index in
      WorkflowMessageRecord(
        communicationId: "comm-\(String(format: "%06d", index))",
        workflowExecutionId: reserved.sessionId, fromStepId: "start", toStepId: "worker",
        sourceStepExecutionId: reserved.executions[0].executionId,
        payload: ["large": .string(String(repeating: "x", count: 16 * 1024))],
        lifecycleStatus: .delivered, createdOrder: index, createdAt: now
      )
    }
    try canonical.save(WorkflowRuntimePersistenceSnapshot(session: reserved, workflowMessages: messages))
    // A retired/unreadable CLI identity must still reserve its counter.
    var unreadable = record
    unreadable.session.sessionId = "resilient-workflow-session-60"
    try insertRecordMissingIncludeDeactivated(unreadable, rootDirectory: root.path)
    let database = try fixtureDatabase(rootDirectory: root.path)
    try database.execute("""
      CREATE TABLE session_retention_tombstones(
        session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, root_id TEXT NOT NULL, pruned_at TEXT NOT NULL,
        artifact_root TEXT NOT NULL, memory_root TEXT NOT NULL, payload_bytes INTEGER NOT NULL, cleanup_pending INTEGER NOT NULL)
      """)
    try database.execute("""
      INSERT INTO session_retention_tombstones VALUES(
        'resilient-workflow-session-65', 'resilient-workflow', 'resilient-workflow-session-65', '2026-01-01', '', '', 0, 0)
      """)
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "active-session")
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let start = ContinuousClock.now
    let runtime = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path, executionLocks: locks, hydration: .none
    )
    FileHandle.standardError.write(Data("fresh identity startup: \(start.duration(to: .now))\n".utf8))
    let unrelated = try await runtime.loadSession(id: record.session.sessionId)
    let reservedUnrelated = try await runtime.loadSession(id: reserved.sessionId)
    XCTAssertNil(unrelated)
    XCTAssertNil(reservedUnrelated)
    XCTAssertThrowsError(try locks.acquire(sessionId: "active-session"))
    let created = try await runtime.createSession(WorkflowSessionCreateInput(
      workflowId: "resilient-workflow", entryStepId: "start"
    ))
    XCTAssertEqual(created.sessionId, "resilient-workflow-session-66")
    let execution = try await runtime.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: created.sessionId, stepId: "start", nodeId: "worker", attempt: 1
    ))
    XCTAssertEqual(execution.executionId, "start-attempt-1-exec-91")
    let message = try await runtime.appendWorkflowMessage(WorkflowMessageAppendInput(
      workflowExecutionId: created.sessionId, fromStepId: "start", toStepId: "worker",
      sourceStepExecutionId: execution.executionId, payload: [:]
    ))
    XCTAssertEqual(message.communicationId, "comm-000201")
    XCTAssertEqual(try canonical.load(sessionId: reserved.sessionId).workflowMessages, messages)
    XCTAssertEqual(try store.load(sessionId: record.session.sessionId), record)
    let workflowRoot = root.appendingPathComponent("workflows")
    let workflowDirectory = workflowRoot.appendingPathComponent("fresh-command")
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "fresh-command", "entryStepId": "start",
      "defaults": {"maxLoopIterations": 1, "nodeTimeoutMs": 10000},
      "nodes": [{"id": "worker", "nodeFile": "worker.json"}],
      "steps": [{"id": "start", "nodeId": "worker", "role": "worker"}]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","nodeType":"command","modelFreeze":false,"command":{"executable":"/bin/echo","arguments":["{\"status\":\"done\"}"]}}"#
      .write(to: workflowDirectory.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    let command = await RielaCLIApplication().run([
      "workflow", "run", "fresh-command", "--workflow-definition-dir", workflowRoot.path,
      "--session-store", root.path, "--output", "json"
    ])
    XCTAssertEqual(command.exitCode, .success, command.stderr + command.stdout)
    XCTAssertEqual(try canonical.load(sessionId: reserved.sessionId).workflowMessages, messages)
    let fullStart = ContinuousClock.now
    let hydrated = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydration: .family(of: reserved.sessionId)
    )
    FileHandle.standardError.write(Data("legacy full hydration startup: \(fullStart.duration(to: .now))\n".utf8))
    let hydratedReserved = try await hydrated.loadSession(id: reserved.sessionId)
    XCTAssertEqual(hydratedReserved, reserved)
  }

  private func makeRecord(
    sessionId: String,
    updatedAt: Date
  ) -> PersistedCLIWorkflowSession {
    PersistedCLIWorkflowSession(
      workflowName: "resilient-workflow",
      session: WorkflowSession(
        workflowId: "resilient-workflow",
        sessionId: sessionId,
        status: .running,
        entryStepId: "start",
        currentStepId: "start",
        createdAt: updatedAt,
        updatedAt: updatedAt
      ),
      resolution: WorkflowResolutionOptions(
        workflowName: "resilient-workflow",
        scope: .project,
        workingDirectory: "/tmp/riela-session-store-resilience"
      )
    )
  }

  private func fixtureDatabase(rootDirectory: String, createTable: Bool = false) throws -> SQLiteDatabase {
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: rootDirectory)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let database = try SQLiteDatabase.open(path: path)
    if createTable {
      try database.execute("CREATE TABLE cli_workflow_sessions (session_id TEXT PRIMARY KEY, record_json TEXT, updated_at TEXT)")
    }
    return database
  }

  private func insertFixture(_ database: SQLiteDatabase, id: String, json: String) throws {
    try database.execute(
      "INSERT INTO cli_workflow_sessions (session_id, record_json, updated_at) VALUES (?, jsonb(?), ?)",
      bindings: [.text(id), .text(json), .text("2026-07-24T00:00:00.000Z")]
    )
  }

  private func storedRows(_ database: SQLiteDatabase) throws -> [SQLiteRow] {
    try database.query(
      "SELECT session_id, hex(record_json) AS record_bytes FROM cli_workflow_sessions ORDER BY session_id"
    )
  }

  private func assertStoreError(
    _ expected: CLIWorkflowSessionStoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> PersistedCLIWorkflowSession
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual(error as? CLIWorkflowSessionStoreError, expected, file: file, line: line)
    }
  }

  private func assertStorageFailure(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> PersistedCLIWorkflowSession
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard case let CLIWorkflowSessionStoreError.sqliteFailed(message) = error else {
        return XCTFail("expected storage failure, got \(error)", file: file, line: line)
      }
      XCTAssertLessThan(message.count, 256, file: file, line: line)
    }
  }

  private func insertRecordMissingIncludeDeactivated(
    _ record: PersistedCLIWorkflowSession,
    rootDirectory: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(record)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var resolution = try XCTUnwrap(object["resolution"] as? [String: Any])
    resolution.removeValue(forKey: "includeDeactivated")
    object["resolution"] = resolution
    let incompatibleData = try JSONSerialization.data(withJSONObject: object)
    let incompatibleJSON = try XCTUnwrap(
      String(data: incompatibleData, encoding: .utf8)
    )

    let database = try SQLiteDatabase.open(
      path: CLIWorkflowSessionStore.defaultDatabasePath(
        rootDirectory: rootDirectory
      )
    )
    try database.execute(
      """
      INSERT INTO cli_workflow_sessions (
        session_id, record_json, updated_at
      ) VALUES (?, jsonb(?), ?)
      """,
      bindings: [
        .text(record.session.sessionId),
        .text(incompatibleJSON),
        .text("2026-07-24T00:00:00.000Z")
      ]
    )
  }

  private func rawRecordCount(rootDirectory: String) throws -> Int {
    let database = try SQLiteDatabase.open(
      path: CLIWorkflowSessionStore.defaultDatabasePath(
        rootDirectory: rootDirectory
      ),
      mode: .readOnly,
      options: .readOnlyDefault
    )
    let row = try XCTUnwrap(
      database.query(
        "SELECT COUNT(*) AS record_count FROM cli_workflow_sessions"
      ).first
    )
    return try XCTUnwrap(Int(row.string("record_count")))
  }
}

private final class CLIWorkflowSessionWarningRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  func record(_ message: String) {
    lock.lock()
    messages.append(message)
    lock.unlock()
  }

  func take() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let result = messages
    messages = []
    return result
  }
}
