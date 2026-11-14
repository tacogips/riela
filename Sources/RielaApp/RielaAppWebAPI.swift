#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaCLI
import RielaServer

extension RielaApp {
  func webAPIResponse(for request: RielaHTTPRequest, csrfToken: String) async -> RielaHTTPResponse {
    if let response = await webInstanceResponse(for: request) { return response }
    if let response = await workerSettingsResponse(for: request) { return response }
    if let response = await webWorkflowHandler.response(for: request) { return response }
    return RielaWebAPIProjection(
      profile: daemonProfileName,
      state: daemonState,
      instances: daemonInstances,
      sources: daemonWorkflowSources,
      revision: webRevision,
      sessionStoreRoot: daemonSessionStoreRoot(profileName: daemonProfileName),
      serverSettings: webServerSettingsJSON()
    ).response(for: request, csrfToken: csrfToken)
  }

  /// The shared console read seam (design delta D8); `riela serve` builds the
  /// same provider from its own daemon state.
  func consoleGraphQLProvider() -> RielaConsoleGraphQLProvider {
    RielaConsoleGraphQLProvider(
      profile: daemonProfileName,
      state: daemonState,
      instances: daemonInstances,
      sources: daemonWorkflowSources,
      revision: webRevision,
      sessionStoreRoot: daemonSessionStoreRoot(profileName: daemonProfileName),
      runtimeSnapshot: { [self] identity in
        daemonRuntime.snapshot(for: profileRuntimeIdentity(profileName: daemonProfileName, localIdentity: identity))
      },
      environment: { [self] instance in
        daemonEnvironment(for: instance.candidate, preference: instance.preference)
      }
    )
  }

  var webWorkflowHandler: RielaWebWorkflowRequestHandler {
    var environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    environment["HOME"] = appHomeDirectory.path
    environment = distributedWorkflowEnvironment(environment)
    return webWorkflowRuntime.handler(context: RielaWebWorkflowContext(
      profile: daemonProfileName, assistant: daemonState.assistant, sources: daemonWorkflowSources,
      workingDirectory: appHomeDirectory, appRoot: profileStore.appRootURL,
      sessionStoreRoot: daemonSessionStoreRoot(profileName: daemonProfileName),
      principalId: RielaAppWebRegistryAuthorizer.principalId, environment: environment
    ))
  }

  private func webServerSettingsJSON() -> JSONObject {
    let settings = webServerController?.settings ?? RielaAppWebServerSettings()
    return [
      "revision": .number(Double(webRevision)),
      "isEnabled": .bool(settings.isEnabled),
      "configuredPort": .number(Double(settings.port)),
      "boundPort": webServerController?.state.boundPort.map { .number(Double($0)) } ?? .null,
      "restartRequired": .bool(webServerController?.restartRequired ?? false),
      "state": .string(webServerController?.state.label ?? "stopped")
    ]
  }

}
#endif
