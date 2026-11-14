import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class AgentDirectorStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-agent-director-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testLinkedAgentAcceptJudgesOriginalWorkAcrossReopenAndReplay() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "work")), state: .verifying
    )
    try store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged"), taskId: task.id, sessionId: "work-session",
                         state: .reconciled, outcome: AttemptOutcome(sessionStatus: .completed))
    let child = Attempt(id: AttemptID("child"), taskId: task.id, generation: 2,
                        sessionId: "child-session", entry: .director, state: .reconciled,
                        outcome: AttemptOutcome(sessionStatus: .completed), judgedAttemptId: judged.id)
    try store.saveAttempt(judged)
    try store.saveAttempt(child)
    let cause = Evidence(id: EvidenceID("work-evidence"), taskId: task.id, attemptId: judged.id,
                         kind: .gate, producedBy: .runtime, payloadRef: .inline(["owner": .string("work")]),
                         createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    try store.saveEvidence(cause)
    let decision = Decision(id: DecisionID("agent-accept"), taskId: task.id, attemptId: judged.id,
                            producer: .agent(sessionId: child.sessionId), kind: .accept,
                            reason: "work passed", causedBy: [cause.id], createdAt: Date())
    let reopened = WorkStore(rootDirectory: root.path)
    var missingCause = decision
    missingCause.causedBy = []
    XCTAssertThrowsError(try reopened.applyDecision(
      missingCause, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("agent-accept-evidence")
    ))
    let foreign = Evidence(id: EvidenceID("foreign"), taskId: task.id, attemptId: child.id,
                           kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
    try reopened.saveEvidence(foreign)
    var foreignCause = decision
    foreignCause.causedBy = [foreign.id]
    XCTAssertThrowsError(try reopened.applyDecision(
      foreignCause, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("agent-accept-evidence")
    ))
    var wrongSession = decision
    wrongSession.producer = .agent(sessionId: "foreign-session")
    XCTAssertThrowsError(try reopened.applyDecision(
      wrongSession, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("agent-accept-evidence")
    ))
    XCTAssertEqual(try reopened.loadTask(id: task.id), task)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id), [])
    let first = try reopened.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([.acceptanceAbsent]),
      decisionEvidenceId: EvidenceID("agent-accept-evidence")
    )
    XCTAssertEqual(first.task.state, .succeeded)
    XCTAssertEqual(first.attempt?.id, judged.id)
    XCTAssertEqual(try reopened.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try reopened.loadAttempt(id: child.id), child)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id).first(where: { $0.id == cause.id }), cause)
    XCTAssertEqual(try reopened.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("agent-accept-evidence")
    ), first)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id).filter { $0.id == decision.id }.count, 1)
  }

  func testLinkedAgentAcceptRejectsChildOnlySuccessAndWrongSession() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task",
                        instruction: "Run", state: .verifying)
    try store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged"), taskId: task.id, sessionId: "work-session",
                         state: .reconciled, outcome: AttemptOutcome(sessionStatus: .failed))
    let child = Attempt(id: AttemptID("child"), taskId: task.id, generation: 2,
                        sessionId: "child-session", entry: .director, state: .reconciled,
                        outcome: AttemptOutcome(sessionStatus: .completed), judgedAttemptId: judged.id)
    try store.saveAttempt(judged)
    try store.saveAttempt(child)
    let cause = Evidence(id: EvidenceID("work-failure"), taskId: task.id, attemptId: judged.id,
                         kind: .finding, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
    try store.saveEvidence(cause)
    let decision = Decision(id: DecisionID("agent-accept"), taskId: task.id, attemptId: judged.id,
                            producer: .agent(sessionId: child.sessionId), kind: .accept,
                            reason: "child passed", causedBy: [cause.id], createdAt: Date())
    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    ))
    var wrongSession = decision
    wrongSession.producer = .agent(sessionId: "foreign-session")
    XCTAssertThrowsError(try store.applyDecision(
      wrongSession, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testLinkedAgentAcceptCannotBypassHumanOrVerificationRequirements() throws {
    for (suffix, contract) in [
      ("human", CompletionContract(requiresHumanAccept: true)),
      ("verification", CompletionContract(verification: [VerificationRequirement(name: "tests")])),
      ("gate", CompletionContract(gates: [GateDeclaration(id: "quality", stepId: "quality", required: true)])),
      ("finding", CompletionContract())
    ] {
      let directory = root.appendingPathComponent(suffix, isDirectory: true)
      let store = WorkStore(rootDirectory: directory.path)
      let task = WorkTask(id: TaskID("task"), intentId: IntentID("intent"), title: "Task",
                          instruction: "Run", completion: contract, state: .verifying)
      try store.saveTask(task)
      let judged = Attempt(id: AttemptID("judged"), taskId: task.id, sessionId: "work-session",
                           state: .reconciled, outcome: AttemptOutcome(sessionStatus: .completed))
      let child = Attempt(id: AttemptID("child"), taskId: task.id, generation: 2,
                          sessionId: "child-session", entry: .director, state: .reconciled,
                          outcome: AttemptOutcome(sessionStatus: .completed), judgedAttemptId: judged.id)
      try store.saveAttempt(judged)
      try store.saveAttempt(child)
      let cause = Evidence(id: EvidenceID("cause"), taskId: task.id, attemptId: judged.id,
                           kind: .gate, producedBy: .runtime, payloadRef: .inline([:]),
                           createdAt: Date(timeIntervalSince1970: 1_800_000_000))
      try store.saveEvidence(cause)
      if suffix == "finding" {
        let blocking = LoopBlockingFinding(id: "unresolved", severity: "high", message: "judged work defect")
        try store.saveFindings([Finding(
          id: blocking.id, fingerprint: LoopFindingFingerprint.make(from: blocking),
          severity: .high, sourceStepExecutionId: "judged-step", message: blocking.message
        )], taskId: task.id)
      }
      let decision = Decision(id: DecisionID("accept"), taskId: task.id, attemptId: judged.id,
                              producer: .agent(sessionId: child.sessionId), kind: .accept,
                              reason: "child accepts", causedBy: [cause.id], createdAt: Date())
      XCTAssertThrowsError(try store.applyDecision(
        decision, expectedTaskVersion: task.version, completion: .satisfied,
        decisionEvidenceId: EvidenceID("decision-evidence")
      ), "contract: \(suffix)")
      XCTAssertEqual(try store.loadTask(id: task.id), task)
      XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
      XCTAssertEqual(try store.loadAttempt(id: judged.id), judged)
      XCTAssertEqual(try store.loadAttempt(id: child.id), child)
      XCTAssertEqual(try store.listEvidence(taskId: task.id).first(where: { $0.id == cause.id }), cause)
    }
  }

  func testLinkedAgentAcceptRejectsMissingLinkageNewerWorkAndStaleVersion() throws {
    for mode in ["missing-link", "newer-work", "stale-version"] {
      let directory = root.appendingPathComponent(mode, isDirectory: true)
      let store = WorkStore(rootDirectory: directory.path)
      let task = WorkTask(id: TaskID("task"), intentId: IntentID("intent"), title: "Task",
                          instruction: "Run", state: .verifying)
      try store.saveTask(task)
      let judged = Attempt(id: AttemptID("judged"), taskId: task.id, sessionId: "work-session",
                           state: .reconciled, outcome: AttemptOutcome(sessionStatus: .completed))
      let child = Attempt(id: AttemptID("child"), taskId: task.id, generation: 2,
                          sessionId: "child-session", entry: .director, state: .reconciled,
                          outcome: AttemptOutcome(sessionStatus: .completed),
                          judgedAttemptId: mode == "missing-link" ? nil : judged.id)
      try store.saveAttempt(judged)
      try store.saveAttempt(child)
      if mode == "newer-work" {
        try store.saveAttempt(Attempt(id: AttemptID("newer"), taskId: task.id, generation: 3,
                                      sessionId: "newer-session", state: .reconciled,
                                      outcome: AttemptOutcome(sessionStatus: .completed)))
      }
      let cause = Evidence(id: EvidenceID("cause"), taskId: task.id, attemptId: judged.id,
                           kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date())
      try store.saveEvidence(cause)
      let decision = Decision(id: DecisionID("accept"), taskId: task.id, attemptId: judged.id,
                              producer: .agent(sessionId: child.sessionId), kind: .accept,
                              reason: "child accepts", causedBy: [cause.id], createdAt: Date())
      let expectedVersion = mode == "stale-version" ? task.version - 1 : task.version
      XCTAssertThrowsError(try store.applyDecision(
        decision, expectedTaskVersion: expectedVersion, completion: .satisfied,
        decisionEvidenceId: EvidenceID("decision-evidence")
      ), "mode: \(mode)")
      XCTAssertEqual(try store.loadTask(id: task.id), task)
      XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    }
  }

  func testLinkedAgentRerunUsesDurableChildWallClockAtSharedAdmission() throws {
    for (name, limit, admitted) in [("available", 2_000, true), ("exhausted", 1_000, false)] {
      let store = WorkStore(rootDirectory: root.appendingPathComponent(name).path)
      let task = WorkTask(
        id: TaskID("task"), intentId: IntentID("intent"), title: "Task", instruction: "Run",
        plan: .workflow(WorkflowReference(name: "work")),
        guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: 3, maxWallClockMs: limit)),
        state: .verifying
      )
      try store.saveTask(task)
      let judged = Attempt(
        id: AttemptID("judged"), taskId: task.id, sessionId: "work-session",
        state: .reconciled, outcome: AttemptOutcome(sessionStatus: .completed)
      )
      let child = Attempt(
        id: AttemptID("child"), taskId: task.id, generation: 2,
        sessionId: "child-session", entry: .director, state: .reconciled,
        outcome: AttemptOutcome(sessionStatus: .completed), judgedAttemptId: judged.id
      )
      try store.saveAttempt(judged)
      try store.saveAttempt(child)
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
      let epoch = Date(timeIntervalSince1970: 1_800_000_000)
      for (attempt, durationMs) in [(judged, 400), (child, 700)] {
        try persistence.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
          workflowId: "work", sessionId: attempt.sessionId, status: .completed,
          entryStepId: "start", createdAt: epoch,
          updatedAt: epoch.addingTimeInterval(Double(durationMs) / 1_000)
        )))
      }
      let cause = Evidence(
        id: EvidenceID("cause"), taskId: task.id, attemptId: judged.id,
        kind: .contextSnapshot, producedBy: .runtime, payloadRef: .inline([:]), createdAt: epoch
      )
      try store.saveEvidence(cause)
      let decision = Decision(
        id: DecisionID("rerun"), taskId: task.id, attemptId: judged.id,
        producer: .agent(sessionId: child.sessionId), kind: .rerun(fromStepId: "start"),
        reason: "retry work", causedBy: [cause.id], createdAt: epoch
      )
      let request = PendingAttemptReservation(
        id: "pending-rerun", taskId: task.id, decisionId: decision.id,
        predecessorAttemptId: judged.id, entry: .rerunFromStep("start")
      )
      if admitted {
        let result = try store.applyDecision(
          decision, expectedTaskVersion: task.version, completion: .unmet([]),
          decisionEvidenceId: EvidenceID("decision-evidence"), pendingReservation: request
        )
        XCTAssertEqual(result.requestedEntry, .rerunFromStep("start"))
        XCTAssertEqual(try TaskDispatcher(store: store).pendingReservation(taskId: task.id), request)
      } else {
        XCTAssertThrowsError(try store.applyDecision(
          decision, expectedTaskVersion: task.version, completion: .unmet([]),
          decisionEvidenceId: EvidenceID("decision-evidence"), pendingReservation: request
        )) { error in
          XCTAssertTrue(String(describing: error).contains("wallClock budget"))
        }
        XCTAssertEqual(try store.loadTask(id: task.id), task)
        XCTAssertTrue(try store.listDecisions(taskId: task.id).isEmpty)
        XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))
      }
    }
  }

}
