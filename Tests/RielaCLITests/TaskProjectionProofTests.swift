import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

/// P0-7, the phase's proof: run the two loop examples with their mock
/// scenarios, project each terminal snapshot into a task, and check the
/// ledger against the numbers the examples' `EXPECTED_RESULTS.md` publish.
///
/// Every expectation below is quoted from those files, so a projector that
/// silently drops a gate, a finding, or a per-step cost fails here.
final class TaskProjectionProofTests: XCTestCase {
  /// `examples/loop-engineer-quality-loop/EXPECTED_RESULTS.md`:
  /// `nodeExecutions: 12`, `status: completed`, one required gate
  /// `loop-engineer-review` accepted, zero rejected gates, zero blocking
  /// findings.
  func testTheQualityLoopExampleProjectsIntoASucceededTask() async throws {
    let run = try await runExample(
      workflow: "loop-engineer-quality-loop",
      scenario: "mock-scenario.json",
      expectedExit: .success
    )
    defer { run.cleanUp() }

    XCTAssertEqual(run.result.status, .completed)
    XCTAssertEqual(run.result.exitCode, 0)
    XCTAssertEqual(run.result.loopEvidence?.gateCount, 1)
    XCTAssertEqual(run.result.loopEvidence?.acceptedGateCount, 1)
    XCTAssertEqual(run.result.loopEvidence?.rejectedGateCount, 0)
    XCTAssertEqual(run.result.loopEvidence?.blockingFindingCount, 0)
    XCTAssertEqual(run.result.nodeExecutions, 12)

    let projected = try project(run)
    XCTAssertEqual(projected.gateIds, ["loop-engineer-review"])
    XCTAssertEqual(projected.count(of: .gate), 1)
    XCTAssertEqual(projected.findings.count, 0, "an accepted gate with no blocking findings projects none")
    XCTAssertEqual(projected.count(of: .finding), 0)
    XCTAssertEqual(projected.count(of: .verification), run.manifest.verification.count)
    // One cost record per executed step, so the ledger accounts for every
    // node execution the example publishes.
    XCTAssertEqual(projected.count(of: .cost), 12)
    XCTAssertEqual(projected.count(of: .guardViolation), 0, "the example converges")
    XCTAssertEqual(projected.projection.decisions, [], "a plain initial run records no redirection")

    XCTAssertEqual(projected.verdict, .satisfied)
    XCTAssertEqual(projected.task.state, .succeeded)

    try await assertTaskShowAgrees(with: projected, run: run)
  }

  /// `examples/required-loop-gate-failure/EXPECTED_RESULTS.md`:
  /// `status: failed`, `nodeExecutions: 1`, `gateCount: 1`,
  /// `acceptedGateCount: 0`, `rejectedGateCount: 1`,
  /// `blockingFindingCount: 2` — "the authored finding plus the runtime
  /// gate-threshold finding".
  func testTheRequiredGateFailureExampleProjectsIntoAFailedTask() async throws {
    let run = try await runExample(
      workflow: "required-loop-gate-failure",
      scenario: "mock-scenario-rejected.json",
      expectedExit: .failure
    )
    defer { run.cleanUp() }

    XCTAssertEqual(run.result.status, .failed)
    XCTAssertEqual(run.result.exitCode, 1)
    XCTAssertEqual(run.result.loopEvidence?.gateCount, 1)
    XCTAssertEqual(run.result.loopEvidence?.acceptedGateCount, 0)
    XCTAssertEqual(run.result.loopEvidence?.rejectedGateCount, 1)
    XCTAssertEqual(run.result.loopEvidence?.blockingFindingCount, 2)
    XCTAssertEqual(run.result.nodeExecutions, 1)

    let projected = try project(run)
    XCTAssertEqual(projected.gateIds, ["implementation-review"])
    XCTAssertEqual(projected.count(of: .gate), 1)
    XCTAssertEqual(projected.findings.count, 2)
    XCTAssertEqual(projected.count(of: .finding), 2)
    XCTAssertEqual(projected.count(of: .verification), run.manifest.verification.count)
    XCTAssertEqual(projected.count(of: .cost), 1)

    // Both findings keep their authored id, but only the authored one keeps
    // it as its identity: `gate-policy-` ids are synthesized per run, so
    // `LoopFindingFingerprint` deliberately falls back to the message for
    // them and a rerun's threshold finding matches the previous one.
    XCTAssertEqual(
      projected.findings.map(\.id),
      ["missing-regression-test", "gate-policy-implementation-review-max-high-findings"]
    )
    XCTAssertEqual(
      projected.findings.map(\.fingerprint.key),
      [
        "id:missing-regression-test",
        "message:\u{0}required loop gate 'implementation-review' has 1 high findings; maximum is 0"
      ]
    )
    XCTAssertEqual(projected.findings.filter(\.blocksCompletion).count, 2)
    XCTAssertEqual(Set(projected.findings.map(\.gateId)), ["implementation-review"])

    // Every finding points at the gate evidence that reported it.
    let gateEvidence = projected.projection.evidence(ofKind: .gate).first
    for record in projected.projection.evidence(ofKind: .finding) {
      XCTAssertEqual(record.causedBy, [gateEvidence?.id].compactMap { $0 })
    }

    XCTAssertEqual(
      projected.verdict,
      .unmet([
        .gateNotAccepted(gateId: "implementation-review"),
        .openBlockingFinding(fingerprint: "id:missing-regression-test"),
        .openBlockingFinding(
          fingerprint: "message:\u{0}required loop gate 'implementation-review' has 1 high findings; maximum is 0"
        )
      ])
    )
    XCTAssertEqual(projected.task.state, .failed)

    try await assertTaskShowAgrees(with: projected, run: run)
  }

