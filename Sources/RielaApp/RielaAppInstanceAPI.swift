#if os(macOS)
import Foundation
import RielaAppSupport
import RielaGraphQL
import RielaServer

extension RielaApp {
  func webInstanceResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    let creates = request.path == "/api/v1/instances" && request.method == "POST"
    let acts = parts.count == 5 && Array(parts.prefix(3)) == ["api", "v1", "instances"] && parts[4] == "actions"
    guard creates || acts else { return nil }
    guard request.method == "POST" else { return instanceAPIError("method_not_allowed", "Use POST.", status: 405) }
    return await distributedControllerOperations.run { [self] in
      guard !terminationShutdownStarted else {
        return instanceAPIError("instance_busy", "The app is shutting down.", status: 409)
      }
      do {
        if creates { return try createWebInstance(request) }
        guard let identity = parts[3].removingPercentEncoding else {
          return instanceAPIError("invalid_request", "Invalid configuration identity.", status: 400)
        }
        let input = try JSONDecoder().decode(WorkflowInstanceActionInput.self, from: request.body)
        return try await performWebInstanceAction(identity: identity, input: input)
      } catch let error as RielaConfigurationGraphQLError {
        let status = error.code == "SOURCE_NOT_FOUND" ? 404 : error.code == "INVALID_CONFIGURATION" ? 400 : 409
        return instanceAPIError(error.code.lowercased(), error.message, status: status)
      } catch is DecodingError {
        return instanceAPIError("invalid_request", "Provide a valid configuration request, profile and revision.", status: 400)
      } catch {
        return instanceAPIError("configuration_io_failure", "Could not save execution configuration.", status: 500)
      }
    }
  }

  private func createWebInstance(_ request: RielaHTTPRequest) throws -> RielaHTTPResponse {
    let input = try JSONDecoder().decode(WorkflowInstanceCreationInput.self, from: request.body)
    try validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
    let preference = try input.preference(sources: daemonWorkflowSources, existingIdentities: Set(daemonState.preferences.keys))
    var state = daemonState
    state.preferences[preference.identity] = preference
    try makeDaemonStore(profileName: daemonProfileName).save(state)
    daemonState = state
    webRevision += 1
    refreshDaemonWorkflowWindow()
    return .json(status: 201, .object([
      "profile": .string(daemonProfileName.rawValue), "revision": .number(Double(webRevision)),
      "identity": .string(preference.identity)
    ]))
  }

  private func performWebInstanceAction(
    identity: String, input: WorkflowInstanceActionInput
  ) async throws -> RielaHTTPResponse {
    try validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
    guard let instance = daemonInstances.first(where: { $0.identity == identity }) else {
      return instanceAPIError("instance_not_found", "Execution configuration was not found.", status: 404)
    }
    let selectedProfile = daemonProfileName
    let runtimeIdentity = profileRuntimeIdentity(profileName: selectedProfile, localIdentity: identity)
    if input.action.startsRuntime {
      guard await approvedDaemonWorkflowInstance(identity: runtimeIdentity) != nil else {
        return instanceAPIError("instance_not_ready", "Configuration is not ready. Check its runtime status.", status: 422)
      }
      try validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard !terminationShutdownStarted, daemonInstances.first(where: { $0.identity == identity }) == instance else {
        return instanceAPIError("configuration_conflict", "Configuration changed. Refresh before continuing.", status: 409)
      }
    }
    var preference = input.action.applying(to: instance.preference)
    preference.sourceIdentity = instance.sourceIdentity
    var state = daemonState
    state.preferences[identity] = preference
    try makeDaemonStore(profileName: selectedProfile).save(state)
    daemonState = state
    webRevision += 1
    let savedRevision = webRevision
    refreshDaemonWorkflowWindow()
    if input.action.stopsRuntime { await daemonRuntime.stop(identity: runtimeIdentity) }
    if input.action.startsRuntime {
      guard let approved = await approvedDaemonWorkflowInstance(identity: runtimeIdentity) else {
        return instanceAPIError("instance_not_ready", "Configuration is not ready. Check its runtime status.", status: 422)
      }
      try validateGraphQLConfigurationRevision(savedRevision, expectedProfile: selectedProfile.rawValue)
      guard !terminationShutdownStarted, approved.preference == preference else {
        return instanceAPIError("configuration_conflict", "Configuration changed. Refresh before continuing.", status: 409)
      }
      await daemonRuntime.start(
        approved.candidate,
        configuration: daemonRuntimeConfiguration(for: approved.candidate, preference: preference),
        server: daemonServerConfiguration(profileName: selectedProfile),
        sessionStoreRoot: daemonSessionStoreRoot(profileName: selectedProfile)
      )
      guard !terminationShutdownStarted, daemonProfileName == selectedProfile,
            daemonState.preferences[identity] == preference else {
        await daemonRuntime.stop(identity: runtimeIdentity)
        return instanceAPIError("configuration_conflict", "Configuration changed. Refresh before continuing.", status: 409)
      }
      if daemonRuntime.snapshot(for: runtimeIdentity).status == .failed {
        return instanceAPIError("instance_start_failed", "Configuration did not start. Check its runtime status.", status: 422)
      }
    }
    refreshDaemonWorkflowWindow()
    return .json(.object(["profile": .string(daemonProfileName.rawValue), "revision": .number(Double(webRevision))]))
  }

  private func instanceAPIError(_ code: String, _ message: String, status: Int) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string(code), "message": .string(message)])]))
  }
}
#endif
