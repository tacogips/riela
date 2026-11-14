import XCTest
@testable import RielaCore

final class FanoutResumeTests: XCTestCase {
  func testCollectPartialPreservesSuspendedChildAndContinuesSameReservation() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-suspended-resume/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore()
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let adapter = FanoutSuspendingAdapter(tracker: tracker)
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter,
      nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path))
    let workflow = fanoutWorkflow(concurrency: 2, failurePolicy: .collectPartial)
    do {
      _ = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads()))
      XCTFail("a suspended child must not be published as a failed item")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .fanoutDispatchPending(_, childId, status) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(status, .suspended)
      let child = try await store.loadSession(id: childId)
      XCTAssertEqual(child?.status, .suspended)
    }
    let latest = await store.latestSession(workflowId: workflow.workflowId)
    let latestSession = try XCTUnwrap(latest)
    let loadedParent = try await store.loadSession(id: latestSession.parentSessionId ?? latestSession.sessionId)
    let parent = try XCTUnwrap(loadedParent)
    XCTAssertEqual(parent.status, .running)
    let firstJoin = await tracker.joinRuntimeFanout()
    XCTAssertNil(firstJoin)
    let resumed = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads(),
      resumeSessionId: parent.sessionId))
    XCTAssertEqual(resumed.status, .completed)
    let identities = await tracker.branchIdentities()
    XCTAssertEqual(identities.count, 3, "completed siblings must not repeat while a suspended child resumes")
  }

  func testCollectPartialDoesNotSealBudgetExhaustedChildrenAndResumesWithoutRepeatingEffects() async throws {
    try await assertBudgetResume(failurePolicy: .collectPartial)
  }

  func testFailFastDoesNotCancelSiblingsOfBudgetExhaustedChild() async throws {
    try await assertBudgetResume(failurePolicy: .failFast)
  }

  private func assertBudgetResume(failurePolicy: WorkflowFanoutFailurePolicy) async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-budget-resume/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let runner = DeterministicWorkflowRunner(store: store, adapter: FanoutTestAdapter(tracker: tracker),
      nestedInvocationPersistenceStore: persistence)
    var workflow = fanoutWorkflow(concurrency: 2, failurePolicy: failurePolicy)
    workflow.steps[1].transitions = [WorkflowStepTransition(toStepId: "continuation")]
    workflow.steps.append(WorkflowStepRef(id: "continuation", nodeId: "join-node",
      transitions: [WorkflowStepTransition(toStepId: "join")]))
    do {
      _ = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads(), maxSteps: 1))
      XCTFail("unfinished children must not reach the join")
    } catch {
      XCTAssertEqual(error as? DeterministicWorkflowRunnerError, .maxStepsExceeded(1))
    }
    let latest = await store.latestSession(workflowId: workflow.workflowId)
    let latestSession = try XCTUnwrap(latest)
    let loadedParent = try await store.loadSession(id: latestSession.parentSessionId ?? latestSession.sessionId)
    let parent = try XCTUnwrap(loadedParent)
    XCTAssertEqual(parent.failureKind, .maxStepsExceeded)
    let records = try persistence.nestedInvocationRecords(parentSessionId: parent.sessionId)
    XCTAssertEqual(records.count, 3)
    for record in records {
      XCTAssertNil(record.childTerminalSnapshot, "budget exhaustion must not seal a terminal receipt")
      XCTAssertNil(record.parentMessage)
      let child = try persistence.load(sessionId: record.reservation.childSnapshot.session.sessionId)
      XCTAssertEqual(child.session.failureKind, .maxStepsExceeded)
    }
    let firstJoin = await tracker.joinRuntimeFanout()
    XCTAssertNil(firstJoin)
    let before = await tracker.branchIdentities()
    XCTAssertEqual(before.count, 3, "a pending child must not cancel or skip siblings")
    let resumed = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads(),
      maxSteps: 8, resumeSessionId: parent.sessionId))
    XCTAssertEqual(resumed.status, .completed)
    let after = await tracker.branchIdentities()
    XCTAssertEqual(after.count, before.count, "accepted child effects must not be repeated")
    let finalRecords = try persistence.nestedInvocationRecords(parentSessionId: parent.sessionId)
    XCTAssertTrue(finalRecords.allSatisfy { $0.phase == .delivered && $0.childTerminalSnapshot?.session.status == .completed })
  }

  func testCancellationAfterReservationDoesNotBecomePendingOrPublishPartialJoin() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let runner = DeterministicWorkflowRunner(store: store, adapter: FanoutTestAdapter(tracker: tracker))
    let workflow = fanoutWorkflow(concurrency: 2, failurePolicy: .collectPartial)
    do {
      _ = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads(),
        sessionExecutionAdmission: { identity in
          if identity.hasPrefix("nested-v1-") { throw CancellationError() }
        }))
      XCTFail("real cancellation must propagate")
    } catch {
      XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
    }
    let latest = await store.latestSession(workflowId: workflow.workflowId)
    let latestSession = try XCTUnwrap(latest)
    let loadedParent = try await store.loadSession(id: latestSession.parentSessionId ?? latestSession.sessionId)
    let parent = try XCTUnwrap(loadedParent)
    XCTAssertEqual(parent.status, .cancelled)
    let join = await tracker.joinRuntimeFanout()
    XCTAssertNil(join)
  }

}

