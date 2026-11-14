import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class AgentDirectorTests: XCTestCase {
  func testAllowedRerunTargetsJudgedWorkAndRetainsItsOutcome() throws {
    let view = taskView()
    let child = directorAttempt()
    let output: JSONObject = [
      "kind": .string("rerun"),
      "reason": .string("  repair the failed work step  "),
      "fromStepId": .string("repair")
    ]

    let validated = AgentDirector.validate(
      output: output,
      directorAttempt: child,
      view: view,
      allowedKinds: ["rerun"],
      causedBy: [EvidenceID("work-failure")],
      decisionId: DecisionID("agent-decision")
    )
    guard case let .decision(decision) = validated else {
      return XCTFail("expected a bounded agent decision")
    }
    XCTAssertEqual(decision.taskId, view.task.id)
    XCTAssertEqual(decision.attemptId, view.judgedAttempt.id)
    XCTAssertEqual(decision.producer, .agent(sessionId: child.sessionId))
    XCTAssertEqual(decision.kind, .rerun(fromStepId: "repair"))
    XCTAssertEqual(decision.reason, "repair the failed work step")
    XCTAssertEqual(view.judgedAttempt.outcome?.sessionStatus, .failed)
    XCTAssertEqual(child.outcome?.sessionStatus, .completed)

    let roundTrip = try JSONDecoder().decode(
      AgentDirectorTaskView.self,
      from: JSONEncoder().encode(view)
    )
    XCTAssertEqual(roundTrip.judgedAttempt.id, view.judgedAttempt.id)
    XCTAssertEqual(roundTrip.judgedAttempt.outcome, view.judgedAttempt.outcome)
  }

  func testInvalidForbiddenAndBudgetBlockedOutputsNeedHuman() {
    let view = taskView()
    let child = directorAttempt()
    let evidenceId = EvidenceID("work-failure")
    let cases: [(JSONObject, Set<String>)] = [
      (["kind": .string("replan"), "reason": .string("change plan")], ["replan"]),
      (["kind": .string("rerun"), "reason": .string("retry")], ["reject"]),
      (["kind": .string("rerun"), "reason": .string("retry"), "taskId": .string("other")], ["rerun"]),
      (["kind": .string("rerun")], ["rerun"]),
      (["kind": .string("recover"), "reason": .string("repair")], ["recover"]),
      (["kind": .string("wait"), "reason": .string("later"), "wait": .object(["kind": .string("capacity")])],
       ["wait"])
    ]
    for (output, allowedKinds) in cases {
      let result = AgentDirector.validate(
        output: output,
        directorAttempt: child,
        view: view,
        allowedKinds: allowedKinds,
        causedBy: [evidenceId],
        decisionId: DecisionID("agent-decision")
      )
      guard case .needsHuman = result else {
        return XCTFail("expected human escalation for \(output)")
      }
    }
    let budgetBlocked = AgentDirector.validate(
      output: ["kind": .string("rerun"), "reason": .string("retry")],
      directorAttempt: child,
      view: taskView(remainingAttempts: 0),
      allowedKinds: ["rerun"],
      causedBy: [evidenceId],
      decisionId: DecisionID("agent-decision")
    )
    guard case .needsHuman = budgetBlocked else { return XCTFail("expected budget escalation") }
  }

  func testFailedOrRecursiveChildAndWrongCausalityNeedHuman() {
    let view = taskView()
    let output: JSONObject = ["kind": .string("reject"), "reason": .string("work failed")]
    var failed = directorAttempt()
    failed.outcome = AttemptOutcome(sessionStatus: .failed)
    XCTAssertNeedsHuman(output: output, child: failed, view: view, causedBy: [EvidenceID("work-failure")])

    var recursive = directorAttempt()
    recursive.id = view.judgedAttempt.id
    XCTAssertNeedsHuman(output: output, child: recursive, view: view, causedBy: [EvidenceID("work-failure")])

    XCTAssertNeedsHuman(
      output: output,
      child: directorAttempt(),
      view: view,
      causedBy: [EvidenceID("foreign-evidence")]
    )
  }

  func testAllowedAcceptTargetsJudgedWorkAndRejectsExtraFields() {
    let view = taskView(completion: .satisfied)
    let output: JSONObject = ["kind": .string("accept"), "reason": .string("work passed")]
    let result = AgentDirector.validate(
      output: output,
      directorAttempt: directorAttempt(),
      view: view,
      allowedKinds: ["accept"],
      causedBy: [EvidenceID("work-failure")],
      decisionId: DecisionID("agent-decision")
    )
    guard case let .decision(decision) = result else {
      return XCTFail("expected a typed decision for shared-store validation")
    }
    XCTAssertEqual(decision.kind, .accept)
    XCTAssertEqual(decision.attemptId, view.judgedAttempt.id)
    XCTAssertEqual(decision.producer, .agent(sessionId: "director-session"))
    let invalid = AgentDirector.validate(
      output: output.merging(["taskId": .string("other")]) { _, new in new },
      directorAttempt: directorAttempt(), view: view, allowedKinds: ["accept"],
      causedBy: [EvidenceID("work-failure")], decisionId: DecisionID("invalid")
    )
    guard case .needsHuman = invalid else { return XCTFail("extra fields must escalate") }
  }

  private func XCTAssertNeedsHuman(
    output: JSONObject,
    child: Attempt,
    view: AgentDirectorTaskView,
    causedBy: [EvidenceID]
  ) {
    let result = AgentDirector.validate(
      output: output,
      directorAttempt: child,
      view: view,
      allowedKinds: ["reject"],
      causedBy: causedBy,
      decisionId: DecisionID("agent-decision")
    )
    guard case .needsHuman = result else { return XCTFail("expected human escalation") }
  }

  private func taskView(
    remainingAttempts: Int = 1,
    completion: CompletionVerdict = .unmet([.acceptanceAbsent])
  ) -> AgentDirectorTaskView {
    let task = WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Repair",
      instruction: "Repair the failed work",
      plan: .workflow(WorkflowReference(name: "repair-workflow")),
      director: DirectorPolicy(agentWorkflow: WorkflowReference(name: "agent-director")),
      state: .verifying
    )
    let judged = Attempt(
      id: AttemptID("work-attempt"),
      taskId: task.id,
      generation: 1,
      sessionId: "work-session",
      state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    let evidence = Evidence(
      id: EvidenceID("work-failure"),
      taskId: task.id,
      attemptId: judged.id,
      kind: .finding,
      producedBy: .runtime,
      payloadRef: .inline(["summary": .string("work failed")]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    return AgentDirectorTaskView(
      task: task,
      judgedAttempt: judged,
      completion: completion,
      guardViolations: [],
      openFindings: [],
      evidenceSummary: [evidence],
      remainingAttempts: remainingAttempts
    )
  }

  private func directorAttempt() -> Attempt {
    Attempt(
      id: AttemptID("director-attempt"),
      taskId: TaskID("task-1"),
      generation: 2,
      sessionId: "director-session",
      entry: .director,
      state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
  }
}
