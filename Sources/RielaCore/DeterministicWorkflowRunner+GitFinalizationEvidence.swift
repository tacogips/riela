import Foundation

struct WorkflowGitFinalizationEvidencePolicy: Equatable, Sendable {
  var commitStepId: String
  var pushStepId: String
  var planningModeStepIds: Set<String>
  var integrationStepId: String?
  var implementationReviewStepId: String?
  var planCommitStepId: String?
  var planPushStepId: String?
}

private enum WorkflowGitFinalizationMode: String {
  case designPlanOnly = "design-plan-only"
  case issueResolution = "issue-resolution"
}

extension DeterministicWorkflowRunner {
  func composedPromptsWithFinalizationEvidence(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    variables: JSONObject,
    session: WorkflowSession
  ) throws -> ComposedAdapterPrompts {
    var prompts = composedPrompts(workflow: workflow, step: step, payload: payload, variables: variables)
    guard Self.requiresGitFinalizationEvidence(workflow: workflow, terminalStep: step) else {
      return prompts
    }
    let evidence = try Self.gitFinalizationPromptEvidence(session: session)
    let supplement = "\n\nRuntime-accepted predecessor step outputs (not authored input):\n\(evidence)"
    prompts.promptText += supplement
    prompts.resumedPromptText += supplement
    return prompts
  }

