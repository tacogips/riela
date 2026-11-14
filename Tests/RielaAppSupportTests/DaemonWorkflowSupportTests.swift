#if os(macOS)
import Foundation
@testable import RielaAppSupport
import RielaServer
import XCTest

final class DaemonWorkflowSupportTests: XCTestCase {
  func testDiscoversUserWorkflowWithDaemonEventSource() throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent(".riela/workflows/chat-workflow", isDirectory: true)
    try writeWorkflow(id: "chat-workflow", to: workflowDirectory)
    try writeEventSource(
      id: "telegram-source",
      kind: "telegram-gateway",
      eventRoot: workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true)
    )
    try writeBinding(
      id: "telegram-to-workflow",
      sourceId: "telegram-source",
      workflowName: "chat-workflow",
      eventRoot: workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true)
    )

    let candidates = RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows()

    XCTAssertEqual(candidates.map(\.workflowId), ["chat-workflow"])
    XCTAssertEqual(candidates.first?.sourceDescription, "user workflow")
    XCTAssertEqual(candidates.first?.eventSourceSummary, "telegram-source:telegram-gateway")
  }

  func testExcludesWebhookOnlyWorkflow() throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent(".riela/workflows/webhook-workflow", isDirectory: true)
    try writeWorkflow(id: "webhook-workflow", to: workflowDirectory)
    let eventRoot = workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true)
    try writeEventSource(id: "adhoc-webhook", kind: "webhook", eventRoot: eventRoot)
    try writeBinding(id: "webhook-to-workflow", sourceId: "adhoc-webhook", workflowName: "webhook-workflow", eventRoot: eventRoot)

    let candidates = RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows()

    XCTAssertEqual(candidates, [])
  }

  func testDiscoversUserPackageWorkflowEventTemplates() throws {
    let root = try temporaryHome()
    let packageDirectory = root.appendingPathComponent(".riela/packages/trio-package", isDirectory: true)
    let workflowDirectory = packageDirectory.appendingPathComponent("workflows/trio", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    try """
    {"kind":"workflow","name":"trio-package","workflowDirectory":"workflows/trio"}
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    try writeWorkflow(id: "trio", to: workflowDirectory)
    let eventRoot = packageDirectory.appendingPathComponent("event-templates/.riela-events", isDirectory: true)
    try writeEventSource(id: "cron-source", kind: "cron", eventRoot: eventRoot)
    try writeBinding(id: "cron-to-trio", sourceId: "cron-source", workflowName: "trio", eventRoot: eventRoot)

    let candidates = RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows()

    XCTAssertEqual(candidates.map(\.id), ["user-package:trio-package:trio"])
    let eventRootPath = try XCTUnwrap(candidates.first?.eventRoot)
    XCTAssertEqual(
      URL(fileURLWithPath: eventRootPath).resolvingSymlinksInPath().path,
      eventRoot.resolvingSymlinksInPath().path
    )
  }

  func testDiscoversSelectedWorkflowDirectoryWithoutDaemonEventSource() throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent("selected-workflow", isDirectory: true)
    try writeWorkflow(id: "selected-workflow", to: workflowDirectory)

    let candidate = try XCTUnwrap(
      RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverSelectedWorkflowDirectory(workflowDirectory.path)
    )

    XCTAssertEqual(candidate.workflowId, "selected-workflow")
    XCTAssertEqual(candidate.sourceDescription, "selected workflow")
    XCTAssertEqual(candidate.eventRoot, nil)
    XCTAssertEqual(candidate.eventSourceSummary, "None")
    XCTAssertFalse(candidate.startsEventSources)
  }

  func testStoreRoundTripsPreferences() throws {
    let root = try temporaryHome()
    let store = RielaAppDaemonWorkflowStore(
      stateURL: root.appendingPathComponent("state/daemon-workflows.json")
    )
    let state = RielaAppDaemonWorkflowState(preferences: [
      "workflow-a": RielaAppDaemonWorkflowPreference(identity: "workflow-a", enabledAtLaunch: true, active: false)
    ], workflowDirectories: [
      root.appendingPathComponent("selected-workflow", isDirectory: true).path
    ])

    try store.save(state)

    XCTAssertEqual(store.load(), state)
  }

  func testProfileStoreRoundTripsActiveProfileAndListsProfiles() throws {
    let root = try temporaryHome()
    let appRoot = root.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let store = RielaAppProfileStore(appRootURL: appRoot)

    try store.saveActiveProfileName(RielaAppProfileName("work"))
    let profileStateURL = RielaAppDaemonWorkflowStore.defaultStateURL(
      profileName: RielaAppProfileName("experiments"),
      homeDirectory: root
    )
    try FileManager.default.createDirectory(at: profileStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{}".write(to: profileStateURL, atomically: true, encoding: .utf8)

    XCTAssertEqual(store.loadActiveProfileName(), RielaAppProfileName("work"))
    XCTAssertEqual(store.listProfileNames(including: RielaAppProfileName("work")), [
      RielaAppProfileName.default,
      RielaAppProfileName("experiments"),
      RielaAppProfileName("work")
    ])
  }

  func testStoreLoadsLegacyStateWithoutWorkflowDirectories() throws {
    let root = try temporaryHome()
    let stateURL = root.appendingPathComponent("state/daemon-workflows.json")
    try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "version": 1,
      "preferences": {
        "workflow-a": {
          "identity": "workflow-a",
          "enabledAtLaunch": true,
          "active": false
        }
      }
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let state = RielaAppDaemonWorkflowStore(stateURL: stateURL).load()

    XCTAssertEqual(state.workflowDirectories, [])
    XCTAssertEqual(state.preferences["workflow-a"]?.enabledAtLaunch, true)
    XCTAssertEqual(state.preferences["workflow-a"]?.active, false)
  }

  func testDefaultStoreLivesUnderDefaultRielaAppProfileDirectory() {
    let root = URL(fileURLWithPath: "/tmp/rielaapp-home", isDirectory: true)
    let defaultPath = RielaAppDaemonWorkflowStore.defaultStateURL(homeDirectory: root).path

    XCTAssertEqual(defaultPath, "/tmp/rielaapp-home/.riela/rielaapp/profiles/default/daemon-workflows.json")
  }

  func testProfileStoreLoadsLegacyUserRielaStateForDefaultProfileOnly() throws {
    let root = try temporaryHome()
    let legacyURL = RielaAppDaemonWorkflowStore.legacyUserRielaStateURL(homeDirectory: root)
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "version": 1,
      "workflowDirectories": ["/tmp/legacy-workflow"],
      "preferences": {
        "legacy": {
          "identity": "legacy",
          "enabledAtLaunch": true,
          "active": true
        }
      }
    }
    """.write(to: legacyURL, atomically: true, encoding: .utf8)

    let defaultState = RielaAppDaemonWorkflowStore(profileName: .default, homeDirectory: root).load()
    let otherState = RielaAppDaemonWorkflowStore(profileName: RielaAppProfileName("work"), homeDirectory: root).load()

    XCTAssertEqual(defaultState.workflowDirectories, ["/tmp/legacy-workflow"])
    XCTAssertEqual(defaultState.preferences["legacy"]?.enabledAtLaunch, true)
    XCTAssertEqual(otherState, RielaAppDaemonWorkflowState())
  }

  func testDaemonSourceKindPolicy() {
    XCTAssertTrue(RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind("cron"))
    XCTAssertTrue(RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind("telegram-gateway"))
    XCTAssertTrue(RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind("chat-sdk"))
    XCTAssertFalse(RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind("webhook"))
    XCTAssertFalse(RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind("custom-kind"))
  }

  func testProcessEventSourceFactoryLaunchesEventsServeCommand() async throws {
    let process = FakeEventServeProcessHandle(isRunning: true)
    let launcher = RecordingEventServeProcessLauncher(process: process)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      launcher: launcher,
      earlyExitGraceNanoseconds: 0
    )

    let handles = try await factory.startEventSources(
      for: WorkflowServeResolvedWorkflow(workflowId: "chat-workflow", selectedIdentity: "chat-workflow"),
      request: WorkflowServeStartRequest(
        selection: .directDirectory("/users/workflows/chat-workflow", identifier: "chat-workflow"),
        workingDirectory: "/users/workflows",
        sessionStoreRoot: "/users/.riela/sessions",
        eventRoot: "/users/workflows/chat-workflow/.riela-events",
        startsEventSources: true
      ),
      generationId: "generation-1"
    )

    XCTAssertEqual(handles.map(\.status.sourceId), ["riela-events-serve"])
    let command = try XCTUnwrap(launcher.commands.first)
    XCTAssertEqual(command.executablePath, "/bin/echo")
    XCTAssertEqual(command.arguments, [
      "events",
      "serve",
      "--workflow-definition-dir",
      "/users/workflows",
      "--event-root",
      "/users/workflows/chat-workflow/.riela-events",
      "--session-store",
      "/users/.riela/sessions"
    ])
    XCTAssertEqual(command.workingDirectory, "/users/workflows")
  }

  func testProcessEventSourceFactoryMergesUserEnvironmentFile() throws {
    let root = try temporaryHome()
    let envURL = root.appendingPathComponent(".riela/rielaapp.env")
    try FileManager.default.createDirectory(at: envURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    # Used by GUI-launched RielaApp daemon children.
    export RIELA_APP_TEST_TOKEN=from-file
    RIELA_APP_TEST_QUOTED_TOKEN="quoted token"
    INVALID-NAME=ignored
    """.write(to: envURL, atomically: true, encoding: .utf8)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      environmentFileURLs: [envURL]
    )

    let command = factory.eventServeCommand(
      workflowDefinitionDirectory: "/users/workflows",
      eventRoot: "/users/workflows/chat-workflow/.riela-events",
      executablePath: "/bin/echo"
    )

    XCTAssertEqual(command.environment["RIELA_APP_TEST_TOKEN"], "from-file")
    XCTAssertEqual(command.environment["RIELA_APP_TEST_QUOTED_TOKEN"], "quoted token")
    XCTAssertNil(command.environment["INVALID-NAME"])
  }

  func testProcessEventSourceFactoryFailsWhenEventsServeExitsImmediately() async throws {
    let process = FakeEventServeProcessHandle(
      isRunning: false,
      terminationStatus: 1,
      capturedOutput: "unsupportedLiveSources=telegram-live:telegram-gateway"
    )
    let launcher = RecordingEventServeProcessLauncher(process: process)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      launcher: launcher,
      earlyExitGraceNanoseconds: 0
    )

    do {
      _ = try await factory.startEventSources(
        for: WorkflowServeResolvedWorkflow(workflowId: "chat-workflow", selectedIdentity: "chat-workflow"),
        request: WorkflowServeStartRequest(
          selection: .directDirectory("/users/workflows/chat-workflow", identifier: "chat-workflow"),
          workingDirectory: "/users/workflows",
          eventRoot: "/users/workflows/chat-workflow/.riela-events",
          startsEventSources: true
        ),
        generationId: "generation-1"
      )
      XCTFail("expected early events serve exit to fail startup")
    } catch let error as WorkflowServeError {
      guard case let .startupFailed(diagnostic) = error else {
        return XCTFail("expected startupFailed, got \(error)")
      }
      XCTAssertEqual(diagnostic.code, "event_source_process_exited")
      XCTAssertTrue(diagnostic.message.contains("unsupportedLiveSources=telegram-live:telegram-gateway"))
    }
  }

  @MainActor
  func testRuntimeRestartsWorkflowWhenEventSourceExits() async throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent(".riela/workflows/chat-workflow", isDirectory: true)
    try writeRunnableWorkflow(id: "chat-workflow", to: workflowDirectory)
    let factory = RestartCountingEventSourceFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(
      eventSourceFactory: factory,
      monitorIntervalNanoseconds: 10_000_000
    )
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:chat-workflow",
      workflowId: "chat-workflow",
      displayName: "chat-workflow",
      sourceDescription: "user workflow",
      workflowDirectory: workflowDirectory.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true).path,
      eventSources: [RielaAppDaemonEventSourceSummary(id: "chat-source", kind: "telegram-gateway")]
    )

    await runtime.start(candidate)
    factory.markLatestExited()

    for _ in 0..<50 where factory.startCount < 2 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertGreaterThanOrEqual(factory.startCount, 2)
    await runtime.stop(identity: candidate.id)
  }

  private func temporaryHome() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-app-support-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeWorkflow(id: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {"workflowId":"\(id)","steps":[],"nodes":[]}
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }

  private func writeRunnableWorkflow(id: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(id)",
      "defaults": {
        "nodeTimeoutMs": 1000,
        "maxLoopIterations": 1
      },
      "entryStepId": "reply",
      "nodes": [
        {
          "id": "reply",
          "addon": {
            "name": "riela/test-reply",
            "version": "1"
          }
        }
      ]
    }
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }

  private func writeEventSource(id: String, kind: String, eventRoot: URL) throws {
    let directory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {"id":"\(id)","kind":"\(kind)"}
    """.write(to: directory.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
  }

  private func writeBinding(id: String, sourceId: String, workflowName: String, eventRoot: URL) throws {
    let directory = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {"id":"\(id)","sourceId":"\(sourceId)","workflowName":"\(workflowName)"}
    """.write(to: directory.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
  }
}

private final class RecordingEventServeProcessLauncher: RielaAppDaemonEventServeProcessLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let process: FakeEventServeProcessHandle
  private var recordedCommands: [RielaAppDaemonEventServeCommand] = []

  var commands: [RielaAppDaemonEventServeCommand] {
    lock.withLock { recordedCommands }
  }

  init(process: FakeEventServeProcessHandle) {
    self.process = process
  }

  func launch(_ command: RielaAppDaemonEventServeCommand) throws -> any RielaAppDaemonEventServeProcessHandle {
    lock.withLock {
      recordedCommands.append(command)
    }
    return process
  }
}

private final class FakeEventServeProcessHandle: RielaAppDaemonEventServeProcessHandle, @unchecked Sendable {
  var processIdentifier: Int32
  var isRunning: Bool
  var terminationStatus: Int32?
  var capturedOutput: String
  private(set) var terminated = false

  init(
    processIdentifier: Int32 = 123,
    isRunning: Bool,
    terminationStatus: Int32? = nil,
    capturedOutput: String = ""
  ) {
    self.processIdentifier = processIdentifier
    self.isRunning = isRunning
    self.terminationStatus = terminationStatus
    self.capturedOutput = capturedOutput
  }

  func terminate() async {
    terminated = true
    isRunning = false
  }
}

private final class RestartCountingEventSourceFactory: WorkflowServeEventSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var handles: [RestartCountingEventSourceHandle] = []

  var startCount: Int {
    lock.withLock { handles.count }
  }

  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    let handle = RestartCountingEventSourceHandle(generationId: generationId)
    lock.withLock {
      handles.append(handle)
    }
    return [handle]
  }

  func markLatestExited() {
    lock.withLock { handles.last }?.markExited()
  }
}

private final class RestartCountingEventSourceHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let generationId: String
  private var running = true

  init(generationId: String) {
    self.generationId = generationId
  }

  var status: WorkflowServeEventSourceStatus {
    lock.withLock {
      WorkflowServeEventSourceStatus(
        sourceId: "restart-counting",
        status: running ? "running" : "exited",
        generationId: generationId
      )
    }
  }

  func markExited() {
    lock.withLock {
      running = false
    }
  }

  func shutdown() async throws {
    markExited()
  }
}
#endif
