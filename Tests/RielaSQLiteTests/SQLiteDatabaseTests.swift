import Foundation
import RielaSQLite
import XCTest

final class SQLiteDatabaseTests: XCTestCase {
  func testWritableOpenAppliesWALBusyTimeoutAndJSONBProbe() throws {
    let database = try SQLiteDatabase.open(path: temporaryDatabasePath())

    let journalMode = try database.query("PRAGMA journal_mode").first?["journal_mode"]
    let foreignKeys = try database.query("PRAGMA foreign_keys").first?["foreign_keys"]
    let busyTimeout = try database.query("PRAGMA busy_timeout").first?["timeout"]
    let jsonStorage = try database.query("SELECT typeof(jsonb('{}')) AS storage_type").first?["storage_type"]

    XCTAssertEqual(journalMode, "wal")
    XCTAssertEqual(foreignKeys, "1")
    XCTAssertEqual(busyTimeout, "3000")
    XCTAssertEqual(jsonStorage, "blob")
  }

  func testForeignKeysCanBeDisabledForCompatibility() throws {
    let database = try SQLiteDatabase.open(
      path: temporaryDatabasePath(),
      options: SQLiteOpenOptions(enableForeignKeys: false)
    )

    let foreignKeys = try database.query("PRAGMA foreign_keys").first?["foreign_keys"]

    XCTAssertEqual(foreignKeys, "0")
  }

  func testFTS5CapabilityProbesDoNotLeaveTempTables() throws {
    let database = try SQLiteDatabase.open(path: temporaryDatabasePath())

    try database.requireFTS5Available()
    try database.requireFTS5TrigramAvailable()

    let probeTables = try database.query(
      "SELECT name FROM sqlite_temp_master WHERE type = 'table' AND name LIKE 'riela_fts5_probe_%'"
    )
    XCTAssertEqual(probeTables, [])
  }

  func testExecuteQueryBindingsAndTransactionRollback() throws {
    let database = try SQLiteDatabase.open(path: temporaryDatabasePath())
    try database.execute("CREATE TABLE records (id TEXT PRIMARY KEY, value INTEGER NOT NULL)")
    try database.execute("INSERT INTO records (id, value) VALUES (?, ?)", bindings: [.text("kept"), .int(1)])

    do {
      try database.transaction { db in
        try db.execute("INSERT INTO records (id, value) VALUES (?, ?)", bindings: [.text("rolled-back"), .int(2)])
        throw SQLiteError(operation: .execute, code: nil, message: "forced rollback")
      }
      XCTFail("transaction should throw")
    } catch let error as SQLiteError {
      XCTAssertEqual(error.message, "forced rollback")
    }

    let rows = try database.query("SELECT id, value FROM records ORDER BY id")

    XCTAssertEqual(rows.map { $0["id"] }, ["kept"])
    XCTAssertEqual(rows.map { $0["value"] }, ["1"])
  }

  private func temporaryDatabasePath() -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-sqlite-tests-\(UUID().uuidString)", isDirectory: true)
    return root.appendingPathComponent("database.sqlite").path
  }
}
