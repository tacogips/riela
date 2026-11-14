import Foundation
import RielaAdapters
import RielaCore
import RielaSQLite
@testable import RielaWork
import XCTest
@testable import RielaCLI

private actor DelayedScenarioNodeAdapter: NodeAdapter {
  let fallback: ScenarioNodeAdapter
  let emitsProgress: Bool
  let stopsAfterProgress: Bool

  init(scenarioPath: String, emitsProgress: Bool, stopsAfterProgress: Bool = false) throws {
    fallback = ScenarioNodeAdapter(
      scenario: try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath)
    )
    self.emitsProgress = emitsProgress
    self.stopsAfterProgress = stopsAfterProgress
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id.contains("repair") {
      for index in 0..<7 {
        try await Task.sleep(for: .milliseconds(80))
        if emitsProgress && (!stopsAfterProgress || index == 0) {
          await context.backendEventHandler?(AdapterBackendEvent(
            provider: "controlled-test", eventType: "progress", channel: .thinking,
            contentDelta: "working"
          ))
        }
      }
    }
    return try await fallback.execute(input, context: context)
  }
}

private final class InactivityDecisionBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var hits = 0
  private(set) var entries = 0
  private(set) var failure: String?
  private(set) var rejectedPreconditions = 0
  let rootDirectory: String

  init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  func commitProgress() throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
    // This callback runs after the observer recheck and before WorkStore's
    // decision transaction. Saving here makes the ordering deterministic.
    lock.lock()
    defer { lock.unlock() }
    entries += 1
    do {
      let store = WorkStore(rootDirectory: rootDirectory)
      let taskId = TaskID("task-task-repair-loop")
      let sessions = try store.listAttempts(taskId: taskId)
      guard let attempt = sessions.last else {
        throw WorkStoreError("inactivity barrier has no reserved attempt")
      }
      var snapshot = try runtime.load(sessionId: attempt.sessionId)
      guard let index = snapshot.session.executions.lastIndex(where: { $0.status == .running }) else {
        throw WorkStoreError("inactivity barrier has no running execution")
      }
      if entries == 1 {
        try rejectInvalidObservations(
          store: store, taskId: taskId, attempt: attempt,
          execution: snapshot.session.executions[index]
        )
      }
      let previous = snapshot.session.executions[index].lastBackendEventAt
      let at = Date()
      snapshot.session.executions[index].lastBackendEventAt = at
      snapshot.session.executions[index].updatedAt = at
      snapshot.session.updatedAt = at
      try runtime.save(snapshot)
      let saved = try runtime.load(sessionId: attempt.sessionId)
      guard let committed = saved.session.executions[index].lastBackendEventAt,
            committed != previous,
            saved.session.executions[index].executionId == snapshot.session.executions[index].executionId else {
        throw WorkStoreError("inactivity barrier progress did not commit")
      }
      hits += 1
    } catch {
      failure = String(describing: error)
      throw error
    }
  }

  private func rejectInvalidObservations(
    store: WorkStore, taskId: TaskID, attempt: Attempt, execution: WorkflowStepExecution
  ) throws {
    let task = try XCTUnwrap(store.loadTask(id: taskId))
    let evidenceId = EvidenceID("evidence-barrier-\(UUID().uuidString)")
    try store.saveEvidence(Evidence(
      id: evidenceId, taskId: taskId, attemptId: attempt.id,
      kind: .guardViolation, producedBy: .runtime,
      payloadRef: .inline(["kind": .string("inactivity")]), createdAt: Date()
    ))
    let beforeDecisions = try store.listDecisions(taskId: taskId).count
    let beforeRows = try durableMutationCounts(store: store)
    let observation = LiveInactivityObservation(
      taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId,
      executionId: "wrong-\(execution.executionId)", createdAt: execution.createdAt,
      lastBackendEventAt: execution.lastBackendEventAt
    )
    for candidate in [nil, observation] {
      let decision = Decision(
        id: DecisionID("decision-barrier-\(UUID().uuidString)"),
        taskId: taskId, attemptId: attempt.id,
        producer: .policy(rule: "guard-policy-fail"),
        kind: .stop(GuardViolationRef(evidenceId: evidenceId, summary: "inactivity")),
        reason: "inactivity", causedBy: [evidenceId], createdAt: Date()
      )
      for _ in 0..<2 {
        do {
          _ = try store.applyDecision(
            decision, expectedTaskVersion: task.version, completion: .unmet([]),
            decisionEvidenceId: EvidenceID("evidence-\(decision.id.rawValue)"),
            liveInactivityObservation: candidate
          )
          throw WorkStoreError("invalid inactivity observation was applied")
        } catch is StaleInactivityObservation {
          rejectedPreconditions += 1
        }
      }
    }
    guard try store.loadTask(id: taskId)?.version == task.version,
          try store.listDecisions(taskId: taskId).count == beforeDecisions,
          try durableMutationCounts(store: store) == beforeRows,
          try store.loadAttempt(id: attempt.id)?.state == .running,
          try TaskDispatcher(store: store).pendingReservation(taskId: taskId) == nil,
          try store.attemptCancellation(
            taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
          ) == nil else {
      throw WorkStoreError("rejected inactivity observation changed durable task state")
    }
  }

  private func durableMutationCounts(store: WorkStore) throws -> [Int] {
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .strictReadOnly)
    return try [
      "work_leases", "work_cancellations", "work_pending_reservations",
      "work_decisions", "work_decision_applications", "work_evidence"
    ].map { table in
      try database.query("SELECT COUNT(*) AS count FROM \(table)")
        .first?["count"].flatMap(Int.init) ?? 0
    }
  }
}

