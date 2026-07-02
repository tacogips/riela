import Foundation

public struct WorkflowRuntimeCapabilityGap: Codable, Equatable, Sendable {
  public var path: String
  public var message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }

  public var diagnostic: WorkflowValidationDiagnostic {
    WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
  }
}

public extension DeterministicWorkflowRunner {
  static func unsupportedFeatures(
    in workflow: WorkflowDefinition,
    maxConcurrency: Int? = nil
  ) -> [WorkflowRuntimeCapabilityGap] {
    var gaps: [WorkflowRuntimeCapabilityGap] = []
    if maxConcurrency != nil {
      gaps.append(WorkflowRuntimeCapabilityGap(
        path: "run.maxConcurrency",
        message: "maxConcurrency is reserved for fanout execution and is not supported yet"
      ))
    }
    let reachableStepIds = reachableSteps(in: workflow)
    for step in workflow.steps where reachableStepIds.contains(step.id) {
      for transition in step.transitions ?? [] {
        if let label = transition.label, !label.isEmpty {
          continue
        }
        if transition.fanout != nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            path: "workflow.steps.\(step.id).transitions.fanout",
            message: "step '\(step.id)' uses fanout transitions, which this runner does not support yet"
          ))
        }
        if transition.toWorkflowId != nil && transition.resumeStepId == nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            path: "workflow.steps.\(step.id).transitions.toWorkflowId",
            message: "step '\(step.id)' uses cross-workflow transitions, which this runner does not support yet"
          ))
        }
        if transition.toWorkflowId == nil && transition.resumeStepId != nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            path: "workflow.steps.\(step.id).transitions.resumeStepId",
            message: "step '\(step.id)' uses resume-step transitions, which this runner does not support yet"
          ))
        }
      }
    }
    return gaps
  }

  private static func reachableSteps(in workflow: WorkflowDefinition) -> Set<String> {
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    var visited: Set<String> = []
    var stack = [workflow.entryStepId]
    while let stepId = stack.popLast() {
      guard visited.insert(stepId).inserted, let step = stepsById[stepId] else {
        continue
      }
      for transition in step.transitions ?? [] {
        if transition.toWorkflowId == nil {
          stack.append(transition.toStepId)
        }
        if let joinStepId = transition.fanout?.joinStepId {
          stack.append(joinStepId)
        }
      }
    }
    return visited
  }
}
