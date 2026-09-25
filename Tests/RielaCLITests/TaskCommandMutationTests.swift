import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskCommandMutationTests: XCTestCase {
  private var sessionStore: URL!
  private var store: WorkStore!

  override func setUpWithError() throws {
    sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-task-decision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionStore)
  }

  func testRejectIsDurableAndIdenticalReplayReturnsOriginalApplication() async throws {
    try seedAttempt()
    let arguments = [
      "task", "decide", "task-1", "--reject", "review failed", "--principal", "operator",
      "--expected-version", "1", "--decision-id", "decision-human-1", "--output", "json"
    ]
    let first = await run(arguments)
    XCTAssertEqual(first.exitCode, .success, first.stderr)
    let payload = try JSONDecoder().decode(TaskDecisionCommandResult.self, from: Data(first.stdout.utf8))
    XCTAssertEqual(payload.state, .failed)
    XCTAssertEqual(payload.version, 2)
    XCTAssertEqual(payload.attemptId, "attempt-1")

    let replay = await run(arguments)
    XCTAssertEqual(replay.exitCode, .success, replay.stderr)
    XCTAssertEqual(replay.stdout, first.stdout)
    XCTAssertEqual(try store.listDecisions(taskId: TaskID("task-1")).count, 1)
    XCTAssertEqual(try store.listEvidence(taskId: TaskID("task-1")).filter { $0.kind == .decision }.count, 1)
  }

  func testConflictingReplayAndStaleVersionLeaveStoreUnchanged() async throws {
    try seedAttempt()
    let common = ["--principal", "operator", "--expected-version", "1", "--decision-id", "decision-human-1"]
    let first = await run(["task", "decide", "task-1", "--reject", "review failed"] + common)
    XCTAssertEqual(first.exitCode, .success, first.stderr)
    let conflict = await run(["task", "decide", "task-1", "--reject", "different reason"] + common)
    XCTAssertEqual(conflict.exitCode, .failure)
    XCTAssertTrue(conflict.stdout.contains("conflicts"), conflict.stdout)
    let stale = await run([
      "task", "decide", "task-1", "--cancel", "--principal", "operator",
      "--expected-version", "1", "--decision-id", "decision-human-2"
    ])
    XCTAssertEqual(stale.exitCode, .failure)
    XCTAssertEqual(try store.loadTask(id: TaskID("task-1"))?.state, .failed)
    XCTAssertEqual(try store.listDecisions(taskId: TaskID("task-1")).count, 1)
  }

  func testDecisionWithoutCausalEvidenceFailsClosed() async throws {
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"),
      title: "Task", instruction: "Run", state: .needsDecision
    )
    try store.saveTask(task)
    let result = await run([
      "task", "decide", "task-1", "--cancel", "--principal", "operator",
      "--expected-version", "1", "--decision-id", "decision-human-1"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("causal evidence"), result.stderr)
    XCTAssertEqual(try store.loadTask(id: task.id), task)
  }

  func testRerunEnqueuesOneDurablePendingRequestAndReplays() async throws {
    try seedAttempt()
    let arguments = [
      "task", "decide", "task-1", "--rerun", "review", "--principal", "operator",
      "--expected-version", "1", "--decision-id", "decision-human-rerun", "--output", "json"
    ]
    let first = await run(arguments)
    XCTAssertEqual(first.exitCode, .success, first.stderr)
    let result = try JSONDecoder().decode(TaskDecisionCommandResult.self, from: Data(first.stdout.utf8))
    XCTAssertEqual(result.state, .scheduled)
    XCTAssertEqual(result.version, 2)
    XCTAssertEqual(try store.listDecisions(taskId: TaskID("task-1")).count, 1)

    let replay = await run(arguments)
    XCTAssertEqual(replay.exitCode, .success, replay.stderr)
    XCTAssertEqual(replay.stdout, first.stdout)
    XCTAssertEqual(try store.listDecisions(taskId: TaskID("task-1")).count, 1)
  }

  private func seedAttempt() throws {
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"),
      title: "Task", instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")),
      state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1",
      state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try store.saveAttempt(attempt)
    try store.saveEvidence(Evidence(
      id: EvidenceID("evidence-cause"), taskId: task.id, attemptId: attempt.id,
      kind: .verification, producedBy: .runtime,
      payloadRef: .inline(["id": .string("tests"), "outcome": .string("failed")]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    ))
  }

  private func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(arguments, environment: ["RIELA_SESSION_STORE": sessionStore.path])
  }
}
