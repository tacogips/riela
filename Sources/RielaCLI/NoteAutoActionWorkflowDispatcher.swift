import Foundation
import RielaCore
import RielaNote

public protocol NoteAutoActionWorkflowRunning: Sendable {
  func run(_ options: WorkflowRunOptions) async -> CLICommandResult
}

extension WorkflowRunCommand: NoteAutoActionWorkflowRunning {}

public protocol NoteAutoActionWorkflowTaskLaunching: Sendable {
  func launch(_ operation: @escaping @Sendable () async -> Void)
}

public struct NoteAutoActionTaskLauncher: NoteAutoActionWorkflowTaskLaunching {
  public init() {}

  public func launch(_ operation: @escaping @Sendable () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task(priority: .background) {
      await operation()
      semaphore.signal()
    }
    semaphore.wait()
  }
}

public enum NoteAutoActionWorkflowDiagnosticCode: String, Codable, Equatable, Sendable {
  case workflowUnresolved = "workflow-unresolved"
  case workflowRunFailed = "workflow-run-failed"
  case variableEncodingFailed = "variable-encoding-failed"
}

public struct NoteAutoActionWorkflowDiagnostic: Codable, Equatable, Sendable {
  public var code: NoteAutoActionWorkflowDiagnosticCode
  public var actionId: String
  public var workflowId: String
  public var trigger: NoteAutoActionTrigger
  public var message: String

  public init(
    code: NoteAutoActionWorkflowDiagnosticCode,
    actionId: String,
    workflowId: String,
    trigger: NoteAutoActionTrigger,
    message: String
  ) {
    self.code = code
    self.actionId = actionId
    self.workflowId = workflowId
    self.trigger = trigger
    self.message = message
  }
}

public protocol NoteAutoActionDiagnosticRecording: Sendable {
  func record(_ diagnostic: NoteAutoActionWorkflowDiagnostic)
}

public struct StderrNoteAutoActionDiagnosticRecorder: NoteAutoActionDiagnosticRecording {
  public init() {}

  public func record(_ diagnostic: NoteAutoActionWorkflowDiagnostic) {
    let message = "riela note auto-action \(diagnostic.code.rawValue): \(diagnostic.message)\n"
    FileHandle.standardError.write(Data(message.utf8))
  }
}

public struct StderrAutoActionFilterDiagnostics: NoteAutoActionFilterDiagnosticRecording {
  public init() {}

  public func record(_ diagnostic: NoteAutoActionDiagnostic) {
    let message = "riela note auto-action \(diagnostic.code.rawValue): \(diagnostic.actionId): \(diagnostic.message)\n"
    FileHandle.standardError.write(Data(message.utf8))
  }
}

public struct NoteAutoActionWorkflowDispatcher: AutoActionDispatching {
  public var resolver: any WorkflowBundleResolving
  public var runner: any NoteAutoActionWorkflowRunning
  public var taskLauncher: any NoteAutoActionWorkflowTaskLaunching
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
    taskLauncher: any NoteAutoActionWorkflowTaskLaunching = NoteAutoActionTaskLauncher(),
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
    self.taskLauncher = taskLauncher
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

  public func dispatch(
    _ record: AutoActionDispatchRecord,
    completion: @escaping @Sendable (AutoActionDispatchOutcome) -> Void
  ) throws {
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
      variables = try autoActionVariablesJSON(for: record, noteRoot: noteRoot)
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
    taskLauncher.launch {
      let result = await runner.run(options)
      guard result.exitCode == .success else {
        let message = noteAutoActionRunFailureMessage(result)
        diagnosticRecorder.record(diagnostic(
          .workflowRunFailed,
          record: record,
          message: message
        ))
        completion(.failed(message))
        return
      }
      completion(.succeeded)
    }
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

private func autoActionVariablesJSON(for record: AutoActionDispatchRecord, noteRoot: String?) throws -> String {
  let variables = autoActionVariables(for: record, noteRoot: noteRoot)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(JSONValue.object(variables))
  guard let json = String(data: data, encoding: .utf8) else {
    throw CLIUsageError("failed to encode note auto-action variables as UTF-8")
  }
  return json
}

private func autoActionVariables(for record: AutoActionDispatchRecord, noteRoot: String?) -> JSONObject {
  var event: JSONObject = [
    "trigger": .string(record.event.trigger.rawValue),
    "actionId": .string(record.action.actionId),
    "workflowId": .string(record.action.workflowId)
  ]
  event.setString(record.event.notebookId, forKey: "notebookId")
  event.setString(record.event.noteId, forKey: "noteId")
  event.setString(record.event.noteBodyMarkdown, forKey: "noteBodyMarkdown")
  event.setString(record.event.originatingActionId, forKey: "originatingActionId")

  var action: JSONObject = [
    "actionId": .string(record.action.actionId),
    "trigger": .string(record.action.trigger.rawValue),
    "workflowId": .string(record.action.workflowId),
    "enabled": .bool(record.action.enabled),
    "position": .integer(Int64(record.action.position)),
    "createdAt": .string(record.action.createdAt)
  ]
  action.setString(record.action.filterJSON, forKey: "filterJSON")

  var workflowInput: JSONObject = [
    "event": .object(event),
    "autoAction": .object(action),
    "trigger": .string(record.event.trigger.rawValue),
    "actionId": .string(record.action.actionId),
    "workflowId": .string(record.action.workflowId),
    "originatingActionId": .string(record.action.actionId)
  ]
  workflowInput.setString(record.event.notebookId, forKey: "notebookId")
  workflowInput.setString(record.event.noteId, forKey: "noteId")
  workflowInput.setString(record.event.noteBodyMarkdown, forKey: "noteBodyMarkdown")
  workflowInput.setString(noteRoot, forKey: "noteRoot")

  var variables = workflowInput
  variables.setString(noteRoot, forKey: "noteRoot")
  variables["workflowInput"] = .object(workflowInput)
  variables["event"] = .object(event)
  variables["autoAction"] = .object(action)
  return variables
}

private func noteAutoActionRunFailureMessage(_ result: CLICommandResult) -> String {
  let details = [result.stderr, result.stdout]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .first { !$0.isEmpty }
  return details ?? "workflow run exited with code \(result.exitCode.rawValue)"
}

private extension Dictionary where Key == String, Value == JSONValue {
  mutating func setString(_ value: String?, forKey key: String) {
    guard let value, !value.isEmpty else {
      return
    }
    self[key] = .string(value)
  }
}
