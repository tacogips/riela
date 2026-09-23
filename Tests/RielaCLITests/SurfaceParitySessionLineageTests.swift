import Foundation
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

/// CLI/GraphQL parity for the session mutations (CSP-5). A rerun issued from a
/// shell and one issued over `/graphql` must take the same runner path and
/// produce the same lineage; `stopSession` must persist a terminal state before
/// it answers.
final class SurfaceParitySessionLineageTests: XCTestCase {
  func testCLIAndGraphQLRerunProduceTheSameLineage() async throws {
    let fixture = try await Self.completedSession()
    defer { try? FileManager.default.removeItem(at: fixture.store) }

    let cli = await RielaCLIApplication().run([
      "session", "rerun", fixture.sessionId, "main-worker",
      "--workflow-definition-dir", "\(fixture.repositoryRoot)/examples",
      "--mock-scenario", "\(fixture.repositoryRoot)/examples/worker-only-single-step/mock-scenario.json",
      "--working-directory", fixture.store.path,
      "--session-store", fixture.store.path,
      "--output", "json"
    ], environment: ["HOME": fixture.store.path])
    XCTAssertEqual(cli.exitCode, .success, cli.stderr)
    let cliRecord = try JSONDecoder().decode(
      SessionRerunCommandResult.self,
      from: Data(cli.stdout.utf8)
    )

    let provider = RielaSessionControlProvider(
      workingDirectory: fixture.store.path,
      sessionStore: fixture.store.path,
      workflowDefinitionDir: "\(fixture.repositoryRoot)/examples",
      registry: RielaRunningSessionRegistry()
    )
    let payload = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.store.path]) {
      try await provider.rerunSession(GraphQLRerunSessionInput(
        workflowId: fixture.workflowId,
        sessionId: fixture.sessionId,
        stepId: "main-worker"
      ))
    }

    XCTAssertTrue(payload.result.accepted)
    XCTAssertEqual(payload.status, cliRecord.status.rawValue)
    let lineage = try XCTUnwrap(payload.lineage)
    XCTAssertEqual(lineage.sourceStepId, cliRecord.rerunFromStepId)
    XCTAssertEqual(lineage.entryMode, cliRecord.recovery?.entryMode.rawValue ?? LoopEntryMode.rerun.rawValue)
    XCTAssertEqual(lineage.rootSessionId, cliRecord.recovery?.rootSessionId ?? cliRecord.sourceSessionId)
    XCTAssertNotEqual(lineage.sessionId, fixture.sessionId, "a rerun starts a new session")
  }

  /// R4: the id a rerun reports is not a stop handle. A run is stopped by the
  /// id it was entered from, which is what the provider registers.
  func testStopUsesTheEnteredSessionIdNotTheIdTheRerunReports() async throws {
    let fixture = try await Self.completedSession()
    defer { try? FileManager.default.removeItem(at: fixture.store) }
    let provider = RielaSessionControlProvider(
      workingDirectory: fixture.store.path,
      sessionStore: fixture.store.path,
      workflowDefinitionDir: "\(fixture.repositoryRoot)/examples",
      registry: RielaRunningSessionRegistry()
    )
    let payload = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.store.path]) {
      try await provider.rerunSession(GraphQLRerunSessionInput(
        workflowId: fixture.workflowId,
        sessionId: fixture.sessionId,
        stepId: "main-worker"
      ))
    }
    let reportedSessionId = try XCTUnwrap(payload.sessionId)
    XCTAssertNotEqual(reportedSessionId, fixture.sessionId)
    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.store.path]) {
        try await provider.stopSession(GraphQLStopSessionInput(
          workflowId: fixture.workflowId,
          sessionId: reportedSessionId
        ))
      }
      XCTFail("the id a rerun reports must not be accepted as a stop handle")
    } catch let error as GraphQLSessionControlError {
      XCTAssertEqual(error.code, "SESSION_NOT_RUNNING")
    }
  }

  /// R5: a session may only be driven through the workflow it belongs to.
  func testSessionControlRejectsAWorkflowThatDoesNotOwnTheSession() async throws {
    let fixture = try await Self.completedSession()
    defer { try? FileManager.default.removeItem(at: fixture.store) }
    let provider = RielaSessionControlProvider(
      workingDirectory: fixture.store.path,
      sessionStore: fixture.store.path,
      workflowDefinitionDir: "\(fixture.repositoryRoot)/examples",
      registry: RielaRunningSessionRegistry()
    )
    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.store.path]) {
        try await provider.resumeSession(GraphQLResumeSessionInput(
          workflowId: "not-the-owning-workflow",
          sessionId: fixture.sessionId
        ))
      }
      XCTFail("a session must not be resumable through a workflow that does not own it")
    } catch let error as GraphQLSessionControlError {
      XCTAssertEqual(error.code, "SESSION_WORKFLOW_MISMATCH")
      XCTAssertTrue(error.message.contains(fixture.workflowId))
    }

    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.store.path]) {
        try await provider.rerunSession(GraphQLRerunSessionInput(
          workflowId: "not-the-owning-workflow",
          sessionId: fixture.sessionId,
          stepId: "main-worker"
        ))
      }
      XCTFail("a session must not be rerunnable through a workflow that does not own it")
    } catch let error as GraphQLSessionControlError {
      XCTAssertEqual(error.code, "SESSION_WORKFLOW_MISMATCH")
    }
  }

  /// Delta D3: stop never reaches across processes.
  func testStoppingASessionThisProcessDoesNotRunFailsClosed() async {
    let provider = RielaSessionControlProvider(registry: RielaRunningSessionRegistry())
    do {
      _ = try await provider.stopSession(GraphQLStopSessionInput(
        workflowId: "workflow-a",
        sessionId: "not-running-here"
      ))
      XCTFail("stopping a session this process does not run must fail")
    } catch let error as GraphQLSessionControlError {
      XCTAssertEqual(error.code, "SESSION_NOT_RUNNING")
      XCTAssertEqual(error.message, "session_not_running: not-running-here")
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  /// A registered session is cancelled and awaited, so the answer comes after
  /// the runner's terminal write, not before it.
  func testStopCancelsAndAwaitsTheRegisteredSession() async {
    let registry = RielaRunningSessionRegistry()
    let finished = FinishedFlag()
    let task = Task<Void, Never> {
      while !Task.isCancelled {
        await Task.yield()
      }
      await finished.set()
    }
    await registry.register(sessionId: "live", task: task)
    let cancelled = await registry.cancelAndAwait(sessionId: "live")
    XCTAssertTrue(cancelled)
    let didFinish = await finished.value
    XCTAssertTrue(didFinish, "cancelAndAwait must return only after the session task finished")
    let again = await registry.cancelAndAwait(sessionId: "live")
    XCTAssertFalse(again, "a session is unregistered once stopped")
  }

  // MARK: - Fixture

  private struct Fixture {
    var store: URL
    var repositoryRoot: String
    var sessionId: String
    var workflowId: String
  }

  private static func completedSession() async throws -> Fixture {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
    let store = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-lineage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(repositoryRoot)/examples",
      "--mock-scenario", "\(repositoryRoot)/examples/worker-only-single-step/mock-scenario.json",
      "--working-directory", store.path,
      "--session-store", store.path,
      "--output", "json"
    ], environment: ["HOME": store.path])
    guard run.exitCode == .success else {
      throw XCTSkip("the fixture workflow did not run: \(run.stderr)")
    }
    // Only the identities matter here, and `WorkflowRunResult` carries dates in
    // the runner's own encoding; decode the two fields directly.
    let result = try JSONDecoder().decode(RunIdentities.self, from: Data(run.stdout.utf8))
    return Fixture(
      store: store,
      repositoryRoot: repositoryRoot,
      sessionId: result.session.sessionId,
      workflowId: result.workflowId
    )
  }
}

private struct RunIdentities: Decodable {
  struct Session: Decodable { let sessionId: String }
  let workflowId: String
  let session: Session
}

private actor FinishedFlag {
  private(set) var value = false

  func set() { value = true }
}
