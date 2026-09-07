import Foundation

/// The selected route prepared between node output acceptance and durable
/// publication. It stays separate from publication execution so routing
/// policy and durable publication each have a focused contract.
public struct WorkflowPrePersistenceRoutingContext: Equatable, Sendable {
  public var session: WorkflowSession
  public var stepExecution: WorkflowStepExecution
  public var payload: JSONObject
  public var when: [String: Bool]
  public var selectedTransitions: [WorkflowStepTransition]
  public var publishesRootOutput: Bool
  public var completesRootWithoutOutput: Bool
  public var intendedSuccessfulStatus: WorkflowStepExecutionStatus

  public init(
    session: WorkflowSession,
    stepExecution: WorkflowStepExecution,
    payload: JSONObject,
    when: [String: Bool],
    selectedTransitions: [WorkflowStepTransition],
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool,
    intendedSuccessfulStatus: WorkflowStepExecutionStatus
  ) {
    self.session = session
    self.stepExecution = stepExecution
    self.payload = payload
    self.when = when
    self.selectedTransitions = selectedTransitions
    self.publishesRootOutput = publishesRootOutput
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.intendedSuccessfulStatus = intendedSuccessfulStatus
  }
}

public struct WorkflowPrePersistenceRoutingDecision: Equatable, Sendable {
  public var selectedTransitions: [WorkflowStepTransition]
  public var routedPayload: JSONObject
  public var publishesRootOutput: Bool
  public var completesRootWithoutOutput: Bool
  public var loopGuard: WorkflowLoopGuardPublication?

  public init(
    selectedTransitions: [WorkflowStepTransition],
    routedPayload: JSONObject,
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool,
    loopGuard: WorkflowLoopGuardPublication? = nil
  ) {
    self.selectedTransitions = selectedTransitions
    self.routedPayload = routedPayload
    self.publishesRootOutput = publishesRootOutput
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.loopGuard = loopGuard
  }

  public static func unchanged(
    _ context: WorkflowPrePersistenceRoutingContext
  ) -> WorkflowPrePersistenceRoutingDecision {
    WorkflowPrePersistenceRoutingDecision(
      selectedTransitions: context.selectedTransitions,
      routedPayload: context.payload,
      publishesRootOutput: context.publishesRootOutput,
      completesRootWithoutOutput: context.completesRootWithoutOutput
    )
  }
}

public typealias WorkflowPrePersistenceRoutingDecider = @Sendable (
  WorkflowPrePersistenceRoutingContext
) throws -> WorkflowPrePersistenceRoutingDecision
