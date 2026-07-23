import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testCodexRunnerPersistsFreshAndResumedBackendSessionIdsBeforeCompletion() async throws {
    let processRunner = SessionIdSequencedStreamingRunner(results: [
      LocalAgentProcessResult(
        stdout: """
        {"type":"thread.started","thread_id":"codex-native-1"}
        {"type":"assistant.snapshot","content":"first"}
        """,
        stderr: "",
        terminationStatus: 0
      ),
      LocalAgentProcessResult(
        stdout: #"{"type":"assistant.snapshot","content":"second"}"#,
        stderr: "",
        terminationStatus: 0
      )
    ])
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: CodexAgentAdapter(runner: processRunner, authPreflight: false)
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendSessionWorkflow(includeReuseStep: true),
      nodePayloads: ["node": backendSessionNode(backend: .codexAgent)]
    ))

    let loaded = try await store.loadSession(id: result.session.sessionId)
    let stored = try XCTUnwrap(loaded)
    XCTAssertEqual(stored.executions.map(\.backendSessionId), ["codex-native-1", "codex-native-1"])
    let runs = await processRunner.runs()
    XCTAssertEqual(runs.count, 2)
    XCTAssertTrue(runs[1].configuration.arguments.containsSubsequence(["exec", "resume", "--json"]))
    XCTAssertTrue(runs[1].configuration.arguments.contains("codex-native-1"))
  }

  func testClaudeProductionStreamCommandPersistsNativeSessionIdAndNormalizesResult() async throws {
    let processRunner = SessionIdSequencedStreamingRunner(results: [
      LocalAgentProcessResult(
        stdout: """
        {"type":"system","subtype":"init","session_id":"claude-native-1"}
        {"type":"result","subtype":"success","result":"done","session_id":"claude-native-1"}
        """,
        stderr: "",
        terminationStatus: 0
      )
    ])
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: ClaudeCodeAgentAdapter(runner: processRunner, authPreflight: false)
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendSessionWorkflow(includeReuseStep: false),
      nodePayloads: ["node": backendSessionNode(backend: .claudeCodeAgent)]
    ))

    let loaded = try await store.loadSession(id: result.session.sessionId)
    let stored = try XCTUnwrap(loaded)
    XCTAssertEqual(stored.executions.map(\.backendSessionId), ["claude-native-1"])
    XCTAssertEqual(stored.executions.first?.acceptedOutput?.payload["text"], .string("done"))
    let runs = await processRunner.runs()
    let command = try XCTUnwrap(runs.first?.configuration.arguments)
    XCTAssertTrue(command.containsSubsequence(["-p", "--output-format", "stream-json"]))
    XCTAssertEqual(command.filter { $0 == "--verbose" }.count, 1)
    XCTAssertFalse(command.containsSubsequence(["--output-format", "text"]))
  }

  private func backendSessionWorkflow(includeReuseStep: Bool) -> WorkflowDefinition {
    let firstTransitions = includeReuseStep ? [WorkflowStepTransition(toStepId: "second")] : nil
    var steps = [WorkflowStepRef(id: "first", nodeId: "node", transitions: firstTransitions)]
    if includeReuseStep {
      steps.append(WorkflowStepRef(
        id: "second",
        nodeId: "node",
        sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse)
      ))
    }
    return WorkflowDefinition(
      workflowId: "backend-session-persistence",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: steps,
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
  }

  private func backendSessionNode(backend: NodeExecutionBackend) -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: backend, model: "model")
  }
}

private actor SessionIdSequencedStreamingRunner: LocalAgentProcessEventStreaming {
  private var results: [LocalAgentProcessResult]
  private var recordedRuns: [RecordedRun] = []

  init(results: [LocalAgentProcessResult]) {
    self.results = results
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    try await run(
      configuration: configuration,
      stdin: stdin,
      deadline: deadline,
      outputEventHandler: nil
    )
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    recordedRuns.append(RecordedRun(configuration: configuration, stdin: stdin, deadline: deadline))
    guard !results.isEmpty else {
      return LocalAgentProcessResult(stdout: "", stderr: "missing result", terminationStatus: 1)
    }
    let result = results.removeFirst()
    for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: line))
    }
    return result
  }

  func runs() -> [RecordedRun] {
    recordedRuns
  }
}
