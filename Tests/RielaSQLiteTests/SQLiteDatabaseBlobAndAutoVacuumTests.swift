import Foundation
import RielaSQLite
import XCTest

final class SQLiteDatabaseBlobAndAutoVacuumTests: XCTestCase {
  func testBlobBindingAndRowDataPreserveBytesAndText() throws {
    let database = try SQLiteDatabase.open(path: temporaryDatabasePath())
    try database.execute("CREATE TABLE values_table (payload BLOB, empty_payload BLOB, text_value TEXT)")
    let bytes = Data([0, 255, 0])
    try database.execute(
      "INSERT INTO values_table (payload, empty_payload, text_value) VALUES (?, ?, ?)",
      bindings: [.blob(bytes), .blob(Data()), .text("kept text")]
    )

    let row = try XCTUnwrap(database.query("SELECT payload, empty_payload, text_value FROM values_table").first)
    XCTAssertEqual(row.data("payload"), bytes)
    XCTAssertEqual(row.data("empty_payload"), Data())
    XCTAssertEqual(row.data("text_value"), Data("kept text".utf8))
    XCTAssertEqual(row["text_value"], "kept text")
  }

  func testIncrementalAutoVacuumAppliesOnlyToNewEmptyFiles() throws {
    let runtimePath = temporaryDatabasePath()
    let runtime = try SQLiteDatabase.open(path: runtimePath, options: .writableRuntimeStoreDefault)
    XCTAssertEqual(try runtime.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
    XCTAssertEqual(try runtime.query("PRAGMA journal_mode").first?["journal_mode"], "wal")

    let defaultDatabase = try SQLiteDatabase.open(path: temporaryDatabasePath(), options: .writableDefault)
    XCTAssertEqual(try defaultDatabase.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")

    let existingPath = temporaryDatabasePath()
    let existing = try SQLiteDatabase.open(path: existingPath, options: .writableDefault)
    try existing.execute("CREATE TABLE existing_rows (id INTEGER PRIMARY KEY)")
    let reopened = try SQLiteDatabase.open(path: existingPath, options: .writableRuntimeStoreDefault)
    XCTAssertEqual(try reopened.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-sqlite-blob-autovacuum-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("database.sqlite").path
  }
}
