import XCTest
@testable import RielaCore

final class PromptOverflowContractsTests: XCTestCase {
  func testClassifierRecognizesPinnedPhrasesAndExplicitHint() {
    let cases = [
      FailureKindCase(.providerError, "Error: Prompt is too long: 1250000 tokens", .promptTooLarge),
      FailureKindCase(.providerError, "context_length_exceeded", .promptTooLarge),
      FailureKindCase(.invalidInput, "This model's maximum context length is 200000", .promptTooLarge),
      FailureKindCase(.providerError, "request_too_large", .promptTooLarge),
      FailureKindCase(.providerError, "rate limited", .adapterFailure),
      FailureKindCase(.timeout, "prompt is too long", .adapterFailure),
      FailureKindCase(.invalidOutput, "prompt is too long", .adapterFailure)
    ]
    for testCase in cases {
      XCTAssertEqual(adapterFailureKind(AdapterExecutionError(testCase.code, testCase.message)), testCase.expected)
    }
    XCTAssertEqual(
      adapterFailureKind(AdapterExecutionError(.invalidInput, "x", failureKind: .promptTooLarge)),
      .promptTooLarge
    )
  }

  func testRunnerPersistsPromptOverflowFailureKind() async throws {
    let session = try await failedSession(message: "Prompt is too long")
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .promptTooLarge)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureKind, .promptTooLarge)
    XCTAssertTrue(session.executions.first?.failureReason?.contains("Prompt is too long") == true)
  }

  func testRunnerKeepsUnrelatedProviderFailureAsAdapterFailure() async throws {
    let session = try await failedSession(message: "boom")
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .adapterFailure)
    XCTAssertEqual(session.executions.first?.failureKind, .adapterFailure)
  }

  private func failedSession(message: String) async throws -> WorkflowSession {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "node.json")]
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: PromptOverflowThrowingAdapter(message: message))
    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", model: "gpt-5.5")]
    )))
    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    return session
  }

  func testConfigurationFieldsDecodeValidateAndOmitWhenUnset() throws {
    let defaults = try JSONDecoder().decode(WorkflowDefaults.self, from: Data(#"{"nodeTimeoutMs":1,"maxLoopIterations":2,"agentPromptMaxBytes":5000}"#.utf8))
    XCTAssertEqual(defaults.agentPromptMaxBytes, 5000)
    let defaultsEncoded = try JSONEncoder().encode(WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 2))
    XCTAssertFalse((String(data: defaultsEncoded, encoding: .utf8) ?? "").contains("agentPromptMaxBytes"))

    let node = try JSONDecoder().decode(AgentNodePayload.self, from: Data(#"{"id":"n","model":"m","promptMaxBytes":1234}"#.utf8))
    XCTAssertEqual(node.promptMaxBytes, 1234)
    XCTAssertTrue(validateAgentNodePayload(AgentNodePayload(id: "n", model: "m", promptMaxBytes: 0)).contains {
      $0.path == "node.promptMaxBytes" && $0.message == "must be a positive integer"
    })
    XCTAssertTrue(validateAgentNodePayload(AgentNodePayload(id: "n", model: "m")).isEmpty)
    let nodeEncoded = try JSONEncoder().encode(AgentNodePayload(id: "n", model: "m"))
    XCTAssertFalse((String(data: nodeEncoded, encoding: .utf8) ?? "").contains("promptMaxBytes"))

    let tracking = try JSONDecoder().decode(
      WorkflowFanoutChangeTracking.self,
      from: Data(#"{"pathsFrom":"/paths","observationInlineLimit":200}"#.utf8)
    )
    XCTAssertEqual(tracking.observationInlineLimit, 200)
    XCTAssertEqual(WorkflowFanoutChangeTracking.defaultObservationInlineLimit, 200)
    XCTAssertEqual(WorkflowFanoutChangeTracking.maximumObservationInlineLimit, 10_000)
    let trackingEncoded = try JSONEncoder().encode(WorkflowFanoutChangeTracking(pathsFrom: "/paths"))
    XCTAssertFalse((String(data: trackingEncoded, encoding: .utf8) ?? "").contains("observationInlineLimit"))

    for invalid: Any in [-1, 10_001, true, "5"] {
      let diagnostics = validateRawAuthoredWorkflow(rawWorkflow(inlineLimit: invalid))
      XCTAssertTrue(diagnostics.contains { $0.path == "workflow.steps[0].transitions[0].fanout.changeTracking.observationInlineLimit" })
    }
    let combinedDiagnostics = validateRawAuthoredWorkflow(rawWorkflow(inlineLimit: true, itemsFrom: "items"))
    XCTAssertTrue(combinedDiagnostics.contains { $0.path.hasSuffix("observationInlineLimit") })
    XCTAssertTrue(combinedDiagnostics.contains { $0.path == "workflow.steps[0].transitions[0].fanout.itemsFrom" })
    for valid in [0, 200] {
      let diagnostics = validateRawAuthoredWorkflow(rawWorkflow(inlineLimit: valid))
      XCTAssertFalse(diagnostics.contains { $0.path.hasSuffix("observationInlineLimit") })
    }
    XCTAssertTrue(validateRawAuthoredWorkflow(rawWorkflow(agentLimit: 0)).contains {
      $0.path == "workflow.defaults.agentPromptMaxBytes"
    })
    XCTAssertFalse(validateRawAuthoredWorkflow(rawWorkflow(agentLimit: 5000)).contains {
      $0.path == "workflow.defaults.agentPromptMaxBytes"
    })
  }

  private func rawWorkflow(
    inlineLimit: Any? = nil,
    agentLimit: Any? = nil,
    itemsFrom: String = "/items"
  ) -> [String: Any] {
    var defaults: [String: Any] = ["nodeTimeoutMs": 1, "maxLoopIterations": 2]
    if let agentLimit { defaults["agentPromptMaxBytes"] = agentLimit }
    var changeTracking: [String: Any] = ["pathsFrom": "/paths"]
    if let inlineLimit { changeTracking["observationInlineLimit"] = inlineLimit }
    return [
      "workflowId": "validation-test",
      "defaults": defaults,
      "entryStepId": "s",
      "nodes": [["id": "n", "nodeFile": "n.json"]],
      "steps": [["id": "s", "nodeId": "n", "transitions": [["toStepId": "s", "fanout": [
        "groupId": "g", "itemsFrom": itemsFrom, "joinStepId": "s",
        "changeTracking": changeTracking
      ]]]]]
    ]
  }
}

private struct FailureKindCase {
  var code: AdapterExecutionErrorCode
  var message: String
  var expected: WorkflowSessionFailureKind

  init(_ code: AdapterExecutionErrorCode, _ message: String, _ expected: WorkflowSessionFailureKind) {
    self.code = code
    self.message = message
    self.expected = expected
  }
}

private actor PromptOverflowThrowingAdapter: NodeAdapter {
  private let message: String

  init(message: String) {
    self.message = message
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(.providerError, message)
  }
}