private final class InactivityBarrierCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func mark() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

extension TaskDispatcherIntegrationTests {
  func testFailedTaskRetriesWithinBudgetAndStopsAtLimit() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
    try harness.store.saveTask(task)
    let dispatcher = TaskDispatcher(store: harness.store)
    let failingScenario = try failedRepairScenario(in: harness)

    let first = try await harness.dispatch("task-repair-loop", scenarioPath: failingScenario)
    XCTAssertEqual(first.exitCode, .failure, first.stderr + first.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(firstAttempt.state, .reconciled)
    XCTAssertEqual(firstAttempt.outcome?.sessionStatus, .failed)
    XCTAssertEqual(firstAttempt.outcome?.failureKind, .adapterFailure, first.stdout)
    let pending = try XCTUnwrap(
      dispatcher.pendingReservation(taskId: task.id),
      "outcome: \(String(describing: firstAttempt.outcome))"
    )
    XCTAssertEqual(pending.predecessorAttemptId, firstAttempt.id)
    XCTAssertEqual(pending.entry, .rerunFromStep(nil))

    let second = try await harness.dispatch("task-repair-loop", scenarioPath: failingScenario)
    XCTAssertEqual(second.exitCode, .failure, second.stderr + second.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertNotEqual(attempts[0].sessionId, attempts[1].sessionId)
    XCTAssertEqual(attempts[1].state, .reconciled)
    XCTAssertEqual(attempts[1].outcome?.sessionStatus, .failed)
    let lastDecision = try harness.store.listDecisions(taskId: task.id).last
    XCTAssertEqual(
      try harness.store.loadTask(id: task.id)?.state, .failed,
      "decision: \(String(describing: lastDecision))"
    )
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
    let beforeReplay = try harness.rowCounts(taskId: task.id)

    let refused = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(refused.exitCode, .failure, refused.stderr + refused.stdout)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeReplay)
  }

  func testLastAdmittedRecoveryAttemptCanSucceed() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
    try harness.store.saveTask(task)
    let dispatcher = TaskDispatcher(store: harness.store)
    let failingScenario = try failedRepairScenario(in: harness)

    let first = try await harness.dispatch("task-repair-loop", scenarioPath: failingScenario)
    XCTAssertEqual(first.exitCode, .failure, first.stderr + first.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(firstAttempt.outcome?.failureKind, .adapterFailure, first.stdout)
    let firstCanonical = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: firstAttempt.sessionId)
    XCTAssertEqual(firstCanonical.session.status, .failed)
    XCTAssertEqual(firstCanonical.session.failureKind, .adapterFailure)
    let pending = try XCTUnwrap(
      dispatcher.pendingReservation(taskId: task.id),
      "outcome: \(String(describing: firstAttempt.outcome))"
    )
    XCTAssertEqual(pending.predecessorAttemptId, firstAttempt.id)

