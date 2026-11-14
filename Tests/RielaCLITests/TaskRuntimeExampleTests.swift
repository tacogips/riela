import Foundation
import RielaCore
@testable import RielaWork
import XCTest
@testable import RielaCLI

final class TaskRuntimeExampleTests: XCTestCase {
  func testRepairExampleRunsTheRequiredGateForARealTaskAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.completion = CompletionContract(
      gates: [GateDeclaration(id: "verification", stepId: "verify", required: true)],
      acceptance: [AcceptanceCriterion(
        id: "fixture-passes", statement: "The fixture check passes", gateIds: ["verification"]
      )]
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let response = try harness.decode(result)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(response.attemptId, attempt.id.rawValue)
    XCTAssertEqual(response.sessionId, attempt.sessionId)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertEqual(attempt.outcome?.latestGateResults.first?.gateId, "verification")
    XCTAssertEqual(attempt.outcome?.latestGateResults.first?.decision, .accepted)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(requiredGates: task.completion.gates, session: snapshot.session),
      GateAcceptance(met: true, note: "The fixture check passed.")
    )
    XCTAssertFalse(try harness.store.listEvidence(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    let accepted = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).last)
    XCTAssertEqual(accepted.kind, .accept)
    XCTAssertFalse(accepted.causedBy.isEmpty)
  }

  func testRejectedGateRecoveryConsumesPendingRequestAndAcceptsSecondAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
    task.completion = CompletionContract(
      gates: [GateDeclaration(id: "verification", stepId: "verify", required: true)],
      acceptance: [AcceptanceCriterion(
        id: "fixture-passes", statement: "The fixture check passes", gateIds: ["verification"]
      )]
    )
    try harness.store.saveTask(task)
    let rejectedScenario = try repairScenario(in: harness, decision: .rejected)

    let first = try await harness.dispatch("task-repair-loop", scenarioPath: rejectedScenario.path)
    XCTAssertEqual(first.exitCode, .success, first.stderr + first.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    let firstSession = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: firstAttempt.sessionId).session
    XCTAssertEqual(firstSession.status, .completed)
    XCTAssertEqual(firstAttempt.outcome?.latestGateResults.first?.decision, .rejected)
    XCTAssertNotEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    let recovery = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).last)
    XCTAssertEqual(recovery.kind, .recover(fromGateId: "verification"))
    XCTAssertFalse(recovery.causedBy.isEmpty)
    let dispatcher = TaskDispatcher(store: harness.store)
    let pending = try XCTUnwrap(dispatcher.pendingReservation(taskId: task.id))
    XCTAssertEqual(pending.decisionId, recovery.id)
    XCTAssertEqual(pending.predecessorAttemptId, firstAttempt.id)
    XCTAssertEqual(pending.entry, .recoverFromGate("verification"))

    let second = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(second.exitCode, .success, second.stderr + second.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let recovered = try XCTUnwrap(attempts.last)
    XCTAssertNotEqual(recovered.id, firstAttempt.id)
    XCTAssertNotEqual(recovered.sessionId, firstAttempt.sessionId)
    XCTAssertEqual(recovered.entry, .recoverFromGate("verification"))
    XCTAssertEqual(recovered.outcome?.latestGateResults.first?.decision, .accepted)
    XCTAssertEqual(try harness.decode(second).sessionId, recovered.sessionId)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
    let decisions = try harness.store.listDecisions(taskId: task.id)
    let evidence = try harness.store.listEvidence(taskId: task.id)
    XCTAssertTrue(decisions.contains { $0.kind == .accept && !$0.causedBy.isEmpty })
    XCTAssertTrue(evidence.contains { $0.attemptId == recovered.id && $0.kind == .gate })

    let replay = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(replay.exitCode, .failure, replay.stderr + replay.stdout)
    XCTAssertTrue(replay.stdout.contains("not eligible for dispatch from state 'succeeded'"))
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id), decisions)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id), evidence)
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
  }

  func testStandaloneNonAcceptedRepairGateFailsAndRetainsEvidence() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for decision in [LoopGateDecision.rejected, .needsWork] {
      let scenario = try repairScenario(in: harness, decision: decision)
      let standaloneStore = harness.sessionStore.appendingPathComponent("standalone-\(decision.rawValue)")
      let artifactStore = harness.sessionStore.appendingPathComponent("artifacts-\(decision.rawValue)")
      let result = await RielaCLIApplication().run([
        "workflow", "run", "task-repair-loop",
        "--workflow-definition-dir", harness.examples.path,
        "--mock-scenario", scenario.path,
        "--session-store", standaloneStore.path,
        "--artifact-root", artifactStore.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
      let run = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(run.status, .failed)
      XCTAssertEqual(run.loopEvidence?.gateCount, 1)
      let canonical = try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: standaloneStore.path)
      ).load(sessionId: run.session.sessionId)
      let artifact = try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactStore.path)
        .load(sessionId: run.session.sessionId)
      for snapshot in [canonical, artifact] {
        XCTAssertEqual(snapshot.session.status, .failed)
        XCTAssertEqual(snapshot.loopEvidence?.gates.first?.decision, decision)
      }
    }
  }

  private func repairScenario(in harness: TaskExampleHarness, decision: LoopGateDecision) throws -> URL {
    let source = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json")
    var scenario = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: source)
    ) as? [String: [String: Any]])
    var verify = try XCTUnwrap(scenario["verify"])
    var payload = try XCTUnwrap(verify["payload"] as? [String: Any])
    var gate = try XCTUnwrap(payload["loopGate"] as? [String: Any])
    gate["decision"] = decision.rawValue
    gate["acceptance"] = ["met": false, "note": "Fixture check failed."]
    payload["loopGate"] = gate
    verify["payload"] = payload
    scenario["verify"] = verify
    let rejectedScenario = harness.sessionStore.appendingPathComponent("\(decision.rawValue)-gate.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: rejectedScenario)
    return rejectedScenario
  }

  func testRepairExampleGuardStopsAfterPersistingViolation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 0),
      onViolation: .fail
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
    let violations = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
    XCTAssertEqual(violations.count, 1)
    guard case let .stop(reference)? = try harness.store.listDecisions(taskId: task.id).last?.kind else {
      return XCTFail("terminal guard decision must stop the task")
    }
    XCTAssertEqual(reference.evidenceId, violations[0].id)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    let decisions = try harness.store.listDecisions(taskId: task.id)
    let replay = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(replay.exitCode, .failure, replay.stderr + replay.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id), attempts)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id), decisions)
  }

  func testRepairExampleCapacityWaitDoesNotReserveAnAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let beforeRows = try harness.rowCounts(taskId: task.id)
    let beforeBytes = try harness.fileBytes()

    let result = try await harness.dispatch("task-repair-loop", capacity: 0)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let response = try harness.decode(result)
    XCTAssertEqual(response.status, "waiting")
    XCTAssertEqual(response.waitReason, .capacity)
    XCTAssertNil(response.attemptId)
    XCTAssertNil(response.sessionId)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeRows)
    XCTAssertEqual(try harness.fileBytes(), beforeBytes)
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    XCTAssertTrue(try reopened.openWritable().query("SELECT attempt_id FROM work_leases").isEmpty)
  }

  func testRepairExampleWarningPreservesEvidenceAndAllowsSatisfiedCompletion() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 0),
      onViolation: .warn
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id, kind: .guardViolation).count, 1)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).last?.kind, .accept)
  }

}

