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
    variables: JSONObject
  ) -> RielaHTTPResponse {
    runtime.launches = runtime.launches.filter { _, launch in
      launch.snapshot["status"] == .string("running") || Date().timeIntervalSince(launch.createdAt) < 3600
    }
    runtime.launchTasks = runtime.launchTasks.filter { runtime.launches[$0.key] != nil }
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
        mode: .lookupOrSeed
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
      let job = WebWorkflowLaunch(profile: context.profile.rawValue)
      runtime.launches[job.id] = job
      var environment = context.environment
      environment["RIELA_API_KEY"] = ""
      runtime.launchTasks[job.id] = Task.detached {
        await CLIRuntimeEnvironment.$overrides.withValue(nil) {
          await CLIRuntimeEnvironment.$captured.withValue(environment) {
          var command = WorkflowRunCommand(resolver: EditorPreparedBundleResolver(bundle: bundle), jsonlRecordWriter: job.append)
          command.configuredInstanceOverride = WorkflowInstanceDefinition(identity: identity, workflowId: source.workflowId,
            sourceIdentity: source.id, configuration: configuration)
          let result = await command.run(options)
          job.finish(result)
          }
        }
      }
      return .json(status: 202, .object(job.snapshot))
    } catch {
      return .json(status: 422, .object(["error": .object(["code": .string("run_preflight_failed")])]))
    }
  }
}
