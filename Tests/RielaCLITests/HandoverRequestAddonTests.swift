import RielaCore
import XCTest
@testable import RielaCLI

final class HandoverRequestAddonTests: XCTestCase {
  func testHandoverRequestRequiresTaskContext() async throws {
    do {
      _ = try await run(variables: [:], inputs: validInputs())
      XCTFail("expected a task-only policy rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("only inside a task attempt"))
    }
  }

  func testHandoverRequestReturnsValidatedEnvelope() async throws {
    let output = try await run(variables: ["rielaTask": .object(["taskId": .string("task-1")])], inputs: validInputs())
    XCTAssertEqual(output.payload["status"], .string("handover-requested"))
    XCTAssertEqual(output.payload["addon"], .string("riela/handover-request"))
    XCTAssertEqual(output.payload["stepId"], .string("request"))
    guard case let .object(envelope)? = output.payload["handover"] else {
      return XCTFail("handover envelope missing")
    }
    XCTAssertEqual(envelope["reason"], .string("userInputRequired"))
    XCTAssertEqual(envelope["resumeStepId"], .string("resume"))
  }

  func testHandoverRequestRequiresResumeStep() async throws {
    do {
      _ = try await run(
        variables: ["rielaTask": .object(["taskId": .string("task-1")])],
        inputs: ["reason": .string("userInputRequired"), "question": .object([
          "id": .string("q1"), "text": .string("Choose"), "options": .array([])
        ])]
      )
      XCTFail("expected missing resume step rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("resumeStepId is required"))
    }
  }

  private func validInputs() -> JSONObject {
    [
      "reason": .string("userInputRequired"),
      "question": .object([
        "id": .string("q1"), "text": .string("Choose"), "options": .array([])
      ]),
      "progressNote": .string("Waiting for an answer"),
      "resumeStepId": .string("resume")
    ]
  }

  private func run(variables: JSONObject, inputs: JSONObject) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "task-handover-addon-test", stepId: "request", nodeId: "request",
        addon: WorkflowNodeAddonRef(name: "riela/handover-request", version: "1"),
        variables: variables, resolvedInputPayload: inputs
      ),
      context: AdapterExecutionContext()
    )
  }
}
