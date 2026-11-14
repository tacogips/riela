import Foundation

struct WorkflowGitFinalizationEvidencePolicy: Equatable, Sendable {
  var commitStepId: String
  var pushStepId: String
  var planningModeStepIds: Set<String>
}

private enum WorkflowGitFinalizationMode: String {
  case designPlanOnly = "design-plan-only"
  case issueResolution = "issue-resolution"
}

extension DeterministicWorkflowRunner {
  static func requiresGitFinalizationEvidence(
    workflow: WorkflowDefinition,
    terminalStep: WorkflowStepRef
  ) -> Bool {
    workflow.workflowId == "codex-design-and-implement-review-loop" &&
      terminalStep.id == "workflow-output"
  }

  static func gitFinalizationEvidencePolicy(
    workflow: WorkflowDefinition,
    terminalStep: WorkflowStepRef
  ) -> WorkflowGitFinalizationEvidencePolicy? {
    guard requiresGitFinalizationEvidence(workflow: workflow, terminalStep: terminalStep),
          terminalStep.transitions?.isEmpty ?? true else {
      return nil
    }
    let pushNodes = workflow.nodes.filter {
      $0.addon?.name == "riela/git-push" && $0.addon?.version == "1"
    }
    guard pushNodes.count == 1, let pushNode = pushNodes.first else {
      return nil
    }
    let pushSteps = workflow.steps.filter { $0.nodeId == pushNode.id }
    guard pushSteps.count == 1, let pushStep = pushSteps.first else {
      return nil
    }
    guard pushStep.transitions?.map(\.toStepId) == [terminalStep.id] else {
      return nil
    }
    let commitNodes = workflow.nodes.filter {
      $0.addon?.name == "riela/git-commit" && $0.addon?.version == "1"
    }
    guard commitNodes.count == 1, let commitNode = commitNodes.first else {
      return nil
    }
    let commitSteps = workflow.steps.filter { $0.nodeId == commitNode.id }
    guard commitSteps.count == 1, let commitStep = commitSteps.first else {
      return nil
    }
    guard commitStep.transitions?.map(\.toStepId) == [pushStep.id] else {
      return nil
    }
    let commitPreparationStepIds = Set(workflow.steps.compactMap { step in
      step.transitions?.contains(where: { $0.toStepId == commitStep.id }) == true ? step.id : nil
    })
    let planningModeStepIds = Set(workflow.steps.compactMap { step in
      let hasPlanningRoute = step.transitions?.contains(where: { transition in
        commitPreparationStepIds.contains(transition.toStepId) &&
          transition.label?.contains("planning_only") == true
      }) == true
      return hasPlanningRoute ? step.id : nil
    })
    guard !planningModeStepIds.isEmpty else {
      return nil
    }
    return WorkflowGitFinalizationEvidencePolicy(
      commitStepId: commitStep.id,
      pushStepId: pushStep.id,
      planningModeStepIds: planningModeStepIds
    )
  }

  static func requiredGitFinalizationEvidencePolicy(
    workflow: WorkflowDefinition,
    terminalStep: WorkflowStepRef
  ) throws -> WorkflowGitFinalizationEvidencePolicy {
    guard requiresGitFinalizationEvidence(workflow: workflow, terminalStep: terminalStep),
          let policy = gitFinalizationEvidencePolicy(workflow: workflow, terminalStep: terminalStep) else {
      throw invalidGitFinalizationEvidence("protected workflow finalization policy is missing or ambiguous")
    }
    return policy
  }

