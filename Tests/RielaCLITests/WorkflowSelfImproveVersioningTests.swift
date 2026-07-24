import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowSelfImproveVersioningTests: XCTestCase {
  func testRuntimeOwnedReviewSessionFinalizesImmutableProposalThroughCLI() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let app = RielaCLIApplication()
    let proposalResponse = await app.run([
      "workflow", "self-improve", "versioned-flow", "--working-dir", root.path,
      "--dry-run", "--source-session-id", "session-proposal", "--output", "json"
    ])
    XCTAssertEqual(proposalResponse.exitCode, .success, proposalResponse.stderr)
    let proposalResult = try decodeVersionJSON(WorkflowSelfImproveCommandResult.self, proposalResponse.stdout)
    let proposalId = try XCTUnwrap(proposalResult.proposalId)
    let proposalDigest = try XCTUnwrap(proposalResult.proposalDigest)
    let resolved = try resolveVersioningTarget(root: root)
    let proposal = try WorkflowChangeSetStore(root: resolved.historyRoot).loadProposal(
      proposalId,
      expectedIdentity: resolved.identity
    )
    let workflowBytes = try Data(contentsOf: URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json"))
    let workflowObject = try XCTUnwrap(JSONSerialization.jsonObject(with: workflowBytes) as? [String: Any])
    let nodeId = try XCTUnwrap((workflowObject["nodes"] as? [[String: Any]])?.first?["id"] as? String)
    let scenarioURL = root.appendingPathComponent("tmp-review-scenario.json")
    let scenario: [String: Any] = [nodeId: [
      "provider": "scenario-mock",
      "model": "gpt-5.5",
      "payload": [
        "loopGate": ["gateId": "review-gate", "decision": "accepted"],
        "workflowChangeReview": [
          "gateId": "review-gate",
          "decision": "accepted",
          "reviewedProposalId": proposalId,
          "reviewedProposalDigest": proposalDigest,
          "reviewedBeforeBundleDigest": proposal.beforeBundleDigest,
          "evidenceReferences": ["runtime:review"]
        ]
      ]
    ]]
    try JSONSerialization.data(withJSONObject: scenario, options: [.sortedKeys]).write(to: scenarioURL)
    let sessionStore = root.appendingPathComponent("sessions").path
    let run = await app.run([
      "workflow", "run", "versioned-flow", "--working-dir", root.path,
      "--mock-scenario", scenarioURL.path, "--session-store", sessionStore, "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    let sessionId = try decodeVersionJSON(WorkflowRunResult.self, run.stdout).session.sessionId

    let finalized = await app.run([
      "workflow", "self-improve", "versioned-flow", "--working-dir", root.path,
      "--proposal-id", proposalId, "--review-session-id", sessionId,
      "--session-store", sessionStore, "--output", "json"
    ])
    XCTAssertEqual(finalized.exitCode, .success, finalized.stdout + finalized.stderr)
    let result = try decodeVersionJSON(WorkflowSelfImproveCommandResult.self, finalized.stdout)
    XCTAssertNotNil(result.changeSetId)
    XCTAssertNotNil(result.finalizedDigest)
    XCTAssertFalse(result.mutated)
  }

  func testProposalReviewFinalizeAndApplyUsesSnapshotAndEvidenceBindings() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let root = fixture.root
    let app = RielaCLIApplication()
    let workflowURL = fixture.workflowDirectory.appendingPathComponent("workflow.json")
    let before = try Data(contentsOf: workflowURL)
    let proposalResponse = await app.run([
      "workflow", "self-improve", "versioned-flow",
      "--scope", "user",
      "--working-dir", root.path,
      "--dry-run",
      "--source-session-id", "session-review",
      "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(proposalResponse.exitCode, .success, proposalResponse.stderr)
    let proposalResult = try decodeVersionJSON(WorkflowSelfImproveCommandResult.self, proposalResponse.stdout)
    XCTAssertFalse(proposalResult.mutated)
    XCTAssertEqual(try Data(contentsOf: workflowURL), before)

    let resolved = fixture.resolved
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let proposalId = try XCTUnwrap(proposalResult.proposalId)
    let proposalDigest = try XCTUnwrap(proposalResult.proposalDigest)
    let proposal = try WorkflowChangeSetStore(root: historyRoot).loadProposal(proposalId, expectedIdentity: target)
    let gate = try WorkflowReviewGatePolicy.requiredGate(in: resolved.bundle.workflow)
    let gateResult = LoopGateResult(
      gateId: gate.id,
      stepId: gate.stepId,
      stepExecutionId: "review-exec",
      decision: .accepted
    )
    let gateResultId = try WorkflowRuntimeGateEvidenceStore.resultId(stepExecutionId: gateResult.stepExecutionId)
    try WorkflowRuntimeGateEvidenceStore(root: historyRoot).publish(WorkflowRuntimeGateEvidence(
      resultId: gateResultId,
      workflowId: resolved.bundle.workflow.workflowId,
      sessionId: "review-session",
      result: gateResult
    ))
    let review = WorkflowChangeSetReviewEvidence(
      gateId: gate.id,
      gateResultId: gateResultId,
      decision: .accepted,
      reviewedProposalId: proposalId,
      reviewedProposalDigest: proposalDigest,
      reviewedBeforeBundleDigest: proposal.beforeBundleDigest,
      reviewerStepId: gate.stepId,
      reviewerStepExecutionId: "review-exec",
      reviewedAt: Date()
    )
    let changeSet = try WorkflowChangeSetStore(root: historyRoot).finalize(
      proposalId: proposalId,
      expectedIdentity: target,
      review: review
    )
    let applyResponse = await app.run([
      "workflow", "self-improve", "versioned-flow",
      "--scope", "user",
      "--working-dir", root.path,
      "--yes",
      "--change-set-id", changeSet.changeSetId,
      "--expected-digest", changeSet.finalizedDigest,
      "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(applyResponse.exitCode, .success, applyResponse.stdout + applyResponse.stderr)
    let result = try decodeVersionJSON(WorkflowSelfImproveCommandResult.self, applyResponse.stdout)
    XCTAssertTrue(result.mutated)
    XCTAssertEqual(result.changeSetId, changeSet.changeSetId)
    XCTAssertNotNil(result.snapshotId)
    XCTAssertNotNil(result.transactionId)
    XCTAssertEqual(result.mutationEvidence?.review?.gateResultId, gateResultId)
    XCTAssertTrue(try String(contentsOf: workflowURL).contains("self-improve-reviewed"))
  }

  func testApplyRejectsMissingApprovalStaleDigestAndImmutablePackageIdentity() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let app = RielaCLIApplication()
    let response = await app.run([
      "workflow", "self-improve", "versioned-flow",
      "--working-dir", root.path,
      "--change-set-id", "change-set-missing",
      "--expected-digest", String(repeating: "0", count: 64),
      "--output", "json"
    ])
    XCTAssertNotEqual(response.exitCode, .success)
    XCTAssertTrue((response.stdout + response.stderr).contains("explicit --yes"))

    for alias in ["--overwrite", "--force", "-f"] {
      let aliased = await app.run([
        "workflow", "self-improve", "versioned-flow", "--working-dir", root.path,
        alias, "--change-set-id", "change-set-missing",
        "--expected-digest", String(repeating: "0", count: 64), "--output", "json"
      ])
      XCTAssertNotEqual(aliased.exitCode, .success)
      XCTAssertTrue((aliased.stdout + aliased.stderr).contains("explicit --yes"))
    }

    let immutableApply = await app.run([
      "workflow", "self-improve", "versioned-flow", "--working-dir", root.path,
      "--yes", "--change-set-id", "change-set-missing",
      "--expected-digest", String(repeating: "0", count: 64), "--output", "json"
    ])
    XCTAssertEqual(immutableApply.exitCode, .failure)
    XCTAssertTrue(
      (immutableApply.stdout + immutableApply.stderr)
        .contains(WorkflowRegistryErrorCode.immutableWorkflow.rawValue)
    )

    let target = try resolveVersioningTarget(root: root).identity
    var immutable = target
    immutable.sourceKind = .installedPackage
    immutable.sourceMutable = false
    immutable.packageDirectory = immutable.ownershipRoot
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: immutable,
      historyRoot: root.appendingPathComponent("history"),
      kind: .apply,
      expectedBeforeBundleDigest: String(repeating: "0", count: 64),
      expectedAfterBundleDigest: String(repeating: "1", count: 64),
      preOperationSnapshotId: "snapshot-test"
    ) { _ in })
  }

  func testFinalizerRejectsOrdinaryNodeWrongGateFabricatedResultIdAndAbsentGate() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let proposal = try makeReviewProposal(root: root, resolved: resolved)
    let gate = try WorkflowReviewGatePolicy.requiredGate(in: resolved.bundle.workflow)
    let finalizer = WorkflowRuntimeReviewFinalizer()

    var workflowWithOrdinaryNode = resolved.bundle.workflow
    workflowWithOrdinaryNode.steps.append(WorkflowStepRef(id: "ordinary", nodeId: "ordinary-node"))
    XCTAssertThrowsError(try finalizer.finalize(
      proposalId: proposal.proposalId,
      expectedIdentity: resolved.identity,
      historyRoot: resolved.historyRoot,
      workflow: workflowWithOrdinaryNode,
      runtimeSnapshot: reviewSnapshot(
        workflow: workflowWithOrdinaryNode,
        proposal: proposal,
        executionStepId: "ordinary",
        resultGateId: gate.id
      )
    ))

    XCTAssertThrowsError(try finalizer.finalize(
      proposalId: proposal.proposalId,
      expectedIdentity: resolved.identity,
      historyRoot: resolved.historyRoot,
      workflow: resolved.bundle.workflow,
      runtimeSnapshot: reviewSnapshot(
        workflow: resolved.bundle.workflow,
        proposal: proposal,
        executionStepId: gate.stepId,
        resultGateId: "wrong-gate"
      )
    ))

    XCTAssertThrowsError(try finalizer.finalize(
      proposalId: proposal.proposalId,
      expectedIdentity: resolved.identity,
      historyRoot: resolved.historyRoot,
      workflow: resolved.bundle.workflow,
      runtimeSnapshot: reviewSnapshot(
        workflow: resolved.bundle.workflow,
        proposal: proposal,
        executionStepId: gate.stepId,
        resultGateId: gate.id,
        fabricatedResultId: true
      )
    ))

    var workflowWithoutGate = resolved.bundle.workflow
    workflowWithoutGate.loop?.gates = []
    XCTAssertThrowsError(try finalizer.finalize(
      proposalId: proposal.proposalId,
      expectedIdentity: resolved.identity,
      historyRoot: resolved.historyRoot,
      workflow: workflowWithoutGate,
      runtimeSnapshot: reviewSnapshot(
        workflow: workflowWithoutGate,
        proposal: proposal,
        executionStepId: gate.stepId,
        resultGateId: gate.id
      )
    ))
  }

  func testChangeSetRejectsEmbeddedProposalMismatchAndMissingOrCorruptProposalObjects() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let store = WorkflowChangeSetStore(root: resolved.historyRoot)

    let mismatchProposal = try makeReviewProposal(root: root, resolved: resolved)
    var mismatchChangeSet = try store.finalize(
      proposalId: mismatchProposal.proposalId,
      expectedIdentity: resolved.identity,
      review: reviewEvidence(for: mismatchProposal)
    )
    mismatchChangeSet.proposal.rationale += " mismatched embedded value"
    mismatchChangeSet.proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(
      mismatchChangeSet.proposal
    )
    mismatchChangeSet.review.reviewedProposalDigest = mismatchChangeSet.proposal.proposalDigest
    mismatchChangeSet.finalizedDigest = try WorkflowHistoryCanonicalCoding.finalizedDigest(mismatchChangeSet)
    let mismatchDirectory = resolved.historyRoot
      .appendingPathComponent("change-sets/\(mismatchChangeSet.changeSetId)")
    let mismatchURL = mismatchDirectory.appendingPathComponent("change-set.json")
    let mismatchSidecar = mismatchDirectory.appendingPathComponent("change-set.sha256")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mismatchURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mismatchSidecar.path)
    let mismatchBytes = try WorkflowHistoryCanonicalCoding.encode(mismatchChangeSet)
    try mismatchBytes.write(to: mismatchURL)
    try Data("\(WorkflowHistoryCanonicalCoding.sha256(mismatchBytes))\n".utf8).write(to: mismatchSidecar)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mismatchURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mismatchSidecar.path)
    XCTAssertThrowsError(try store.loadChangeSet(
      mismatchChangeSet.changeSetId,
      expectedIdentity: resolved.identity
    )) { error in
      XCTAssertTrue(String(describing: error).contains("embedded proposal"))
    }

    for corruption in ["missing", "corrupt"] {
      let proposal = try makeReviewProposal(root: root, resolved: resolved)
      let changeSet = try store.finalize(
        proposalId: proposal.proposalId,
        expectedIdentity: resolved.identity,
        review: reviewEvidence(for: proposal)
      )
      let digest = try XCTUnwrap(proposal.operations.compactMap(\.after?.contentDigest).first)
      let objectDirectory = resolved.historyRoot
        .appendingPathComponent("proposals/\(proposal.proposalId)/objects/sha256/\(digest.prefix(2))")
      let objectURL = objectDirectory.appendingPathComponent(digest)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: objectDirectory.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: objectURL.path)
      if corruption == "missing" {
        try FileManager.default.removeItem(at: objectURL)
      } else {
        try Data("corrupt".utf8).write(to: objectURL)
      }
      XCTAssertThrowsError(try store.loadChangeSet(changeSet.changeSetId, expectedIdentity: resolved.identity))
    }
  }

  func testDeclaredGatePolicyRejectsPersistedRuntimeEvidence() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let resolved = fixture.resolved
      let proposal = try makeReviewProposal(root: fixture.root, resolved: resolved)
      let gate = try WorkflowReviewGatePolicy.requiredGate(in: resolved.bundle.workflow)
      let gateResult = LoopGateResult(
        gateId: gate.id,
        stepId: gate.stepId,
        stepExecutionId: "review-execution",
        decision: .accepted,
        severityCounts: LoopFindingSeverityCounts(medium: 1)
      )
      let resultId = try WorkflowRuntimeGateEvidenceStore.resultId(
        stepExecutionId: gateResult.stepExecutionId
      )
      try WorkflowRuntimeGateEvidenceStore(root: resolved.historyRoot).publish(
        WorkflowRuntimeGateEvidence(
          resultId: resultId,
          workflowId: resolved.bundle.workflow.workflowId,
          sessionId: "review-session",
          result: gateResult
        )
      )
      var review = reviewEvidence(for: proposal)
      review.gateResultId = resultId
      review.reviewerStepId = gate.stepId
      let changeSet = try WorkflowChangeSetStore(root: resolved.historyRoot).finalize(
        proposalId: proposal.proposalId,
        expectedIdentity: resolved.identity,
        review: review
      )
      XCTAssertThrowsError(try WorkflowSelfImproveVersioning().execute(
        workflowName: "versioned-flow",
        bundle: resolved.bundle,
        workingDirectory: fixture.root,
        dryRun: false,
        approved: true,
        changeSetId: changeSet.changeSetId,
        expectedDigest: changeSet.finalizedDigest,
        sourceSessionId: nil
      )) { error in
        XCTAssertTrue(String(describing: error).contains("medium-finding policy"))
      }
    }
  }

  private func makeReviewProposal(
    root: URL,
    resolved: WorkflowVersioningResolvedTarget
  ) throws -> WorkflowChangeProposal {
    let result = try WorkflowSelfImproveVersioning().execute(
      workflowName: "versioned-flow",
      bundle: resolved.bundle,
      workingDirectory: root,
      dryRun: true,
      approved: false,
      changeSetId: nil,
      expectedDigest: nil,
      sourceSessionId: "proposal-session"
    )
    return try WorkflowChangeSetStore(root: resolved.historyRoot).loadProposal(
      try XCTUnwrap(result.proposalId),
      expectedIdentity: resolved.identity
    )
  }

  private func reviewEvidence(for proposal: WorkflowChangeProposal) -> WorkflowChangeSetReviewEvidence {
    WorkflowChangeSetReviewEvidence(
      gateId: "review-gate",
      gateResultId: "gate-result-review-execution",
      decision: .accepted,
      reviewedProposalId: proposal.proposalId,
      reviewedProposalDigest: proposal.proposalDigest,
      reviewedBeforeBundleDigest: proposal.beforeBundleDigest,
      reviewerStepId: "step-main-worker",
      reviewerStepExecutionId: "review-execution",
      reviewedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func reviewSnapshot(
    workflow: WorkflowDefinition,
    proposal: WorkflowChangeProposal,
    executionStepId: String,
    resultGateId: String,
    fabricatedResultId: Bool = false
  ) -> WorkflowRuntimePersistenceSnapshot {
    let now = Date(timeIntervalSince1970: 1)
    let executionId = "review-execution"
    var reviewPayload: JSONObject = [
      "gateId": .string(resultGateId),
      "decision": .string("accepted"),
      "reviewedProposalId": .string(proposal.proposalId),
      "reviewedProposalDigest": .string(proposal.proposalDigest),
      "reviewedBeforeBundleDigest": .string(proposal.beforeBundleDigest),
      "evidenceReferences": .array([.string("runtime:review")])
    ]
    if fabricatedResultId {
      reviewPayload["gateResultId"] = .string("fabricated-result")
    }
    let execution = WorkflowStepExecution(
      executionId: executionId,
      stepId: executionStepId,
      nodeId: "review-node",
      attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: [
          "loopGate": .object(["gateId": .string(resultGateId), "decision": .string("accepted")]),
          "workflowChangeReview": .object(reviewPayload)
        ],
        when: [:],
        acceptedAt: now
      ),
      createdAt: now,
      updatedAt: now
    )
    let gateResult = LoopGateResult(
      gateId: resultGateId,
      stepId: executionStepId,
      stepExecutionId: executionId,
      decision: .accepted,
      acceptedAt: now
    )
    let session = WorkflowSession(
      workflowId: workflow.workflowId,
      sessionId: "review-session",
      status: .completed,
      entryStepId: executionStepId,
      createdAt: now,
      updatedAt: now,
      executions: [execution]
    )
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "review-manifest",
      workflowId: workflow.workflowId,
      sessionId: session.sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: [gateResult],
      redaction: LoopRedactionSummary(policyName: "test", status: "verified"),
      createdAt: now,
      updatedAt: now
    )
    return WorkflowRuntimePersistenceSnapshot(
      session: session,
      loopEvidence: manifest,
      loopMetadata: workflow.loop
    )
  }
}