  // MARK: - Running an example

  private struct ExampleRun {
    var workflow: String
    var sessionStore: URL
    var artifactRoot: URL
    var result: WorkflowRunResult
    var snapshot: WorkflowRuntimePersistenceSnapshot

    var manifest: LoopEvidenceManifest {
      snapshot.loopEvidence ?? LoopEvidenceManifest(
        schemaVersion: 0,
        manifestId: "",
        workflowId: workflow,
        sessionId: snapshot.session.sessionId,
        workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: false),
        policy: LoopPolicyEvidence(),
        redaction: LoopRedactionSummary(policyName: "none", status: "none"),
        createdAt: Date(),
        updatedAt: Date()
      )
    }

    var storeRoot: String {
      canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: sessionStore)
      try? FileManager.default.removeItem(at: artifactRoot)
    }
  }

  private func runExample(
    workflow: String,
    scenario: String,
    expectedExit: CLIExitCode
  ) async throws -> ExampleRun {
    let root = repositoryRoot()
    let examples = root.appendingPathComponent("examples", isDirectory: true)
    let unique = UUID().uuidString
    let sessionStore = root.appendingPathComponent("tmp/task-projection-proof/\(unique)/sessions", isDirectory: true)
    let artifactRoot = root.appendingPathComponent("tmp/task-projection-proof/\(unique)/artifacts", isDirectory: true)

    let result = await RielaCLIApplication().run([
      "workflow", "run", workflow,
      "--workflow-definition-dir", examples.path,
      "--mock-scenario", examples.appendingPathComponent(workflow).appendingPathComponent(scenario).path,
      "--session-store", sessionStore.path,
      "--artifact-root", artifactRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, expectedExit, result.stderr + result.stdout)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let runResult = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: runResult.session.sessionId)
    XCTAssertNotNil(snapshot.loopEvidence, "the example must persist loop evidence to be projectable")

    return ExampleRun(
      workflow: workflow,
      sessionStore: sessionStore,
      artifactRoot: artifactRoot,
      result: runResult,
      snapshot: snapshot
    )
  }

  // MARK: - Projecting it into a task

  private struct ProjectedTask {
    var task: WorkTask
    var attempt: Attempt
    var projection: WorkProjection
    var verdict: CompletionVerdict

    var findings: [Finding] { projection.findings }
    var gateIds: [String] { Array(Set(projection.evidence(ofKind: .gate).compactMap(gateId))).sorted() }

    func count(of kind: EvidenceKind) -> Int {
      projection.evidence(ofKind: kind).count
    }

    private func gateId(_ evidence: Evidence) -> String? {
      guard case let .string(value)? = evidence.payloadRef.inlinePayload?["gateId"] else { return nil }
      return value
    }
  }

  /// Builds the intent, task, and attempt the run stands for, projects the
  /// terminal snapshot into them, and persists the whole ledger — the path
  /// P1's dispatcher will take at attempt terminal.
  private func project(_ run: ExampleRun) throws -> ProjectedTask {
    let store = WorkStore(rootDirectory: run.storeRoot)
    let intent = Intent(
      id: IntentID.generate(),
      title: "Run \(run.workflow)",
      instruction: "Execute the \(run.workflow) example and judge it by its gates.",
      origin: .cli
    )
    let requiredGate = try XCTUnwrap(run.manifest.gates.first).gateId
    var task = WorkTask(
      id: TaskID.generate(),
      intentId: intent.id,
      title: "Run \(run.workflow)",
      instruction: intent.instruction,
      plan: .workflow(WorkflowReference(name: run.workflow)),
      completion: CompletionContract(
        gates: [GateDeclaration(id: requiredGate, stepId: requiredGate, required: true)]
      ),
      state: .verifying
    )
    var attempt = Attempt(
      id: AttemptID.generate(),
      taskId: task.id,
      sessionId: run.snapshot.session.sessionId,
      entry: .start,
      state: .terminal,
      outcome: WorkEvidenceProjector.outcome(from: run.snapshot)
    )

    try store.saveIntent(intent)
    try store.saveTask(task)
    try store.saveAttempt(attempt)

    let projection = WorkEvidenceProjector().project(snapshot: run.snapshot, task: task, attempt: attempt)
    try store.saveEvidence(projection.evidence)
    try store.saveFindings(projection.findings, taskId: task.id)
    for decision in projection.decisions {
      try store.saveDecision(decision)
    }

    let verdict = CompletionEvaluator.evaluate(
      contract: task.completion,
      attemptOutcome: attempt.outcome ?? AttemptOutcome(sessionStatus: .created),
      ledger: CompletionLedger(findings: projection.findings)
    )
    attempt.state = .reconciled
    try store.saveAttempt(attempt)

    // P1 owns the real transition; P0 proves the verdict decides the state.
    task.state = verdict.isSatisfied ? .succeeded : .failed
    task = try store.updateTask(task, expectedVersion: task.version)

    // The ledger must survive the round trip through SQLite unchanged.
    XCTAssertEqual(try store.listEvidence(taskId: task.id).count, projection.evidence.count)
    XCTAssertEqual(try store.listFindings(taskId: task.id).count, projection.findings.count)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).count, projection.decisions.count)

    return ProjectedTask(task: task, attempt: attempt, projection: projection, verdict: verdict)
  }

  /// `riela task show` must report exactly what the projector wrote: the read
  /// surface and the projection are one contract, not two.
  private func assertTaskShowAgrees(with projected: ProjectedTask, run: ExampleRun) async throws {
    let result = await RielaCLIApplication().run(
      ["task", "show", projected.task.id.rawValue, "--session-store", run.sessionStore.path, "--output", "json"],
      environment: ["RIELA_SESSION_STORE": run.sessionStore.path]
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(TaskShowCommandResult.self, from: Data(result.stdout.utf8))

    XCTAssertEqual(payload.task.state, projected.task.state)
    XCTAssertEqual(payload.attempts.map(\.sessionId), [run.snapshot.session.sessionId])
    XCTAssertEqual(payload.findings.count, projected.findings.count)
    XCTAssertEqual(payload.decisions.count, projected.projection.decisions.count)
    XCTAssertEqual(payload.completion, projected.verdict)
    XCTAssertEqual(
      payload.evidence.reduce(0) { $0 + $1.count },
      projected.projection.evidence.count
    )

    let listed = await RielaCLIApplication().run(
      ["task", "list", "--session-store", run.sessionStore.path, "--output", "json"],
      environment: ["RIELA_SESSION_STORE": run.sessionStore.path]
    )
    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    let list = try decoder.decode(TaskListCommandResult.self, from: Data(listed.stdout.utf8))
    XCTAssertEqual(list.tasks.map(\.taskId), [projected.task.id.rawValue])
    XCTAssertEqual(list.tasks.first?.workflowId, run.workflow)
    XCTAssertEqual(list.tasks.first?.attemptCount, 1)
    XCTAssertEqual(
      list.tasks.first?.openBlockingFindingCount,
      projected.findings.filter(\.blocksCompletion).count
    )
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
