import Foundation
import XCTest
@testable import RielaCore

final class WorkflowGitFinalizationEvidenceTests: XCTestCase {
  func testFinalOutputPromptReceivesLatestAcceptedPredecessorEvidence() throws {
    var session = makeContext().session
    let now = Date(timeIntervalSince1970: 1_700_000_003)
    session.executions.append(execution(
      id: "first-review", stepId: "step3-design-review",
      payload: ["decision": .string("needs-revision")], now: now
    ))
    session.executions.append(execution(
      id: "latest-review", stepId: "step3-design-review",
      payload: ["decision": .string("accepted")], now: now
    ))
    session.executions.append(WorkflowStepExecution(
      executionId: "failed-push", stepId: "step11-git-push", nodeId: "step11-git-push",
      attempt: 2, status: .failed, createdAt: now, updatedAt: now
    ))

    let json = try DeterministicWorkflowRunner.gitFinalizationPromptEvidence(session: session)
    let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    XCTAssertEqual(evidence.filter { $0["stepId"] as? String == "step3-design-review" }.count, 1)
    let review = try XCTUnwrap(evidence.first { $0["stepId"] as? String == "step3-design-review" })
    XCTAssertEqual((review["payload"] as? [String: String])?["decision"], "accepted")
    XCTAssertFalse(evidence.contains { $0["stepId"] as? String == "step11-git-push" })
    let commit = try XCTUnwrap(evidence.first { $0["stepId"] as? String == "step10-git-commit" })
    XCTAssertEqual(((commit["payload"] as? [String: Any])?["git"] as? [String: Any])?["committedFiles"] as? [String], ["tracked.txt"])
  }

  func testProtectedFinalPromptIncludesAcceptedHistoryButOtherStepsDoNot() throws {
    let workflow = WorkflowDefinition(
      workflowId: "codex-design-and-implement-review-loop",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "workflow-output", nodeRegistry: [], steps: [], nodes: []
    )
    let payload = AgentNodePayload(id: "workflow-output", model: "test", promptTemplate: "Publish result")
    let runner = DeterministicWorkflowRunner()
    let session = makeContext().session
    let outputStep = WorkflowStepRef(id: "workflow-output", nodeId: "workflow-output")
    let final = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow, step: outputStep, payload: payload, variables: [:], session: session
    )
    XCTAssertTrue(final.promptText.contains("Runtime-accepted predecessor step outputs"))
    XCTAssertTrue(final.promptText.contains("test: finalization evidence"))
    XCTAssertTrue(final.resumedPromptText.contains("test: finalization evidence"))

