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

  func testConcurrentGenerationNineOpenersApplyEachMigrationOnce() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-schema-migrator-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    let path = root.appendingPathComponent("database.sqlite").path
    let seed = try SQLiteDatabase.open(path: path)
    try seed.execute("CREATE TABLE migration_counts (generation INTEGER PRIMARY KEY)")
    try seed.execute("PRAGMA user_version = 9")
    let gate = MigrationOpenGate(participants: 8)
    let count = MigrationCallCount()
    let migrations = [
      SQLiteSchemaMigration(fromGeneration: 9) { db in
        count.increment()
        try db.execute("INSERT INTO migration_counts VALUES (10)")
      },
      SQLiteSchemaMigration(fromGeneration: 10) { db in
        count.increment()
        try db.execute("INSERT INTO migration_counts VALUES (11)")
      }
    ]
    let errors = MigrationOpenErrors()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      do {
        let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
        try SQLiteSchemaMigrator.migrateIfNeeded(in: db, currentGeneration: 11, migrations: migrations,
          preGenerationProbe: { _ in gate.waitUntilAllArrive(); return true }, storeDescription: "test store")
      } catch {
        errors.append(error)
      }
    }

    XCTAssertTrue(errors.values.isEmpty, "concurrent opens failed: \(errors.values)")
    XCTAssertEqual(count.value, 2)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: seed), 11)
    XCTAssertEqual(try seed.query("SELECT generation FROM migration_counts ORDER BY generation").compactMap { $0["generation"] }, ["10", "11"])
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

private final class MigrationOpenGate: @unchecked Sendable {
  private let condition = NSCondition()
  private let participants: Int
  private var arrivals = 0

  init(participants: Int) { self.participants = participants }

  func waitUntilAllArrive() {
    condition.lock()
    arrivals += 1
    if arrivals == participants { condition.broadcast() }
    while arrivals < participants { condition.wait() }
    condition.unlock()
  }
}

private final class MigrationCallCount: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
  func increment() { lock.lock(); calls += 1; lock.unlock() }
}

private final class MigrationOpenErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
  func append(_ error: Error) { lock.lock(); stored.append(String(describing: error)); lock.unlock() }
}
