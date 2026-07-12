import Foundation
import RielaCore
import RielaNote
import RielaNoteDispatch

public protocol NoteAutoActionWorkflowRunning: Sendable {
  func run(_ options: WorkflowRunOptions) async -> CLICommandResult
}

extension WorkflowRunCommand: NoteAutoActionWorkflowRunning {}

/// CLI-backed launcher for note auto-action dispatches: resolves the workflow
/// bundle and runs it through `WorkflowRunCommand`. The generic
/// `NoteAutoActionWorkflowDispatcher` (in `RielaNoteDispatch`) wraps this so
/// both `RielaCLI` and `RielaApp` share the dispatch/lease machinery while
/// only the launcher binds to the CLI workflow-run stack.
public struct NoteAutoActionWorkflowCLILauncher: NoteAutoActionWorkflowLaunching {
  public var resolver: any WorkflowBundleResolving
  public var runner: any NoteAutoActionWorkflowRunning
  public var diagnosticRecorder: any NoteAutoActionDiagnosticRecording
  public var workingDirectory: String
  public var output: WorkflowOutputFormat
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var defaultTimeoutMs: Int?
  public var timeoutMs: Int?
  public var agentSilenceWarningMs: Int?
  public var agentSilenceMonitorIntervalMs: Int
  public var artifactRoot: String?
  public var sessionStore: String?
  public var noteRoot: String?

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    runner: any NoteAutoActionWorkflowRunning = WorkflowRunCommand(),
    diagnosticRecorder: any NoteAutoActionDiagnosticRecording = StderrNoteAutoActionDiagnosticRecorder(),
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    output: WorkflowOutputFormat = .jsonl,
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    defaultTimeoutMs: Int? = nil,
    timeoutMs: Int? = nil,
    agentSilenceWarningMs: Int? = 120_000,
    agentSilenceMonitorIntervalMs: Int = 1_000,
    artifactRoot: String? = nil,
    sessionStore: String? = nil,
    noteRoot: String? = nil
  ) {
    self.resolver = resolver
    self.runner = runner
    self.diagnosticRecorder = diagnosticRecorder
    self.workingDirectory = workingDirectory
    self.output = output
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.defaultTimeoutMs = defaultTimeoutMs
    self.timeoutMs = timeoutMs
    self.agentSilenceWarningMs = agentSilenceWarningMs
    self.agentSilenceMonitorIntervalMs = agentSilenceMonitorIntervalMs
    self.artifactRoot = artifactRoot
    self.sessionStore = sessionStore
    self.noteRoot = noteRoot
  }

  public func launch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    let resolution = WorkflowResolutionOptions(
      workflowName: record.action.workflowId,
      workingDirectory: workingDirectory
    )
    do {
      _ = try resolver.resolve(resolution)
    } catch {
      diagnosticRecorder.record(diagnostic(
        .workflowUnresolved,
        record: record,
        message: workflowResolutionErrorDescription(error)
      ))
      throw error
    }

    let variables: String
    do {
      variables = try noteAutoActionVariablesJSON(for: record, noteRoot: noteRoot)
    } catch {
      diagnosticRecorder.record(diagnostic(.variableEncodingFailed, record: record, message: "\(error)"))
      throw error
    }

    let options = WorkflowRunOptions(
      target: record.action.workflowId,
      resolution: resolution,
      variables: variables,
      output: output,
      maxSteps: maxSteps,
      maxConcurrency: maxConcurrency,
      maxLoopIterations: maxLoopIterations,
      defaultTimeoutMs: defaultTimeoutMs,
      timeoutMs: timeoutMs,
      agentSilenceWarningMs: agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: agentSilenceMonitorIntervalMs,
      artifactRoot: artifactRoot,
      sessionStore: sessionStore,
      workingDirectory: workingDirectory
    )
    let result = await runner.run(options)
    guard result.exitCode == .success else {
      let message = noteAutoActionRunFailureMessage(result)
      diagnosticRecorder.record(diagnostic(
        .workflowRunFailed,
        record: record,
        message: message
      ))
      return .failed(message)
    }
    return .succeeded
  }

  private func diagnostic(
    _ code: NoteAutoActionWorkflowDiagnosticCode,
    record: AutoActionDispatchRecord,
    message: String
  ) -> NoteAutoActionWorkflowDiagnostic {
    NoteAutoActionWorkflowDiagnostic(
      code: code,
      actionId: record.action.actionId,
      workflowId: record.action.workflowId,
      trigger: record.event.trigger,
      message: message
    )
  }
}

private func noteAutoActionRunFailureMessage(_ result: CLICommandResult) -> String {
  let details = [result.stderr, result.stdout]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .first { !$0.isEmpty }
  return details ?? "workflow run exited with code \(result.exitCode.rawValue)"
}
