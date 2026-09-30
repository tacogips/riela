import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class WorkStoreTakeoverTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-work-takeover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testUnclaimedHandoverBlocksStartReservationAndPreview() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .waiting
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    try store.saveHandover(try packet().sealed())

    let result = try store.reserveAttempt(reservation(task: task))
    XCTAssertEqual(result, .wait(.handover(HandoverID("handover-1"))))
    XCTAssertEqual(try TaskDispatcher(store: store).preview(
      taskId: task.id, workflowId: "flow", entryStepId: "start", entry: .start,
      placement: BackendCapabilityPlacementResult(choices: [], failures: [])
    ), .wait(.handover(HandoverID("handover-1"))))
    XCTAssertTrue(try store.listAttempts(taskId: task.id).allSatisfy { $0.id == AttemptID("attempt-1") })
  }

  func testAnswerValidatesAndReplaySchedulesAnswerBackedTakeover() throws {
    let store = WorkStore(rootDirectory: root.path)
    let question = HandoverQuestion(
      id: "confirm", text: "Proceed?",
      answerSchema: [
        "type": .string("object"), "required": .array([.string("approved")]),
        "properties": .object(["approved": .object(["type": .string("boolean")])])
      ]
    )
    try setupHandover(store, reason: .userInputRequired(question))
    let answer = ["approved": JSONValue.bool(true)]
    XCTAssertThrowsError(try store.recordAnswer(
      taskId: TaskID("task-1"), questionId: "wrong", payload: answer,
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-bad-question"), now: fixedNow
    ))
    XCTAssertThrowsError(try store.recordAnswer(
      taskId: TaskID("task-1"), questionId: "confirm", payload: ["approved": .string("yes")],
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-bad-schema"), now: fixedNow
    ))
    let changed = try store.recordAnswer(
      taskId: TaskID("task-1"), questionId: "confirm", payload: answer,
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-1"), now: fixedNow
    )
    XCTAssertEqual(changed.state, .scheduled)
    XCTAssertEqual(try store.latestAnswer(handoverId: HandoverID("handover-1"))?.payload, answer)
    XCTAssertEqual(try store.listDecisions(taskId: changed.id).filter {
      if case .answer = $0.kind { return true }; return false
    }.count, 1)
    let replay = try store.recordAnswer(
      taskId: TaskID("task-1"), questionId: "confirm", payload: answer,
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-1"), now: fixedNow.addingTimeInterval(1)
    )
    XCTAssertEqual(replay, changed)

    let pending = try XCTUnwrap(TaskDispatcher(store: store).pendingReservation(taskId: changed.id))
    XCTAssertEqual(pending.entry, .takeover(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("handover-1")))
    var request = reservation(task: changed, entry: pending.entry, decisionId: pending.decisionId)
    request.pendingRequestId = pending.id
    let reserved = try store.reserveAttempt(request)
    guard case let .reserved(value) = reserved else { return XCTFail("expected takeover reservation") }
    XCTAssertEqual(value.decision.kind, .answer(try XCTUnwrap(try store.latestAnswer(handoverId: HandoverID("handover-1")))))
    XCTAssertEqual(value.attempt.takeoverLineage?.hops, 1)
  }

  func testTakeoverDecisionReservesAndAttachesSuccessorWithLineageAndLeaseFence() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Be present")))
    let placement = TakeoverPlacement(hostId: "reachable-host", requiredTraits: [.userReachable])
    let task = try store.requestTakeover(
      taskId: TaskID("task-1"), placement: placement, producer: .human(principal: "operator"),
      decisionId: DecisionID("takeover-1"), now: fixedNow
    )
    let pending = try XCTUnwrap(TaskDispatcher(store: store).pendingReservation(taskId: task.id))
    var request = reservation(task: task, entry: pending.entry, decisionId: pending.decisionId)
    request.pendingRequestId = pending.id
    let result = try store.reserveAttempt(request)
    guard case let .reserved(value) = result else { return XCTFail("expected takeover reservation") }
    XCTAssertEqual(value.decision.kind, .takeover(handoverId: HandoverID("handover-1"), placement: placement))
    XCTAssertEqual(value.attempt.takeoverLineage, TakeoverLineage(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("handover-1"), hops: 1))
    XCTAssertEqual(value.task.fence, 1)
    XCTAssertEqual(try store.loadLease(attemptId: value.attempt.id)?.fence, value.task.fence)
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).load(sessionId: value.attempt.sessionId).session.entryStepId, "next")
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT successor_attempt_id FROM work_handovers WHERE handover_id = 'handover-1'").first?["successor_attempt_id"], value.attempt.id.rawValue)
  }

  func testReservationDecisionResolvesPendingTakeoverDecisionForSuccessor() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Be present")))
    let placement = TakeoverPlacement(hostId: "reachable-host", requiredTraits: [.userReachable])
    let task = try store.requestTakeover(
      taskId: TaskID("task-1"), placement: placement, producer: .human(principal: "operator"),
      decisionId: DecisionID("takeover-1"), now: fixedNow
    )
    let pending = try XCTUnwrap(TaskDispatcher(store: store).pendingReservation(taskId: task.id))
    var request = reservation(task: task, entry: pending.entry, decisionId: pending.decisionId)
    request.pendingRequestId = pending.id
    guard case let .reserved(value) = try store.reserveAttempt(request) else {
      return XCTFail("expected takeover reservation")
    }

    XCTAssertNotEqual(value.decision.attemptId, value.attempt.id)
    XCTAssertEqual(try store.reservationDecision(attemptId: value.attempt.id), value.decision)
  }

  func testSecondTakeoverForSameHandoverIsRefused() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Be present")))
    let placement = TakeoverPlacement(hostId: "reachable-host", requiredTraits: [.userReachable])
    let task = try store.requestTakeover(
      taskId: TaskID("task-1"), placement: placement, producer: .human(principal: "operator"),
      decisionId: DecisionID("takeover-1"), now: fixedNow
    )
    let pending = try XCTUnwrap(TaskDispatcher(store: store).pendingReservation(taskId: task.id))
    var request = reservation(task: task, entry: pending.entry, decisionId: pending.decisionId)
    request.pendingRequestId = pending.id
    guard case let .reserved(first) = try store.reserveAttempt(request) else { return XCTFail("expected takeover reservation") }

    XCTAssertThrowsError(try store.requestTakeover(
      taskId: task.id, placement: placement, producer: .human(principal: "operator"),
      decisionId: DecisionID("takeover-2"), now: fixedNow.addingTimeInterval(1)
    ))

    let current = try XCTUnwrap(try store.loadTask(id: task.id))
    var second = reservation(
      task: current, entry: .takeover(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("handover-1")),
      decisionId: DecisionID("takeover-2-reserve"), now: fixedNow.addingTimeInterval(2)
    )
    second.attemptId = AttemptID("attempt-second")
    second.sessionId = "session-second"
    second.pendingRequestId = pending.id
    XCTAssertThrowsError(try store.reserveAttempt(second))

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(
      try database.query("SELECT successor_attempt_id FROM work_handovers WHERE handover_id = 'handover-1'").first?["successor_attempt_id"],
      first.attempt.id.rawValue
    )
    XCTAssertFalse(try store.listAttempts(taskId: task.id).contains { $0.id == AttemptID("attempt-second") })
  }

  func testRequestTakeoverRequiresAnswerForUnansweredQuestion() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userInputRequired(HandoverQuestion(id: "q-1", text: "Need input")))
    XCTAssertThrowsError(try store.requestTakeover(
      taskId: TaskID("task-1"), placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-1"), now: fixedNow
    )) { error in XCTAssertTrue(String(describing: error).contains("needs an answer")) }
    XCTAssertEqual(try store.loadTask(id: TaskID("task-1"))?.state, .waiting)
  }

  func testRequestTakeoverRefusesCheckpointFailedRepositoryWithoutReservation() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .waiting
    task.context = .repository(RepositoryContext(root: "/tmp/repository"))
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    var sealedPacket = packet()
    sealedPacket.deliverables = [.repository(RepositoryDeliverable(
      root: "/tmp/repository", remote: "origin", branch: "riela/task/task-1/g1",
      baseRevision: "base", state: .checkpointFailed(reason: "remote unreachable")
    ))]
    try store.saveHandover(try sealedPacket.sealed())

    XCTAssertThrowsError(try store.requestTakeover(
      taskId: task.id, placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-refused"), now: fixedNow
    )) { error in XCTAssertTrue(String(describing: error).contains("checkpoint failed: remote unreachable")) }
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertFalse(try store.listDecisions(taskId: task.id).contains { if case .takeover = $0.kind { return true }; return false })
    XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))
  }

  func testRequestTakeoverAcceptsUnpublishedRepositoryDeliverable() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .waiting
    task.context = .repository(RepositoryContext(root: "/tmp/repository"))
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    var sealedPacket = packet()
    sealedPacket.deliverables = [.repository(RepositoryDeliverable(
      root: "/tmp/repository", remote: "origin", branch: "riela/task/task-1/g1",
      baseRevision: "base", state: .unpublished(lastKnown: nil)
    ))]
    try store.saveHandover(try sealedPacket.sealed())

    let changed = try store.requestTakeover(
      taskId: task.id, placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-unpublished"), now: fixedNow
    )
    XCTAssertEqual(changed.state, .scheduled)
    XCTAssertEqual(try TaskDispatcher(store: store).pendingReservation(taskId: task.id)?.entry,
                   .takeover(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("handover-1")))
  }

  func testRequestTakeoverRefusesTerminalTask() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Be present")))
    var cancelled = try XCTUnwrap(store.loadTask(id: TaskID("task-1")))
    cancelled.state = .cancelled
    cancelled.version += 1
    try store.saveTask(cancelled)
    XCTAssertThrowsError(try store.requestTakeover(
      taskId: TaskID("task-1"), placement: TakeoverPlacement(hostId: "reachable-host", requiredTraits: [.userReachable]),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-1"), now: fixedNow
    )) { error in XCTAssertTrue(String(describing: error).contains("cannot be taken over")) }
    XCTAssertEqual(try store.loadTask(id: TaskID("task-1"))?.state, .cancelled)
    XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: TaskID("task-1")))
  }

  func testLiveHandoverDecisionCancellationPersistsAndAcknowledges() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reserved = try store.reserveAttempt(reservation(task: sampleTask()))
    let attemptId = reserved.attempt.id
    _ = try store.authorizeAttemptLaunch(attemptId: attemptId, launchToken: reserved.launchToken)
    let evidenceId = EvidenceID("evidence-live-handover")
    try store.saveEvidence(Evidence(
      id: evidenceId, taskId: reserved.task.id, attemptId: attemptId,
      kind: .contextSnapshot, producedBy: .runtime,
      payloadRef: .inline(["reason": .string("handover")]), createdAt: fixedNow
    ))
    let decision = Decision(
      id: DecisionID("decision-live-handover"), taskId: reserved.task.id, attemptId: attemptId,
      producer: .human(principal: "operator"), kind: .handover(.operatorMove(reason: "move")),
      reason: "hand over live run", causedBy: [evidenceId], createdAt: fixedNow
    )
    _ = try store.applyDecision(
      decision, expectedTaskVersion: reserved.task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("evidence-decision-live-handover")
    )
    let pending = try XCTUnwrap(store.attemptCancellation(
      taskId: reserved.task.id, attemptId: attemptId, sessionId: reserved.attempt.sessionId
    ))
    XCTAssertFalse(pending.acknowledged)

    let snapshot = try XCTUnwrap(store.persistJoinedCancellation(
      taskId: reserved.task.id, attemptId: attemptId, sessionId: reserved.attempt.sessionId,
      selectedHostStopProven: true
    ))
    XCTAssertEqual(snapshot.session.status, .failed)
    let attempt = try store.acknowledgeAttemptCancellation(
      attemptId: attemptId, outcome: WorkEvidenceProjector.outcome(from: snapshot)
    )
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertEqual(try store.loadTask(id: reserved.task.id)?.state, .failed)
  }

  func testLatestAnswerFindsItsHandoverAfterANewerPacketIsRecorded() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userInputRequired(HandoverQuestion(id: "first-question", text: "First?")))
    let answerPayload = ["choice": JSONValue.string("first")]
    _ = try store.recordAnswer(
      taskId: TaskID("task-1"), questionId: "first-question", payload: answerPayload,
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-first"), now: fixedNow.addingTimeInterval(1)
    )
    var laterPacket = packet(reason: .userInputRequired(HandoverQuestion(id: "second-question", text: "Second?")))
    laterPacket.id = HandoverID("handover-2")
    laterPacket.createdAt = fixedNow.addingTimeInterval(2)
    try store.saveHandover(try laterPacket.sealed())
    XCTAssertEqual(try store.latestAnswer(handoverId: HandoverID("handover-1"))?.payload, answerPayload)
  }

  func testSameSecondAnswerAfterSealAllowsTakeover() throws {
    let store = WorkStore(rootDirectory: root.path)
    let question = HandoverQuestion(id: "same-second", text: "Proceed?")
    var task = sampleTask()
    task.state = .waiting
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    var sealedPacket = packet(reason: .userInputRequired(question))
    sealedPacket.createdAt = fixedNow.addingTimeInterval(0.5)
    try store.saveHandover(try sealedPacket.sealed())

    let payload = ["approved": JSONValue.bool(true)]
    _ = try store.recordAnswer(
      taskId: task.id, questionId: question.id, payload: payload,
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-same-second"),
      now: fixedNow.addingTimeInterval(0.8)
    )

    XCTAssertEqual(try store.latestAnswer(handoverId: sealedPacket.id)?.payload, payload)
    let changed = try store.requestTakeover(
      taskId: task.id, placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-same-second"),
      now: fixedNow.addingTimeInterval(0.9)
    )
    XCTAssertEqual(changed.state, .scheduled)
    let pending = try XCTUnwrap(TaskDispatcher(store: store).pendingReservation(taskId: task.id))
    XCTAssertEqual(pending.entry, .takeover(fromAttemptId: AttemptID("attempt-1"), handoverId: sealedPacket.id))
  }

  func testLatestAnswerRejectsForeignAttempt() throws {
    let store = WorkStore(rootDirectory: root.path)
    try setupHandover(store, reason: .userInputRequired(HandoverQuestion(id: "q-1", text: "Proceed?")))
    let answer = HandoverAnswer(
      questionId: "q-1", payload: ["approved": .bool(true)],
      answeredBy: .human(principal: "operator"), answeredAt: fixedNow.addingTimeInterval(1)
    )
    try store.saveDecision(Decision(
      id: DecisionID("answer-foreign-attempt"), taskId: TaskID("task-1"), attemptId: AttemptID("attempt-foreign"),
      producer: .human(principal: "operator"), kind: .answer(answer),
      reason: "Answer handover 'handover-1' question 'q-1'", createdAt: fixedNow.addingTimeInterval(1)
    ))

    XCTAssertNil(try store.latestAnswer(handoverId: HandoverID("handover-1")))
  }

  func testAnswerBeforeSealDoesNotAllowTakeover() throws {
    let store = WorkStore(rootDirectory: root.path)
    let question = HandoverQuestion(id: "pre-seal", text: "Proceed?")
    var task = sampleTask()
    task.state = .waiting
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    var sealedPacket = packet(reason: .userInputRequired(question))
    sealedPacket.createdAt = fixedNow.addingTimeInterval(1)
    try store.saveHandover(try sealedPacket.sealed())
    _ = try store.recordAnswer(
      taskId: task.id, questionId: question.id, payload: ["approved": .bool(true)],
      producer: .human(principal: "operator"), decisionId: DecisionID("answer-before-seal"), now: fixedNow
    )

    XCTAssertNil(try store.latestAnswer(handoverId: sealedPacket.id))
    XCTAssertThrowsError(try store.requestTakeover(
      taskId: task.id, placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "operator"), decisionId: DecisionID("takeover-before-seal"),
      now: fixedNow.addingTimeInterval(2)
    )) { error in XCTAssertTrue(String(describing: error).contains("riela task answer")) }
  }

  func testFenceOrphanRequiresExpiryAndLateReconcileIsIgnored() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy.lease = LeasePolicy(ttlMs: 1_000)
    try store.saveTask(task)
    let start = fixedNow
    let first = try store.reserveAttempt(reservation(task: task, now: start))
    XCTAssertThrowsError(try store.fenceOrphan(taskId: task.id, now: start.addingTimeInterval(0.5), producer: .human(principal: "operator")))
    let fenced = try store.fenceOrphan(taskId: task.id, now: start.addingTimeInterval(2), producer: .human(principal: "operator"))
    XCTAssertEqual(fenced.predecessor.id, first.attempt.id)
    XCTAssertEqual(fenced.predecessor.state, .reconciled)
    XCTAssertEqual(fenced.predecessor.outcome?.failureKind, .leaseLost)
    XCTAssertEqual(fenced.predecessor.supersededByFence, first.task.fence + 1)
    XCTAssertEqual(fenced.task.fence, first.task.fence + 1)
    XCTAssertNil(try store.loadLease(taskId: task.id))
    XCTAssertEqual(try store.listEvidence(taskId: task.id).first(where: { $0.id == fenced.fenceEvidenceId })?.kind, .leaseFence)
    XCTAssertEqual(try store.reconcileAttempt(attemptId: first.attempt.id, outcome: AttemptOutcome(sessionStatus: .completed)), fenced.predecessor)
  }

  private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

  private func setupHandover(_ store: WorkStore, reason: HandoverReason) throws {
    var task = sampleTask()
    task.state = .waiting
    try store.saveTask(task)
    try store.saveAttempt(Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled))
    try store.saveHandover(try packet(reason: reason).sealed())
  }

  private func reservation(
    task: WorkTask, entry: AttemptEntry = .start, decisionId: DecisionID = DecisionID("decision-1"), now: Date? = nil
  ) -> AttemptReservationRequest {
    AttemptReservationRequest(
      taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-next"), sessionId: "session-next",
      workflowId: "flow", entryStepId: entry == .start ? "start" : "next", entry: entry,
      decisionId: decisionId, producer: .policy(rule: "dispatch"), reason: "dispatch",
      now: now ?? fixedNow
    )
  }

  private func packet(
    reason: HandoverReason = .operatorMove(reason: "move")
  ) -> HandoverPacket {
    HandoverPacket(
      id: HandoverID("handover-1"), taskId: TaskID("task-1"), intentId: IntentID("intent-1"),
      fromAttemptId: AttemptID("attempt-1"), fromSessionId: "session-1", generation: 1, reason: reason,
      workflow: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "next"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["next"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 1, tokensUsed: 0, wallClockMsUsed: 1)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "next", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()),
      brief: "Continue task", producedBy: .runtime, producedOn: "test-host", createdAt: fixedNow
    )
  }

  private func sampleTask() -> WorkTask {
    WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Work",
             plan: .workflow(WorkflowReference(name: "flow")), state: .ready)
  }
}
