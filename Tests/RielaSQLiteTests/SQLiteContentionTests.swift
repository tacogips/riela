import Foundation
import RielaSQLite
import XCTest

final class SQLiteContentionTests: XCTestCase {
  func testWALOpenRespectsBusyTimeoutAndDoesNotChangeLockedDatabase() throws {
    for timeout: Int32 in [0, 100] {
      let path = databasePath()
      let writer = try SQLiteDatabase.open(path: path, options: SQLiteOpenOptions(enableWAL: false))
      try writer.execute("CREATE TABLE records (id INTEGER PRIMARY KEY)")
      try writer.execute("BEGIN IMMEDIATE")
      defer { try? writer.execute("ROLLBACK") }
      let clock = ContinuousClock()
      let start = clock.now

      XCTAssertThrowsError(try SQLiteDatabase.open(
        path: path, options: SQLiteOpenOptions(busyTimeoutMilliseconds: timeout)
      )) { error in
        XCTAssertEqual((error as? SQLiteError)?.code, 5)
        XCTAssertEqual((error as? SQLiteError)?.sql, "PRAGMA journal_mode=WAL")
      }

      let elapsed = start.duration(to: clock.now)
      XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(Int64(timeout)))
      XCTAssertLessThan(elapsed, .seconds(2))
      XCTAssertEqual(try writer.query("PRAGMA journal_mode").first?["journal_mode"], "delete")
    }
  }

  func testThreeConcurrentConnectionsInitializeAndPersistEveryRecord() throws {
    let path = databasePath()
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let completed = expectation(description: "three writers completed")
    completed.expectedFulfillmentCount = 3
    for worker in 0..<3 {
      DispatchQueue.global().async {
        ready.signal()
        guard start.wait(timeout: .now() + 5) == .success else {
          XCTFail("writer start timed out")
          completed.fulfill()
          return
        }
        defer { completed.fulfill() }
        do {
          for record in 0..<30 {
            let database = try SQLiteDatabase.open(path: path)
            try database.execute("CREATE TABLE IF NOT EXISTS records (id INTEGER PRIMARY KEY)")
            try database.transaction { db in
              try db.execute("INSERT INTO records VALUES (?)", bindings: [.int(Int64(worker * 30 + record))])
            }
          }
        } catch {
          XCTFail("writer \(worker) failed: \(error)")
        }
      }
    }
    for _ in 0..<3 {
      XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    }
    for _ in 0..<3 { start.signal() }
    wait(for: [completed], timeout: 15)

    let database = try SQLiteDatabase.open(path: path)
    XCTAssertEqual(try database.query("SELECT COUNT(*) AS count FROM records").first?["count"], "90")
    XCTAssertEqual(try database.query("PRAGMA integrity_check").first?["integrity_check"], "ok")
  }

  func testWALOpenWaitsForRollbackJournalWriter() throws {
    try assertWALOpenWaits(delay: 0.2, options: SQLiteOpenOptions())
  }

  func testDefaultWALOpenWaitsBeyondThreeSeconds() throws {
    try assertWALOpenWaits(delay: 3.3, options: .writableDefault)
  }

  private func assertWALOpenWaits(delay: TimeInterval, options: SQLiteOpenOptions) throws {
    let path = databasePath()
    let writer = try SQLiteDatabase.open(path: path, options: SQLiteOpenOptions(enableWAL: false))
    try writer.execute("CREATE TABLE records (id INTEGER PRIMARY KEY)")
    try writer.execute("BEGIN IMMEDIATE")
    try writer.execute("INSERT INTO records VALUES (1)")
    let released = expectation(description: "writer committed")
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
      defer { released.fulfill() }
      do {
        try writer.execute("COMMIT")
      } catch {
        XCTFail("writer commit failed: \(error)")
      }
    }
    defer { wait(for: [released], timeout: 5) }

    let reader = try SQLiteDatabase.open(path: path, options: options)

    XCTAssertEqual(try reader.query("PRAGMA journal_mode").first?["journal_mode"], "wal")
    XCTAssertEqual(try reader.query("PRAGMA busy_timeout").first?["timeout"], options.waitForLocks ? "0" : "3000")
    XCTAssertEqual(try reader.query("SELECT COUNT(*) AS count FROM records").first?["count"], "1")
  }

  func testDefaultWriterWaitsBeyondThreeSecondsWithoutReplayingTransaction() throws {
    let path = databasePath()
    let owner = try SQLiteDatabase.open(path: path)
    let contender = try SQLiteDatabase.open(path: path)
    try owner.execute("CREATE TABLE records (id INTEGER PRIMARY KEY)")
    try owner.execute("BEGIN IMMEDIATE")
    try owner.execute("INSERT INTO records VALUES (1)")
    let released = expectation(description: "long-running writer committed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 3.3) {
      defer { released.fulfill() }
      do {
        try owner.execute("COMMIT")
      } catch {
        XCTFail("owner commit failed: \(error)")
      }
    }
    defer { wait(for: [released], timeout: 10) }
    var bodyCalls = 0

    try contender.transaction { db in
      bodyCalls += 1
      try db.execute("INSERT INTO records VALUES (2)")
    }

    XCTAssertEqual(bodyCalls, 1)
    XCTAssertEqual(try contender.query("SELECT COUNT(*) AS count FROM records").first?["count"], "2")
  }

  private var roots: [URL] = []

  func testCancelledTaskStopsWaitingForWriteLock() async throws {
    try await assertCancelledWaiterStops(openingWAL: false)
  }

  func testCancelledTaskStopsWaitingForWALInitialization() async throws {
    try await assertCancelledWaiterStops(openingWAL: true)
  }

  private func assertCancelledWaiterStops(openingWAL: Bool) async throws {
    let path = databasePath()
    let options = SQLiteOpenOptions(enableWAL: !openingWAL, waitForLocks: true)
    let owner = try SQLiteDatabase.open(path: path, options: options)
    let contender = try SQLiteDatabase.open(path: path, options: options)
    try owner.execute("BEGIN IMMEDIATE")
    let started = expectation(description: "contender started")
    let released = expectation(description: "fallback unlock")
    // Keep a broken cancellation implementation from hanging the test suite.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
      try? owner.execute("ROLLBACK")
      released.fulfill()
    }
    let waiting = Task.detached {
      started.fulfill()
      if openingWAL {
        _ = try SQLiteDatabase.open(path: path)
      } else {
        try contender.transaction { _ in }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    waiting.cancel()
    do {
      try await waiting.value
      XCTFail("cancelled waiter must not acquire the lock after fallback unlock")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? SQLiteError)?.code == 5)
    }
    await fulfillment(of: [released], timeout: 2)
  }

  private func databasePath() -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/sqlite-contention-tests/\(UUID().uuidString)", isDirectory: true)
    roots.append(root)
    return root.appendingPathComponent("database.sqlite").path
  }

  override func tearDown() {
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }
}
