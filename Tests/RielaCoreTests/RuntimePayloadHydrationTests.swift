import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class RuntimePayloadHydrationTests: XCTestCase {
  func testNestedReducedSnapshotsRoundTrip() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(executionId: "child-exec", stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: ["shared": .string(String(repeating: "x", count: 2048))],
      status: .completed, createdAt: date, updatedAt: date)
    let child = WorkflowSession(workflowId: "child", sessionId: "child", status: .created, entryStepId: "step",
      createdAt: date, updatedAt: date, executions: [execution], parentSessionId: "parent", rootSessionId: "parent")
    let reservation = WorkflowNestedInvocationReservation(parentSessionId: "parent", parentStepId: "step",
      resumeStepId: "resume", sourceStepExecutionId: "source", branchId: "branch",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true) {
      try store.save(WorkflowRuntimePersistenceSnapshot(session: child))
      _ = try store.reserveNestedInvocation(reservation)
      XCTAssertEqual(try store.nestedInvocationRecord(reservation)?.reservation, reservation)
      let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
        mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
      let shared = try db.query("""
        SELECT COUNT(*) AS count FROM workflow_runtime_payload_refs f
        JOIN workflow_runtime_executions e ON e.root_session_id=f.root_session_id AND e.payload_digest=f.parent_digest
        JOIN workflow_nested_invocation_refs n ON n.root_session_id=e.root_session_id AND n.digest=e.payload_digest
        WHERE e.workflow_execution_id='child' AND n.role='reservation'
        """).first?["count"]
      XCTAssertGreaterThan(Int(shared ?? "0") ?? 0, 0)
      var terminal = child
      terminal.status = .completed
      let snapshot = WorkflowRuntimePersistenceSnapshot(session: terminal)
      _ = try store.recordNestedChildTerminal(reservation: reservation, terminalSnapshot: snapshot)
      XCTAssertEqual(try store.nestedInvocationRecord(reservation)?.childTerminalSnapshot, snapshot)
    }
  }

  func testRoundTripAndCorruption() throws {
    for status: WorkflowSessionStatus in [.running, .completed] {
      let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let execution = WorkflowStepExecution(executionId: "exec", stepId: "step", nodeId: "node", attempt: 1,
        inputSnapshot: ["shared": .string(String(repeating: "x", count: 2048))],
        status: .completed, createdAt: date, updatedAt: date)
      let session = WorkflowSession(workflowId: "workflow", sessionId: "session", status: status,
        entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution])
      try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true) {
        try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
      }
      XCTAssertEqual(try store.load(sessionId: "session").session, session)
      XCTAssertEqual(try store.loadWebSessionDetail(sessionId: "session", messageLimit: 10).session.executions, session.executions)
      let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
        mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
      let digest = try XCTUnwrap(db.query("SELECT digest FROM workflow_runtime_payload_refs LIMIT 1").first?["digest"])
      try db.execute("UPDATE workflow_runtime_payloads SET bytes=jsonb('{}') WHERE digest=?", bindings: [.text(digest)])
      XCTAssertThrowsError(try store.load(sessionId: "session")) {
        XCTAssertTrue(String(describing: $0).contains("runtime payload fragment missing or corrupt"))
      }
      try db.execute("DELETE FROM workflow_runtime_payloads WHERE digest=?", bindings: [.text(digest)])
      XCTAssertThrowsError(try store.load(sessionId: "session")) {
        XCTAssertTrue(String(describing: $0).contains("runtime payload fragment missing or corrupt"))
      }
    }
  }

  func testFullAndLegacyInlineSnapshotsWithMarkerText() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(executionId: "exec", stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: ["data": .string(String(repeating: "x", count: 2048))],
      status: .completed, streamedResponseText: "_rielaPayloadRefs", createdAt: date, updatedAt: date)
    let session = WorkflowSession(workflowId: "workflow", sessionId: "session", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution])
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(false) {
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    }
    XCTAssertEqual(try store.load(sessionId: "session").session, session)
    let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
    let json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
    try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(session.sessionId)])
    XCTAssertEqual(try store.load(sessionId: "session").session, session)
  }

  func testRecursiveExpansion() throws {
    let original = #"{"output":{"$rielaPayloadRef":"literal"},"inputSnapshot":{"value":""#
      + String(repeating: "x", count: 2048) + #""}}"#
    let reduced = try RuntimePayloadFragmentEncoder.reduce(fullJSON: original)
    var execution = try JSONDecoder().decode(JSONValue.self, from: Data(reduced.json.utf8))
    try RuntimePayloadFragmentEncoder.expand(&execution, fragments: Dictionary(uniqueKeysWithValues: reduced.fragments.map { ($0.digest, $0.json) }))
    XCTAssertEqual(execution, try JSONDecoder().decode(JSONValue.self, from: Data(original.utf8)))
    let leaf = #""nested""#
    let leafDigest = SQLiteWorkflowRuntimePersistenceStore.sha256(leaf)
    let parent = #"{"child":{"$rielaPayloadRef":""# + leafDigest + #""}}"#
    let parentDigest = SQLiteWorkflowRuntimePersistenceStore.sha256(parent)
    var nested: JSONValue = .object([
      "inputSnapshot": .object(["$rielaPayloadRef": .string(parentDigest)]),
      "_rielaPayloadRefs": .array([.string(parentDigest), .string(leafDigest)])
    ])
    try RuntimePayloadFragmentEncoder.expand(&nested, fragments: [parentDigest: parent, leafDigest: leaf])
    XCTAssertEqual(nested, .object(["inputSnapshot": .object(["child": .string("nested")])]))
  }
}
