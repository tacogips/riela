import XCTest
@testable import RielaCore

final class WorkflowLoopMetadataCodableTests: XCTestCase {
  func testDecodesWorkflowWithoutLoopMetadata() throws {
    let data = Data("""
      {
        "workflowId": "sample",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "main",
        "nodes": [{ "id": "main", "nodeFile": "nodes/main.json" }],
        "steps": [{ "id": "main", "nodeId": "main", "role": "worker" }]
      }
      """.utf8)

    let authored = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)
    let result = validateAuthoredWorkflowJSON(authored)

    XCTAssertNil(authored.loop)
    XCTAssertNil(authored.steps?.first?.loop)
    XCTAssertNil(result.workflow?.loop)
    XCTAssertNil(result.workflow?.steps.first?.loop)
  }

  func testDecodesPartialLoopMetadataWithDefaults() throws {
    let data = Data("""
      {
        "workflowId": "sample",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "main",
        "loop": {
          "kind": "design-implement-review",
          "evidence": { "requiredSections": ["changedFiles"] }
        },
        "nodes": [{ "id": "main", "nodeFile": "nodes/main.json" }],
        "steps": [{
          "id": "main",
          "nodeId": "main",
          "role": "worker",
          "loop": { "role": "worker" }
        }]
      }
      """.utf8)

    let authored = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)
    let result = validateAuthoredWorkflowJSON(authored)
    let workflow = try XCTUnwrap(result.workflow)

    XCTAssertEqual(workflow.loop?.kind, "design-implement-review")
    XCTAssertEqual(workflow.loop?.required, false)
    XCTAssertEqual(workflow.loop?.evidence?.required, false)
    XCTAssertEqual(workflow.loop?.evidence?.requiredSections, ["changedFiles"])
    XCTAssertEqual(workflow.loop?.gates, [])
    XCTAssertEqual(workflow.steps.first?.loop?.role, "worker")
    XCTAssertEqual(workflow.steps.first?.loop?.evidenceTags, [])
  }

  func testDecodesFullLoopMetadataAndStepLoopMetadata() throws {
    let data = Data("""
      {
        "workflowId": "sample",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "implement",
        "loop": {
          "kind": "design-implement-review",
          "required": true,
          "description": "Plan, implement, review, and verify.",
          "evidence": {
            "required": true,
            "artifactRootPolicy": "runtime-owned",
            "requiredSections": ["changedFiles", "verification", "residualRisks"]
          },
          "policies": {
            "mutation": {
              "allowedWriteRoots": ["Sources", "Tests", "tmp"],
              "scratchRoot": "tmp",
              "commit": "deny",
              "push": "deny"
            },
            "process": {
              "nestedRiela": "deny",
              "nestedCodex": "deny",
              "allowedBackends": ["codex-agent"],
              "requiredWorkerModel": "gpt-5.5"
            },
            "network": { "mode": "inherit-command" },
            "redaction": {
              "secretPolicy": "redact-known-patterns",
              "storeRawStdout": false,
              "storeRawStderr": false
            }
          },
          "gates": [{
            "id": "implementation-review",
            "stepId": "review",
            "required": true,
            "acceptWhen": {
              "decision": "accepted",
              "maxHighFindings": 0,
              "maxMediumFindings": 0
            }
          }],
          "recovery": {
            "resume": "preserve-session",
            "rerun": "new-child-session",
            "retry": "same-communication-or-step-attempt"
          },
          "implementationPlan": {
            "required": true,
            "pathPattern": "impl-plans/active/*.md"
          },
          "selfEvolution": {
            "allowed": true,
            "defaultMode": "propose",
            "requiresReviewGate": true,
            "snapshotPolicy": "bundle-before-apply",
            "historyRoot": ".riela/workflow-history",
            "immutablePackageMutation": "deny",
            "requiredVerification": ["workflow validate", "mock-scenario"]
          }
        },
        "nodes": [
          { "id": "implement", "nodeFile": "nodes/implement.json" },
          { "id": "review", "nodeFile": "nodes/review.json" }
        ],
        "steps": [
          {
            "id": "implement",
            "nodeId": "implement",
            "role": "worker",
            "loop": {
              "role": "worker",
              "evidenceTags": ["implementation"],
              "recordsChangedFiles": true
            }
          },
          {
            "id": "review",
            "nodeId": "review",
            "role": "worker",
            "loop": {
              "role": "gate",
              "gateId": "implementation-review",
              "evidenceTags": ["review", "blocking-findings"],
              "recordsChangedFiles": false,
              "recordsVerification": true
            }
          }
        ]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)
    let workflow = try XCTUnwrap(result.workflow)
    let loop = try XCTUnwrap(workflow.loop)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertTrue(loop.required)
    XCTAssertEqual(loop.policies?.mutation?.allowedWriteRoots, ["Sources", "Tests", "tmp"])
    XCTAssertEqual(loop.policies?.process?.allowedBackends, ["codex-agent"])
    XCTAssertEqual(loop.gates.first?.acceptWhen.decision, .accepted)
    XCTAssertEqual(loop.gates.first?.acceptWhen.maxHighFindings, 0)
    XCTAssertEqual(loop.recovery?.rerun, "new-child-session")
    XCTAssertEqual(loop.implementationPlan?.pathPattern, "impl-plans/active/*.md")
    XCTAssertEqual(loop.selfEvolution?.defaultMode, .propose)
    XCTAssertEqual(loop.selfEvolution?.snapshotPolicy, .bundleBeforeApply)
    XCTAssertEqual(loop.selfEvolution?.requiredVerification, [.workflowValidate, .mockScenario])
    XCTAssertEqual(workflow.steps[1].loop?.gateId, "implementation-review")
    XCTAssertEqual(workflow.steps[1].loop?.recordsVerification, true)
  }
}
