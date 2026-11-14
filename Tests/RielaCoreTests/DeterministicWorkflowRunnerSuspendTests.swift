import XCTest
@testable import RielaCore

final class DeterministicWorkflowRunnerSuspendTests: XCTestCase {
  func testDefaultEnvelopeSuspendsWithoutPublishingBusinessOutputAndResumesAtStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: envelopeOutput()))
    let first = try await runner.run(request(eventHandler: { await recorder.append($0) }))

    XCTAssertEqual(first.status, .suspended)
    XCTAssertEqual(first.exitCode, 5)
    XCTAssertEqual(first.session.suspend?.stepId, "step-a")
    let suspendedExecutionId = try XCTUnwrap(first.session.executions.first?.executionId)
    XCTAssertEqual(first.session.suspend?.reasonKind, .userInputRequired)
    XCTAssertEqual(first.session.suspend?.stepExecutionId, suspendedExecutionId)
    XCTAssertEqual(first.session.suspend?.question?.id, "q")
    XCTAssertEqual(first.session.suspend?.question?.text, "Choose")
    XCTAssertEqual(first.session.suspend?.producer, .stepExecution(suspendedExecutionId))
    XCTAssertEqual(first.session.executions.map(\.status), [.suspended])
    XCTAssertNil(first.session.executions.first?.acceptedOutput)
    let firstMessages = try await store.listMessages(for: first.session.sessionId, toStepId: nil)
    XCTAssertEqual(firstMessages, [])
    let events = await recorder.events()
    XCTAssertEqual(events.suffix(2).map(\.type), [.handover, .sessionCompleted])
    XCTAssertEqual(events.last?.status, .suspended)

    var resume = request()
    resume.resumeSessionId = first.session.sessionId
    let resumed = try await DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: plainOutput())
    ).run(resume)
    XCTAssertEqual(resumed.status, .completed)
    XCTAssertNil(resumed.session.suspend)
    XCTAssertEqual(resumed.session.executions.map(\.stepId), ["step-a", "step-a", "step-b"])
  }

  func testDownstreamResumePublishesBusinessPayloadAndSuspendsAtNextStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    var output = envelopeOutput()
    output.payload["handover"] = .object([
      "reason": .string("userInputRequired"),
      "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])]),
      "resumeStepId": .string("step-b")
    ])
    let workflow = workflowWithTwoSteps()
    let result = try await DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output)
    ).run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodePayloads(for: workflow)))

    XCTAssertEqual(result.status, .suspended)
    XCTAssertEqual(result.session.suspend?.stepId, "step-b")
    XCTAssertEqual(result.session.executions.first?.status, .completed)
    XCTAssertEqual(result.session.executions.first?.acceptedOutput?.payload, ["answer": .string("accepted")])
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["step-b"])
  }

  func testInvalidResumeStepAndMalformedEnvelopeFailClosed() async throws {
    let workflow = workflowWithTwoSteps()
    var mismatched = envelopeOutput()
    mismatched.payload["handover"] = .object([
      "reason": .string("userInputRequired"),
      "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])]),
      "resumeStepId": .string("not-selected")
    ])
    let mismatchStore = InMemoryWorkflowRuntimeStore()
    do {
      _ = try await DeterministicWorkflowRunner(store: mismatchStore, adapter: StaticAdapter(output: mismatched))
        .run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodePayloads(for: workflow)))
      XCTFail("expected invalid resume-step rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
    }
    let mismatchSession = await mismatchStore.latestSession(workflowId: "suspend-tests")
    XCTAssertEqual(mismatchSession?.status, .failed)

    var malformed = envelopeOutput()
    malformed.payload["handover"] = .object(["reason": .string("userInputRequired")])
    let malformedStore = InMemoryWorkflowRuntimeStore()
    do {
      _ = try await DeterministicWorkflowRunner(store: malformedStore, adapter: StaticAdapter(output: malformed))
        .run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: nodePayloads(for: workflow)))
      XCTFail("expected malformed envelope rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
    }
    let malformedSession = await malformedStore.latestSession(workflowId: "suspend-tests")
    XCTAssertEqual(malformedSession?.status, .failed)
  }

  func testNormalizedPayloadEnvelopeIsExtractedAfterOutputContractEnvelope() throws {
    let candidate = try normalizeRuntimeAdapterOutput(AdapterExecutionOutput(
      provider: "test",
      model: "fixture",
      promptText: "",
      completionPassed: true,
      payload: [
        "when": .object(["always": .bool(true)]),
        "payload": .object([
          "answer": .string("yes"),
          "handover": .object(["reason": .string("userInputRequired"),
                               "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])])])
        ])
      ]
    ))
    XCTAssertEqual(candidate.payload, ["answer": .string("yes")])
    XCTAssertEqual(candidate.handover?.question?.id, "q")
  }

  func testBoundaryHandoverSuspendsBeforeNextStepStarts() async throws {
    let workflow = workflowWithTwoSteps()
    let store = InMemoryWorkflowRuntimeStore()
    let request = DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      boundaryHandover: { nextStepId in
        SuspendRecord(reasonKind: .operatorMove, stepId: nextStepId, suspendedAt: Date(), producer: .runtime)
      }
    )
    let result = try await DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: plainOutput())).run(request)
    XCTAssertEqual(result.status, .suspended)
    XCTAssertEqual(result.session.suspend?.stepId, "step-b")
    XCTAssertEqual(result.session.executions.map(\.stepId), ["step-a"])
  }

  func testEnvelopeResumeStepOnFanoutTransitionFailsClosedWithoutPublishing() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = fanoutSuspendWorkflow()
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: FanoutSuspendAdapter(sourceResumeStepId: "branch"))
        .run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: fanoutSuspendPayloads()))
      XCTFail("expected fanout resume-step rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertTrue(error.message.contains("cannot target a fanout or cross-workflow dispatch transition"), error.message)
    }
    let latest = await store.latestSession(workflowId: "suspend-fanout")
    let session = try XCTUnwrap(latest)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.map(\.stepId), ["source"])
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testBoundaryHandoverIsNotInvokedAtFanoutBoundaryAndFiresAtNextOrdinaryBoundary() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = fanoutSuspendWorkflow()
    let calls = BoundaryCallRecorder()
    let request = DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: fanoutSuspendPayloads(),
      boundaryHandover: { nextStepId in
        await calls.record(nextStepId)
        return SuspendRecord(reasonKind: .operatorMove, stepId: nextStepId, suspendedAt: Date(), producer: .runtime)
      }
    )
    let result = try await DeterministicWorkflowRunner(store: store, adapter: FanoutSuspendAdapter(sourceResumeStepId: nil))
      .run(request)

    let recorded = await calls.all()
    XCTAssertEqual(recorded, ["tail"], "boundary hook must skip the fanout boundary (target: branch) and fire after the join")
    XCTAssertEqual(result.status, .suspended)
    XCTAssertEqual(result.session.suspend?.stepId, "tail")
    let stepIds = result.session.executions.map(\.stepId)
    XCTAssertTrue(stepIds.contains("source"), "\(stepIds)")
    XCTAssertTrue(stepIds.contains("join"), "\(stepIds)")
    XCTAssertFalse(stepIds.contains("tail"), "\(stepIds)")
  }

  private func fanoutSuspendPayloads() -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: ["source", "branch", "join", "tail"].map {
      ("\($0)-node", AgentNodePayload(id: "\($0)-node", executionBackend: .codexAgent, model: "fixture", agentSandbox: .readOnly))
    })
  }

  private func fanoutSuspendWorkflow() -> WorkflowDefinition {
    let fanout = WorkflowStepFanout(
      groupId: "group",
      itemsFrom: "/payload/items",
      itemVariable: "feature",
      concurrency: 2,
      joinStepId: "join",
      failurePolicy: .failFast,
      resultOrder: .input,
      writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)
    )
    let ids = ["source", "branch", "join", "tail"]
    return WorkflowDefinition(
      workflowId: "suspend-fanout",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "source",
      nodeRegistry: ids.map { WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(id: "source", nodeId: "source-node", transitions: [WorkflowStepTransition(toStepId: "branch", fanout: fanout)]),
        WorkflowStepRef(id: "branch", nodeId: "branch-node", transitions: [WorkflowStepTransition(toStepId: "join")]),
        WorkflowStepRef(id: "join", nodeId: "join-node", transitions: [WorkflowStepTransition(toStepId: "tail")]),
        WorkflowStepRef(id: "tail", nodeId: "tail-node")
      ],
      nodes: ids.map { WorkflowNodeRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") }
    )
  }

  private func request(eventHandler: WorkflowRunEventHandler? = nil) -> DeterministicWorkflowRunRequest {
    let workflow = workflowWithTwoSteps()
    return DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      eventHandler: eventHandler
    )
  }

  private func workflowWithTwoSteps() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "suspend-tests",
      defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 2),
      entryStepId: "step-a",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node-a"), WorkflowNodeRegistryRef(id: "node-b")],
      steps: [
        WorkflowStepRef(id: "step-a", nodeId: "node-a", transitions: [WorkflowStepTransition(toStepId: "step-b")]),
        WorkflowStepRef(id: "step-b", nodeId: "node-b")
      ],
      nodes: [WorkflowNodeRef(id: "step-a", nodeFile: "nodes/a.json"), WorkflowNodeRef(id: "step-b", nodeFile: "nodes/b.json")]
    )
  }

  private func nodePayloads(for workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: workflow.nodeRegistry.map {
      ($0.id, AgentNodePayload(id: $0.id, executionBackend: .codexAgent, model: "fixture", agentSandbox: .readOnly))
    })
  }

  private func envelopeOutput() -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "fixture",
      promptText: "",
      completionPassed: true,
      payload: [
        "answer": .string("accepted"),
        "handover": .object([
          "reason": .string("userInputRequired"),
          "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])])
        ])
      ]
    )
  }

  private func plainOutput() -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: "fixture", promptText: "", completionPassed: true, payload: ["answer": .string("done")])
  }
}

private actor BoundaryCallRecorder {
  private var calls: [String] = []

  func record(_ stepId: String) { calls.append(stepId) }

  func all() -> [String] { calls }
}

private struct FanoutSuspendAdapter: NodeAdapter {
  var sourceResumeStepId: String?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    var payload: JSONObject = ["status": .string("ok")]
    if input.node.id.hasPrefix("source") {
      payload = ["payload": .object(["items": .array([.object(["index": .integer(0)]), .object(["index": .integer(1)])])])]
      if let sourceResumeStepId {
        payload["handover"] = .object([
          "reason": .string("userInputRequired"),
          "question": .object(["id": .string("q"), "text": .string("Choose"), "options": .array([])]),
          "resumeStepId": .string(sourceResumeStepId)
        ])
      }
    }
    return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText, completionPassed: true, payload: payload)
  }
}
