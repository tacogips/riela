import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class BotMemoryInjectionTests: XCTestCase {
  func testMockWorkflowUsesMemoryFromSelectedDirectoryOnlyForLinkedRuns() async throws {
    try await exerciseMemoryRoot(useEnvironment: false)
  }

  func testMockWorkflowAndRecoveryUseSelectedEnvironmentMemoryRoot() async throws {
    try await exerciseMemoryRoot(useEnvironment: true)
  }

  private func exerciseMemoryRoot(useEnvironment: Bool) async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-15-memory-surfaces/injection-\(UUID().uuidString)")
    let work = root.appendingPathComponent("selected")
    let sessions = root.appendingPathComponent("sessions").path
    let workflow = "worker-only-single-step"
    let workflows = work.appendingPathComponent(".riela/workflows")
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = workflows.appendingPathComponent(workflow)
    try FileManager.default.copyItem(at: repository.appendingPathComponent("examples/\(workflow)"), to: bundle)
    let nodePath = bundle.appendingPathComponent("nodes/node-main-worker.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var node = try decoder.decode(JSONObject.self, from: Data(contentsOf: nodePath))
    node["promptMaxBytes"] = .integer(8_000)
    try JSONEncoder().encode(node).write(to: nodePath)
    let scenarioPath = bundle.appendingPathComponent("mock-scenario.json").path
    var environment = [
      "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("home").path,
      "RIELA_MEMORY_ROOT": useEnvironment ? root.appendingPathComponent("custom-memory").path : ""
    ]
    environment["RIELA_API_KEY"] = ""
    let flags = ["--working-dir", work.path, "--session-store", sessions]
    let adapter = CapturingMemoryScenarioAdapter(underlying: ScenarioNodeAdapter(
      scenario: try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath), requiresScenarioResponse: true
    ))
    var command = WorkflowRunCommand()
    command.taskNodeAdapterOverride = adapter
    let app = RielaCLIApplication(runCommand: command)
    let created = await app.run(["bot", "create", "--name", "Alpha"] + flags, environment: environment)
    XCTAssertEqual(created.exitCode, .success, created.stderr)
    let edit = root.appendingPathComponent("edit.md")
    let instruction = "Use the staging cluster for canaries."
    try "## Instructions\n- \(instruction)\n## Notes\n".write(to: edit, atomically: true, encoding: .utf8)
    let saved = await app.run(["bot", "memory", "edit", "alpha", "--file", edit.path] + flags, environment: environment)
    XCTAssertEqual(saved.exitCode, .success, saved.stderr)

    let run = ["workflow", "run", workflow, "--output", "json",
      "--artifact-root", root.appendingPathComponent("artifacts").path] + flags
    let runScenario = run + ["--mock-scenario", scenarioPath]
    let linked = await app.run(runScenario + ["--bot", "alpha"], environment: environment)
    XCTAssertEqual(linked.exitCode, .success, linked.stderr + linked.stdout)
    let unlinked = await app.run(runScenario, environment: environment)
    XCTAssertEqual(unlinked.exitCode, .success, unlinked.stderr + unlinked.stdout)
    let prompts = await adapter.prompts
    XCTAssertEqual(prompts.count, 2)
    let linkedPrompt = try XCTUnwrap(prompts.first)
    XCTAssertTrue(linkedPrompt.contains("Bot memory (riela memory)"))
    XCTAssertTrue(linkedPrompt.contains(instruction))
    XCTAssertFalse(prompts.last?.contains(instruction) ?? true)

    let session = try decoder.decode(WorkflowRunResult.self, from: Data(linked.stdout.utf8)).session
    let recovered = BotActivityRuntime.botContext(
      forExistingSession: session.sessionId, sessionStoreRoot: sessions,
      workingDirectory: work.path, environment: environment
    )
    XCTAssertTrue(recovered?.memoryBlock?.contains(instruction) ?? false)

    if useEnvironment {
      let failureScenario = root.appendingPathComponent("failing-scenario.json")
      try #"{"main-worker":{"fail":true}}"#.write(to: failureScenario, atomically: true, encoding: .utf8)
      let failed = await RielaCLIApplication().run(
        run + ["--mock-scenario", failureScenario.path, "--bot", "alpha"], environment: environment
      )
      XCTAssertEqual(failed.exitCode, .failure, failed.stderr + failed.stdout)
      let bots = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions))
      let beforeRecovery = try Set(bots.links(botId: "alpha").map(\.sessionId))
      let failedId = try XCTUnwrap(beforeRecovery.subtracting([session.sessionId]).first)
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: bots.sessionStoreRoot)
      let originalFailure = try runtime.loadStrictReadOnly(sessionId: failedId).session
      XCTAssertEqual(originalFailure.status, .failed)
      XCTAssertNotEqual(originalFailure.failureKind, .promptTooLarge)

      let bullets = ["a", "b", "c"].map { "- " + String(repeating: $0, count: 3_600) }.joined(separator: "\n")
      try ("## Instructions\n" + bullets + "\n").write(to: edit, atomically: true, encoding: .utf8)
      let updated = await app.run(["bot", "memory", "edit", "alpha", "--file", edit.path] + flags, environment: environment)
      XCTAssertEqual(updated.exitCode, .success, updated.stderr)
      let recoveryFlags = flags + ["--mock-scenario", scenarioPath, "--output", "json"]
      let resumed = await app.run(
        ["session", "resume", failedId, "--retry-failed-step"] + recoveryFlags, environment: environment
      )
      XCTAssertEqual(resumed.exitCode, .failure, resumed.stderr + resumed.stdout)
      XCTAssertEqual(try runtime.loadStrictReadOnly(sessionId: failedId).session.failureKind, .promptTooLarge)

      let rerun = await app.run(
        ["session", "rerun", session.sessionId, session.entryStepId] + recoveryFlags, environment: environment
      )
      XCTAssertEqual(rerun.exitCode, .failure, rerun.stderr + rerun.stdout)
      let rerunIds = try Set(bots.links(botId: "alpha").map(\.sessionId)).subtracting(beforeRecovery)
      XCTAssertEqual(rerunIds.count, 1)
      let rerunId = try XCTUnwrap(rerunIds.first)
      XCTAssertEqual(try runtime.loadStrictReadOnly(sessionId: rerunId).session.failureKind, .promptTooLarge)
    }
  }
}

private actor CapturingMemoryScenarioAdapter: NodeAdapter {
  let underlying: ScenarioNodeAdapter
  private(set) var prompts: [String] = []

  init(underlying: ScenarioNodeAdapter) { self.underlying = underlying }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    prompts.append(input.systemPromptText ?? "")
    return try await underlying.execute(input, context: context)
  }
}
