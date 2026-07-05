import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

final class NoteAutoActionWorkflowDispatcherTests: XCTestCase {
  func testDefaultTaskLauncherBlocksCallerUntilOperationCompletes() async {
    let launcher = NoteAutoActionTaskLauncher()
    let completed = expectation(description: "background operation completed")
    let startedAt = Date()

    launcher.launch {
      try? await Task.sleep(nanoseconds: 100_000_000)
      completed.fulfill()
    }

    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.09)
    await fulfillment(of: [completed], timeout: 0.1)
  }

  func testDispatchResolvesAndLaunchesWorkflowRunWithNoteEventVariables() async throws {
    let resolver = RecordingWorkflowBundleResolver()
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .success))
    let launcher = CapturingAutoActionTaskLauncher()
    let diagnostics = RecordingAutoActionDiagnostics()
    let dispatcher = NoteAutoActionWorkflowDispatcher(
      resolver: resolver,
      runner: runner,
      taskLauncher: launcher,
      diagnosticRecorder: diagnostics,
      workingDirectory: "/tmp/project",
      maxSteps: 12,
      sessionStore: "/tmp/project/.riela/sessions",
      noteRoot: "/tmp/project/.riela/note"
    )

    let outcomes = RecordingAutoActionDispatchOutcomes()
    try dispatcher.dispatch(record(), completion: outcomes.record)
    XCTAssertEqual(resolver.options().map(\.workflowName), ["ai-tag-workflow"])
    XCTAssertEqual(launcher.operationCount(), 1)
    XCTAssertEqual(outcomes.records(), [])

    await launcher.drain()
    let options = await runner.recordedOptions()
    XCTAssertEqual(options.count, 1)
    XCTAssertEqual(options.first?.target, "ai-tag-workflow")
    XCTAssertEqual(options.first?.resolution?.workflowName, "ai-tag-workflow")
    XCTAssertEqual(options.first?.workingDirectory, "/tmp/project")
    XCTAssertEqual(options.first?.maxSteps, 12)
    XCTAssertEqual(options.first?.sessionStore, "/tmp/project/.riela/sessions")

    let variables = try XCTUnwrap(options.first?.variables)
    let object = try JSONReferenceLoader().object(from: variables)
    XCTAssertEqual(string(object["noteId"]), "note-1")
    XCTAssertEqual(string(object["notebookId"]), "notebook-1")
    XCTAssertEqual(string(object["noteBodyMarkdown"]), "# Note\nBody")
    XCTAssertEqual(string(object["originatingActionId"]), "auto-action-1")
    XCTAssertEqual(string(object["trigger"]), "note-created")
    XCTAssertEqual(string(object["noteRoot"]), "/tmp/project/.riela/note")

    let workflowInput = try objectValue(object["workflowInput"])
    XCTAssertEqual(string(workflowInput["originatingActionId"]), "auto-action-1")
    XCTAssertEqual(string(workflowInput["actionId"]), "auto-action-1")
    XCTAssertEqual(string(workflowInput["workflowId"]), "ai-tag-workflow")
    XCTAssertEqual(string(workflowInput["noteRoot"]), "/tmp/project/.riela/note")

    let event = try objectValue(object["event"])
    XCTAssertEqual(string(event["trigger"]), "note-created")
    XCTAssertEqual(string(event["noteId"]), "note-1")
    XCTAssertEqual(outcomes.records(), [.succeeded])
    XCTAssertTrue(diagnostics.records().isEmpty)
  }

  func testUnresolvedWorkflowSkipsLaunchAndRecordsDiagnostic() throws {
    let resolver = RecordingWorkflowBundleResolver(error: WorkflowResolutionError.notFound("missing", ["not installed"]))
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .success))
    let launcher = CapturingAutoActionTaskLauncher()
    let diagnostics = RecordingAutoActionDiagnostics()
    let dispatcher = NoteAutoActionWorkflowDispatcher(
      resolver: resolver,
      runner: runner,
      taskLauncher: launcher,
      diagnosticRecorder: diagnostics
    )

    let outcomes = RecordingAutoActionDispatchOutcomes()
    XCTAssertThrowsError(try dispatcher.dispatch(record(workflowId: "missing"), completion: outcomes.record))

    XCTAssertEqual(launcher.operationCount(), 0)
    XCTAssertEqual(outcomes.records(), [])
    XCTAssertEqual(diagnostics.records().map(\.code), [.workflowUnresolved])
    XCTAssertEqual(diagnostics.records().first?.actionId, "auto-action-1")
    XCTAssertEqual(diagnostics.records().first?.workflowId, "missing")
    XCTAssertTrue(diagnostics.records().first?.message.contains("not installed") == true)
  }

  func testWorkflowRunFailureRecordsDiagnosticAndCompletesAsFailed() async throws {
    let resolver = RecordingWorkflowBundleResolver()
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .failure, stderr: "run failed"))
    let launcher = CapturingAutoActionTaskLauncher()
    let diagnostics = RecordingAutoActionDiagnostics()
    let dispatcher = NoteAutoActionWorkflowDispatcher(
      resolver: resolver,
      runner: runner,
      taskLauncher: launcher,
      diagnosticRecorder: diagnostics
    )

    let outcomes = RecordingAutoActionDispatchOutcomes()
    try dispatcher.dispatch(record(), completion: outcomes.record)

    XCTAssertEqual(launcher.operationCount(), 1)
    await launcher.drain()
    let options = await runner.recordedOptions()
    XCTAssertEqual(options.count, 1)
    XCTAssertEqual(diagnostics.records().map(\.code), [.workflowRunFailed])
    XCTAssertEqual(diagnostics.records().first?.message, "run failed")
    XCTAssertEqual(outcomes.records(), [.failed("run failed")])
  }

  private func record(workflowId: String = "ai-tag-workflow") -> AutoActionDispatchRecord {
    AutoActionDispatchRecord(
      action: AutoAction(
        actionId: "auto-action-1",
        trigger: .noteCreated,
        workflowId: workflowId,
        filterJSON: #"{"noteTags":["research"]}"#,
        enabled: true,
        position: 3,
        createdAt: "2026-07-04T00:00:00Z"
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: "notebook-1",
        noteId: "note-1",
        noteBodyMarkdown: "# Note\nBody"
      )
    )
  }

  private func string(_ value: JSONValue?) -> String? {
    guard case let .string(string)? = value else {
      return nil
    }
    return string
  }

  private func objectValue(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw XCTSkip("expected object")
    }
    return object
  }
}

