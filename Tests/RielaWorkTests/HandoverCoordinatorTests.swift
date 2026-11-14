import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class HandoverCoordinatorTests: XCTestCase {
  func testSealPersistsPacketDecisionAndReconcilesPredecessor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Do",
      plan: .workflow(WorkflowReference(name: "flow")), state: .running)
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .running)
    try store.saveTask(task)
    try store.saveAttempt(attempt)
    let now = Date(timeIntervalSince1970: 10)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .suspended, entryStepId: "start", createdAt: now, updatedAt: now)
    let input = HandoverPacketBuilderInput(handoverId: HandoverID("handover-1"), task: task, attempt: attempt,
      reason: .operatorMove(reason: "capacity"), resumeStepId: "start", snapshot: WorkflowRuntimePersistenceSnapshot(session: session),
      workflow: WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 1), entryStepId: "start", nodeRegistry: [], steps: [], nodes: []),
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"), hostId: "host", producer: .runtime, now: now)
    let failingSink = FailingSink(store: store, packetId: input.handoverId)
    let packet = try await HandoverCoordinator(store: store, builder: HandoverPacketBuilder(store: store)).seal(
      HandoverSealRequest(builderInput: input, ownerAlive: true, sinks: [failingSink],
        decisionId: DecisionID("decision-1"), decisionProducer: .human(principal: "operator"),
        predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 1))
    XCTAssertEqual(try store.loadHandover(id: packet.id)?.digest, packet.digest)
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).count, 1)
    XCTAssertTrue(failingSink.observedSealedPacket)
    XCTAssertEqual(packet.sinks.map(\.kind), [.store])
    XCTAssertEqual(try store.listEvidence(taskId: task.id, kind: .publication).count, 1)
  }

  func testVersionConflictDoesNotSealOrCallSink() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-conflict"), intentId: IntentID("intent-conflict"), title: "Task", instruction: "Do",
      plan: .workflow(WorkflowReference(name: "flow")), state: .running)
    let attempt = Attempt(id: AttemptID("attempt-conflict"), taskId: task.id, sessionId: "session-conflict", state: .running)
    try store.saveTask(task)
    try store.saveAttempt(attempt)
    let now = Date(timeIntervalSince1970: 10)
    let input = HandoverPacketBuilderInput(handoverId: HandoverID("handover-conflict"), task: task, attempt: attempt,
      reason: .operatorMove(reason: "move"), resumeStepId: "start",
      snapshot: WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "flow", sessionId: attempt.sessionId,
        status: .suspended, entryStepId: "start", createdAt: now, updatedAt: now)),
      workflow: WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 1),
        entryStepId: "start", nodeRegistry: [], steps: [], nodes: []),
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"),
      hostId: "host", producer: .runtime, now: now)
    let sink = FailingSink(store: store, packetId: input.handoverId)
    do {
      _ = try await HandoverCoordinator(store: store, builder: HandoverPacketBuilder(store: store)).seal(
        HandoverSealRequest(builderInput: input, ownerAlive: true, sinks: [sink], decisionId: DecisionID("decision-conflict"),
          decisionProducer: .human(principal: "operator"), predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 2))
      XCTFail("stale task version should not seal")
    } catch {
      XCTAssertTrue(String(describing: error).contains("version"))
    }
    XCTAssertFalse(sink.observedSealedPacket)
    XCTAssertNil(try store.loadHandover(id: input.handoverId))
  }

  func testSealOrdersPublishBeforeStoreRowBeforeSinksAndPersistsSuccessfulSinkRefs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-order"), intentId: IntentID("intent-order"), title: "Task", instruction: "Do",
      plan: .workflow(WorkflowReference(name: "flow")), state: .running)
    let attempt = Attempt(id: AttemptID("attempt-order"), taskId: task.id, sessionId: "session-order", state: .running)
    try store.saveTask(task)
    try store.saveAttempt(attempt)
    let now = Date(timeIntervalSince1970: 10)
    let handoverId = HandoverID("handover-order")
    let input = HandoverPacketBuilderInput(handoverId: handoverId, task: task, attempt: attempt,
      reason: .operatorMove(reason: "move"), resumeStepId: "start",
      snapshot: WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "flow", sessionId: attempt.sessionId,
        status: .suspended, entryStepId: "start", createdAt: now, updatedAt: now)),
      workflow: WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 1),
        entryStepId: "start", nodeRegistry: [], steps: [], nodes: []),
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"),
      hostId: "host", producer: .runtime, now: now)
    let recorder = CallRecorder()
    let deliverable = DeliverableRef.localOnly(LocalOnlyDeliverable(kind: "note", path: "/tmp/order-deliverable.txt"))
    let publisher = RecordingPublisher(store: store, handoverId: handoverId, recorder: recorder, deliverable: deliverable)
    let fileSink = RecordingSink(kind: .file, store: store, handoverId: handoverId, recorder: recorder, failure: nil)
    let commandSink = RecordingSink(kind: .command, store: store, handoverId: handoverId, recorder: recorder,
      failure: WorkStoreError("intentional command sink failure"))
    let packet = try await HandoverCoordinator(store: store, builder: HandoverPacketBuilder(store: store)).seal(
      HandoverSealRequest(builderInput: input, publisher: publisher, ownerAlive: true, sinks: [fileSink, commandSink],
        decisionId: DecisionID("decision-order"), decisionProducer: .human(principal: "operator"),
        predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 1))
    XCTAssertEqual(recorder.calls, ["publish", "sink:file", "sink:command"])
    XCTAssertEqual(recorder.rowExistsAtCall, ["publish": false, "sink:file": true, "sink:command": true])
    XCTAssertTrue(packet.deliverables.contains(deliverable))
    XCTAssertEqual(packet.sinks.map(\.kind), [.store, .file])
    XCTAssertEqual(packet.sinks.first?.locator, "host/task-order/handover-order")
    let loaded = try XCTUnwrap(try store.loadHandover(id: handoverId))
    XCTAssertTrue(loaded.deliverables.contains(deliverable))
    XCTAssertEqual(loaded.sinks.map(\.kind), [.store, .file])
    XCTAssertEqual(loaded.sinks.first?.locator, "host/task-order/handover-order")
    XCTAssertEqual(loaded.digest, packet.digest)
    let publications = try store.listEvidence(taskId: task.id, kind: .publication)
    XCTAssertEqual(publications.count, 1)
    guard case .inline(let payload)? = publications.first?.payloadRef else { return XCTFail("expected inline publication payload") }
    XCTAssertEqual(payload["sink"], .string(HandoverSinkKind.command.rawValue))
  }
}

