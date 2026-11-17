import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaWorkflowRegistry

public extension RielaWebWorkflowRequestHandler {
  /// Host-selected configuration only. HTTP callers cannot supply paths or env.
  ///
  /// Every session-store filesystem/SQLite access (overlap probe, definition
  /// store lookup/seed) runs off the caller's actor through
  /// `BoundedSessionStoreIO`, so an `open(2)` blocked on an unavailable or
  /// permission-gated volume cannot freeze the App main thread. A probe that
  /// exceeds its deadline yields `session_store_unavailable` instead.
  func launchConfiguredWorkflow(
    identity: String,
    source: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowInstanceConfiguration,
    variables: JSONObject,
    allowOverlap: Bool = false,
    storeTimeout: TimeInterval = BoundedSessionStoreIO.defaultTimeout
  ) async -> RielaHTTPResponse {
    runtime.launches = runtime.launches.filter { _, launch in
      launch.snapshot["status"] == .string("running") || Date().timeIntervalSince(launch.createdAt) < 3600
    }
    runtime.launchTasks = runtime.launchTasks.filter { runtime.launches[$0.key] != nil }
    if !allowOverlap, runtime.configuredLaunchPreflights[identity, default: 0] > 0 {
      return instanceBusyResponse(runningSessionId: "pending")
    }
    guard runLimitAvailable else {
      return .json(status: 429, .object(["error": .object(["code": .string("run_limit")])]))
    }
    let runningLaunches: [(createdAt: Date, sessionId: String?)] = allowOverlap ? [] : runtime.launches.values
      .filter { $0.identity == identity && $0.snapshot["status"] == .string("running") }
      .map { launch in
        if case let .string(sessionId) = launch.snapshot["sessionId"] { return (launch.createdAt, sessionId) }
        return (launch.createdAt, nil)
      }
      .sorted { $0.createdAt < $1.createdAt }
    let sessionStoreRoot = context.sessionStoreRoot
    let directory = configuration.normalizedWorkingDirectory ?? source.workingDirectory
    let resolution = WorkflowResolutionOptions(
      workflowName: source.workflowId,
      workflowDefinitionDir: source.workflowDirectory,
      workingDirectory: directory
    )
    let checkOverlap = !allowOverlap
    let knownLaunchIds = Set(runtime.launches.keys)
    runtime.configuredLaunchPreflights[identity, default: 0] += 1
    let outcome = await BoundedSessionStoreIO.run(
      key: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot), timeout: storeTimeout
    ) { () throws -> ConfiguredLaunchPreflight in
      if checkOverlap, let blocker = try configuredLaunchOverlapBlocker(
        runningLaunches: runningLaunches, workflowId: source.workflowId, sessionStoreRoot: sessionStoreRoot
      ) {
        return .busy(blocker)
      }
      return try resolveConfiguredLaunchBundle(source: source, resolution: resolution, sessionStoreRoot: sessionStoreRoot)
    }
    runtime.configuredLaunchPreflights[identity, default: 1] -= 1
    if runtime.configuredLaunchPreflights[identity] == 0 { runtime.configuredLaunchPreflights[identity] = nil }
    let bundle: ResolvedWorkflowBundle
    switch outcome {
    case .timedOut, .storeBusy:
      return .json(status: 503, .object(["error": .object([
        "code": .string("session_store_unavailable"),
        "message": .string("The session store did not respond within \(Int(storeTimeout)) seconds. " +
          "Check that its volume is mounted, writable, and that removable-volume access is granted; " +
          "no workflow was launched.")
      ])]))
    case let .completed(.failure(error)):
      if error is ConfiguredLaunchSourceChanged {
        return .json(status: 409, .object(["error": .object(["code": .string("source_changed")])]))
      }
      return .json(status: 422, .object(["error": .object(["code": .string("run_preflight_failed")])]))
    case let .completed(.success(.busy(blocker))):
      return instanceBusyResponse(runningSessionId: blocker)
    case let .completed(.success(.ready(resolved))):
      bundle = resolved
    }
    // Launches started (with allowOverlap) while the store work was in flight.
    if !allowOverlap, let launch = runtime.launches.values
      .filter({ !knownLaunchIds.contains($0.id) && $0.identity == identity && $0.snapshot["status"] == .string("running") })
      .min(by: { $0.createdAt < $1.createdAt }) {
      if case let .string(sessionId) = launch.snapshot["sessionId"] {
        return instanceBusyResponse(runningSessionId: sessionId)
      }
      return instanceBusyResponse(runningSessionId: "pending")
    }
    guard runLimitAvailable else {
      return .json(status: 429, .object(["error": .object(["code": .string("run_limit")])]))
    }
    do {
      let input = variables
      let encoder = JSONEncoder()
      guard let encodedVariables = String(data: try encoder.encode(input), encoding: .utf8) else {
        throw CLIUsageError("configured workflow variables must be UTF-8")
      }
      var options = WorkflowRunOptions(
        target: source.workflowId, resolution: resolution,
        variables: encodedVariables,
        output: .jsonl, sessionStore: context.sessionStoreRoot,
        workingDirectory: directory, explicitWorkingDirectory: true
      )
      options.executionMode = .service(.init(kind: .api, id: "configured-run"))
      let job = WebWorkflowLaunch(profile: context.profile.rawValue, identity: identity)
      runtime.launches[job.id] = job
      var environment = context.environment
      environment["RIELA_API_KEY"] = ""
      let registry = runtime.registry(for: identity)
      let cancellation = OperatorCancellation()
      let handleBox = ConfiguredLaunchTaskHandleBox()
      job.onFirstSessionId = { sessionId in
        registry.register(sessionId: sessionId, cancellation: cancellation) { handleBox.cancel() }
      }
      registry.beginRun()
      let task = Task.detached {
        await CLIRuntimeEnvironment.$overrides.withValue(nil) {
          await CLIRuntimeEnvironment.$captured.withValue(environment) {
          var command = WorkflowRunCommand(resolver: EditorPreparedBundleResolver(bundle: bundle), jsonlRecordWriter: job.append)
          command.operatorCancellationReason = { cancellation.failureReason }
          command.configuredInstanceOverride = WorkflowInstanceDefinition(identity: identity, workflowId: source.workflowId,
            sourceIdentity: source.id, configuration: configuration)
          let result = await command.run(options)
          job.finish(result)
          if case let .string(sessionId) = job.snapshot["sessionId"] { registry.unregister(sessionId: sessionId) }
          registry.endRun()
          }
        }
      }
      handleBox.store(task)
      runtime.launchTasks[job.id] = task
      return .json(status: 202, .object(job.snapshot))
    } catch {
      return .json(status: 422, .object(["error": .object(["code": .string("run_preflight_failed")])]))
    }
  }
}

