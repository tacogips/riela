import Foundation
import RielaCore
import RielaGraphQL
import RielaWork
import XCTest
@testable import RielaCLI

final class BotActivityCommandTests: XCTestCase {
  func testReplayCursorsAndTruncatedText() async throws {
    let fixture = try fixture(retention: 4)
    try await fixture.start("replay")
    await fixture.recorder.record(
      sessionId: "replay", executionId: "execution-replay",
      update: .plan(planId: "release", entries: [.init(content: "Ship", status: "pending", priority: "high")]),
      at: fixture.at
    )
    await fixture.recorder.record(
      sessionId: "replay", executionId: "execution-replay",
      update: .toolCall(.init(toolCallId: "shipping", title: "Publish", status: "inProgress")), at: fixture.at
    )
    for index in 3...5 {
      await fixture.notice("event-\(index)", sessionId: "replay")
    }

    let replay = await fixture.run(["activity", "--session", "replay", "--output", "json"])
    let page = try fixture.decode(BotActivityPage.self, result: replay)
    XCTAssertEqual(page.events.map(\.seq), [3, 4, 5, 6])
    XCTAssertEqual(page.activitySource, "acp")
    XCTAssertEqual(page.firstRetainedSequence, 3)
    XCTAssertTrue(page.truncated)

    let slice = await fixture.run(["activity", "--session", "replay", "--after", "3", "--limit", "2", "--output", "json"])
    let slicedPage = try fixture.decode(BotActivityPage.self, result: slice)
    XCTAssertEqual(slicedPage.events.map(\.seq), [4, 5])
    XCTAssertEqual(slicedPage.lastSequence, 5)
    XCTAssertFalse(slicedPage.truncated)

    let text = await fixture.run(["activity", "--session", "replay"])
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.hasPrefix("activitySource: acp\n(earlier events were trimmed; state follows)\n"))
    XCTAssertTrue(text.stdout.contains("Plan:\n  [pending] Ship\nOpen tool calls:\n  Publish\nPending requests:\n"))
    XCTAssertTrue(text.stdout.contains("6 14:13:20 notice event-5"))
  }

  func testFollowEmitsLiveBeforeSessionSettlesAndDrainsEveryPage() async throws {
    let fixture = try fixture()
    try await fixture.start("follow")
    let firstPage = expectation(description: "The follow writer receives a page before settlement")
    let output = ActivityLineCapture()
    let follower = Task {
      await fixture.run(["activity", "--session", "follow", "--follow", "--limit", "1", "--output", "jsonl"], writer: {
        if output.append($0) { firstPage.fulfill() }
      })
    }
    defer { follower.cancel() }
    await fulfillment(of: [firstPage], timeout: 5)
    await fixture.notice("while-following", sessionId: "follow")
    await fixture.recorder.settle(
      sessionId: "follow", executionId: "execution-follow", reason: .completed, stepStatus: "completed", at: fixture.at
    )
    try fixture.save("follow", status: .completed)
    let finished = await follower.value
    XCTAssertEqual(finished.exitCode, .success, finished.stderr)
    XCTAssertEqual(finished.stdout, "")
    let events = try output.text.split(separator: "\n").map {
      try fixture.decoder.decode(ActivityEvent.self, from: Data($0.utf8))
    }
    XCTAssertEqual(events.map(\.seq), [1, 2, 3, 4])
    XCTAssertEqual(events.map(\.kind), [.stepStarted, .notice, .stepFinished, .settled])
  }

  func testMissingSessionEndsFollow() async throws {
    let fixture = try fixture()
    let result = await fixture.run(["activity", "--session", "missing", "--follow", "--output", "json"])
    let page = try fixture.decode(BotActivityPage.self, result: result)
    XCTAssertEqual(page.sessionStatus, "unknown")
    XCTAssertEqual(page.events, [])
  }

  func testBotActivityPicksNeedsYouBeforeRunning() async throws {
    let fixture = try fixture()
    let created = await fixture.run(["create", "--name", "Release Bot"])
    XCTAssertEqual(created.exitCode, .success, created.stderr)
    try await fixture.start("older-running", offset: -60)
    try await fixture.start("needs-you")
    for id in ["older-running", "needs-you"] {
      try fixture.store.linkSession(sessionId: id, botId: "release-bot", source: "run", at: fixture.at)
    }
    let waiting = fixture.request("needs-you")
    defer { waiting.cancel() }
    let id = try await fixture.pendingRequestId("needs-you")
    let activity = await fixture.run(["activity", "release-bot", "--output", "json"])
    let page = try fixture.decode(BotActivityPage.self, result: activity)
    XCTAssertEqual(Set(page.events.map(\.sessionId)), ["needs-you"])
    XCTAssertEqual(page.state?.pendingRequestIds, [id])
    _ = try fixture.store.answerActivityRequest(requestId: id, decline: true)
    _ = await waiting.value
  }

  func testAnswerValidatesOptionsAndReleasesTheWaitingRecorder() async throws {
    let fixture = try fixture()
    try await fixture.start("approval")
    let waiting = fixture.request("approval")
    defer { waiting.cancel() }
    let requestId = try await fixture.pendingRequestId("approval")
    for (flags, code) in [
      ([], "request_answer_invalid"),
      (["--option", "allow-1", "--decline"], "request_answer_invalid"),
      (["--option", "nope"], "request_option_unknown")
    ] {
      let invalid = await fixture.run(["answer", requestId] + flags)
      XCTAssertEqual(invalid.exitCode, .failure)
      XCTAssertTrue(invalid.stderr.contains(code), invalid.stderr)
    }
    let approved = await fixture.run(["answer", requestId, "--option", "allow-1"])
    XCTAssertEqual(approved.exitCode, .success, approved.stderr)
    XCTAssertEqual(approved.stdout, "answered\n")
    let outcome = await waiting.value
    XCTAssertEqual(outcome, .selected(optionId: "allow-1"))
    let duplicate = await fixture.run(["answer", requestId, "--decline"])
    XCTAssertEqual(duplicate.exitCode, .failure)
    XCTAssertTrue(duplicate.stderr.contains("request_already_resolved"), duplicate.stderr)

    let anotherRequest = fixture.request("approval")
    defer { anotherRequest.cancel() }
    let declineId = try await fixture.pendingRequestId("approval")
    let declined = await fixture.run(["answer", declineId, "--decline"])
    XCTAssertEqual(declined.exitCode, .success, declined.stderr)
    let declinedOutcome = await anotherRequest.value
    XCTAssertEqual(declinedOutcome, .cancelled)
  }

  func testWorkQuestionUsesTaskAnswerHint() async throws {
    let fixture = try fixture()
    let store = WorkStore(rootDirectory: fixture.store.sessionStoreRoot)
    let task = WorkTask(id: TaskID("task"), intentId: IntentID("intent"), title: "Review", instruction: "Review the result")
    let question = HandoverQuestion(id: "work-question", text: "Proceed?", answerSchema: ["type": .string("object")])
    try store.saveTask(task)
    let packet = try HandoverPacket(
      id: HandoverID("handover"), taskId: task.id, intentId: task.intentId, fromAttemptId: AttemptID("attempt"),
      fromSessionId: "session", generation: 1, reason: .userInputRequired(question),
      workflow: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"),
      progress: HandoverProgress(
        acceptedSteps: [], remainingSteps: ["start"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)
      ),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(
        resumeStepId: "start", completion: task.completion, verification: [], guardPolicy: task.guardPolicy
      ),
      brief: "Ask the user", producedBy: .runtime, producedOn: "test", createdAt: fixture.at
    ).sealed()
    try store.saveHandover(packet)
    let result = await fixture.run(["answer", question.id, "--decline"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("request_not_found"), result.stderr)
    XCTAssertTrue(result.stderr.contains("not a permission request; answer handover questions with riela task answer"), result.stderr)
  }

  private func fixture(retention: Int = 2_000) throws -> ActivityCommandFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-12-activity-surfaces/test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return ActivityCommandFixture(root: root, retention: retention)
  }
}

