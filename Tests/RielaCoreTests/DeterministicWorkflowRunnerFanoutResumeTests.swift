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
