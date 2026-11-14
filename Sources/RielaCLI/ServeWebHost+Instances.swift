import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer

extension ServeWebHost {
  func requireIdleInstanceOperation() throws {
    guard !instanceOperationInProgress, !isShuttingDown else {
      throw RielaConfigurationGraphQLError(code: "INSTANCE_BUSY", message: "An instance operation is in progress. Try again.")
    }
  }

  func instanceEnvironment(_ instance: WorkflowInstance) -> [String: String] {
    var values = RielaAppEnvironmentFileStore(
      environmentFileURL: instance.preference.environmentFilePath.map { URL(fileURLWithPath: $0) },
      processEnvironment: workflowEnvironment
    ).mergedEnvironment()
    values.merge(instance.preference.environmentVariables) { _, configured in configured }
    return values
  }

  /// `GET /api/v1/instances/{identity}/environment`: the same names-and-codes
  /// status the desktop host serves; never values.
  func instanceEnvironmentResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "environment" else { return nil }
    guard request.method == "GET" else { return instanceError("method_not_allowed", "Use GET.", status: 405) }
    guard request.headers["x-riela-profile"] == profile.rawValue,
          let identity = parts[3].removingPercentEncoding,
          instances.contains(where: { $0.identity == identity }) else {
      return instanceError("profile_or_instance_conflict", "Select the current profile and instance.", status: 409)
    }
    return environmentStatusResponse(await runtime.environmentStatus(identity: identity, profile: profile.rawValue))
  }

  func instanceActionResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "actions" else { return nil }
    guard request.method == "POST" else { return instanceError("method_not_allowed", "Use POST.", status: 405) }
    guard let identity = parts[3].removingPercentEncoding,
          let input = try? JSONDecoder().decode(WorkflowInstanceActionInput.self, from: request.body) else {
      return instanceError("invalid_request", "Provide an action, profile and revision.", status: 400)
    }
    do {
      try requireIdleInstanceOperation()
      try validateRevision(input.expectedRevision, profile: input.expectedProfile)
      guard let instance = instances.first(where: { $0.identity == identity }) else {
        return instanceError("instance_not_found", "Workflow instance was not found.", status: 404)
      }
      instanceOperationInProgress = true
      defer { instanceOperationInProgress = false }
      // Reload changes no saved preference; it runs the loaders through the
      // daemon runtime and answers with the resulting status.
      if input.action == .reloadEnvironment { return await reloadEnvironmentResponse(instance) }
      let selectedProfile = profile
      var preference = instance.preference
      preference.sourceIdentity = instance.sourceIdentity
      preference = input.action.applying(to: preference)
      var updated = state
      updated.preferences[identity] = preference
      try stateStore.save(updated)
      refreshConfigurationState()
      if input.action == .stop || input.action == .restart { await runtime.stop(identity: identity) }
      if input.action == .start || input.action == .restart {
        guard profile == selectedProfile, !isShuttingDown else {
          return instanceError("profile_conflict", "The profile changed. Refresh before continuing.", status: 409)
        }
        let configured = WorkflowInstance.configured(identity: identity, source: instance.source, preference: preference)
        await startInstance(configured)
        refreshConfigurationState()
        guard profile == selectedProfile, !isShuttingDown,
              instances.first(where: { $0.identity == identity }) == configured else {
          await runtime.stop(identity: identity)
          return instanceError("profile_conflict", "The profile changed. Refresh before continuing.", status: 409)
        }
        if runtime.snapshot(for: identity).status == .failed {
          return instanceError("instance_start_failed", "Instance did not start. Check its runtime status.", status: 422)
        }
      }
      return .json(.object(["profile": .string(profile.rawValue), "revision": .number(Double(revision))]))
    } catch let error as RielaConfigurationGraphQLError {
      return instanceError(error.code.lowercased(), error.message, status: 409)
    } catch {
      return instanceError("configuration_io_failure", "Could not save instance configuration.", status: 500)
    }
  }

  func startConfiguredInstances() async {
    await evictStaleProfileEnvironment()
    guard !instanceOperationInProgress, !isShuttingDown else { return }
    instanceOperationInProgress = true
    defer { instanceOperationInProgress = false }
    let selectedProfile = profile
    for instance in instances where instance.preference.available && instance.preference.active {
      guard profile == selectedProfile, !isShuttingDown else { break }
      await startInstance(instance)
    }
    if profile != selectedProfile || isShuttingDown { await runtime.stopAll() }
  }

  func restartRunningInstance(_ identity: String) async {
    guard runtime.snapshot(for: identity).status == .running,
          let instance = instances.first(where: { $0.identity == identity }) else { return }
    instanceOperationInProgress = true
    defer { instanceOperationInProgress = false }
    let selectedProfile = profile
    await runtime.stop(identity: identity)
    guard selectedProfile == profile, !isShuttingDown else { return }
    await startInstance(instance)
    if selectedProfile != profile || isShuttingDown { await runtime.stop(identity: identity) }
  }

  /// Credentials are scoped to the serve profile, so a profile switch never
  /// reuses another profile's in-memory snapshot for the same identity.
  func runtimeConfiguration(for instance: WorkflowInstance) -> WorkflowServeRuntimeConfiguration {
    var configuration = instance.preference.configuration.serveConfiguration(inheritedEnvironment: instanceEnvironment(instance))
    if configuration.workingDirectory == nil { configuration.workingDirectory = instance.candidate.workingDirectory }
    configuration.environmentProfile = profile.rawValue
    return configuration
  }

  /// Drops the previous profile's in-memory credentials and statuses once its
  /// instances are stopped (both profile-switch paths start configured instances).
  func evictStaleProfileEnvironment() async {
    guard environmentProfile != profile else { return }
    let previous = environmentProfile
    environmentProfile = profile
    await runtime.evictEnvironment(profile: previous.rawValue)
  }

  private func startInstance(_ instance: WorkflowInstance) async {
    await evictStaleProfileEnvironment()
    let root = sessionStoreRoot
    let configuration = runtimeConfiguration(for: instance)
    await CLIRuntimeEnvironment.$overrides.withValue(workflowEnvironment) {
      await runtime.start(instance.candidate, configuration: configuration, sessionStoreRoot: root)
    }
  }

  /// Mirrors the desktop host: run the loaders (installing into a live channel
  /// child first), start an active instance an earlier locked loader kept from
  /// starting, and answer with the status. Failures answer 422 with the safe
  /// code in `lastError`; the previous snapshot stays published.
  private func reloadEnvironmentResponse(_ instance: WorkflowInstance) async -> RielaHTTPResponse {
    let selectedProfile = profile
    let configuration = runtimeConfiguration(for: instance)
    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue(workflowEnvironment) {
        try await runtime.reloadEnvironment(for: instance.candidate, configuration: configuration)
      }
      if instance.preference.active, profile == selectedProfile, !isShuttingDown,
         runtime.snapshot(for: instance.identity).status != .running {
        await startInstance(instance)
      }
      return environmentStatusResponse(await runtime.environmentStatus(identity: instance.identity, profile: selectedProfile.rawValue))
    } catch {
      var status = await runtime.environmentStatus(identity: instance.identity, profile: selectedProfile.rawValue)
      status.lastError = error as? RuntimeEnvironmentError ?? .sourceFailed
      return environmentStatusResponse(status, status: 422)
    }
  }

  func environmentStatusResponse(_ value: RuntimeEnvironmentStatus, status: Int = 200) -> RielaHTTPResponse {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      return instanceError("environment_status_unavailable", "Environment status unavailable.", status: 500)
    }
    return .json(status: status, object)
  }

  func instanceError(_ code: String, _ message: String, status: Int) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string(code), "message": .string(message)])]))
  }
}
