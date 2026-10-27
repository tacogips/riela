import Foundation
import RielaCore
import RielaSQLite
import XCTest

final class SQLiteRuntimeAutoVacuumTests: XCTestCase {
  func testRuntimeStoreFirstOpenUsesIncrementalAutoVacuumAndCanReclaimPages() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-runtime-autovacuum-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "vacuum", sessionId: "vacuum-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))

    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path, options: .writableRuntimeStoreDefault)
    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
    XCTAssertEqual(try database.query("PRAGMA journal_mode").first?["journal_mode"], "wal")

    try database.execute("CREATE TABLE reclaim_test (payload BLOB NOT NULL)")
    let payload = Data(repeating: 0x5A, count: 4_096)
    for _ in 0..<128 {
      try database.execute("INSERT INTO reclaim_test(payload) VALUES (?)", bindings: [.blob(payload)])
    }
    try database.execute("DELETE FROM reclaim_test")
    let freePagesBefore = try XCTUnwrap(Int(database.query("PRAGMA freelist_count").first?[
      "freelist_count"
    ] ?? "0"))
    XCTAssertGreaterThan(freePagesBefore, 0)

    _ = try database.query("PRAGMA incremental_vacuum(100)")
    let freePagesAfter = try XCTUnwrap(Int(database.query("PRAGMA freelist_count").first?[
      "freelist_count"
    ] ?? "0"))
    XCTAssertLessThan(freePagesAfter, freePagesBefore)
  }
}
