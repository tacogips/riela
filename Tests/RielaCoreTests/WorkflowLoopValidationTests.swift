import XCTest
@testable import RielaCore

final class WorkflowLoopValidationTests: XCTestCase {
  func testValidationAcceptsAdditiveWorkflowAndStepLoopKeys() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "implement",
        "loop": {
          "kind": "design-implement-review",
          "required": true,
          "gates": [{
            "id": "implementation-review",
            "stepId": "review",
            "required": true,
            "acceptWhen": {
              "decision": "accepted",
              "maxHighFindings": 0,
              "maxMediumFindings": 0
            }
          }]
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
              "evidenceTags": ["changed-files"],
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
              "evidenceTags": ["verification"],
              "recordsVerification": true
            }
          }
        ]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.loop?.gates.first?.id, "implementation-review")
    XCTAssertEqual(result.workflow?.steps.last?.loop?.gateId, "implementation-review")
  }

  func testValidationStillRejectsUnrelatedUnknownStepKeys() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "implement",
        "nodes": [{ "id": "implement", "nodeFile": "nodes/implement.json" }],
        "steps": [{
          "id": "implement",
          "nodeId": "implement",
          "role": "worker",
          "unexpected": true
        }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].unexpected" && $0.message == "uses an unsupported step field"
    })
  }

  func testValidationRejectsInvalidLoopGateReferencesPoliciesAndPaths() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "implement",
        "loop": {
          "kind": "design-implement-review",
          "required": true,
          "evidence": { "artifactRootPolicy": "caller-owned" },
          "policies": {
            "mutation": {
              "allowedWriteRoots": ["Sources", "../Secrets"],
              "scratchRoot": "/tmp/riela",
              "commit": "always",
              "push": "maybe"
            },
            "process": {
              "nestedRiela": "inherit-command",
              "nestedCodex": "sometimes"
            },
            "network": { "mode": "online" }
          },
          "implementationPlan": {
            "required": true,
            "pathPattern": "../impl-plans/*.md"
          },
          "gates": [
            {
              "id": "",
              "stepId": "missing-review",
              "required": true,
              "acceptWhen": {
                "decision": "accepted",
                "maxHighFindings": -1,
                "maxMediumFindings": -2
              }
            },
            {
              "id": "implementation-review",
              "stepId": "",
              "required": true
            }
          ]
        },
        "nodes": [{ "id": "implement", "nodeFile": "nodes/implement.json" }],
        "steps": [{
          "id": "implement",
          "nodeId": "implement",
          "role": "worker",
          "loop": {
            "role": "gate",
            "gateId": "missing-gate"
          }
        }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)
    let errors = result.diagnostics.filter { $0.severity == .error }

    XCTAssertNil(result.workflow)
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.evidence.artifactRootPolicy" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.mutation.allowedWriteRoots[1]" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.mutation.scratchRoot" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.mutation.commit" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.mutation.push" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.process.nestedRiela" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.process.nestedCodex" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.policies.network.mode" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.implementationPlan.pathPattern" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.gates[0].id" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.gates[0].stepId" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.gates[0].acceptWhen.maxHighFindings" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.gates[0].acceptWhen.maxMediumFindings" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.gates[1].stepId" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.steps[0].loop.gateId" })
  }

  func testValidationRejectsDuplicateLoopGateIds() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "gates": [
            { "id": "implementation-review", "stepId": "review" },
            { "id": "implementation-review", "stepId": "review" }
          ]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains {
      $0.path == "workflow.loop.gates[1].id" &&
        $0.message == "must be unique across workflow.loop.gates[]"
    })
  }

  func testValidationAcceptsLoopConvergenceMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "required": false,
          "convergence": {
            "maxGateVisits": 6,
            "maxRepeatedFindingRounds": 2,
            "onStall": "warn"
          },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.loop?.convergence?.maxGateVisits, 6)
    XCTAssertEqual(result.workflow?.loop?.convergence?.maxRepeatedFindingRounds, 2)
    XCTAssertEqual(result.workflow?.loop?.convergence?.onStall, .warn)
  }

  func testValidationRejectsInvalidLoopConvergenceMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "required": true,
          "convergence": {
            "maxGateVisits": 0,
            "maxRepeatedFindingRounds": -1,
            "onStall": "warn"
          },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.convergence.maxGateVisits" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.convergence.maxRepeatedFindingRounds" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.convergence.onStall" })
  }

  func testValidationRejectsConvergenceWithoutBounds() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "convergence": {},
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.convergence" })
  }

  func testValidationAcceptsLoopBudgetMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "required": false,
          "budget": {
            "maxTotalTokens": 500000,
            "maxWallClockMs": 3600000,
            "maxSessionAttempts": 3,
            "onExceeded": "warn"
          },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.loop?.budget?.maxTotalTokens, 500_000)
    XCTAssertEqual(result.workflow?.loop?.budget?.maxWallClockMs, 3_600_000)
    XCTAssertEqual(result.workflow?.loop?.budget?.maxSessionAttempts, 3)
    XCTAssertEqual(result.workflow?.loop?.budget?.onExceeded, "warn")
  }

  func testValidationRejectsInvalidLoopBudgetMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "required": true,
          "budget": {
            "maxTotalTokens": 0,
            "maxWallClockMs": -5,
            "maxSessionAttempts": 0,
            "onExceeded": "warn"
          },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget.maxTotalTokens" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget.maxWallClockMs" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget.maxSessionAttempts" })
    // `warn` while required is invalid.
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget.onExceeded" })
  }

  func testValidationRejectsBudgetWithoutBoundsAndUnknownOnExceeded() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "budget": { "onExceeded": "explode" },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.budget.onExceeded" })
  }

  func testValidationAcceptsLoopConcurrencyMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "concurrency": { "maxActive": 1, "onBusy": "skip" },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.loop?.concurrency?.maxActive, 1)
    XCTAssertEqual(result.workflow?.loop?.concurrency?.onBusy, "skip")
  }

  func testValidationDefaultsLoopConcurrencyToSingleFail() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "concurrency": {},
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.loop?.concurrency?.maxActive, 1)
    XCTAssertEqual(result.workflow?.loop?.concurrency?.onBusy, "fail")
  }

  func testValidationRejectsInvalidLoopConcurrencyMetadata() throws {
    let data = Data("""
      {
        "workflowId": "loop-metadata",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "loop": {
          "concurrency": { "maxActive": 2, "onBusy": "queue" },
          "gates": [{ "id": "implementation-review", "stepId": "review" }]
        },
        "nodes": [{ "id": "review", "nodeFile": "nodes/review.json" }],
        "steps": [{ "id": "review", "nodeId": "review", "role": "worker" }]
      }
      """.utf8)

    let errors = validateAuthoredWorkflowData(data).diagnostics.filter { $0.severity == .error }

    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.concurrency.maxActive" })
    XCTAssertTrue(errors.contains { $0.path == "workflow.loop.concurrency.onBusy" })
  }
}
