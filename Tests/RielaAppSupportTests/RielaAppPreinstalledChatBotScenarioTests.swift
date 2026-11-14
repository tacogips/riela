#if os(macOS)
import Foundation
@testable import RielaAppSupport
import RielaServer
import XCTest

@MainActor
final class RielaAppPreinstalledChatBotScenarioTests: XCTestCase {
  func testFreshInstallCanEnableAndStartPreinstalledTelegramChatBot() async throws {
    let root = try temporaryHome()
    let appRoot = root.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let profileName = RielaAppProfileName.default
    let profileStore = RielaAppProfileStore(appRootURL: appRoot)
    try profileStore.prepareInitialProfile(profileName, persistsSelection: false)
    let daemonStore = RielaAppDaemonWorkflowStore(
      stateURL: appRoot.appendingPathComponent("profiles/default/daemon-workflows.json"),
      profileName: profileName
    )

    let bootstrapResult = try RielaAppDefaultProfileBootstrapper(
      profileStore: profileStore,
      daemonStore: daemonStore,
      profileName: profileName
    ).bootstrapIfNeeded()

    XCTAssertEqual(bootstrapResult.installedPackageNames.sorted(), [
      "discord-yuki-chat-bot",
      "mail-gateway-latest-mail",
      "slack-chat-bot",
      "telegram-yuki-chat-bot"
    ])

    var state = daemonStore.load()
    let packageRoot = RielaAppProfileStore.packageRootURL(appRootURL: appRoot, profileName: profileName)
    let sourceCandidates = RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows(
      appPackageRoot: packageRoot
    )
    let instances = state.workflowInstances(from: sourceCandidates)
    let instance = try XCTUnwrap(instances.first { $0.source.workflowId == "telegram-yuki-chat-bot" })
    let candidate = instance.candidate

    XCTAssertEqual(candidate.displayName, "Telegram Yuki Chat Bot")
    XCTAssertEqual(candidate.sourceDescription, "profile package")
    XCTAssertEqual(candidate.eventSourceSummary, "telegram-yuki-bot:telegram-gateway")
    XCTAssertTrue(candidate.startsEventSources)
    XCTAssertEqual(candidate.requiredEnvironment.map(\.name).sorted(), [
      "OPENAI_API_KEY",
      "RIELA_TELEGRAM_BOT_ID",
      "RIELA_TELEGRAM_BOT_TOKEN",
      "RIELA_TELEGRAM_YUKI_BOT_TOKEN"
    ])
    XCTAssertTrue(candidate.requiredEnvironment.filter(\.secret).map(\.name).sorted().contains("RIELA_TELEGRAM_BOT_TOKEN"))

    let missingEnvironmentStore = RielaAppEnvironmentFileStore(
      environmentFileURL: nil,
      processEnvironment: [:]
    )
    XCTAssertTrue(
      missingEnvironmentStore.statuses(for: candidate.requiredEnvironment.map(\.name)).allSatisfy { !$0.configured }
    )

    let configuredEnvironmentStore = RielaAppEnvironmentFileStore(
      environmentFileURL: nil,
      processEnvironment: [
        "OPENAI_API_KEY": "test-openai-key",
        "RIELA_TELEGRAM_BOT_ID": "12345",
        "RIELA_TELEGRAM_BOT_TOKEN": "test-reader-token",
        "RIELA_TELEGRAM_YUKI_BOT_TOKEN": "test-reply-token"
      ]
    )
    XCTAssertTrue(
      configuredEnvironmentStore.statuses(for: candidate.requiredEnvironment.map(\.name)).allSatisfy(\.configured)
    )

    var preference = state.preference(for: candidate.id)
    XCTAssertTrue(preference.available)
    XCTAssertFalse(preference.active)
    preference.active = true
    preference.environmentVariables = configuredEnvironmentStore.mergedEnvironment()
    state.preferences[candidate.id] = preference
    try daemonStore.save(state)

    let recorder = ScenarioEventSourceRecorder()
    let runtime = RielaAppDaemonWorkflowRuntime(
      eventSourceFactory: ScenarioEventSourceFactory(recorder: recorder),
      monitorIntervalNanoseconds: 0
    )
    await runtime.start(
      candidate,
      configuration: preference.configuration.serveConfiguration(
        inheritedEnvironment: preference.environmentVariables
      )
    )
    let snapshot = runtime.snapshot(for: candidate.id)

    XCTAssertEqual(snapshot.status, .running)
    XCTAssertTrue(snapshot.detail.contains("telegram-yuki-bot"))
    XCTAssertEqual(recorder.lastRequest?.eventRoot, candidate.eventRoot)
    XCTAssertEqual(recorder.lastRequest?.selection.path, candidate.workflowDirectory)
    XCTAssertEqual(
      recorder.lastRequest?.inheritedEnvironment["RIELA_TELEGRAM_BOT_TOKEN"],
      "test-reader-token"
    )
    XCTAssertEqual(recorder.lastResolvedWorkflow?.workflowId, "telegram-yuki-chat-bot")

    await runtime.stop(identity: candidate.id)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .stopped)
  }

  private func temporaryHome() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-app-preinstalled-chatbot-scenario-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}

private struct ScenarioEventSourceFactory: WorkflowServeEventSourceFactory {
  var recorder: ScenarioEventSourceRecorder

  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    recorder.record(request: request, resolvedWorkflow: resolvedWorkflow)
    return [
      ScenarioEventSourceHandle(status: WorkflowServeEventSourceStatus(
        sourceId: "telegram-yuki-bot",
        status: "running",
        generationId: generationId
      ))
    ]
  }
}

private final class ScenarioEventSourceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedRequest: WorkflowServeStartRequest?
  private var recordedResolvedWorkflow: WorkflowServeResolvedWorkflow?

  var lastRequest: WorkflowServeStartRequest? {
    lock.withLock { recordedRequest }
  }

  var lastResolvedWorkflow: WorkflowServeResolvedWorkflow? {
    lock.withLock { recordedResolvedWorkflow }
  }

  func record(request: WorkflowServeStartRequest, resolvedWorkflow: WorkflowServeResolvedWorkflow) {
    lock.withLock {
      recordedRequest = request
      recordedResolvedWorkflow = resolvedWorkflow
    }
  }
}

private final class ScenarioEventSourceHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  let status: WorkflowServeEventSourceStatus

  init(status: WorkflowServeEventSourceStatus) {
    self.status = status
  }

  func shutdown() async throws {}
}
#endif