private actor FanoutSuspendingAdapter: NodeAdapter {
  let tracker: FanoutBranchTracker
  private var shouldSuspend = true

  init(tracker: FanoutBranchTracker) { self.tracker = tracker }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "branch", shouldSuspend,
       case let .object(item)? = input.arguments["feature"], item["index"] == .integer(1) {
      shouldSuspend = false
      return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
        completionPassed: true, payload: ["handover": .object([
          "reason": .string("userInputRequired"),
          "question": .object(["id": .string("question"), "text": .string("Continue?"), "options": .array([])])
        ])])
    }
    return try await FanoutTestAdapter(tracker: tracker).execute(input, context: context)
  }
}

extension FanoutResumeTests {
  func testIncludedStepOutputsUseAcceptedChildPayloadsAndPreserveAbsentShape() async throws {
    for include in [false, true] {
      let tracker = FanoutBranchTracker(delaysByIndex: [:])
      let store = InMemoryWorkflowRuntimeStore()
      var workflow = fanoutWorkflow(concurrency: 2)
      workflow.steps[1].transitions = [WorkflowStepTransition(toStepId: "continuation")]
      workflow.steps.append(WorkflowStepRef(id: "continuation", nodeId: "join-node",
        transitions: [WorkflowStepTransition(toStepId: "join")]))
      workflow.steps.append(WorkflowStepRef(id: "never", nodeId: "branch-node"))
      if include { workflow.steps[0].transitions?[0].fanout?.includeStepOutputs = ["branch", "continuation", "never"] }
      let fanout = try XCTUnwrap(workflow.steps[0].transitions?.first?.fanout)
      let encoded = try JSONEncoder().encode(fanout)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertEqual(object["includeStepOutputs"] != nil, include)
      _ = try await DeterministicWorkflowRunner(store: store, adapter: FanoutTestAdapter(tracker: tracker))
        .run(.init(workflow: workflow, nodePayloads: fanoutPayloads()))
      let captured = await tracker.joinRuntimeFanout()
      let join = try XCTUnwrap(captured)
      guard case let .array(branches)? = join["branches"] else { return XCTFail("missing branches") }
      for branch in branches {
        guard case let .object(record) = branch, case let .string(id)? = record["sessionId"] else {
          return XCTFail("missing branch session")
        }
        if include {
          let child = try await store.loadSession(id: id)
          let payload = try XCTUnwrap(child?.executions.last(where: { $0.stepId == "branch" })?.acceptedOutput?.payload)
          let continuation = try XCTUnwrap(child?.executions.last(where: { $0.stepId == "continuation" })?.acceptedOutput?.payload)
          XCTAssertEqual(record["stepOutputs"], .object(["branch": .object(payload), "continuation": .object(continuation)]))
        } else {
          XCTAssertEqual(Set(record.keys), Set(["index", "item", "status", "output", "sessionId", "branchId"]))
        }
      }
    }
  }
}

extension FanoutResumeTests {
  func testIncludedStepOutputsValidation() throws {
    for ids in [[String](), [""], ["branch", "branch"], ["missing"], ["join"]] {
      var workflow = fanoutWorkflow(concurrency: 1)
      workflow.steps[0].transitions?[0].fanout?.includeStepOutputs = ids
      let diagnostics = DefaultWorkflowValidator().validate(workflow)
      XCTAssertTrue(diagnostics.contains { $0.path.contains("includeStepOutputs") && $0.severity == .error }, "\(ids)")
    }
    var workflow = fanoutWorkflow(concurrency: 1, toWorkflowId: "callee")
    workflow.steps[0].transitions?[0].fanout?.includeStepOutputs = ["callee-only"]
    XCTAssertFalse(DefaultWorkflowValidator().validate(workflow).contains { $0.path.contains("includeStepOutputs") })
  }
}

extension FanoutResumeTests {
  func testIncludedOutputLimitStopsJoinPublication() async throws {
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let store = InMemoryWorkflowRuntimeStore()
    var workflow = fanoutWorkflow(concurrency: 1)
    workflow.steps[0].transitions?[0].fanout?.includeStepOutputs = ["branch"]
    let runner = DeterministicWorkflowRunner(store: store, adapter: LargeFanoutOutputAdapter(tracker: tracker))
    do {
      _ = try await runner.run(.init(workflow: workflow, nodePayloads: fanoutPayloads()))
      XCTFail("expected size failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .fanoutDispatchFailed(_, reason) = error else { return XCTFail("unexpected error: \(error)") }
      XCTAssertTrue(reason.contains("branch 0 step 'branch'"))
    }
    let captured = await tracker.joinRuntimeFanout()
    XCTAssertNil(captured)
    let parent = await store.latestSession(workflowId: workflow.workflowId)
    let parentId = try XCTUnwrap(parent?.sessionId)
    let messages = try await store.listMessages(for: parentId, toStepId: "join")
    XCTAssertFalse(messages.contains { $0.payload["fanoutJoin"] != nil })
  }

}

private struct LargeFanoutOutputAdapter: NodeAdapter {
  let tracker: FanoutBranchTracker
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    var output = try await FanoutTestAdapter(tracker: tracker).execute(input, context: context)
    if input.node.id == "branch" { output.payload["large"] = .string(String(repeating: "x", count: 8_000_001)) }
    return output
  }
}