private final class FailingSink: HandoverSink, @unchecked Sendable {
  let store: WorkStore
  let packetId: HandoverID
  private(set) var observedSealedPacket = false
  let kind: HandoverSinkKind = .file

  init(store: WorkStore, packetId: HandoverID) { self.store = store; self.packetId = packetId }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    observedSealedPacket = try store.loadHandover(id: packetId) != nil
    throw WorkStoreError("intentional test sink failure")
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data { throw WorkStoreError("not implemented") }
}

private final class CallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCalls: [String] = []
  private var recordedRowExists: [String: Bool] = [:]

  var calls: [String] { lock.lock(); defer { lock.unlock() }; return recordedCalls }
  var rowExistsAtCall: [String: Bool] { lock.lock(); defer { lock.unlock() }; return recordedRowExists }

  func record(_ call: String, rowExists: Bool) {
    lock.lock(); defer { lock.unlock() }
    recordedCalls.append(call)
    recordedRowExists[call] = rowExists
  }
}

private final class RecordingPublisher: DeliverablePublisher, @unchecked Sendable {
  let store: WorkStore
  let handoverId: HandoverID
  let recorder: CallRecorder
  let deliverable: DeliverableRef

  init(store: WorkStore, handoverId: HandoverID, recorder: CallRecorder, deliverable: DeliverableRef) {
    self.store = store; self.handoverId = handoverId; self.recorder = recorder; self.deliverable = deliverable
  }

  func publish(task: WorkTask, attempt: Attempt, snapshot: WorkflowRuntimePersistenceSnapshot, ownerAlive: Bool) async -> [DeliverableRef] {
    recorder.record("publish", rowExists: (try? store.loadHandover(id: handoverId)) != nil)
    return [deliverable]
  }
}

private final class RecordingSink: HandoverSink, @unchecked Sendable {
  let kind: HandoverSinkKind
  let store: WorkStore
  let handoverId: HandoverID
  let recorder: CallRecorder
  let failure: WorkStoreError?

  init(kind: HandoverSinkKind, store: WorkStore, handoverId: HandoverID, recorder: CallRecorder, failure: WorkStoreError?) {
    self.kind = kind; self.store = store; self.handoverId = handoverId; self.recorder = recorder; self.failure = failure
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    recorder.record("sink:\(kind.rawValue)", rowExists: (try? store.loadHandover(id: handoverId)) != nil)
    if let failure { throw failure }
    return HandoverSinkRef(kind: kind, locator: "/tmp/order-sink.json", digest: packet.digest, writtenAt: Date(timeIntervalSince1970: 11))
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data { throw WorkStoreError("not implemented") }
}
