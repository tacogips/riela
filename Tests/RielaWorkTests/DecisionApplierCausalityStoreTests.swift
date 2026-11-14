import Foundation
import RielaSQLite
import XCTest
@testable import RielaWork

final class DecisionApplierCausalityStoreTests: XCTestCase {
  private struct ActionCase {
    let name: String
    let kind: DecisionKind
    let entry: AttemptEntry?
  }

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testDestructiveAndReplacementDecisionsRejectEmptyOrForeignCausalEvidenceForPolicyAndHuman() throws {
    let actions = [
      ActionCase(name: "cancel", kind: .cancel, entry: nil),
      ActionCase(name: "stop", kind: .stop(GuardViolationRef(evidenceId: EvidenceID("guard"), summary: "limit")), entry: nil),
      ActionCase(name: "reject", kind: .reject(reason: "rejected"), entry: nil),
      ActionCase(name: "rerun", kind: .rerun(fromStepId: "repair"), entry: .rerunFromStep("repair")),
      ActionCase(name: "recover", kind: .recover(fromGateId: "review"), entry: .recoverFromGate("review"))
    ]
    for action in actions {
      for producer in [
        DecisionProducer.human(principal: "operator"),
        .policy(rule: "guard")
      ] {
        for causeMode in ["empty", "foreign"] {
          let store = try makeStore("\(causeMode)-cause-\(action.name)-\(producer)")
          let reservation = try reserveLiveAttempt(name: action.name, producer: producer, store: store)
          let causedBy: [EvidenceID]
          if causeMode == "foreign" {
            let foreign = Evidence(id: EvidenceID("foreign"), taskId: TaskID("other-task"), attemptId: reservation.attempt.id,
              kind: .command, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
            try store.saveEvidence(foreign)
            causedBy = [foreign.id]
          } else {
            causedBy = []
          }
          let decision = Decision(id: DecisionID("decision"), taskId: reservation.task.id, attemptId: reservation.attempt.id,
                                  producer: producer, kind: action.kind, reason: action.name, causedBy: causedBy, createdAt: Date())
          let request = action.entry.map { PendingAttemptReservation(id: "pending", taskId: reservation.task.id,
            decisionId: decision.id, predecessorAttemptId: reservation.attempt.id, entry: $0) }
          let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
          let beforeTask = try store.loadTask(id: reservation.task.id)
          let beforeAttempt = try store.loadAttempt(id: reservation.attempt.id)
          let counts = try mutationCounts(database)

          XCTAssertThrowsError(try store.applyDecision(decision, expectedTaskVersion: reservation.task.version,
            completion: .unmet([]), decisionEvidenceId: EvidenceID("decision-evidence"), pendingReservation: request)) {
            let message = String(describing: $0)
            XCTAssertTrue(message.contains(causeMode == "empty" ? "requires causal evidence" : "outside the task attempt scope"), action.name)
          }
          XCTAssertEqual(try store.loadTask(id: reservation.task.id), beforeTask)
          XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id), beforeAttempt)
          XCTAssertEqual(try mutationCounts(database), counts)
        }
      }
    }
  }

  func testStopRejectsNonGuardCausalEvidenceWithoutMutating() throws {
    let store = try makeStore("non-guard-stop")
    let reservation = try reserveLiveAttempt(name: "stop", producer: .human(principal: "operator"), store: store)
    let cause = Evidence(id: EvidenceID("not-a-guard"), taskId: reservation.task.id, attemptId: reservation.attempt.id,
      kind: .command, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
    try store.saveEvidence(cause)
    let decision = Decision(id: DecisionID("stop"), taskId: reservation.task.id, attemptId: reservation.attempt.id,
      producer: .human(principal: "operator"), kind: .stop(GuardViolationRef(evidenceId: cause.id, summary: "limit")),
      reason: "stop", causedBy: [cause.id], createdAt: Date())
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    let beforeTask = try store.loadTask(id: reservation.task.id)
    let beforeAttempt = try store.loadAttempt(id: reservation.attempt.id)
    let counts = try mutationCounts(database)

    XCTAssertThrowsError(try store.applyDecision(decision, expectedTaskVersion: reservation.task.version,
      completion: .unmet([]), decisionEvidenceId: EvidenceID("decision-evidence"))) {
      XCTAssertTrue(String(describing: $0).contains("guard-violation"))
    }
    XCTAssertEqual(try store.loadTask(id: reservation.task.id), beforeTask)
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id), beforeAttempt)
    XCTAssertEqual(try mutationCounts(database), counts)
  }

  private func makeStore(_ name: String) throws -> WorkStore {
    let caseRoot = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
    return WorkStore(rootDirectory: caseRoot.path)
  }

  private func reserveLiveAttempt(name: String, producer: DecisionProducer, store: WorkStore) throws -> AttemptReservationResult {
    let task = WorkTask(id: TaskID("task-\(name)-\(producer)"), intentId: IntentID("intent-1"), title: "Task",
      instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")), state: .ready)
    try store.saveTask(task)
    let reservation = try store.reserveAttempt(AttemptReservationRequest(taskId: task.id, expectedTaskVersion: task.version,
      attemptId: AttemptID("attempt-1"), sessionId: "session-1", workflowId: "workflow", entryStepId: "start",
      entry: .start, decisionId: DecisionID("start"), producer: .policy(rule: "start"), reason: "start", launchToken: "launch"))
    _ = try store.authorizeAttemptLaunch(attemptId: reservation.attempt.id, launchToken: reservation.launchToken)
    return reservation
  }

  private func mutationCounts(_ database: SQLiteDatabase) throws -> [Int] {
    try ["work_leases", "work_cancellations", "work_pending_reservations", "work_decisions",
         "work_decision_applications", "work_evidence"].map { table in
      try database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"].flatMap(Int.init) ?? 0
    }
  }
}
