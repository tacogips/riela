import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskHandoverCommandTests: XCTestCase {
  private var sessionStore: URL!
  private var store: WorkStore!

  override func setUpWithError() throws {
    sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-task-handover-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path))
    try store.saveTask(WorkTask(
      id: TaskID("task-cli"), intentId: IntentID("intent-cli"), title: "CLI handover",
      instruction: "Exercise the handover CLI.", plan: .workflow(WorkflowReference(name: "fixture")), state: .waiting
    ))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionStore)
  }

  func testTaskCommandRoutingIncludesHandoverSurface() throws {
    let parser = RielaArgumentParser()
    for subcommand in ["handover", "takeover", "answer", "handovers"] {
      guard case let .task(command) = try parser.parse(["task", subcommand, "task-cli"]) else {
        return XCTFail("expected task command for \(subcommand)")
      }
      XCTAssertEqual(command.kind.rawValue, subcommand)
    }
    guard case let .task(reconcile) = try parser.parse(["task", "reconcile"]) else {
      return XCTFail("expected task reconcile command")
    }
    XCTAssertEqual(reconcile.kind, .reconcile)
    guard case let .session(.handover(options)) = try parser.parse([
      "session", "handover", "session-1", "--task", "task-cli"
    ]) else { return XCTFail("expected session handover command") }
    XCTAssertEqual(options.target, "session-1")
    XCTAssertTrue(options.arguments.contains("--task"))
  }

  func testTakeoverRejectsUnknownTraitByName() async {
    let result = await run(["task", "takeover", "task-cli", "--traits", "bogus"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("bogus"), result.stderr)
  }

  func testForceOrphanFlagReachesOrphanFenceRuntime() async {
    let result = await run(["task", "takeover", "task-cli", "--force-orphan"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("has no lease"), result.stderr)
  }

  func testAnswerRequiresExactlyOnePayloadFlag() async {
    let result = await run([
      "task", "answer", "task-cli", "--question", "q1", "--text", "one", "--option", "staging"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("exactly one payload flag"), result.stderr)
  }

  func testReconcileRequiresExpiredLeasesFlag() async {
    let result = await run(["task", "reconcile"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("supports --expired-leases"), result.stderr)
  }

  func testImmediateHandoverWithoutRunningAttemptFails() async {
    let result = await run(["task", "handover", "task-cli", "--reason", "move", "--now"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("requires a running attempt"), result.stderr)
  }

  func testShowIncludesHandoverLeaseAndSuspendFields() async throws {
    let result = await run(["task", "show", "task-cli", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try JSONDecoder().decode(TaskShowCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.handovers, [])
    XCTAssertNil(payload.lease)
    XCTAssertNil(payload.suspend)
  }

  func testHandoversReturnsEmptyListForTaskWithoutHandover() async throws {
    let result = await run(["task", "handovers", "task-cli", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try JSONDecoder().decode(TaskHandoversCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.taskId, "task-cli")
    XCTAssertEqual(payload.handovers, [])
  }

  private func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(
      arguments + ["--session-store", sessionStore.path],
      environment: ["RIELA_SESSION_STORE": sessionStore.path]
    )
  }
}
