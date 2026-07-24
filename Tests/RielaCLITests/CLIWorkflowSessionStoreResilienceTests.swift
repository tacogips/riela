import Foundation
import RielaSQLite
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class CLIWorkflowSessionStoreResilienceTests: XCTestCase {
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
        session_id, workflow_name, workflow_id, status, record_json, updated_at
      ) VALUES (?, ?, ?, ?, jsonb(?), ?)
      """,
      bindings: [
        .text(record.session.sessionId),
        .text(record.workflowName),
        .text(record.session.workflowId),
        .text(record.session.status.rawValue),
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
