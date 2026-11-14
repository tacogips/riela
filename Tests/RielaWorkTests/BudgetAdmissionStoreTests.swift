import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class BudgetAdmissionDecisionApplierStoreTests: XCTestCase {
  private struct ActionCase {
    let name: String
    let kind: DecisionKind
    let entry: AttemptEntry
  }

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testDirectExecutionDecisionsCannotBypassExhaustedDurableBudgets() throws {
    let actions = [
      ActionCase(name: "start", kind: .start, entry: .start),
      ActionCase(name: "resume", kind: .resume, entry: .resume),
      ActionCase(name: "rerun", kind: .rerun(fromStepId: "repair"), entry: .rerunFromStep("repair")),
      ActionCase(name: "recover", kind: .recover(fromGateId: "review"), entry: .recoverFromGate("review"))
    ]
    for dimension in [BudgetDimension.tokens, .wallClock, .proposals] {
      for action in actions {
        for (producerName, producer) in producers {
          let store = try makeStore("decision-\(dimension.rawValue)-\(action.name)-\(producerName)")
          let task = exhaustedBudgetTask(dimension)
          let attempt = try seedExhaustedBudget(dimension, task: task, store: store)
          let decision = Decision(id: DecisionID("\(dimension.rawValue)-\(action.name)-\(producerName)"), taskId: task.id,
                                  attemptId: action.name == "start" ? nil : attempt.id, producer: producer, kind: action.kind,
                                  reason: "direct entry", createdAt: Date())
          let request = ["rerun", "recover"].contains(action.name) ? PendingAttemptReservation(
            id: "pending-\(decision.id.rawValue)", taskId: task.id, decisionId: decision.id,
            predecessorAttemptId: attempt.id, entry: action.entry
          ) : nil
          try assertRejectedAdmission(store: store, task: task, attempt: attempt, decision: decision,
                                      pendingReservation: request, dimension: dimension)
        }
      }
    }
  }

  func testDirectReservationsCannotBypassExhaustedDurableBudgets() throws {
    for dimension in [BudgetDimension.tokens, .wallClock, .proposals] {
      for entry in [AttemptEntry.start, .resume] {
        for (producerName, producer) in producers {
          let store = try makeStore("reservation-\(dimension.rawValue)-\(producerName)-\(entry)")
          var task = exhaustedBudgetTask(dimension); task.state = .scheduled
          let attempt = try seedExhaustedBudget(dimension, task: task, store: store)
          let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
          let beforeTask = try store.loadTask(id: task.id)
          let beforeAttempts = try store.listAttempts(taskId: task.id)
          let counts = try mutationCounts(database)
          XCTAssertThrowsError(try store.reserveAttempt(AttemptReservationRequest(
            taskId: task.id, expectedTaskVersion: task.version,
            attemptId: AttemptID("new-\(dimension.rawValue)-\(producerName)"), sessionId: "new-session",
            workflowId: "workflow", entryStepId: "start", entry: entry,
            decisionId: DecisionID("new-decision-\(dimension.rawValue)-\(producerName)"), producer: producer,
            reason: "direct reservation"
          ))) { XCTAssertTrue(String(describing: $0).contains("\(dimension.rawValue) budget")) }
          XCTAssertEqual(try store.loadTask(id: task.id), beforeTask)
          XCTAssertEqual(try store.listAttempts(taskId: task.id), beforeAttempts)
          XCTAssertEqual(try mutationCounts(database), counts)
          XCTAssertEqual(attempt.state, .reconciled)
        }
      }
    }
  }

  func testAcceptanceRemainsAvailableToTheLastAdmittedAttempt() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-last-admitted"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
                        plan: .workflow(WorkflowReference(name: "workflow")),
                        guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: 1)), state: .verifying)
    let attempt = Attempt(id: AttemptID("attempt-last-admitted"), taskId: task.id, sessionId: "session-last-admitted",
                          state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed))
    let cause = Evidence(id: EvidenceID("cause-last-admitted"), taskId: task.id, attemptId: attempt.id,
                         kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
    try store.saveTask(task); try store.saveAttempt(attempt); try store.saveEvidence(cause)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(WorkflowRuntimePersistenceSnapshot(
      session: WorkflowSession(workflowId: "workflow", sessionId: attempt.sessionId, status: .completed,
                               entryStepId: "start", createdAt: Date(), updatedAt: Date())
    ))
    let application = try store.applyDecision(Decision(
      id: DecisionID("accept-last-admitted"), taskId: task.id, attemptId: attempt.id,
      producer: .human(principal: "operator"), kind: .accept, reason: "complete", causedBy: [cause.id], createdAt: Date()
    ), expectedTaskVersion: task.version, completion: .satisfied, decisionEvidenceId: EvidenceID("decision-evidence-last-admitted"))
    XCTAssertEqual(application.task.state, .succeeded)
    XCTAssertEqual(application.attempt?.state, .reconciled)
  }

  func testTokenAdmissionCountsSameExecutionIDAcrossAttempts() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-token-collision"), intentId: IntentID("intent-1"), title: "Task",
                        instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")),
                        guardPolicy: GuardPolicy(budget: BudgetGuard(maxTotalTokens: 100)), state: .scheduled)
    let attempts = ["attempt-1", "attempt-2"].map { id in
      Attempt(id: AttemptID(id), taskId: task.id, sessionId: "session-\(id)", state: .reconciled,
              outcome: AttemptOutcome(sessionStatus: .failed,
                                      costs: [LoopCostEvidence(stepExecutionId: "session-local-execution", totalTokens: 60)]))
    }
    try store.saveTask(task)
    try attempts.forEach(store.saveAttempt)

    XCTAssertThrowsError(try store.reserveAttempt(AttemptReservationRequest(
      taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-3"), sessionId: "session-3",
      workflowId: "workflow", entryStepId: "start", entry: .start, decisionId: DecisionID("decision-3"),
      producer: .policy(rule: "test"), reason: "must respect cumulative token budget"
    ))) { error in
      XCTAssertTrue(String(describing: error).contains("tokens budget"))
    }
  }

  func testTokenAdmissionDeduplicatesCumulativeRecordsWithinAnAttempt() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-token-replay"), intentId: IntentID("intent-1"), title: "Task",
                        instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")),
                        guardPolicy: GuardPolicy(budget: BudgetGuard(maxTotalTokens: 50)), state: .scheduled)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed, costs: [
        LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 13),
        LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 42)
      ])
    )
    try store.saveTask(task)
    try store.saveAttempt(attempt)

    let reservation = try store.reserveAttempt(AttemptReservationRequest(
      taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-2"), sessionId: "session-2",
      workflowId: "workflow", entryStepId: "start", entry: .start, decisionId: DecisionID("decision-2"),
      producer: .policy(rule: "test"), reason: "latest cumulative token record remains below budget"
    ))
    XCTAssertEqual(reservation.attempt.id, AttemptID("attempt-2"))
  }

  private let producers: [(String, DecisionProducer)] = [
    ("human", .human(principal: "operator")), ("policy", .policy(rule: "direct")), ("agent", .agent(sessionId: "director"))
  ]

  private func makeStore(_ name: String) throws -> WorkStore {
    let caseRoot = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
    return WorkStore(rootDirectory: caseRoot.path)
  }

  private func assertRejectedAdmission(store: WorkStore, task: WorkTask, attempt: Attempt, decision: Decision,
                                       pendingReservation: PendingAttemptReservation?, dimension: BudgetDimension) throws {
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    let beforeTask = try store.loadTask(id: task.id)
    let beforeAttempt = try store.loadAttempt(id: attempt.id)
    let counts = try mutationCounts(database)
    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("decision-evidence-\(decision.id.rawValue)"), pendingReservation: pendingReservation
    )) { XCTAssertTrue(String(describing: $0).contains("\(dimension.rawValue) budget")) }
    XCTAssertEqual(try store.loadTask(id: task.id), beforeTask)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id), beforeAttempt)
    XCTAssertEqual(try mutationCounts(database), counts)
  }

  private func exhaustedBudgetTask(_ dimension: BudgetDimension) -> WorkTask {
    let budget: BudgetGuard = switch dimension {
    case .tokens: BudgetGuard(maxTotalTokens: 1)
    case .wallClock: BudgetGuard(maxWallClockMs: 1)
    case .proposals: BudgetGuard(maxProposals: 1)
    case .attempts: BudgetGuard(maxAttempts: 1)
    }
    return WorkTask(id: TaskID("task-\(dimension.rawValue)"), intentId: IntentID("intent-1"), title: "Task",
                    instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")),
                    guardPolicy: GuardPolicy(budget: budget), state: .ready)
  }

  private func seedExhaustedBudget(_ dimension: BudgetDimension, task: WorkTask, store: WorkStore) throws -> Attempt {
    try store.saveTask(task)
    let costs = dimension == .tokens ? [LoopCostEvidence(stepExecutionId: "cost-\(task.id.rawValue)", totalTokens: 1)] : []
    let attempt = Attempt(id: AttemptID("attempt-\(task.id.rawValue)"), taskId: task.id, sessionId: "session-\(task.id.rawValue)",
                          state: .reconciled, outcome: AttemptOutcome(sessionStatus: .failed, costs: costs))
    try store.saveAttempt(attempt)
    if dimension == .proposals {
      try store.saveDecision(Decision(
        id: DecisionID("proposal-\(task.id.rawValue)"), taskId: task.id, attemptId: attempt.id,
        producer: .agent(sessionId: "director"),
        kind: .proposeWorkflowChange(ProposalRef(id: "proposal-\(task.id.rawValue)")),
        reason: "proposal budget", createdAt: Date()
      ))
    } else if dimension != .tokens {
      try store.saveEvidence(Evidence(id: EvidenceID("budget-\(dimension.rawValue)-\(task.id.rawValue)"), taskId: task.id,
        attemptId: attempt.id, kind: .guardViolation, producedBy: .runtime,
        payloadRef: .inline(["kind": .string("budget"), "dimension": .string(dimension.rawValue),
                             "used": .integer(1), "limit": .integer(1)]), createdAt: Date()))
    }
    return attempt
  }

  private func mutationCounts(_ database: SQLiteDatabase) throws -> [Int] {
    try ["work_leases", "work_cancellations", "work_pending_reservations", "work_decisions",
         "work_decision_applications", "work_evidence"].map { table in
      try database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"].flatMap(Int.init) ?? 0
    }
  }
}