extension TaskRuntimeExampleTests {
  func testDirectorExampleProducesOneRecommendationInARealTaskAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-agent-director")

    let result = try await harness.dispatch("task-agent-director")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 1)
    let attempt = try XCTUnwrap(attempts.first)
    XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.executions.first?.acceptedOutput?.payload["kind"], .string("accept"))
  }

  func testConfiguredDirectorChildRunsOrdinarilyAndCannotAcceptFailedWork() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    task.director.humanEscalation.escalateAfterFailedAttempts = 1
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 3)
    try harness.store.saveTask(task)
    let workScenario = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.examples
      .appendingPathComponent("task-repair-loop/mock-scenario.json"))) as? [String: Any]
    let directorScenario = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.examples
      .appendingPathComponent("task-agent-director/mock-scenario.json"))) as? [String: Any]
    let combined = try XCTUnwrap(workScenario).merging(try XCTUnwrap(directorScenario)) { _, child in child }
    let scenario = harness.sessionStore.appendingPathComponent("director-combined-scenario.json")
    try JSONSerialization.data(withJSONObject: combined).write(to: scenario)

    let result = try await harness.dispatch(
      "task-repair-loop", failRepairNode: true,
      directorBundle: harness.bundle("task-agent-director"), scenarioPath: scenario.path
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let judged = try XCTUnwrap(attempts.first(where: { $0.entry != .director }))
    let child = try XCTUnwrap(attempts.first(where: { $0.entry == .director }))
    XCTAssertEqual(judged.outcome?.sessionStatus, .failed)
    XCTAssertEqual(child.judgedAttemptId, judged.id)
    XCTAssertEqual(child.outcome?.sessionStatus, .completed)
    let context = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
      $0.attemptId == child.id && $0.payloadRef.inlinePayload?["taskView"] != nil
    }))
    let viewJSON = try XCTUnwrap(context.payloadRef.inlinePayload?["taskView"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receivedView = try decoder.decode(AgentDirectorTaskView.self, from: JSONEncoder().encode(viewJSON))
    XCTAssertEqual(receivedView.task.id, task.id)
    XCTAssertEqual(receivedView.judgedAttempt.id, judged.id)
    XCTAssertEqual(receivedView.judgedAttempt.outcome, judged.outcome)
    XCTAssertEqual(receivedView.remainingAttempts, 1)
    let hostJSON = try XCTUnwrap(context.payloadRef.inlinePayload?["hostCapabilityContext"])
    let hostContext = try decoder.decode(
      WorkflowPlanningCapabilityContext.self, from: JSONEncoder().encode(hostJSON)
    )
    XCTAssertEqual(hostContext.host.hostId, "local")
    XCTAssertFalse(hostContext.requirements.isEmpty)
    let childSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: child.sessionId)
    let invocation = try XCTUnwrap(childSnapshot.session.executions.first)
    guard case let .object(nodeVariables)? = invocation.inputSnapshot?["mergedVariables"] else {
      return XCTFail("actual director node has no captured merged variables")
    }
    XCTAssertEqual(nodeVariables["taskView"], viewJSON)
    XCTAssertEqual(nodeVariables["hostCapabilityContext"], hostJSON)
    XCTAssertEqual(invocation.backend, .codexAgent)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
  }

  func testDirectorEscalationRequiresConfigurationThresholdAndCapacity() throws {
    for caseName in ["unconfigured", "below-threshold", "no-capacity", "director-child"] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("task-repair-loop")
      task.state = .verifying
      task.guardPolicy.budget = BudgetGuard(maxAttempts: caseName == "no-capacity" ? 1 : 3)
      if caseName != "unconfigured" {
        task.director.agentWorkflow = WorkflowReference(
          name: "task-agent-director", scope: WorkflowScope.project.rawValue,
          workflowDefinitionDir: harness.examples.path
        )
      }
      task.director.humanEscalation.escalateAfterFailedAttempts = caseName == "below-threshold" ? 2 : 1
      try harness.store.saveTask(task)
      let attempt = Attempt(
        id: AttemptID("judged-\(caseName)"), taskId: task.id,
        sessionId: "session-\(caseName)", entry: caseName == "director-child" ? .director : .start,
        state: .reconciled,
        outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
      )
      try harness.store.saveAttempt(attempt)
      let violationIds = caseName == "no-capacity" ? [EvidenceID("budget-\(caseName)")] : []
      let result = try TaskGuardCoordinator(store: harness.store).evaluateAndApply(
        task: task, latestAttempt: attempt, snapshot: GuardSnapshot(attemptCount: 1),
        completion: .unmet([]), failedStepId: "repair", violationEvidenceIds: violationIds,
        decisionId: DecisionID("decision-\(caseName)"),
        decisionEvidenceId: EvidenceID("decision-evidence-\(caseName)"), terminal: true
      )
      XCTAssertFalse(result.requiresDirectorChild, caseName)
      XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 1, caseName)
      XCTAssertFalse(try harness.store.listDecisions(taskId: task.id).contains {
        $0.producer == .policy(rule: "director-escalation")
      }, caseName)
      if caseName == "no-capacity" {
        XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
        XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
      }
    }
  }

  func testOrdinaryDirectorChildReceivesDurableGateFindingAndGuardView() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    task.guardPolicy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 0),
      budget: BudgetGuard(maxAttempts: 3), onViolation: .askDirector
    )
    try harness.store.saveTask(task)
    let source = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json")
    var work = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: source)
    ) as? [String: [String: Any]])
    var verify = try XCTUnwrap(work["verify"])
    var payload = try XCTUnwrap(verify["payload"] as? [String: Any])
    var gate = try XCTUnwrap(payload["loopGate"] as? [String: Any])
    gate["decision"] = "rejected"
    gate["severityCounts"] = ["high": 1, "medium": 0, "low": 0, "informational": 0]
    gate["blockingFindings"] = [[
      "id": "judged-defect", "severity": "high", "message": "judged repair failed review"
    ]]
    gate["acceptance"] = ["met": false, "note": "judged repair still fails"]
    payload["loopGate"] = gate
    verify["payload"] = payload
    work["verify"] = verify
    let directorSource = harness.examples.appendingPathComponent("task-agent-director/mock-scenario.json")
    let director = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: directorSource)
    ) as? [String: [String: Any]])
    let scenario = harness.sessionStore.appendingPathComponent("director-durable-view-scenario.json")
    try JSONSerialization.data(withJSONObject: work.merging(director) { _, child in child }).write(to: scenario)
    let result = try await harness.dispatch(
      "task-repair-loop", directorBundle: harness.bundle("task-agent-director"),
      scenarioPath: scenario.path
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let judged = try XCTUnwrap(attempts.first(where: { $0.entry != .director }))
    let child = try XCTUnwrap(attempts.first(where: { $0.entry == .director }))
    XCTAssertEqual(child.judgedAttemptId, judged.id)
    let context = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
      $0.attemptId == child.id && $0.payloadRef.inlinePayload?["taskView"] != nil
    }))
    let viewJSON = try XCTUnwrap(context.payloadRef.inlinePayload?["taskView"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let view = try decoder.decode(AgentDirectorTaskView.self, from: JSONEncoder().encode(viewJSON))
    XCTAssertEqual(view.task.id, task.id)
    XCTAssertEqual(view.judgedAttempt.id, judged.id)
    XCTAssertEqual(view.judgedAttempt.outcome, judged.outcome)
    XCTAssertEqual(view.completion, try harness.store.currentCompletionVerdict(
      taskId: task.id, attemptId: judged.id
    ))
    XCTAssertFalse(view.completion.isSatisfied)
    XCTAssertFalse(view.guardViolations.isEmpty)
    XCTAssertFalse(view.openFindings.isEmpty)
    XCTAssertEqual(view.openFindings, try harness.store.listFindings(taskId: task.id, status: .open))
    let judgedEvidence = try harness.store.listEvidence(taskId: task.id).filter { $0.attemptId == judged.id }
    XCTAssertFalse(judgedEvidence.isEmpty)
    XCTAssertTrue(view.evidenceSummary.contains { $0.kind == .guardViolation })
    XCTAssertTrue(view.evidenceSummary.contains { $0.kind == .finding })
    for delivered in view.evidenceSummary {
      let stored = try XCTUnwrap(judgedEvidence.first(where: { $0.id == delivered.id }))
      XCTAssertEqual(delivered.payloadRef, stored.payloadRef)
    }
    XCTAssertEqual(view.remainingAttempts, 1)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: child.sessionId)
    guard case let .object(variables)? = snapshot.session.executions.first?.inputSnapshot?["mergedVariables"] else {
      return XCTFail("ordinary director node has no captured merged variables")
    }
    XCTAssertEqual(variables["taskView"], viewJSON)
    XCTAssertEqual(variables["hostCapabilityContext"], context.payloadRef.inlinePayload?["hostCapabilityContext"])
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
  }

  func testConfiguredDirectorChildCanAcceptDurablySatisfiedJudgedWork() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 2)
    try harness.store.saveTask(task)
    let judged = Attempt(
      id: AttemptID("judged-work"), taskId: task.id,
      sessionId: "judged-session", state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(
      id: EvidenceID("judged-success"), taskId: task.id, attemptId: judged.id,
      kind: .contextSnapshot, producedBy: .runtime,
      payloadRef: .inline(["status": .string("completed")]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try harness.store.saveEvidence(evidence)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .satisfied,
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
    )
    let result = try await harness.dispatchDirector(view: view)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let child = try XCTUnwrap(attempts.first(where: { $0.entry == .director }))
    XCTAssertEqual(child.judgedAttemptId, judged.id)
    XCTAssertEqual(child.outcome?.sessionStatus, .completed)
    let childContext = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
      $0.attemptId == child.id && $0.payloadRef.inlinePayload?["taskView"] != nil
    }))
    let deliveredView = try XCTUnwrap(childContext.payloadRef.inlinePayload?["taskView"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedView = try decoder.decode(AgentDirectorTaskView.self, from: JSONEncoder().encode(deliveredView))
    XCTAssertEqual(decodedView.remainingAttempts, 0)
    XCTAssertEqual(decodedView.task, task)
    XCTAssertEqual(decodedView.judgedAttempt, judged)
    XCTAssertEqual(decodedView.completion, .satisfied)
    XCTAssertEqual(decodedView.guardViolations, [])
    XCTAssertEqual(decodedView.openFindings, [])
    XCTAssertEqual(decodedView.evidenceSummary, [evidence])
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
    let decision = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).first(where: {
      $0.producer == .agent(sessionId: child.sessionId)
    }))
    let replay = try harness.store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("evidence-decision-\(decision.id.rawValue)")
    )
    XCTAssertEqual(replay.task.state, .succeeded)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
  }

  func testReservedDirectorChildResumesSameSessionAfterReopen() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged-work"), taskId: task.id,
                         sessionId: "judged-session", state: .reconciled,
                         outcome: AttemptOutcome(sessionStatus: .completed))
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(id: EvidenceID("judged-evidence"), taskId: task.id,
                            attemptId: judged.id, kind: .contextSnapshot, producedBy: .runtime,
                            payloadRef: .inline(["owner": .string("judged")]),
                            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    try harness.store.saveEvidence(evidence)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .satisfied,
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
    )
    do {
      _ = try await harness.dispatchDirector(view: view, beforeExecution: { _ in
        throw WorkStoreError("injected prelaunch interruption")
      })
      XCTFail("director child unexpectedly launched")
    } catch {
      XCTAssertTrue(String(describing: error).contains("injected prelaunch interruption"))
    }
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    let reserved = try XCTUnwrap(reopened.listAttempts(taskId: task.id).first(where: { $0.entry == .director }))
    XCTAssertEqual(reserved.state, .prepared)
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: reserved.sessionId).session.status, .created)
    let originalScenario = harness.examples.appendingPathComponent("task-agent-director/mock-scenario.json")
    var scenario = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: originalScenario)
    ) as? [String: [String: Any]])
    scenario["director"]?["usage"] = ["input_tokens": 3, "output_tokens": 4, "total_tokens": 7]
    let childScenario = harness.sessionStore.appendingPathComponent("director-usage-scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: childScenario)
    let directorBundle = try harness.bundle("task-agent-director")
    XCTAssertNil(directorBundle.workflow.loop)
    let completed = try await harness.dispatch(
      "task-repair-loop", directorBundle: directorBundle,
      scenarioPath: childScenario.path
    )
    XCTAssertEqual(completed.exitCode, .success, completed.stderr + completed.stdout)
    let child = try XCTUnwrap(reopened.loadAttempt(id: reserved.id))
    XCTAssertEqual(child.sessionId, reserved.sessionId)
    XCTAssertEqual(child.taskId, task.id)
    XCTAssertEqual(child.judgedAttemptId, judged.id)
    XCTAssertEqual(child.outcome?.sessionStatus, .completed)
    XCTAssertEqual(child.outcome?.costs.map(\.totalTokens), [7])
    XCTAssertNil(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: child.sessionId).loopEvidence)
    XCTAssertEqual(try reopened.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try reopened.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
    let decisionsBeforeReplay = try reopened.listDecisions(taskId: task.id)
    let evidenceBeforeReplay = try reopened.listEvidence(taskId: task.id)
    let replay = try await harness.dispatch(
      "task-repair-loop", directorBundle: directorBundle,
      scenarioPath: childScenario.path
    )
    XCTAssertEqual(replay.exitCode, .success)
    XCTAssertEqual(try reopened.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try reopened.loadAttempt(id: child.id)?.outcome?.costs, child.outcome?.costs)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id), decisionsBeforeReplay)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id), evidenceBeforeReplay)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id).filter {
      $0.producer == .policy(rule: "director-child")
    }.count, 1)
  }

  func testAuthorizedDirectorChildWaitsForHumanAfterInterruptedLaunch() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged-work"), taskId: task.id,
                         sessionId: "judged-session", state: .reconciled,
                         outcome: AttemptOutcome(sessionStatus: .completed))
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(id: EvidenceID("judged-evidence"), taskId: task.id,
                            attemptId: judged.id, kind: .contextSnapshot, producedBy: .runtime,
                            payloadRef: .inline(["owner": .string("judged")]),
                            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    try harness.store.saveEvidence(evidence)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .satisfied,
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
    )
    do {
      _ = try await harness.dispatchDirector(view: view, beforeExecution: { reservation in
        _ = try harness.store.authorizeAttemptLaunch(
          attemptId: reservation.attempt.id, launchToken: reservation.launchToken
        )
        throw WorkStoreError("injected post-authorization interruption")
      })
      XCTFail("director child unexpectedly launched")
    } catch {
      XCTAssertTrue(String(describing: error).contains("injected post-authorization interruption"))
    }
    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    let child = try XCTUnwrap(reopened.listAttempts(taskId: task.id).first(where: { $0.entry == .director }))
    XCTAssertEqual(child.launch?.phase, .authorized)
    let result = try await harness.dispatch(
      "task-repair-loop", directorBundle: harness.bundle("task-agent-director")
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try reopened.loadTask(id: task.id)?.state, .waiting)
    XCTAssertEqual(try reopened.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try reopened.loadAttempt(id: child.id)?.sessionId, child.sessionId)
    XCTAssertEqual(try reopened.loadAttempt(id: child.id)?.state, .running)
    XCTAssertEqual(try reopened.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try reopened.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id).filter {
      $0.producer == .policy(rule: "director-uncertain-launch")
    }.count, 1)
    let replay = try await harness.dispatch(
      "task-repair-loop", directorBundle: harness.bundle("task-agent-director")
    )
    XCTAssertEqual(replay.exitCode, .success)
    XCTAssertEqual(try reopened.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try reopened.listDecisions(taskId: task.id).filter {
      $0.producer == .policy(rule: "director-uncertain-launch")
    }.count, 1)
  }

  func testDirectorChildCancellationAcknowledgesExactTerminalSession() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let ((task, judged), (evidence, view)) = try seedJudgedDirectorView(harness)
    let result = try await harness.dispatchDirector(view: view, beforeExecution: { reservation in
      let decision = Decision(
        id: DecisionID("human-cancel-child"), taskId: task.id, attemptId: reservation.attempt.id,
        producer: .human(principal: "test"), kind: .cancel,
        reason: "stop this child", causedBy: [EvidenceID("evidence-placement-\(reservation.attempt.id.rawValue)")],
        createdAt: Date()
      )
      _ = try harness.store.applyDecision(
        decision, expectedTaskVersion: reservation.task.version,
        completion: .unmet([]), decisionEvidenceId: EvidenceID("human-cancel-evidence")
      )
    })
    XCTAssertEqual(result.exitCode, .failure)
    let child = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first(where: { $0.entry == .director }))
    XCTAssertEqual(child.state, .reconciled)
    XCTAssertEqual(child.outcome?.failureKind, .cancelled)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try harness.store.attemptCancellation(
      taskId: task.id, attemptId: child.id, sessionId: child.sessionId
    )?.acknowledged, true)
    XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
    let replay = try await harness.dispatch(
      "task-repair-loop", directorBundle: harness.bundle("task-agent-director")
    )
    XCTAssertEqual(replay.exitCode, .failure)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
  }

  func testDirectorChildCannotOverwriteNewerHumanWait() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let ((task, judged), (evidence, view)) = try seedJudgedDirectorView(harness)
    do {
      _ = try await harness.dispatchDirector(view: view, beforeExecution: { reservation in
        let decision = Decision(
          id: DecisionID("human-wait-child"), taskId: task.id, attemptId: judged.id,
          producer: .human(principal: "test"), kind: .wait(.human),
          reason: "review before accepting", causedBy: [evidence.id], createdAt: Date()
        )
        _ = try harness.store.applyDecision(
          decision, expectedTaskVersion: reservation.task.version,
          completion: .unmet([]), decisionEvidenceId: EvidenceID("human-wait-evidence")
        )
      })
      XCTFail("stale director decision unexpectedly applied")
    } catch {
      XCTAssertTrue(String(describing: error).contains("stale"), "\(error)")
    }
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    let child = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first(where: { $0.entry == .director }))
    XCTAssertEqual(child.state, .reconciled)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter {
      if case .agent = $0.producer { return true }
      return false
    }.count, 0)
    XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
  }

  func testDirectorInvalidRerunAndRecoveryTargetsEscalateWithoutPendingRequest() async throws {
    for kind in ["rerun", "recover"] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      let ((task, judged), (evidence, view)) = try seedJudgedDirectorView(harness)
      let targetKey = kind == "rerun" ? "fromStepId" : "fromGateId"
      let response: [String: Any] = ["director": [
        "provider": "scenario-mock", "model": "gpt-5.4-mini", "when": ["always": true],
        "payload": ["kind": kind, "reason": "try missing target", targetKey: "missing"]
      ]]
      let scenario = harness.sessionStore.appendingPathComponent("invalid-\(kind)-scenario.json")
      try JSONSerialization.data(withJSONObject: response).write(to: scenario)
      let result = try await harness.dispatchDirector(view: view, scenarioPath: scenario.path)
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
      XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
      let escalation = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).first(where: {
        $0.producer == .policy(rule: "director-escalation")
      }))
      XCTAssertTrue(escalation.reason.contains(kind == "rerun" ? "target step" : "recovery gate"))
      XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
      XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
      XCTAssertEqual(try harness.store.listEvidence(taskId: task.id).first(where: { $0.id == evidence.id }), evidence)
    }
  }

  func testDirectorRerunEscalatesWhenChildExhaustsWallClockBudget() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let (seeded, judged) = try seedJudgedDirectorView(harness).0
    var task = seeded
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 3, maxWallClockMs: 1_000)
    try harness.store.saveTask(task)
    let now = Date()
    let judgedSession = WorkflowSession(
      workflowId: "task-repair-loop", sessionId: judged.sessionId,
      status: .completed, entryStepId: "repair",
      createdAt: now.addingTimeInterval(-0.1), updatedAt: now
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .save(WorkflowRuntimePersistenceSnapshot(session: judgedSession))
    let evidence = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .unmet([]),
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 1
    )
    let response: [String: Any] = ["director": [
      "provider": "scenario-mock", "model": "gpt-5.4-mini", "when": ["always": true],
      "payload": ["kind": "rerun", "reason": "try repair", "fromStepId": "repair"]
    ]]
    let scenario = harness.sessionStore.appendingPathComponent("wall-clock-director.json")
    try JSONSerialization.data(withJSONObject: response).write(to: scenario)
    let root = harness.store.rootDirectory
    let result = try await harness.dispatchDirector(
      view: view, scenarioPath: scenario.path, beforeExecution: { reservation in
        let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
        var snapshot = try persistence.load(sessionId: reservation.attempt.sessionId)
        snapshot.session.createdAt = Date().addingTimeInterval(-2)
        try persistence.save(snapshot)
      }
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
    let escalation = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).first(where: {
      $0.producer == .policy(rule: "director-escalation")
    }))
    XCTAssertTrue(escalation.reason.contains("wallClock"))
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
  }

  func testDirectorSetupFailureEscalatesWithoutChildReservation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(name: "missing-director")
    try harness.store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged-work"), taskId: task.id,
                         sessionId: "judged-session", state: .reconciled,
                         outcome: AttemptOutcome(sessionStatus: .failed))
    try harness.store.saveAttempt(judged)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .unmet([]),
      guardViolations: [], openFindings: [], evidenceSummary: [], remainingAttempts: 0
    )
    let result = try await harness.dispatchDirector(view: view)
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertEqual(try harness.decode(result).statusKind, .waiting)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id), [judged])
    XCTAssertTrue(try harness.store.listDecisions(taskId: task.id).contains {
      $0.producer == .policy(rule: "director-escalation") && $0.kind == .wait(.human)
    })
  }

  func testDirectorRejectReportsTerminalFailure() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(id: AttemptID("judged-work"), taskId: task.id,
                         sessionId: "judged-session", state: .reconciled,
                         outcome: AttemptOutcome(sessionStatus: .completed))
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(id: EvidenceID("judged-evidence"), taskId: task.id,
                            attemptId: judged.id, kind: .contextSnapshot, producedBy: .runtime,
                            payloadRef: .inline([:]), createdAt: Date())
    try harness.store.saveEvidence(evidence)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .satisfied,
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
    )
    let scenario = harness.sessionStore.appendingPathComponent("reject-director.json")
    let source = harness.examples.appendingPathComponent("task-agent-director/mock-scenario.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    var director = try XCTUnwrap(object["director"] as? [String: Any])
    director["payload"] = ["kind": "reject", "reason": "reviewed failure"]
    object["director"] = director
    try JSONSerialization.data(withJSONObject: object).write(to: scenario)
    let result = try await harness.dispatchDirector(view: view, scenarioPath: scenario.path)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(try harness.decode(result).statusKind, .failed)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
    let replay = try await harness.dispatch(
      "task-repair-loop", directorBundle: harness.bundle("task-agent-director"),
      scenarioPath: scenario.path
    )
    XCTAssertEqual(replay.exitCode, .failure)
    XCTAssertEqual(try harness.decode(replay).statusKind, .failed)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
  }

  func testDirectorAdmissionBudgetDenialEscalatesWithoutChildCharge() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.guardPolicy.budget = BudgetGuard(maxAttempts: 1)
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(
      id: AttemptID("judged-work"), taskId: task.id,
      sessionId: "judged-session", state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    try harness.store.saveAttempt(judged)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .unmet([.acceptanceAbsent]),
      guardViolations: [], openFindings: [], evidenceSummary: [], remainingAttempts: 0
    )
    let result = try await harness.dispatchDirector(view: view)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id), [judged])
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertTrue(try harness.store.listDecisions(taskId: task.id).contains(where: {
      $0.producer == .policy(rule: "director-escalation") && $0.kind == .wait(.human)
    }))
  }

  func testForbiddenOutputAndFailedDirectorChildEscalateWithoutRecursion() async throws {
    for failedChild in [false, true] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("task-repair-loop")
      task.state = .verifying
      task.director.agentWorkflow = WorkflowReference(
        name: "task-agent-director", scope: WorkflowScope.project.rawValue,
        workflowDefinitionDir: harness.examples.path
      )
      try harness.store.saveTask(task)
      let judged = Attempt(
        id: AttemptID("judged-work"), taskId: task.id,
        sessionId: "judged-session", state: .reconciled,
        outcome: AttemptOutcome(sessionStatus: .completed)
      )
      try harness.store.saveAttempt(judged)
      let evidence = Evidence(
        id: EvidenceID("judged-evidence"), taskId: task.id, attemptId: judged.id,
        kind: .contextSnapshot, producedBy: .runtime,
        payloadRef: .inline(["status": .string("completed")]),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
      try harness.store.saveEvidence(evidence)
      let view = AgentDirectorTaskView(
        task: task, judgedAttempt: judged, completion: .satisfied,
        guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
      )
      let scenario = harness.sessionStore.appendingPathComponent("forbidden-director.json")
      let source = harness.examples.appendingPathComponent("task-agent-director/mock-scenario.json")
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
      var director = try XCTUnwrap(object["director"] as? [String: Any])
      director["payload"] = failedChild
        ? ["kind": "accept", "reason": "ignored after failure"]
        : ["kind": "replan", "reason": "forbidden"]
      object["director"] = director
      try JSONSerialization.data(withJSONObject: object).write(to: scenario)
      let result = try await harness.dispatchDirector(
        view: view, scenarioPath: scenario.path, failChild: failedChild
      )
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      let attempts = try harness.store.listAttempts(taskId: task.id)
      XCTAssertEqual(attempts.count, 2)
      let child = try XCTUnwrap(attempts.first(where: { $0.entry == .director }))
      XCTAssertEqual(child.outcome?.sessionStatus, failedChild ? .failed : .completed)
      XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
      XCTAssertEqual(try harness.store.loadAttempt(id: judged.id)?.outcome, judged.outcome)
      let escalation = try XCTUnwrap(harness.store.listDecisions(taskId: task.id).first(where: {
        $0.producer == .policy(rule: "director-escalation")
      }))
      XCTAssertEqual(escalation.kind, .wait(.human))
      let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
      let decisionsBeforeReplay = try reopened.listDecisions(taskId: task.id)
      let evidenceBeforeReplay = try reopened.listEvidence(taskId: task.id)
      let childCosts = child.outcome?.costs
      XCTAssertTrue(try harness.store.listEvidence(taskId: task.id).contains(where: {
        $0.kind == .decision
          && $0.payloadRef.inlinePayload?["decisionId"] == .string(escalation.id.rawValue)
      }))
      let replay = try await harness.dispatch(
        "task-repair-loop", directorBundle: harness.bundle("task-agent-director"),
        scenarioPath: scenario.path
      )
      XCTAssertEqual(replay.exitCode, .success)
      XCTAssertEqual(try reopened.listAttempts(taskId: task.id).count, 2)
      XCTAssertEqual(try reopened.loadAttempt(id: child.id)?.outcome?.costs, childCosts)
      XCTAssertEqual(try reopened.listDecisions(taskId: task.id), decisionsBeforeReplay)
      XCTAssertEqual(try reopened.listEvidence(taskId: task.id), evidenceBeforeReplay)
    }
  }

  func testBothBundlesLoadAndMatchTheirDocumentedMockKeys() throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    for name in ["task-repair-loop", "task-agent-director"] {
      let bundle = try harness.bundle(name)
      XCTAssertEqual(bundle.workflow.workflowId, name)
      XCTAssertFalse(DefaultWorkflowValidator().validate(
        bundle.workflow, nodePayloads: bundle.nodePayloads
      ).contains { $0.severity == .error })
      let scenario = harness.examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json")
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: scenario)) as? [String: Any]
      let mockKeys = Set(try XCTUnwrap(object).keys)
      let nodeIds = Set(bundle.workflow.nodeRegistry.map(\.id))
      XCTAssertEqual(mockKeys, nodeIds)
      let expected = harness.examples.appendingPathComponent(name)
        .appendingPathComponent("EXPECTED_RESULTS.md")
      XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }
  }

  private func seedJudgedDirectorView(
    _ harness: TaskExampleHarness
  ) throws -> ((WorkTask, Attempt), (Evidence, AgentDirectorTaskView)) {
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(
      id: AttemptID("judged-work"), taskId: task.id,
      sessionId: "judged-session", state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(
      id: EvidenceID("judged-evidence"), taskId: task.id, attemptId: judged.id,
      kind: .contextSnapshot, producedBy: .runtime,
      payloadRef: .inline(["owner": .string("judged")]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try harness.store.saveEvidence(evidence)
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .satisfied,
      guardViolations: [], openFindings: [], evidenceSummary: [evidence], remainingAttempts: 0
    )
    return ((task, judged), (evidence, view))
  }
}
