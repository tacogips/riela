import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class WorkStoreFirstOpenerAutoVacuumTests: XCTestCase {
  func testWorkStoreAsFirstOpenerEnablesIncrementalAutoVacuum() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    try store.saveIntent(sampleIntent())

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
    XCTAssertEqual(try database.query("PRAGMA journal_mode").first?["journal_mode"], "wal")
  }

  func testWorkStoreLeavesExistingNoneDatabaseUnchanged() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let existing = try SQLiteDatabase.open(path: store.databasePath, options: .writableDefault)
    try existing.execute("CREATE TABLE preexisting (id INTEGER PRIMARY KEY)")

    try store.saveIntent(sampleIntent())

    let reopened = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try reopened.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")
  }

  private func sampleIntent() -> Intent {
    Intent(
      id: IntentID("intent-autovacuum"), title: "First opener", instruction: "Persist this intent.",
      acceptance: [AcceptanceCriterion(id: "criterion", statement: "the runtime database opens")], origin: .cli
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-work-first-opener-\(UUID().uuidString)", isDirectory: true)
  }
}
