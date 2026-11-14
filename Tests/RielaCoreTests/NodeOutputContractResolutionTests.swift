import XCTest
@testable import RielaCore

final class NodeOutputContractResolutionTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("id")]), "properties": .object([
      "id": .object(["type": .string("string"), "enum": .array([.string("allowed")])])])]

  func testResolvesSchemaWithoutModifyingInputAndKeepsStaticContract() throws {
    let source = NodeOutputContract(jsonSchema: ["required": .array([.string("id")])],
      maxValidationAttempts: 1, jsonSchemaFrom: "/supplied/schema")
    let output = try XCTUnwrap(resolveNodeOutputContract(source,
      variables: ["supplied": .object(["schema": .object(schema)])]))
    XCTAssertNil(output.jsonSchemaFrom)
    XCTAssertEqual(output.maxValidationAttempts, 1)
    XCTAssertNotNil(output.jsonSchema?["allOf"])
    XCTAssertEqual(source.jsonSchemaFrom, "/supplied/schema")
    let rejected = try DefaultWorkflowOutputValidator().validate(
      .init(source: .inlineCandidate, payload: ["id": .string("outside")]),
      contract: .init(schema: output.jsonSchema))
    XCTAssertEqual(rejected.status, .rejected)
  }

  func testNativeStructuredOutputNeverReceivesComposedAllOfRoot() throws {
    let variables: JSONObject = ["supplied": .object(["schema": .object(schema)])]
    XCTAssertThrowsError(try resolveNodeOutputContract(.init(jsonSchema: ["required": .array([.string("id")])],
      jsonSchemaFrom: "/supplied/schema", nativeStructuredOutput: true), variables: variables)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
    let resolved = try resolveNodeOutputContract(.init(jsonSchemaFrom: "/supplied/schema", nativeStructuredOutput: true),
      variables: variables)
    XCTAssertEqual(resolved?.jsonSchema, schema)
  }

  func testInvalidPointerMissingSchemaAndUnsupportedDialectFailClosed() throws {
    for pointer in ["schema", "/bad~2escape", "/missing", "/wrong", "/unsupported"] {
      XCTAssertThrowsError(try resolveNodeOutputContract(.init(jsonSchemaFrom: pointer), variables: [
        "wrong": .string("not a schema"), "unsupported": .object(["if": .object([:])])]))
    }
    XCTAssertThrowsError(try resolveNodeOutputContract(.init(jsonSchemaFrom: "/schema"),
      variables: ["schema": .object(["type": .string("string")])]))
  }

  func testRunnerUsesSameResolvedSchemaForAdapterAndPublication() async throws {
    let workflow = WorkflowDefinition(workflowId: "dynamic-output", defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "edit", nodeRegistry: [.init(id: "edit", nodeFile: "edit.json")],
      steps: [.init(id: "edit", nodeId: "edit")], nodes: [.init(id: "edit", nodeFile: "edit.json")])
    let node = AgentNodePayload(id: "edit", model: "fixture", promptTemplate: "Choose an allowed id",
      output: .init(maxValidationAttempts: 1, jsonSchemaFrom: "/runtimeVariables/editor_schema"))
    for identity in ["allowed", "outside"] {
      let adapter = DynamicContractAdapter(payload: ["id": .string(identity)])
      let runner = DeterministicWorkflowRunner(adapter: adapter)
      do {
        let result = try await runner.run(.init(workflow: workflow, nodePayloads: ["edit": node],
          variables: ["editor_schema": .object(schema)]))
        XCTAssertEqual(identity, "allowed")
        XCTAssertEqual(result.session.status, .completed)
      } catch let error as WorkflowPublicationError {
        guard identity == "outside", case .validationRejected = error else { throw error }
      }
      let inputs = await adapter.inputs
      XCTAssertEqual(inputs.count, 1)
      XCTAssertEqual(inputs.first?.node.output?.jsonSchema, schema)
      XCTAssertNil(inputs.first?.node.output?.jsonSchemaFrom)
      XCTAssertTrue(inputs.first?.systemPromptText?.contains("allowed") == true)
    }
  }

  func testAdapterRoutingDiagnosticsReachAcceptedOutput() async throws {
    let workflow = WorkflowDefinition(workflowId: "adapter-diagnostics", defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "edit", nodeRegistry: [.init(id: "edit", nodeFile: "edit.json")],
      steps: [.init(id: "edit", nodeId: "edit")], nodes: [.init(id: "edit", nodeFile: "edit.json")])
    let note = "agent-gateway/codex returned `when` without `payload`; normalized the sibling top-level fields as the payload"
    let adapter = DynamicContractAdapter(payload: ["id": .string("allowed")], routingDiagnostics: [note])
    let result = try await DeterministicWorkflowRunner(adapter: adapter).run(.init(workflow: workflow,
      nodePayloads: ["edit": .init(id: "edit", model: "fixture", output: .init(jsonSchema: schema))]))
    XCTAssertEqual(result.session.status, .completed)
    XCTAssertEqual(result.session.executions.first?.acceptedOutput?.routingDiagnostics, [note])
  }

  func testMissingDynamicSchemaNeverInvokesAdapter() async throws {
    let workflow = WorkflowDefinition(workflowId: "dynamic-missing", defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "edit", nodeRegistry: [.init(id: "edit", nodeFile: "edit.json")],
      steps: [.init(id: "edit", nodeId: "edit")], nodes: [.init(id: "edit", nodeFile: "edit.json")])
    let adapter = DynamicContractAdapter(payload: [:])
    do {
      _ = try await DeterministicWorkflowRunner(adapter: adapter).run(.init(workflow: workflow,
        nodePayloads: ["edit": .init(id: "edit", model: "fixture", output: .init(jsonSchemaFrom: "/absent"))]))
      XCTFail("Missing schema must fail before invocation")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    let inputs = await adapter.inputs
    XCTAssertTrue(inputs.isEmpty)
  }
}

private actor DynamicContractAdapter: NodeAdapter {
  var payload: JSONObject
  var routingDiagnostics: [String]
  var inputs: [AdapterExecutionInput] = []
  init(payload: JSONObject, routingDiagnostics: [String] = []) {
    self.payload = payload
    self.routingDiagnostics = routingDiagnostics
  }
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    return .init(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: payload,
      routingDiagnostics: routingDiagnostics)
  }
}
