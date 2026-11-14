import Foundation

public struct WorkflowRuntimeCapabilityGap: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case severity
    case path
    case message
  }

  public var severity: WorkflowValidationSeverity
  public var path: String
  public var message: String

  public init(
    severity: WorkflowValidationSeverity = .error,
    path: String,
    message: String
  ) {
    self.severity = severity
    self.path = path
    self.message = message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.severity = try container.decodeIfPresent(WorkflowValidationSeverity.self, forKey: .severity) ?? .error
    self.path = try container.decode(String.self, forKey: .path)
    self.message = try container.decode(String.self, forKey: .message)
  }

  public var diagnostic: WorkflowValidationDiagnostic {
    WorkflowValidationDiagnostic(severity: severity, path: path, message: message)
  }
}

public struct WorkflowCrossWorkflowDispatchReference: Equatable, Sendable {
  public var stepId: String
  public var workflowId: String
  public var calleeEntryStepId: String
  public var resumeStepId: String
  public var path: String

  public var resumeStepPath: String {
    "workflow.steps.\(stepId).transitions.resumeStepId"
  }

  public init(
    stepId: String,
    workflowId: String,
    calleeEntryStepId: String,
    resumeStepId: String,
    path: String
  ) {
    self.stepId = stepId
    self.workflowId = workflowId
    self.calleeEntryStepId = calleeEntryStepId
    self.resumeStepId = resumeStepId
    self.path = path
  }
}

public extension DeterministicWorkflowRunner {
  static func crossWorkflowDispatchReferences(in workflow: WorkflowDefinition) -> [WorkflowCrossWorkflowDispatchReference] {
    let reachableStepIds = reachableSteps(in: workflow)
    return workflow.steps
      .filter { reachableStepIds.contains($0.id) }
      .flatMap { step in
        (step.transitions ?? []).compactMap { transition -> WorkflowCrossWorkflowDispatchReference? in
          guard let workflowId = transition.toWorkflowId,
                let resumeStepId = transition.resumeStepId else {
            return nil
          }
          return WorkflowCrossWorkflowDispatchReference(
            stepId: step.id,
            workflowId: workflowId,
            calleeEntryStepId: transition.toStepId,
            resumeStepId: resumeStepId,
            path: "workflow.steps.\(step.id).transitions.toWorkflowId"
          )
        }
      }
  }

  static func unsupportedFeatures(
    in workflow: WorkflowDefinition,
    maxConcurrency: Int? = nil,
    supportsCrossWorkflowDispatch: Bool = false
  ) -> [WorkflowRuntimeCapabilityGap] {
    var gaps: [WorkflowRuntimeCapabilityGap] = []
    _ = maxConcurrency
    let reachableStepIds = reachableSteps(in: workflow)
    for step in workflow.steps where reachableStepIds.contains(step.id) {
      for transition in step.transitions ?? [] {
        let severity: WorkflowValidationSeverity = isLabeledTransition(transition) ? .warning : .error
        if let fanout = transition.fanout {
          if transition.toWorkflowId != nil && !supportsCrossWorkflowDispatch {
            gaps.append(WorkflowRuntimeCapabilityGap(
              severity: severity,
              path: "workflow.steps.\(step.id).transitions.fanout",
              message: "step '\(step.id)' uses cross-workflow fanout dispatch, but this run has no callee workflow resolver wired"
            ))
          }
          if fanout.writeOwnership?.mode == .isolatedWorkspace {
            gaps.append(WorkflowRuntimeCapabilityGap(
              severity: severity,
              path: "workflow.steps.\(step.id).transitions.fanout.writeOwnership",
              message: "step '\(step.id)' uses fanout writeOwnership isolated-workspace, which this runner does not support yet"
            ))
          }
        }
        if transition.toWorkflowId != nil && transition.resumeStepId == nil && transition.fanout == nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            severity: severity,
            path: "workflow.steps.\(step.id).transitions.toWorkflowId",
            message: "step '\(step.id)' uses cross-workflow transitions, which this runner does not support yet"
          ))
        }
        if transition.toWorkflowId != nil &&
          transition.resumeStepId != nil &&
          transition.fanout == nil &&
          !supportsCrossWorkflowDispatch {
          gaps.append(WorkflowRuntimeCapabilityGap(
            severity: .warning,
            path: "workflow.steps.\(step.id).transitions.toWorkflowId",
            message: "step '\(step.id)' uses cross-workflow dispatch, but this run has no callee workflow resolver wired; wire a resolver for live dispatch or use a mock scenario to simulate the callee through the resume step"
          ))
        }
        if transition.toWorkflowId == nil && transition.resumeStepId != nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            severity: severity,
            path: "workflow.steps.\(step.id).transitions.resumeStepId",
            message: "step '\(step.id)' uses resume-step transitions, which this runner does not support yet"
          ))
        }
      }
    }
    return gaps
  }

  private static func reachableSteps(in workflow: WorkflowDefinition) -> Set<String> {
    let stepsById = Dictionary(workflow.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var visited: Set<String> = []
    var stack = [workflow.entryStepId]
    while let stepId = stack.popLast() {
      guard visited.insert(stepId).inserted, let step = stepsById[stepId] else {
        continue
      }
      for transition in step.transitions ?? [] {
        if transition.toWorkflowId == nil {
          stack.append(transition.toStepId)
        } else if let resumeStepId = transition.resumeStepId {
          stack.append(resumeStepId)
        }
        if let joinStepId = transition.fanout?.joinStepId {
          stack.append(joinStepId)
        }
      }
    }
    return visited
  }

  private static func isLabeledTransition(_ transition: WorkflowStepTransition) -> Bool {
    guard let label = transition.label else {
      return false
    }
    return !label.isEmpty
  }
}
