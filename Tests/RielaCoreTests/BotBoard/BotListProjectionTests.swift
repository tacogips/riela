import Foundation
import XCTest
@testable import RielaCore

final class BotListProjectionTests: XCTestCase {
  private let now = BoardFixture.now

  func testOrderIsPinnedThenManualThenBumpThenId() {
    let inputs = [
      row("z", activity: 35), row("y", activity: -10, pinned: true), row("x", activity: -20, order: 1),
      row("w", activity: -30, order: 0), row("b", activity: 35), row("c", activity: 50, terminal: 10)
    ]
    let expected = ["y", "w", "x", "b", "z", "c"]
    XCTAssertEqual(BotBoardProjector.overviewList(inputs, groupBy: .none).rows.map(\.bot.botId), expected)
    XCTAssertEqual(BotBoardProjector.overviewList(inputs.reversed(), groupBy: .none).rows.map(\.bot.botId), expected)
  }

  func testSnoozeWakesOnlyForNewNeedsYouOrFailure() {
    var input = BoardFixture.input()
    let cutoff = now.addingTimeInterval(-60)
    input.listStates[.bot] = BotListState(snoozedUntil: now.addingTimeInterval(86_400), snoozedAt: cutoff)
    var session = BoardFixture.session("run", .running)
    input.sessions = [BotBoardSessionInput(session: session, pendingRequests: [BoardFixture.permission(at: cutoff)])]
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .snoozed)

    input.sessions[0].pendingRequests = [BoardFixture.permission()]
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .active)

    session.status = .failed
    session.failedAt = cutoff
    input.sessions = [BotBoardSessionInput(session: session)]
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .snoozed)
    input.sessions[0].session.failedAt = now
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .active)
  }

  func testSettledBotReturnsToActiveAndBackgroundWorkUsesWorkingSection() {
    var input = BoardFixture.input()
    input.listStates[.bot] = BotListState(settledAt: now.addingTimeInterval(-60), settledBy: "user")
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .settled)
    input.sessions = [BotBoardSessionInput(session: BoardFixture.session("run", .running))]
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .active)
    input.listStates = [:]
    input.tasks = [BotBoardTaskInput(taskId: "pending-ci", title: "CI", state: "waiting", updatedAt: now, waitReason: "CI")]
    XCTAssertEqual(BotBoardProjector.overviewRow(input).section, .working)
    XCTAssertEqual(BotBoardProjector.board(input).groups[.waiting]?.first?.waitingReason, "CI")
  }

  func testAutoSettleOnlyAppliesToClosedAndCanSettleRejectsBusyItems() throws {
    var input = BoardFixture.input()
    let day: TimeInterval = 86_400
    let old = now.addingTimeInterval(-8 * day)
    input.sessions = [
      BotBoardSessionInput(session: BoardFixture.session("closed", .completed, updatedAt: old)),
      BotBoardSessionInput(session: BoardFixture.session("running", .running, updatedAt: old)),
      BotBoardSessionInput(session: BoardFixture.session("waiting", .suspended, updatedAt: old)),
      BotBoardSessionInput(
        session: BoardFixture.session("blocked", .running, updatedAt: old),
        pendingRequests: [BoardFixture.permission(at: old)]
      ),
      BotBoardSessionInput(session: BoardFixture.session("planned", .created, updatedAt: old))
    ]
    let board = BotBoardProjector.board(input)
    let done = try XCTUnwrap(board.groups[.closed]?.first)
    XCTAssertEqual(done.listState.settledAt, old.addingTimeInterval(7 * day))
    XCTAssertEqual(done.listState.settledBy, "auto")
    XCTAssertTrue(BotBoardProjector.canSettle(done))
    for group in [BotBoardGroup.needsYou, .inProgress, .waiting] {
      let busy = try XCTUnwrap(board.groups[group]?.first)
      XCTAssertNil(busy.listState.settledAt)
      XCTAssertFalse(BotBoardProjector.canSettle(busy))
    }
    XCTAssertFalse(BotBoardProjector.canSettleBot(board))
    input.sessions = input.sessions.filter { ["closed", "planned"].contains($0.session.sessionId) }
    XCTAssertTrue(BotBoardProjector.canSettleBot(BotBoardProjector.board(input)))
  }

  func testWorkspaceGroupingUsesServerOrderAndNeedsYouIndicator() {
    var build = BoardFixture.input("build", workspace: "shared")
    build.listStates[.bot] = BotListState(pinned: true)
    var release = BoardFixture.input("release", workspace: "shared")
    release.tasks = [BotBoardTaskInput(taskId: "review", title: "Review release", state: "needsDecision", updatedAt: now)]
    let local = BoardFixture.input("local")
    let list = BotBoardProjector.overviewList([release, local, build], groupBy: .workspace)
    XCTAssertEqual(list.rows.map(\.bot.botId), ["build", "release", "local"])
    XCTAssertEqual(list.groups, [
      BotWorkspaceGroup(key: "shared", needsYou: true, botIds: ["build", "release"]),
      BotWorkspaceGroup(key: "ungrouped", needsYou: false, botIds: ["local"])
    ])
  }

  private func row(
    _ id: String, activity: TimeInterval, pinned: Bool = false, order: Int? = nil, terminal: TimeInterval? = nil
  ) -> BotBoardInput {
    var input = BoardFixture.input(id)
    input.listStates[.bot] = BotListState(pinned: pinned, manualOrder: order)
    var session = BoardFixture.session(id, terminal == nil ? .running : .failed, updatedAt: now.addingTimeInterval(activity))
    session.failedAt = terminal.map { now.addingTimeInterval($0) }
    input.sessions = [BotBoardSessionInput(session: session)]
    return input
  }
}
