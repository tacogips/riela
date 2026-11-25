import Foundation
import XCTest
@testable import RielaCore

final class BotJobLedgerTests: XCTestCase {
  func testClaimIsExclusiveAndSuccessfulRunRetainsProvenance() throws {
    try withBotJobStore { store, date in
      let otherStore = BotStore(sessionStoreRoot: store.sessionStoreRoot)
      XCTAssertTrue(try store.claimJobRun(botId: "bot", job: .upkeep, periodKey: "day", sessionId: "first", at: date))
      XCTAssertFalse(try otherStore.claimJobRun(botId: "bot", job: .upkeep, periodKey: "day", sessionId: "second", at: date))
      XCTAssertNil(try store.lastSuccessfulJobRun(botId: "bot", job: .upkeep))

      let finish = date.addingTimeInterval(10)
      try store.finishJobRun(botId: "bot", job: .upkeep, periodKey: "day", status: .succeeded, detail: "applied", at: finish)
      let run = try XCTUnwrap(otherStore.lastSuccessfulJobRun(botId: "bot", job: .upkeep))
      XCTAssertEqual(run.status, .succeeded)
      XCTAssertEqual(run.detail, "applied")
      XCTAssertEqual(run.sessionId, "first")
      XCTAssertEqual(run.startedAt, RoutineStore.timestamp(date))
      XCTAssertEqual(run.finishedAt, RoutineStore.timestamp(finish))
      XCTAssertThrowsError(
        try store.finishJobRun(botId: "bot", job: .upkeep, periodKey: "day", status: .failed, detail: nil, at: finish)
      ) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_job_not_running")
      }
      XCTAssertEqual(try otherStore.jobRuns(botId: "bot", job: .upkeep, limit: 10), [run])
    }
  }

  func testSkippedRowsDoNotReplaceClaimsOrOtherSkips() throws {
    try withBotJobStore { store, date in
      XCTAssertTrue(try store.claimJobRun(botId: "bot", job: .lookAround, periodKey: "2027-01-03", sessionId: nil, at: date))
      try store.recordSkippedJobRuns(
        botId: "bot", job: .lookAround, periodKeys: ["2027-01-02", "2027-01-03", "2027-01-01"], reason: "catch_up", at: date
      )
      try store.recordSkippedJobRuns(botId: "bot", job: .lookAround, periodKeys: ["2027-01-02"], reason: "replacement", at: date)
      XCTAssertFalse(try store.claimJobRun(botId: "bot", job: .lookAround, periodKey: "2027-01-02", sessionId: nil, at: date))
      let runs = try store.jobRuns(botId: "bot", job: .lookAround, limit: 2)
      XCTAssertEqual(runs.map(\.periodKey), ["2027-01-03", "2027-01-02"])
      XCTAssertEqual(runs.map(\.status), [.running, .skipped])
      XCTAssertEqual(runs.last?.detail, "catch_up")
      XCTAssertEqual(runs.last?.finishedAt, RoutineStore.timestamp(date))
      XCTAssertTrue(try store.jobRuns(botId: "bot", job: .upkeep, limit: 5).isEmpty)
      XCTAssertNil(try store.lastSuccessfulJobRun(botId: "bot", job: .lookAround))
    }
  }

  func testLastSuccessUsesCompletionTime() throws {
    try withBotJobStore { store, date in
      XCTAssertTrue(try store.claimJobRun(botId: "bot", job: .upkeep, periodKey: "older", sessionId: nil, at: date))
      XCTAssertTrue(try store.claimJobRun(botId: "bot", job: .upkeep, periodKey: "newer", sessionId: nil, at: date.addingTimeInterval(1)))
      try store.finishJobRun(botId: "bot", job: .upkeep, periodKey: "newer", status: .succeeded, detail: nil, at: date.addingTimeInterval(2))
      try store.finishJobRun(botId: "bot", job: .upkeep, periodKey: "older", status: .succeeded, detail: nil, at: date.addingTimeInterval(3))
      XCTAssertEqual(try store.lastSuccessfulJobRun(botId: "bot", job: .upkeep)?.periodKey, "older")
    }
  }

  func testClaimRejectsUnknownBot() throws {
    try withBotJobStore { store, date in
      XCTAssertThrowsError(try store.claimJobRun(botId: "missing", job: .upkeep, periodKey: "day", sessionId: nil, at: date)) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "bot_not_found")
      }
      XCTAssertTrue(try store.jobRuns(botId: "missing", job: .upkeep, limit: 10).isEmpty)
    }
  }
}

func withBotJobStore(_ body: (BotStore, Date) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = BotStore(sessionStoreRoot: root.path)
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let timestamp = RoutineStore.timestamp(date)
  try store.create(BotRecord(botId: "bot", name: "Bot", createdAt: timestamp, updatedAt: timestamp))
  try body(store, date)
}
