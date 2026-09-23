import Foundation
import RielaCore
import RielaServer
import RielaWorkflowRegistry

public extension RielaWebWorkflowRequestHandler {
  func webWorkflowEditorLaunch(request: RielaHTTPRequest) -> RielaHTTPResponse {
    let profile = context.profile.rawValue
    guard request.headers["x-riela-profile"] == profile else {
      return launchError(409, "The active profile changed. Refresh before running.")
    }
    let parts = request.path.split(separator: "/")
    if parts.count == 5, request.method == "GET" {
      guard let job = runtime.launches[String(parts[4])], job.profile == profile else {
        return launchError(404, "This launch was not found.")
      }
      return .json(.object(job.snapshot))
    }
    guard parts.count == 4, request.method == "POST", request.body.count <= 524_288,
          let body = try? JSONDecoder().decode(JSONObject.self, from: request.body),
          case let .string(workflowId) = body["workflowId"],
          case let .string(originId) = body["originId"],
          case let .string(revision) = body["definitionRevision"],
          case let .string(directory) = body["workingDirectory"], directory.hasPrefix("/"),
          case let .object(variables) = body["variables"] else {
      return launchError(400, "Provide a saved workflow, input object and absolute working directory.")
    }
    runtime.launches = runtime.launches.filter { _, launch in
      launch.snapshot["status"] == .string("running") || Date().timeIntervalSince(launch.createdAt) < 3600
    }
    runtime.launchTasks = runtime.launchTasks.filter { runtime.launches[$0.key] != nil }
    guard runtime.launches.count < 40,
          runtime.launches.values.filter({ $0.snapshot["status"] == .string("running") }).count < 4 else {
      return launchError(429, "The editor run limit is reached. Wait for a running workflow to finish.")
    }
    do {
      let bundle = try WorkflowRegistryService().prepareEditorExecution(
        target: WorkflowRegistryTarget(workflowId: workflowId, scope: .user, originId: originId),
        expectedDefinitionRevision: revision, workingDirectory: context.workingDirectory.path,
        resolver: FileSystemWorkflowBundleResolver()
      )
      let inputData = try JSONEncoder().encode(variables)
      let options = WorkflowRunOptions(
        target: workflowId,
        resolution: WorkflowResolutionOptions(workflowName: workflowId, scope: .user, workingDirectory: context.workingDirectory.path),
        variables: String(data: inputData, encoding: .utf8),
        output: .jsonl,
        sessionStore: context.sessionStoreRoot,
        workingDirectory: directory,
        explicitWorkingDirectory: true
      )
      let job = WebWorkflowLaunch(profile: profile)
      runtime.launches[job.id] = job
      let environmentOverrides = CLIRuntimeEnvironment.overrides
      runtime.launchTasks[job.id] = Task.detached {
        await CLIRuntimeEnvironment.$overrides.withValue(environmentOverrides) {
          let result = await WorkflowRunCommand(resolver: EditorPreparedBundleResolver(bundle: bundle), jsonlRecordWriter: job.append).run(options)
          job.finish(result)
        }
      }
      return .json(status: 202, .object(job.snapshot))
    } catch let error as WorkflowRegistryError {
      return launchError(409, error.message)
    } catch {
      return launchError(422, "Workflow preflight failed. Check activation, validation and the working directory.")
    }
  }

  private func launchError(_ status: Int, _ message: String) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string("workflow_launch_failed"), "message": .string(message)])]))
  }
}