  static func gitFinalizationPromptEvidence(session: WorkflowSession) throws -> String {
    let relevantStepIds = [
      "step1-issue-intake", "step2-design-doc-update", "step3-design-review",
      "step4-impl-plan-create", "step5-impl-plan-review", "step5-feature-plan-join",
      "plan-checkpoint", "plan-git-commit", "plan-git-push", "dispatch-plans",
      "step6-implement", "step6-test-integrity-check", "step7-adversarial-review",
      "step7b-e2e-evidence", "implementation-wave-outcome", "reconcile-implementations",
      "integration-review", "step8-docs-refresh", "step9-commit-message",
      "step10-git-commit", "step11-git-push", "base-branch-integrate"
    ]
    let entries: [JSONValue] = relevantStepIds.compactMap { stepId in
      guard let execution = session.executions.last(where: { $0.stepId == stepId }),
            execution.status == .completed,
            let accepted = execution.acceptedOutput else {
        return nil
      }
      return .object([
        "stepId": .string(stepId),
        "payload": .object(accepted.payload),
        "when": .object(accepted.when.mapValues(JSONValue.bool))
      ])
    }
    return try JSONValue.array(entries).compactJSONString()
  }

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
    guard (1...2).contains(pushNodes.count) else {
      return nil
    }
    let pushNodeIds = Set(pushNodes.map(\.id))
    let pushSteps = workflow.steps.filter { pushNodeIds.contains($0.nodeId) }
    let integrationStep = workflow.steps.first { $0.id == "base-branch-integrate" }
    let terminalPushSteps = pushSteps.filter { candidate in
      let directTerminal = candidate.transitions?.map(\.toStepId) == [terminalStep.id]
      let integratedTerminal = integrationStep.map {
        candidate.transitions?.map(\.toStepId) == [$0.id] &&
          $0.transitions?.map(\.toStepId) == [terminalStep.id]
      } ?? false
      return directTerminal || integratedTerminal
    }
    guard terminalPushSteps.count == 1, let pushStep = terminalPushSteps.first else {
      return nil
    }
    let directTerminal = pushStep.transitions?.map(\.toStepId) == [terminalStep.id]
    let integratedTerminal = integrationStep.map {
      pushStep.transitions?.map(\.toStepId) == [$0.id] &&
        $0.transitions?.map(\.toStepId) == [terminalStep.id]
    } ?? false
    guard directTerminal || integratedTerminal else {
      return nil
    }
    let commitNodes = workflow.nodes.filter {
      $0.addon?.name == "riela/git-commit" && $0.addon?.version == "1"
    }
    let commitNodeIds = Set(commitNodes.map(\.id))
    // A planning checkpoint is not finalization. Select the unique commit
    // directly feeding the final push instead of rejecting multiple commits.
    let commitSteps = workflow.steps.filter {
      commitNodeIds.contains($0.nodeId) && $0.transitions?.map(\.toStepId) == [pushStep.id]
    }
    guard commitSteps.count == 1, let commitStep = commitSteps.first else {
      return nil
    }
    let otherCommitNodes = commitNodes.filter { $0.id != commitStep.nodeId }
    let planCommitStep = workflow.steps.first { $0.id == "plan-git-commit" }
    let planPushStep = workflow.steps.first { $0.id == "plan-git-push" }
    let planCommitTransition = planPushStep == nil ? "dispatch-plans" : "plan-git-push"
    let hasValidPlanCommit = otherCommitNodes.count == 1 &&
      otherCommitNodes[0].id == "plan-git-commit" &&
      workflow.steps.filter { $0.nodeId == "plan-git-commit" }.count == 1 &&
      planCommitStep?.nodeId == "plan-git-commit" &&
      planCommitStep?.transitions?.map(\.toStepId) == [planCommitTransition] &&
      workflow.steps.contains { $0.id == "dispatch-plans" && $0.transitions?.contains { $0.fanout != nil } == true }
    let hasValidPlanPush = planPushStep == nil ? pushNodes.count == 1 && pushSteps.count == 1 : (
      pushNodes.count == 2 && pushSteps.count == 2 &&
      pushNodes.contains { $0.id == "plan-git-push" } &&
      planPushStep?.nodeId == "plan-git-push" &&
      planPushStep?.transitions?.map(\.toStepId) == ["dispatch-plans"] &&
      pushStep.id != "plan-git-push"
    )
    guard (otherCommitNodes.isEmpty && planPushStep == nil || hasValidPlanCommit) &&
          hasValidPlanPush else {
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
      planningModeStepIds: planningModeStepIds,
      integrationStepId: integratedTerminal ? integrationStep?.id : nil,
      implementationReviewStepId: workflow.steps.contains { $0.id == "integration-review" }
        ? "integration-review" : nil,
      planCommitStepId: hasValidPlanCommit ? planCommitStep?.id : nil,
      planPushStepId: planPushStep?.id
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
    if expectedMode == .issueResolution,
       let planCommitStepId = policy.planCommitStepId,
       let planPushStepId = policy.planPushStepId {
      let planCommit = try gitEvidence(
        acceptedPayload(stepId: planCommitStepId, session: context.session),
        expectedOperation: "commit",
        expectedStatuses: ["committed", "already-committed"],
        expectedKeys: ["operation", "status", "commitHash", "commitMessage", "committedFiles"]
      )
      let planPush = try gitEvidence(
        acceptedPayload(stepId: planPushStepId, session: context.session),
        expectedOperation: "push",
        expectedStatuses: ["pushed", "already-pushed"],
        expectedKeys: ["operation", "status", "commitHash", "pushedRemote", "pushedBranch"]
      )
      guard let planCommitHash = stringValue(planCommit["commitHash"]),
            isFullGitObjectID(planCommitHash),
            planPush["commitHash"] == .string(planCommitHash),
            planPush["pushedRemote"] == .string(pushedRemote),
            planPush["pushedBranch"] == .string(pushedBranch) else {
        throw invalidGitFinalizationEvidence("plan checkpoint commit and push evidence is missing or mismatched")
      }
    }
    if let integrationStepId = policy.integrationStepId {
      let integration = try acceptedPayload(stepId: integrationStepId, session: context.session)
      guard let mergeStatus = stringValue(integration["mergeStatus"]),
            let pushStatus = stringValue(integration["basePushStatus"]),
            integration["implementationCommit"] == .string(commitHash),
            integration["implementationBranch"] == .string(pushedBranch),
            integration["remote"] == .string(pushedRemote),
            let baseBranch = stringValue(integration["baseBranch"]), !baseBranch.isEmpty,
            context.payload["baseBranch"] == .string(baseBranch),
            context.payload["mergeStatus"] == .string(mergeStatus),
            context.payload["basePushStatus"] == .string(pushStatus) else {
        throw invalidGitFinalizationEvidence("base integration evidence is missing or mismatched")
      }
      if mergeStatus == "pr-open" {
        guard pushStatus == "not-requested",
              let pullRequestURL = stringValue(integration["pullRequestURL"]),
              let parsedURL = URL(string: pullRequestURL),
              parsedURL.scheme == "https", parsedURL.host?.isEmpty == false,
              let pullRequestNumber = integration["pullRequestNumber"]?.asInt64,
              pullRequestNumber > 0,
              Array(parsedURL.pathComponents.suffix(2)) == ["pull", String(pullRequestNumber)],
              integration["pullRequestDraft"] == .bool(true) || integration["pullRequestDraft"] == .bool(false),
              let pullRequestBaseBranch = stringValue(integration["pullRequestBaseBranch"]),
              !pullRequestBaseBranch.isEmpty, pullRequestBaseBranch != pushedBranch,
              context.payload["pullRequestURL"] == .string(pullRequestURL),
              context.payload["pullRequestNumber"] == integration["pullRequestNumber"],
              context.payload["pullRequestDraft"] == integration["pullRequestDraft"],
              context.payload["pullRequestBaseBranch"] == .string(pullRequestBaseBranch) else {
          throw invalidGitFinalizationEvidence("PR handoff evidence is missing or mismatched")
        }
      } else if !["merged", "already-on-base", "already-merged"].contains(mergeStatus) ||
                  !["pushed", "already-pushed"].contains(pushStatus) {
        throw invalidGitFinalizationEvidence("base integration evidence is missing or mismatched")
      }
    }
  }

  private static func expectedGitFinalizationMode(
    session: WorkflowSession,
    policy: WorkflowGitFinalizationEvidencePolicy
  ) throws -> WorkflowGitFinalizationMode {
    if let reviewStepId = policy.implementationReviewStepId,
       session.executions.contains(where: { $0.stepId == reviewStepId }) {
      let review = try acceptedPayload(stepId: reviewStepId, session: session)
      guard review["accepted"] == .bool(true),
            review["needs_revision"] == .bool(false),
            review["plans_remaining"] == .bool(false) else {
        throw invalidGitFinalizationEvidence("combined implementation review is not complete")
      }
      return .issueResolution
    }
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
