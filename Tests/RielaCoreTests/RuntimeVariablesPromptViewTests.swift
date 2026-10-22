import XCTest
@testable import RielaCore

final class RuntimeVariablesPromptViewTests: XCTestCase {
  func testSingleMessagePayloadIsElidedAndLatestAliasesMessage() throws {
    let marker = String(repeating: "unique-runtime-marker-", count: 5_000)
    let payload: JSONObject = ["big": .string(marker), "small": .string("s")]
    let input: JSONObject = [
      "big": .string(marker), "small": .string("s"),
      "_rielaInput": .object([
        "messages": .array([.object(["payload": .object(payload), "stepId": .string("one")])]),
        "latest": .object(["payload": .object(payload), "stepId": .string("one")])
      ])
    ]
    let view = deduplicatedRuntimeVariablesView(input)
    guard case let .object(rielaInput)? = view["_rielaInput"],
          case let .array(messages)? = rielaInput["messages"],
          case let .object(message) = messages[0],
          case let .object(messagePayload)? = message["payload"],
          case let .object(latest)? = rielaInput["latest"] else {
      return XCTFail("deduplicated runtime input structure was not preserved")
    }
    XCTAssertEqual(messagePayload[runtimeVariablesElidedKeysMarker], .array([.string("big"), .string("small")]))
    XCTAssertEqual(latest["payload"], .object([runtimeVariablesSameAsMarker: .string("/_rielaInput/messages/0/payload")]))
  }

  func testOverriddenMessageValueStaysInlineAndMalformedInputIsUnchanged() {
    let input: JSONObject = [
      "k": .string("later"),
      "_rielaInput": .object(["messages": .array([
        .object(["payload": .object(["k": .string("earlier")])]),
        .object(["payload": .object(["k": .string("later")])])
      ])])
    ]
    let view = deduplicatedRuntimeVariablesView(input)
    guard case let .object(rielaInput)? = view["_rielaInput"],
          case let .array(messages)? = rielaInput["messages"],
          case let .object(first) = messages[0],
          case let .object(firstPayload)? = first["payload"],
          case let .object(second) = messages[1],
          case let .object(secondPayload)? = second["payload"] else {
      return XCTFail("message payloads are missing")
    }
    XCTAssertEqual(firstPayload["k"], .string("earlier"))
    XCTAssertEqual(secondPayload[runtimeVariablesElidedKeysMarker], .array([.string("k")]))
    XCTAssertEqual(deduplicatedRuntimeVariablesView(["_rielaInput": .string("bad")]), ["_rielaInput": .string("bad")])
  }

  func testRunnerPromptContainsLargePayloadExactlyOnceAndTemplatesUseOriginalInput() async throws {
    let marker = String(repeating: "unique-large-payload-marker-", count: 4_000)
    let workflow = twoStepWorkflow()
    let variables: JSONObject = ["workflowInput": .object(["k": .string("value")])]

    let defaultPromptAdapter = TwoStepPayloadAdapter(marker: marker)
    let defaultStore = InMemoryWorkflowRuntimeStore()
    let defaultResult = try await DeterministicWorkflowRunner(store: defaultStore, adapter: defaultPromptAdapter).run(
      DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: twoStepNodePayloads(),
        variables: variables
      )
    )
    let executedNodeIDs = await defaultPromptAdapter.executedNodeIDs()
    XCTAssertEqual(executedNodeIDs, ["producer-node", "consumer-node"])
    XCTAssertEqual(defaultResult.session.executions.first?.acceptedOutput?.payload["big"], .string(marker))
    let producerMessages = try await defaultStore.listMessages(for: defaultResult.session.sessionId, toStepId: "consumer-node")
    XCTAssertEqual(producerMessages.first?.payload["big"], .string(marker))
    let capturedDefaultInput = await defaultPromptAdapter.capturedInput()
    let defaultInput = try XCTUnwrap(capturedDefaultInput)
    let composed = (defaultInput.systemPromptText ?? "") + "\n" + defaultInput.promptText
    XCTAssertEqual(composed.components(separatedBy: marker).count - 1, 1)
    XCTAssertTrue(defaultInput.systemPromptText?.contains(runtimeVariablesSameAsMarker) == true)
    XCTAssertTrue(defaultInput.systemPromptText?.contains(runtimeVariablesElidedKeysMarker) == true)

    let templateAdapter = TwoStepPayloadAdapter(marker: marker)
    let templateStore = InMemoryWorkflowRuntimeStore()
    _ = try await DeterministicWorkflowRunner(store: templateStore, adapter: templateAdapter).run(
      DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: twoStepNodePayloads(promptTemplate: "{{_rielaInput.latest.payload.small}}|{{runtimeVariables.workflowInput.k}}"),
        variables: variables
      )
    )
    let capturedTemplateInput = await templateAdapter.capturedInput()
    let templateInput = try XCTUnwrap(capturedTemplateInput)
    XCTAssertEqual(templateInput.promptText, "s|value")
  }

  private func twoStepWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runtime-dedup-test", description: "dedup prompt test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "producer-node",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "producer-node", nodeFile: "producer.json"),
        WorkflowNodeRegistryRef(id: "consumer-node", nodeFile: "consumer.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "producer-node", nodeId: "producer-node",
          transitions: [WorkflowStepTransition(toStepId: "consumer-node", label: "always")]
        ),
        WorkflowStepRef(id: "consumer-node", nodeId: "consumer-node", role: .worker)
      ],
      nodes: [
        WorkflowNodeRef(id: "producer-node", nodeFile: "producer.json"),
        WorkflowNodeRef(id: "consumer-node", nodeFile: "consumer.json")
      ]
    )
  }

  private func twoStepNodePayloads(promptTemplate: String? = nil) -> [String: AgentNodePayload] {
    [
      "producer-node": AgentNodePayload(
        id: "producer-node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly
      ),
      "consumer-node": AgentNodePayload(
        id: "consumer-node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly,
        promptTemplate: promptTemplate
      )
    ]
  }
}

private actor TwoStepPayloadAdapter: NodeAdapter {
  private let marker: String
  private var input: AdapterExecutionInput?
  private var nodeIDs: [String] = []

  init(marker: String) {
    self.marker = marker
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    nodeIDs.append(input.node.id)
    if input.node.id == "producer-node" {
      return AdapterExecutionOutput(
        provider: "test", model: input.node.model, promptText: input.promptText, completionPassed: true,
        payload: ["big": .string(marker), "small": .string("s")]
      )
    }
    self.input = input
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText, completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func capturedInput() -> AdapterExecutionInput? {
    input
  }

  func executedNodeIDs() -> [String] {
    nodeIDs
  }
}
