import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaSQLite
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

// The plan and verification filter require this suite name.
// swiftlint:disable:next type_name
final class WorkflowDefinitionSourceDriftResolutionTests: XCTestCase {
  @MainActor
  func testConfiguredLaunchRejectsChangedSource() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await makeProvider(fixture).executeWorkflow(.init(workflowName: "service-flow"))
    let fileOptions = WorkflowResolutionOptions(workflowName: "service-flow", workingDirectory: fixture.root.path)
    let bundle = try FileSystemWorkflowBundleResolver().resolve(fileOptions)
    let mismatchedOptions = WorkflowResolutionOptions(workflowName: "other", workingDirectory: fixture.root.path)
    let resolver = DefinitionStoreWorkflowBundleResolver(inner: FileSystemWorkflowBundleResolver(),
      sessionStore: fixture.store.path, environment: ["HOME": fixture.root.path], actor: .init(kind: .api), mode: .lookupOnly)
    _ = try resolver.seed(fileBundle: bundle, options: mismatchedOptions)
    let counts = try rowCounts(fixture.store.path)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "other", workflowId: "other", displayName: "other", sourceDescription: "test fixture",
      workflowDirectory: fixture.workflow.path, workingDirectory: fixture.root.path, eventRoot: nil, eventSources: []
    )
    let context = RielaWebWorkflowContext(
      profile: .default, assistant: .init(), sources: [candidate], workingDirectory: fixture.root,
      appRoot: fixture.root, sessionStoreRoot: fixture.store.path, principalId: "test", environment: ["HOME": fixture.root.path]
    )
    let runtime = RielaWebWorkflowRuntime()
    let response = runtime.handler(context: context).launchConfiguredWorkflow(identity: "configured", source: candidate,
      configuration: WorkflowInstanceConfiguration(workingDirectory: fixture.root.path), variables: [:])
    XCTAssertEqual(response.status, 409)
    XCTAssertTrue(try XCTUnwrap(String(data: response.body, encoding: .utf8)).contains("source_changed"))
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
    await runtime.shutdown()
  }

  func testCalleeSyncAndOneTimeRun() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtureRoot = root.appendingPathComponent(
      "tmp/stale-definition/sdwd-03-service-resolution-integration/fixture-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let workflowRoot = fixtureRoot.appendingPathComponent(".riela/workflows")
    try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
    for name in ["workflow-call-live-echo", "workflow-call-live-echo-callee"] {
      try FileManager.default.copyItem(at: root.appendingPathComponent("examples/\(name)"),
                                       to: workflowRoot.appendingPathComponent(name))
    }
    let storeRoot = fixtureRoot.appendingPathComponent("sessions").path
    let provider = WorkflowExecutionProvider(workingDirectory: fixtureRoot.path, sessionStoreRoot: storeRoot,
                                              environment: ["HOME": fixtureRoot.path])
    _ = try await provider.executeWorkflow(.init(workflowName: "workflow-call-live-echo"))
    let store = WorkflowDefinitionStore(rootDirectory: storeRoot)
    let name = "workflow-call-live-echo-callee"
    let old = try XCTUnwrap(store.current(workflowName: name)?.version.versionId)
    let path = workflowRoot.appendingPathComponent("\(name)/workflow.json")
    let contents = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "120000", with: "21600000")
    try contents.write(to: path, atomically: true, encoding: .utf8)
    let second = try await provider.executeWorkflow(.init(workflowName: "workflow-call-live-echo"))
    let parent = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)).load(sessionId: second.sessionId)
    let execution = try XCTUnwrap(parent.session.executions.first { $0.stepId == "produce-request" }?.executionId)
    let invocation = try XCTUnwrap(try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)).nestedInvocationRecord(
        parentSessionId: second.sessionId, sourceStepExecutionId: execution, branchId: "cross-workflow"))
    let pin = try XCTUnwrap(invocation.childTerminalSnapshot?.session.definitionSource?.versionId)
    XCTAssertNotEqual(pin, old)
    XCTAssertEqual(try store.version(versionId: pin)?.operation, .import)
    let freshStore = fixtureRoot.appendingPathComponent("one-time").path
    let result = await WorkflowRunCommand().run(.init(target: "workflow-call-live-echo",
      resolution: .init(workflowName: "workflow-call-live-echo", workingDirectory: fixtureRoot.path),
      output: .json, sessionStore: freshStore, workingDirectory: fixtureRoot.path))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: freshStore)), mode: .strictReadOnly, options: .readOnlyDefault)
    for table in ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"] {
      XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"], "0")
    }
  }

  @MainActor
  func testEditedHeadWarnsOnBothLaunchPaths() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = makeProvider(fixture)
    _ = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let definitionService = service(fixture)
    let updated = try definitionService.updatePrompt(workflowName: "service-flow", nodeId: "other",
      field: WorkflowDefinitionPromptField(parsing: "promptTemplate"), text: "STORE", reason: "independent edit",
      expectedVersionId: nil, evidence: [], actor: .init(kind: .user)).0
    try editTimeout(fixture)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let history = try store.history(workflowName: "service-flow")
    let counts = try rowCounts(fixture.store.path)
    let ordinary = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let ordinarySnapshot = try snapshot(ordinary.sessionId, fixture)
    XCTAssertEqual(ordinarySnapshot.session.definitionSource?.versionId, updated.versionId)
    XCTAssertTrue(ordinarySnapshot.diagnostics.contains { $0.contains("definitionStore.sourceDrift") })
    let configured = try await configuredLaunch(fixture)
    XCTAssertEqual(configured.session.definitionSource?.versionId, updated.versionId)
    XCTAssertTrue(configured.diagnostics.contains { $0.contains("definitionStore.sourceDrift") })
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, history.count)
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
  }

  func testPreparedResolverUsesFileAndLookupOnlyDoesNotSync() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await makeProvider(fixture).executeWorkflow(.init(workflowName: "service-flow"))
    let options = WorkflowResolutionOptions(workflowName: "service-flow", workingDirectory: fixture.root.path)
    let original = DefinitionStoreWorkflowBundleResolver(inner: FileSystemWorkflowBundleResolver(),
      sessionStore: fixture.store.path, environment: ["HOME": fixture.root.path], actor: .init(kind: .api), mode: .lookupOrSeed)
    let stale = try original.resolve(options)
    try editTimeout(fixture)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let count = try store.history(workflowName: "service-flow").count
    let counts = try rowCounts(fixture.store.path)
    let readOnly = DefinitionStoreWorkflowBundleResolver(inner: EditorPreparedBundleResolver(bundle: stale),
      sessionStore: fixture.store.path, environment: ["HOME": fixture.root.path], actor: .init(kind: .api), mode: .lookupOnly)
    XCTAssertEqual(try readOnly.lookup(options)?.workflow.defaults.nodeTimeoutMs, 3300000)
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, count)
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
    let syncing = DefinitionStoreWorkflowBundleResolver(inner: EditorPreparedBundleResolver(bundle: stale),
      sessionStore: fixture.store.path, environment: ["HOME": fixture.root.path], actor: .init(kind: .api), mode: .lookupOrSeed)
    let bundle = try XCTUnwrap(syncing.lookup(options))
    XCTAssertEqual(bundle.workflow.defaults.nodeTimeoutMs, 21600000)
    let versionId = try XCTUnwrap(bundle.definitionSource?.versionId)
    let document = try service(fixture).show(workflowName: "service-flow", versionId: versionId).document
    XCTAssertTrue(try XCTUnwrap(document.authoredFiles["workflow.json"]).contains("21600000"))
  }

  @MainActor
  func testConfiguredLaunchSyncAndInvalidSource() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try await configuredLaunch(fixture)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let initialVersion = try XCTUnwrap(first.session.definitionSource?.versionId)
    XCTAssertEqual(try store.history(workflowName: "service-flow").filter { $0.operation == .seed }.count, 1)
    try editTimeout(fixture)
    let second = try await configuredLaunch(fixture)
    let versionId = try XCTUnwrap(second.session.definitionSource?.versionId)
    XCTAssertNotEqual(versionId, initialVersion)
    XCTAssertEqual(try store.version(versionId: versionId)?.operation, .import)
    let document = try service(fixture).show(workflowName: "service-flow", versionId: versionId).document
    XCTAssertEqual(document.runtime.workflow.defaults.nodeTimeoutMs, 21600000)
    XCTAssertTrue(try XCTUnwrap(document.authoredFiles["workflow.json"]).contains("21600000"))
    let history = try store.history(workflowName: "service-flow")
    let counts = try rowCounts(fixture.store.path)
    XCTAssertEqual(history.filter { $0.operation == .import && $0.actor.id == "service-auto-sync" }.count, 1)
    XCTAssertTrue(second.diagnostics.contains { $0.contains("definitionStore.autoSynced") })
    let third = try await configuredLaunch(fixture)
    XCTAssertEqual(third.session.definitionSource?.versionId, versionId)
    XCTAssertFalse(third.diagnostics.contains { $0.contains("definitionStore.autoSynced") })
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, history.count)
    try "{".write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let invalid = try await configuredLaunch(fixture)
    XCTAssertEqual(invalid.session.definitionSource?.versionId, versionId)
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, history.count)
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
    XCTAssertTrue(invalid.diagnostics.contains { $0.contains("definitionStore.sourceInvalid") })
  }

  func testServiceAutoSyncAndUnchangedRelaunch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = makeProvider(fixture)
    let first = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let initial = try snapshot(first.sessionId, fixture)
    let initialVersion = try XCTUnwrap(initial.session.definitionSource?.versionId)
    try editTimeout(fixture)
    let second = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let synced = try snapshot(second.sessionId, fixture)
    let versionId = try XCTUnwrap(synced.session.definitionSource?.versionId)
    XCTAssertNotEqual(versionId, initialVersion)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    XCTAssertEqual(try store.version(versionId: versionId)?.operation, .import)
    let document = try service(fixture).show(workflowName: "service-flow", versionId: versionId).document
    XCTAssertEqual(document.runtime.workflow.defaults.nodeTimeoutMs, 21600000)
    XCTAssertTrue(try XCTUnwrap(document.authoredFiles["workflow.json"]).contains("21600000"))
    let history = try store.history(workflowName: "service-flow")
    let counts = try rowCounts(fixture.store.path)
    XCTAssertEqual(history.filter { $0.operation == .import && $0.actor.id == "service-auto-sync" }.count, 1)
    XCTAssertTrue(synced.diagnostics.contains { $0.contains("definitionStore.autoSynced") })
    let third = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let repeated = try snapshot(third.sessionId, fixture)
    XCTAssertEqual(repeated.session.definitionSource?.versionId, versionId)
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, history.count)
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
    XCTAssertFalse(repeated.diagnostics.contains { $0.contains("definitionStore.autoSynced") })
  }

  func testServiceInvalidSourceKeepsStoredHead() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = makeProvider(fixture)
    let first = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let before = try snapshot(first.sessionId, fixture)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let history = try store.history(workflowName: "service-flow")
    let counts = try rowCounts(fixture.store.path)
    try "{".write(to: fixture.workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let second = try await provider.executeWorkflow(.init(workflowName: "service-flow"))
    let after = try snapshot(second.sessionId, fixture)
    XCTAssertEqual(after.session.definitionSource?.versionId, before.session.definitionSource?.versionId)
    XCTAssertEqual(try store.history(workflowName: "service-flow").count, history.count)
    XCTAssertEqual(try rowCounts(fixture.store.path), counts)
    XCTAssertTrue(after.diagnostics.contains { $0.contains("definitionStore.sourceInvalid") })
  }

  private struct Fixture {
    let root: URL
    let workflow: URL
    let store: URL
  }

  @MainActor
  private func configuredLaunch(_ fixture: Fixture) async throws -> WorkflowRuntimePersistenceSnapshot {
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "service-flow", workflowId: "service-flow", displayName: "service-flow", sourceDescription: "test fixture",
      workflowDirectory: fixture.workflow.path, workingDirectory: fixture.root.path, eventRoot: nil, eventSources: []
    )
    let context = RielaWebWorkflowContext(
      profile: .default, assistant: .init(), sources: [candidate], workingDirectory: fixture.root,
      appRoot: fixture.root, sessionStoreRoot: fixture.store.path, principalId: "test", environment: ["HOME": fixture.root.path]
    )
    let runtime = RielaWebWorkflowRuntime()
    let response = runtime.handler(context: context).launchConfiguredWorkflow(
      identity: "configured", source: candidate,
      configuration: WorkflowInstanceConfiguration(workingDirectory: fixture.root.path), variables: [:]
    )
    XCTAssertEqual(response.status, 202)
    let launch = try XCTUnwrap(runtime.launches.values.first)
    for _ in 0..<200 where launch.snapshot["status"] == .string("running") {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(launch.snapshot["status"], .string("completed"))
    guard case let .string(sessionId) = launch.snapshot["sessionId"] else {
      await runtime.shutdown()
      throw NSError(domain: "ConfiguredLaunch", code: 1)
    }
    let result = try snapshot(sessionId, fixture)
    await runtime.shutdown()
    return result
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(
        "tmp/stale-definition/sdwd-03-service-resolution-integration/fixture-\(UUID().uuidString)"
      )
    let workflow = root.appendingPathComponent(".riela/workflows/service-flow")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    let json = #"""
      {"workflowId":"service-flow","entryStepId":"work","defaults":{"nodeTimeoutMs":3300000,"maxLoopIterations":1},
      "nodes":[{"id":"worker","nodeFile":"nodes/node-worker.json"},{"id":"other","nodeFile":"nodes/node-other.json"}],
      "steps":[{"id":"work","nodeId":"worker","role":"worker"}]}
      """#
    try json.write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let node = #"{"id":"worker","nodeType":"command","command":{"executable":"/bin/echo","arguments":["{\"ok\":true}"]}}"#
    try node.write(to: workflow.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)
    let other = #"{"id":"other","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"promptTemplateFile":"prompts/a.md","output":{"description":"Return a result."}}"#
    try other.write(to: workflow.appendingPathComponent("nodes/node-other.json"), atomically: true, encoding: .utf8)
    try "FILE".write(to: workflow.appendingPathComponent("prompts/a.md"), atomically: true, encoding: .utf8)
    return Fixture(root: root, workflow: workflow, store: root.appendingPathComponent("sessions"))
  }

  private func editTimeout(_ fixture: Fixture) throws {
    let path = fixture.workflow.appendingPathComponent("workflow.json")
    let json = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "3300000", with: "21600000")
    try json.write(to: path, atomically: true, encoding: .utf8)
  }

  private func makeProvider(_ fixture: Fixture) -> WorkflowExecutionProvider {
    WorkflowExecutionProvider(workingDirectory: fixture.root.path, sessionStoreRoot: fixture.store.path,
                              environment: ["HOME": fixture.root.path])
  }

  private func service(_ fixture: Fixture) -> WorkflowDefinitionService {
    WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver())
  }

  private func snapshot(_ id: String, _ fixture: Fixture) throws -> WorkflowRuntimePersistenceSnapshot {
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.store.path)
    ).load(sessionId: id)
  }

  private func rowCounts(_ root: String) throws -> [String?] {
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root)), mode: .strictReadOnly, options: .readOnlyDefault)
    return try ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"].map {
      try database.query("SELECT COUNT(*) AS count FROM \($0)").first?["count"]
    }
  }
}