private struct ActivityCommandFixture {
  let root: URL
  let recorder: SQLiteWorkflowActivityRecorder
  let at = Date(timeIntervalSince1970: 1_790_000_000)

  init(root: URL, retention: Int) {
    self.root = root
    recorder = SQLiteWorkflowActivityRecorder(
      sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: root.appendingPathComponent("sessions").path),
      limits: ActivityLimits(maxEventsPerSession: retention, requestPollIntervalMs: 20)
    )
  }

  var sessions: String { root.appendingPathComponent("sessions").path }
  var store: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions)) }
  var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  func run(_ arguments: [String], writer: (@Sendable (String) -> Void)? = nil) async -> CLICommandResult {
    await RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(followRecordWriter: writer)).run(
      ["bot"] + arguments + ["--working-dir", root.path, "--session-store", sessions],
      environment: ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                    "RIELA_WORKFLOW_HOME": root.appendingPathComponent("workflow-home").path]
    )
  }

  func decode<T: Decodable>(_ type: T.Type, result: CLICommandResult) throws -> T {
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    return try decoder.decode(type, from: Data(result.stdout.utf8))
  }

  func save(_ sessionId: String, status: WorkflowSessionStatus, offset: TimeInterval = 0) throws {
    let timestamp = at.addingTimeInterval(offset)
    let session = WorkflowSession(
      workflowId: "flow", sessionId: sessionId, status: status, entryStepId: "start", currentStepId: "start",
      createdAt: timestamp, updatedAt: timestamp
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot).save(.init(session: session))
  }

  func start(_ sessionId: String, offset: TimeInterval = 0) async throws {
    try save(sessionId, status: .running, offset: offset)
    await recorder.stepStarted(
      sessionId: sessionId, executionId: "execution-\(sessionId)", stepId: "start", nodeId: "worker",
      backend: nil, requestedModel: nil, at: at.addingTimeInterval(offset)
    )
  }

  func notice(_ title: String, sessionId: String) async {
    await recorder.record(
      sessionId: sessionId, executionId: "execution-\(sessionId)",
      update: .notice(severity: "info", title: title, description: nil), at: at
    )
  }

  func request(_ sessionId: String) -> Task<AdapterPermissionOutcome, Never> {
    Task {
      await recorder.requestPermission(
        sessionId: sessionId, executionId: "execution-\(sessionId)",
        request: AdapterPermissionRequest(
          title: "Continue?", options: [AdapterPermissionOption(optionId: "allow-1", name: "Allow", kind: "allow_once")]
        ), waitMs: 10_000, deadline: nil
      )
    }
  }

  func pendingRequestId(_ sessionId: String) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    repeat {
      if let record = try store.pendingActivityRequests(sessionIds: [sessionId]).first {
        return record.requestId
      }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    throw BotStoreError(code: "missing_fixture_request", message: "The recorder did not create a pending request")
  }
}

private final class ActivityLineCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = ""

  var text: String { lock.withLock { buffer } }

  func append(_ line: String) -> Bool {
    lock.withLock {
      let first = buffer.isEmpty
      buffer += line
      return first
    }
  }
}