    let other = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow,
      step: WorkflowStepRef(id: "other-step", nodeId: "workflow-output"),
      payload: payload, variables: [:], session: session
    )
    XCTAssertFalse(other.promptText.contains("Runtime-accepted predecessor step outputs"))
  }

  func testParallelImplementationRequiresLatestCombinedReviewAndBaseIntegration() throws {
    var context = makeContext()
    context.session.executions.removeAll { $0.stepId == "step6-implement" }
    let now = Date(timeIntervalSince1970: 1_700_000_002)
    context.session.executions.append(execution(
      id: "combined-review", stepId: "integration-review",
      payload: ["accepted": .bool(true), "needs_revision": .bool(false), "plans_remaining": .bool(false)],
      now: now
    ))
    context.session.executions.append(execution(
      id: "base-integration", stepId: "base-branch-integrate",
      payload: [
        "mergeStatus": .string("already-on-base"), "basePushStatus": .string("pushed"),
        "implementationCommit": .string(String(repeating: "a", count: 40)),
        "implementationBranch": .string("main"), "baseBranch": .string("main"),
        "remote": .string("origin")
      ], now: now
    ))
    context.payload["baseBranch"] = .string("main")
    context.payload["mergeStatus"] = .string("already-on-base")
    context.payload["basePushStatus"] = .string("pushed")
    let policy = WorkflowGitFinalizationEvidencePolicy(
      commitStepId: "step10-git-commit", pushStepId: "step11-git-push",
      planningModeStepIds: ["step5-impl-plan-review"],
      integrationStepId: "base-branch-integrate", implementationReviewStepId: "integration-review"
    )
    XCTAssertNoThrow(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(context: context, policy: policy))
    var mismatch = context
    mismatch.payload["baseBranch"] = .string("different")
    XCTAssertThrowsError(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(context: mismatch, policy: policy))
    for payload: JSONObject in [
      ["accepted": .bool(true), "needs_revision": .bool(false), "plans_remaining": .bool(true)],
      ["accepted": .bool(false), "needs_revision": .bool(true), "plans_remaining": .bool(false)]
    ] {
      var incomplete = context
      incomplete.session.executions.append(execution(
        id: "latest-review", stepId: "integration-review", payload: payload, now: now
      ))
      XCTAssertThrowsError(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(context: incomplete, policy: policy))
    }
    context.session.executions.removeAll { $0.stepId == "base-branch-integrate" }
    XCTAssertThrowsError(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(context: context, policy: policy))
  }

  func testAcceptsExactCommitAndPushEvidence() throws {
    XCTAssertNoThrow(try validate())
  }

  func testCheckpointPushEvidenceMustMatchAcceptedPlanCommitAndFinalBranch() throws {
    var context = makeContext()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    context.session.executions.insert(execution(
      id: "plan-commit", stepId: "plan-git-commit",
      payload: ["git": .object([
        "operation": .string("commit"), "status": .string("committed"),
        "commitHash": .string(String(repeating: "b", count: 40)),
        "commitMessage": .string("docs: plan checkpoint"),
        "committedFiles": .array([.string("plan.md")])
      ])], now: now
    ), at: 0)
    context.session.executions.insert(execution(
      id: "plan-push", stepId: "plan-git-push",
      payload: ["git": .object([
        "operation": .string("push"), "status": .string("pushed"),
        "commitHash": .string(String(repeating: "b", count: 40)),
        "pushedRemote": .string("origin"), "pushedBranch": .string("main")
      ])], now: now
    ), at: 1)
    let policy = WorkflowGitFinalizationEvidencePolicy(
      commitStepId: "step10-git-commit", pushStepId: "step11-git-push",
      planningModeStepIds: ["step5-impl-plan-review"],
      planCommitStepId: "plan-git-commit", planPushStepId: "plan-git-push"
    )
    let planningOnly = makeContext(workflowMode: "design-plan-only", planningOnly: true)
    XCTAssertNoThrow(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
      context: planningOnly, policy: policy
    ))
    XCTAssertNoThrow(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
      context: context, policy: policy
    ))

    var mismatched = context
    let planPushIndex = try XCTUnwrap(mismatched.session.executions.firstIndex { $0.stepId == "plan-git-push" })
    mismatched.session.executions[planPushIndex].acceptedOutput?.payload["git"] = .object([
      "operation": .string("push"), "status": .string("pushed"),
      "commitHash": .string(String(repeating: "c", count: 40)),
      "pushedRemote": .string("origin"), "pushedBranch": .string("main")
    ])
    XCTAssertThrowsError(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
      context: mismatched, policy: policy
    ))

    var missing = context
    missing.session.executions.removeAll { $0.stepId == "plan-git-push" }
    XCTAssertThrowsError(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
      context: missing, policy: policy
    ))
  }

  func testAcceptsDesignPlanOnlyOutputWithExactGitFinalizationEvidence() throws {
    XCTAssertNoThrow(try validate(makeContext(
      workflowMode: "design-plan-only",
      planningOnly: true
    )))
  }

  func testAcceptsFeatureFanoutDesignPlanOnlyOutputWithExactGitFinalizationEvidence() throws {
    XCTAssertNoThrow(try validate(makeContext(
      workflowMode: "design-plan-only",
      planningOnly: true,
      planningStepId: "step5-feature-plan-join"
    )))
  }

  func testRejectsIssueResolutionModeDowngrade() throws {
    var context = makeContext()
    context.payload["workflowMode"] = .string("design-plan-only")

    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testRejectsPlanningOutputWithoutGitFinalizationEvidence() throws {
    var context = makeContext(workflowMode: "design-plan-only", planningOnly: true)
    context.payload.removeValue(forKey: "commitHash")

    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }

    context = makeContext(
      pushHash: String(repeating: "8", count: 40),
      workflowMode: "design-plan-only",
      planningOnly: true
    )
    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testRejectsMissingFinalEvidence() throws {
    var context = makeContext()
    context.payload.removeValue(forKey: "pushedRemote")

    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testRejectsMissingOrMismatchedTerminalCommittedFiles() throws {
    var context = makeContext()
    context.payload.removeValue(forKey: "committedFiles")
    XCTAssertThrowsError(try validate(context))

    context = makeContext()
    context.payload["committedFiles"] = .array([.string("different.txt")])
    XCTAssertThrowsError(try validate(context))
  }

  func testRejectsStaleOrMismatchedCommitHash() throws {
    var context = makeContext()
    context.payload["commitHash"] = .string(String(repeating: "9", count: 40))

    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }

    context = makeContext(pushHash: String(repeating: "8", count: 40))
    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testRejectsNonCanonicalFullCommitHashes() throws {
    for invalidHash in ["abc", String(repeating: "A", count: 40), String(repeating: "a", count: 41)] {
      XCTAssertThrowsError(try validate(makeContext(commitHash: invalidHash))) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
      }
    }
  }

  func testRejectsUnexpectedAcceptedEvidenceFields() throws {
    var context = makeContext()
    let commitIndex = try XCTUnwrap(context.session.executions.firstIndex {
      $0.stepId == "step10-git-commit"
    })
    var commitExecution = context.session.executions[commitIndex]
    var payload = try XCTUnwrap(commitExecution.acceptedOutput?.payload)
    guard case var .object(evidence)? = payload["git"] else {
      return XCTFail("missing git evidence")
    }
    evidence["remoteURL"] = .string("https://example.invalid/private")
    payload["git"] = .object(evidence)
    commitExecution.acceptedOutput?.payload = payload
    context.session.executions[commitIndex] = commitExecution

    XCTAssertThrowsError(try validate(context)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testRejectsOlderAcceptedGitEvidenceWhenLatestAttemptIsNotAccepted() throws {
    for stepId in ["step10-git-commit", "step11-git-push"] {
      for status in [WorkflowStepExecutionStatus.failed, .running] {
        var context = makeContext()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_001)
        context.session.executions.append(WorkflowStepExecution(
          executionId: "latest-\(stepId)-\(status.rawValue)",
          stepId: stepId,
          nodeId: stepId,
          attempt: 2,
          status: status,
          createdAt: timestamp,
          updatedAt: timestamp
        ))

        XCTAssertThrowsError(try validate(context), "\(stepId) \(status.rawValue)") { error in
          XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
        }
      }
    }
  }

  private func validate(_ context: WorkflowPrePersistenceRoutingContext? = nil) throws {
    try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
      context: context ?? makeContext(),
      policy: WorkflowGitFinalizationEvidencePolicy(
        commitStepId: "step10-git-commit",
        pushStepId: "step11-git-push",
        planningModeStepIds: ["step5-impl-plan-review", "step5-feature-plan-join"]
      )
    )
  }

  private func makeContext(
    commitHash: String = String(repeating: "a", count: 40),
    pushHash: String? = nil,
    workflowMode: String = "issue-resolution",
    planningOnly: Bool = false,
    planningStepId: String = "step5-impl-plan-review"
  ) -> WorkflowPrePersistenceRoutingContext {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let modeExecution = execution(
      id: planningOnly ? "planning-review-execution" : "implementation-execution",
      stepId: planningOnly ? planningStepId : "step6-implement",
      payload: planningOnly ? ["planning_only": .bool(true)] : ["accepted": .bool(true)],
      when: planningOnly ? ["planning_only": true] : ["accepted": true],
      now: now
    )
    let commitExecution = execution(
      id: "commit-execution",
      stepId: "step10-git-commit",
      payload: [
        "git": .object([
          "operation": .string("commit"),
          "status": .string("committed"),
          "commitHash": .string(commitHash),
          "commitMessage": .string("test: finalization evidence"),
          "committedFiles": .array([.string("tracked.txt")])
        ])
      ],
      now: now
    )
    let pushExecution = execution(
      id: "push-execution",
      stepId: "step11-git-push",
      payload: [
        "git": .object([
          "operation": .string("push"),
          "status": .string("pushed"),
          "commitHash": .string(pushHash ?? commitHash),
          "pushedRemote": .string("origin"),
          "pushedBranch": .string("main")
        ])
      ],
      now: now
    )
    let outputExecution = WorkflowStepExecution(
      executionId: "output-execution",
      stepId: "workflow-output",
      nodeId: "workflow-output",
      attempt: 1,
      createdAt: now,
      updatedAt: now
    )
    let session = WorkflowSession(
      workflowId: "codex-design-and-implement-review-loop",
      sessionId: "session",
      status: .running,
      entryStepId: "step10-git-commit",
      currentStepId: "workflow-output",
      createdAt: now,
      updatedAt: now,
      executions: [modeExecution, commitExecution, pushExecution, outputExecution]
    )
    return WorkflowPrePersistenceRoutingContext(
      session: session,
      stepExecution: outputExecution,
      payload: [
        "status": .string("accepted"),
        "workflowMode": .string(workflowMode),
        "commitMessage": .string("test: finalization evidence"),
        "committedFiles": .array([.string("tracked.txt")]),
        "commitHash": .string(commitHash),
        "pushedRemote": .string("origin"),
        "pushedBranch": .string("main")
      ],
      when: ["always": true],
      selectedTransitions: [],
      publishesRootOutput: true,
      completesRootWithoutOutput: false,
      intendedSuccessfulStatus: .completed
    )
  }

  private func execution(
    id: String,
    stepId: String,
    payload: JSONObject,
    when: [String: Bool] = ["always": true],
    now: Date
  ) -> WorkflowStepExecution {
    WorkflowStepExecution(
      executionId: id,
      stepId: stepId,
      nodeId: stepId,
      attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: payload,
        when: when,
        acceptedAt: now
      ),
      createdAt: now,
      updatedAt: now
    )
  }
}
