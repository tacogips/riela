import Foundation
import RielaSQLite
import XCTest

@testable import RielaCore

final class SQLiteWorkflowStartupIdentityTests: XCTestCase {
  private func fixture(_ body: (SQLiteDatabase) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try SQLiteDatabase.open(path: root.appendingPathComponent("store.sqlite").path)
    try db.execute(
      "CREATE TABLE cli_workflow_sessions(session_id TEXT PRIMARY KEY, record_json BLOB NOT NULL, workflow_id TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.session.workflowId')) STORED)"
    )
    try body(db)
  }

  private func insert(_ db: SQLiteDatabase, suffix: Int, payloadBytes: Int = 0) throws {
    let value: [String: Any] = [
      "session": [
        "workflowId": "fixture",
        "executions": [
          [
            "executionId": "start-attempt-1-exec-\(suffix)",
            "inputSnapshot": String(repeating: "x", count: payloadBytes)
          ]
        ]
      ]
    ]
    let text = String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    try db.execute(
      "INSERT OR REPLACE INTO cli_workflow_sessions VALUES (?,jsonb(?))",
      bindings: [.text("fixture-session-7"), .text(text)])
  }

  func testLegacyBackfillAndPayloadReplacementInvalidateOnlyAffectedIdentity() throws {
    try fixture { db in
      try insert(db, suffix: 80, payloadBytes: 2 * 1024 * 1024)
      XCTAssertFalse(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli))
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      XCTAssertTrue(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli))
      XCTAssertEqual(
        try SQLiteWorkflowStartupIdentities.load(db, source: .cli).first?.executionIds,
        ["start-attempt-1-exec-80"])
      try insert(db, suffix: 999)
      XCTAssertFalse(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli))
      XCTAssertThrowsError(try SQLiteWorkflowStartupIdentities.load(db, source: .cli))
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      XCTAssertEqual(
        try SQLiteWorkflowStartupIdentities.load(db, source: .cli).first?.executionIds,
        ["start-attempt-1-exec-999"])
      let plan = try db.query(
        "EXPLAIN QUERY PLAN SELECT 1 FROM cli_workflow_sessions AS s WHERE NOT EXISTS (SELECT 1 FROM cli_startup_identities AS i WHERE i.session_id=s.session_id) LIMIT 1"
      )
      XCTAssertTrue(
        plan.contains {
          $0["detail"]?.contains("COVERING INDEX sqlite_autoindex_cli_workflow_sessions") == true
        })
    }
  }

  func testLostWriterLineageRebuildsInsteadOfTrustingOldProjection() throws {
    try fixture { db in
      try insert(db, suffix: 1)
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      try db.execute("DROP TRIGGER cli_startup_identities_update")
      try db.execute(
        "UPDATE cli_workflow_sessions SET record_json=jsonb_set(record_json,'$.session.executions[0].executionId','start-attempt-1-exec-1234')"
      )
      XCTAssertFalse(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli))
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      XCTAssertEqual(
        try SQLiteWorkflowStartupIdentities.load(db, source: .cli).first?.executionIds,
        ["start-attempt-1-exec-1234"])
    }
  }

  func testFutureProjectionVersionAndInvalidIDsFailClosed() throws {
    try fixture { db in
      try insert(db, suffix: 2)
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      try db.execute("UPDATE cli_startup_identities SET execution_ids_json='[42]'")
      XCTAssertThrowsError(try SQLiteWorkflowStartupIdentities.load(db, source: .cli))
      try db.execute("UPDATE workflow_startup_identity_schema SET version=2")
      XCTAssertThrowsError(try SQLiteWorkflowStartupIdentities.ensureSchema(db, source: .cli))
      XCTAssertThrowsError(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli))
    }
  }

  func testDeleteInvalidatesProjectionAndRollbackKeepsBothGenerations() throws {
    try fixture { db in
      try insert(db, suffix: 7)
      try db.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .cli) }
      enum Stop: Error { case rollback }
      XCTAssertThrowsError(
        try db.transaction { tx in
          try tx.execute("DELETE FROM cli_workflow_sessions")
          throw Stop.rollback
        })
      XCTAssertEqual(try SQLiteWorkflowStartupIdentities.load(db, source: .cli).count, 1)
      try db.execute("DELETE FROM cli_workflow_sessions")
      XCTAssertTrue(try SQLiteWorkflowStartupIdentities.load(db, source: .cli).isEmpty)
    }
  }
}
