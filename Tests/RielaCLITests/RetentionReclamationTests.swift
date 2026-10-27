import Foundation
import XCTest
import RielaSQLite
@testable import RielaCLI

final class RetentionReclamationTests: XCTestCase {
  func testFreshRuntimeStoreStartsInIncrementalAutoVacuumMode() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path, options: .writableRuntimeStoreDefault)

    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
  }

  func testAutomaticIncrementalVacuumShrinksWithoutFullVacuum() throws {
    let fixture = try makeDatabase(incremental: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = StatementRecorder()
    let before = try fileSize(fixture.databasePath)
    let reclaimer = RetentionSQLiteReclaimer(statementObserver: { recorder.append($0) })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .automatic)

    XCTAssertEqual(result.action, .incrementalVacuum)
    XCTAssertEqual(result.autoVacuum, "incremental")
    XCTAssertGreaterThan(result.reclaimedBytes, 0)
    XCTAssertLessThan(try fileSize(fixture.databasePath), before)
    XCTAssertFalse(recorder.statements.contains { $0.uppercased() == "VACUUM" })
  }

  func testManualIncrementalVacuumUsesBoundedPageBudget() throws {
    let fixture = try makeDatabase(incremental: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = StatementRecorder()
    let result = RetentionSQLiteReclaimer(manualPageBudget: 17, statementObserver: { recorder.append($0) })
      .reclaim(databasePath: fixture.databasePath, mode: .manual)

    XCTAssertEqual(result.action, .incrementalVacuum)
    XCTAssertTrue(recorder.statements.contains("PRAGMA incremental_vacuum(17)"))
  }

  func testManualIncrementalVacuumReclaimsMoreThanOneChunkInOneRun() throws {
    let fixture = try makeDatabase(incremental: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let database = try SQLiteDatabase.open(path: fixture.databasePath)
    try database.execute("""
      WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 20)
      INSERT INTO payloads SELECT zeroblob(2097152) FROM sequence
      """)
    try database.execute("DELETE FROM payloads")
    XCTAssertGreaterThan(Int(try database.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0, 4_096)

    let result = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max }).reclaim(
      databasePath: fixture.databasePath, mode: .manual)
    let after = try SQLiteDatabase.open(path: fixture.databasePath, mode: .strictReadOnly, options: .readOnlyDefault)

    XCTAssertEqual(result.action, .incrementalVacuum)
    XCTAssertEqual(try after.query("PRAGMA freelist_count").first?["freelist_count"], "0")
  }

  func testManualFullVacuumDefersWhenAnySessionLockIsHeld() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lock = SessionExecutionLockRegistry(sessionStoreRoot: fixture.root.path)
    try lock.acquire(sessionId: "live-session")
    defer { lock.release(sessionId: "live-session") }

    let result = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max }).reclaim(
      databasePath: fixture.databasePath, mode: .manual)

    XCTAssertEqual(result.action, .deferredLiveSessions)
  }

  func testAutomaticModeDefersConversionAboveConfiguredSizeLimit() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fileSize(fixture.databasePath)
    let recorder = StatementRecorder()
    let reclaimer = RetentionSQLiteReclaimer(
      freeSpace: { _ in Int64.max },
      automaticConversionLimitBytes: 1,
      statementObserver: { recorder.append($0) }
    )

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .automatic)

    XCTAssertEqual(result.action, .deferredAutomaticSizeLimit)
    XCTAssertEqual(result.fileBytesAfter, before)
    XCTAssertFalse(recorder.statements.contains { $0.uppercased() == "VACUUM" })
  }

  func testManualConversionSetsIncrementalModeAndShrinks() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fileSize(fixture.databasePath)
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)
    let database = try SQLiteDatabase.open(path: fixture.databasePath, mode: .strictReadOnly, options: .readOnlyDefault)

    XCTAssertEqual(result.action, .converted)
    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
    XCTAssertGreaterThan(result.reclaimedBytes, 0)
    XCTAssertLessThan(try fileSize(fixture.databasePath), before)
  }

  func testReportedSizeAfterConversionMatchesDiskOnceTheConnectionCloses() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try diskBytes(fixture.databasePath)
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)
    let onDisk = try diskBytes(fixture.databasePath)

    // The converted pages sit in the WAL until the reclaimer's connection closes, so a size
    // measured while it is open double-counts them and reports no reclaimed bytes.
    XCTAssertEqual(result.action, .converted)
    XCTAssertEqual(result.fileBytesAfter, onDisk)
    XCTAssertEqual(result.reclaimedBytes, before - onDisk)
    XCTAssertGreaterThan(result.reclaimedBytes, 20_000_000)
  }

  func testManualConversionDefersWhenFreeSpaceIsInsufficient() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = StatementRecorder()
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in 1 }, statementObserver: { recorder.append($0) })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)

    XCTAssertEqual(result.action, .deferredInsufficientSpace)
    XCTAssertFalse(recorder.statements.contains { $0.uppercased() == "VACUUM" })
  }

  func testManualConversionDefersWhenFreeSpaceCannotBeRead() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in nil })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)

    XCTAssertEqual(result.action, .deferredInsufficientSpace)
  }

  func testMissingDatabaseIsNotCreated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = root.appendingPathComponent("missing.sqlite").path

    let result = RetentionSQLiteReclaimer().reclaim(databasePath: databasePath, mode: .automatic)

    XCTAssertEqual(result.action, .none)
    XCTAssertEqual(result.fileBytesBefore, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
  }

  func testBusyWriterReturnsWarningInsteadOfThrowing() throws {
    let fixture = try makeDatabase(incremental: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try SQLiteDatabase.open(
      path: fixture.databasePath,
      options: SQLiteOpenOptions(enableWAL: false, requireJSONB: false)
    )
    try writer.execute("BEGIN IMMEDIATE")
    defer { try? writer.execute("ROLLBACK") }
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)

    XCTAssertEqual(result.action, .busy)
    XCTAssertNotNil(result.warning)
  }

  func testRollbackJournalModeRemainsUnchanged() throws {
    let fixture = try makeDatabase(incremental: false, enableWAL: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in Int64.max })

    let result = reclaimer.reclaim(databasePath: fixture.databasePath, mode: .manual)
    let database = try SQLiteDatabase.open(path: fixture.databasePath, mode: .strictReadOnly, options: .readOnlyDefault)

    XCTAssertEqual(result.action, .converted)
    XCTAssertNotEqual(try database.query("PRAGMA journal_mode").first?["journal_mode"], "wal")
  }

  private func makeDatabase(incremental: Bool, enableWAL: Bool = true) throws -> (root: URL, databasePath: String) {
    let root = try makeRoot()
    let databasePath = root.appendingPathComponent("runtime.sqlite").path
    let database = try SQLiteDatabase.open(
      path: databasePath,
      options: SQLiteOpenOptions(enableWAL: false, requireJSONB: false)
    )
    if incremental { try database.execute("PRAGMA auto_vacuum=INCREMENTAL") }
    if enableWAL { _ = try database.query("PRAGMA journal_mode=WAL") }
    try database.execute("CREATE TABLE payloads(value BLOB NOT NULL)")
    try database.execute("""
      WITH RECURSIVE sequence(value) AS (
        SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 32
      )
      INSERT INTO payloads SELECT zeroblob(2097152) FROM sequence
      """)
    try database.execute("DELETE FROM payloads WHERE rowid <= 24")
    if enableWAL { _ = try database.query("PRAGMA wal_checkpoint(FULL)") }
    return (root, databasePath)
  }

  private func makeRoot() throws -> URL {
    let temporaryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/retention-reclaim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    guard let resolvedPath = realpath(temporaryRoot.path, nil) else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
  }

  private func diskBytes(_ databasePath: String) throws -> Int64 {
    let wal = databasePath + "-wal"
    return try fileSize(databasePath) + (FileManager.default.fileExists(atPath: wal) ? try fileSize(wal) : 0)
  }

  private func fileSize(_ path: String) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }
}

private final class StatementRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  var statements: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  func append(_ statement: String) {
    lock.lock()
    defer { lock.unlock() }
    values.append(statement)
  }
}
