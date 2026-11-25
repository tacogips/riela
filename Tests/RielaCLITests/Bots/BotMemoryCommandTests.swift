import Foundation
import RielaCore
import RielaGraphQL
import RielaWork
import XCTest
@testable import RielaCLI

final class BotMemoryCommandTests: XCTestCase {
  func testMarkdownRoundTripRedactionDiffAndUndo() async throws {
    let fixture = try await makeFixture()
    let before = await fixture.run(["memory", "show", "alpha"])
    XCTAssertEqual(before.stdout, "## Instructions\n## Notes\n")
    let input = fixture.root.appendingPathComponent("edit.md")
    try """
      ## Instructions
      ### release
      - Use staging; remove token sk-example-private-1234
      ## Notes
      ### review
      - A correction is pending.
      """.write(to: input, atomically: true, encoding: .utf8)
    let edit: BotMemoryChangeSet = try await fixture.json(["memory", "edit", "alpha", "--file", input.path, "--reason", "QA"])
    XCTAssertEqual(edit.actor, .cli)
    XCTAssertEqual(edit.reason, "QA")
    XCTAssertEqual(edit.entries.map(\.op), [.add, .add])
    XCTAssertTrue(edit.redacted)

    let shown = await fixture.run(["memory", "show", "alpha"])
    XCTAssertTrue(shown.stdout.contains("<redacted:OPENAI_API_KEY>"))
    XCTAssertTrue(shown.stdout.contains("A correction is pending."))
    XCTAssertEqual(shown.stdout.components(separatedBy: "<!-- id:").count, 3)
    XCTAssertFalse(shown.stdout.contains("sk-example-private-1234"))
    let detail: BotDetailPayload = try await fixture.json(["show", "alpha"])
    XCTAssertEqual(detail.memory.instructionCount, 1)
    XCTAssertEqual(detail.memory.noteCount, 1)
    XCTAssertEqual(detail.memory.lastChangedAt, edit.createdAt)

    let output = fixture.root.appendingPathComponent("export.md")
    let exported = await fixture.run(["memory", "export", "alpha", "--out", output.path])
    XCTAssertEqual(exported.exitCode, .success, exported.stderr)
    let refused = await fixture.run(["memory", "export", "alpha", "--out", output.path])
    XCTAssertEqual(refused.exitCode, .failure)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), shown.stdout)
    let overwrite = await fixture.run(["memory", "export", "alpha", "--out", output.path, "--force"])
    XCTAssertEqual(overwrite.exitCode, .success, overwrite.stderr)
    let noChange: BotMemoryChangeSet = try await fixture.json(["memory", "edit", "alpha", "--file", output.path])
    XCTAssertEqual(noChange.entries, [])

    let diff = await fixture.run(["memory", "diff", "alpha", edit.changeId])
    XCTAssertEqual(diff.exitCode, .success, diff.stderr)
    XCTAssertTrue(diff.stdout.contains("Use staging"))
    let undo: BotMemoryChangeSet = try await fixture.json(["memory", "undo", "alpha", edit.changeId])
    XCTAssertEqual(undo.reason, "undo:\(edit.changeId)")
    let restored = await fixture.run(["memory", "show", "alpha"])
    XCTAssertEqual(restored.stdout, before.stdout)
    let history: [BotMemoryChangeSet] = try await fixture.json(["memory", "history", "alpha"])
    XCTAssertEqual(Set(history.map(\.changeId)), Set([edit.changeId, undo.changeId]))
  }

  func testAuditAndUndoStayWithinSelectedMemoryRoot() async throws {
    let fixture = try await makeFixture()
    let input = fixture.root.appendingPathComponent("memory.md")
    let edit = ["memory", "edit", "alpha", "--file", input.path]
    try "## Instructions\n- First database\n".write(to: input, atomically: true, encoding: .utf8)
    let first: BotMemoryChangeSet = try await fixture.json(edit)
    let alternate = ["--memory-root", fixture.root.appendingPathComponent("alternate").path]
    try "## Instructions\n- Second database\n".write(to: input, atomically: true, encoding: .utf8)
    let second: BotMemoryChangeSet = try await fixture.json(edit + alternate)
    XCTAssertEqual(first.entries, second.entries, "The two databases independently assigned the same record and version")
    let crossRoot = await fixture.run(["memory", "undo", "alpha", first.changeId] + alternate)
    XCTAssertEqual(crossRoot.exitCode, .failure)
    XCTAssertTrue(crossRoot.stderr.contains("memory_change_not_found"), crossRoot.stderr)
    let history: [BotMemoryChangeSet] = try await fixture.json(["memory", "history", "alpha"] + alternate)
    XCTAssertEqual(history, [second])
    let result = await fixture.run(["memory", "show", "alpha"] + alternate)
    XCTAssertTrue(result.stdout.contains("Second database"))
    let original = await fixture.run(["memory", "show", "alpha"])
    XCTAssertTrue(original.stdout.contains("First database"))
  }

  func testFeedbackAuditsCorrectionAndFindingsWithProvenance() async throws {
    let fixture = try await makeFixture()
    try fixture.saveSession(id: "complete", status: .completed, linked: true, messages: ["One\nextra line", String(repeating: "x", count: 501)])
    let change: BotMemoryChangeSet = try await fixture.json([
      "feedback", "alpha", "--session", "complete", "--text", "Use staging", "--from-findings"
    ])
    XCTAssertEqual(change.actor, .feedback)
    XCTAssertEqual(change.evidenceRefs, ["session:complete"])
    XCTAssertEqual(change.entries.count, 3)
    let entries = try fixture.service.memoryWriter().entries(botId: "alpha")
    let correction = try XCTUnwrap(entries.first { $0.kind == .instruction })
    XCTAssertEqual(correction.text, "Use staging")
    XCTAssertEqual(correction.topic, "corrections")
    XCTAssertEqual(correction.provenance.source, .correction)
    let notes = entries.filter { $0.kind == .note }
    XCTAssertEqual(Set(notes.map(\.text)), Set(["One", String(repeating: "x", count: 500)]))
    XCTAssertTrue(notes.allSatisfy { $0.provenance.source == .review && $0.provenance.ref == "session:complete" })
    let history: [BotMemoryChangeSet] = try await fixture.json(["memory", "history", "alpha", "--limit", "1"])
    XCTAssertEqual(history, [change])
  }

  func testFeedbackRejectsUnlinkedRunningAndEmptyItems() async throws {
    let fixture = try await makeFixture()
    try fixture.saveSession(id: "stranger", status: .completed, linked: false)
    try fixture.saveSession(id: "working", status: .running, linked: true)
    try fixture.saveSession(id: "empty", status: .completed, linked: true)
    let cases = [
      ("stranger", "feedback_item_not_found"), ("working", "feedback_item_not_finished"), ("empty", "feedback_empty")
    ]
    for (id, code) in cases {
      let result = await fixture.run(["feedback", "alpha", "--session", id, "--from-findings"])
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertTrue(result.stderr.contains(code), result.stderr)
    }
    XCTAssertTrue(try fixture.service.memoryWriter().history(botId: "alpha").isEmpty)
  }

  func testGraphQLAndCLIUseSameMemoryAndFinishedTaskEvidence() async throws {
    let fixture = try await makeFixture()
    try fixture.saveSession(id: "task-session", status: .completed, linked: true)
    let task = WorkTask(
      id: TaskID(rawValue: "task-owned"), intentId: IntentID(rawValue: "intent-example"),
      title: "Owned task", instruction: "Ship", owner: OwnerAssignment(identity: "bot:alpha"), state: .succeeded
    )
    let work = WorkStore(rootDirectory: fixture.service.store.sessionStoreRoot)
    try work.saveTask(task)
    try work.saveAttempt(Attempt(id: AttemptID(rawValue: "attempt-owned"), taskId: task.id, sessionId: "task-session"))

    let provider = BotsGraphQLProvider(workingDirectory: fixture.root.path, sessionStoreRoot: fixture.sessions, environment: fixture.environment)
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let operation = #"""
      mutation {
        updateBotMemory(input: {botId: "alpha", markdown: "## Instructions\n- Build locally\n## Notes\n"}) {
          change { actor entries { recordId } }
        }
        captureBotFeedback(input: {botId: "alpha", taskId: "task-owned", text: "Use staging"}) {
          change { reason evidenceRefs }
        }
      }
      """#
    let answer = await executor.execute(.init(query: operation, environment: [:], isLocallyTrusted: true))
    XCTAssertNil(answer.body["errors"], "\(answer.body)")
    let history: [BotMemoryChangeSet] = try await fixture.json(["memory", "history", "alpha"])
    XCTAssertEqual(Set(history.map(\.actor)), Set([.api, .feedback]))
    XCTAssertEqual(history.first { $0.actor == .feedback }?.evidenceRefs, ["task:task-owned"])
    let shown = await fixture.run(["memory", "show", "alpha"])
    XCTAssertTrue(shown.stdout.contains("Build locally"))
    XCTAssertTrue(shown.stdout.contains("Use staging"))
  }

  private func makeFixture() async throws -> MemoryCommandFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-15-memory-surfaces/cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let fixture = MemoryCommandFixture(root: root)
    let result = await fixture.run(["create", "--name", "Alpha"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    return fixture
  }
}

private struct MemoryCommandFixture {
  let root: URL
  var sessions: String { root.appendingPathComponent("sessions").path }
  var environment: [String: String] {
    [
      "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("home").path,
      "RIELA_MEMORY_ROOT": root.appendingPathComponent("memory").path,
      "OPENAI_API_KEY": "sk-example-private-1234"
    ]
  }
  var service: BotsService {
    BotsService(workingDirectory: root.path, sessionStoreRoot: sessions, environment: environment)
  }

  func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(
      ["bot"] + arguments + ["--working-dir", root.path, "--session-store", sessions], environment: environment
    )
  }

  func json<T: Decodable>(_ arguments: [String]) async throws -> T {
    let result = await run(arguments + ["--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(result.stdout.utf8))
  }

  func saveSession(id: String, status: WorkflowSessionStatus, linked: Bool, messages: [String] = []) throws {
    let instant = Date(timeIntervalSince1970: 1_790_000_000)
    let findings = messages.enumerated().map { index, message in
      WorkflowReviewFinding(
        id: "finding-\(index)", sourceReviewStepId: "review", sourceStepExecutionId: "review-exec",
        sourceExecutionAttempt: 1, severity: .mid, message: message, originatingSessionId: id, createdAt: instant
      )
    }
    let session = WorkflowSession(
      workflowId: "flow", sessionId: id, status: status, entryStepId: "work",
      createdAt: instant, updatedAt: instant, reviewFindings: findings
    )
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: service.store.sessionStoreRoot)
    try runtime.save(.init(session: session))
    if linked { try service.store.linkSession(sessionId: id, botId: "alpha", source: "run", at: instant) }
  }
}
