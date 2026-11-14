import XCTest
@testable import RielaCore

final class WorkflowOutputContractPreflightTests: XCTestCase {
  private var workflow: WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "schema-preflight", description: "Contract guidance",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "only",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "only", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
  }

  func testDialectIsSharedAndNestedUnsupportedKeywordsFailBeforeAdapter() async throws {
    let schema: JSONObject = ["properties": .object(["nested": .object(["if": .object([:])])])]
    let node = AgentNodePayload(id: "node", model: "model", output: NodeOutputContract(jsonSchema: schema))
    let diagnostics = DefaultWorkflowValidator().validate(workflow, nodePayloads: ["node": node])
    XCTAssertEqual(diagnostics.first?.path, "workflow.nodes.node.output.jsonSchema")
    XCTAssertTrue(diagnostics.first?.message.contains("$schema.properties.nested.if") == true)
    let adapter = ContractCapturingAdapter()
    do {
      _ = try await DeterministicWorkflowRunner(adapter: adapter).run(
        DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: ["node": node]))
      XCTFail("Unsupported schemas must fail preflight")
    } catch {
      guard case DeterministicWorkflowRunnerError.invalidWorkflow = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let inputs = await adapter.inputs
    XCTAssertTrue(inputs.isEmpty)
  }

  func testRejectsBoundedImpossibleObjectContracts() {
    let validator = DefaultWorkflowOutputValidator()
    let schemas: [JSONObject] = [
      ["type": .string("string")],
      ["const": .object([:]), "allOf": .array([.object(["type": .string("string")])])],
      ["enum": .array([.object([:])]), "required": .array([.string("missing")])],
      ["allOf": .array([.object([:])]), "anyOf": .array([.object(["type": .string("string")])])],
      ["additionalProperties": .bool(false), "required": .array([.string("missing")])]
    ]
    for schema in schemas { XCTAssertNotNil(validator.validateContractSchema(schema), "\(schema)") }
    XCTAssertNil(validator.validateContractSchema(["type": .array([.string("object"), .string("null")])]))
  }

  func testSchemaFreePromptsRemainUnchanged() async throws {
    let node = AgentNodePayload(id: "node", model: "model", systemPromptTemplate: "Existing persona",
      promptTemplate: "Existing task")
    let adapter = ContractCapturingAdapter()
    _ = try await DeterministicWorkflowRunner(adapter: adapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow, nodePayloads: ["node": node]))
    let inputs = await adapter.inputs
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.promptText, "Existing task")
    XCTAssertTrue(input.systemPromptText?.hasPrefix("Existing persona\n\nRuntime variables are available") == true)
    XCTAssertFalse(input.systemPromptText?.contains("Required output contract") == true)
    let prompts = DeterministicWorkflowRunner(adapter: adapter).composedPrompts(
      workflow: workflow, step: workflow.steps[0], payload: node, variables: [:])
    XCTAssertEqual(prompts.systemPromptText, "Existing persona")
    XCTAssertEqual(prompts.promptText, "Existing task")
    XCTAssertEqual(prompts.resumedPromptText, "Existing task")
  }

  func testFiniteCandidatesHandleBoundsBeyondMachineIntegerRange() {
    let validator = DefaultWorkflowOutputValidator()
    let huge = JSONValue.number(1e20)
    for candidateKey in ["const", "enum"] {
      for (value, minimum, maximum) in [
        (JSONValue.string("a"), "minLength", "maxLength"),
        (JSONValue.array([.string("a")]), "minItems", "maxItems"),
        (JSONValue.integer(1), "minimum", "maximum")
      ] {
        let candidate = JSONValue.object(["x": value])
        let fixed = candidateKey == "const" ? candidate : .array([candidate])
        XCTAssertNil(validator.validateContractSchema([
          candidateKey: fixed, "properties": .object(["x": .object([maximum: huge])])
        ]))
        XCTAssertNotNil(validator.validateContractSchema([
          candidateKey: fixed, "properties": .object(["x": .object([minimum: huge])])
        ]))
      }
    }
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
      XCTAssertNotNil(validator.validateContractSchema([
        "properties": .object(["x": .object(["maxLength": .number(invalid)])])
      ]))
    }
    XCTAssertNil(validator.validateContractSchema([
      "const": .object(["x": .string("a")]),
      "properties": .object(["x": .object(["maxLength": .number(Double(Int.max))])])
    ]))
  }

  func testAppendsLiteralAuthoredSchemaAfterRenderingWithoutReplacingPersona() async throws {
    let schema: JSONObject = ["type": .string("object"), "description": .string("Keep {{literal}} intact")]
    let node = AgentNodePayload(id: "node", model: "model", systemPromptTemplate: "Persona {{name}}",
      promptTemplate: "Task {{name}}", output: NodeOutputContract(jsonSchema: schema))
    let adapter = ContractCapturingAdapter()
    _ = try await DeterministicWorkflowRunner(adapter: adapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow, nodePayloads: ["node": node], variables: ["name": .string("Aster"), "literal": .string("REPLACED")]))
    let inputs = await adapter.inputs
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.promptText, "Task Aster")
    XCTAssertTrue(input.systemPromptText?.contains("Persona Aster") == true)
    XCTAssertTrue(input.systemPromptText?.contains(try JSONValue.object(schema).compactJSONString()) == true)
    XCTAssertTrue(input.systemPromptText?.contains("{{literal}}") == true)
    XCTAssertTrue(input.systemPromptText?.contains("the schema applies to payload, not the routing envelope") == true)
  }
}

private actor ContractCapturingAdapter: NodeAdapter {
  var inputs: [AdapterExecutionInput] = []
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: [:])
  }
}
