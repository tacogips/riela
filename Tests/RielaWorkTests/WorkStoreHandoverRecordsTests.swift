import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class WorkStoreHandoverRecordsTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-handover-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testSchemaCanonicalCRUDSuccessorSinkAndAwaitingProjection() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let packet = try samplePacket().sealed()
    try store.saveHandover(packet)
    let laterPacket = try samplePacket(handoverId: HandoverID("handover-3"),
      reason: .userInputRequired(HandoverQuestion(id: "q2", text: "More?")),
      createdAt: Date(timeIntervalSince1970: 11)).sealed()
    try store.saveHandover(laterPacket)
    let presenceTask = WorkTask(id: TaskID("task-2"), intentId: IntentID("intent-1"), title: "Presence", instruction: "Approve",
                                plan: .workflow(WorkflowReference(name: "flow")), state: .waiting)
    try store.saveTask(presenceTask)
    try store.saveHandover(try samplePacket(taskId: presenceTask.id, handoverId: HandoverID("handover-2"),
      reason: .userPresenceRequired(PresenceRequirement(traits: [.gui], instructions: "Approve on host"))).sealed())
    XCTAssertEqual(try store.loadHandover(id: packet.id), packet)
    XCTAssertEqual(try JSONCanonical.encode(try XCTUnwrap(store.loadHandover(id: packet.id))),
                   try JSONCanonical.encode(packet))
    XCTAssertEqual(try store.listHandovers(taskId: packet.taskId), [packet, laterPacket])
    XCTAssertEqual(try store.latestHandover(taskId: packet.taskId), laterPacket)
    XCTAssertEqual(try store.tasksAwaitingHandover().first(where: { $0.taskId == packet.taskId })?.needsAnswer, true)
    XCTAssertEqual(try store.tasksAwaitingHandover(traits: [.interactive]).map(\.taskId), [TaskID("task-1")])
    let ref = HandoverSinkRef(kind: .file, locator: "packet", digest: "sha", writtenAt: Date(timeIntervalSince1970: 7))
    try store.recordSinkRefs(handoverId: packet.id, refs: [ref])
    XCTAssertEqual(try store.loadHandover(id: packet.id)?.digest, packet.digest)
    try store.attachSuccessor(handoverId: packet.id, attemptId: AttemptID("attempt-2"))
    try store.attachSuccessor(handoverId: packet.id, attemptId: AttemptID("attempt-2"))
    XCTAssertThrowsError(try store.attachSuccessor(handoverId: packet.id, attemptId: AttemptID("attempt-3")))
    XCTAssertEqual(try store.tasksAwaitingHandover().map(\.taskId), [presenceTask.id, TaskID("task-1")])
    try store.attachSuccessor(handoverId: laterPacket.id, attemptId: AttemptID("attempt-4"))
    XCTAssertEqual(try store.tasksAwaitingHandover().map(\.taskId), [presenceTask.id])
    let db = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    for table in ["work_handovers", "work_handover_requests"] { XCTAssertTrue(try db.tableExists(table)) }
    let leaseColumns = try db.query("PRAGMA table_info('work_leases')").compactMap { $0["name"] }
    XCTAssertTrue(["heartbeat_at", "expires_at", "fence", "host_id"].allSatisfy(leaseColumns.contains))
    XCTAssertEqual(try db.query("SELECT fence FROM work_tasks WHERE task_id = 'task-1'").first?["fence"], "0")
    let writable = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try writable.execute(
      "UPDATE work_handovers SET record = jsonb_set(record, '$.brief', '\"tampered\"') WHERE handover_id = ?",
      bindings: [.text(laterPacket.id.rawValue)]
    )
    XCTAssertThrowsError(try store.loadHandover(id: laterPacket.id))
  }

  func testSealIsAtomicAndVersionConflictWritesNothing() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .running)
    try store.saveAttempt(attempt)
    let db = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try db.execute("INSERT INTO work_leases (attempt_id, task_id, session_id, token_digest, acquired_at, updated_at) VALUES ('attempt-1', 'task-1', 'session-1', 'x', 'now', 'now')")
    let packet = try samplePacket().sealed()
    let decision = Decision(id: DecisionID("decision-1"), taskId: task.id, attemptId: attempt.id, producer: .human(principal: "operator"),
                            kind: .handover(.userInputRequired(HandoverQuestion(id: "q", text: "Proceed?"))),
                            reason: "needs input", createdAt: Date(timeIntervalSince1970: 10))
    let evidence = Evidence(id: EvidenceID("evidence-1"), taskId: task.id, attemptId: attempt.id, kind: .handover,
                           producedBy: .runtime, payloadRef: .inline(["handoverId": .string(packet.id.rawValue)]), createdAt: Date(timeIntervalSince1970: 10))
    XCTAssertThrowsError(try store.sealHandoverRecords(packet: packet, decision: decision, evidence: [evidence],
      predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 99, now: Date(timeIntervalSince1970: 10)))
    XCTAssertNil(try store.loadHandover(id: packet.id))
    XCTAssertTrue(try store.listDecisions(taskId: task.id).isEmpty)
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
    let updated = try store.sealHandoverRecords(packet: packet, decision: decision, evidence: [evidence],
      predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 1, now: Date(timeIntervalSince1970: 10))
    XCTAssertEqual(updated.state, TaskState.waiting)
    XCTAssertEqual(updated.version, 2)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertTrue(try db.query("SELECT attempt_id FROM work_leases").isEmpty)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).count, 1)
    XCTAssertEqual(try store.listEvidence(taskId: task.id).count, 1)
  }

  func testSealRollsBackWhenFailingAfterPacketInsert() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    // The predecessor attempt is intentionally not saved: requiredAttempt throws after the packet/decision/evidence inserts.
    let packet = try samplePacket().sealed()
    let decision = Decision(id: DecisionID("decision-1"), taskId: task.id, attemptId: AttemptID("attempt-1"), producer: .human(principal: "operator"),
                            kind: .handover(.userInputRequired(HandoverQuestion(id: "q", text: "Proceed?"))),
                            reason: "needs input", createdAt: Date(timeIntervalSince1970: 10))
    let evidence = Evidence(id: EvidenceID("evidence-1"), taskId: task.id, attemptId: AttemptID("attempt-1"), kind: .handover,
                           producedBy: .runtime, payloadRef: .inline(["handoverId": .string(packet.id.rawValue)]), createdAt: Date(timeIntervalSince1970: 10))
    XCTAssertThrowsError(try store.sealHandoverRecords(packet: packet, decision: decision, evidence: [evidence],
      predecessorOutcome: AttemptOutcome(sessionStatus: .suspended), expectedTaskVersion: 1, now: Date(timeIntervalSince1970: 10)))
    XCTAssertNil(try store.loadHandover(id: packet.id))
    let db = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS c FROM work_handovers").first?["c"], "0")
    XCTAssertTrue(try store.listDecisions(taskId: task.id).isEmpty)
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
    let reloaded = try XCTUnwrap(store.loadTask(id: task.id))
    XCTAssertEqual(reloaded.version, 1)
    XCTAssertEqual(reloaded.state, .running)
  }

  func testAwaitingHandoverNeedsAnswerTracksMatchingAnswerDecision() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    try store.saveHandover(try samplePacket().sealed())
    let presenceTask = WorkTask(id: TaskID("task-2"), intentId: IntentID("intent-1"), title: "Presence", instruction: "Approve",
                                plan: .workflow(WorkflowReference(name: "flow")), state: .waiting)
    try store.saveTask(presenceTask)
    try store.saveHandover(try samplePacket(taskId: presenceTask.id, handoverId: HandoverID("handover-2"),
      reason: .userPresenceRequired(PresenceRequirement(traits: [.gui], instructions: "Approve on host"))).sealed())
    func needsAnswer() throws -> Bool? {
      try store.tasksAwaitingHandover().first(where: { $0.taskId == TaskID("task-1") })?.needsAnswer
    }
    func answer(_ id: String, questionId: String) -> Decision {
      Decision(id: DecisionID(id), taskId: TaskID("task-1"), producer: .human(principal: "operator"),
               kind: .answer(HandoverAnswer(questionId: questionId, payload: ["value": .string("yes")],
                                            answeredBy: .human(principal: "operator"), answeredAt: Date(timeIntervalSince1970: 12))),
               reason: "answered", createdAt: Date(timeIntervalSince1970: 12))
    }
    XCTAssertEqual(try needsAnswer(), true)
    try store.saveDecision(answer("decision-other", questionId: "other"))
    XCTAssertEqual(try needsAnswer(), true)
    try store.saveDecision(answer("decision-q", questionId: "q"))
    XCTAssertEqual(try needsAnswer(), false)
    XCTAssertTrue(try store.tasksAwaitingHandover(traits: [.gui]).map(\.taskId).contains(presenceTask.id))
  }

  func testAwaitingHandoverIgnoresAnswersToEarlierHandovers() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    try store.saveHandover(try samplePacket(createdAt: Date(timeIntervalSince1970: 10)).sealed())
    func answer(_ id: String, at time: Double) -> Decision {
      Decision(id: DecisionID(id), taskId: TaskID("task-1"), producer: .human(principal: "operator"),
               kind: .answer(HandoverAnswer(questionId: "q", payload: ["value": .string("yes")],
                                            answeredBy: .human(principal: "operator"), answeredAt: Date(timeIntervalSince1970: time))),
               reason: "answered", createdAt: Date(timeIntervalSince1970: time))
    }
    try store.saveDecision(answer("decision-1", at: 12))
    try store.attachSuccessor(handoverId: HandoverID("handover-1"), attemptId: AttemptID("attempt-2"))
    try store.saveHandover(try samplePacket(handoverId: HandoverID("handover-2"), createdAt: Date(timeIntervalSince1970: 20)).sealed())
    let stale = try XCTUnwrap(store.tasksAwaitingHandover().first(where: { $0.taskId == TaskID("task-1") }))
    XCTAssertEqual(stale.handoverId, HandoverID("handover-2"))
    XCTAssertTrue(stale.needsAnswer)
    try store.saveDecision(answer("decision-2", at: 21))
    XCTAssertEqual(try store.tasksAwaitingHandover().first(where: { $0.taskId == TaskID("task-1") })?.needsAnswer, false)
  }

  func testAwaitingHandoverExcludesTerminalTasks() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .waiting
    try store.saveTask(task)
    try store.saveHandover(try samplePacket().sealed())
    XCTAssertEqual(try store.tasksAwaitingHandover().map(\.taskId), [task.id])
    task.state = .cancelled
    try store.saveTask(task)
    XCTAssertTrue(try store.tasksAwaitingHandover().isEmpty)
  }

  private func sampleTask() -> WorkTask {
    WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Do work",
             plan: .workflow(WorkflowReference(name: "flow")), state: .running)
  }
  private func samplePacket(taskId: TaskID = TaskID("task-1"), handoverId: HandoverID = HandoverID("handover-1"),
                            reason: HandoverReason = .userInputRequired(HandoverQuestion(id: "q", text: "Proceed?")),
                            createdAt: Date = Date(timeIntervalSince1970: 10)) -> HandoverPacket {
    HandoverPacket(id: handoverId, taskId: taskId, intentId: IntentID("intent-1"),
      fromAttemptId: AttemptID("attempt-1"), fromSessionId: "session-1", generation: 1,
      reason: reason,
      workflow: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "next"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["next"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 1, tokensUsed: 0, wallClockMsUsed: 1)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "next", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()),
      brief: "Continue.", producedBy: .runtime, producedOn: "host", createdAt: createdAt)
  }
}
