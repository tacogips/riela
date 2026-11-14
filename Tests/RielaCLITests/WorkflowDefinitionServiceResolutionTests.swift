import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaServer
import RielaSQLite
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class WorkflowDefinitionServiceResolutionTests: XCTestCase {
  func testServiceRunsUseStorePromptAndOneTimeRunStaysFileOnly() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let filePrompt = fixture.workflow.appendingPathComponent("prompts/a.md")
    let originalPromptDigest = try Data(contentsOf: filePrompt).sha256
    let provider = makeProvider(fixture: fixture)

    let first = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let firstCurrent = try XCTUnwrap(store.current(workflowName: "service-flow"))
    let firstRecord = try loadSession(first.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(firstRecord.session.definitionSource?.kind, .store)
    XCTAssertEqual(firstRecord.session.definitionSource?.versionId, firstCurrent.version.versionId)
    XCTAssertEqual(firstRecord.session.definitionSource?.storeRoot, fixture.store.standardizedFileURL.path)
    XCTAssertEqual(promptText(firstRecord), "FILE1")

    let updated = try WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
      .updatePrompt(
        workflowName: "service-flow",
        nodeId: "worker",
        field: WorkflowDefinitionPromptField(parsing: "promptTemplate"),
        text: "STORE",
        reason: "service resolution regression",
        expectedVersionId: firstCurrent.version.versionId,
        evidence: [],
        actor: WorkflowDefinitionActor(kind: .user)
      )
    XCTAssertEqual(try Data(contentsOf: filePrompt).sha256, originalPromptDigest)

    let second = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let secondRecord = try loadSession(second.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(secondRecord.session.definitionSource?.versionId, updated.0.versionId)
    XCTAssertEqual(promptText(secondRecord), "STORE")
    XCTAssertEqual(try Data(contentsOf: filePrompt).sha256, originalPromptDigest)

    let existingHeadCounts = try definitionRowCounts(root: fixture.store.path)
    let oneTimeAgainstHead = await makeCommand().run(WorkflowRunOptions(
      target: "service-flow",
      resolution: WorkflowResolutionOptions(workflowName: "service-flow", workingDirectory: fixture.root.path),
      output: .json,
      sessionStore: fixture.store.path,
      workingDirectory: fixture.root.path
    ))
    XCTAssertEqual(oneTimeAgainstHead.exitCode, .success, oneTimeAgainstHead.stderr)
    let oneTimeHeadResult = try decodeRunResult(oneTimeAgainstHead.stdout)
    let oneTimeHeadRecord = try loadSession(oneTimeHeadResult.session.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(oneTimeHeadRecord.session.definitionSource?.kind, .file)
    XCTAssertEqual(promptText(oneTimeHeadRecord), "FILE1")
    let fileBundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "service-flow", workingDirectory: fixture.root.path)
    )
    XCTAssertEqual(
      oneTimeHeadRecord.session.definitionSource?.digest,
      WorkflowDefinitionDocument.fileDefinitionSource(for: fileBundle, workflowName: "service-flow").digest
    )
    XCTAssertEqual(try definitionRowCounts(root: fixture.store.path), existingHeadCounts)

    let freshStore = fixture.root.appendingPathComponent("one-time-store", isDirectory: true)
    let oneTimeFresh = await makeCommand().run(WorkflowRunOptions(
      target: "service-flow",
      resolution: WorkflowResolutionOptions(workflowName: "service-flow", workingDirectory: fixture.root.path),
      output: .json,
      sessionStore: freshStore.path,
      workingDirectory: fixture.root.path
    ))
    XCTAssertEqual(oneTimeFresh.exitCode, .success, oneTimeFresh.stderr)
    let oneTimeFreshResult = try decodeRunResult(oneTimeFresh.stdout)
    let oneTimeFreshRecord = try loadSession(oneTimeFreshResult.session.sessionId, storeRoot: freshStore.path)
    XCTAssertEqual(oneTimeFreshRecord.session.definitionSource?.kind, .file)
    XCTAssertEqual(promptText(oneTimeFreshRecord), "FILE1")
    XCTAssertEqual(try definitionRowCounts(root: freshStore.path), [0, 0, 0, 0])

    try "FILE2".write(to: filePrompt, atomically: true, encoding: .utf8)
    try "{".write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let third = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let thirdRecord = try loadSession(third.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(thirdRecord.session.definitionSource?.versionId, updated.0.versionId)
    XCTAssertEqual(promptText(thirdRecord), "STORE")

  }

  func testConcurrentServiceFirstRunsSeedOneHeadAndOneAudit() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = makeProvider(fixture: fixture)

    async let first = provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    async let second = provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let results = try await [first, second]
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let current = try XCTUnwrap(store.current(workflowName: "service-flow"))
    let audit = try store.history(workflowName: "service-flow")
    XCTAssertEqual(audit.count, 1)
    let sources = try results.map { try loadSession($0.sessionId, storeRoot: fixture.store.path).session.definitionSource }
    XCTAssertEqual(sources.compactMap { $0?.versionId }, [current.version.versionId, current.version.versionId])
  }

  func testRerunUsesPinnedStoreVersionAfterHeadMoves() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scenario = fixture.root.appendingPathComponent("scenario.json")
    try #"{"worker":{"provider":"scenario-mock","when":{"always":true},"payload":{"ok":true}}}"#
      .write(to: scenario, atomically: true, encoding: .utf8)
    let provider = makeProvider(fixture: fixture)
    let first = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let original = try loadSession(first.sessionId, storeRoot: fixture.store.path)
    let pinnedVersion = try XCTUnwrap(original.session.definitionSource?.versionId)
    _ = try WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
      .updatePrompt(
        workflowName: "service-flow",
        nodeId: "worker",
        field: WorkflowDefinitionPromptField(parsing: "promptTemplate"),
        text: "NEW-HEAD",
        reason: "pin rerun to source version",
        expectedVersionId: nil,
        evidence: [],
        actor: WorkflowDefinitionActor(kind: .user)
      )

    let rerun = await SessionRerunCommand().run(SessionRerunOptions(
      sessionId: first.sessionId,
      stepId: "work",
      output: .json,
      workingDirectory: fixture.root.path,
      mockScenarioPath: scenario.path,
      sessionStore: fixture.store.path
    ))
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let rerunResult = try JSONDecoder().decode(SessionRerunCommandResult.self, from: Data(rerun.stdout.utf8))
    let rerunRecord = try loadSession(rerunResult.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(rerunRecord.session.definitionSource?.versionId, pinnedVersion)
    XCTAssertEqual(promptText(rerunRecord), "FILE1")
  }

  func testResumeUsesPinnedStoreVersionAfterHeadMoves() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try installTwoStepWorkflow(fixture)
    let provider = makeProvider(fixture: fixture)
    let first = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(
      workflowName: "service-flow",
      maxSteps: 1
    ))
    let original = try loadSession(first.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(original.session.status, .failed)
    XCTAssertEqual(original.session.failureKind, .maxStepsExceeded)
    let pinnedVersion = try XCTUnwrap(original.session.definitionSource?.versionId)
    _ = try WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
      .updatePrompt(
        workflowName: "service-flow",
        nodeId: "worker2",
        field: WorkflowDefinitionPromptField(parsing: "promptTemplate"),
        text: "NEW-HEAD",
        reason: "pin resume to source version",
        expectedVersionId: nil,
        evidence: [],
        actor: WorkflowDefinitionActor(kind: .user)
      )
    let scenario = fixture.root.appendingPathComponent("scenario.json")
    try #"{"worker":{"provider":"scenario-mock","when":{"always":true},"payload":{"ok":true}},"worker2":{"provider":"scenario-mock","when":{"always":true},"payload":{"ok":true}}}"#
      .write(to: scenario, atomically: true, encoding: .utf8)

    let resumed = await SessionResumeCommand().run(SessionResumeOptions(
      sessionId: first.sessionId,
      output: .json,
      workingDirectory: fixture.root.path,
      mockScenarioPath: scenario.path,
      sessionStore: fixture.store.path,
      maxSteps: 3
    ))
    XCTAssertEqual(resumed.exitCode, .success, resumed.stderr + resumed.stdout)
    let resumeResult = try JSONDecoder().decode(SessionResumeCommandResult.self, from: Data(resumed.stdout.utf8))
    let resumedRecord = try loadSession(resumeResult.sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(resumedRecord.session.status, .completed)
    XCTAssertEqual(resumedRecord.session.definitionSource?.versionId, pinnedVersion)
    XCTAssertEqual(
      resumedRecord.session.executions.first(where: { $0.nodeId == "worker2" })?.inputSnapshot?["promptText"]?.stringValue,
      "FILE1"
    )
  }

  func testEventRunnerUsesExistingStoreDefinition() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = makeProvider(fixture: fixture)
    _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "service-flow"))
    let service = WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
    let updated = try service.updatePrompt(
      workflowName: "service-flow",
      nodeId: "worker",
      field: WorkflowDefinitionPromptField(parsing: "promptTemplate"),
      text: "EVENT-STORE",
      reason: "event resolution regression",
      expectedVersionId: nil,
      evidence: [],
      actor: WorkflowDefinitionActor(kind: .user)
    )
    let scenario = fixture.root.appendingPathComponent("scenario.json")
    try #"{"worker":{"provider":"scenario-mock","when":{"always":true},"payload":{"ok":true}}}"#
      .write(to: scenario, atomically: true, encoding: .utf8)
    let parsed = try ParsedParityOptions([
      "--working-dir", fixture.root.path,
      "--session-store", fixture.store.path,
      "--mock-scenario", scenario.path
    ])
    let result = try await CLIEventWorkflowRunner().runWorkflow(EventWorkflowRunRequest(
      workflowName: "service-flow",
      runtimeVariables: [:],
      parsed: parsed
    ))
    XCTAssertEqual(result.session.definitionSource?.kind, .store)
    XCTAssertEqual(result.session.definitionSource?.versionId, updated.0.versionId)
    XCTAssertEqual(result.session.executions.first?.inputSnapshot?["promptText"]?.stringValue, "EVENT-STORE")

    let eventRoot = fixture.root.appendingPathComponent("events", isDirectory: true)
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    let config = EventLiveConfigProjection(
      sources: [EventSourceContract(id: "cron", kind: .cron)],
      bindings: [EventBindingContract(
        id: "binding",
        sourceId: "cron",
        workflowName: "service-flow",
        inputMapping: EventInputMapping(mode: .eventInput)
      )]
    )
    try JSONEncoder().encode(config).write(to: eventRoot.appendingPathComponent("events.json"))
    try "{".write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try "FILE2".write(to: fixture.workflow.appendingPathComponent("prompts/a.md"), atomically: true, encoding: .utf8)
    let auditCount = try service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count
    _ = try await eventRequiredEnvironment(eventRoot: eventRoot, target: nil, parsed: parsed)
    XCTAssertEqual(try service.history(workflowName: "service-flow", nodeId: nil, limit: nil).count, auditCount)
  }

  @MainActor
  func testConfiguredLaunchUsesStoredDefinitionAfterSourceBreaks() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let nodeJSON = #"{"id":"worker","nodeType":"command","command":{"executable":"/bin/echo","arguments":["{\"ok\":true}"]}}"#
    try nodeJSON.write(to: fixture.workflow.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)
    let resolution = WorkflowResolutionOptions(
      workflowName: "service-flow",
      workflowDefinitionDir: fixture.workflow.path,
      workingDirectory: fixture.root.path
    )
    let resolver = FileSystemWorkflowBundleResolver()
    let storeResolver = DefinitionStoreWorkflowBundleResolver(
      inner: resolver,
      sessionStore: fixture.store.path,
      environment: ["HOME": fixture.root.path],
      actor: .init(kind: .api, id: "configured-run"),
      mode: .lookupOrSeed
    )
    let storedBundle = try storeResolver.resolve(resolution)
    let storedVersion = try XCTUnwrap(storedBundle.definitionSource?.versionId)
    try "{".write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try "broken".write(to: fixture.workflow.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)

    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "service-flow",
      workflowId: "service-flow",
      displayName: "service-flow",
      sourceDescription: "test fixture",
      workflowDirectory: fixture.workflow.path,
      workingDirectory: fixture.root.path,
      eventRoot: nil,
      eventSources: []
    )
    let context = RielaWebWorkflowContext(
      profile: .default,
      assistant: .init(),
      sources: [candidate],
      workingDirectory: fixture.root,
      appRoot: fixture.root,
      sessionStoreRoot: fixture.store.path,
      principalId: "test",
      environment: ["HOME": fixture.root.path]
    )
    let runtime = RielaWebWorkflowRuntime()
    let handler = runtime.handler(context: context)
    let response = handler.launchConfiguredWorkflow(
      identity: "configured",
      source: candidate,
      configuration: WorkflowInstanceConfiguration(workingDirectory: fixture.root.path),
      variables: [:]
    )
    XCTAssertEqual(response.status, 202)
    let launch = try XCTUnwrap(runtime.launches.values.first)
    for _ in 0..<200 where launch.snapshot["status"] == .string("running") {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(launch.snapshot["status"], .string("completed"))
    guard case let .string(sessionId) = launch.snapshot["sessionId"] else {
      await runtime.shutdown()
      return XCTFail("configured launch did not record a session")
    }
    let persisted = try loadSession(sessionId, storeRoot: fixture.store.path)
    XCTAssertEqual(persisted.session.definitionSource?.versionId, storedVersion)
    await runtime.shutdown()
  }

  func testServiceRunCalleeChildCarriesStorePinAndOneTimeRunStaysFileOnly() async throws {
    let fixture = try makeCrossWorkflowFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = WorkflowExecutionProvider(
      workingDirectory: fixture.root.path,
      sessionStoreRoot: fixture.store.path,
      environment: ["HOME": fixture.root.path]
    )

    let serviceResult = try await provider.executeWorkflow(
      GraphQLExecuteWorkflowInput(workflowName: "workflow-call-live-echo")
    )
    let serviceParent = try loadSession(serviceResult.sessionId, storeRoot: fixture.store.path)
    let serviceChild = try crossWorkflowChildRecord(parent: serviceParent, storeRoot: fixture.store.path)
    let calleeHead = try XCTUnwrap(
      WorkflowDefinitionStore(rootDirectory: fixture.store.path)
        .current(workflowName: "workflow-call-live-echo-callee")
    )
    XCTAssertEqual(serviceParent.session.definitionSource?.kind, .store)
    XCTAssertEqual(serviceChild.definitionSource?.kind, .store)
    XCTAssertEqual(serviceChild.definitionSource?.versionId, calleeHead.version.versionId)

    let freshStore = fixture.root.appendingPathComponent("one-time-session-store", isDirectory: true)
    let oneTimeResult = await WorkflowRunCommand().run(WorkflowRunOptions(
      target: "workflow-call-live-echo",
      resolution: WorkflowResolutionOptions(
        workflowName: "workflow-call-live-echo",
        workingDirectory: fixture.root.path
      ),
      output: .json,
      sessionStore: freshStore.path,
      workingDirectory: fixture.root.path
    ))
    XCTAssertEqual(oneTimeResult.exitCode, .success, oneTimeResult.stderr + oneTimeResult.stdout)
    let oneTimeParent = try loadSession(try decodeRunResult(oneTimeResult.stdout).session.sessionId,
                                       storeRoot: freshStore.path)
    let oneTimeChild = try crossWorkflowChildRecord(parent: oneTimeParent, storeRoot: freshStore.path)
    XCTAssertEqual(oneTimeChild.definitionSource?.kind, .file)
    XCTAssertEqual(try definitionRowCounts(root: freshStore.path), [0, 0, 0, 0])
  }

  private func makeFixture() throws -> Fixture {
    let root = repositoryRoot().appendingPathComponent("tmp/ds179/ds179-03-service-resolution/fixture-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/service-flow", isDirectory: true)
    let store = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    let workflowJSON = #"""
      {"workflowId":"service-flow","entryStepId":"work",
      "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
      "nodes":[{"id":"worker","nodeFile":"nodes/node-worker.json"}],
      "steps":[{"id":"work","nodeId":"worker","role":"worker"}]}
      """#
    try workflowJSON.write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let nodeJSON = #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"promptTemplateFile":"prompts/a.md","output":{"description":"Return a result."}}"#
    try nodeJSON.write(to: workflow.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)
    try "FILE1".write(to: workflow.appendingPathComponent("prompts/a.md"), atomically: true, encoding: .utf8)
    return Fixture(root: root, workflow: workflow, store: store)
  }

  private func makeCrossWorkflowFixture() throws -> Fixture {
    let checkoutRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = checkoutRoot.appendingPathComponent(
      "tmp/ds179/ds179-03-service-resolution/fixture-\(UUID().uuidString)"
    )
    let workflowRoot = root.appendingPathComponent(".riela/workflows", isDirectory: true)
    let store = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
    for workflowName in ["workflow-call-live-echo", "workflow-call-live-echo-callee"] {
      let source = checkoutRoot.appendingPathComponent("examples/\(workflowName)", isDirectory: true)
      try FileManager.default.copyItem(at: source, to: workflowRoot.appendingPathComponent(workflowName))
    }
    return Fixture(
      root: root,
      workflow: workflowRoot.appendingPathComponent("workflow-call-live-echo", isDirectory: true),
      store: store
    )
  }

  private func crossWorkflowChildRecord(
    parent: PersistedCLIWorkflowSession,
    storeRoot: String
  ) throws -> WorkflowSession {
    let sourceExecutionId = try XCTUnwrap(
      parent.session.executions.first(where: { $0.stepId == "produce-request" })?.executionId
    )
    let nestedRecord = try XCTUnwrap(try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)
    ).nestedInvocationRecord(
      parentSessionId: parent.session.sessionId,
      sourceStepExecutionId: sourceExecutionId,
      branchId: "cross-workflow"
    ))
    return try XCTUnwrap(nestedRecord.childTerminalSnapshot).session
  }

  private func makeProvider(fixture: Fixture) -> WorkflowExecutionProvider {
    WorkflowExecutionProvider(
      workingDirectory: fixture.root.path,
      sessionStoreRoot: fixture.store.path,
      environment: ["HOME": fixture.root.path],
      command: makeCommand()
    )
  }

  private func installTwoStepWorkflow(_ fixture: Fixture) throws {
    let workflowJSON = #"""
      {"workflowId":"service-flow","entryStepId":"work",
       "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
       "nodes":[{"id":"worker","nodeFile":"nodes/node-worker.json"},
         {"id":"worker2","nodeFile":"nodes/node-worker2.json"}],
       "steps":[{"id":"work","nodeId":"worker","role":"worker",
         "transitions":[{"toStepId":"next"}]},
         {"id":"next","nodeId":"worker2","role":"worker"}]}
      """#
    try workflowJSON.write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let nodeJSON = #"{"id":"worker2","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"promptTemplateFile":"prompts/a.md","output":{"description":"Return a result."}}"#
    try nodeJSON.write(to: fixture.workflow.appendingPathComponent("nodes/node-worker2.json"), atomically: true, encoding: .utf8)
  }

  private func makeCommand() -> WorkflowRunCommand {
    var command = WorkflowRunCommand()
    command.taskNodeAdapterOverride = ScenarioNodeAdapter(scenario: WorkflowMockScenario(responses: [
      "worker": [MockNodeResponse(payload: ["ok": .bool(true)])],
      "worker2": [MockNodeResponse(payload: ["ok": .bool(true)])]
    ]))
    return command
  }

  private func loadSession(_ id: String, storeRoot: String) throws -> PersistedCLIWorkflowSession {
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).loadStrictReadOnly(sessionId: id)
  }

  private func decodeRunResult(_ text: String) throws -> WorkflowRunResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(text.utf8))
  }

  private func promptText(_ record: PersistedCLIWorkflowSession) -> String? {
    record.session.executions.first?.inputSnapshot?["promptText"]?.stringValue
  }

  private func definitionRowCounts(root: String) throws -> [Int] {
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root)
      ),
      mode: .strictReadOnly,
      options: .readOnlyDefault
    )
    return try ["definition_blobs", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }
}

private struct Fixture {
  var root: URL
  var workflow: URL
  var store: URL
}

private struct EventLiveConfigProjection: Codable {
  var sources: [EventSourceContract]
  var bindings: [EventBindingContract]
}

private extension Data {
  var sha256: String { RielaCore.JSONCanonical.sha256Hex(self) }
}
