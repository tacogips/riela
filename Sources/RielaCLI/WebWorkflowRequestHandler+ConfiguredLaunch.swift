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
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      guard bundle.workflow.workflowId == source.workflowId,
            URL(fileURLWithPath: bundle.workflowDirectory).standardizedFileURL == URL(fileURLWithPath: source.workflowDirectory).standardizedFileURL else {
        return .json(status: 409, .object(["error": .object(["code": .string("source_changed")])]))
      }
      let input = variables
      let encoder = JSONEncoder()
      let options = WorkflowRunOptions(
        target: source.workflowId, resolution: resolution,
        variables: String(decoding: try encoder.encode(input), as: UTF8.self),
        output: .jsonl, sessionStore: context.sessionStoreRoot,
        workingDirectory: directory, explicitWorkingDirectory: true
      )
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
