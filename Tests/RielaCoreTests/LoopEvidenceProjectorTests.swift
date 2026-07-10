import XCTest
@testable import RielaCore

final class LoopEvidenceProjectorTests: XCTestCase {
  func testProjectorReturnsNilForLegacyWorkflowWithoutLoopMetadata() throws {
    let manifest = try DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(loop: nil),
        session: session(executions: []),
        workflowSource: workflowSource()
      )
    )

    XCTAssertNil(manifest)
  }

  func testProjectorCanExplicitlyProjectRuntimeEvidenceWithoutLoopMetadata() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "worker-exec-1",
      stepId: "review",
      nodeId: "review-node",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: ["status": .string("done")],
        when: ["always": true],
        acceptedAt: date
      ),
      adapterOutput: WorkflowAdapterOutputMetadata(
        provider: "codex-agent",
        model: "gpt-5.5",
        completionPassed: true,
        when: ["always": true]
      ),
      createdAt: date,
      updatedAt: date
    )

    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(loop: nil),
        session: session(executions: [execution]),
        workflowSource: workflowSource(),
        includeWorkflowWithoutLoopMetadata: true
      )
    ))

    XCTAssertEqual(manifest.workflowId, "wf")
    XCTAssertEqual(manifest.sessionId, "session-1")
    XCTAssertEqual(manifest.steps.count, 1)
    XCTAssertEqual(manifest.steps.first?.stepExecutionId, "worker-exec-1")
    XCTAssertEqual(manifest.steps.first?.acceptedOutputSummary, #"{"status":"done"}"#)
    XCTAssertEqual(manifest.gates, [])
    XCTAssertEqual(manifest.redaction.policyName, "not-configured")
    XCTAssertTrue(manifest.redaction.warnings.contains(
      "workflow.loop metadata is absent; explicit projection includes runtime step evidence only"
    ))
  }

  func testProjectorPreservesRecoveryLineageAndFailureEvidenceRefs() throws {
    let recovery = LoopRecoveryLineage(
      entryMode: .rerun,
      sourceSessionId: "source-session",
      sourceStepId: "review",
      sourceStepExecutionId: "review-exec-0",
      parentSessionId: "source-session",
      childSessionIds: ["session-1"],
      reason: "rerun from review",
      inputReusePolicy: "source-session",
      preservedFailureEvidenceRefs: ["tmp/failure.json"]
    )

    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(),
        session: session(executions: []),
        workflowSource: workflowSource(),
        recovery: recovery
      )
    ))

    XCTAssertEqual(manifest.recovery, recovery)
    XCTAssertEqual(manifest.recovery?.preservedFailureEvidenceRefs, ["tmp/failure.json"])
  }

  func testProjectorBuildsManifestAndExtractsAcceptedGateResult() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "review-exec-1",
      stepId: "review",
      nodeId: "review-node",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: [
          "loopGate": .object([
            "gateId": .string("implementation-review"),
            "stepId": .string("review"),
            "decision": .string("accepted"),
            "severityCounts": .object(["high": .number(0), "medium": .number(0), "low": .number(1)]),
            "evidenceRefs": .array([.string("tmp/review.json")]),
            "diagnostics": .array([.string("accepted")])
          ])
        ],
        when: ["always": true],
        acceptedAt: date
      ),
      adapterOutput: WorkflowAdapterOutputMetadata(
        provider: "codex-agent",
        model: "gpt-5.5",
        completionPassed: true,
        when: ["always": true]
      ),
      createdAt: date,
      updatedAt: date
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-1",
      workflowExecutionId: "session-1",
      fromStepId: "review",
      toStepId: nil,
      sourceStepExecutionId: "review-exec-1",
      payload: ["status": .string("accepted")],
      artifactRefs: ["tmp/review.json"],
      createdOrder: 1,
      createdAt: date
    )

    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(),
        session: session(executions: [execution]),
        workflowMessages: [message],
        workflowSource: workflowSource(),
        policy: LoopPolicyEvidence(
          declared: LoopPolicyDeclaration(mutation: LoopMutationPolicyDeclaration(commit: "deny", push: "deny"))
        )
      )
    ))

    XCTAssertEqual(manifest.manifestId, "loop-evidence-session-1")
    XCTAssertEqual(manifest.workflowId, "wf")
    XCTAssertEqual(manifest.sessionId, "session-1")
    XCTAssertEqual(manifest.steps.first?.backend, "codex-agent")
    XCTAssertEqual(manifest.steps.first?.model, "gpt-5.5")
    XCTAssertEqual(manifest.steps.first?.artifactRefs, ["tmp/review.json"])
    XCTAssertEqual(manifest.steps.first?.evidenceTags, ["review"])
    XCTAssertEqual(manifest.gates.first?.decision, .accepted)
    XCTAssertEqual(manifest.gates.first?.acceptedAt, date)
    XCTAssertEqual(manifest.gates.first?.severityCounts.high, 0)
    XCTAssertEqual(manifest.artifacts.first?.path, "tmp/review.json")
    XCTAssertEqual(manifest.policy.declared?.mutation?.commit, "deny")
  }

  func testProjectorEmitsRejectedGateWhenRequiredGateIsMissing() throws {
    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(),
        session: session(executions: []),
        workflowSource: workflowSource()
      )
    ))

    XCTAssertEqual(manifest.gates.count, 1)
    XCTAssertEqual(manifest.gates.first?.gateId, "implementation-review")
    XCTAssertEqual(manifest.gates.first?.decision, .rejected)
    XCTAssertEqual(manifest.gates.first?.severityCounts.high, 1)
    XCTAssertEqual(manifest.gates.first?.blockingFindings.first?.severity, "high")
  }

  func testProjectorRejectsAcceptedRequiredGateWhenHighFindingsExceedPolicy() throws {
    let manifest = try projectManifest(gatePayload: [
      "decision": .string("accepted"),
      "severityCounts": .object(["high": .integer(1), "medium": .integer(0)])
    ])

    let gate = try XCTUnwrap(manifest.gates.first)
    XCTAssertEqual(gate.decision, .rejected)
    XCTAssertNil(gate.acceptedAt)
    XCTAssertEqual(gate.severityCounts.high, 1)
    XCTAssertEqual(gate.blockingFindings.map(\.id), ["gate-policy-implementation-review-max-high-findings"])
    XCTAssertEqual(gate.blockingFindings.first?.severity, "high")
    XCTAssertTrue(gate.diagnostics.contains("required loop gate 'implementation-review' has 1 high findings; maximum is 0"))
  }

  func testProjectorRejectsAcceptedRequiredGateWhenMediumFindingsExceedPolicy() throws {
    let manifest = try projectManifest(gatePayload: [
      "decision": .string("accepted"),
      "severityCounts": .object(["high": .number(0), "medium": .number(1)])
    ])

    let gate = try XCTUnwrap(manifest.gates.first)
    XCTAssertEqual(gate.decision, .rejected)
    XCTAssertNil(gate.acceptedAt)
    XCTAssertEqual(gate.severityCounts.medium, 1)
    XCTAssertEqual(gate.blockingFindings.map(\.id), ["gate-policy-implementation-review-max-medium-findings"])
    XCTAssertEqual(gate.blockingFindings.first?.severity, "medium")
  }

  func testProjectorPreservesNeedsWorkDecisionAndAddsPolicyDiagnosticForRequiredGate() throws {
    let manifest = try projectManifest(gatePayload: [
      "decision": .string("needs_work"),
      "severityCounts": .object(["high": .number(0), "medium": .number(0)])
    ])

    let gate = try XCTUnwrap(manifest.gates.first)
    XCTAssertEqual(gate.decision, .needsWork)
    XCTAssertNil(gate.acceptedAt)
    XCTAssertEqual(gate.blockingFindings.map(\.id), ["gate-policy-implementation-review-decision"])
    XCTAssertTrue(gate.diagnostics.contains(
      "required loop gate 'implementation-review' expected decision accepted but got needs_work"
    ))
  }

  func testProjectorUsesStepLoopGateIdWhenGatePayloadOmitsGateId() throws {
    let manifest = try projectManifest(gatePayload: [
      "decision": .string("accepted"),
      "severityCounts": .object(["high": .number(0), "medium": .number(0)])
    ])

    XCTAssertEqual(manifest.gates.first?.gateId, "implementation-review")
    XCTAssertEqual(manifest.gates.first?.decision, .accepted)
  }

  func testProjectorLeavesNonRequiredGatePayloadsBackwardCompatible() throws {
    let optionalLoop = WorkflowLoopMetadata(
      kind: "design-implement-review",
      required: true,
      gates: [
        LoopGateDeclaration(
          id: "implementation-review",
          stepId: "review",
          required: false,
          acceptWhen: LoopGateAcceptancePolicy(decision: .accepted, maxHighFindings: 0, maxMediumFindings: 0)
        )
      ]
    )
    let manifest = try projectManifest(
      workflow: workflow(loop: optionalLoop),
      gatePayload: [
        "decision": .string("accepted"),
        "severityCounts": .object(["high": .number(1), "medium": .number(1)])
      ]
    )

    let gate = try XCTUnwrap(manifest.gates.first)
    XCTAssertEqual(gate.decision, .accepted)
    XCTAssertEqual(gate.severityCounts.high, 1)
    XCTAssertEqual(gate.severityCounts.medium, 1)
    XCTAssertEqual(gate.blockingFindings, [])
  }

  func testProjectorRecordsWarnStallConvergenceEvidenceAndResidualRisk() throws {
    let convergenceLoop = WorkflowLoopMetadata(
      kind: "design-implement-review",
      required: false,
      convergence: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2, onStall: .warn),
      gates: [LoopGateDeclaration(id: "implementation-review", stepId: "review", required: false)]
    )
    let executions = [
      gateExecution(id: "review-exec-1", decision: "needs_work", findingId: "same"),
      gateExecution(id: "review-exec-2", decision: "needs_work", findingId: "same")
    ]

    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow(loop: convergenceLoop),
        session: session(executions: executions),
        workflowSource: workflowSource()
      )
    ))

    XCTAssertEqual(manifest.convergence?.gateVisitCounts, ["implementation-review": 2])
    XCTAssertEqual(manifest.convergence?.stallDetected, true)
    XCTAssertEqual(manifest.convergence?.stalledGateId, "implementation-review")
    XCTAssertEqual(manifest.convergence?.repeatedRounds, 2)
    XCTAssertEqual(manifest.convergence?.action, "warn")
    XCTAssertTrue(manifest.convergence?.diagnostics.first?.contains("id:same") == true)
    XCTAssertEqual(manifest.residualRisks.count, 1)
    XCTAssertEqual(manifest.residualRisks.first?.owner, "loop-convergence-guard")
    XCTAssertEqual(manifest.residualRisks.first?.accepted, true)
  }

  func testProjectorPreservesIdlessFindingForFallbackFingerprinting() throws {
    let manifest = try projectManifest(gatePayload: [
      "decision": .string("needs_work"),
      "blockingFindings": .array([
        .object([
          "severity": .string("high"),
          "filePath": .string("Sources/A.swift"),
          "message": .string("id-less finding")
        ])
      ])
    ])

    let finding = try XCTUnwrap(manifest.gates.first?.blockingFindings.first {
      $0.message == "id-less finding"
    })
    XCTAssertEqual(finding.id, "")
    XCTAssertEqual(finding.filePath, "Sources/A.swift")
    XCTAssertEqual(LoopFindingFingerprint.make(from: finding).key, "message:Sources/A.swift\u{0}id-less finding")
  }

  private func workflow(loop: WorkflowLoopMetadata? = loopMetadata()) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "wf",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review", nodeFile: "nodes/review.json")],
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review",
          role: .worker,
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review", evidenceTags: ["review"])
        )
      ],
      nodes: [],
      loop: loop
    )
  }

  private static func loopMetadata() -> WorkflowLoopMetadata {
    WorkflowLoopMetadata(
      kind: "design-implement-review",
      required: true,
      policies: LoopPolicyDeclaration(redaction: LoopRedactionPolicyDeclaration(secretPolicy: "redact-known-patterns")),
      gates: [
        LoopGateDeclaration(
          id: "implementation-review",
          stepId: "review",
          required: true,
          acceptWhen: LoopGateAcceptancePolicy(decision: .accepted, maxHighFindings: 0, maxMediumFindings: 0)
        )
      ]
    )
  }

  private func session(executions: [WorkflowStepExecution]) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowSession(
      workflowId: "wf",
      sessionId: "session-1",
      status: .completed,
      entryStepId: "review",
      createdAt: date,
      updatedAt: date,
      executions: executions
    )
  }

  private func workflowSource() -> LoopWorkflowSource {
    LoopWorkflowSource(scope: "project", kind: "workflow-directory", workflowDirectory: ".riela/workflows/wf", mutable: true)
  }

  private func gateExecution(id: String, decision: String, findingId: String) -> WorkflowStepExecution {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowStepExecution(
      executionId: id,
      stepId: "review",
      nodeId: "review-node",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: [
          "loopGate": .object([
            "gateId": .string("implementation-review"),
            "decision": .string(decision),
            "blockingFindings": .array([
              .object([
                "id": .string(findingId),
                "severity": .string("high"),
                "message": .string("same finding")
              ])
            ])
          ])
        ],
        when: ["always": true],
        acceptedAt: date
      ),
      createdAt: date,
      updatedAt: date
    )
  }

  private func projectManifest(
    workflow: WorkflowDefinition? = nil,
    gatePayload: JSONObject
  ) throws -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "review-exec-1",
      stepId: "review",
      nodeId: "review-node",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: ["loopGate": .object(gatePayload)],
        when: ["always": true],
        acceptedAt: date
      ),
      adapterOutput: WorkflowAdapterOutputMetadata(
        provider: "codex-agent",
        model: "gpt-5.5",
        completionPassed: true,
        when: ["always": true]
      ),
      createdAt: date,
      updatedAt: date
    )
    return try XCTUnwrap(DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: workflow ?? self.workflow(),
        session: session(executions: [execution]),
        workflowSource: workflowSource()
      )
    ))
  }
}
