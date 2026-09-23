import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaWorkflowRegistry

public struct RielaWebWorkflowContext: Sendable {
  public var profile: RielaAppProfileName
  public var assistant: RielaAppAssistantSettings
  public var sources: [RielaAppDaemonWorkflowCandidate]
  public var workingDirectory: URL
  public var appRoot: URL
  public var sessionStoreRoot: String
  public var principalId: String
  public var environment: [String: String]

  public init(
    profile: RielaAppProfileName, assistant: RielaAppAssistantSettings,
    sources: [RielaAppDaemonWorkflowCandidate], workingDirectory: URL,
    appRoot: URL, sessionStoreRoot: String, principalId: String, environment: [String: String]
  ) {
    self.profile = profile
    self.assistant = assistant
    self.sources = sources
    self.workingDirectory = workingDirectory
    self.appRoot = appRoot
    self.sessionStoreRoot = sessionStoreRoot
    self.principalId = principalId
    self.environment = environment
  }
}

/// Owns asynchronous editor work for either a desktop or a browser host.
@MainActor
public final class RielaWebWorkflowRuntime {
  public let generations = WorkflowEditorGenerationStore()
  public internal(set) var launches: [String: WebWorkflowLaunch] = [:]
  var launchTasks: [String: Task<Void, Never>] = [:]

  public init() {}

  public func handler(context: RielaWebWorkflowContext) -> RielaWebWorkflowRequestHandler {
    RielaWebWorkflowRequestHandler(context: context, runtime: self)
  }

  public func shutdown() async {
    let tasks = Array(launchTasks.values)
    for task in tasks { task.cancel() }
    await generations.cancelAll()
    for task in tasks { await task.value }
    launchTasks.removeAll()
  }
}

/// The immutable request context cannot change during an asynchronous edit.
@MainActor
public struct RielaWebWorkflowRequestHandler {
  let context: RielaWebWorkflowContext
  let runtime: RielaWebWorkflowRuntime

  public func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    await CLIRuntimeEnvironment.$overrides.withValue(context.environment) {
      switch request.path {
      case "/api/v1/workflow-editor/node-settings":
        return await webWorkflowEditorNodeSettings(request: request)
      case "/api/v1/workflow-editor/definition":
        return await webWorkflowEditorDefinition(request: request)
      default: break
      }
      if request.path == "/api/v1/workflow-editor/launches" || request.path.hasPrefix("/api/v1/workflow-editor/launches/") {
        return webWorkflowEditorLaunch(request: request)
      }
      if request.path.hasPrefix("/api/v1/workflow-editor/runs/") {
        return webWorkflowEditorRunEvidence(request: request)
      }
      if request.path == "/api/v1/workflow-editor/generations" || request.path.hasPrefix("/api/v1/workflow-editor/generations/") {
        return await webWorkflowEditorGeneration(request: request)
      }
      let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
      if parts.count == 6, parts[0...3] == ["api", "v1", "workflows", "sources"],
         parts[5] == "editable-copy", request.method == "POST", let sourceId = parts[4].removingPercentEncoding {
        return await webWorkflowEditableCopy(sourceId: sourceId, request: request)
      }
      return nil
    }
  }
}