  static func validateGitFinalizationEvidence(
    context: WorkflowPrePersistenceRoutingContext,
    policy: WorkflowGitFinalizationEvidencePolicy
  ) throws {
    let expectedMode = try expectedGitFinalizationMode(
      session: context.session,
      policy: policy
    )
    let commitPayload = try acceptedPayload(
      stepId: policy.commitStepId,
      session: context.session
    )
    let pushPayload = try acceptedPayload(
      stepId: policy.pushStepId,
      session: context.session
    )
    let commitEvidence = try gitEvidence(
      commitPayload,
      expectedOperation: "commit",
      expectedStatuses: ["committed", "already-committed"],
      expectedKeys: ["operation", "status", "commitHash", "commitMessage", "committedFiles"]
    )
    let pushEvidence = try gitEvidence(
      pushPayload,
      expectedOperation: "push",
      expectedStatuses: ["pushed", "already-pushed"],
      expectedKeys: ["operation", "status", "commitHash", "pushedRemote", "pushedBranch"]
    )
    guard let commitHash = stringValue(commitEvidence["commitHash"]),
          let pushHash = stringValue(pushEvidence["commitHash"]),
          isFullGitObjectID(commitHash),
          isFullGitObjectID(pushHash),
          commitHash == pushHash,
          let commitMessage = stringValue(commitEvidence["commitMessage"]),
          let committedFiles = stringArrayValue(commitEvidence["committedFiles"]),
          !committedFiles.isEmpty,
          Set(committedFiles).count == committedFiles.count,
          let pushedRemote = stringValue(pushEvidence["pushedRemote"]),
          let pushedBranch = stringValue(pushEvidence["pushedBranch"]) else {
      throw invalidGitFinalizationEvidence("commit and push evidence is missing or mismatched")
    }
    guard context.payload["status"] == .string("accepted"),
          context.payload["workflowMode"] == .string(expectedMode.rawValue),
          context.payload["commitHash"] == .string(commitHash),
          context.payload["commitMessage"] == .string(commitMessage),
          context.payload["committedFiles"] == .array(committedFiles.map(JSONValue.string)),
          context.payload["pushedRemote"] == .string(pushedRemote),
          context.payload["pushedBranch"] == .string(pushedBranch) else {
      throw invalidGitFinalizationEvidence("final output does not exactly consume accepted git evidence")
    }
  }

  private static func expectedGitFinalizationMode(
    session: WorkflowSession,
    policy: WorkflowGitFinalizationEvidencePolicy
  ) throws -> WorkflowGitFinalizationMode {
    if session.executions.contains(where: {
      $0.stepId == "step6-implement" && $0.status == .completed && $0.acceptedOutput != nil
    }) {
      return .issueResolution
    }
    if session.executions.contains(where: { execution in
      guard policy.planningModeStepIds.contains(execution.stepId),
            execution.status == .completed,
            let acceptedOutput = execution.acceptedOutput else {
        return false
      }
      return acceptedOutput.when["planning_only"] == true ||
        acceptedOutput.payload["planning_only"] == .bool(true)
    }) {
      return .designPlanOnly
    }
    throw invalidGitFinalizationEvidence("authoritative workflow mode evidence is missing")
  }

  private static func acceptedPayload(
    stepId: String,
    session: WorkflowSession
  ) throws -> JSONObject {
    guard let execution = session.executions.last(where: { $0.stepId == stepId }),
          execution.status == .completed,
          let payload = execution.acceptedOutput?.payload else {
      throw invalidGitFinalizationEvidence("required accepted step evidence is missing")
    }
    return payload
  }

  private static func gitEvidence(
    _ payload: JSONObject,
    expectedOperation: String,
    expectedStatuses: Set<String>,
    expectedKeys: Set<String>
  ) throws -> JSONObject {
    guard Set(payload.keys) == ["git"],
          case let .object(evidence)? = payload["git"],
          Set(evidence.keys) == expectedKeys,
          evidence["operation"] == .string(expectedOperation),
          let status = stringValue(evidence["status"]),
          expectedStatuses.contains(status) else {
      throw invalidGitFinalizationEvidence("accepted git evidence has missing or unexpected fields")
    }
    return evidence
  }

  static func invalidGitFinalizationEvidence(_ message: String) -> AdapterExecutionError {
    AdapterExecutionError(.invalidOutput, "git_finalization_evidence_invalid: \(message)")
  }

  private static func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(text)? = value else {
      return nil
    }
    return text
  }

  private static func stringArrayValue(_ value: JSONValue?) -> [String]? {
    guard case let .array(values)? = value else {
      return nil
    }
    let strings = values.compactMap(stringValue)
    return strings.count == values.count ? strings : nil
  }

  private static func isFullGitObjectID(_ value: String) -> Bool {
    value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil
  }
}
