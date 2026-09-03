import Foundation
import RielaSQLite
import XCTest

final class SQLiteSchemaMigratorTests: XCTestCase {
  func testFreshDatabaseIsStampedToCurrentGeneration() throws {
    let db = try openDatabase()

    try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 3,
      migrations: [],
      preGenerationProbe: { _ in false },
      storeDescription: "test store"
    )

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 3)
  }

  func testVerifyModeLeavesFreshDatabaseUnstamped() throws {
    let db = try openDatabase()

    try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 3,
      migrations: [],
      preGenerationProbe: { _ in false },
      storeDescription: "test store",
      mode: .verify
    )

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 0)
  }

  func testPreGenerationTablesWithoutPathThrowMissingMigrationPath() throws {
    let db = try openDatabase()
    try db.execute("CREATE TABLE old_layout (id TEXT PRIMARY KEY)")

    XCTAssertThrowsError(try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 2,
      migrations: [],
      preGenerationProbe: { try $0.tableExists("old_layout") },
      storeDescription: "test store"
    )) { error in
      XCTAssertTrue(error is SQLiteSchemaMigrator.MissingMigrationPathError)
    }
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 0)
  }

  func testAppliesMigrationChainInOrderAndPreservesData() throws {
    let db = try openDatabase()
    try db.execute("CREATE TABLE records (id TEXT PRIMARY KEY)")
    try db.execute("INSERT INTO records (id) VALUES ('kept')")
    try db.execute("PRAGMA user_version = 1")

    try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 3,
      migrations: [
        SQLiteSchemaMigration(fromGeneration: 2) { db in
          try db.execute("ALTER TABLE records ADD COLUMN second TEXT DEFAULT 'v3'")
        },
        SQLiteSchemaMigration(fromGeneration: 1) { db in
          try db.execute("ALTER TABLE records ADD COLUMN first TEXT DEFAULT 'v2'")
        }
      ],
      preGenerationProbe: { _ in true },
      storeDescription: "test store"
    )

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 3)
    let row = try db.query("SELECT id, first, second FROM records").first
    XCTAssertEqual(row?["id"], "kept")
    XCTAssertEqual(row?["first"], "v2")
    XCTAssertEqual(row?["second"], "v3")
  }

  func testGapInMigrationChainThrowsMissingMigrationPath() throws {
    let db = try openDatabase()
    try db.execute("CREATE TABLE records (id TEXT PRIMARY KEY)")
    try db.execute("PRAGMA user_version = 1")

    XCTAssertThrowsError(try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 3,
      migrations: [
        SQLiteSchemaMigration(fromGeneration: 2) { _ in }
      ],
      preGenerationProbe: { _ in true },
      storeDescription: "test store"
    )) { error in
      XCTAssertTrue(error is SQLiteSchemaMigrator.MissingMigrationPathError)
    }
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 1)
  }

  func testNewerGenerationThrows() throws {
    let db = try openDatabase()
    try db.execute("PRAGMA user_version = 9")

    XCTAssertThrowsError(try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 2,
      migrations: [],
      preGenerationProbe: { _ in false },
      storeDescription: "test store"
    )) { error in
      XCTAssertEqual(
        error as? SQLiteSchemaMigrator.NewerGenerationError,
        SQLiteSchemaMigrator.NewerGenerationError(
          storeDescription: "test store",
          stampedGeneration: 9,
          currentGeneration: 2
        )
      )
    }
  }

  func testVerifyModeThrowsMigrationPendingForMigratableDatabase() throws {
    let db = try openDatabase()
    try db.execute("CREATE TABLE records (id TEXT PRIMARY KEY)")
    try db.execute("PRAGMA user_version = 1")

    XCTAssertThrowsError(try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 2,
      migrations: [
        SQLiteSchemaMigration(fromGeneration: 1) { _ in }
      ],
      preGenerationProbe: { _ in true },
      storeDescription: "test store",
      mode: .verify
    )) { error in
      XCTAssertTrue(error is SQLiteSchemaMigrator.MigrationPendingError)
    }
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 1)
  }

  func testFailingMigrationStepRollsBackItsTransaction() throws {
    let db = try openDatabase()
    try db.execute("CREATE TABLE records (id TEXT PRIMARY KEY)")
    try db.execute("PRAGMA user_version = 1")

    XCTAssertThrowsError(try SQLiteSchemaMigrator.migrateIfNeeded(
      in: db,
      currentGeneration: 3,
      migrations: [
        SQLiteSchemaMigration(fromGeneration: 1) { db in
          try db.execute("INSERT INTO records (id) VALUES ('from-failed-step')")
          try db.execute("THIS IS NOT SQL")
        },
        SQLiteSchemaMigration(fromGeneration: 2) { _ in }
      ],
      preGenerationProbe: { _ in true },
      storeDescription: "test store"
    ))

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 1)
    XCTAssertTrue(try db.query("SELECT id FROM records").isEmpty)
  }

  private func openDatabase() throws -> SQLiteDatabase {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-schema-migrator-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return try SQLiteDatabase.open(path: root.appendingPathComponent("database.sqlite").path)
  }

  private var roots: [URL] = []

  override func tearDown() {
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }
}
