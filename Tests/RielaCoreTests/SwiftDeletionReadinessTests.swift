import Foundation
import XCTest
@testable import RielaCore

final class SwiftDeletionReadinessTests: XCTestCase {
  func testTrackedGateAllowsDeletionWithAcceptedReviewedTreeEvidence() throws {
    let data = try loadTrackedGateData()
    let gate = try JSONDecoder().decode(SwiftDeletionReadinessGate.self, from: data)
    let context = try trackedDeletionReadyContext(for: gate)
    let result = SwiftDeletionReadinessValidator().decodeAndValidate(data, context: context)

    XCTAssertTrue(result.valid, result.diagnostics.joined(separator: "\n"))
    XCTAssertTrue(result.allowsTypeScriptDeletion)
    XCTAssertTrue(gate.allowsTypeScriptDeletion)
    XCTAssertTrue(gate.typeScriptSourceDeletionReady)
    XCTAssertEqual(gate.migrationStatus, "deletion_ready")
    XCTAssertTrue(gate.productionSwiftPackagingReady)
    XCTAssertEqual(Set(gate.domains.compactMap(\.id)), Set(SwiftDeletionReadinessValidator.requiredDomainIds))
    XCTAssertEqual(result.blockingDomainIds, [])
    XCTAssertTrue(gate.domains.allSatisfy { $0.status == "passed" && $0.reviewDecision == "accepted" })
    XCTAssertTrue(gate.domains.allSatisfy { $0.verifiedBranch == context.currentBranch })
    XCTAssertTrue(gate.domains.allSatisfy { $0.verifiedCommit == context.evidenceBaseCommit })
    XCTAssertTrue(gate.domains.allSatisfy { $0.acceptedReviewWorkflowId == "codex-design-and-implement-review-loop" })
    XCTAssertTrue(gate.domains.allSatisfy { $0.acceptedReviewNodeId == "step7-adversarial-review" })
    XCTAssertTrue(gate.domains.allSatisfy { $0.acceptedReviewFindingSeverities == ["none"] })
    XCTAssertEqual(Set(gate.domains.flatMap { $0.evidenceArtifacts ?? [] }), Set(context.resolvedEvidenceArtifacts.keys))

    let evidence = try loadTrackedEvidence()
    let currentReviewedTreeState = try trackedReviewedTreeState(root: try repositoryRoot())
    XCTAssertEqual(evidence.reviewedTreeState.branch, context.currentBranch)
    XCTAssertEqual(evidence.reviewedTreeState.treeDigest, currentReviewedTreeState.treeDigest)
    XCTAssertEqual(evidence.reviewedTreeState.treeDigestAlgorithm, currentReviewedTreeState.treeDigestAlgorithm)
    XCTAssertEqual(Set(evidence.artifacts.map(\.nodeId)), ["step6-implement"])
    XCTAssertEqual(Set(evidence.artifacts.map(\.reviewedTreeDigest)), [evidence.reviewedTreeState.treeDigest])
  }

  func testTrackedGateRejectsManifestCommitThatDiffersFromEvidenceBaseCommit() throws {
    var gate = try deletionReadyGate()
    gate.domains = gate.domains.map { domain in
      var updated = domain
      updated.verifiedCommit = "stale-self-derived-commit"
      return updated
    }
    let data = try JSONEncoder().encode(gate)
    let context = try trackedDeletionReadyContext(for: gate)

    let result = SwiftDeletionReadinessValidator().decodeAndValidate(data, context: context)

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build verifiedCommit does not match evidence base commit"))
  }

  func testDecodeAndValidateRejectsMissingRequiredDomainField() throws {
    var gate = try loadTrackedGate()
    gate.domains[0].evidenceArtifacts = nil
    let data = try JSONEncoder().encode(gate)

    let result = SwiftDeletionReadinessValidator().decodeAndValidate(data)

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing evidenceArtifacts"))
  }