    let second = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(second.exitCode, .success, second.stderr + second.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[1].entry, .rerunFromStep(nil))
    XCTAssertNotEqual(attempts[1].sessionId, attempts[0].sessionId)
    XCTAssertEqual(attempts[1].outcome?.sessionStatus, .completed)
    let completion = try harness.store.currentCompletionVerdict(taskId: task.id, attemptId: attempts[1].id)
    let lastDecision = try harness.store.listDecisions(taskId: task.id).last
    let findings = try harness.store.listFindings(taskId: task.id)
    XCTAssertEqual(findings.first(where: { $0.id == "missing-required-gate-verification" })?.status,
                   .superseded)
    let resolution = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
      $0.payloadRef.inlinePayload?["resolvedFindingId"] == .string("missing-required-gate-verification")
    }))
    XCTAssertEqual(resolution.attemptId, attempts[1].id)
    XCTAssertEqual(resolution.causedBy.count, 1)
    let accepted = try XCTUnwrap(attempts[1].outcome?.latestGateResults.first(where: {
      $0.gateId == "verification" && $0.decision == .accepted
    }))
    let acceptedEvidence = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
      $0.kind == .gate && $0.attemptId == attempts[1].id
        && $0.payloadRef.inlinePayload?["gateId"] == .string(accepted.gateId)
        && $0.payloadRef.inlinePayload?["stepExecutionId"] == .string(accepted.stepExecutionId)
    }))
    XCTAssertEqual(resolution.causedBy, [acceptedEvidence.id])
    XCTAssertTrue(try harness.store.listEvidence(taskId: task.id).contains {
      $0.attemptId == attempts[0].id && $0.kind == .gate
    })
    XCTAssertEqual(
      try harness.store.loadTask(id: task.id)?.state, .succeeded,
      "completion: \(completion); decision: \(String(describing: lastDecision)); "
        + "prior gates: \(String(describing: attempts[0].outcome?.gateResults)); "
        + "latest gates: \(String(describing: attempts[1].outcome?.gateResults)); "
        + "findings: \(findings)"
    )
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
    let beforeReplay = try harness.rowCounts(taskId: task.id)

    let refused = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(refused.exitCode, .failure, refused.stderr + refused.stdout)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeReplay)
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    XCTAssertEqual(try reopened.listFindings(taskId: task.id), findings)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id).filter { $0.id == resolution.id }.count, 1)
  }

  func testRetryDisabledAdapterFailureWaitsWithoutPendingRequest() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.director.deterministic.rerunOnAdapterFailure = false
    try harness.store.saveTask(task)
    let failingScenario = try failedRepairScenario(in: harness)
    let result = try await harness.dispatch("task-repair-loop", scenarioPath: failingScenario)
    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.outcome?.failureKind, .adapterFailure)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
  }

  func testUnclassifiedFailureDoesNotAutomaticallyRetry() throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
    try harness.store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("unclassified-attempt"), taskId: task.id,
      sessionId: "unclassified-session", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    try harness.store.saveAttempt(attempt)
    let outcome = try TaskGuardCoordinator(store: harness.store).evaluateAndApply(
      task: task, latestAttempt: attempt, snapshot: GuardSnapshot(attemptCount: 1),
      completion: .unmet([]), failedStepId: "repair", violationEvidenceIds: [],
      decisionId: DecisionID("unclassified-wait"),
      decisionEvidenceId: EvidenceID("unclassified-wait-evidence")
    )
    XCTAssertNil(attempt.outcome?.failureKind)
    XCTAssertEqual(outcome.resolution?.kind, .wait(.human))
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 1)
    XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id).first?.kind, .wait(.human))
  }

  func testCurrentMissingOrRejectedGateAndSubstantiveFindingsStillBlock() async throws {
    for caseName in ["missing", "rejected", "needs-work", "mismatched-lineage", "high", "mid", "human"] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("task-repair-loop")
      task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
      task.completion.requiresHumanAccept = caseName == "human"
      try harness.store.saveTask(task)
      let failed = try await harness.dispatch(
        "task-repair-loop", scenarioPath: failedRepairScenario(in: harness)
      )
      XCTAssertEqual(failed.exitCode, .failure, "\(caseName): \(failed.stderr + failed.stdout)")
      let first = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
      XCTAssertEqual(first.outcome?.failureKind, .adapterFailure, caseName)
      let syntheticId = "missing-required-gate-verification"
      let historical = try XCTUnwrap(harness.store.listFindings(taskId: task.id).first(where: {
        $0.id == syntheticId
      }))
      XCTAssertEqual(historical.status, .open, caseName)
      if ["high", "mid", "mismatched-lineage"].contains(caseName) {
        if caseName == "mismatched-lineage" {
          var mismatch = historical
          mismatch.sourceStepExecutionId = "different-lineage"
          try harness.store.saveFindings([mismatch], taskId: task.id)
        } else {
          let severity: FindingSeverity = caseName == "mid" ? .mid : .high
          let id = "missing-required-gate-verification-substantive-\(caseName)"
          let blocking = LoopBlockingFinding(id: id, severity: severity.rawValue, message: "real defect")
          try harness.store.saveFindings([Finding(
            id: id, fingerprint: LoopFindingFingerprint.make(from: blocking), severity: severity,
            gateId: "verification", sourceStepExecutionId: "verify-substantive", message: "real defect"
          )], taskId: task.id)
        }
      }

      let source = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json")
      var scenario = try XCTUnwrap(JSONSerialization.jsonObject(
        with: Data(contentsOf: source)
      ) as? [String: [String: Any]])
      if ["missing", "rejected", "needs-work"].contains(caseName) {
        var verify = try XCTUnwrap(scenario["verify"])
        var payload = try XCTUnwrap(verify["payload"] as? [String: Any])
        if caseName == "missing" {
          payload.removeValue(forKey: "loopGate")
        } else {
          var gate = try XCTUnwrap(payload["loopGate"] as? [String: Any])
          gate["decision"] = caseName == "rejected" ? "rejected" : LoopGateDecision.needsWork.rawValue
          gate["acceptance"] = ["met": false, "note": "still blocked"]
          payload["loopGate"] = gate
        }
        verify["payload"] = payload
        scenario["verify"] = verify
      }
      let scenarioFile = harness.sessionStore.appendingPathComponent("gate-negative-\(caseName).json")
      try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioFile)
      _ = try await harness.dispatch("task-repair-loop", scenarioPath: scenarioFile.path)
      let attempts = try harness.store.listAttempts(taskId: task.id)
      XCTAssertEqual(attempts.count, 2, caseName)
      let current = attempts[1]
      XCTAssertNotEqual(current.sessionId, first.sessionId, caseName)
      let latestGate = current.outcome?.latestGateResults.first(where: { $0.gateId == "verification" })
      if caseName == "missing" {
        XCTAssertEqual(latestGate?.decision, .rejected, caseName)
        XCTAssertEqual(latestGate?.stepExecutionId, "missing", caseName)
      } else if caseName == "rejected" {
        XCTAssertEqual(latestGate?.decision, .rejected, caseName)
      } else if caseName == "needs-work" {
        XCTAssertEqual(latestGate?.decision, .needsWork, caseName)
      } else {
        XCTAssertEqual(latestGate?.decision, .accepted, caseName)
      }
      let findings = try harness.store.listFindings(taskId: task.id)
      let synthetic = try XCTUnwrap(findings.first(where: { $0.id == syntheticId }))
      XCTAssertEqual(synthetic.status,
                     ["high", "mid", "human"].contains(caseName) ? .superseded : .open, caseName)
      let verdict = try harness.store.currentCompletionVerdict(taskId: task.id, attemptId: current.id)
      XCTAssertFalse(verdict.isSatisfied, caseName)
      if caseName == "human" {
        XCTAssertTrue(verdict.unmetRequirements.contains(.humanAcceptRequired), caseName)
      } else if caseName == "high" || caseName == "mid" {
        let substantiveId = "missing-required-gate-verification-substantive-\(caseName)"
        let substantive = try XCTUnwrap(findings.first(where: { $0.id == substantiveId }))
        XCTAssertEqual(substantive.status, .open, caseName)
        XCTAssertEqual(substantive.severity, caseName == "mid" ? .mid : .high, caseName)
        XCTAssertTrue(verdict.unmetRequirements.contains(.openBlockingFinding(
          fingerprint: substantive.fingerprint.key
        )), caseName)
      } else if caseName == "mismatched-lineage" {
        XCTAssertEqual(synthetic.sourceStepExecutionId, "different-lineage")
        XCTAssertTrue(verdict.unmetRequirements.contains(.openBlockingFinding(
          fingerprint: synthetic.fingerprint.key
        )), caseName)
      } else {
        XCTAssertTrue(verdict.unmetRequirements.contains(.openBlockingFinding(
          fingerprint: synthetic.fingerprint.key
        )), caseName)
      }
      let resolutions = try harness.store.listEvidence(taskId: task.id).filter {
        $0.payloadRef.inlinePayload?["resolvedFindingId"] == .string(syntheticId)
      }
      XCTAssertEqual(resolutions.count, ["high", "mid", "human"].contains(caseName) ? 1 : 0, caseName)
      let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
      XCTAssertEqual(try reopened.listFindings(taskId: task.id), findings, caseName)
    }
  }

  func testCancelledTaskDoesNotRetryOrCreateLegacyIncident() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let signal = TaskRunSignalState()
    let result = try await harness.dispatch(
      "task-repair-loop", beforeExecution: { _ in signal.request(2) }, signalState: signal
    )
    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.sessionId, attempt.sessionId)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertTrue(try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    )).acknowledged)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: harness.sessionStore.appendingPathComponent("supervision-record.json").path
    ))
    let rows = try harness.rowCounts(taskId: task.id)
    let refused = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(refused.exitCode, .failure, refused.stderr + refused.stdout)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), rows)
  }

  func testSecondRunStopsWhenEarlierDurableSessionExhaustsWallClockBudget() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.completion.requiresHumanAccept = true
    try harness.store.saveTask(task)

    let firstRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr + firstRun.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
    var firstSnapshot = try runtimeStore.load(sessionId: firstAttempt.sessionId)
    firstSnapshot.session.createdAt = firstSnapshot.session.updatedAt.addingTimeInterval(-5)
    try runtimeStore.save(firstSnapshot)

    task = try XCTUnwrap(harness.store.loadTask(id: task.id))
    task.guardPolicy.budget = BudgetGuard(maxWallClockMs: 4_000)
    try harness.store.saveTask(task)
    let version = try XCTUnwrap(harness.store.loadTask(id: task.id)).version
    let decision = await RielaCLIApplication().run([
      "task", "decide", task.id.rawValue, "--rerun", "repair",
      "--principal", "operator", "--expected-version", String(version),
      "--decision-id", "decision-wall-clock-rerun", "--session-store", harness.sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(decision.exitCode, .success, decision.stderr + decision.stdout)

    let secondRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(secondRun.exitCode, .success, secondRun.stderr + secondRun.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
    let violations = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
    XCTAssertTrue(violations.contains {
      $0.payloadRef.inlinePayload?["dimension"] == .string(BudgetDimension.wallClock.rawValue)
    })
  }

  func testTaskInactivityPersistsViolationAndStopsExactAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.inactivity = InactivityGuard(
      stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
    )
    try harness.store.saveTask(task)
    let scenario = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)
    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    let cancellation = try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertTrue(cancellation.acknowledged)
    let violations = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
    XCTAssertEqual(violations.filter {
      $0.payloadRef.inlinePayload?["kind"] == .string("inactivity")
    }.count, 1)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter {
      $0.producer == .policy(rule: "guard-policy-fail")
    }.count, 1)
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id, kind: .guardViolation), violations)
    XCTAssertTrue(try XCTUnwrap(reopened.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    )).acknowledged)
    let liveDecision = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).first {
      $0.id.rawValue.hasPrefix("decision-live-guard-")
    })
    let replayEvidenceId = EvidenceID(liveDecision.id.rawValue.replacingOccurrences(
      of: "decision-live-guard-", with: "evidence-live-decision-"
    ))
    let beforeReplay = try harness.rowCounts(taskId: task.id)
    let firstReplay = try reopened.applyDecision(
      liveDecision, expectedTaskVersion: -1, completion: .unmet([]),
      decisionEvidenceId: replayEvidenceId
    )
    let secondReplay = try reopened.applyDecision(
      liveDecision, expectedTaskVersion: -1, completion: .unmet([]),
      decisionEvidenceId: replayEvidenceId
    )
    XCTAssertEqual(firstReplay, secondReplay)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeReplay)

    let stalledHarness = try TaskExampleHarness()
    defer { stalledHarness.remove() }
    var stalledTask = try stalledHarness.seed("task-repair-loop")
    stalledTask.guardPolicy.inactivity = task.guardPolicy.inactivity
    try stalledHarness.store.saveTask(stalledTask)
    let stalledAdapter = try DelayedScenarioNodeAdapter(
      scenarioPath: scenario, emitsProgress: true, stopsAfterProgress: true
    )
    let stalled = try await stalledHarness.dispatch("task-repair-loop", nodeAdapter: stalledAdapter)
    XCTAssertEqual(stalled.exitCode, .failure, stalled.stderr + stalled.stdout)
    let stalledAttempt = try XCTUnwrap(stalledHarness.store.listAttempts(taskId: stalledTask.id).first)
    let stalledSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: stalledHarness.store.rootDirectory)
      .load(sessionId: stalledAttempt.sessionId)
    XCTAssertTrue(stalledSnapshot.session.executions.contains { $0.lastBackendEventAt != nil })
    XCTAssertTrue(try XCTUnwrap(stalledHarness.store.attemptCancellation(
      taskId: stalledTask.id, attemptId: stalledAttempt.id, sessionId: stalledAttempt.sessionId
    )).acknowledged)
    XCTAssertEqual(try stalledHarness.store.listEvidence(taskId: stalledTask.id, kind: .guardViolation)
      .filter { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") }.count, 1)
    XCTAssertEqual(try stalledHarness.store.listAttempts(taskId: stalledTask.id).count, 1)
  }

  func testTaskProgressPreventsInactivityAction() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.inactivity = InactivityGuard(
      stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
    )
    try harness.store.saveTask(task)
    let scenario = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: true)
    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertNil(try harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertFalse(try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
      .contains { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") })
  }

  func testTaskProgressBetweenObserverRecheckAndDecisionPreventsInactivityAction() async throws {
    for action in [ViolationAction.fail, .askDirector] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("task-repair-loop")
      task.guardPolicy.inactivity = InactivityGuard(
        stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
      )
      task.guardPolicy.onViolation = action
      task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
      try harness.store.saveTask(task)
      let scenario = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
      let adapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
      let barrier = InactivityDecisionBarrier(rootDirectory: harness.store.rootDirectory)
      let result = try await harness.dispatch(
        "task-repair-loop", nodeAdapter: adapter,
        afterInactivityRecheck: { try barrier.commitProgress() }
      )
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      XCTAssertGreaterThan(
        barrier.hits, 0, "action: \(action), entries: \(barrier.entries), error: \(barrier.failure ?? "none")"
      )
      XCTAssertEqual(barrier.rejectedPreconditions, 4)
      let attempts = try harness.store.listAttempts(taskId: task.id)
      XCTAssertEqual(attempts.count, 1)
      let attempt = try XCTUnwrap(attempts.first)
      XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
      XCTAssertNil(try harness.store.attemptCancellation(
        taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
      ))
      XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
      XCTAssertFalse(try harness.store.listDecisions(taskId: task.id).contains {
        $0.id.rawValue.hasPrefix("decision-live-guard-") || $0.id.rawValue.hasPrefix("decision-barrier-")
      })
      let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
      XCTAssertEqual(try reopened.listDecisions(taskId: task.id), try harness.store.listDecisions(taskId: task.id))
      XCTAssertEqual(try reopened.listAttempts(taskId: task.id), attempts)
      XCTAssertNil(try TaskDispatcher(store: reopened).pendingReservation(taskId: task.id))
    }

    let terminalHarness = try TaskExampleHarness()
    defer { terminalHarness.remove() }
    var terminalTask = try terminalHarness.seed("task-repair-loop")
    terminalTask.guardPolicy.inactivity = InactivityGuard(
      stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
    )
    try terminalHarness.store.saveTask(terminalTask)
    let scenario = terminalHarness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let terminalAdapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
    let terminalCommitted = DispatchSemaphore(value: 0)
    let terminalHits = InactivityBarrierCounter()
    let terminalReleases = InactivityBarrierCounter()
    let terminalResult = try await terminalHarness.dispatch(
      "task-repair-loop", nodeAdapter: terminalAdapter,
      afterTerminalPersistence: { terminalCommitted.signal() },
      afterInactivityRecheck: {
        terminalHits.mark()
        guard terminalCommitted.wait(timeout: .now() + 5) == .success else {
          throw WorkStoreError("terminal barrier did not reach canonical commit")
        }
        terminalReleases.mark()
      }
    )
    XCTAssertEqual(terminalResult.exitCode, .success, terminalResult.stderr + terminalResult.stdout)
    XCTAssertGreaterThan(terminalHits.count, 0)
    XCTAssertGreaterThan(terminalReleases.count, 0)
    XCTAssertEqual(try terminalHarness.store.loadTask(id: terminalTask.id)?.state, .succeeded)
    XCTAssertFalse(try terminalHarness.store.listDecisions(taskId: terminalTask.id).contains {
      $0.id.rawValue.hasPrefix("decision-live-guard-")
    })

    let cancelHarness = try TaskExampleHarness()
    defer { cancelHarness.remove() }
    var cancelTask = try cancelHarness.seed("task-repair-loop")
    cancelTask.guardPolicy.inactivity = terminalTask.guardPolicy.inactivity
    try cancelHarness.store.saveTask(cancelTask)
    let cancelTaskId = cancelTask.id
    let cancelAdapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
    let signal = TaskRunSignalState()
    let cancelHits = InactivityBarrierCounter()
    let cancelCommits = InactivityBarrierCounter()
    let cancelResult = try await cancelHarness.dispatch(
      "task-repair-loop", nodeAdapter: cancelAdapter,
      afterInactivityRecheck: {
        cancelHits.mark()
        signal.request(2)
        guard try signal.commitIfRequested(
          store: cancelHarness.store, taskId: cancelTaskId
        ) else {
          throw WorkStoreError("cancellation barrier did not commit")
        }
        cancelCommits.mark()
      }, signalState: signal
    )
    XCTAssertEqual(cancelResult.exitCode, .failure, cancelResult.stderr + cancelResult.stdout)
    XCTAssertGreaterThan(cancelHits.count, 0)
    XCTAssertGreaterThan(cancelCommits.count, 0)
    let cancelledAttempt = try XCTUnwrap(cancelHarness.store.listAttempts(taskId: cancelTask.id).first)
    XCTAssertTrue(try XCTUnwrap(cancelHarness.store.attemptCancellation(
      taskId: cancelTask.id, attemptId: cancelledAttempt.id, sessionId: cancelledAttempt.sessionId
    )).acknowledged)
    XCTAssertFalse(try cancelHarness.store.listDecisions(taskId: cancelTask.id).contains {
      $0.id.rawValue.hasPrefix("decision-live-guard-")
    })

    let idleHarness = try TaskExampleHarness()
    defer { idleHarness.remove() }
    var idleTask = try idleHarness.seed("task-repair-loop")
    idleTask.guardPolicy.inactivity = terminalTask.guardPolicy.inactivity
    try idleHarness.store.saveTask(idleTask)
    let idleAdapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
    let idleHits = InactivityBarrierCounter()
    let idleResult = try await idleHarness.dispatch(
      "task-repair-loop", nodeAdapter: idleAdapter, afterInactivityRecheck: { idleHits.mark() }
    )
    XCTAssertEqual(idleResult.exitCode, .failure, idleResult.stderr + idleResult.stdout)
    XCTAssertGreaterThan(idleHits.count, 0)
    XCTAssertEqual(try idleHarness.store.listDecisions(taskId: idleTask.id).filter {
      $0.id.rawValue.hasPrefix("decision-live-guard-")
    }.count, 1)
    XCTAssertEqual(try idleHarness.store.listEvidence(taskId: idleTask.id, kind: .guardViolation)
      .filter { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") }.count, 1)
  }

  func testTaskInactivityWarningAndReplayPreserveSingleObservation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.inactivity = InactivityGuard(
      stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
    )
    task.guardPolicy.onViolation = .warn
    try harness.store.saveTask(task)
    let scenario = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: false)
    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
    XCTAssertNil(try harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    let warnings = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
      .filter { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") }
    XCTAssertEqual(warnings.count, 1)
    XCTAssertFalse(try harness.store.listDecisions(taskId: task.id).contains {
      $0.producer == .policy(rule: "guard-policy-fail")
    })
    let rows = try harness.rowCounts(taskId: task.id)
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id, kind: .guardViolation)
      .filter { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") }, warnings)
    let replay = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(replay.exitCode, .failure, replay.stderr + replay.stdout)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), rows)
  }

  func testTaskInactivityProgressTerminalAndCancellationRacesPreservePrecedence() async throws {
    let completedHarness = try TaskExampleHarness()
    defer { completedHarness.remove() }
    var completedTask = try completedHarness.seed("task-repair-loop")
    completedTask.guardPolicy.inactivity = InactivityGuard(
      stallTimeoutMs: 170, monitorIntervalMs: 100, heartbeatBackends: ["codex-agent"]
    )
    try completedHarness.store.saveTask(completedTask)
    let scenario = completedHarness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let progressing = try DelayedScenarioNodeAdapter(scenarioPath: scenario, emitsProgress: true)
    let lateSignal = TaskRunSignalState()
    let completed = try await completedHarness.dispatch(
      "task-repair-loop", nodeAdapter: progressing,
      afterTerminalPersistence: { lateSignal.request(2) }, signalState: lateSignal
    )
    XCTAssertEqual(completed.exitCode, .success, completed.stderr + completed.stdout)
    let completedAttempt = try XCTUnwrap(completedHarness.store.listAttempts(taskId: completedTask.id).first)
    let completedSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: completedHarness.store.rootDirectory
    ).load(sessionId: completedAttempt.sessionId)
    XCTAssertEqual(completedSnapshot.session.status, .completed)
    XCTAssertTrue(completedSnapshot.session.executions.contains { $0.lastBackendEventAt != nil })
    XCTAssertEqual(try completedHarness.store.loadTask(id: completedTask.id)?.state, .succeeded)
    XCTAssertNil(try completedHarness.store.attemptCancellation(
      taskId: completedTask.id, attemptId: completedAttempt.id, sessionId: completedAttempt.sessionId
    ))
    XCTAssertFalse(try completedHarness.store.listEvidence(taskId: completedTask.id, kind: .guardViolation)
      .contains { $0.payloadRef.inlinePayload?["kind"] == .string("inactivity") })
    let completedRows = try completedHarness.rowCounts(taskId: completedTask.id)
    let completedReplay = try await completedHarness.dispatch("task-repair-loop")
    XCTAssertEqual(completedReplay.exitCode, .failure, completedReplay.stderr + completedReplay.stdout)
    XCTAssertEqual(try completedHarness.rowCounts(taskId: completedTask.id), completedRows)

    let cancelledHarness = try TaskExampleHarness()
    defer { cancelledHarness.remove() }
    var cancelledTask = try cancelledHarness.seed("task-repair-loop")
    cancelledTask.guardPolicy.inactivity = completedTask.guardPolicy.inactivity
    try cancelledHarness.store.saveTask(cancelledTask)
    let earlySignal = TaskRunSignalState()
    let cancelled = try await cancelledHarness.dispatch(
      "task-repair-loop", beforeExecution: { _ in earlySignal.request(2) }, signalState: earlySignal
    )
    XCTAssertEqual(cancelled.exitCode, .failure, cancelled.stderr + cancelled.stdout)
    let cancelledAttempt = try XCTUnwrap(cancelledHarness.store.listAttempts(taskId: cancelledTask.id).first)
    XCTAssertEqual(cancelledAttempt.outcome?.failureKind, .cancelled)
    XCTAssertTrue(try XCTUnwrap(cancelledHarness.store.attemptCancellation(
      taskId: cancelledTask.id, attemptId: cancelledAttempt.id, sessionId: cancelledAttempt.sessionId
    )).acknowledged)
    XCTAssertEqual(try cancelledHarness.store.loadTask(id: cancelledTask.id)?.state, .cancelled)
    XCTAssertNil(try TaskDispatcher(store: cancelledHarness.store).pendingReservation(taskId: cancelledTask.id))
    let cancelledRows = try cancelledHarness.rowCounts(taskId: cancelledTask.id)
    let cancelledReplay = try await cancelledHarness.dispatch("task-repair-loop")
    XCTAssertEqual(cancelledReplay.exitCode, .failure, cancelledReplay.stderr + cancelledReplay.stdout)
    XCTAssertEqual(try cancelledHarness.rowCounts(taskId: cancelledTask.id), cancelledRows)
  }

  private func failedRepairScenario(in harness: TaskExampleHarness) throws -> String {
    let source = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json")
    var scenario = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: source)
    ) as? [String: [String: Any]])
    var repair = try XCTUnwrap(scenario["repair"])
    repair["fail"] = true
    scenario["repair"] = repair
    let failed = harness.sessionStore.appendingPathComponent("failed-repair-scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: failed)
    return failed.path
  }
}
