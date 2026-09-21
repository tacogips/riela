import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

/// P0-6: `riela task show|list` over a fixture ledger, in every output
/// format, resolving the store through `canonicalRuntimeStoreRoot`.
final class TaskCommandTests: XCTestCase {
  private var sessionStore: URL!
  private var store: WorkStore!

  override func setUpWithError() throws {
    sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-task-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionStore)
  }

  // MARK: - show

  func testShowRendersTheTaskItsLedgerAndItsCompletionVerdictAsJSON() async throws {
    try seed()
    let result = await run(["task", "show", "task-1", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)

    let payload = try decode(TaskShowCommandResult.self, from: result.stdout)
    XCTAssertEqual(payload.taskId, "task-1")
    XCTAssertEqual(payload.task.title, "Fix the vendor importer")
    XCTAssertEqual(payload.task.state, .verifying)
    XCTAssertEqual(payload.attempts.map(\.id), [AttemptID("attempt-1")])
    XCTAssertEqual(payload.decisions.map(\.id), [DecisionID("decision-1")])
    XCTAssertEqual(payload.findings.map(\.id), ["finding-open"])
    XCTAssertEqual(
      payload.evidence,
      [
        TaskEvidenceCount(kind: .gate, count: 1),
        TaskEvidenceCount(kind: .verification, count: 2)
      ]
    )
    // One open high finding and one failed verification: the task is not done.
    XCTAssertEqual(
      payload.completion,
      .unmet([
        .verificationFailed(name: "unit-tests"),
        .openBlockingFinding(fingerprint: "id:finding-open")
      ])
    )
  }

  func testShowRendersTextLinesAndJSONL() async throws {
    try seed()
    let text = await run(["task", "show", "task-1", "--output", "text"])
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    let lines = text.stdout.split(separator: "\n").map(String.init)
    XCTAssertTrue(lines.contains("taskId: task-1"))
    XCTAssertTrue(lines.contains("state: verifying"))
    XCTAssertTrue(lines.contains("workflow: loop-engineer-quality-loop"))
    XCTAssertTrue(lines.contains("attempts: 1"))
    XCTAssertTrue(lines.contains("openBlockingFindings: 1"))
    XCTAssertTrue(lines.contains("latestSession: session-1"))
    XCTAssertTrue(lines.contains("evidence.gate: 1"))
    XCTAssertTrue(lines.contains("evidence.verification: 2"))
    XCTAssertTrue(
      lines.contains("completion: unmet(verification-failed:unit-tests, finding:id:finding-open)"),
      "the text rendering names the unmet requirements: \(lines)"
    )

    // `show` returns one document, so JSONL and JSON agree.
    let jsonl = await run(["task", "show", "task-1", "--output", "jsonl"])
    XCTAssertEqual(jsonl.exitCode, .success, jsonl.stderr)
    let json = await run(["task", "show", "task-1", "--output", "json"])
    XCTAssertEqual(
      try decode(TaskShowCommandResult.self, from: jsonl.stdout),
      try decode(TaskShowCommandResult.self, from: json.stdout)
    )
  }

  func testShowReportsASatisfiedContract() async throws {
    try seed(satisfied: true)
    let result = await run(["task", "show", "task-1", "--output", "json"])
    let payload = try decode(TaskShowCommandResult.self, from: result.stdout)
    XCTAssertEqual(payload.completion, .satisfied)
    XCTAssertEqual(TaskCommandRunner.completionCell(payload.completion), "satisfied")
  }

  func testShowFailsWithUsageWhenTheTaskIsAbsent() async throws {
    try seed()
    let result = await run(["task", "show", "task-missing", "--output", "json"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("task 'task-missing' was not found"), result.stderr)
    XCTAssertTrue(result.stderr.contains("runtime-records"), "the error names the store roots searched")
  }

  func testShowOnAnEmptyStoreRootIsAUsageErrorNotACrash() async {
    let result = await run(["task", "show", "task-1", "--output", "json"])
    XCTAssertEqual(result.exitCode, .usage)
  }

  // MARK: - list

  func testListRendersSummariesInEveryFormat() async throws {
    try seed()
    try seedSecondTask()

    let json = await run(["task", "list", "--output", "json"])
    XCTAssertEqual(json.exitCode, .success, json.stderr)
    let payload = try decode(TaskListCommandResult.self, from: json.stdout)
    XCTAssertEqual(payload.tasks.map(\.taskId), ["task-1", "task-2"])
    XCTAssertEqual(payload.tasks.first?.state, .verifying)
    XCTAssertEqual(payload.tasks.first?.workflowId, "loop-engineer-quality-loop")
    XCTAssertEqual(payload.tasks.first?.attemptCount, 1)
    XCTAssertEqual(payload.tasks.first?.latestSessionId, "session-1")
    XCTAssertEqual(payload.tasks.first?.openBlockingFindingCount, 1)
    XCTAssertEqual(payload.tasks.last?.openBlockingFindingCount, 0)

    let jsonl = await run(["task", "list", "--output", "jsonl"])
    XCTAssertEqual(jsonl.exitCode, .success, jsonl.stderr)
    let rows = jsonl.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(try rows.map { try decode(TaskSummary.self, from: $0) }, payload.tasks)

    let text = await run(["task", "list", "--output", "text"])
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.contains("taskId: task-1"))
    XCTAssertTrue(text.stdout.contains("taskId: task-2"))
  }

  func testListFiltersByStateIntentWorkflowAndLimit() async throws {
    try seed()
    try seedSecondTask()

    let cases: [(filters: [String], expected: [String])] = [
      (["--state", "succeeded"], ["task-2"]),
      (["--state", "verifying"], ["task-1"]),
      (["--intent", "intent-1"], ["task-1"]),
      (["--workflow", "required-loop-gate-failure"], ["task-2"]),
      (["--limit", "1"], ["task-1"]),
      ([], ["task-1", "task-2"])
    ]
    for testCase in cases {
      let actual = try await listedIds(testCase.filters)
      XCTAssertEqual(actual, testCase.expected, "filters \(testCase.filters)")
    }
  }

  func testListRejectsAnInvalidStateOrLimit() async throws {
    try seed()
    let state = await run(["task", "list", "--state", "archived", "--output", "json"])
    XCTAssertEqual(state.exitCode, .usage)
    XCTAssertTrue(state.stderr.contains("invalid --state value 'archived'"), state.stderr)
    XCTAssertTrue(state.stderr.contains("succeeded"), "the error lists the accepted states")

    let limit = await run(["task", "list", "--limit", "0", "--output", "json"])
    XCTAssertEqual(limit.exitCode, .usage)
    XCTAssertTrue(limit.stderr.contains("--limit must be between 1 and 1000"), limit.stderr)

    let scope = await run(["task", "list", "--scope", "sideways", "--output", "json"])
    XCTAssertEqual(scope.exitCode, .usage)
    XCTAssertTrue(scope.stderr.contains("invalid --scope value 'sideways'"), scope.stderr)
  }

  func testListOnAStoreThatWasNeverWrittenIsEmptyNotAnError() async {
    let result = await run(["task", "list", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try? decode(TaskListCommandResult.self, from: result.stdout), TaskListCommandResult(tasks: []))
  }

  /// The commands read the runtime records database beside the session store,
  /// so a store root that holds no Work Runtime rows reads as empty rather
  /// than reading another root's.
  func testTheStoreRootComesFromTheSessionStoreFlag() async throws {
    try seed()
    let other = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-task-command-other-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: other) }
    let result = await RielaCLIApplication().run(
      ["task", "list", "--session-store", other.path, "--output", "json"],
      environment: environment(sessionStore: other.path)
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try decode(TaskListCommandResult.self, from: result.stdout).tasks, [])
  }

  // MARK: - Help

  func testHelpDocumentsBothReadCommands() async {
    let help = await RielaCLIApplication().run(["--help"])
    XCTAssertTrue(help.stdout.contains("riela task show <task-id>"), help.stdout)
    XCTAssertTrue(help.stdout.contains("riela task list"), help.stdout)
  }

  // MARK: - Helpers

  private func environment(sessionStore path: String? = nil) -> [String: String] {
    ["RIELA_SESSION_STORE": path ?? sessionStore.path]
  }

  private func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(arguments, environment: environment())
  }

  private func listedIds(_ filters: [String]) async throws -> [String] {
    let output = await run(["task", "list"] + filters + ["--output", "json"]).stdout
    return try decode(TaskListCommandResult.self, from: output).tasks.map(\.taskId)
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }

  private func seed(satisfied: Bool = false) throws {
    let task = WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Fix the vendor importer",
      instruction: "Fix the vendor import.",
      plan: .workflow(WorkflowReference(name: "loop-engineer-quality-loop")),
      completion: CompletionContract(
        gates: [GateDeclaration(id: "review", stepId: "review", required: true)],
        verification: [VerificationRequirement(name: "unit-tests", command: "swift test")]
      ),
      state: .verifying
    )
    try store.saveTask(task)
    try store.saveAttempt(Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      entry: .start,
      state: .terminal,
      outcome: AttemptOutcome(
        sessionStatus: .completed,
        gateResults: [
          LoopGateResult(gateId: "review", stepId: "review", stepExecutionId: "exec-1", decision: .accepted)
        ]
      )
    ))
    try store.saveDecision(Decision(
      id: DecisionID("decision-1"),
      taskId: task.id,
      attemptId: AttemptID("attempt-1"),
      producer: .policy(rule: "gate-accepted"),
      kind: .accept,
      reason: "gate accepted",
      createdAt: Date(timeIntervalSince1970: 1_000)
    ))
    try store.saveEvidence([
      evidence(id: "evidence-gate", kind: .gate, payload: ["gateId": .string("review")], at: 1_000),
      evidence(
        id: "evidence-verification-unit",
        kind: .verification,
        payload: ["id": .string("unit-tests"), "outcome": .string(satisfied ? "passed" : "failed")],
        at: 2_000
      ),
      evidence(
        id: "evidence-verification-lint",
        kind: .verification,
        payload: ["id": .string("lint"), "outcome": .string("passed")],
        at: 3_000
      )
    ])
    if !satisfied {
      try store.saveFindings([finding(id: "finding-open", severity: .high, status: .open)], taskId: task.id)
    }
  }

  private func seedSecondTask() throws {
    let task = WorkTask(
      id: TaskID("task-2"),
      intentId: IntentID("intent-2"),
      title: "Prove the gate fails closed",
      instruction: "Run the rejected scenario.",
      plan: .workflow(WorkflowReference(name: "required-loop-gate-failure")),
      state: .succeeded
    )
    try store.saveTask(task)
    try store.saveFindings([finding(id: "finding-addressed", severity: .high, status: .addressed)], taskId: task.id)
  }

  private func evidence(id: String, kind: EvidenceKind, payload: JSONObject, at seconds: TimeInterval) -> Evidence {
    Evidence(
      id: EvidenceID(id),
      taskId: TaskID("task-1"),
      attemptId: AttemptID("attempt-1"),
      kind: kind,
      producedBy: .runtime,
      payloadRef: .inline(payload),
      createdAt: Date(timeIntervalSince1970: seconds)
    )
  }

  private func finding(id: String, severity: FindingSeverity, status: FindingStatus) -> Finding {
    let blocking = LoopBlockingFinding(id: id, severity: severity.rawValue, message: "m")
    return Finding(
      id: id,
      fingerprint: LoopFindingFingerprint.make(from: blocking),
      severity: severity,
      status: status,
      gateId: "review",
      sourceStepExecutionId: "exec-1",
      message: "m"
    )
  }
}
