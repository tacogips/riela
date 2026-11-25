import Foundation
import XCTest
@testable import RielaCore

enum BoardFixture {
  static let now = Date(timeIntervalSince1970: 1_700_000_000)

  static func session(
    _ id: String, _ status: WorkflowSessionStatus, updatedAt: Date = now
  ) -> WorkflowSession {
    WorkflowSession(
      workflowId: "workflow-\(id)", sessionId: id, status: status, entryStepId: "initial",
      currentStepId: "build", createdAt: updatedAt.addingTimeInterval(-60), updatedAt: updatedAt
    )
  }

  static func input(_ id: String = "release", workspace: String? = nil) -> BotBoardInput {
    let timestamp = RoutineStore.timestamp(now)
    return BotBoardInput(
      bot: BotRecord(botId: id, name: id, workspace: workspace, createdAt: timestamp, updatedAt: timestamp),
      now: now, origin: .local(serverId: "host", serverName: nil, at: now), redact: { $0 }
    )
  }

  static func permission(at date: Date = now) -> BotBoardPendingRequest {
    BotBoardPendingRequest(
      requestId: "child-request", title: "Allow fetch?",
      options: [AdapterPermissionOption(optionId: "native-allow", name: "Allow", kind: "allow_once")],
      createdAt: date, expiresAt: date.addingTimeInterval(60)
    )
  }
}

final class BotBoardProjectorTests: XCTestCase {
  func testRunningSessionUsesExecutionAndActivity() throws {
    let now = BoardFixture.now
    var input = BoardFixture.input()
    var session = BoardFixture.session("run", .running)
    session.executions = [
      WorkflowStepExecution(
        executionId: "current", stepId: "build", nodeId: "agent", attempt: 1, backend: .codexAgent,
        createdAt: now.addingTimeInterval(-40), updatedAt: now
      )
    ]
    var activity = ActivityState()
    activity.source = "acp"
    activity.currentExecutionId = "current"
    activity.reportedModel = "reported"
    activity.lastEventAt = now.addingTimeInterval(1)
    activity.plans = [ActivityPlan(planId: "checks", entries: [])]
    activity.toolCalls = [
      ActivityToolCall(toolCallId: "a", title: "Read", status: "pending", updatedAt: now.addingTimeInterval(-2)),
      ActivityToolCall(toolCallId: "b", title: "Test", status: "inProgress", updatedAt: now.addingTimeInterval(-1)),
      ActivityToolCall(toolCallId: "c", title: "Write", status: "completed", updatedAt: now)
    ]
    input.sessions = [BotBoardSessionInput(session: session, activity: activity, requestedModel: "configured")]
    let item = try XCTUnwrap(BotBoardProjector.board(input).groups[.inProgress]?.first)
    XCTAssertEqual(item.stepId, "build")
    XCTAssertEqual(item.nodeId, "agent")
    XCTAssertEqual(item.backend, "codex-agent")
    XCTAssertEqual(item.model, "reported")
    XCTAssertEqual(item.doingNow, "Test")
    XCTAssertEqual(item.checklist, activity.plans)
    XCTAssertEqual(item.activitySource, "acp")
    XCTAssertEqual(item.elapsedMs, 60_000)
    XCTAssertEqual(item.lastActivityAt, activity.lastEventAt)
    XCTAssertEqual(item.origin, input.origin)

    input.sessions[0].activity = nil
    let fallback = try XCTUnwrap(BotBoardProjector.board(input).groups[.inProgress]?.first)
    XCTAssertEqual(fallback.activitySource, "session")
    XCTAssertEqual(fallback.model, "configured")
    XCTAssertEqual(fallback.doingNow, "build")
  }

  func testChildPermissionTakesPrecedenceAndKeepsNativeOptions() throws {
    var input = BoardFixture.input()
    let child = BoardFixture.session("child", .running)
    let request = BoardFixture.permission()
    var activity = ActivityState()
    activity.currentStepId = "child-step"
    activity.reportedModel = "child-model"
    input.sessions = [
      BotBoardSessionInput(
        session: BoardFixture.session("root", .running), descendants: [child],
        descendantActivities: [child.sessionId: activity], pendingRequests: [request]
      )
    ]
    let board = BotBoardProjector.board(input)
    let item = try XCTUnwrap(board.groups[.needsYou]?.first)
    XCTAssertEqual(board.groups[.inProgress], [])
    XCTAssertEqual(item.answerPath, "bot")
    XCTAssertEqual(item.pendingRequests, [request])
    XCTAssertEqual(item.bumpedAt, request.createdAt)
    XCTAssertEqual(item.sessionId, "root")
    XCTAssertEqual(item.stepId, "child-step")
    XCTAssertEqual(item.model, "child-model")
  }

