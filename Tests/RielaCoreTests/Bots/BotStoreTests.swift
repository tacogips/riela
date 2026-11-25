import Foundation
import XCTest
@testable import RielaCore

final class BotStoreTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  func testCreateLoadListAndDuplicate() throws {
    try withStore { store in
      let release = record("release-bot")
      let build = record("build-bot")
      try store.create(release)
      try store.create(build)

      XCTAssertEqual(try store.load(botId: release.botId), release)
      XCTAssertEqual(try store.list(), [build, release])
      XCTAssertNil(try store.load(botId: "missing"))
      XCTAssertThrowsError(try store.create(release)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_exists")
      }
    }
  }

  func testRecordValidationAndSlugDefaults() throws {
    try withStore { store in
      let invalidRecords = [
        record("Bad_ID"),
        record("newline\n"),
        record("valid", name: ""),
        record("valid", name: "Invalid\nname"),
        record("valid", wait: 3_600_001),
        record("valid", backend: "invalid-backend")
      ]
      for invalid in invalidRecords {
        XCTAssertThrowsError(try store.create(invalid)) { error in
          XCTAssertEqual((error as? BotStoreError)?.code, "bot_invalid")
        }
      }
      XCTAssertEqual(BotRecord.slug(from: "Release Bot #1"), "release-bot-1")
      XCTAssertEqual(BotRecord.slug(from: "#!"), "bot")
      XCTAssertEqual(BotRecord.slug(from: String(repeating: "A", count: 70)).count, 63)
      let timestamp = RoutineStore.timestamp(date)
      let defaults = BotRecord(name: "Release Bot #1", createdAt: timestamp, updatedAt: timestamp)
      XCTAssertEqual(defaults.botId, "release-bot-1")
      XCTAssertEqual(defaults.memoryUpkeep, .nightly)
      XCTAssertEqual(defaults.lookAround, .off)
      XCTAssertEqual(defaults.permissionWaitMs, 300_000)
    }
  }

  func testUpdateAndPausePreserveIdentity() throws {
    try withStore { store in
      let original = record("release")
      try store.create(original)
      let paused = try store.setPaused(botId: original.botId, paused: true)
      XCTAssertTrue(paused.paused)
      XCTAssertEqual(paused.createdAt, original.createdAt)
      let renamed = try store.update(botId: original.botId) { $0.name = "Release Bot" }
      XCTAssertEqual(renamed.name, "Release Bot")
      let replacement = record("another")
      XCTAssertThrowsError(try store.update(botId: original.botId) { $0 = replacement }) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_invalid")
      }
      XCTAssertEqual(try store.load(botId: original.botId), renamed)
      XCTAssertThrowsError(try store.update(botId: "missing") { _ in }) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_not_found")
      }
    }
  }

  func testLinkIsIdempotentAndExclusive() throws {
    try withStore { store in
      let release = record("release")
      let build = record("build")
      let later = date.addingTimeInterval(60)
      XCTAssertThrowsError(try store.linkSession(sessionId: "one", botId: release.botId, source: "run", at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_not_found")
      }
      try store.create(release)
      try store.create(build)
      try store.linkSession(sessionId: "one", botId: release.botId, source: "routine", sourceRef: "nightly", at: date)
      try store.linkSession(sessionId: "one", botId: release.botId, source: "run", at: later)
      XCTAssertThrowsError(try store.linkSession(sessionId: "one", botId: build.botId, source: "run", at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_link_conflict")
      }
      XCTAssertEqual(
        try store.link(forSession: "one"),
        BotSessionLink(
          sessionId: "one", botId: "release", source: "routine", sourceRef: "nightly", linkedAt: RoutineStore.timestamp(date)
        )
      )
      try store.linkSession(sessionId: "two", botId: release.botId, source: "job", at: later)
      XCTAssertEqual(try store.links(botId: release.botId).map(\.sessionId), ["two", "one"])
      XCTAssertTrue(try store.links(botId: build.botId).isEmpty)
    }
  }

  func testRemoveRefusesPendingPermissionAndCleansOnlyBotOwnedRows() throws {
    try withStore { store in
      try store.create(record("release"))
      try store.create(record("build"))
      try store.linkSession(sessionId: "run", botId: "release", source: "run", at: date)
      try store.write { database in
        try database.execute("INSERT INTO bot_list_state VALUES ('release', 'bot', '', jsonb('{}'), 'now')")
        try database.execute("INSERT INTO bot_list_state VALUES ('build', 'bot', '', jsonb('{}'), 'now')")
        try database.execute(
          "INSERT INTO bot_suggestions (suggestion_id, bot_id, record_json, created_at) VALUES ('suggestion', 'release', jsonb('{\"status\":\"open\"}'), 'now')"
        )
        try database.execute(
          "INSERT INTO bot_job_runs (bot_id, job, period_key, status, started_at) VALUES ('release', 'upkeep', 'period', 'finished', 'now')"
        )
        try database.execute("INSERT INTO bot_memory_changes VALUES ('change', 'release', jsonb('{}'), 'now')")
        try database.execute(
          """
          INSERT INTO activity_requests (request_id, session_id, options_json, status, created_at, expires_at)
          VALUES ('request', 'run', jsonb('[]'), 'pending', 'now', 'later')
          """
        )
      }
      XCTAssertThrowsError(try store.remove(botId: "release")) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_busy")
      }
      XCTAssertNotNil(try store.load(botId: "release"))
      XCTAssertNotNil(try store.link(forSession: "run"))

      try store.write { database in
        try database.execute("UPDATE activity_requests SET status = 'answered' WHERE request_id = 'request'")
      }
      try store.remove(botId: "release")

      XCTAssertNil(try store.load(botId: "release"))
      XCTAssertNil(try store.link(forSession: "run"))
      try store.read { database in
        for table in ["bot_list_state", "bot_suggestions", "bot_job_runs"] {
          XCTAssertTrue(try database.query("SELECT 1 FROM \(table) WHERE bot_id = 'release'").isEmpty, table)
        }
        XCTAssertEqual(try database.query("SELECT 1 FROM bot_list_state WHERE bot_id = 'build'").count, 1)
        XCTAssertEqual(try database.query("SELECT 1 FROM bot_memory_changes WHERE bot_id = 'release'").count, 1)
        XCTAssertEqual(try database.query("SELECT 1 FROM activity_requests WHERE request_id = 'request'").count, 1)
      }
    }
  }

  func testReadMissingStoreCreatesNoDirectory() throws {
    try withStore { store in
      XCTAssertNil(try store.read { _ in XCTFail("Missing store invoked read body") })
      XCTAssertTrue(try store.list().isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionStoreRoot))
    }
  }

  private func withStore(_ body: (BotStore) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(BotStore(sessionStoreRoot: root.path))
  }

  private func record(
    _ id: String, name: String = "Bot", wait: Int = 300_000, backend: String? = nil
  ) -> BotRecord {
    let timestamp = RoutineStore.timestamp(date)
    return BotRecord(
      botId: id, name: name, defaultBackend: backend,
      permissionWaitMs: wait, createdAt: timestamp, updatedAt: timestamp
    )
  }
}
