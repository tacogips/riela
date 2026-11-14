import Foundation
import XCTest
@testable import RielaCore

final class WorkflowHistoryModelsTests: XCTestCase {
  func testCanonicalSnapshotRoundTripPreservesMillisecondsModesAndTypedProvenance() throws {
    let target = fixtureTarget()
    let file = WorkflowBundleSnapshotFile(
      relativePath: "workflow.json",
      contentDigest: WorkflowHistoryCanonicalCoding.sha256(Data("{}".utf8)),
      byteCount: 2,
      artifactKind: .workflowDefinition,
      executable: true
    )
    let digest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: [file])
    let manifest = WorkflowBundleSnapshotManifest(
      snapshotId: "snapshot-fixture",
      target: target,
      createdAt: Date(timeIntervalSince1970: 1_704_164_645.123),
      bundleDigest: digest,
      files: [file]
    )

    let bytes = try WorkflowHistoryCanonicalCoding.encode(manifest)
    XCTAssertEqual(try WorkflowHistoryCanonicalCoding.decode(WorkflowBundleSnapshotManifest.self, from: bytes), manifest)
    XCTAssertTrue(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("2024-01-02T03:04:05.123Z"))
    XCTAssertEqual(manifest.target.sourceKind, .authoredWorkflow)
    XCTAssertTrue(manifest.files[0].executable)
  }

  func testProposalAndFinalizedDigestsBindReviewAndRejectMutation() throws {
    let target = fixtureTarget()
    let content = Data("updated".utf8)
    let state = WorkflowFileState(
      contentDigest: WorkflowHistoryCanonicalCoding.sha256(content),
      byteCount: content.count,
      artifactKind: .workflowDefinition,
      executable: false
    )
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-fixture",
      sourceSessionId: "session-fixture",
      target: target,
      beforeBundleDigest: String(repeating: "1", count: 64),
      operations: [WorkflowFileOperation(relativePath: "workflow.json", kind: .create, before: nil, after: state)],
      expectedAfterBundleDigest: String(repeating: "2", count: 64),
      rationale: "fixture",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    try WorkflowHistoryCanonicalCoding.validate(proposal)
    let review = WorkflowChangeSetReviewEvidence(
      gateId: "gate",
      gateResultId: "gate-result",
      decision: .accepted,
      reviewedProposalId: proposal.proposalId,
      reviewedProposalDigest: proposal.proposalDigest,
      reviewedBeforeBundleDigest: proposal.beforeBundleDigest,
      reviewerStepId: "review",
      reviewerStepExecutionId: "review-exec",
      reviewedAt: Date(timeIntervalSince1970: 1)
    )
    var changeSet = WorkflowChangeSet(
      changeSetId: "change-set-fixture",
      proposal: proposal,
      review: review,
      finalizedAt: Date(timeIntervalSince1970: 2),
      finalizedDigest: String(repeating: "0", count: 64)
    )
    changeSet.finalizedDigest = try WorkflowHistoryCanonicalCoding.finalizedDigest(changeSet)
    try WorkflowHistoryCanonicalCoding.validate(changeSet)

    changeSet.review.reviewedProposalDigest = String(repeating: "f", count: 64)
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validate(changeSet))
  }

  func testValidationRejectsTraversalDuplicateOrderingAndUnsupportedSchema() throws {
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validateRelativePath("../workflow.json"))
    var manifest = WorkflowBundleSnapshotManifest(
      snapshotId: "snapshot-fixture",
      target: fixtureTarget(),
      createdAt: Date(timeIntervalSince1970: 0),
      bundleDigest: String(repeating: "0", count: 64),
      files: [],
      complete: true
    )
    manifest.schemaVersion = 2
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validate(manifest))

    let file = WorkflowBundleSnapshotFile(
      relativePath: "workflow.json",
      contentDigest: String(repeating: "0", count: 64),
      byteCount: 0,
      artifactKind: .workflowDefinition,
      executable: false
    )
    manifest.schemaVersion = 1
    manifest.files = [file, file]
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validate(manifest))

    var invalidIdentity = fixtureTarget()
    invalidIdentity.workflowDirectory = "/tmp/outside"
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validate(invalidIdentity))
  }

  func testLoopEvidenceDecodesWithoutWorkflowMutation() throws {
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "m",
      workflowId: "w",
      sessionId: "s",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow", mutable: true),
      policy: LoopPolicyEvidence(),
      redaction: LoopRedactionSummary(policyName: "default", status: "complete"),
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    let bytes = try JSONEncoder().encode(manifest)
    XCTAssertFalse(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("workflowMutation"))
    let decoded = try JSONDecoder().decode(LoopEvidenceManifest.self, from: bytes)
    XCTAssertNil(decoded.workflowMutation)
  }

  func testPinnedCanonicalBytesAndDigestAreIndependentFixtures() throws {
    let file = WorkflowBundleSnapshotFile(
      relativePath: "workflow.json",
      contentDigest: String(repeating: "a", count: 64),
      byteCount: 2,
      artifactKind: .workflowDefinition,
      executable: false
    )
    let expected = Data("""
    {"artifactKind":"workflow-definition","byteCount":2,"contentDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executable":false,"relativePath":"workflow.json"}
    """.utf8)
    XCTAssertEqual(try WorkflowHistoryCanonicalCoding.encode(file), expected)
    XCTAssertEqual(WorkflowHistoryCanonicalCoding.sha256(expected), "a829b74bb3ee96dbe69c8a2e32df7b874daa250ec6dfde49e822cf3195013edb")
  }

  func testCanonicalDecoderRejectsMissingRequiredFieldAndUnknownEnums() throws {
    let missingByteCount = Data("""
    {"artifactKind":"workflow-definition","contentDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executable":false,"relativePath":"workflow.json"}
    """.utf8)
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.decode(
      WorkflowBundleSnapshotFile.self,
      from: missingByteCount
    ))
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.decode(
      WorkflowArtifactKind.self,
      from: Data("\"future-artifact\"".utf8)
    ))
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.decode(
      WorkflowHistoryOutcome.self,
      from: Data("\"future-outcome\"".utf8)
    ))
  }

  func testUnicodeScalarKeyOrderIsPinned() throws {
    let value = ["😀": "emoji", "Ω": "omega", "a": "ascii"]
    XCTAssertEqual(
      try WorkflowHistoryCanonicalCoding.encode(value),
      Data("{\"a\":\"ascii\",\"Ω\":\"omega\",\"😀\":\"emoji\"}".utf8)
    )
  }

  func testDigestInputsExcludeOnlyTheirNamedDigestFieldAndSnapshotMetadata() throws {
    let target = fixtureTarget()
    let file = WorkflowBundleSnapshotFile(
      relativePath: "workflow.json", contentDigest: String(repeating: "a", count: 64),
      byteCount: 1, artifactKind: .workflowDefinition, executable: false
    )
    let digest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: [file])
    let first = WorkflowBundleSnapshotManifest(
      snapshotId: "snapshot-one", target: target, createdAt: Date(timeIntervalSince1970: 1),
      bundleDigest: digest, files: [file]
    )
    let second = WorkflowBundleSnapshotManifest(
      snapshotId: "snapshot-two", target: target, createdAt: Date(timeIntervalSince1970: 2),
      bundleDigest: digest, files: [file]
    )
    XCTAssertEqual(first.bundleDigest, second.bundleDigest)
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-fixture", sourceSessionId: "session-fixture", target: target,
      beforeBundleDigest: digest, operations: [], expectedAfterBundleDigest: digest,
      rationale: "fixture", createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    let firstProposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    proposal.proposalDigest = String(repeating: "f", count: 64)
    XCTAssertEqual(try WorkflowHistoryCanonicalCoding.proposalDigest(proposal), firstProposalDigest)
  }

  private func fixtureTarget() -> WorkflowBundleIdentity {
    WorkflowBundleIdentity(
      workflowId: "fixture",
      sourceScope: .project,
      sourceKind: .authoredWorkflow,
      workflowDirectory: "/tmp/fixture",
      ownershipRoot: "/tmp/fixture",
      sourceMutable: true
    )
  }
}
