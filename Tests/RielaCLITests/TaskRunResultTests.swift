import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskRunResultTests: XCTestCase {
  func testTextPreviewIncludesProspectivePlacement() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    _ = try harness.seed("task-repair-loop")
    let result = try await dispatch(harness, output: .text, dryRun: true)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("status: ready"), result.stdout)
    XCTAssertTrue(result.stdout.contains("placement: task-repair-loop/"), result.stdout)
    XCTAssertTrue(result.stdout.contains("host=local"), result.stdout)
    XCTAssertTrue(result.stdout.contains("backend="), result.stdout)
    XCTAssertFalse(result.stdout.contains("attemptId:"))
  }

  func testStructuredPreAdmissionErrorUsesTaskFailureEnvelope() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let result = try await dispatch(harness, output: .json, dryRun: true)
    XCTAssertEqual(result.exitCode, .failure)
    let error = try JSONDecoder().decode(TaskCommandFailureResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(error.taskId, "task-task-repair-loop")
    XCTAssertEqual(error.command, "run")
    XCTAssertEqual(error.exitCode, CLIExitCode.failure.rawValue)
  }

  func testStructuredReadyAndTextWaitRetainPlacementAndNoIdentity() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let prerequisite = try harness.seed("prerequisite")
    _ = try harness.seed("task-repair-loop", dependsOn: [prerequisite.id])
    let waiting = try await dispatch(harness, output: .text, dryRun: true)
    XCTAssertEqual(waiting.exitCode, .success)
    XCTAssertTrue(waiting.stdout.contains("status: waiting"), waiting.stdout)
    XCTAssertTrue(waiting.stdout.contains("waitReason: dependency"), waiting.stdout)
    XCTAssertFalse(waiting.stdout.contains("attemptId:"))
    var completed = prerequisite
    completed.state = .succeeded
    try harness.store.saveTask(completed)
    let ready = try await dispatch(harness, output: .json, dryRun: true)
    XCTAssertEqual(ready.exitCode, .success)
    let response = try harness.decode(ready)
    XCTAssertEqual(response.status, "ready")
    XCTAssertFalse(response.placement?.choices.isEmpty ?? true)
    XCTAssertNil(response.attemptId)
    XCTAssertNil(response.sessionId)
  }

  func testAdmittedExecutionFailureRetainsDurableIdentityInTextAndJSON() async throws {
    for output in [WorkflowOutputFormat.text, .json] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      let task = try harness.seed("task-repair-loop")
      let scenario = harness.sessionStore.appendingPathComponent("failed-scenario.json")
      try Data(#"{"repair":{"provider":"scenario-mock","fail":true}}"#.utf8).write(to: scenario)
      let result = try await dispatch(
        harness, output: output, dryRun: false, mockScenarioPath: scenario.path
      )
      XCTAssertEqual(result.exitCode, .failure)
      let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
      if output == .json {
        let response = try harness.decode(result)
        XCTAssertEqual(response.status, "failed")
        XCTAssertEqual(response.attemptId, attempt.id.rawValue)
        XCTAssertEqual(response.sessionId, attempt.sessionId)
      } else {
        XCTAssertTrue(result.stdout.contains("status: failed"), result.stdout)
        XCTAssertTrue(result.stdout.contains("attemptId: \(attempt.id.rawValue)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("sessionId: \(attempt.sessionId)"), result.stdout)
      }
    }
  }

  func testAdmittedErrorReportsDurableAttemptAndSession() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let result = try await dispatch(
      harness, output: .json, dryRun: false,
      mockScenarioPath: harness.sessionStore.appendingPathComponent("missing-scenario.json").path
    )
    XCTAssertEqual(result.exitCode, .failure)
    let response = try harness.decode(result)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(response.attemptId, attempt.id.rawValue)
    XCTAssertEqual(response.sessionId, attempt.sessionId)
    XCTAssertNotNil(response.error)
  }

  private func dispatch(
    _ harness: TaskExampleHarness,
    output: WorkflowOutputFormat,
    dryRun: Bool,
    mockScenarioPath: String? = nil
  ) async throws -> CLICommandResult {
    let resolver = TaskExampleBundleResolver(bundle: try harness.bundle("task-repair-loop"))
    return await TaskDispatch(
      resolver: resolver,
      hostResolver: ResultTestHostResolver(),
      runner: WorkflowRunCommand(resolver: resolver),
      mockScenarioPath: mockScenarioPath
    ).run(
      taskId: "task-task-repair-loop",
      options: TaskStoreOptions(
        scope: .project, workingDirectory: harness.repository.path,
        sessionStore: harness.sessionStore.path
      ),
      dryRun: dryRun,
      output: output
    )
  }
}

private struct ResultTestHostResolver: HostCapabilityResolving {
  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    let now = Date()
    return [HostCapabilitySnapshot(
      hostId: "local", capacity: 1,
      backends: [BackendCapability(
        backend: .codexAgent, source: .observed, observedAt: now,
        availability: .available, authentication: .available, models: ["gpt-5.4-mini"]
      )], refreshedAt: now
    )]
  }
}
