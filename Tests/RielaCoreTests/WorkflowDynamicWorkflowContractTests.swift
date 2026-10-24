import XCTest
@testable import RielaCore

final class WorkflowDynamicWorkflowContractTests: XCTestCase {
  func testTransitionCodableSupportsOptionalDynamicWorkflow() throws {
    let legacy = try JSONDecoder().decode(WorkflowStepTransition.self, from: Data("""
      {"toStepId":"brain"}
      """.utf8))
    XCTAssertNil(legacy.dynamicWorkflow)

    let transition = WorkflowStepTransition(
      toStepId: "brain",
      dynamicWorkflow: WorkflowDynamicWorkflowTransition(maxIterations: 6)
    )
    let data = try JSONEncoder().encode(transition)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(object["dynamicWorkflow"])
    XCTAssertEqual(try JSONDecoder().decode(WorkflowStepTransition.self, from: data), transition)
  }

  func testAuthoredValidatorAcceptsDynamicSelfLoopAndWarnsAtLoopBoundary() throws {
    let accepted = validateAuthoredWorkflowJSON(try authoredWorkflow(maxLoopIterations: 6))
    XCTAssertNotNil(accepted.workflow)
    XCTAssertFalse(accepted.diagnostics.contains { $0.severity == .error })
    XCTAssertFalse(accepted.diagnostics.contains { $0.severity == .warning })

    let warning = validateAuthoredWorkflowJSON(try authoredWorkflow(maxLoopIterations: 3))
    XCTAssertNotNil(warning.workflow)
    XCTAssertEqual(warning.diagnostics.filter { $0.severity == .warning }.count, 1)
  }

  func testAuthoredValidatorRejectsDynamicWorkflowCombinationsAndPolicyErrors() throws {
    for field in ["toWorkflowId", "resumeStepId", "fanout"] {
      let fieldValue = field == "fanout"
        ? #"{"groupId":"g","itemsFrom":"/items","joinStepId":"brain"}"#
        : #""other""#
      let workflow = try authoredWorkflow(transitionExtra: "\"\(field)\":\(fieldValue)")
      let result = validateAuthoredWorkflowJSON(workflow)
      XCTAssertNil(result.workflow)
      XCTAssertTrue(result.diagnostics.contains { $0.message.contains("cannot be combined with \(field)") })
    }

    let invalidPolicy = validateAuthoredWorkflowJSON(try authoredWorkflow(dynamicMaxIterations: 0))
    XCTAssertTrue(invalidPolicy.diagnostics.contains { $0.path.hasSuffix("dynamicWorkflow.maxIterations") })

    let missingTarget = validateAuthoredWorkflowJSON(try authoredWorkflow(toStepId: "missing"))
    XCTAssertNil(missingTarget.workflow)
    XCTAssertTrue(missingTarget.diagnostics.contains { $0.path.hasSuffix("transitions[0].toStepId") })
  }

  func testWorkflowSessionGeneratedWorkflowRoundTripsAndLegacyDecodesNil() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let origin = WorkflowGeneratedWorkflowOrigin(
      iteration: 2,
      definitionDigest: "sha256:abc",
      sourceStepExecutionId: "brain-attempt-2-exec-4",
      rationale: "Run the generated analysis"
    )
    let session = WorkflowSession(
      workflowId: "generated",
      sessionId: "child-1",
      entryStepId: "step-1",
      createdAt: date,
      updatedAt: date,
      generatedWorkflow: origin
    )
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(session)
    XCTAssertEqual(try JSONDecoder().decode(WorkflowSession.self, from: encoded), session)

    var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyObject.removeValue(forKey: "generatedWorkflow")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    XCTAssertNil(try JSONDecoder().decode(WorkflowSession.self, from: legacyData).generatedWorkflow)
  }

  func testTemporaryWorkflowPayloadMapsNodeFileThenIdAndClearsInvalidPayloads() throws {
    let workflow = try authoredWorkflow(twoNodes: true)
    let byFile = AgentNodePayload(id: "file-payload", model: "model-a")
    let brainFallback = AgentNodePayload(id: "brain-fallback", model: "model-fallback")
    let byId = AgentNodePayload(id: "id-payload", model: "model-b")
    let materialized = materializeTemporaryWorkflowPayload(TemporaryWorkflowPayload(
      workflow: workflow,
      nodePayloads: ["nodes/brain.json": byFile, "brain": brainFallback, "other": byId]
    ))
    XCTAssertNotNil(materialized.validation.workflow)
    XCTAssertEqual(materialized.nodePayloads["brain"], byFile)
    XCTAssertEqual(materialized.nodePayloads["other"], byId)

    let invalid = materializeTemporaryWorkflowPayload(TemporaryWorkflowPayload(
      workflow: try authoredWorkflow(toStepId: "missing"),
      nodePayloads: ["nodes/brain.json": byFile]
    ))
    XCTAssertNil(invalid.validation.workflow)
    XCTAssertEqual(invalid.nodePayloads, [:])
  }

  func testTemporaryWorkflowPayloadKeepsRawAuthoredValidation() throws {
    let workflow = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: Data("""
      {
        "workflowId":"advisory-terminal",
        "defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":6},
        "entryStepId":"brain",
        "nodes":[{"id":"brain","nodeFile":"nodes/brain.json"}],
        "steps":[{"id":"brain","nodeId":"brain","failurePolicy":"advisory"}]
      }
      """.utf8))
    let payload = AgentNodePayload(id: "brain", model: "model-a")

    let materialized = materializeTemporaryWorkflowPayload(TemporaryWorkflowPayload(
      workflow: workflow,
      nodePayloads: ["nodes/brain.json": payload]
    ))

    XCTAssertNil(materialized.validation.workflow)
    XCTAssertTrue(materialized.validation.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy"
        && $0.message.contains("'advisory' requires at least one transition")
    })
    XCTAssertEqual(materialized.nodePayloads, [:])
  }

  private func authoredWorkflow(
    maxLoopIterations: Int = 6,
    dynamicMaxIterations: Int = 4,
    toStepId: String = "brain",
    transitionExtra: String? = nil,
    twoNodes: Bool = false
  ) throws -> AuthoredWorkflowJSON {
    let additionalNode = twoNodes ? #", {"id":"other","nodeFile":"nodes/other.json"}"# : ""
    let additionalStep = twoNodes ? #", {"id":"other","nodeId":"other"}"# : ""
    let extra = transitionExtra.map { ",\($0)" } ?? ""
    let data = Data("""
      {
        "workflowId":"parent",
        "defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":\(maxLoopIterations)},
        "entryStepId":"brain",
        "nodes":[{"id":"brain","nodeFile":"nodes/brain.json"}\(additionalNode)],
        "steps":[
          {"id":"brain","nodeId":"brain","transitions":[{"toStepId":"\(toStepId)","dynamicWorkflow":{"maxIterations":\(dynamicMaxIterations)}\(extra)}]}\(additionalStep)
        ]
      }
      """.utf8)
    return try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)
  }
}
