import XCTest
import Crypto
@testable import RielaCore

final class AgentPromptGuardTests: XCTestCase {
  func testOversizedRuntimeValueSpillsAndRecordsEvidence() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = PromptGuardCapturingAdapter()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-guard-test", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, fanoutWorkspaceRoot: root)
    let marker = String(repeating: "large-payload-", count: 5_000)
    let payload = AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      agentSandbox: .readOnly,
      promptTemplate: "Proceed",
      promptMaxBytes: 2_000
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": payload],
      variables: ["huge": .string(marker)]
    ))

    let capturedValue = await adapter.input()
    let captured = try XCTUnwrap(capturedValue)
    XCTAssertTrue(captured.systemPromptText?.contains("$rielaSpilled") == true)
    XCTAssertFalse(captured.systemPromptText?.contains(marker) == true)
    XCTAssertEqual(captured.mergedVariables["huge"], .string(marker))
    let execution = try XCTUnwrap(result.session.executions.first)
    guard case let .object(compaction)? = execution.inputSnapshot?["promptCompaction"],
          case let .array(spills)? = compaction["spills"],
          case let .object(spill)? = spills.first,
          case let .string(path)? = spill["path"],
          case let .string(digest)? = spill["sha256"] else {
      return XCTFail("expected spill evidence")
    }
    XCTAssertEqual(compaction["outcome"], .string("spilled"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let spilledData = try Data(contentsOf: URL(fileURLWithPath: path))
    let actualDigest = SHA256.hash(data: spilledData).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(digest, actualDigest)
  }

  func testStillOverBudgetFailsBeforeAdapterInvocation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = PromptGuardCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)
    let payload = AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      agentSandbox: .readOnly,
      promptTemplate: "Proceed",
      promptMaxBytes: 100
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": payload],
      variables: ["huge": .string(String(repeating: "x", count: 6_000))]
    )))

    let captured = await adapter.input()
    XCTAssertNil(captured)
    let loadedSession = await store.latestSession(workflowId: "prompt-guard-test")
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .promptTooLarge)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions[0].failureKind, .promptTooLarge)
    guard case let .object(compaction)? = session.executions[0].inputSnapshot?["promptCompaction"] else {
      return XCTFail("expected prompt compaction evidence")
    }
    XCTAssertEqual(compaction["outcome"], JSONValue.string("overBudget"))
  }

  func testBudgetPrecedence() throws {
    let runner = DeterministicWorkflowRunner(adapter: PromptGuardCapturingAdapter())
    var workflow = workflow()
    workflow.defaults.agentPromptMaxBytes = 9_000
    var payload = AgentNodePayload(id: "worker", model: "test", promptMaxBytes: 5_000)
    XCTAssertEqual(runner.effectiveAgentPromptMaxBytes(workflow: workflow, payload: payload), 5_000)
    payload.promptMaxBytes = nil
    XCTAssertEqual(runner.effectiveAgentPromptMaxBytes(workflow: workflow, payload: payload), 9_000)
    workflow.defaults.agentPromptMaxBytes = nil
    XCTAssertEqual(runner.effectiveAgentPromptMaxBytes(workflow: workflow, payload: payload), agentPromptDefaultMaxBytes)
  }

  func testPlacedOverBudgetStepRejectsWithoutWritingSpills() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/prompt-overflow/pog-03-prompt-guard/placed-test", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = DeterministicWorkflowRunner(adapter: PromptGuardCapturingAdapter(), fanoutWorkspaceRoot: root)
    var workflow = workflow()
    workflow.prompts = WorkflowPrompts(workerSystemPromptTemplate: String(repeating: "context ", count: 40))
    var payload = AgentNodePayload(
      id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
      promptTemplate: "Proceed"
    )
    let requestVariables: JSONObject = ["huge": .string(String(repeating: "x", count: 6_000))]
    let step = WorkflowStepRef(
      id: "worker-step", nodeId: "worker", role: .worker,
      placement: DistributedExecutionPlacement(target: DistributedWorkerTarget(), workspace: "remote")
    )
    payload.promptMaxBytes = 100
    let request = DeterministicWorkflowRunRequest(
      workflow: workflow, nodePayloads: ["worker": payload], variables: requestVariables
    )
    let date = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: workflow.workflowId,
      sessionId: "placed-prompt-guard-session",
      entryStepId: step.id,
      createdAt: date,
      updatedAt: date
    )
    let variables = runner.promptVariables(
      workflow: workflow, step: step, payload: payload,
      requestVariables: requestVariables, resolvedInputPayload: [:]
    )
    let prompts = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow, step: step, payload: payload, variables: variables, session: session
    )
    let result = try runner.guardAgentPrompt(
      workflow: workflow, step: step, payload: payload, request: request,
      session: session, resolvedInputPayload: [:], prompts: prompts
    )

    XCTAssertEqual(result.rejection?.failureKind, .promptTooLarge)
    XCTAssertEqual(result.evidence?["outcome"], .string("overBudget"))
    XCTAssertEqual(result.evidence?["spills"], .array([]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tmp/riela-prompt-spill").path))

    let unplacedStep = WorkflowStepRef(id: step.id, nodeId: step.nodeId, role: step.role)
    payload.promptMaxBytes = nil
    let unplacedVariables = runner.promptVariables(
      workflow: workflow, step: unplacedStep, payload: payload,
      requestVariables: requestVariables, resolvedInputPayload: [:]
    )
    let unplacedPrompts = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow, step: unplacedStep, payload: payload, variables: unplacedVariables, session: session
    )
    let measuredBytes = (unplacedPrompts.systemPromptText ?? "").utf8.count
      + max(unplacedPrompts.promptText.utf8.count, unplacedPrompts.resumedPromptText.utf8.count)
    payload.promptMaxBytes = measuredBytes - 1_000
    let unplacedRequest = DeterministicWorkflowRunRequest(
      workflow: workflow, nodePayloads: ["worker": payload], variables: requestVariables
    )
    let unplacedResult = try runner.guardAgentPrompt(
      workflow: workflow, step: unplacedStep, payload: payload, request: unplacedRequest,
      session: session, resolvedInputPayload: [:], prompts: unplacedPrompts
    )
    XCTAssertNil(unplacedResult.rejection)
    guard case let .array(unplacedSpills)? = unplacedResult.evidence?["spills"] else {
      return XCTFail("expected unplaced control spill evidence")
    }
    XCTAssertFalse(unplacedSpills.isEmpty)
  }

  func testMismatchedExistingSpillFileRecordsOneFailedExecutionWithoutAdapterInvocation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/prompt-overflow/pog-03-prompt-guard/mismatched-spill-test", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = PromptGuardCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, fanoutWorkspaceRoot: root)
    let workflow = workflow()
    let step = try XCTUnwrap(workflow.steps.first)
    let variables: JSONObject = ["huge": .string(String(repeating: "x", count: 6_000))]
    var payload = AgentNodePayload(
      id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
      promptTemplate: "Proceed"
    )
    let session = try await store.createSession(WorkflowSessionCreateInput(
      sessionId: "mismatched-spill-session", workflowId: workflow.workflowId, entryStepId: step.id
    ))
    let mergedVariables = runner.promptVariables(
      workflow: workflow, step: step, payload: payload,
      requestVariables: variables, resolvedInputPayload: [:]
    )
    let prompts = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow, step: step, payload: payload, variables: mergedVariables, session: session
    )
    let measuredBytes = (prompts.systemPromptText ?? "").utf8.count
      + max(prompts.promptText.utf8.count, prompts.resumedPromptText.utf8.count)
    payload.promptMaxBytes = measuredBytes - 1_000
    let boundedRequest = DeterministicWorkflowRunRequest(
      workflow: workflow, nodePayloads: ["worker": payload], variables: variables
    )
    let initialGuard = try runner.guardAgentPrompt(
      workflow: workflow, step: step, payload: payload, request: boundedRequest,
      session: session, resolvedInputPayload: [:], prompts: prompts
    )
    guard case let .array(spills)? = initialGuard.evidence?["spills"],
          case let .object(firstSpill)? = spills.first,
          case let .string(path)? = firstSpill["path"] else {
      return XCTFail("expected initial spill path")
    }
    try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))

    let mismatchedGuard = try runner.guardAgentPrompt(
      workflow: workflow, step: step, payload: payload, request: boundedRequest,
      session: session, resolvedInputPayload: [:], prompts: prompts
    )
    XCTAssertEqual(mismatchedGuard.rejection?.code, .policyBlocked)
    XCTAssertTrue(mismatchedGuard.rejection?.message.contains("different content") == true)
    XCTAssertEqual(mismatchedGuard.evidence?["outcome"], .string("overBudget"))
    let adapterInput = AdapterExecutionInput(
      node: payload,
      promptText: prompts.promptText,
      freshPromptText: prompts.promptText,
      resumedPromptText: prompts.resumedPromptText,
      systemPromptText: prompts.systemPromptText,
      arguments: variables,
      mergedVariables: mergedVariables
    )
    do {
      _ = try await runner.executeAndPublish(
        adapterInput: adapterInput,
        sessionId: session.sessionId,
        step: step,
        basePayload: payload,
        transitions: [],
        request: boundedRequest,
        executionIndex: 1,
        promptGuard: mismatchedGuard
      )
      XCTFail("expected mismatched spill rejection to be published")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("different content"))
    }

    let captured = await adapter.input()
    XCTAssertNil(captured)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let failedSession = try XCTUnwrap(loadedSession)
    XCTAssertEqual(failedSession.status, .failed)
    XCTAssertEqual(failedSession.executions.count, 1)
    XCTAssertEqual(failedSession.executions[0].status, .failed)
    XCTAssertTrue(failedSession.executions[0].failureReason?.contains("different content") == true)
    guard case let .object(compaction)? = failedSession.executions[0].inputSnapshot?["promptCompaction"] else {
      return XCTFail("expected prompt compaction on failed execution")
    }
    XCTAssertEqual(compaction["outcome"], .string("overBudget"))
  }

  func testSpillUpdatesLatestMessagePayloadAliasForTemplates() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/prompt-overflow/pog-03-prompt-guard/latest-alias-test", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = DeterministicWorkflowRunner(adapter: PromptGuardCapturingAdapter(), fanoutWorkspaceRoot: root)
    let workflow = workflow()
    var payload = AgentNodePayload(
      id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
      promptTemplate: "{{_rielaInput.latest.payload.huge}}"
    )
    let step = WorkflowStepRef(id: "worker-step", nodeId: "worker", role: .worker)
    let sessionDate = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: workflow.workflowId, sessionId: "latest-alias-session", entryStepId: step.id,
      createdAt: sessionDate, updatedAt: sessionDate
    )
    let original = JSONValue.string(String(repeating: "message-payload", count: 5_000))
    let resolved: JSONObject = ["_rielaInput": .object([
      "messages": .array([.object(["payload": .object(["huge": original])])]),
      "latest": .object(["payload": .object(["huge": original])])
    ])]
    let variables = runner.promptVariables(
      workflow: workflow, step: step, payload: payload,
      requestVariables: [:], resolvedInputPayload: resolved
    )
    let prompts = try runner.composedPromptsWithFinalizationEvidence(
      workflow: workflow, step: step, payload: payload, variables: variables, session: session
    )
    let measuredBytes = (prompts.systemPromptText ?? "").utf8.count + max(prompts.promptText.utf8.count, prompts.resumedPromptText.utf8.count)
    payload.promptMaxBytes = measuredBytes - 70_000
    let request = DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: ["worker": payload])
    let result = try runner.guardAgentPrompt(
      workflow: workflow, step: step, payload: payload, request: request,
      session: session, resolvedInputPayload: resolved, prompts: prompts
    )
    let repeatedResult = try runner.guardAgentPrompt(
      workflow: workflow, step: step, payload: payload, request: request,
      session: session, resolvedInputPayload: resolved, prompts: prompts
    )

    XCTAssertNil(result.rejection)
    XCTAssertEqual(result.evidence, repeatedResult.evidence)
    XCTAssertEqual(result.prompts.promptText, repeatedResult.prompts.promptText)
    XCTAssertEqual(result.prompts.systemPromptText, repeatedResult.prompts.systemPromptText)
    XCTAssertTrue(result.prompts.promptText.contains("$rielaSpilled"))
    XCTAssertFalse(result.prompts.promptText.contains(String(repeating: "message-payload", count: 100)))
    guard case let .array(spills)? = result.evidence?["spills"],
          case let .object(firstSpill)? = spills.first else {
      return XCTFail("expected latest alias spill evidence")
    }
    XCTAssertEqual(firstSpill["pointer"], .string("/_rielaInput/messages/0/payload/huge"))
    guard case let .array(repeatedSpills)? = repeatedResult.evidence?["spills"],
          case let .object(repeatedSpill)? = repeatedSpills.first else {
      return XCTFail("expected deterministic repeated spill evidence")
    }
    XCTAssertEqual(firstSpill["path"], repeatedSpill["path"])
  }

  func testUnderBudgetInputHasNoCompactionEvidence() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = PromptGuardCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": AgentNodePayload(
        id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "Proceed"
      )]
    ))
    let captured = await adapter.input()
    XCTAssertEqual(captured?.promptText, "Proceed")
    XCTAssertNil(result.session.executions.first?.inputSnapshot?["promptCompaction"])
  }

  func testSmallestCoveringCandidateIsSpilledAndTemplateRendersStub() async throws {
    let variables: JSONObject = [
      "a": .string(String(repeating: "a", count: 60_000)),
      "b": .string(String(repeating: "b", count: 15_000))
    ]
    let baselineAdapter = PromptGuardCapturingAdapter()
    _ = try await DeterministicWorkflowRunner(adapter: baselineAdapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": AgentNodePayload(
        id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "{{runtimeVariables.b}}"
      )],
      variables: variables
    ))
    let baselineValue = await baselineAdapter.input()
    let baseline = try XCTUnwrap(baselineValue)
    let measuredBytes = (baseline.systemPromptText ?? "").utf8.count + max(baseline.promptText.utf8.count, baseline.resumedPromptText?.utf8.count ?? 0)
    let adapter = PromptGuardCapturingAdapter()
    let result = try await DeterministicWorkflowRunner(adapter: adapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": AgentNodePayload(
        id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "{{runtimeVariables.b}}", promptMaxBytes: measuredBytes - 12_000
      )],
      variables: variables
    ))
    let capturedValue = await adapter.input()
    let captured = try XCTUnwrap(capturedValue)
    XCTAssertTrue(captured.promptText.contains("$rielaSpilled"))
    XCTAssertFalse(captured.promptText.contains(String(repeating: "b", count: 1_000)))
    guard case let .object(compaction)? = result.session.executions.first?.inputSnapshot?["promptCompaction"],
          case let .array(spills)? = compaction["spills"],
          case let .object(firstSpill)? = spills.first else {
      return XCTFail("expected smallest candidate spill evidence")
    }
    XCTAssertEqual(spills.count, 1)
    XCTAssertEqual(firstSpill["pointer"], .string("/b"))
  }

  func testEqualSizeCandidatesUseAscendingPointerTieBreak() async throws {
    let variables: JSONObject = [
      "a": .string(String(repeating: "same", count: 4_000)),
      "b": .string(String(repeating: "same", count: 4_000))
    ]
    let baselineAdapter = PromptGuardCapturingAdapter()
    _ = try await DeterministicWorkflowRunner(adapter: baselineAdapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": AgentNodePayload(
        id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "Proceed"
      )],
      variables: variables
    ))
    let baselineValue = await baselineAdapter.input()
    let baseline = try XCTUnwrap(baselineValue)
    let measuredBytes = (baseline.systemPromptText ?? "").utf8.count + baseline.promptText.utf8.count
    let adapter = PromptGuardCapturingAdapter()
    let result = try await DeterministicWorkflowRunner(adapter: adapter).run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["worker": AgentNodePayload(
        id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "Proceed", promptMaxBytes: measuredBytes - 1
      )],
      variables: variables
    ))
    guard case let .object(compaction)? = result.session.executions.first?.inputSnapshot?["promptCompaction"],
          case let .array(spills)? = compaction["spills"],
          case let .object(firstSpill)? = spills.first else {
      return XCTFail("expected tie-break spill evidence")
    }
    XCTAssertEqual(spills.count, 1)
    XCTAssertEqual(firstSpill["pointer"], .string("/a"))
  }

  private func workflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "prompt-guard-test",
      description: "prompt guard test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker-step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker", nodeFile: "nodes/worker.json")],
      steps: [WorkflowStepRef(id: "worker-step", nodeId: "worker", role: .worker)],
      nodes: [WorkflowNodeRef(id: "worker-step", nodeFile: "nodes/worker.json")]
    )
  }
}

private actor PromptGuardCapturingAdapter: NodeAdapter {
  private var captured: AdapterExecutionInput?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    captured = input
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["ok": .bool(true)]
    )
  }

  func input() -> AdapterExecutionInput? { captured }
}
