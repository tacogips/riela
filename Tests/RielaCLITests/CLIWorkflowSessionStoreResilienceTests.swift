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
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    try await seedRuntimeStoreFromPersistedCLIState(
      runtimeStore,
      sessionStoreRoot: root.path
    )
    let seededValidSession = try await runtimeStore.loadSession(
      id: validRecord.session.sessionId
    )
    let skippedUnreadableSession = try await runtimeStore.loadSession(
      id: unreadableRecord.session.sessionId
    )
    XCTAssertNotNil(seededValidSession)
    XCTAssertNil(skippedUnreadableSession)
    XCTAssertEqual(try rawRecordCount(rootDirectory: root.path), 2)
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
