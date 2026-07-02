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
        let severity: WorkflowValidationSeverity = isLabeledTransition(transition) ? .warning : .error
        if transition.fanout != nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            severity: severity,
            path: "workflow.steps.\(step.id).transitions.fanout",
            message: "step '\(step.id)' uses fanout transitions, which this runner does not support yet"
          ))
        }
        if transition.toWorkflowId != nil && transition.resumeStepId == nil {
          gaps.append(WorkflowRuntimeCapabilityGap(
            severity: severity,
            path: "workflow.steps.\(step.id).transitions.toWorkflowId",
            message: "step '\(step.id)' uses cross-workflow transitions, which this runner does not support yet"
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
