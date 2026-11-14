import Foundation
import RielaCore
import RielaWork

/// One row of `riela task list`. A summary, not the record: the full task is
/// what `riela task show` returns.
public struct TaskSummary: Codable, Equatable, Sendable {
  public var taskId: String
  public var intentId: String
  public var title: String
  public var state: TaskState
  public var workflowId: String?
  public var version: Int
  public var attemptCount: Int
  public var latestSessionId: String?
  public var openBlockingFindingCount: Int

  public init(
    taskId: String,
    intentId: String,
    title: String,
    state: TaskState,
    workflowId: String? = nil,
    version: Int,
    attemptCount: Int,
    latestSessionId: String? = nil,
    openBlockingFindingCount: Int
  ) {
    self.taskId = taskId
    self.intentId = intentId
    self.title = title
    self.state = state
    self.workflowId = workflowId
    self.version = version
    self.attemptCount = attemptCount
    self.latestSessionId = latestSessionId
    self.openBlockingFindingCount = openBlockingFindingCount
  }
}

public struct TaskListCommandResult: Codable, Equatable, Sendable {
  public var tasks: [TaskSummary]

  public init(tasks: [TaskSummary]) {
    self.tasks = tasks
  }
}

public struct TaskDecisionCommandResult: Codable, Equatable, Sendable {
  public var taskId: String
  public var decisionId: String
  public var state: TaskState
  public var version: Int
  public var attemptId: String?

  public init(taskId: String, decisionId: String, state: TaskState, version: Int, attemptId: String?) {
    self.taskId = taskId
    self.decisionId = decisionId
    self.state = state
    self.version = version
    self.attemptId = attemptId
  }
}

/// Ledger counts per evidence kind, in a stable order so the text and JSON
/// renderings agree.
public struct TaskEvidenceCount: Codable, Equatable, Sendable {
  public var kind: EvidenceKind
  public var count: Int

  public init(kind: EvidenceKind, count: Int) {
    self.kind = kind
    self.count = count
  }
}

public struct TaskShowCommandResult: Codable, Equatable, Sendable {
  public var taskId: String
  public var task: WorkTask
  public var attempts: [Attempt]
  public var decisions: [Decision]
  public var findings: [Finding]
  public var evidence: [TaskEvidenceCount]
  public var completion: CompletionVerdict

  public init(
    taskId: String,
    task: WorkTask,
    attempts: [Attempt],
    decisions: [Decision],
    findings: [Finding],
    evidence: [TaskEvidenceCount],
    completion: CompletionVerdict
  ) {
    self.taskId = taskId
    self.task = task
    self.attempts = attempts
    self.decisions = decisions
    self.findings = findings
    self.evidence = evidence
    self.completion = completion
  }
}

/// Structured failure, shaped like `LoopCommandFailureResult` so agents parse
/// one failure envelope across the read commands.
public struct TaskCommandFailureResult: Codable, Equatable, Sendable {
  public var taskId: String
  public var command: String
  public var error: String
  public var exitCode: Int32

  public init(taskId: String, command: String, error: String, exitCode: Int32) {
    self.taskId = taskId
    self.command = command
    self.error = error
    self.exitCode = exitCode
  }
}
