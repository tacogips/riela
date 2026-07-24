import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

func applyReviewedSelfImprove(
  app: RielaCLIApplication,
  workingDirectory: URL
) async throws -> WorkflowSelfImproveCommandResult {
  try configurePackageLifecycleReviewGate(workingDirectory: workingDirectory)
  // Self-improve apply now requires a mutable registry origin; register the
  // created project workflow as a mutable copy under an isolated home and
  // apply against that origin. The immutable project bundle stays untouched.
  let home = workingDirectory.appendingPathComponent("self-improve-home", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  let environment = ["HOME": home.path]
  let registerResponse = await app.run([
    "workflow", "register",
    workingDirectory.appendingPathComponent(".riela/workflows/created-flow").path,
    "--mutable",
    "--working-dir", workingDirectory.path,
    "--output", "json"
  ], environment: environment)
  XCTAssertEqual(registerResponse.exitCode, .success, registerResponse.stderr)
  let proposalResponse = await app.run([
    "workflow", "self-improve", "created-flow",
    "--scope", "user",
    "--working-dir", workingDirectory.path,
    "--dry-run",
    "--output", "json"
  ], environment: environment)
  XCTAssertEqual(proposalResponse.exitCode, .success, proposalResponse.stderr)
  let proposalResult = try JSONDecoder().decode(
    WorkflowSelfImproveCommandResult.self,
    from: Data(proposalResponse.stdout.utf8)
  )
  let (bundle, target, historyRoot) = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
    let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: "created-flow",
      scope: .user,
      workingDirectory: workingDirectory.path
    ))
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: workingDirectory
    )
    return (bundle, target, historyRoot)
  }
  let proposalId = try XCTUnwrap(proposalResult.proposalId)
  let proposalDigest = try XCTUnwrap(proposalResult.proposalDigest)
  let store = WorkflowChangeSetStore(root: historyRoot)
  let proposal = try store.loadProposal(proposalId, expectedIdentity: target)
  let gate = try WorkflowReviewGatePolicy.requiredGate(in: bundle.workflow)
  let gateResult = LoopGateResult(
    gateId: gate.id,
    stepId: gate.stepId,
    stepExecutionId: "review-exec",
    decision: .accepted
  )
  let gateResultId = try WorkflowRuntimeGateEvidenceStore.resultId(stepExecutionId: gateResult.stepExecutionId)
  try WorkflowRuntimeGateEvidenceStore(root: historyRoot).publish(WorkflowRuntimeGateEvidence(
    resultId: gateResultId,
    workflowId: bundle.workflow.workflowId,
    sessionId: "package-lifecycle-review-session",
    result: gateResult
  ))
  let changeSet = try store.finalize(
    proposalId: proposalId,
    expectedIdentity: target,
    review: WorkflowChangeSetReviewEvidence(
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
  )
  let applyResponse = await app.run([
    "workflow", "self-improve", "created-flow",
    "--scope", "user",
    "--working-dir", workingDirectory.path,
    "--yes",
    "--change-set-id", changeSet.changeSetId,
    "--expected-digest", changeSet.finalizedDigest,
    "--output", "json"
  ], environment: environment)
  XCTAssertEqual(applyResponse.exitCode, .success, applyResponse.stderr)
  let mutableWorkflowURL = home.appendingPathComponent(
    ".riela/temporary-workflows/created-flow/workflow.json"
  )
  XCTAssertTrue(try String(contentsOf: mutableWorkflowURL).contains("self-improve-reviewed"))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(WorkflowSelfImproveCommandResult.self, from: Data(applyResponse.stdout.utf8))
}

private func configurePackageLifecycleReviewGate(workingDirectory: URL) throws {
  let url = workingDirectory.appendingPathComponent(".riela/workflows/created-flow/workflow.json")
  var workflow = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
  var steps = workflow["steps"] as? [[String: Any]] ?? []
  guard !steps.isEmpty, let stepId = steps[0]["id"] as? String else {
    throw CLIUsageError("package lifecycle fixture requires a workflow step")
  }
  steps[0]["loop"] = ["role": "gate", "gateId": "package-lifecycle-review"]
  workflow["steps"] = steps
  workflow["loop"] = [
    "required": true,
    "gates": [[
      "id": "package-lifecycle-review",
      "stepId": stepId,
      "required": true,
      "acceptWhen": ["decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0]
    ]],
    "selfEvolution": [
      "allowed": true,
      "defaultMode": "propose",
      "requiresReviewGate": true,
      "snapshotPolicy": "bundle-before-apply",
      "historyRoot": ".riela/workflow-history",
      "immutablePackageMutation": "deny",
      "requiredVerification": ["workflow validate"]
    ]
  ]
  try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
