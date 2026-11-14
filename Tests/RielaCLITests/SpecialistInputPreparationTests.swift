import Foundation
import XCTest
import RielaCore
import RielaWorkflowRegistry
@testable import RielaCLI

final class SpecialistInputPreparationTests: XCTestCase {
  func testInvalidPreparedInputIsRepairedWithoutExposingDefaultValues() async throws {
    let adapter = PreparationFixtureAdapter(responses: [response([:]), response(["request": .string("build")])])
    let result = try await prepare(adapter)
    XCTAssertEqual(result, ["request": .string("build")])
    let inputs = await adapter.inputs
    XCTAssertEqual(inputs.count, 2)
    XCTAssertFalse(inputs.contains { $0.promptText.contains("private-default-value") })
    XCTAssertTrue(inputs[1].promptText.contains("validationFeedback"))
  }

  func testMissingInformationReturnsClarificationWithoutGuessing() async {
    let adapter = PreparationFixtureAdapter(responses: [[
      "variables": .object([:]), "needsClarification": .bool(true), "question": .string("Which project?")
    ]])
    do {
      _ = try await prepare(adapter)
      XCTFail("A clarification response must not become executable variables")
    } catch {
      XCTAssertEqual(error as? SpecialistInputPreparationError, .needsClarification("Which project?"))
    }
    let inputs = await adapter.inputs
    XCTAssertEqual(inputs.count, 1)
  }

  func testRepairStopsAfterTwoInvalidResponses() async {
    let adapter = PreparationFixtureAdapter(responses: [response([:])])
    do {
      _ = try await prepare(adapter)
      XCTFail("An invalid input must not escape bounded repair")
    } catch {
      guard case SpecialistInputPreparationError.invalidInput = error else {
        return XCTFail("Expected bounded schema failure, got \(error)")
      }
    }
    let inputs = await adapter.inputs
    XCTAssertEqual(inputs.count, 2)
  }

  private func prepare(_ adapter: PreparationFixtureAdapter) async throws -> JSONObject {
    let card = WorkflowCompactCatalogCard(
      workflowId: "build", workflowName: "Build", shortSummary: "Build project", tags: [], domain: "software",
      originId: "origin", sourceKind: .workflow, scope: .project, provenance: .immutable, revision: "revision", active: true
    )
    let provider = SpecialistRielaClassifier(
      node: AgentNodePayload(id: "planner", executionBackend: .officialOpenAISDK, model: "fixture"), cards: [card], adapter: adapter
    )
    let callable = AgentNodePayload(
      id: "work", model: "fixture", variables: ["credential": .string("private-default-value")],
      input: NodeInputContract(jsonSchema: [
        "type": .string("object"), "required": .array([.string("request")]),
        "properties": .object(["request": .object(["type": .string("string")])])
      ])
    )
    return try await provider.prepareInput(
      request: SpecialistRequest(
        requestId: "request", sourceEventId: "event",
        principal: SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room"), route: .work, body: "Build it"
      ), specialist: .init(id: "engineering", capacity: 1, domain: "software"),
      workflow: card, callableNode: callable, deadline: Date().addingTimeInterval(30)
    )
  }

  private func response(_ variables: JSONObject) -> JSONObject {
    ["variables": .object(variables), "needsClarification": .bool(false), "question": .string("")]
  }
}

private actor PreparationFixtureAdapter: NodeAdapter {
  var inputs: [AdapterExecutionInput] = []
  let responses: [JSONObject]

  init(responses: [JSONObject]) { self.responses = responses }

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let response = responses[min(inputs.count, responses.count - 1)]
    inputs.append(input)
    return AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: response)
  }
}
