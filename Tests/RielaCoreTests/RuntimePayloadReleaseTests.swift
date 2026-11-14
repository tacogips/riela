import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class RuntimePayloadReleaseTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_700_000_000)
  private func value(_ char: String) -> String { String(repeating: char, count: 2048) }
  private func execution(_ id: String, _ values: [String: String]) -> WorkflowStepExecution {
    WorkflowStepExecution(executionId: id, stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: values.mapValues { .string($0) }, status: .completed, createdAt: date, updatedAt: date)
  }
  private func session(_ id: String = "root", _ items: [WorkflowStepExecution]) -> WorkflowSession {
    WorkflowSession(workflowId: "workflow", sessionId: id, status: .running, entryStepId: "step",
      createdAt: date, updatedAt: date, executions: items)
  }
  private func withStore(_ body: (SQLiteWorkflowRuntimePersistenceStore, SQLiteDatabase) throws -> Void) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true) {
      // Initialize the schema before opening the inspection connection.
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session("setup", [])))
      let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
        mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
      try body(store, db)
    }
  }
  private func save(_ session: WorkflowSession, _ store: SQLiteWorkflowRuntimePersistenceStore) throws {
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
  }
  private func digest(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    return SQLiteWorkflowRuntimePersistenceStore.sha256(try XCTUnwrap(String(data: data, encoding: .utf8)))
  }
  private func has(_ value: String, _ root: String, _ db: SQLiteDatabase) throws -> Bool {
    try !db.query("SELECT digest FROM workflow_runtime_payloads WHERE root_session_id=? AND digest=?",
      bindings: [.text(root), .text(digest(value))]).isEmpty
  }
  private func check(_ root: String, _ db: SQLiteDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
    let predicates = [
      "SELECT count(*) AS n FROM workflow_runtime_payload_refs f WHERE f.root_session_id=? "
        + "AND NOT EXISTS (SELECT 1 FROM workflow_runtime_payloads p WHERE p.root_session_id=f.root_session_id AND p.digest=f.parent_digest)",
      "SELECT count(*) AS n FROM workflow_runtime_payload_refs f WHERE f.root_session_id=? AND NOT EXISTS (SELECT 1 FROM workflow_runtime_payloads p WHERE p.root_session_id=f.root_session_id AND p.digest=f.digest)",
      "SELECT count(*) AS n FROM workflow_runtime_payloads p WHERE p.root_session_id=? "
        + "AND NOT EXISTS (SELECT 1 FROM workflow_runtime_executions e WHERE e.root_session_id=p.root_session_id AND e.payload_digest=p.digest) "
        + "AND NOT EXISTS (SELECT 1 FROM workflow_nested_invocation_refs n WHERE n.root_session_id=p.root_session_id AND n.digest=p.digest) "
        + "AND NOT EXISTS (SELECT 1 FROM workflow_runtime_payload_refs f WHERE f.root_session_id=p.root_session_id AND f.digest=p.digest)"
    ]
    for sql in predicates {
      XCTAssertEqual(try db.query(sql, bindings: [.text(root)]).first?["n"], "0", file: file, line: line)
    }
  }
  func testRewrittenExecutionReleasesOnlyItsUniqueFragment() throws {
    try withStore { store, db in
      var current = session("root", [execution("one", ["shared": value("s"), "unique": value("a")]),
                             execution("two", ["shared": value("s"), "unique": value("b")])])
      try save(current, store)
      let old = try XCTUnwrap(db.query("SELECT payload_digest FROM workflow_runtime_executions WHERE root_session_id='root' AND ordinal=0").first?["payload_digest"])
      current.executions[0] = execution("one", ["shared": value("s"), "unique": value("c")])
      try save(current, store)
      let now = try XCTUnwrap(db.query("SELECT payload_digest FROM workflow_runtime_executions WHERE root_session_id='root' AND ordinal=0").first?["payload_digest"])
      XCTAssertNotEqual(old, now)
      XCTAssertTrue(try db.query("SELECT digest FROM workflow_runtime_payloads WHERE root_session_id='root' AND digest=?", bindings: [.text(old)]).isEmpty)
      XCTAssertFalse(try has(value("a"), "root", db))
      for char in ["s", "b", "c"] { XCTAssertTrue(try has(value(char), "root", db)) }
      try check("root", db)
      XCTAssertEqual(try store.load(sessionId: "root").session, current)
    }
  }
  func testTruncationReleasesFragmentsOfRemovedExecutions() throws {
    try withStore { store, db in
      var current = session("root", [execution("one", ["shared": value("s"), "unique": value("a")]),
        execution("two", ["shared": value("s"), "unique": value("b")]), execution("three", ["unique": value("c")])])
      try save(current, store)
      current.executions.removeLast(2)
      try save(current, store)
      for char in ["s", "a"] { XCTAssertTrue(try has(value(char), "root", db)) }
      for char in ["b", "c"] { XCTAssertFalse(try has(value(char), "root", db)) }
      try check("root", db)
    }
  }
  func testTerminalRunEndReleaseKeepsReferencedFragments() throws {
    try withStore { store, db in
      var current = session("root", [execution("one", ["shared": value("s")])])
      try save(current, store)
      let sql = "SELECT DISTINCT p.digest, json(p.bytes) AS json, p.byte_count FROM workflow_runtime_payloads p "
        + "JOIN workflow_runtime_payload_refs f ON f.root_session_id=p.root_session_id AND f.digest=p.digest "
        + "WHERE p.root_session_id='root' ORDER BY p.digest"
      let before = try db.query(sql)
      XCTAssertFalse(before.isEmpty)
      current.status = .completed
      try save(current, store)
      XCTAssertEqual(try db.query(sql), before)
      try check("root", db)
      XCTAssertEqual(try store.load(sessionId: "root").session, current)
    }
  }
  func testSweepRemovesLeakedRefsAndFragments() throws {
    try withStore { store, db in
      try save(session("root", [execution("one", ["shared": value("s")])]), store)
      let json = "\"leaked\""
      let leak = SQLiteWorkflowRuntimePersistenceStore.sha256(json)
      try db.execute("INSERT INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) VALUES('root',?,jsonb(?),?)", bindings: [.text(leak), .text(json), .int(Int64(json.utf8.count))])
      for id in [leak, try digest(value("s"))] {
        try db.execute("INSERT INTO workflow_runtime_payload_refs(root_session_id,parent_digest,digest) VALUES('root','missing-parent',?)", bindings: [.text(id)])
      }
      XCTAssertGreaterThanOrEqual(try store.releaseUnreferencedPayloads(rootSessionId: "root"), Int64(json.utf8.count))
      XCTAssertTrue(try db.query("SELECT digest FROM workflow_runtime_payloads WHERE root_session_id='root' AND digest=?", bindings: [.text(leak)]).isEmpty)
      XCTAssertTrue(try db.query("SELECT digest FROM workflow_runtime_payload_refs WHERE root_session_id='root' AND parent_digest='missing-parent'").isEmpty)
      XCTAssertTrue(try has(value("s"), "root", db))
      try check("root", db)
    }
  }
  func testReleaseIsIsolatedPerRoot() throws {
    try withStore { store, db in
      var a = session("A", [execution("a", ["shared": value("s")])])
      try save(a, store)
      try save(session("B", [execution("b", ["shared": value("s")])]), store)
      let payloads = try db.query("SELECT digest, hex(bytes) AS bytes, byte_count FROM workflow_runtime_payloads WHERE root_session_id='B' ORDER BY digest")
      let refs = try db.query("SELECT parent_digest,digest FROM workflow_runtime_payload_refs WHERE root_session_id='B' ORDER BY parent_digest,digest")
      a.executions = []
      try save(a, store)
      _ = try store.releaseUnreferencedPayloads(rootSessionId: "A")
      XCTAssertFalse(try has(value("s"), "A", db))
      XCTAssertEqual(try db.query("SELECT digest, hex(bytes) AS bytes, byte_count FROM workflow_runtime_payloads WHERE root_session_id='B' ORDER BY digest"), payloads)
      XCTAssertEqual(try db.query("SELECT parent_digest,digest FROM workflow_runtime_payload_refs WHERE root_session_id='B' ORDER BY parent_digest,digest"), refs)
      try check("A", db)
      try check("B", db)
    }
  }
  func testNestedRefReplacementKeepsFragmentsSharedWithRootRows() throws {
    try withStore { store, db in
      try save(session("root", [execution("root-exec", ["shared": value("s")])]), store)
      var child = session("child", [execution("child-exec", ["shared": value("s"), "unique": value("a")])])
      child.status = .created
      child.parentSessionId = "root"
      child.rootSessionId = "root"
      let reservation = WorkflowNestedInvocationReservation(parentSessionId: "root", parentStepId: "step", resumeStepId: "resume",
        sourceStepExecutionId: "root-exec", branchId: "branch", childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
      _ = try store.reserveNestedInvocation(reservation)
      let key = try XCTUnwrap(db.query("SELECT invocation_key FROM workflow_nested_invocations").first?["invocation_key"])
      for (new, gone) in [("b", false), ("c", true)] {
        child.executions = [execution("child-exec", ["shared": value("s"), "unique": value(new)])]
        try db.transaction { transaction in
          _ = try store.persistNestedReferences(WorkflowRuntimePersistenceSnapshot(session: child), invocationKey: key, role: "reservation", in: transaction)
        }
        XCTAssertTrue(try has(value("s"), "root", db))
        XCTAssertTrue(try has(value("a"), "root", db))
        XCTAssertTrue(try has(value(new), "root", db))
        XCTAssertEqual(try has(value("b"), "root", db), !gone)
        try check("root", db)
      }
    }
  }
}
