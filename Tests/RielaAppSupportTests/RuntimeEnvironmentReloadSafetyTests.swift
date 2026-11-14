#if os(macOS)
import Foundation
import RielaCore
import RielaServer
@testable import RielaAppSupport
import XCTest

/// Loader stub: returns `TOKEN=<prefix><call>` for every source name, optionally
/// failing or sleeping on chosen calls (1-based).
private actor ReloadSafetyRunner: RuntimeEnvironmentCommandRunning {
  private var calls = 0
  private let failingCalls: Set<Int>
  private let slowCalls: [Int: UInt64]
  init(failingCalls: Set<Int> = [], slowCalls: [Int: UInt64] = [:]) {
    self.failingCalls = failingCalls; self.slowCalls = slowCalls
  }
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    calls += 1
    let call = calls
    if let delay = slowCalls[call] { try await Task.sleep(nanoseconds: delay) }
    if failingCalls.contains(call) { throw RuntimeEnvironmentError.sourceFailed }
    var object: [String: String] = [:]
    for name in source.names { object[name] = "value-\(call)" }
    return try JSONEncoder().encode(object)
  }
  func count() -> Int { calls }
}

/// Event source handle that records every runtime-environment update and shutdown.
private final class RecordingEnvironmentHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let generationId: String
  private var running = true
  private var updates: [UInt64] = []
  private var shutdowns = 0
  init(generationId: String) { self.generationId = generationId }
  var status: WorkflowServeEventSourceStatus {
    lock.withLock { WorkflowServeEventSourceStatus(sourceId: "recording", status: running ? "running" : "exited", generationId: generationId) }
  }
  var updateGenerations: [UInt64] { lock.withLock { updates } }
  var shutdownCount: Int { lock.withLock { shutdowns } }
  func markExited() { lock.withLock { running = false } }
  func shutdown() async throws { lock.withLock { shutdowns += 1; running = false } }
  func updateRuntimeEnvironment(generation: UInt64, names: [String], values: [String: String]) async throws {
    lock.withLock { updates.append(generation) }
  }
}

private final class RecordingEnvironmentFactory: WorkflowServeEventSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedHandles: [RecordingEnvironmentHandle] = []
  private var recordedRequests: [WorkflowServeStartRequest] = []
  var handles: [RecordingEnvironmentHandle] { lock.withLock { recordedHandles } }
  var requests: [WorkflowServeStartRequest] { lock.withLock { recordedRequests } }
  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow, request: WorkflowServeStartRequest, generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    let handle = RecordingEnvironmentHandle(generationId: generationId)
    lock.withLock { recordedHandles.append(handle); recordedRequests.append(request) }
    return [handle]
  }
}

final class RuntimeEnvironmentReloadSafetyTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-runtime-environment-reload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func writeWorkflow(id: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try """
    {"workflowId": "\(id)", "defaults": {"nodeTimeoutMs": 1000, "maxLoopIterations": 1}, "entryStepId": "worker",
     "nodes": [{"id": "worker", "nodeFile": "nodes/worker.node.json"}],
     "steps": [{"id": "worker", "nodeId": "worker", "role": "worker"}]}
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id": "worker", "model": "gpt-5", "modelFreeze": false, "promptTemplate": "Reply"}"#
      .write(to: directory.appendingPathComponent("nodes/worker.node.json"), atomically: true, encoding: .utf8)
  }

  /// A candidate with an event root so the runtime starts (fake) event-serve children.
  private func candidate(root: URL) throws -> RielaAppDaemonWorkflowCandidate {
    let workflowId = "reload-\(UUID().uuidString.prefix(8).lowercased())"
    let directory = root.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try writeWorkflow(id: workflowId, to: directory)
    return RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:\(workflowId)", workflowId: workflowId, displayName: workflowId, sourceDescription: "fixture",
      workflowDirectory: directory.path, workingDirectory: root.path,
      eventRoot: directory.appendingPathComponent(".riela-events", isDirectory: true).path,
      eventSources: [RielaAppDaemonEventSourceSummary(id: "chat", kind: "telegram-gateway")]
    )
  }

  private func configuration(names: [String] = ["TOKEN"], command: String = "/fixture", root: URL) -> WorkflowServeRuntimeConfiguration {
    WorkflowServeRuntimeConfiguration(
      workingDirectory: root.path, inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
      environmentResolution: RuntimeEnvironmentConfiguration(required: ["TOKEN"], sources: [
        RuntimeEnvironmentCommandSource(id: "fixture", names: names, command: [command])
      ]), environmentProfile: "default"
    )
  }

  @MainActor
  private func startRunning(
    _ runtime: RielaAppDaemonWorkflowRuntime, _ candidate: RielaAppDaemonWorkflowCandidate,
    _ configuration: WorkflowServeRuntimeConfiguration, root: URL
  ) async throws {
    await runtime.start(candidate, configuration: configuration, sessionStoreRoot: root.appendingPathComponent("sessions").path)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .running, runtime.snapshot(for: candidate.id).detail)
    let identity = candidate.id
    addTeardownBlock { await runtime.stop(identity: identity) }
  }

  /// B1: a reload that changes the managed-name set of a running channel child
  /// fails fast; neither the child nor the store entry is touched.
  @MainActor
  func testManagedNameChangeOnRunningChildFailsFastWithoutTouchingChildOrStore() async throws {
    let root = try temporaryRoot()
    let runner = ReloadSafetyRunner()
    let factory = RecordingEnvironmentFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(
      eventSourceFactory: factory, monitorIntervalNanoseconds: 0, environmentStore: RuntimeEnvironmentSnapshotStore(runner: runner)
    )
    let candidate = try candidate(root: root)
    let original = configuration(root: root)
    try await startRunning(runtime, candidate, original, root: root)
    XCTAssertEqual(factory.requests.first?.configuration.runtimeEnvironmentNames, ["TOKEN"])

    do {
      _ = try await runtime.reloadEnvironment(for: candidate, configuration: configuration(names: ["TOKEN", "EXTRA"], root: root))
      XCTFail("managed-name change on a running child must require a restart")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .restartRequired) }

    let handle = try XCTUnwrap(factory.handles.first)
    XCTAssertEqual(handle.updateGenerations, [])
    XCTAssertEqual(handle.shutdownCount, 0)
    XCTAssertEqual(factory.handles.count, 1)
    let loaderCalls = await runner.count()
    XCTAssertEqual(loaderCalls, 1, "no loader may run for a refused reload")
    let status = await runtime.environmentStatus(identity: candidate.id, profile: "default")
    XCTAssertEqual(status.generation, 1)
    XCTAssertEqual(status.readiness, .ready)
    XCTAssertNil(status.lastError)
    let captured = try await runtime.prepareEnvironment(for: candidate, configuration: original)
    XCTAssertEqual(captured.generation, 1)
    XCTAssertEqual(captured.runtimeEnvironment()["TOKEN"], "value-1")

    // Positive control: the same names reload into the live child.
    let reloaded = try await runtime.reloadEnvironment(for: candidate, configuration: original)
    XCTAssertEqual(reloaded.generation, 2)
    XCTAssertEqual(handle.updateGenerations, [2])
    XCTAssertEqual(handle.shutdownCount, 0)
  }

  /// D (changed descriptor, same names): a failed loader keeps the snapshot the
  /// running child still executes; a successful one installs into the child.
  @MainActor
  func testChangedDescriptorOnRunningChildKeepsPreviousSnapshotUntilLoaderSucceeds() async throws {
    let root = try temporaryRoot()
    let runner = ReloadSafetyRunner(failingCalls: [2])
    let factory = RecordingEnvironmentFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(
      eventSourceFactory: factory, monitorIntervalNanoseconds: 0, environmentStore: RuntimeEnvironmentSnapshotStore(runner: runner)
    )
    let candidate = try candidate(root: root)
    let original = configuration(root: root)
    try await startRunning(runtime, candidate, original, root: root)
    let changed = configuration(command: "/changed", root: root)

    do {
      _ = try await runtime.reloadEnvironment(for: candidate, configuration: changed)
      XCTFail("failing loader")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .sourceFailed) }
    let handle = try XCTUnwrap(factory.handles.first)
    XCTAssertEqual(handle.shutdownCount, 0)
    XCTAssertEqual(handle.updateGenerations, [])
    let failed = await runtime.environmentStatus(identity: candidate.id, profile: "default")
    XCTAssertEqual(failed.readiness, .ready)
    XCTAssertEqual(failed.generation, 1)
    XCTAssertEqual(failed.lastError, .sourceFailed)
    let retained = try await runtime.prepareEnvironment(for: candidate, configuration: original)
    XCTAssertEqual(retained.runtimeEnvironment()["TOKEN"], "value-1")

    let applied = try await runtime.reloadEnvironment(for: candidate, configuration: changed)
    XCTAssertEqual(applied.generation, 2)
    XCTAssertEqual(handle.updateGenerations, [2])
  }

  /// B6: a monitor restart during the loader window must not leave the live child
  /// on generation N while the store publishes N+1.
  @MainActor
  func testMonitorRestartDuringReloadDoesNotSplitGenerations() async throws {
    let root = try temporaryRoot()
    let runner = ReloadSafetyRunner(slowCalls: [2: 400_000_000])
    let factory = RecordingEnvironmentFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(
      eventSourceFactory: factory, monitorIntervalNanoseconds: 0, environmentStore: RuntimeEnvironmentSnapshotStore(runner: runner)
    )
    let candidate = try candidate(root: root)
    let configuration = configuration(root: root)
    try await startRunning(runtime, candidate, configuration, root: root)

    let reload = Task { @MainActor in try await runtime.reloadEnvironment(for: candidate, configuration: configuration) }
    var attempts = 0
    while await runner.count() < 2, attempts < 200 { attempts += 1; try await Task.sleep(nanoseconds: 5_000_000) }
    factory.handles.first?.markExited()
    await runtime.refresh(identity: candidate.id)
    XCTAssertEqual(factory.handles.count, 2, "monitor restarted the child")
    XCTAssertEqual(factory.requests.last?.configuration.runtimeEnvironmentGeneration, 1)

    do {
      _ = try await reload.value
      XCTFail("reload must not publish past a restarted child")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .instanceChanged) }
    let status = await runtime.environmentStatus(identity: candidate.id, profile: "default")
    XCTAssertEqual(status.generation, factory.requests.last?.configuration.runtimeEnvironmentGeneration)
    XCTAssertEqual(factory.handles.flatMap(\.updateGenerations), [])

    // A retry targets the new child.
    let retried = try await runtime.reloadEnvironment(for: candidate, configuration: configuration)
    XCTAssertEqual(retried.generation, 2)
    XCTAssertEqual(factory.handles.last?.updateGenerations, [2])
  }

  /// Store eviction (instance delete / profile switch) drops credentials and status.
  @MainActor
  func testEvictEnvironmentDropsSnapshotAndStatus() async throws {
    let root = try temporaryRoot()
    let runner = ReloadSafetyRunner()
    let runtime = RielaAppDaemonWorkflowRuntime(monitorIntervalNanoseconds: 0, environmentStore: RuntimeEnvironmentSnapshotStore(runner: runner))
    let candidate = try candidate(root: root)
    let configuration = configuration(root: root)
    _ = try await runtime.prepareEnvironment(for: candidate, configuration: configuration)
    XCTAssertEqual(runtime.cachedEnvironmentStatus(identity: candidate.id, profile: "default").readiness, .ready)
    await runtime.evictEnvironment(identity: candidate.id, profile: "default")
    XCTAssertEqual(runtime.cachedEnvironmentStatus(identity: candidate.id, profile: "default"), RuntimeEnvironmentStatus())
    let evicted = await runtime.environmentStatus(identity: candidate.id, profile: "default")
    XCTAssertEqual(evicted.readiness, .unprepared)
    let next = try await runtime.prepareEnvironment(for: candidate, configuration: configuration)
    XCTAssertEqual(next.generation, 2, "generations never repeat after eviction")
    XCTAssertEqual(next.runtimeEnvironment()["TOKEN"], "value-2")
    await runtime.evictEnvironment(profile: "default")
    XCTAssertEqual(runtime.cachedEnvironmentStatus(identity: candidate.id, profile: "default"), RuntimeEnvironmentStatus())
  }
}

/// Serving-layer contract (RielaServer) exercised from the App test target.
final class RuntimeEnvironmentServingControllerTests: XCTestCase {
  private struct Resolver: WorkflowServeResolving {
    func resolve(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeResolvedWorkflow {
      WorkflowServeResolvedWorkflow(workflowId: "fixture", selectedIdentity: request.selection.identifier)
    }
  }
  private struct Listener: WorkflowServeListenerHandle {
    var endpoint: String { "http://127.0.0.1:1" }
    func shutdown() async throws {}
  }
  private struct ListenerFactory: WorkflowServeListenerFactory {
    func startListener(for resolvedWorkflow: WorkflowServeResolvedWorkflow, request: WorkflowServeStartRequest,
                       generationId: String) async throws -> any WorkflowServeListenerHandle { Listener() }
  }
  private struct PlainHandle: WorkflowServeEventSourceHandle {
    var status: WorkflowServeEventSourceStatus { WorkflowServeEventSourceStatus(sourceId: "plain", status: "running", generationId: "g") }
    func shutdown() async throws {}
  }

  func testUpdateWithoutActiveGenerationThrowsTypedError() async throws {
    let controller = WorkflowServingController()
    do {
      try await controller.updateRuntimeEnvironment(generation: 2, names: ["TOKEN"], values: ["TOKEN": "x"])
      XCTFail("a stopped controller must not report success")
    } catch { XCTAssertEqual(error as? WorkflowServeRuntimeEnvironmentError, .noActiveGeneration) }
    do {
      try await PlainHandle().updateRuntimeEnvironment(generation: 2, names: [], values: [:])
      XCTFail("default handle has no channel")
    } catch {
      XCTAssertEqual(error as? WorkflowServeRuntimeEnvironmentError, .unsupported)
      XCTAssertEqual(RuntimeEnvironmentError(rawValue: (error as? WorkflowServeRuntimeEnvironmentError)?.rawValue ?? ""), .notPrepared)
    }
    XCTAssertEqual(RuntimeEnvironmentError(rawValue: WorkflowServeRuntimeEnvironmentError.noActiveGeneration.rawValue), .instanceChanged)
  }

  func testRestartAfterUpdateStartsFromTheInstalledSnapshot() async throws {
    let factory = RecordingEnvironmentFactory()
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: Resolver(), listenerFactory: ListenerFactory(), eventSourceFactory: factory
    ))
    var configuration = WorkflowServeRuntimeConfiguration(runtimeEnvironmentGeneration: 1, runtimeEnvironmentNames: ["TOKEN"])
    configuration.runtimeEnvironmentValues = ["TOKEN": "first"]
    _ = try await controller.start(WorkflowServeStartRequest(selection: .directDirectory("/fixture"), configuration: configuration))
    try await controller.updateRuntimeEnvironment(generation: 2, names: ["TOKEN"], values: ["TOKEN": "second", "OTHER": "dropped"])
    XCTAssertEqual(factory.handles.first?.updateGenerations, [2])
    _ = try await controller.restart()
    let restarted = try XCTUnwrap(factory.requests.last?.configuration)
    XCTAssertEqual(restarted.runtimeEnvironmentGeneration, 2)
    XCTAssertEqual(restarted.runtimeEnvironmentValues, ["TOKEN": "second"])
    _ = try await controller.stop()
  }
}
#endif
