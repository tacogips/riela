import Foundation
import RielaCore
import RielaNote
import RielaNoteDispatch
import XCTest
@testable import RielaCLI

final class NoteAutoActionWorkflowCLILauncherTests: XCTestCase {
  func testLaunchResolvesAndRunsWorkflowRunWithNoteEventVariables() async throws {
    let resolver = RecordingWorkflowBundleResolver()
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .success))
    let diagnostics = RecordingAutoActionDiagnostics()
    let launcher = NoteAutoActionWorkflowCLILauncher(
      resolver: resolver,
      runner: runner,
      diagnosticRecorder: diagnostics,
      workingDirectory: "/tmp/project",
      maxSteps: 12,
      sessionStore: "/tmp/project/.riela/sessions",
      noteRoot: "/tmp/project/.riela/note"
    )

    let outcome = try await launcher.launch(record())
    XCTAssertEqual(resolver.options().map(\.workflowName), ["ai-tag-workflow"])

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
    XCTAssertEqual(outcome, .succeeded)
    XCTAssertTrue(diagnostics.records().isEmpty)
  }

  func testUnresolvedWorkflowSkipsLaunchAndRecordsDiagnostic() async throws {
    let resolver = RecordingWorkflowBundleResolver(error: WorkflowResolutionError.notFound("missing", ["not installed"]))
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .success))
    let diagnostics = RecordingAutoActionDiagnostics()
    let launcher = NoteAutoActionWorkflowCLILauncher(
      resolver: resolver,
      runner: runner,
      diagnosticRecorder: diagnostics
    )

    do {
      _ = try await launcher.launch(record(workflowId: "missing"))
      XCTFail("expected launch to throw for unresolved workflow")
    } catch {
      // expected
    }

    let options = await runner.recordedOptions()
    XCTAssertTrue(options.isEmpty)
    XCTAssertEqual(diagnostics.records().map(\.code), [.workflowUnresolved])
    XCTAssertEqual(diagnostics.records().first?.actionId, "auto-action-1")
    XCTAssertEqual(diagnostics.records().first?.workflowId, "missing")
    XCTAssertTrue(diagnostics.records().first?.message.contains("not installed") == true)
  }

  func testWorkflowRunFailureRecordsDiagnosticAndReturnsFailed() async throws {
    let resolver = RecordingWorkflowBundleResolver()
    let runner = RecordingAutoActionWorkflowRunner(result: CLICommandResult(exitCode: .failure, stderr: "run failed"))
    let diagnostics = RecordingAutoActionDiagnostics()
    let launcher = NoteAutoActionWorkflowCLILauncher(
      resolver: resolver,
      runner: runner,
      diagnosticRecorder: diagnostics
    )

    let outcome = try await launcher.launch(record())

    let options = await runner.recordedOptions()
    XCTAssertEqual(options.count, 1)
    XCTAssertEqual(diagnostics.records().map(\.code), [.workflowRunFailed])
    XCTAssertEqual(diagnostics.records().first?.message, "run failed")
    XCTAssertEqual(outcome, .failed("run failed"))
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

final class RecordingWorkflowBundleResolver: WorkflowBundleResolving, @unchecked Sendable {
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

actor RecordingAutoActionWorkflowRunner: NoteAutoActionWorkflowRunning {
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

final class RecordingAutoActionDiagnostics: NoteAutoActionDiagnosticRecording, @unchecked Sendable {
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