private extension RielaWebWorkflowRequestHandler {
  var runLimitAvailable: Bool {
    runtime.launches.count < 40 &&
      runtime.launches.values.filter { $0.snapshot["status"] == .string("running") }.count < 4
  }

  func instanceBusyResponse(runningSessionId: String) -> RielaHTTPResponse {
    .json(status: 409, .object(["error": .object([
      "code": .string("instance_busy"), "runningSessionId": .string(runningSessionId)
    ])]))
  }
}

private enum ConfiguredLaunchPreflight: Sendable {
  case busy(String)
  case ready(ResolvedWorkflowBundle)
}

private struct ConfiguredLaunchSourceChanged: Error {}

/// Blocking: opens the session store. Call only through `BoundedSessionStoreIO`.
private func configuredLaunchOverlapBlocker(
  runningLaunches: [(createdAt: Date, sessionId: String?)],
  workflowId: String,
  sessionStoreRoot: String
) throws -> String? {
  let root = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
  let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
  for launch in runningLaunches {
    guard let sessionId = launch.sessionId else { return "pending" }
    guard FileManager.default.fileExists(atPath: databasePath),
          let status = try? SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
            .loadStrictReadOnly(sessionId: sessionId).session.status else { return sessionId }
    if !status.isTerminal { return sessionId }
  }
  if let sessions = try? LiveRootSessionProbe.liveRootSessions(workflowId: workflowId, sessionStoreRoot: sessionStoreRoot) {
    return sessions.first?.sessionId
  }
  return nil
}

/// Blocking: reads/seeds the definition store. Call only through `BoundedSessionStoreIO`.
private func resolveConfiguredLaunchBundle(
  source: RielaAppDaemonWorkflowCandidate,
  resolution: WorkflowResolutionOptions,
  sessionStoreRoot: String
) throws -> ConfiguredLaunchPreflight {
  let fileResolver = FileSystemWorkflowBundleResolver()
  let storeResolver = DefinitionStoreWorkflowBundleResolver(
    inner: fileResolver,
    sessionStore: sessionStoreRoot,
    actor: .init(kind: .api, id: "configured-run"),
    mode: .lookupOnly
  )
  if let stored = try storeResolver.lookup(resolution) {
    guard stored.workflow.workflowId == source.workflowId else { throw ConfiguredLaunchSourceChanged() }
    return .ready(stored)
  }
  let fileBundle = try fileResolver.resolve(resolution)
  guard fileBundle.workflow.workflowId == source.workflowId,
        URL(fileURLWithPath: fileBundle.workflowDirectory).standardizedFileURL
          == URL(fileURLWithPath: source.workflowDirectory).standardizedFileURL else {
    throw ConfiguredLaunchSourceChanged()
  }
  return .ready(try storeResolver.seed(fileBundle: fileBundle, options: resolution))
}

private final class ConfiguredLaunchTaskHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancelled = false

  func store(_ task: Task<Void, Never>) {
    lock.lock()
    self.task = task
    let shouldCancel = cancelled
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}
