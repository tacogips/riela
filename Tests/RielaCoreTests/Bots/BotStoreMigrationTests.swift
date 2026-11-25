import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class BotStoreMigrationTests: XCTestCase {
  private let tableNames = [
    "bots", "bot_session_links", "bot_list_state", "bot_suggestions", "bot_job_runs",
    "bot_memory_changes", "activity_events", "activity_state", "activity_requests",
    "provider_instances", "provider_reports"
  ]

  func testBotWriteMigratesGeneration12AndPreservesSnapshot() throws {
    try withStore { store, session in
      try SQLiteRuntimeSchemaMigrationTests.createHistoricalStore(
        path: store.databasePath, session: session, generation: 12
      )
      let historical = try SQLiteDatabase.open(path: store.databasePath, mode: .strictReadOnly)
      XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: historical), 12)
      let original = try historical.query("SELECT workflow_execution_id, json(session_json) FROM workflow_runtime_snapshots")
      XCTAssertEqual(original.count, 1)
      for table in tableNames {
        XCTAssertFalse(try historical.tableExists(table), table)
      }

      try store.write { database in
        XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: database), 13)
        XCTAssertEqual(
          try database.query("SELECT workflow_execution_id, json(session_json) FROM workflow_runtime_snapshots"), original
        )
        try assertBotTables(in: database)
      }
    }
  }

  func testFreshRuntimeStoreCreatesBotTables() throws {
    try withStore { store, session in
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot)
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
      let database = try SQLiteDatabase.open(path: store.databasePath, mode: .strictReadOnly)
      XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: database), 13)
      try assertBotTables(in: database)
    }
  }

  private func assertBotTables(in database: SQLiteDatabase) throws {
    for table in tableNames {
      XCTAssertTrue(try database.tableExists(table), table)
    }
  }

  private func withStore(_ body: (BotStore, WorkflowSession) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    try body(BotStore(sessionStoreRoot: root.path), session)
  }
}
