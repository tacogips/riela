import Foundation
import RielaCore
import RielaNote

/// Launches the workflow run for a single claimed auto-action dispatch. The
/// concrete implementation (CLI `WorkflowRunCommand`, or an app-side runner)
/// lives in the consuming target; this abstraction keeps `RielaNoteDispatch`
/// free of the CLI workflow-run machinery so both `RielaCLI` and `RielaApp`
/// can wire a launcher.
public protocol NoteAutoActionWorkflowLaunching: Sendable {
  /// Runs the workflow for a claimed dispatch. Throwing signals the attempt
  /// could not be launched (e.g. workflow resolution failed); a returned
  /// `.failed` signals the workflow ran but did not succeed.
  func launch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome
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

/// Bridges the `NoteService` dispatch contract (`AutoActionDispatching`) to a
/// workflow launcher. Wired identically by `RielaCLI` and `RielaApp`; only the
/// launcher differs between them.
public struct NoteAutoActionWorkflowDispatcher: AutoActionDispatching {
  public var launcher: any NoteAutoActionWorkflowLaunching

  public init(launcher: any NoteAutoActionWorkflowLaunching) {
    self.launcher = launcher
  }

  public func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    try await launcher.launch(record)
  }
}
