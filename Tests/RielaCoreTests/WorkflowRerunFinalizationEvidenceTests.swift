import Foundation
import XCTest
@testable import RielaCore

final class WorkflowRerunFinalizationEvidenceTests: XCTestCase {
  func testDispatchRerunBindsLatestGitEvidenceWithoutModeEvidence() throws {
    let workflow = protectedWorkflow()
    let source = sourceSession(workflow: workflow, executions: acceptedEvidence())
    let expectedSteps: Set<String> = [
      "plan-git-commit", "plan-git-push", "step10-git-commit", "step11-git-push", "base-branch-integrate"
    ]
    for target in ["dispatch-plans", "integration-review", "reconcile-implementations"] {
      let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
        workflow: workflow, source: source, targetStepId: target, available: source.executions
      )
      XCTAssertEqual(Set(bound.map(\.stepId)), expectedSteps, target)
      XCTAssertEqual(bound.map(\.stepId), source.executions.filter { bound.contains($0) }.map(\.stepId))
    }
  }

  func testCompletedRetryWinsAndTerminalRerunBindsModeEvidence() throws {
    let workflow = protectedWorkflow()
    var executions = acceptedEvidence()
    let retry = try XCTUnwrap(executions.first { $0.stepId == "step10-git-commit" })
    var failed = retry
    failed.executionId = "step10-failed"
    failed.status = .failed
    failed.acceptedOutput = nil
    executions.insert(failed, at: try XCTUnwrap(executions.firstIndex(of: retry)))
    let source = sourceSession(workflow: workflow, executions: executions)
    let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "workflow-output", available: executions
    )

    XCTAssertTrue(bound.contains { $0.executionId == retry.executionId })
    XCTAssertFalse(bound.contains { $0.executionId == failed.executionId })
    XCTAssertTrue(bound.contains { $0.stepId == "integration-review" })
    XCTAssertTrue(bound.contains { $0.stepId == "step6-implement" })
  }

  func testFailedLatestPlanEvidenceRejectsMidPipelineRerun() throws {
    let workflow = protectedWorkflow()
    var executions = acceptedEvidence()
    var failed = try XCTUnwrap(executions.first { $0.stepId == "plan-git-commit" })
    failed.executionId = "plan-commit-failed"
    failed.status = .failed
    failed.acceptedOutput = nil
    executions.removeAll { $0.stepId == "plan-git-commit" }
    executions.append(failed)
    let source = sourceSession(workflow: workflow, executions: executions)

    XCTAssertThrowsError(try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "dispatch-plans", available: executions
    )) { error in
      XCTAssertTrue(String(describing: error).contains("protected git finalization evidence for plan-git-commit"))
      XCTAssertTrue(String(describing: error).contains("rerun from plan-git-commit or use session resume --retry-failed-step"))
    }
  }

  func testGuaranteedPlanEvidenceDoesNotNeedSourceExecutionForEarlyTargets() throws {
    let workflow = protectedWorkflow()
    var executions = acceptedEvidence().filter { $0.stepId != "plan-git-push" }
    let failedPlanCommit = try XCTUnwrap(executions.first { $0.stepId == "plan-git-commit" })
    executions.removeAll { $0.stepId == "plan-git-commit" }
    executions.append(failed("plan-commit-failed", step: failedPlanCommit.stepId))
    let source = sourceSession(workflow: workflow, executions: executions)

    for target in ["step4-impl-plan-create", "step1-issue-intake"] {
      let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
        workflow: workflow, source: source, targetStepId: target, available: executions
      )
      XCTAssertFalse(bound.contains { $0.stepId == "plan-git-commit" || $0.stepId == "plan-git-push" })
    }

    let policy = try XCTUnwrap(DeterministicWorkflowRunner.gitFinalizationEvidencePolicy(
      workflow: workflow, terminalStep: try XCTUnwrap(workflow.steps.first { $0.id == "workflow-output" })
    ))
    XCTAssertTrue(policy.planningModeStepIds.contains("step5-impl-plan-review"))
  }

  func testFailedModeEvidenceOutsideRerunPathRejects() throws {
    let workflow = protectedWorkflow()
    var executions = acceptedEvidence()
    var failed = try XCTUnwrap(executions.first { $0.stepId == "integration-review" })
    failed.executionId = "integration-review-failed"
    failed.status = .failed
    failed.acceptedOutput = nil
    executions.removeAll { $0.stepId == "integration-review" }
    executions.append(failed)
    let source = sourceSession(workflow: workflow, executions: executions)

    XCTAssertThrowsError(try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "workflow-output", available: executions
    )) { error in
      XCTAssertTrue(String(describing: error).contains("integration-review"))
    }
  }

  func testFinalCommitTargetBindsModeAndPlanEvidence() throws {
    let workflow = protectedWorkflow()
    let executions = acceptedEvidence()
    let source = sourceSession(workflow: workflow, executions: executions)
    let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "step10-git-commit", available: executions
    )
    XCTAssertTrue(bound.contains { $0.stepId == "integration-review" })
    XCTAssertTrue(bound.contains { $0.stepId == "step6-implement" })
    XCTAssertTrue(bound.contains { $0.stepId == "step5-impl-plan-review" })
    XCTAssertTrue(bound.contains { $0.stepId == "plan-git-commit" })
    XCTAssertTrue(bound.contains { $0.stepId == "plan-git-push" })
  }

  func testFullRestartDoesNotBindStaleModeAndUnprotectedWorkflowIsNoOp() throws {
    let workflow = protectedWorkflow()
    let executions = acceptedEvidence()
    let source = sourceSession(workflow: workflow, executions: executions)
    let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "step1-issue-intake", available: executions
    )
    XCTAssertFalse(bound.contains { ["integration-review", "step6-implement", "step5-impl-plan-review"].contains($0.stepId) })

    var unprotected = workflow
    unprotected.workflowId = "unprotected"
    XCTAssertEqual(try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: unprotected, source: source, targetStepId: "workflow-output", available: executions
    ), [])
  }

  func testPlanningRouteFilterKeepsOtherLabeledEdges() throws {
    let workflow = protectedWorkflow()
    let terminal = try XCTUnwrap(workflow.steps.first { $0.id == "workflow-output" })
    let policy = try XCTUnwrap(DeterministicWorkflowRunner.gitFinalizationEvidencePolicy(
      workflow: workflow, terminalStep: terminal
    ))
    XCTAssertEqual(policy.planCommitStepId, "plan-git-commit")
    XCTAssertEqual(policy.planPushStepId, "plan-git-push")
    XCTAssertEqual(policy.integrationStepId, "base-branch-integrate")
    let executions = acceptedEvidence().filter { !["plan-git-commit", "plan-git-push"].contains($0.stepId) }
    let source = sourceSession(workflow: workflow, executions: executions)
    XCTAssertNoThrow(try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "step5-impl-plan-review", available: executions
    ))
  }

  func testPlanningRouteFilterRetainsParallelNonPlanningEdge() throws {
    var workflow = protectedWorkflow()
    let reviewIndex = try XCTUnwrap(workflow.steps.firstIndex { $0.id == "step5-impl-plan-review" })
    workflow.steps[reviewIndex].transitions?.append(WorkflowStepTransition(
      toStepId: "step9-commit-message", label: "alternate_route"
    ))
    let executions = acceptedEvidence().filter { !["plan-git-commit", "plan-git-push"].contains($0.stepId) }
    let source = sourceSession(workflow: workflow, executions: executions)

    XCTAssertThrowsError(try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: "step5-impl-plan-review", available: executions
    )) { error in
      XCTAssertTrue(String(describing: error).contains("plan-git-commit"))
    }
  }

  func testValidatorRoundTripForDispatchAndIntegrationReviewTargets() throws {
    let workflow = protectedWorkflow()
    let sourceExecutions = acceptedEvidence()
    let source = sourceSession(workflow: workflow, executions: sourceExecutions)
    let policy = try XCTUnwrap(DeterministicWorkflowRunner.gitFinalizationEvidencePolicy(
      workflow: workflow, terminalStep: try XCTUnwrap(workflow.steps.first { $0.id == "workflow-output" })
    ))
    for target in ["dispatch-plans", "integration-review"] {
      let bound = try DeterministicWorkflowRunner.rerunFinalizationEvidenceExecutions(
        workflow: workflow, source: source, targetStepId: target, available: sourceExecutions
      )
      let tail = sourceExecutions.filter {
        ["step6-implement", "reconcile-implementations", "integration-review", "step8-docs-refresh",
          "step9-commit-message", "step10-git-commit", "step11-git-push", "base-branch-integrate"].contains($0.stepId)
      }
      var simulated = source
      simulated.executions = bound + tail
      let outputExecution = WorkflowStepExecution(
        executionId: "workflow-output", stepId: "workflow-output", nodeId: "workflow-output",
        attempt: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
      )
      let context = WorkflowPrePersistenceRoutingContext(
        session: simulated,
        stepExecution: outputExecution,
        payload: finalOutputPayload(),
        when: ["always": true],
        selectedTransitions: [],
        publishesRootOutput: true,
        completesRootWithoutOutput: false,
        intendedSuccessfulStatus: .completed
      )
      XCTAssertNoThrow(try DeterministicWorkflowRunner.validateGitFinalizationEvidence(
        context: context, policy: policy
      ), target)
    }
  }

  func testRunnerImportsEvidenceBeforePlainWorkflowOutputRerunAndRejectsIncompleteModePreflight() async throws {
    let workflow = protectedWorkflow()
    let nodes = nodePayloads(for: workflow)
    let output = finalOutputPayload()
    let acceptedSourceExecutions = acceptedEvidence()
    let terminalFailure = failed("workflow-output-failed", step: "workflow-output")
    let source = sourceSession(workflow: workflow, executions: acceptedSourceExecutions + [terminalFailure])
    let store = InMemoryWorkflowRuntimeStore()
    await store.seedSession(source)
    let adapter = FinalOutputAdapter(payload: output)
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes,
        rerunFromSessionId: source.sessionId, rerunFromStepId: "workflow-output")
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.nodeExecutions, 1)
    XCTAssertEqual(result.session.executions.filter { $0.importedFrom != nil }.map(\.stepId),
      ["step5-impl-plan-review", "step6-implement", "integration-review", "plan-git-commit",
        "plan-git-push", "step10-git-commit", "step11-git-push", "base-branch-integrate"])
    let successfulAdapterCallCount = await adapter.callCount
    XCTAssertEqual(successfulAdapterCallCount, 1)

    var incompleteExecutions = acceptedSourceExecutions.filter { $0.stepId != "integration-review" }
    incompleteExecutions.append(failed("integration-review-failed", step: "integration-review"))
    let incompleteSource = sourceSession(
      workflow: workflow, executions: incompleteExecutions + [terminalFailure]
    )
    let blockedStore = InMemoryWorkflowRuntimeStore()
    await blockedStore.seedSession(incompleteSource)
    let blockedAdapter = FinalOutputAdapter(payload: output)
    do {
      _ = try await DeterministicWorkflowRunner(store: blockedStore, adapter: blockedAdapter).run(
        DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodes,
          rerunFromSessionId: incompleteSource.sessionId, rerunFromStepId: "workflow-output")
      )
      XCTFail("incomplete mode evidence must reject before creating a session")
    } catch {
      XCTAssertTrue(String(describing: error).contains("integration-review"))
    }
    let latestBlockedSession = await blockedStore.latestSession(workflowId: workflow.workflowId)
    let blockedAdapterCallCount = await blockedAdapter.callCount
    XCTAssertEqual(latestBlockedSession, incompleteSource)
    XCTAssertEqual(blockedAdapterCallCount, 0)
  }

  private func acceptedEvidence() -> [WorkflowStepExecution] {
    [
      accepted("planning-review", step: "step5-impl-plan-review", payload: ["planning_only": .bool(false)]),
      accepted("implementation", step: "step6-implement", payload: ["accepted": .bool(true)]),
      accepted("combined-review", step: "integration-review", payload: [
        "accepted": .bool(true), "needs_revision": .bool(false), "plans_remaining": .bool(false)
      ]),
      accepted("plan-commit", step: "plan-git-commit", payload: ["git": .object(commitEvidence(hash: String(repeating: "b", count: 40)))]),
      accepted("plan-push", step: "plan-git-push", payload: ["git": .object(pushEvidence(hash: String(repeating: "b", count: 40)))]),
      accepted("final-commit", step: "step10-git-commit", payload: ["git": .object(commitEvidence(hash: String(repeating: "a", count: 40)))]),
      accepted("final-push", step: "step11-git-push", payload: ["git": .object(pushEvidence(hash: String(repeating: "a", count: 40)))]),
      accepted("integration", step: "base-branch-integrate", payload: [
        "mergeStatus": .string("already-on-base"), "basePushStatus": .string("pushed"),
        "implementationCommit": .string(String(repeating: "a", count: 40)),
        "implementationBranch": .string("main"), "remote": .string("origin"), "baseBranch": .string("main")
      ])
    ]
  }

  private func commitEvidence(hash: String) -> JSONObject {
    ["operation": .string("commit"), "status": .string("committed"), "commitHash": .string(hash),
      "commitMessage": .string("test: finalization evidence"),
      "committedFiles": .array([.string("tracked.txt")])]
  }

  private func pushEvidence(hash: String) -> JSONObject {
    ["operation": .string("push"), "status": .string("pushed"), "commitHash": .string(hash),
      "pushedRemote": .string("origin"), "pushedBranch": .string("main")]
  }

  private func finalOutputPayload() -> JSONObject {
    ["status": .string("accepted"), "workflowMode": .string("issue-resolution"),
      "commitHash": .string(String(repeating: "a", count: 40)),
      "commitMessage": .string("test: finalization evidence"),
      "committedFiles": .array([.string("tracked.txt")]), "pushedRemote": .string("origin"),
      "pushedBranch": .string("main"), "baseBranch": .string("main"),
      "mergeStatus": .string("already-on-base"), "basePushStatus": .string("pushed")]
  }

  private func nodePayloads(for workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: workflow.nodes.map { node in
      (node.id, AgentNodePayload(
        id: node.id,
        model: "fixture",
        output: NodeOutputContract(jsonSchema: ["type": .string("object")])
      ))
    })
  }

  private func failed(_ id: String, step: String) -> WorkflowStepExecution {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowStepExecution(
      executionId: id, stepId: step, nodeId: step, attempt: 1, status: .failed,
      createdAt: now, updatedAt: now
    )
  }

  private func accepted(_ id: String, step: String, payload: JSONObject = [:]) -> WorkflowStepExecution {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowStepExecution(
      executionId: id,
      stepId: step,
      nodeId: step,
      attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: payload, when: [:], acceptedAt: now),
      createdAt: now,
      updatedAt: now
    )
  }

  private func sourceSession(workflow: WorkflowDefinition, executions: [WorkflowStepExecution]) -> WorkflowSession {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowSession(
      workflowId: workflow.workflowId,
      sessionId: "source",
      status: .failed,
      entryStepId: workflow.entryStepId,
      currentStepId: "workflow-output",
      createdAt: now,
      updatedAt: now,
      executions: executions
    )
  }

  private func protectedWorkflow() -> WorkflowDefinition {
    let ids = [
      "step1-issue-intake", "step2-design-doc-update", "step4-impl-plan-create", "step5-impl-plan-review",
      "plan-checkpoint", "plan-contract-validate", "plan-git-commit", "plan-git-push", "dispatch-plans",
      "step6-implement", "reconcile-implementations", "integration-review", "runtime-tracking-contract-check",
      "step8-docs-refresh",
      "step9-commit-message", "step10-git-commit", "step11-git-push", "base-branch-integrate", "workflow-output"
    ]
    let commitAddon = WorkflowNodeAddonRef(name: "riela/git-commit", version: "1")
    let pushAddon = WorkflowNodeAddonRef(name: "riela/git-push", version: "1")
    let transitions: [String: [WorkflowStepTransition]] = [
      "step1-issue-intake": [WorkflowStepTransition(toStepId: "step4-impl-plan-create")],
      "step2-design-doc-update": [WorkflowStepTransition(toStepId: "step4-impl-plan-create")],
      "step4-impl-plan-create": [WorkflowStepTransition(toStepId: "step5-impl-plan-review")],
      "step5-impl-plan-review": [
        WorkflowStepTransition(toStepId: "step2-design-doc-update", label: "needs_design_revision"),
        WorkflowStepTransition(toStepId: "step4-impl-plan-create", label: "needs_revision && !(needs_design_revision)"),
        WorkflowStepTransition(toStepId: "step9-commit-message", label: "planning_only && !(needs_design_revision || needs_revision)"),
        WorkflowStepTransition(toStepId: "plan-checkpoint", label: "!(planning_only || needs_design_revision || needs_revision)")
      ],
      "plan-checkpoint": [WorkflowStepTransition(toStepId: "plan-contract-validate")],
      "plan-contract-validate": [WorkflowStepTransition(toStepId: "plan-git-commit")],
      "plan-git-commit": [WorkflowStepTransition(toStepId: "plan-git-push")],
      "plan-git-push": [WorkflowStepTransition(toStepId: "dispatch-plans")],
      "dispatch-plans": [WorkflowStepTransition(toStepId: "step6-implement", fanout: WorkflowStepFanout(
        groupId: "implementations", itemsFrom: "/items", joinStepId: "reconcile-implementations"
      ))],
      "step6-implement": [WorkflowStepTransition(toStepId: "reconcile-implementations")],
      "reconcile-implementations": [WorkflowStepTransition(toStepId: "integration-review")],
      "integration-review": [
        WorkflowStepTransition(toStepId: "dispatch-plans", label: "plans_remaining"),
        WorkflowStepTransition(toStepId: "runtime-tracking-contract-check")
      ],
      "runtime-tracking-contract-check": [
        WorkflowStepTransition(toStepId: "step4-impl-plan-create", label: "tracking_contract_rejected"),
        WorkflowStepTransition(toStepId: "step8-docs-refresh")
      ],
      "step8-docs-refresh": [WorkflowStepTransition(toStepId: "step9-commit-message")],
      "step9-commit-message": [WorkflowStepTransition(toStepId: "step10-git-commit")],
      "step10-git-commit": [WorkflowStepTransition(toStepId: "step11-git-push")],
      "step11-git-push": [WorkflowStepTransition(toStepId: "base-branch-integrate")],
      "base-branch-integrate": [WorkflowStepTransition(toStepId: "workflow-output")]
    ]
    let nodes = ids.map { id in
      let addon: WorkflowNodeAddonRef?
      if id == "step10-git-commit" || id == "plan-git-commit" {
        addon = commitAddon
      } else if id == "step11-git-push" || id == "plan-git-push" {
        addon = pushAddon
      } else {
        addon = nil
      }
      return WorkflowNodeRef(id: id, addon: addon)
    }
    let steps = ids.map { id in WorkflowStepRef(id: id, nodeId: id, transitions: transitions[id]) }
    return WorkflowDefinition(
      workflowId: "codex-design-and-implement-review-loop",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step1-issue-intake",
      nodeRegistry: nodes.map { WorkflowNodeRegistryRef(id: $0.id, addon: $0.addon) },
      steps: steps,
      nodes: nodes
    )
  }
}

private actor FinalOutputAdapter: NodeAdapter {
  let payload: JSONObject
  private(set) var callCount = 0

  init(payload: JSONObject) {
    self.payload = payload
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    callCount += 1
    return AdapterExecutionOutput(
      provider: "test", model: "fixture", promptText: input.promptText,
      completionPassed: true, payload: payload
    )
  }
}
