import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class WorkStoreReservationTests: XCTestCase {
  private final class RaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }

    var successes: Int {
      lock.lock()
      defer { lock.unlock() }
      return values.filter { $0 }.count
    }
  }

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-work-reservation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testReservationAtomicallyCreatesAttemptDecisionLeaseAndCreatedSession() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)

    let reservation = try store.reserveAttempt(request(token: "one-time-secret"))

    XCTAssertEqual(reservation.task.state, .running)
    XCTAssertEqual(reservation.task.version, 2)
    XCTAssertEqual(reservation.attempt.state, .prepared)
    XCTAssertEqual(reservation.attempt.launch?.phase, .reserved)
    XCTAssertNotEqual(reservation.attempt.launch?.tokenDigest, reservation.launchToken)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [reservation.decision])
    XCTAssertEqual(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).load(sessionId: "session-1").session.status,
      .created
    )

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT task_id FROM work_leases").first?["task_id"], task.id.rawValue)
    XCTAssertFalse(try XCTUnwrap(database.query(
      "SELECT token_digest FROM work_leases"
    ).first?["token_digest"]).contains("one-time-secret"))
  }

  func testReservationRejectsRuntimeOnlyDuplicateSessionAndRollsBackEveryWrite() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let existingSession = WorkflowSession(
      workflowId: "existing-workflow",
      sessionId: "session-1",
      status: .completed,
      entryStepId: "existing-start",
      currentStepId: "existing-finish",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let existingMessage = WorkflowMessageRecord(
      communicationId: "comm-existing",
      workflowExecutionId: existingSession.sessionId,
      fromStepId: "existing-start",
      toStepId: "existing-finish",
      sourceStepExecutionId: "exec-existing",
      payload: ["owner": .string("existing-session")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: existingSession.createdAt
    )
    let existingSnapshot = WorkflowRuntimePersistenceSnapshot(
      session: existingSession,
      workflowMessages: [existingMessage],
      rootOutput: ["result": .string("preserve-me")],
      diagnostics: ["preserve-diagnostic"]
    )
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(existingSnapshot)

    XCTAssertThrowsError(try store.reserveAttempt(request())) { error in
      XCTAssertTrue(String(describing: error).contains("already exists"))
    }

    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [])
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    XCTAssertEqual(try store.listEvidence(taskId: task.id), [])
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [])
    XCTAssertEqual(try persistence.load(sessionId: existingSession.sessionId), existingSnapshot)
  }

  func testReservationRejectsStaleVersionAndOneLiveAttempt() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    XCTAssertThrowsError(try store.reserveAttempt(request(expectedVersion: 0)))

    _ = try store.reserveAttempt(request())
    XCTAssertThrowsError(try store.reserveAttempt(request(
      expectedVersion: 2,
      attemptId: "attempt-2",
      sessionId: "session-2",
      decisionId: "decision-2"
    ))) { error in
      XCTAssertTrue(String(describing: error).contains("live attempt"))
    }
  }

  func testAuthorizationAndNodeStartAreTokenFencedAndNotReplayable() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "launch-token"))

    XCTAssertThrowsError(try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: "wrong"
    ))
    let authorized = try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    XCTAssertEqual(authorized.launch?.phase, .authorized)
    XCTAssertEqual(authorized.state, .running)
    XCTAssertThrowsError(try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    ))
    XCTAssertNotEqual(authorized.launch?.tokenDigest, reservation.attempt.launch?.tokenDigest)

    let started = try store.markAttemptNodeStarted(attemptId: reservation.attempt.id)
    XCTAssertEqual(started.launch?.phase, .nodeStarted)
    XCTAssertNotNil(started.launch?.nodeStartedAt)
  }

  func testAuthorizationRejectsAReplacedLeaseDigestAndRollsBackAttemptMutation() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "launch-token"))
    let database = try SQLiteDatabase.open(
      path: store.databasePath,
      mode: .readWriteCreate,
      options: .writableDefault
    )
    try database.execute(
      "UPDATE work_leases SET token_digest = ? WHERE attempt_id = ?",
      bindings: [.text("replaced-digest"), .text(reservation.attempt.id.rawValue)]
    )

    XCTAssertThrowsError(try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )) { error in
      XCTAssertTrue(String(describing: error).contains("missing or replaced"))
    }
    let storedAttempt = try XCTUnwrap(store.loadAttempt(id: reservation.attempt.id))
    XCTAssertEqual(storedAttempt.state, .prepared)
    XCTAssertEqual(storedAttempt.launch?.phase, .reserved)
    XCTAssertEqual(storedAttempt.launch?.tokenDigest, reservation.attempt.launch?.tokenDigest)
  }

  func testOnlyPreAuthorizationLossCanBeFencedForRecovery() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let first = try store.reserveAttempt(request(token: "first-token"))
    let recovered = try store.recoverPreLaunchReservation(
      attemptId: first.attempt.id,
      launchToken: first.launchToken,
      expectedTaskVersion: first.task.version
    )
    XCTAssertEqual(recovered.state, .scheduled)
    XCTAssertEqual(try store.loadAttempt(id: first.attempt.id)?.state, .reconciled)

    let second = try store.reserveAttempt(request(
      expectedVersion: recovered.version,
      attemptId: "attempt-2",
      sessionId: "session-2",
      decisionId: "decision-2",
      token: "second-token"
    ))
    _ = try store.authorizeAttemptLaunch(attemptId: second.attempt.id, launchToken: second.launchToken)
    XCTAssertThrowsError(try store.recoverPreLaunchReservation(
      attemptId: second.attempt.id,
      launchToken: second.launchToken,
      expectedTaskVersion: second.task.version
    )) { error in
      XCTAssertTrue(String(describing: error).contains("launch token is invalid"))
    }
  }

  func testReservationFailureRollsBackEveryRowAndTaskMutation() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    try store.saveAttempt(Attempt(
      id: AttemptID("old-attempt"),
      taskId: task.id,
      sessionId: "session-1",
      state: .reconciled
    ))

    XCTAssertThrowsError(try store.reserveAttempt(request()))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listAttempts(taskId: task.id).map(\.id), [AttemptID("old-attempt")])
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [])
    XCTAssertThrowsError(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).load(sessionId: "session-1")
    )
  }

  func testTerminalReconciliationReleasesLeaseAndMovesTaskToVerification() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "token"))
    _ = try store.authorizeAttemptLaunch(attemptId: reservation.attempt.id, launchToken: "token")
    let terminal = try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    XCTAssertEqual(terminal.state, .reconciled)
    XCTAssertEqual(terminal.launch?.phase, .terminal)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .verifying)
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [])
  }

  func testIndependentConnectionsPermitOnlyOneReservation() throws {
    let firstStore = WorkStore(rootDirectory: root.path)
    let secondStore = WorkStore(rootDirectory: root.path)
    try firstStore.saveTask(sampleTask())
    let queue = DispatchQueue(label: "reservation-race", attributes: .concurrent)
    let group = DispatchGroup()
    let results = RaceResults()
    let requests = (0..<2).map { index in
      request(
        attemptId: "attempt-\(index)",
        sessionId: "session-\(index)",
        decisionId: "decision-\(index)"
      )
    }
    for index in 0..<2 {
      group.enter()
      queue.async {
        defer { group.leave() }
        let store = index == 0 ? firstStore : secondStore
        results.append((try? store.reserveAttempt(requests[index])) != nil)
      }
    }
    group.wait()
    XCTAssertEqual(results.successes, 1)
    XCTAssertEqual(try firstStore.listAttempts(taskId: TaskID("task-1")).count, 1)
  }

  func testEveryInjectedBoundaryRollsBackReservation() throws {
    for point in AttemptReservationFailurePoint.allCases {
      let caseRoot = root.appendingPathComponent(String(describing: point), isDirectory: true)
      let store = WorkStore(rootDirectory: caseRoot.path)
      var task = sampleTask()
      task.state = .scheduled
      try store.saveTask(task)
      let decision = Decision(
        id: DecisionID("rerun-decision"),
        taskId: task.id,
        attemptId: AttemptID("predecessor"),
        producer: .policy(rule: "recover"),
        kind: .rerun(fromStepId: "repair"),
        reason: "retry terminal failure",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
      try store.saveDecision(decision)
      try store.enqueuePendingReservation(PendingAttemptReservation(
        id: "pending-1",
        taskId: task.id,
        decisionId: decision.id,
        predecessorAttemptId: decision.attemptId,
        entry: .rerunFromStep("repair")
      ))
      var value = request(decisionId: decision.id.rawValue)
      value.entry = .rerunFromStep("repair")
      value.pendingRequestId = "pending-1"
      value.placementEvidence = Evidence(
        id: EvidenceID("placement-1"),
        taskId: task.id,
        attemptId: value.attemptId,
        kind: .contextSnapshot,
        producedBy: .runtime,
        payloadRef: .inline(["host": .string("local")]),
        createdAt: value.now
      )
      value.failurePoint = point
      XCTAssertThrowsError(try store.reserveAttempt(value), "expected rollback at \(point)")
      XCTAssertEqual(try store.loadTask(id: task.id), task)
      XCTAssertEqual(try store.listAttempts(taskId: task.id), [])
      XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])
      XCTAssertEqual(try store.listEvidence(taskId: task.id), [])
      let database = try SQLiteDatabase.open(
        path: store.databasePath,
        mode: .readOnly,
        options: .readOnlyDefault
      )
      XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [])
      XCTAssertNil(try database.query(
        "SELECT consumed_attempt_id FROM work_pending_reservations WHERE request_id = 'pending-1'"
      ).first?["consumed_attempt_id"])
      XCTAssertThrowsError(
        try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: caseRoot.path).load(sessionId: "session-1")
      )
    }
  }

  func testDependenciesAndExactAttemptBudgetAreRechecked() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.dependsOn = [TaskID("dependency")]
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 1)
    try store.saveTask(task)
    XCTAssertThrowsError(try store.reserveAttempt(request())) { error in
      XCTAssertTrue(String(describing: error).contains("was not found"))
    }
    var dependency = sampleTask()
    dependency.id = TaskID("dependency")
    dependency.state = .waiting
    try store.saveTask(dependency)
    XCTAssertThrowsError(try store.reserveAttempt(request())) { error in
      XCTAssertTrue(String(describing: error).contains("not satisfied"))
    }
    dependency.state = .succeeded
    try store.saveTask(dependency)
    let reservation = try store.reserveAttempt(request())
    _ = try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    _ = try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    var scheduled = try XCTUnwrap(store.loadTask(id: task.id))
    scheduled.state = .scheduled
    try store.saveTask(scheduled)
    XCTAssertThrowsError(try store.reserveAttempt(request(
      expectedVersion: scheduled.version,
      attemptId: "attempt-2",
      sessionId: "session-2",
      decisionId: "decision-2"
    ))) { error in
      XCTAssertTrue(String(describing: error).contains("attempt budget"))
    }
  }

  func testPendingRerunRequestIsConsumedOnceWithoutDuplicatingDecision() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .scheduled
    try store.saveTask(task)
    let decision = Decision(
      id: DecisionID("rerun-decision"),
      taskId: task.id,
      attemptId: AttemptID("predecessor"),
      producer: .policy(rule: "recover"),
      kind: .rerun(fromStepId: "repair"),
      reason: "retry terminal failure",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.saveDecision(decision)
    try store.enqueuePendingReservation(PendingAttemptReservation(
      id: "pending-1",
      taskId: task.id,
      decisionId: decision.id,
      predecessorAttemptId: decision.attemptId,
      entry: .rerunFromStep("repair")
    ))
    var value = request(decisionId: decision.id.rawValue)
    value.entry = AttemptEntry.rerunFromStep("repair")
    value.pendingRequestId = "pending-1"
    let reservation = try store.reserveAttempt(value)
    XCTAssertEqual(reservation.decision, decision)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])
    _ = try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    _ = try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    var scheduled = try XCTUnwrap(store.loadTask(id: task.id))
    scheduled.state = .scheduled
    try store.saveTask(scheduled)
    value.expectedTaskVersion = scheduled.version
    value.attemptId = AttemptID("attempt-2")
    value.sessionId = "session-2"
    XCTAssertThrowsError(try store.reserveAttempt(value)) { error in
      XCTAssertTrue(String(describing: error).contains("already consumed"))
    }
    XCTAssertEqual(try store.listAttempts(taskId: task.id).count, 1)
  }

  func testStaleTerminalWriterFailsAfterAuthorizedReplacement() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let first = try store.reserveAttempt(request(token: "first-token"))
    let recovered = try store.recoverPreLaunchReservation(
      attemptId: first.attempt.id,
      launchToken: first.launchToken,
      expectedTaskVersion: first.task.version
    )
    let replacement = try store.reserveAttempt(request(
      expectedVersion: recovered.version,
      attemptId: "replacement",
      sessionId: "replacement-session",
      decisionId: "replacement-decision",
      token: "replacement-token"
    ))
    _ = try store.authorizeAttemptLaunch(
      attemptId: replacement.attempt.id,
      launchToken: replacement.launchToken
    )

    XCTAssertThrowsError(try store.reconcileAttempt(
      attemptId: first.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("not live"))
    }
    XCTAssertEqual(try store.loadAttempt(id: replacement.attempt.id)?.state, .running)
  }

  func testCancellationRetainsFenceUntilDurableAcknowledgment() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "cancel-token"))
    try store.requestAttemptCancellation(
      attemptId: reservation.attempt.id,
      decisionId: DecisionID("cancel-decision")
    )
    XCTAssertThrowsError(try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    ))
    XCTAssertThrowsError(try store.reserveAttempt(request(
      expectedVersion: 2,
      attemptId: "replacement",
      sessionId: "replacement-session",
      decisionId: "replacement-decision"
    )))
    let acknowledged = try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    XCTAssertEqual(acknowledged.state, .reconciled)
  }

  private func sampleTask() -> WorkTask {
    WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Repair task",
      instruction: "Run the repair workflow",
      plan: .workflow(WorkflowReference(name: "repair-workflow")),
      state: .ready
    )
  }

  private func request(
    expectedVersion: Int = 1,
    attemptId: String = "attempt-1",
    sessionId: String = "session-1",
    decisionId: String = "decision-1",
    token: String? = nil
  ) -> AttemptReservationRequest {
    AttemptReservationRequest(
      taskId: TaskID("task-1"),
      expectedTaskVersion: expectedVersion,
      attemptId: AttemptID(attemptId),
      sessionId: sessionId,
      workflowId: "repair-workflow",
      entryStepId: "start",
      entry: .start,
      decisionId: DecisionID(decisionId),
      producer: .policy(rule: "start-ready-task"),
      reason: "ready task dispatch",
      launchToken: token,
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }
}
