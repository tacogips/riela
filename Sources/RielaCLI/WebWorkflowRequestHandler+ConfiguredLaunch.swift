import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaWorkflowRegistry

public extension RielaWebWorkflowRequestHandler {
  /// Host-selected configuration only. HTTP callers cannot supply paths or env.
  func launchConfiguredWorkflow(
    identity: String,
    source: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowInstanceConfiguration,
    variables: JSONObject,
    allowOverlap: Bool = false
  ) -> RielaHTTPResponse {
    runtime.launches = runtime.launches.filter { _, launch in
      launch.snapshot["status"] == .string("running") || Date().timeIntervalSince(launch.createdAt) < 3600
    }
    runtime.launchTasks = runtime.launchTasks.filter { runtime.launches[$0.key] != nil }
    if !allowOverlap {
      let running = runtime.launches.values.filter {
        guard $0.identity == identity, $0.snapshot["status"] == .string("running") else { return false }
        guard case let .string(sessionId) = $0.snapshot["sessionId"] else { return true }
        let root = canonicalRuntimeStoreRoot(sessionStoreRoot: context.sessionStoreRoot)
        let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
        guard FileManager.default.fileExists(atPath: databasePath),
              let status = try? SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
                .loadStrictReadOnly(sessionId: sessionId).session.status else { return true }
        return !status.isTerminal
      }.sorted { $0.createdAt < $1.createdAt }
      var blocker: String?
      if let launch = running.first {
        if case let .string(sessionId) = launch.snapshot["sessionId"] {
          blocker = sessionId
        } else {
          blocker = "pending"
        }
      } else if let sessions = try? LiveRootSessionProbe.liveRootSessions(
        workflowId: source.workflowId, sessionStoreRoot: context.sessionStoreRoot
      ) {
        blocker = sessions.first?.sessionId
      }
      if let blocker {
        return .json(status: 409, .object(["error": .object([
          "code": .string("instance_busy"), "runningSessionId": .string(blocker)
        ])]))
      }
    }
    guard runtime.launches.count < 40,
          runtime.launches.values.filter({ $0.snapshot["status"] == .string("running") }).count < 4 else {
      return .json(status: 429, .object(["error": .object(["code": .string("run_limit")])]))
    }
    do {
      let directory = configuration.normalizedWorkingDirectory ?? source.workingDirectory
      let resolution = WorkflowResolutionOptions(
        workflowName: source.workflowId,
        workflowDefinitionDir: source.workflowDirectory,
        workingDirectory: directory
      )
      let fileResolver = FileSystemWorkflowBundleResolver()
      let storeResolver = DefinitionStoreWorkflowBundleResolver(
        inner: fileResolver,
        sessionStore: context.sessionStoreRoot,
        actor: .init(kind: .api, id: "configured-run"),
        mode: .lookupOnly
      )
      let bundle: ResolvedWorkflowBundle
      if let stored = try storeResolver.lookup(resolution) {
        guard stored.workflow.workflowId == source.workflowId else {
          return .json(status: 409, .object(["error": .object(["code": .string("source_changed")])]))
        }
        bundle = stored
      } else {
        let fileBundle = try fileResolver.resolve(resolution)
        guard fileBundle.workflow.workflowId == source.workflowId,
              URL(fileURLWithPath: fileBundle.workflowDirectory).standardizedFileURL
                == URL(fileURLWithPath: source.workflowDirectory).standardizedFileURL else {
          return .json(status: 409, .object(["error": .object(["code": .string("source_changed")])]))
        }
        bundle = try storeResolver.seed(fileBundle: fileBundle, options: resolution)
      }
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
