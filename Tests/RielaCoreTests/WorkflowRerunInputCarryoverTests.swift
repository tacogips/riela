import XCTest
@testable import RielaCore

final class WorkflowRerunInputCarryoverTests: XCTestCase {
  func testPlainRerunImportsTargetInboxWithNewCommunicationIdentity() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = carryoverWorkflow
    let failingTailAdapter = InboxCheckingAdapter(failTail: true)
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: failingTailAdapter
    ).run(request(workflow: workflow)))
    let maybeSource = await store.latestSession(workflowId: workflow.workflowId)
    let source = try XCTUnwrap(maybeSource)
    XCTAssertEqual(source.status, .failed)
    let sourceProducer = try XCTUnwrap(source.executions.first { $0.stepId == "checkpoint" })
    let sourceInbox = try XCTUnwrap(source.executions.first { $0.stepId == "consumer" }?.inputSnapshot?["mergedVariables"])
    let sourceCommunicationId = try XCTUnwrap(communicationId(in: sourceInbox))

    let adapter = InboxCheckingAdapter(failTail: false)
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      request(workflow: workflow, sourceSessionId: source.sessionId, targetStepId: "consumer"))
    let captured = await adapter.capturedConsumerInput()
    XCTAssertEqual(result.session.executions.map(\.stepId), ["checkpoint", "consumer", "tail"])
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.first?.importedFrom?.sessionId, source.sessionId)
    XCTAssertEqual(result.session.executions.first?.importedFrom?.executionId, sourceProducer.executionId)
    XCTAssertNil(result.session.executions[1].importedFrom)
    XCTAssertEqual(result.session.newExecutionCount, 2)
    let newInbox = try XCTUnwrap(captured?.mergedVariables["_rielaInput"])
    let newCommunicationId = try XCTUnwrap(communicationId(in: .object(["_rielaInput": newInbox])))
    XCTAssertNotEqual(newCommunicationId, sourceCommunicationId)
    XCTAssertEqual(result.session.executions.first?.importedFrom?.communicationIds[newCommunicationId], sourceCommunicationId)
    XCTAssertEqual(result.session.newExecutionCount, 2, "imported checkpoint execution is not a new execution")
  }

  func testCompletedSourceCanCarryTargetInbox() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = carryoverWorkflow
    let completed = try await DeterministicWorkflowRunner(
      store: store, adapter: InboxCheckingAdapter(failTail: false)
    ).run(request(workflow: workflow))
    XCTAssertEqual(completed.status, .completed)

    let rerun = try await DeterministicWorkflowRunner(
      store: store, adapter: InboxCheckingAdapter(failTail: false)
    ).run(request(workflow: workflow, sourceSessionId: completed.session.sessionId, targetStepId: "consumer"))
    XCTAssertEqual(rerun.status, .completed)
    XCTAssertEqual(rerun.session.executions.first?.importedFrom?.sessionId, completed.session.sessionId)
  }

  func testUnexecutedTargetCarriesNothing() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = carryoverWorkflow
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: FailingAdapter()
    ).run(request(workflow: workflow)))
    let maybeSource = await store.latestSession(workflowId: workflow.workflowId)
    let source = try XCTUnwrap(maybeSource)
    XCTAssertFalse(source.executions.contains { $0.stepId == "tail" })

    let result = try await DeterministicWorkflowRunner(
      store: store, adapter: InboxCheckingAdapter(failTail: false)
    ).run(request(workflow: workflow, sourceSessionId: source.sessionId, targetStepId: "tail"))
    XCTAssertEqual(result.status, .completed)
    XCTAssertTrue(result.session.executions.allSatisfy { $0.importedFrom == nil })
  }

  func testInboxFromNonExecutionProducerIsSkipped() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let date = Date(timeIntervalSince1970: 100)
    let source = WorkflowSession(
      workflowId: "rerun-carryover", sessionId: "non-execution-source", status: .failed,
      entryStepId: "consumer", currentStepId: "consumer", createdAt: date, updatedAt: date,
      executions: [WorkflowStepExecution(
        executionId: "failed-consumer", stepId: "consumer", nodeId: "consumer", attempt: 1,
        inputSnapshot: ["mergedVariables": .object(["_rielaInput": .object([
          "communicationIds": .array([.string("event-communication")])
        ])])],
        status: .failed, createdAt: date, updatedAt: date
      )]
    )
    await store.seedSession(source)
    await store.seedWorkflowMessages([WorkflowMessageRecord(
      communicationId: "event-communication", workflowExecutionId: source.sessionId,
      fromStepId: nil, toStepId: "consumer", sourceStepExecutionId: "event-injection",
      payload: ["answer": .string("external")], lifecycleStatus: .delivered,
      createdOrder: 1, createdAt: date
    )])

    let input = try await DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: AdapterExecutionOutput(
      provider: "test", model: "fixture", promptText: "prompt", completionPassed: true,
      payload: ["answer": .string("ready")]
    ))).rerunCarriedInbox(source: source, targetStepId: "consumer")
    XCTAssertNil(input)
  }

  func testMissingRecordedCommunicationIsRejectedBeforeSessionCreation() async throws {
    let source = try await failedSource().session
    let store = InMemoryWorkflowRuntimeStore()
    await store.seedSession(source)

    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: InboxCheckingAdapter(failTail: false)).run(
        request(workflow: carryoverWorkflow, sourceSessionId: source.sessionId, targetStepId: "consumer"))
      XCTFail("missing recorded inbox evidence must be rejected")
    } catch {
      XCTAssertTrue(String(describing: error).contains(
        "cannot carry rerun input: recorded inbox communication"))
      XCTAssertTrue(String(describing: error).contains("is missing or unaccepted; use --preserve-history or rerun an earlier step"))
    }
    let latest = await store.latestSession(workflowId: carryoverWorkflow.workflowId)
    XCTAssertEqual(latest?.sessionId, source.sessionId)
  }

  func testUnacceptedRecordedCommunicationIsRejectedBeforeSessionCreation() async throws {
    let fixture = try await failedSource()
    let source = fixture.session
    var superseded = try XCTUnwrap(fixture.messages.first { $0.toStepId == "consumer" })
    superseded.lifecycleStatus = .superseded
    let store = InMemoryWorkflowRuntimeStore()
    await store.seedSession(source)
    await store.seedWorkflowMessages([superseded])

    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: InboxCheckingAdapter(failTail: false)).run(
        request(workflow: carryoverWorkflow, sourceSessionId: source.sessionId, targetStepId: "consumer"))
      XCTFail("superseded inbox evidence must be rejected")
    } catch {
      XCTAssertTrue(String(describing: error).contains("is missing or unaccepted"))
    }
    let latest = await store.latestSession(workflowId: carryoverWorkflow.workflowId)
    XCTAssertEqual(latest?.sessionId, source.sessionId)
  }

  func testRunningSourceIsRejectedBeforeSessionCreation() async throws {
    var source = try await failedSource().session
    source.status = .running
    let store = InMemoryWorkflowRuntimeStore()
    await store.seedSession(source)

    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: InboxCheckingAdapter(failTail: false)).run(
        request(workflow: carryoverWorkflow, sourceSessionId: source.sessionId, targetStepId: "consumer"))
      XCTFail("running source must be rejected")
    } catch {
      XCTAssertTrue(String(describing: error).contains(
        "rerun source session must be failed, suspended or completed"))
    }
    let latest = await store.latestSession(workflowId: carryoverWorkflow.workflowId)
    XCTAssertEqual(latest?.sessionId, source.sessionId)
  }

  private func failedSource() async throws -> (session: WorkflowSession, messages: [WorkflowMessageRecord]) {
    let store = InMemoryWorkflowRuntimeStore()
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: InboxCheckingAdapter(failTail: true)
    ).run(request(workflow: carryoverWorkflow)))
    let latest = await store.latestSession(workflowId: carryoverWorkflow.workflowId)
    let session = try XCTUnwrap(latest)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    return (session, messages)
  }

  private var carryoverWorkflow: WorkflowDefinition {
    let stepIds = ["checkpoint", "consumer", "tail"]
    return WorkflowDefinition(
      workflowId: "rerun-carryover",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 2),
      entryStepId: "checkpoint",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "\($0).json") },
      steps: stepIds.enumerated().map { index, stepId in
        WorkflowStepRef(id: stepId, nodeId: stepId,
          transitions: index + 1 < stepIds.count ? [WorkflowStepTransition(toStepId: stepIds[index + 1])] : nil)
      },
      nodes: stepIds.map { WorkflowNodeRef(id: $0, nodeFile: "\($0).json") }
    )
  }

  private func request(workflow: WorkflowDefinition, sourceSessionId: String? = nil, targetStepId: String? = nil)
    -> DeterministicWorkflowRunRequest {
    let nodePayloads = Dictionary(uniqueKeysWithValues: ["checkpoint", "consumer", "tail"].map { id in
      (id, AgentNodePayload(id: id, model: "fixture", output: NodeOutputContract(
        jsonSchema: ["type": .string("object"), "required": .array([.string("answer")])]
      )))
    })
    return DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads,
      rerunFromSessionId: sourceSessionId,
      rerunFromStepId: targetStepId
    )
  }

  private func communicationId(in snapshot: JSONValue) -> String? {
    guard case let .object(values) = snapshot,
          case let .object(rielaInput)? = values["_rielaInput"],
          case let .array(ids)? = rielaInput["communicationIds"],
          case let .string(id)? = ids.first else {
      return nil
    }
    return id
  }
}

private actor InboxCheckingAdapter: NodeAdapter {
  private let failTail: Bool
  private var consumerInput: AdapterExecutionInput?

  init(failTail: Bool) {
    self.failTail = failTail
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "consumer" {
      consumerInput = input
      guard case let .object(inbox)? = input.mergedVariables["_rielaInput"],
            case let .array(messages)? = inbox["messages"], messages.count == 1 else {
        throw AdapterExecutionError(.invalidInput, "consumer requires exactly one checkpoint message")
      }
    }
    if input.node.id == "tail", failTail {
      throw AdapterExecutionError(.providerError, "tail failure")
    }
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: ["answer": .string("ready")]
    )
  }

  func capturedConsumerInput() -> AdapterExecutionInput? {
    consumerInput
  }
}
