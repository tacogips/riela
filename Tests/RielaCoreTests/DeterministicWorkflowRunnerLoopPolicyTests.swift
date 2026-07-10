import XCTest
@testable import RielaCore

final class WorkflowRunnerLoopPolicyTests: XCTestCase {
  func testRequiredLoopPolicyDenialStopsBeforeAdapterExecution() async throws {
    let adapter = CountingAdapter()
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)
    let workflow = WorkflowDefinition(
      workflowId: "runner-loop-policy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")],
      loop: WorkflowLoopMetadata(
        required: true,
        policies: LoopPolicyDeclaration(
          process: LoopProcessPolicyDeclaration(
            allowedBackends: ["codex-agent"],
            requiredWorkerModel: "gpt-5.5"
          )
        )
      )
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: ["node": AgentNodePayload(id: "node", executionBackend: .claudeCodeAgent, model: "claude-sonnet")]
      ))
      XCTFail("expected required loop policy denial")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("loop policy denied"))
    }

    let executionCount = await adapter.executionCount()
    XCTAssertEqual(executionCount, 0)
  }

  func testOptionalLoopPolicyDoesNotBlockRunner() async throws {
    let adapter = CountingAdapter()
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)
    let workflow = WorkflowDefinition(
      workflowId: "runner-loop-policy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")],
      loop: WorkflowLoopMetadata(
        required: false,
        policies: LoopPolicyDeclaration(
          process: LoopProcessPolicyDeclaration(
            allowedBackends: ["codex-agent"],
            requiredWorkerModel: "gpt-5.5"
          )
        )
      )
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", executionBackend: .claudeCodeAgent, model: "claude-sonnet")]
    ))

    let executionCount = await adapter.executionCount()
    XCTAssertEqual(executionCount, 1)
  }

  func testRunnerPassesStepPolicyContextToStdioNode() async throws {
    let stdioExecutor = CapturingPolicyStdioExecutor()
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      stdioNodeExecutor: stdioExecutor
    )
    let workflow = WorkflowDefinition(
      workflowId: "runner-loop-policy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")],
      loop: WorkflowLoopMetadata(
        required: false,
        policies: LoopPolicyDeclaration(
          process: LoopProcessPolicyDeclaration(
            nestedCodex: "deny",
            allowedBackends: ["codex-agent"]
          )
        )
      )
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "codex exec --json"])
        )
      ]
    ))

    let capturedInput = await stdioExecutor.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.policy?.allowed, false)
    XCTAssertTrue(input.policy?.denials.contains { $0.policy == "process.allowedBackends" } ?? false)
    XCTAssertTrue(input.policy?.denials.contains { $0.policy == "process.nestedCodex" } ?? false)
  }

  func testLoopGateStepReconcilesCompletionReviewRouting() async throws {
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test",
        model: "gpt-5.5",
        promptText: "prompt",
        completionPassed: true,
        when: ["always": true],
        payload: [
          "decision": .string("needs_work"),
          "goalAchieved": .bool(false)
        ]
      ))
    )
    let workflow = WorkflowDefinition(
      workflowId: "runner-loop-policy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          role: .worker,
          transitions: [
            WorkflowStepTransition(toStepId: "rework", label: "needs_work"),
            WorkflowStepTransition(toStepId: "done", label: "accepted")
          ],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        ),
        WorkflowStepRef(id: "rework", nodeId: "review-node", role: .worker),
        WorkflowStepRef(id: "done", nodeId: "review-node", role: .worker)
      ],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(
        gates: [
          LoopGateDeclaration(id: "implementation-review", stepId: "review", required: true)
        ]
      )
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")]
    ))

    XCTAssertEqual(result.session.executions.first?.acceptedOutput?.when, ["needs_replan": false, "needs_work": true])
    XCTAssertEqual(result.session.executions.first?.acceptedOutput?.routingDiagnostics.count, 1)
  }

  func testLoopConvergenceFailsOnRepeatedIdenticalFindings() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: SequenceAdapter(outputs: [
        Self.gateOutput(decision: "needs_work", findingId: "same"),
        Self.gateOutput(decision: "needs_work", findingId: "same")
      ])
    )
    let workflow = Self.convergenceWorkflow(convergence: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 2))

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
        maxSteps: 4
      ))
      XCTFail("expected loop convergence failure")
    } catch let error as DeterministicWorkflowRunner.LoopConvergenceError {
      XCTAssertEqual(error.violation.kind, .repeatedFindingsStall)
    }

    let latestSession = await store.latestSession(workflowId: "runner-loop-convergence")
    let session = try XCTUnwrap(latestSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .loopNotConverging)
  }

  func testLoopConvergenceWarnEmitsLoopStallAndContinues() async throws {
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: SequenceAdapter(outputs: [
        Self.gateOutput(decision: "needs_work", findingId: "same"),
        Self.gateOutput(decision: "needs_work", findingId: "same"),
        Self.gateOutput(decision: "accepted", findingId: "resolved")
      ])
    )
    let workflow = Self.convergenceWorkflow(convergence: LoopConvergenceDeclaration(
      maxRepeatedFindingRounds: 2,
      onStall: .warn
    ))

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
      maxSteps: 4,
      eventHandler: { event in await recorder.append(event) }
    ))

    XCTAssertEqual(result.session.status, WorkflowSessionStatus.completed)
    let events = await recorder.events()
    XCTAssertEqual(events.filter { $0.type == .loopStall }.count, 1)
  }
}

private actor CountingAdapter: NodeAdapter {
  private var count = 0

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    count += 1
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func executionCount() -> Int {
    count
  }
}

private actor CapturingPolicyStdioExecutor: WorkflowStdioNodeExecuting {
  private var input: WorkflowStdioNodeExecutionInput?

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    self.input = input
    return WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")])
  }

  func capturedInput() -> WorkflowStdioNodeExecutionInput? {
    input
  }
}

private actor SequenceAdapter: NodeAdapter {
  private var outputs: [AdapterExecutionOutput]

  init(outputs: [AdapterExecutionOutput]) {
    self.outputs = outputs
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard !outputs.isEmpty else {
      return WorkflowRunnerLoopPolicyTests.gateOutput(decision: "accepted", findingId: "default")
    }
    return outputs.removeFirst()
  }
}

private extension WorkflowRunnerLoopPolicyTests {
  static func gateOutput(decision: String, findingId: String) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      when: ["always": true],
      payload: [
        "decision": .string(decision),
        "loopGate": .object([
          "gateId": .string("implementation-review"),
          "decision": .string(decision),
          "blockingFindings": .array([
            .object([
              "id": .string(findingId),
              "severity": .string("high"),
              "filePath": .string("Sources/A.swift"),
              "message": .string("same message")
            ])
          ])
        ])
      ]
    )
  }

  static func convergenceWorkflow(convergence: LoopConvergenceDeclaration) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner-loop-convergence",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          role: .worker,
          transitions: [WorkflowStepTransition(toStepId: "review", label: "needs_work")],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        )
      ],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(
        required: false,
        convergence: convergence,
        gates: [LoopGateDeclaration(id: "implementation-review", stepId: "review", required: false)]
      )
    )
  }
}
