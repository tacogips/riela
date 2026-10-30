import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class RuntimePayloadFragmentWriterTests: XCTestCase {
  func testDeterminismEscapeAndSmallPayload() throws {
    let small = #"{"inputSnapshot":{"x":"small"}}"#
    XCTAssertEqual(try RuntimePayloadFragmentEncoder.reduce(fullJSON: small).json, small)
    XCTAssertTrue(try RuntimePayloadFragmentEncoder.reduce(fullJSON: small).fragments.isEmpty)
    let escaped = #"{"inputSnapshot":{"$rielaPayloadRef":"literal","x":""#
      + String(repeating: "x", count: 2048) + #""}}"#
    XCTAssertEqual(try RuntimePayloadFragmentEncoder.reduce(fullJSON: escaped).json, escaped)
    let large = #"{"inputSnapshot":{"x":""# + String(repeating: "x", count: 2048) + #""}}"#
    let first = try RuntimePayloadFragmentEncoder.reduce(fullJSON: large)
    XCTAssertEqual(first, try RuntimePayloadFragmentEncoder.reduce(fullJSON: large))
    XCTAssertFalse(first.fragments.isEmpty)
    let reducedObject = try JSONDecoder().decode(JSONObject.self, from: Data(first.json.utf8))
    XCTAssertEqual(reducedObject[RuntimePayloadFragmentEncoder.markerKey], .array(first.fragments.map { .string($0.digest) }))
    XCTAssertEqual(first.fragments.map(\.digest), first.fragments.map(\.digest).sorted())
  }

  func testTerminalSaveKeepsFragmentsAndSharesThem() throws {
    for initialTerminal in [false, true] {
      let root = try makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let executions = [execution("one", date), execution("two", date)]
      var session = WorkflowSession(
        workflowId: "workflow", sessionId: "session", status: initialTerminal ? .completed : .running,
        entryStepId: "step", createdAt: date, updatedAt: date, executions: executions
      )
      try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true) {
        try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
        let db = try database(root)
        let before = try fragmentRows(db)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(try db.query("SELECT * FROM workflow_runtime_payload_refs").count, 2)
        if !initialTerminal {
          session.status = .completed
          session.updatedAt = date.addingTimeInterval(1)
          try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
        }
        XCTAssertEqual(try fragmentRows(db), before)
        for row in before {
          let json = try XCTUnwrap(row["json"])
          XCTAssertEqual(SQLiteWorkflowRuntimePersistenceStore.sha256(json), row["digest"])
        }
        XCTAssertTrue(try db.query(
          "SELECT r.digest FROM workflow_runtime_payload_refs r LEFT JOIN workflow_runtime_payloads p "
            + "ON p.root_session_id=r.root_session_id AND p.digest=r.digest WHERE p.digest IS NULL"
        ).isEmpty)
      }
    }
  }

  func testFullPayloadModeWritesFullPayloadAndNestedWritesReduced() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let item = execution("exec", date)
    let session = WorkflowSession(workflowId: "workflow", sessionId: "session", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [item])
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(false) {
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    }
    let db = try database(root)
    XCTAssertTrue(try db.query("SELECT * FROM workflow_runtime_payload_refs").isEmpty)
    let full = try store.payloadJSON(item)
    XCTAssertEqual(try db.query("SELECT json(bytes) AS json FROM workflow_runtime_payloads").first?["json"], full)
    var child = session
    child.status = .created
    child.sessionId = "child"
    child.parentSessionId = "session"
    child.rootSessionId = "session"
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: "session", parentStepId: "step", resumeStepId: "resume",
      sourceStepExecutionId: "exec", branchId: "branch", childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true) {
      _ = try store.reserveNestedInvocation(reservation)
    }
    let reduced = try RuntimePayloadFragmentEncoder.reduce(fullJSON: full)
    XCTAssertEqual(try db.query("SELECT digest FROM workflow_nested_invocation_refs WHERE ordinal=0").first?["digest"], reduced.digest)
    XCTAssertEqual(try db.query("SELECT digest FROM workflow_runtime_payload_refs WHERE root_session_id='session' AND parent_digest=?", bindings: [.text(reduced.digest)]).count, reduced.fragments.count)
  }

  func testDefaultWritesReducedPayloads() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(workflowId: "workflow", sessionId: "session", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution("exec", date)])
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let db = try database(root)
    XCTAssertFalse(try db.query("SELECT * FROM workflow_runtime_payload_refs").isEmpty)
    let rows = try db.query("SELECT json(p.bytes) AS json FROM workflow_runtime_payloads p "
      + "JOIN workflow_runtime_executions e ON e.root_session_id=p.root_session_id AND e.payload_digest=p.digest")
    XCTAssertTrue(try XCTUnwrap(rows.first?["json"]).contains("_rielaPayloadRefs"))
  }

  private func execution(_ id: String, _ date: Date) -> WorkflowStepExecution {
    WorkflowStepExecution(executionId: id, stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: ["shared": .string(String(repeating: "x", count: 2048))],
      status: .completed, createdAt: date, updatedAt: date)
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func database(_ root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
  }

  private func fragmentRows(_ db: SQLiteDatabase) throws -> [SQLiteRow] {
    try db.query(
      "SELECT DISTINCT p.digest, json(p.bytes) AS json, p.byte_count FROM workflow_runtime_payloads p "
        + "JOIN workflow_runtime_payload_refs r ON r.root_session_id=p.root_session_id AND r.digest=p.digest ORDER BY p.digest"
    )
  }
}
