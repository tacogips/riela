import Foundation

public struct DistributedWorkerWorkspace: Sendable {
  public let root: URL
  public let controllerRoot: String?

  public init(root: URL, controllerRoot: String? = nil) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.controllerRoot = controllerRoot
  }

  func resolve(_ path: String?) throws -> String {
    var relative = path ?? "."
    if relative.hasPrefix("/") {
      guard let controllerRoot else { throw AdapterExecutionError(.invalidInput, "remote absolute path requires a controller workspace mapping") }
      let prefix = URL(fileURLWithPath: controllerRoot).standardizedFileURL.path
      guard relative == prefix || relative.hasPrefix(prefix + "/") else {
        throw AdapterExecutionError(.policyBlocked, "remote path is outside the configured workspace")
      }
      relative = String(relative.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    let resolved = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
      throw AdapterExecutionError(.policyBlocked, "remote path escapes the worker workspace")
    }
    return resolved.path
  }
}

/// Executes resolved invocations on the worker. No controller filesystem or
/// inherited controller credentials are needed; workspace mappings are local.
public struct DistributedWorkerNodeExecutor: Sendable {
  private let workspaces: [String: DistributedWorkerWorkspace]
  private let adapter: any NodeAdapter
  private let stdio: any WorkflowStdioNodeExecuting
  private let addons: (any WorkflowAddonResolving)?
  private let allowedAddons: Set<String>
  private let environment: [String: String]

  public init(
    workspaces: [String: DistributedWorkerWorkspace], adapter: any NodeAdapter,
    stdio: any WorkflowStdioNodeExecuting, addons: (any WorkflowAddonResolving)? = nil,
    allowedAddons: Set<String> = [], environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.workspaces = workspaces
    self.adapter = adapter
    self.stdio = stdio
    self.addons = addons
    self.allowedAddons = allowedAddons
    self.environment = environment
  }

  public func execute(_ job: DistributedJob, backendEventHandler: AdapterBackendEventHandler? = nil) async throws -> DistributedJobResult {
    let request = try JSONDecoder().decode(DistributedNodeRequest.self, from: JSONEncoder().encode(job.payload))
    guard let workspace = workspaces[request.workspace], request.timeoutSeconds.isFinite,
      request.timeoutSeconds > 0, request.timeoutSeconds <= 86400 else {
      throw AdapterExecutionError(.invalidInput, "unknown worker workspace or invalid timeout")
    }
    try DistributedArtifact.validatePaths(request.exports ?? [])
    await backendEventHandler?(AdapterBackendEvent(
      provider: "riela-worker", eventType: "remote.node_started", channel: .lifecycle,
      metadata: ["jobId": .string(job.id), "workspace": .string(request.workspace)]
    ))
    let output = try await withThrowingTaskGroup(of: DistributedNodeOutput.self) { group in
      group.addTask {
        try await execute(request.invocation, workspace: workspace, context: .init(
          deadline: Date().addingTimeInterval(request.timeoutSeconds), backendEventHandler: backendEventHandler
        ))
      }
      group.addTask {
        try await Task.sleep(for: .seconds(request.timeoutSeconds))
        throw AdapterExecutionError(.timeout, "worker execution deadline exceeded")
      }
      defer { group.cancelAll() }
      guard let output = try await group.next() else { throw CancellationError() }
      return output
    }
    let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(output))
    await backendEventHandler?(AdapterBackendEvent(provider: "riela-worker", eventType: "remote.node_completed", channel: .lifecycle))
    let artifacts = try DistributedArtifact.collect(paths: request.exports ?? [], root: workspace.root)
    return DistributedJobResult(outcome: .succeeded, payload: payload, artifacts: artifacts.isEmpty ? nil : artifacts)
  }

  private func execute(
    _ invocation: DistributedNodeInvocation, workspace: DistributedWorkerWorkspace, context: AdapterExecutionContext
  ) async throws -> DistributedNodeOutput {
    switch invocation {
    case var .adapter(input):
      input.node.workingDirectory = try workspace.resolve(input.node.workingDirectory)
      input.agentEnvironment = try resolveAgentEnvironment(input.node.agentEnvironment, variables: input.mergedVariables, runtimeEnvironment: environment)
      return .adapter(try await adapter.execute(input, context: context))
    case var .stdio(input):
      input.node.workingDirectory = try workspace.resolve(input.node.workingDirectory)
      if var command = input.node.command {
        command.workingDirectory = try command.workingDirectory.map(workspace.resolve) ?? input.node.workingDirectory
        input.node.command = command
      }
      if var container = input.node.container {
        container.workingDirectory = try container.workingDirectory.map(workspace.resolve) ?? input.node.workingDirectory
        input.node.container = container
      }
      // Memory belongs to the worker's mapped workspace, not the controller's
      // local memory directory. A later artifact channel synchronizes exports.
      input.memoryRootDirectory = input.availableMemories.isEmpty ? nil : workspace.root.appendingPathComponent(".riela/memory").path
      return .stdio(try await stdio.execute(input, context: context))
    case let .addon(input):
      guard let addons, allowedAddons.contains(input.addon.name),
        !["riela/git-commit", "riela/git-push", "riela/workflow-create-register-run"].contains(input.addon.name) else {
        throw AdapterExecutionError(.policyBlocked, "add-on is not authorized on this worker")
      }
      let output = try await addons.execute(input, context: context)
      guard output.runtimeFinalizationToken == nil else { throw AdapterExecutionError(.policyBlocked, "remote runtime finalization is not supported") }
      return .adapter(output)
    }
  }
}