  func testDecodeAndValidateRejectsMissingLastVerifiedAtAndNotesFields() throws {
    let gate = try deletionReadyGate()
    let encoded = try JSONEncoder().encode(gate)
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var domains = try XCTUnwrap(raw["domains"] as? [[String: Any]])
    domains[0].removeValue(forKey: "lastVerifiedAt")
    domains[1].removeValue(forKey: "notes")
    raw["domains"] = domains
    let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])

    let result = SwiftDeletionReadinessValidator().decodeAndValidate(data)

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing lastVerifiedAt"))
    XCTAssertTrue(result.diagnostics.contains("domain cli missing notes"))
  }

  func testValidateRejectsMissingEvidenceMetadata() throws {
    var gate = try loadTrackedGate()
    gate.domains[0].evidenceCommands = nil
    gate.domains[1].evidenceArtifacts = nil

    let result = SwiftDeletionReadinessValidator().validate(gate)

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing evidenceCommands"))
    XCTAssertTrue(result.diagnostics.contains("domain cli missing evidenceArtifacts"))
  }

  func testValidateIgnoresShellCommentFragmentsWhenMatchingRequiredCommands() throws {
    var gate = try deletionReadyGate()
    guard let cliIndex = gate.domains.firstIndex(where: { $0.id == "cli" }) else {
      return XCTFail("expected cli domain")
    }
    gate.domains[cliIndex].evidenceCommands = [
      "swift test --filter OtherTests # WorkflowCommandTests",
    ]

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.diagnostics.contains("domain cli missing required evidence command matching swift + test + WorkflowCommand"))
  }

  func testValidateRejectsMissingAgentDomain() throws {
    var gate = try loadTrackedGate()
    gate.domains.removeAll { $0.id == "agent-cursor-cli" }

    let result = SwiftDeletionReadinessValidator().validate(gate)

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.blockingDomainIds.contains("agent-cursor-cli"))
    XCTAssertTrue(result.diagnostics.contains("required domain agent-cursor-cli is missing"))
  }

  func testValidateRejectsDuplicateDomainId() throws {
    var gate = try loadTrackedGate()
    gate.domains.append(try XCTUnwrap(gate.domains.first { $0.id == "cli" }))

    let result = SwiftDeletionReadinessValidator().validate(gate)

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.diagnostics.contains("domain cli is duplicated"))
  }

  func testValidateRejectsUnsafeDeletionReadyAggregate() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].status = "blocked"
    gate.domains[0].reviewDecision = "blocked"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("allowsTypeScriptDeletion cannot be true while required domains are blocked"))
    XCTAssertTrue(result.diagnostics.contains("typeScriptSourceDeletionReady cannot be true while required domains are blocked"))
  }

  func testValidateAllowsDeletionWhenHeadAdvancesButReviewedTreeDigestMatches() throws {
    let gate = try deletionReadyGate()
    let context = deletionReadyContext(
      for: gate,
      currentBranch: "main",
      currentCommit: "post-review-workflow-commit",
      evidenceBaseCommit: "current-commit"
    )

    let result = SwiftDeletionReadinessValidator().validate(gate, context: context)

    XCTAssertTrue(result.valid, result.diagnostics.joined(separator: "\n"))
    XCTAssertTrue(result.allowsTypeScriptDeletion)
    XCTAssertEqual(result.blockingDomainIds, [])
  }

  func testValidateRejectsDeletionReadyClaimWithoutCurrentAcceptedEvidence() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].verifiedCommit = "stale-commit"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build verifiedCommit does not match evidence base commit"))
  }

  func testValidateRejectsDeletionReadyClaimWithHighOrMidReviewFinding() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].acceptedReviewFindingSeverities = ["low", "Mid"]

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build accepted review includes blocking finding severity mid"))
  }

  func testValidateRejectsDeletionReadyClaimWithoutReviewSeverityEvidence() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].acceptedReviewFindingSeverities = nil

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing acceptedReviewFindingSeverities"))
  }

  func testValidateRejectsDeletionReadyClaimWithEmptyReviewSeverityEvidence() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].acceptedReviewFindingSeverities = []

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(
      result.diagnostics.contains(
        "domain package-build acceptedReviewFindingSeverities must include explicit non-blocking severity evidence"
      )
    )
  }

  func testValidateRejectsDeletionReadyClaimWithBlockingOrInvalidReviewSeverity() throws {
    let cases = [
      ("medium", "domain package-build accepted review includes blocking finding severity medium"),
      ("critical", "domain package-build accepted review includes blocking finding severity critical"),
      ("blocker", "domain package-build accepted review includes blocking finding severity blocker"),
      ("unknown", "domain package-build accepted review includes unknown finding severity unknown"),
      ("", "domain package-build accepted review includes blank finding severity"),
    ]

    for (severity, expectedDiagnostic) in cases {
      var gate = try deletionReadyGate()
      gate.domains[0].acceptedReviewFindingSeverities = [severity]

      let result = SwiftDeletionReadinessValidator().validate(
        gate,
        context: deletionReadyContext(for: gate)
      )

      XCTAssertFalse(result.valid, "severity: \(severity)")
      XCTAssertFalse(result.allowsTypeScriptDeletion, "severity: \(severity)")
      XCTAssertTrue(result.diagnostics.contains(expectedDiagnostic), "severity: \(severity)")
    }
  }

  func testValidateRejectsDeletionReadyClaimWithPlaceholderEvidenceCommand() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].evidenceCommands = ["true"]

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build evidenceCommands contains placeholder command true"))
  }

  func testValidateRejectsDeletionReadyClaimWithSourceOnlyEvidenceArtifact() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].evidenceArtifacts = ["Sources"]

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build evidenceArtifacts contains non-durable reference Sources"))
  }

  func testValidateRejectsDeletionReadyClaimWithMalformedLastVerifiedAt() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].lastVerifiedAt = "not-a-date"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build lastVerifiedAt must be ISO-8601"))
  }

  func testValidateRejectsDeletionReadyClaimWithUnresolvedEvidenceArtifact() throws {
    var gate = try deletionReadyGate()
    let context = deletionReadyContext(for: gate)
    gate.domains[0].evidenceArtifacts = ["verification-result:fake/package-build"]

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: context
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(
      result.diagnostics.contains(
        "domain package-build evidenceArtifact verification-result:fake/package-build is not resolved"
      )
    )
  }

  func testValidateRejectsDeletionReadyClaimWithFailedCommandEvidence() throws {
    let gate = try deletionReadyGate()
    var context = deletionReadyContext(for: gate)
    let artifact = try XCTUnwrap(gate.domains[0].evidenceArtifacts?.first)
    context.resolvedEvidenceArtifacts[artifact]?.exitCode = 1

    let result = SwiftDeletionReadinessValidator().validate(gate, context: context)

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build evidenceArtifact \(artifact) command exitCode is not 0"))
  }

  func testValidateRejectsDeletionReadyClaimWithIncompleteMigrationStatus() throws {
    var gate = try deletionReadyGate()
    gate.migrationStatus = "incomplete"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("migrationStatus must be deletion_ready when TypeScript deletion is accepted"))
  }

  func testValidateRejectsDeletionReadyClaimWithUnexpectedReviewWorkflow() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].acceptedReviewWorkflowId = "manual"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(
      result.diagnostics.contains("domain package-build acceptedReviewWorkflowId does not match expected review workflow")
    )
  }

  func testValidateRejectsDeletionReadyClaimWithUnexpectedReviewNode() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].acceptedReviewNodeId = "step1"

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build acceptedReviewNodeId does not match expected review node"))
  }

  func testValidateRejectsDeletionReadyClaimWithUnexpectedEvidenceExecutionNode() throws {
    let gate = try deletionReadyGate()
    var context = deletionReadyContext(for: gate)
    let artifact = try XCTUnwrap(gate.domains[0].evidenceArtifacts?.first)
    context.resolvedEvidenceArtifacts[artifact]?.nodeId = "step7-adversarial-review"

    let result = SwiftDeletionReadinessValidator().validate(gate, context: context)

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(
      result.diagnostics.contains(
        "domain package-build evidenceArtifact \(artifact) nodeId does not match expected evidence execution node"
      )
    )
  }

  func testValidateDoesNotAllowDeletionWhenDuplicateDomainInvalidatesReadyGate() throws {
    var gate = try deletionReadyGate()
    gate.domains.append(try XCTUnwrap(gate.domains.first { $0.id == "cli" }))

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain cli is duplicated"))
  }

  func testDecodeAndValidateDoesNotAllowDeletionWhenRequiredStructuralFieldIsMissing() throws {
    let gate = try deletionReadyGate()
    var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gate)) as? [String: Any]
    var domains = try XCTUnwrap(raw?["domains"] as? [[String: Any]])
    domains[0].removeValue(forKey: "notes")
    raw?["domains"] = domains
    let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(raw), options: [.sortedKeys])

    let result = SwiftDeletionReadinessValidator().decodeAndValidate(
      data,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing notes"))
  }

  func testValidateRejectsDeletionReadyClaimWhenEvidenceCommandHasNoResolvedArtifact() throws {
    var gate = try deletionReadyGate()
    gate.domains[0].evidenceCommands = [
      "swift build",
      "swift test --filter RielaServerTests",
    ]
    gate.domains[0].evidenceArtifacts = ["verification-result:swift-deletion-readiness/package-build-0"]
    let context = deletionReadyContext(for: gate)

    let result = SwiftDeletionReadinessValidator().validate(gate, context: context)

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(
      result.diagnostics.contains(
        "domain package-build evidenceCommand swift test --filter RielaServerTests has no resolved successful evidenceArtifact"
      )
    )
  }

  func testValidateRejectsDeletionReadyClaimWithValidatorOnlyCommands() throws {
    var gate = try deletionReadyGate()
    gate.domains = gate.domains.map { domain in
      var updated = domain
      updated.evidenceCommands = ["swift test --filter SwiftDeletionReadinessTests"]
      updated.evidenceArtifacts = ["verification-result:swift-deletion-readiness/\(updated.id ?? "domain")-validator-only"]
      return updated
    }

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertFalse(result.valid)
    XCTAssertFalse(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.blockingDomainIds.contains("package-build"))
    XCTAssertTrue(result.blockingDomainIds.contains("agent-codex"))
    XCTAssertTrue(result.diagnostics.contains("domain package-build missing required evidence command matching swift + build"))
    XCTAssertTrue(result.diagnostics.contains("domain agent-codex missing required evidence command matching swift + test + CodexAgent"))
  }

  func testValidateAllowsDeletionOnlyWhenEveryDomainHasAcceptedEvidence() throws {
    let gate = try deletionReadyGate()

    let result = SwiftDeletionReadinessValidator().validate(
      gate,
      context: deletionReadyContext(for: gate)
    )

    XCTAssertTrue(result.valid, result.diagnostics.joined(separator: "\n"))
    XCTAssertTrue(result.allowsTypeScriptDeletion)
    XCTAssertTrue(result.blockingDomainIds.isEmpty)
  }

  private func deletionReadyGate() throws -> SwiftDeletionReadinessGate {
    var gate = try loadTrackedGate()
    gate.migrationStatus = "deletion_ready"
    gate.allowsTypeScriptDeletion = true
    gate.typeScriptSourceDeletionReady = true
    gate.domains = try gate.domains.map { domain in
      var updated = domain
      let domainId = try XCTUnwrap(updated.id)
      let commands = deletionReadyEvidenceCommands(for: domainId)
      updated.status = "passed"
      updated.reviewDecision = "accepted"
      updated.lastVerifiedAt = "2026-06-16T00:00:00Z"
      updated.evidenceCommands = commands
      updated.evidenceArtifacts = commands.indices.map { index in
        "verification-result:swift-deletion-readiness/\(domainId)-\(index)"
      }
      updated.verifiedBranch = "main"
      updated.verifiedCommit = "current-commit"
      updated.acceptedReviewWorkflowId = "codex-design-and-implement-review-loop"
      updated.acceptedReviewNodeId = "step7-adversarial-review"
      updated.acceptedReviewFindingSeverities = ["low"]
      return updated
    }
    return gate
  }

  private func deletionReadyEvidenceCommands(for domainId: String) -> [String] {
    switch domainId {
    case "package-build":
      return ["swift build"]
    case "cli":
      return ["swift test --filter WorkflowCommandTests"]
    case "server":
      return ["swift test --filter RielaServerTests"]
    case "graphql":
      return ["swift test --filter RielaGraphQLTests"]
    case "event":
      return ["swift test --filter RielaEventsTests"]
    case "workflow-package":
      return ["swift test --filter WorkflowPackage"]
    case "persistence":
      return ["swift test --filter Persistence"]
    case "release":
      return [
        "scripts/build-homebrew-release.sh --dry-run darwin-arm64",
        "scripts/render-homebrew-formula.sh 0.0.0 Formula/riela.rb",
      ]
    case "documentation":
      return [
        "rg -n \"swift-deletion-readiness\" design-docs",
        "rg -n \"TypeScript deletion\" design-docs",
      ]
    case "test":
      return ["swift test"]
    case "agent-codex":
      return ["swift test --filter CodexAgent"]
    case "agent-claude-code":
      return ["swift test --filter Claude"]
    case "agent-cursor-cli":
      return ["swift test --filter CursorCLIAgent"]
    default:
      return ["swift test"]
    }
  }

  private func deletionReadyContext(
    for gate: SwiftDeletionReadinessGate,
    currentBranch: String = "main",
    currentCommit: String = "current-commit",
    evidenceBaseCommit: String? = nil
  ) -> SwiftDeletionReadinessValidationContext {
    // Unit fixtures synthesize evidence to isolate validator rules; tracked gate
    // coverage loads packaging/swift-deletion-readiness-evidence.json instead.
    let resolvedEvidenceBaseCommit = evidenceBaseCommit ?? currentCommit
    var resolvedEvidenceArtifacts: [String: SwiftDeletionReadinessEvidenceArtifact] = [:]
    for domain in gate.domains {
      guard
        let domainId = domain.id,
        let commands = domain.evidenceCommands,
        let artifacts = domain.evidenceArtifacts
      else {
        continue
      }
      for (artifact, command) in zip(artifacts, commands) {
        resolvedEvidenceArtifacts[artifact] = SwiftDeletionReadinessEvidenceArtifact(
          domainId: domainId,
          command: command,
          exitCode: 0,
          branch: currentBranch,
          commit: resolvedEvidenceBaseCommit,
          workflowId: "codex-design-and-implement-review-loop",
          nodeId: "step6-implement",
          reviewedTreeDigest: "fixture-reviewed-tree-digest"
        )
      }
    }
    return SwiftDeletionReadinessValidationContext(
      currentBranch: currentBranch,
      currentCommit: currentCommit,
      evidenceBaseCommit: resolvedEvidenceBaseCommit,
      currentReviewedTreeDigest: "fixture-reviewed-tree-digest",
      resolvedEvidenceArtifacts: resolvedEvidenceArtifacts
    )
  }

  private struct TrackedDeletionReadinessEvidence: Decodable {
    var reviewedTreeState: TrackedDeletionReadinessReviewedTreeState
    var artifacts: [TrackedDeletionReadinessArtifact]
  }

  private struct TrackedDeletionReadinessReviewedTreeState: Decodable, Equatable {
    var branch: String
    var baseCommit: String
    var treeDigestAlgorithm: String
    var treeDigest: String
    var excludedPaths: [String]
  }

  private struct TrackedDeletionReadinessArtifact: Decodable {
    var artifact: String
    var domainId: String
    var command: String
    var exitCode: Int
    var branch: String
    var commit: String
    var workflowId: String
    var nodeId: String
    var reviewedTreeDigest: String
  }

  private func trackedDeletionReadyContext(
    for gate: SwiftDeletionReadinessGate
  ) throws -> SwiftDeletionReadinessValidationContext {
    let root = try repositoryRoot()
    let evidence = try loadTrackedEvidence()
    var resolvedEvidenceArtifacts: [String: SwiftDeletionReadinessEvidenceArtifact] = [:]
    for artifact in evidence.artifacts {
      resolvedEvidenceArtifacts[artifact.artifact] = SwiftDeletionReadinessEvidenceArtifact(
        domainId: artifact.domainId,
        command: artifact.command,
        exitCode: artifact.exitCode,
        branch: artifact.branch,
        commit: artifact.commit,
        workflowId: artifact.workflowId,
        nodeId: artifact.nodeId,
        reviewedTreeDigest: artifact.reviewedTreeDigest
      )
    }
    return SwiftDeletionReadinessValidationContext(
      currentBranch: try runGit(["rev-parse", "--abbrev-ref", "HEAD"], root: root),
      currentCommit: try runGit(["rev-parse", "HEAD"], root: root),
      evidenceBaseCommit: evidence.reviewedTreeState.baseCommit,
      currentReviewedTreeDigest: try trackedReviewedTreeState(root: root).treeDigest,
      resolvedEvidenceArtifacts: resolvedEvidenceArtifacts
    )
  }

  private func loadTrackedEvidence() throws -> TrackedDeletionReadinessEvidence {
    let evidenceURL = try repositoryRoot()
      .appendingPathComponent("packaging/swift-deletion-readiness-evidence.json")
    return try JSONDecoder().decode(
      TrackedDeletionReadinessEvidence.self,
      from: Data(contentsOf: evidenceURL)
    )
  }

  private func trackedReviewedTreeState(root: URL) throws -> TrackedDeletionReadinessReviewedTreeState {
    let excludedPaths = ["packaging/swift-deletion-readiness-evidence.json"]
    let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], root: root)
    let baseCommit = try runGit(["rev-parse", "HEAD"], root: root)
    let pathOutput = try runGit(["ls-files", "--cached", "--others", "--exclude-standard"], root: root)
    let paths = pathOutput.split(separator: "\n")
      .map(String.init)
      .filter { !excludedPaths.contains($0) }
      .sorted()

    var digestInput = Data()
    digestInput.append("reviewed-tree-v1\n".data(using: .utf8)!)
    for path in paths {
      let url = root.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        continue
      }
      digestInput.append("path:\(path)\n".data(using: .utf8)!)
      let executable = FileManager.default.isExecutableFile(atPath: url.path) ? "true" : "false"
      digestInput.append("executable:\(executable)\n".data(using: .utf8)!)
      digestInput.append(try Data(contentsOf: url))
      digestInput.append("\n".data(using: .utf8)!)
    }

    return TrackedDeletionReadinessReviewedTreeState(
      branch: branch,
      baseCommit: baseCommit,
      treeDigestAlgorithm: "sha256:reviewed-tree-v1-path-executable-content-excluding-evidence-manifest",
      treeDigest: try sha256Hex(digestInput, root: root),
      excludedPaths: excludedPaths
    )
  }

  private func runGit(_ arguments: [String], root: URL) throws -> String {
    let data = try runCommandData(["git"] + arguments, root: root)
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runCommandData(_ arguments: [String], root: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = root

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, stderr)
    return stdout
  }

  private func sha256Hex(_ data: Data, root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["shasum", "-a", "256"]
    process.currentDirectoryURL = root

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    try process.run()
    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderr)
    return stdout.split(separator: " ").first.map(String.init) ?? ""
  }

  private func loadTrackedGate() throws -> SwiftDeletionReadinessGate {
    try JSONDecoder().decode(SwiftDeletionReadinessGate.self, from: loadTrackedGateData())
  }

  private func loadTrackedGateData() throws -> Data {
    let url = try repositoryRoot()
      .appendingPathComponent("packaging/swift-deletion-readiness.json")
    return try Data(contentsOf: url)
  }

  private func rawTrackedGateObject() throws -> [String: Any] {
    let raw = try JSONSerialization.jsonObject(with: loadTrackedGateData())
    return try XCTUnwrap(raw as? [String: Any])
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(domain: "SwiftDeletionReadinessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"])
  }
}