private final class RecordingWorkflowBundleResolver: WorkflowBundleResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let error: Error?
  private var recordedOptions: [WorkflowResolutionOptions] = []

  init(error: Error? = nil) {
    self.error = error
  }

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    lock.lock()
    recordedOptions.append(options)
    lock.unlock()
    if let error {
      throw error
    }
    return ResolvedWorkflowBundle(
      workflow: WorkflowDefinition(
        workflowId: options.workflowName,
        defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
        entryStepId: "step",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "node.json")],
        steps: [WorkflowStepRef(id: "step", nodeId: "node")],
        nodes: [WorkflowNodeRef(id: "node", nodeFile: "node.json")]
      ),
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          executionBackend: .codexAgent,
          model: "gpt-5.5"
        )
      ],
      sourceScope: options.scope,
      workflowDirectory: options.workingDirectory
    )
  }

  func options() -> [WorkflowResolutionOptions] {
    lock.lock()
    defer { lock.unlock() }
    return recordedOptions
  }
}

private actor RecordingAutoActionWorkflowRunner: NoteAutoActionWorkflowRunning {
  private let result: CLICommandResult
  private var options: [WorkflowRunOptions] = []

  init(result: CLICommandResult) {
    self.result = result
  }

  func run(_ options: WorkflowRunOptions) async -> CLICommandResult {
    self.options.append(options)
    return result
  }

  func recordedOptions() -> [WorkflowRunOptions] {
    options
  }
}

private final class CapturingAutoActionTaskLauncher: NoteAutoActionWorkflowTaskLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private var operations: [@Sendable () async -> Void] = []

  func launch(_ operation: @escaping @Sendable () async -> Void) {
    lock.lock()
    operations.append(operation)
    lock.unlock()
  }

  func drain() async {
    while let operation = nextOperation() {
      await operation()
    }
  }

  func operationCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return operations.count
  }

  private func nextOperation() -> (@Sendable () async -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    guard !operations.isEmpty else {
      return nil
    }
    return operations.removeFirst()
  }
}

private final class RecordingAutoActionDiagnostics: NoteAutoActionDiagnosticRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var diagnostics: [NoteAutoActionWorkflowDiagnostic] = []

  func record(_ diagnostic: NoteAutoActionWorkflowDiagnostic) {
    lock.lock()
    diagnostics.append(diagnostic)
    lock.unlock()
  }

  func records() -> [NoteAutoActionWorkflowDiagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return diagnostics
  }
}

private final class RecordingAutoActionDispatchOutcomes: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [AutoActionDispatchOutcome] = []

  func record(_ outcome: AutoActionDispatchOutcome) {
    lock.lock()
    outcomes.append(outcome)
    lock.unlock()
  }

  func records() -> [AutoActionDispatchOutcome] {
    lock.lock()
    defer { lock.unlock() }
    return outcomes
  }
}