  func testSuspensionReasonsAndHandoverQuestion() throws {
    let now = BoardFixture.now
    var input = BoardFixture.input()
    var question = BoardFixture.session("question", .suspended)
    question.suspend = SuspendRecord(
      reasonKind: .userInputRequired, stepId: "build",
      question: HandoverQuestion(id: "q", text: "Continue?", options: [HandoverOption(id: "next", label: "Next")]),
      suspendedAt: now, producer: .runtime
    )
    var move = BoardFixture.session("move", .suspended)
    move.suspend = SuspendRecord(reasonKind: .operatorMove, stepId: "build", suspendedAt: now, producer: .runtime)
    var presence = BoardFixture.session("presence", .suspended)
    presence.suspend = SuspendRecord(reasonKind: .userPresenceRequired, stepId: "build", suspendedAt: now, producer: .runtime)
    input.sessions = [question, move, presence].map { BotBoardSessionInput(session: $0) }

    let board = BotBoardProjector.board(input)
    let item = try XCTUnwrap(board.groups[.needsYou]?.first { $0.itemId == "question" })
    XCTAssertEqual(item.answerPath, "task")
    XCTAssertEqual(item.question, BotBoardQuestion(questionId: "q", text: "Continue?", optionIds: ["next"]))
    XCTAssertEqual(board.groups[.needsYou]?.map(\.itemId), ["presence", "question"])
    XCTAssertEqual(board.groups[.waiting]?.first?.waitingReason, "operatorMove")
  }

  func testTaskDecisionAndAttemptFolding() throws {
    var input = BoardFixture.input()
    let now = BoardFixture.now
    input.tasks = [
      BotBoardTaskInput(taskId: "decision", title: "Decide", state: "needsDecision", updatedAt: now),
      BotBoardTaskInput(taskId: "work", title: "Build", state: "running", updatedAt: now, attemptSessionIds: ["attempt"])
    ]
    var activity = ActivityState()
    activity.source = "acp"
    activity.reportedModel = "attempt-model"
    input.sessions = [BotBoardSessionInput(session: BoardFixture.session("attempt", .running), activity: activity)]

    let board = BotBoardProjector.board(input)
    XCTAssertEqual(board.groups[.needsYou]?.first?.answerPath, "task")
    let item = try XCTUnwrap(board.groups[.inProgress]?.first)
    XCTAssertEqual(board.groups[.inProgress]?.map(\.itemId), ["work"])
    XCTAssertEqual(item.sessionId, "attempt")
    XCTAssertEqual(item.model, "attempt-model")

    input.sessions[0].pendingRequests = [BoardFixture.permission()]
    let pending = try XCTUnwrap(BotBoardProjector.board(input).groups[.needsYou]?.first { $0.itemId == "work" })
    XCTAssertEqual(pending.answerPath, "bot")
    XCTAssertEqual(pending.pendingRequests.map(\.requestId), ["child-request"])
  }

  func testFailedLimitedSessionWaitsWithResetAndFrozenElapsedTime() throws {
    let now = BoardFixture.now
    let failedAt = now.addingTimeInterval(-5)
    var input = BoardFixture.input()
    var session = BoardFixture.session("limited", .failed)
    session.failedAt = failedAt
    var activity = ActivityState()
    activity.lastStop = ActivityStop(stopReason: "usage", limited: true, limitedResetAt: now.addingTimeInterval(600))
    input.sessions = [BotBoardSessionInput(session: session, activity: activity)]

    let board = BotBoardProjector.board(input)
    let item = try XCTUnwrap(board.groups[.waiting]?.first)
    XCTAssertEqual(item.status, "limited")
    XCTAssertEqual(item.waitingReason, "limited")
    XCTAssertEqual(item.limitedResetAt, activity.lastStop?.limitedResetAt)
    XCTAssertEqual(item.bumpedAt, failedAt)
    XCTAssertEqual(item.elapsedMs, 55_000)
    XCTAssertEqual(board.closedTotal, 0)
  }