extension FanoutResumeTests {
  func testRawFanoutOutputSelectionRejectsWrongShape() {
    let raw: [String: Any] = ["nodes": [["id": "source", "nodeFile": "source.json"]],
      "steps": [["id": "source", "nodeId": "source", "transitions": [[
      "toStepId": "branch", "fanout": ["groupId": "group", "itemsFrom": "/items", "joinStepId": "join",
        "includeStepOutputs": "branch"]
    ]]]]]
    let diagnostics = validateRawAuthoredWorkflow(raw)
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix("fanout.includeStepOutputs") })
  }
}

extension FanoutResumeTests {
  func testIncludedOutputsRebuildIdenticalJoinAcrossTerminalRecovery() async throws {
    for mode in 0...2 {
      let uninterrupted = try await includedOutputJoin(mode: mode, interrupt: false)
      let resumed = try await includedOutputJoin(mode: mode, interrupt: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      XCTAssertEqual(try encoder.encode(uninterrupted), try encoder.encode(resumed), "mode \(mode)")
    }
  }

  private func includedOutputJoin(mode: Int, interrupt: Bool) async throws -> JSONObject {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore()
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let adapter = FanoutTestAdapter(tracker: tracker)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let payloads = fanoutPayloads()
    let callee = WorkflowDefinition(workflowId: "fanout-callee",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "branch",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "branch-node", nodeFile: "nodes/branch.json")],
      steps: [WorkflowStepRef(id: "branch", nodeId: "branch-node")],
      nodes: [WorkflowNodeRef(id: "branch-node", nodeFile: "nodes/branch.json")])
    let resolver = OutputRecoveryResolver(callee: .init(workflow: callee,
      nodePayloads: ["branch-node": try XCTUnwrap(payloads["branch-node"])]))
    var workflow = fanoutWorkflow(concurrency: 1, toWorkflowId: mode == 0 ? nil : "fanout-callee")
    workflow.steps[0].transitions?[0].fanout?.includeStepOutputs = ["branch"]
    if mode == 2 { workflow.steps[0].transitions?[0].resumeStepId = nil }
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, calleeResolver: resolver,
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: interrupt ? OutputRecoveryCheckpoint() : nil)
    let parentId: String
    if interrupt {
      await XCTAssertThrowsErrorAsync(try await runner.run(.init(workflow: workflow, nodePayloads: payloads)))
      parentId = "fanout-runner-session-1"
      let parent = try await store.loadSession(id: parentId)
      XCTAssertNotNil(parent)
      let resumed = try await DeterministicWorkflowRunner(store: store, adapter: adapter, calleeResolver: resolver,
        nestedInvocationPersistenceStore: persistence).run(
          .init(workflow: workflow, nodePayloads: payloads, resumeSessionId: parentId))
      XCTAssertEqual(resumed.status, .completed)
    } else {
      let result = try await runner.run(.init(workflow: workflow, nodePayloads: payloads))
      XCTAssertEqual(result.status, .completed)
      parentId = result.session.sessionId
    }
    let messages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: parentId, toStepId: "join")
    XCTAssertEqual(messages.count, 1)
    guard case let .object(join)? = messages.first?.payload["fanoutJoin"],
          case let .array(branches)? = join["branches"] else { throw NSError(domain: "missing join", code: 1) }
    XCTAssertEqual(branches.count, 3)
    for branch in branches {
      guard case let .object(record) = branch, case let .string(id)? = record["sessionId"] else {
        throw NSError(domain: "missing branch", code: 1)
      }
      let child = try await store.loadSession(id: id)
      if mode != 0 { XCTAssertEqual(child?.workflowId, "fanout-callee") }
      let payload = try XCTUnwrap(child?.executions.last(where: { $0.stepId == "branch" })?.acceptedOutput?.payload)
      XCTAssertEqual(record["stepOutputs"], .object(["branch": .object(payload)]))
    }
    return join
  }
}

private struct OutputRecoveryCheckpoint: NestedRecoveryCheckpointing {
  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    if checkpoint == .childTerminalPersisted { throw NestedRecoveryInterruption() }
  }
}

private struct OutputRecoveryResolver: WorkflowCalleeResolving {
  let callee: ResolvedWorkflowCallee
  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee { callee }
}
