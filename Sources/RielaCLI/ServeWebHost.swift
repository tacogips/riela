import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer
import RielaWorkflowRegistry

/// Hosts the shared web projections without creating an AppKit application.
@MainActor
final class ServeWebHost: RielaHTTPRouteHandling {
  let homeDirectory: URL
  let workingDirectory: URL
  let sessionStoreOverride: String?
  var profile: RielaAppProfileName
  var runtimeProfile: RielaAppProfileName
  var state: RielaAppDaemonWorkflowState
  var sources: [RielaAppDaemonWorkflowCandidate]
  var instances: [WorkflowInstance]
  let webWorkflowRuntime = RielaWebWorkflowRuntime()
  let runtime = RielaAppDaemonWorkflowRuntime()
  let fallback: any RielaHTTPRouteHandling
  let host: String
  var port: Int
  let environment: [String: String]
  let browserAccess: ServeWebAccess
  var observedAppearance = RielaAppAppearanceSettings()
  var observedProfiles: [RielaAppProfileName] = []
  var revision = 1
  var configuredPort: Int
  var instanceOperationInProgress = false
  var isShuttingDown = false
  let csrfToken = UUID().uuidString + UUID().uuidString

  init(
    homeDirectory: URL,
    workingDirectory: URL,
    sessionStoreRoot: String?,
    host: String,
    port: Int,
    fallback: any RielaHTTPRouteHandling,
    environment: [String: String]
  ) {
    self.homeDirectory = homeDirectory
    self.workingDirectory = workingDirectory
    self.host = host
    self.port = port
    configuredPort = port
    self.fallback = fallback
    self.environment = environment
    browserAccess = ServeWebAccess(host: host, environment: environment)
    let appRoot = RielaAppProfileStore.defaultAppRootURL(homeDirectory: homeDirectory)
    let profile = RielaAppProfileStore(appRootURL: appRoot).loadActiveProfileName()
    self.profile = profile
    runtimeProfile = profile
    sessionStoreOverride = sessionStoreRoot
    let state = RielaAppDaemonWorkflowStore(profileName: profile, homeDirectory: homeDirectory).load()
    self.state = state
    let sources = RielaAppDaemonWorkflowDiscovery(homeDirectory: homeDirectory, projectRoot: workingDirectory)
      .discoverUserDaemonWorkflows(
        appWorkflowRoot: RielaAppProfileStore.workflowRootURL(appRootURL: appRoot, profileName: profile),
        appPackageRoot: RielaAppProfileStore.packageRootURL(appRootURL: appRoot, profileName: profile),
        projectDirectories: state.projectDirectories,
        additionalWorkflowDirectories: state.workflowDirectories
      )
    self.sources = sources
    instances = state.workflowInstances(from: sources)
  }

  func shutdown() async {
    isShuttingDown = true
    await webWorkflowRuntime.shutdown()
    await runtime.stopAll()
  }

  func updateBoundPort(_ port: Int) {
    self.port = port
  }

  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    var response = await routedResponse(for: request)
    if request.path.hasPrefix("/api/v1/") || request.path == "/graphql" {
      response.headers["Cache-Control"] = "no-store"
    }
    return response
  }

  private func routedResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.path.hasPrefix("/api/v1/") || request.path == "/graphql" else {
      return await fallback.response(for: request)
    }
    if request.path == "/graphql", request.headers["origin"] == nil,
       request.headers["x-riela-csrf"] == nil, request.headers["x-riela-profile"] == nil {
      // CLI/manager clients retain their existing authenticated GraphQL route.
      return await fallback.response(for: request)
    }
    let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    if let rejection = browserAccess.rejection(for: request, localAuthority: authority, csrfToken: csrfToken) {
      return rejection
    }
    refreshConfigurationState()
    if runtimeProfile != profile {
      guard !instanceOperationInProgress else {
        return .json(status: 409, .object(["error": .object([
          "code": .string("profile_conflict"), "message": .string("The profile changed during an instance operation. Retry shortly.")
        ])]))
      }
      instanceOperationInProgress = true
      await runtime.stopAll()
      runtimeProfile = profile
      instanceOperationInProgress = false
      await startConfiguredInstances()
    }
    if let response = await instanceActionResponse(for: request) { return response }
    if request.path == "/graphql" {
      guard request.headers["x-riela-profile"] == profile.rawValue else {
        return .json(status: 409, .object(["error": .string("profile_conflict")]))
      }
      let executor = ServeWebRegistryExecutor(workingDirectory: workingDirectory.path, configurationProvider: self)
      return await CLIRuntimeEnvironment.$overrides.withValue(environment) {
        await DeterministicServerHTTPAdapter(
          routeHandler: DeterministicServerRouteHandler(graphQLExecutor: executor),
          context: ServerRequestContext(serviceName: "riela-serve")
        ).response(for: request)
      }
    }
    let editor = webWorkflowRuntime.handler(context: RielaWebWorkflowContext(
      profile: profile, assistant: state.assistant, sources: sources,
      workingDirectory: workingDirectory, appRoot: profileStore.appRootURL,
      sessionStoreRoot: sessionStoreRoot, principalId: "riela-serve-local-web", environment: environment
    ))
    if let response = await editor.response(for: request) { return response }
    return RielaWebAPIProjection(
      profile: profile,
      state: state,
      instances: instances,
      sources: sources,
      revision: revision,
      sessionStoreRoot: sessionStoreRoot,
      serverSettings: [
        "revision": .number(Double(revision)), "isEnabled": .bool(true),
        "configuredPort": .number(Double(configuredPort)), "boundPort": .number(Double(port)),
        "restartRequired": .bool(configuredPort != port), "state": .string("running")
      ],
      runtimeSnapshot: { [self] identity in runtime.snapshot(for: identity) },
      environment: { [self] instance in
        var values = RielaAppEnvironmentFileStore(
          environmentFileURL: instance.preference.environmentFilePath.map { URL(fileURLWithPath: $0) },
          processEnvironment: environment
        ).mergedEnvironment()
        values.merge(instance.preference.environmentVariables) { _, configured in configured }
        return values
      },
      hostKind: .server
    ).response(for: request, csrfToken: csrfToken)
  }
}

private struct ServeWebRegistryExecutor: GraphQLDocumentExecuting {
  let workingDirectory: String
  let configurationProvider: any RielaConfigurationGraphQLProviding

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var trusted = request
    trusted.isLocallyTrusted = true
    trusted.localWorkingDirectory = workingDirectory
    return await CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(
      localProvider: FileWorkflowRegistryGraphQLProvider(
        workingDirectory: workingDirectory, webPrincipalId: "riela-serve-local-web"
      ),
      localManagedReferenceResolver: ServeWebManagedReferenceResolver()
      ),
      fallback: RielaConfigGraphQLDocumentExecutor(provider: configurationProvider)
    ).execute(trusted)
  }
}

private struct ServeWebManagedReferenceResolver: WorkflowRegistryManagedReferenceResolver {
  func resolveManagedReference(_ reference: String) async throws -> URL {
    throw WorkflowRegistryError(
      code: .unsupportedBundleReference, message: "managed bundle references are unavailable from the web"
    )
  }
}
