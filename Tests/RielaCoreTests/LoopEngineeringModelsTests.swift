import XCTest
@testable import RielaCore

final class LoopEngineeringModelsTests: XCTestCase {
  func testLoopEvidenceManifestCodableRoundTrip() throws {
    let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-25T00:00:00Z"))
    let updatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-25T00:01:00Z"))
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "manifest-1",
      workflowId: "workflow-1",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(
        scope: "project",
        kind: "workflow-directory",
        workflowDirectory: ".riela/workflows/loop",
        mutable: true
      ),
      workflowDefinitionDigest: "sha256:workflow",
      variablesDigest: "sha256:variables",
      worktree: LoopWorktreeSummary(
        branch: "main",
        baseCommit: "base",
        headCommit: "head",
        dirtySummary: "2 modified",
        hadUnrelatedDirtyFiles: true
      ),
      policy: LoopPolicyEvidence(
        declared: LoopPolicyDeclaration(
          mutation: LoopMutationPolicyDeclaration(
            allowedWriteRoots: ["Sources", "Tests", "tmp"],
            scratchRoot: "tmp",
            commit: "deny",
            push: "deny"
          )
        ),
        decisions: [
          LoopPolicyDecision(id: "policy-1", policy: "mutation.commit", decision: "deny", reason: "declared")
        ]
      ),
      recovery: LoopRecoveryLineage(
        entryMode: .rerun,
        sourceSessionId: "session-0",
        sourceStepId: "implement",
        parentSessionId: "session-0",
        childSessionIds: ["session-1"],
        reason: "review requested changes",
        inputReusePolicy: "reuse-original-input",
        preservedFailureEvidenceRefs: ["artifact-0"]
      ),
      steps: [
        LoopStepEvidence(
          stepId: "implement",
          nodeId: "implement",
          stepExecutionId: "execution-1",
          backend: "codex-agent",
          model: "gpt-5.5",
          status: "succeeded",
          artifactRefs: ["artifact-1"],
          acceptedOutputSummary: "Implemented core models.",
          evidenceTags: ["implementation"]
        )
      ],
      gates: [
        sampleGateResult(acceptedAt: updatedAt)
      ],
      artifacts: [
        LoopArtifactRef(
          id: "artifact-1",
          path: "tmp/loop/work.json",
          kind: "json",
          digest: "sha256:artifact",
          producerStepExecutionId: "execution-1",
          redactionStatus: "clean",
          retentionClass: "runtime-owned"
        )
      ],
      changedFiles: [
        LoopChangedFile(
          path: "Sources/RielaCore/LoopEvidenceManifest.swift",
          changeKind: "added",
          producerStepExecutionId: "execution-1",
          digest: "sha256:file",
          withinAllowedMutationRoots: true
        )
      ],
      commands: [
        LoopCommandEvidence(
          id: "command-1",
          argvSummary: "swift test --filter LoopEngineeringModelsTests",
          argvRedactionStatus: "clean",
          workingDirectoryPolicyStatus: "allowed",
          exitCode: 0,
          durationMs: 1200,
          stdoutStoragePolicy: "summary-only",
          stderrStoragePolicy: "summary-only",
          evidenceRefs: ["artifact-1"]
        )
      ],
      verification: [
        LoopVerificationEvidence(
          id: "verification-1",
          commandRef: "command-1",
          evidenceRefs: ["artifact-1"],
          outcome: "passed",
          diagnosticSummary: "Focused tests passed."
        )
      ],
      implementationPlans: [
        LoopImplementationPlanRef(
          path: "impl-plans/active/loop-engineering-first-line-tool.md",
          status: "active",
          linkedSessionId: "session-1",
          completionChecks: ["models-added"],
          verificationRefs: ["verification-1"]
        )
      ],
      residualRisks: [
        LoopResidualRisk(
          severity: "low",
          message: "Runtime projector deferred.",
          evidenceRefs: ["artifact-1"],
          owner: "future-slice",
          accepted: true
        )
      ],
      redaction: LoopRedactionSummary(
        policyName: "redact-known-patterns",
        status: "clean",
        redactedFieldCount: 1,
        unredactedExceptions: ["digest"],
        warnings: ["raw stdout omitted"]
      ),
      createdAt: createdAt,
      updatedAt: updatedAt
    )

    let roundTripped = try roundTrip(manifest)

    XCTAssertEqual(roundTripped, manifest)
  }

  func testLoopRecoveryLineageCodableRoundTrip() throws {
    let lineage = LoopRecoveryLineage(
      entryMode: .resume,
      sourceSessionId: "session-1",
      sourceStepExecutionId: "execution-1",
      parentSessionId: "session-0",
      childSessionIds: ["session-2"],
      reason: "resume after interruption",
      inputReusePolicy: "preserve-session-input",
      preservedFailureEvidenceRefs: ["evidence-1"]
    )

    let roundTripped = try roundTrip(lineage)

    XCTAssertEqual(roundTripped, lineage)
  }

  func testLoopGateResultCodableRoundTrip() throws {
    let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-25T00:01:00Z"))
    let gateResult = sampleGateResult(acceptedAt: acceptedAt)

    let roundTripped = try roundTrip(gateResult)

    XCTAssertEqual(roundTripped, gateResult)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Value.self, from: encoder.encode(value))
  }
}

private func sampleGateResult(acceptedAt: Date) -> LoopGateResult {
  LoopGateResult(
    gateId: "implementation-review",
    stepId: "review",
    stepExecutionId: "execution-review",
    decision: .accepted,
    severityCounts: LoopFindingSeverityCounts(high: 0, medium: 0, low: 1, informational: 2),
    blockingFindings: [
      LoopBlockingFinding(
        id: "finding-1",
        severity: "low",
        filePath: "Sources/RielaCore/LoopGateResult.swift",
        line: 12,
        message: "Consider future projector coverage.",
        evidenceRefs: ["artifact-1"]
      )
    ],
    evidenceRefs: ["artifact-1"],
    rerunPolicy: "new-child-session",
    residualRisks: [
      LoopResidualRisk(severity: "low", message: "Runtime enforcement deferred.", accepted: true)
    ],
    acceptedAt: acceptedAt,
    diagnostics: ["accepted with no blocking findings"]
  )
}
