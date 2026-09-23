import Foundation

public struct DecisionApplication: Codable, Equatable, Sendable {
  public var task: WorkTask
  public var attempt: Attempt?
  /// Decisions that request another execution are reserved by the dispatcher
  /// only after this state transition commits.
  public var requestedEntry: AttemptEntry?

  public init(task: WorkTask, attempt: Attempt?, requestedEntry: AttemptEntry? = nil) {
    self.task = task
    self.attempt = attempt
    self.requestedEntry = requestedEntry
  }
}

public struct DecisionApplicationError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

/// Validates and stages a decision without doing I/O. `WorkStore` owns the
/// transaction and version bump; CLI, policy, and future GraphQL callers all
/// share this transition table.
public enum DecisionApplier {
  public static func apply(
    _ decision: Decision,
    to task: WorkTask,
    attempt: Attempt?,
    completion: CompletionVerdict
  ) throws -> DecisionApplication {
    guard decision.taskId == task.id else {
      throw DecisionApplicationError("decision task does not match the target task")
    }
    if let decisionAttemptId = decision.attemptId {
      guard let attempt, attempt.id == decisionAttemptId, attempt.taskId == task.id else {
        throw DecisionApplicationError("decision attempt does not match the target task")
      }
    }
    guard !task.state.isTerminal else {
      throw DecisionApplicationError("task '\(task.id.rawValue)' is already terminal")
    }

    var updatedTask = task
    var updatedAttempt = attempt
    var requestedEntry: AttemptEntry?
    switch decision.kind {
    case .start:
      try requirePlan(task)
      updatedTask.state = .scheduled
      requestedEntry = .start
    case .resume:
      try requireAttempt(attempt)
      updatedTask.state = .scheduled
      requestedEntry = .resume
    case let .rerun(fromStepId):
      try requireAttempt(attempt)
      updatedTask.state = .scheduled
      requestedEntry = .rerunFromStep(fromStepId)
      reconcile(&updatedAttempt)
    case let .recover(fromGateId):
      try requireAttempt(attempt)
      updatedTask.state = .scheduled
      requestedEntry = .recoverFromGate(fromGateId)
      reconcile(&updatedAttempt)
    case .replan:
      reconcile(&updatedAttempt)
      updatedTask.plan = nil
      updatedTask.state = .draft
    case .wait:
      updatedTask.state = .waiting
    case .proposeWorkflowChange:
      updatedTask.state = .needsDecision
    case .accept:
      guard canAccept(decision: decision, completion: completion) else {
        throw DecisionApplicationError("accept decision requires a satisfied completion contract")
      }
      reconcile(&updatedAttempt)
      updatedTask.state = .succeeded
    case .reject:
      reconcile(&updatedAttempt)
      updatedTask.state = .failed
    case .cancel:
      reconcile(&updatedAttempt)
      updatedTask.state = .cancelled
    case .stop:
      reconcile(&updatedAttempt)
      updatedTask.state = .failed
    }
    return DecisionApplication(task: updatedTask, attempt: updatedAttempt, requestedEntry: requestedEntry)
  }

  private static func canAccept(decision: Decision, completion: CompletionVerdict) -> Bool {
    if completion == .satisfied { return true }
    guard case .human = decision.producer else { return false }
    return completion == .unmet([.humanAcceptRequired])
  }

  private static func requirePlan(_ task: WorkTask) throws {
    guard task.plan != nil else {
      throw DecisionApplicationError("task '\(task.id.rawValue)' has no executable plan")
    }
  }

  private static func requireAttempt(_ attempt: Attempt?) throws {
    guard attempt != nil else {
      throw DecisionApplicationError("decision requires an existing attempt")
    }
  }

  private static func reconcile(_ attempt: inout Attempt?) {
    guard attempt != nil else { return }
    attempt?.state = .reconciled
  }
}
