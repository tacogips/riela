import Foundation
import XCTest
@testable import RielaCore

final class WorkflowGitFinalizationEvidenceTests: XCTestCase {
  func testAcceptsExactCommitAndPushEvidence() throws {
    XCTAssertNoThrow(try validate())
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