  func testPlannedEntriesAndFiveNamedArrays() throws {
    let now = BoardFixture.now
    var input = BoardFixture.input()
    input.routines = [
      BotBoardRoutineInput(routineId: "ready", name: "Upcoming", workflowName: "build", nextFireAt: now, active: true),
      BotBoardRoutineInput(routineId: "disabled", name: "Disabled", workflowName: "build", nextFireAt: now, active: false),
      BotBoardRoutineInput(routineId: "event", name: "Event", workflowName: "build", nextFireAt: nil, active: true)
    ]
    input.suggestions = [
      BotBoardSuggestionInput(suggestionId: "accepted", title: "Apply", status: "accepted", acceptedAt: now, startedSessionId: nil),
      BotBoardSuggestionInput(suggestionId: "started", title: "Started", status: "accepted", acceptedAt: now, startedSessionId: "run"),
      BotBoardSuggestionInput(suggestionId: "dismissed", title: "Dismissed", status: "dismissed", acceptedAt: nil, startedSessionId: nil)
    ]
    input.sessions = [BotBoardSessionInput(session: BoardFixture.session("created", .created))]
    let board = BotBoardProjector.board(input)
    XCTAssertEqual(board.groups[.planned]?.map(\.itemId), ["created", "accepted", "ready"])
    XCTAssertEqual(board.groups[.planned]?.last?.startedAt, now)

    let data = try JSONEncoder().encode(board)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let groups = try XCTUnwrap(object["groups"] as? [String: [Any]])
    XCTAssertEqual(Set(groups.keys), Set(BotBoardGroup.allCases.map(\.rawValue)))
    XCTAssertEqual(try JSONDecoder().decode(BotBoard.self, from: data), board)
  }

  func testClosedHistoryUsesTerminalTimeBeforePinOrderAndKeepsFullCount() {
    let now = BoardFixture.now
    var input = BoardFixture.input()
    input.sessions = (0..<25).map { index in
      BotBoardSessionInput(
        session: BoardFixture.session("done-\(index)", .completed, updatedAt: now.addingTimeInterval(TimeInterval(index - 25))),
        finalMessageLine: "result-\(index)"
      )
    }
    let baseline = BotBoardProjector.board(input)
    XCTAssertEqual(baseline.closedTotal, 25)
    XCTAssertEqual(baseline.groups[.closed]?.map(\.itemId), (5...24).reversed().map { "done-\($0)" })

    for id in ["done-0", "done-10"] {
      input.listStates[BotListStateKey(itemKind: "session", itemId: id)] = BotListState(pinned: true)
    }
    let pinned = BotBoardProjector.board(input)
    XCTAssertEqual(pinned.groups[.closed]?.first?.itemId, "done-10")
    XCTAssertFalse(pinned.groups[.closed]?.contains { $0.itemId == "done-0" } ?? true)
    XCTAssertEqual(BotBoardProjector.overviewRow(input).lastResult, "result-24")
  }

  func testLastResultRedactsBeforeTruncationAndUsesOneLine() throws {
    var session = BoardFixture.session("failed", .failed)
    session.failureReason = "Token secret " + String(repeating: "x", count: 220) + "\nprivate detail"
    var input = BoardFixture.input()
    input.sessions = [BotBoardSessionInput(session: session, finalMessageLine: "ignored")]
    input.redact = { $0.replacingOccurrences(of: "secret", with: "[redacted]") }
    let result = try XCTUnwrap(BotBoardProjector.overviewRow(input).lastResult)
    XCTAssertTrue(result.hasPrefix("Token [redacted]"))
    XCTAssertEqual(result.count, 200)
    XCTAssertFalse(result.contains(where: \.isNewline))
    XCTAssertEqual(
      BotBoardProjector.lastResultLine(session: session, finalMessageLine: nil, redact: { _ in "safe\nextra" }), "safe"
    )

    session.failureReason = "Token first\nsecond"
    let multiline = BotBoardProjector.lastResultLine(session: session, finalMessageLine: nil) {
      $0.replacingOccurrences(of: "first\nsecond", with: "[redacted]")
    }
    XCTAssertEqual(multiline, "Token [redacted]")
  }

  func testEmptyAndWorkingOverview() {
    var input = BoardFixture.input()
    let empty = BotBoardProjector.overviewRow(input)
    XCTAssertEqual(empty.counts, BotOverviewCounts(needsYou: 0, working: 0, waiting: 0, planned: 0))
    XCTAssertNil(empty.lastActivityAt)
    XCTAssertNil(empty.lastResult)

    input.sessions = [
      BotBoardSessionInput(session: BoardFixture.session("run", .running)),
      BotBoardSessionInput(session: BoardFixture.session("done", .completed), finalMessageLine: "Complete")
    ]
    let working = BotBoardProjector.overviewRow(input)
    XCTAssertEqual(working.counts.working, 1)
    XCTAssertEqual(working.inProgress.map(\.itemId), ["run"])
    XCTAssertNil(working.lastResult)
  }
}
