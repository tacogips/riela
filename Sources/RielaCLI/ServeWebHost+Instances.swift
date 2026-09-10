import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer

extension ServeWebHost {
  enum InstanceAction: String, Decodable {
    case start, stop, restart, enableAtLaunch, disableAtLaunch
  }

  private struct InstanceActionInput: Decodable {
    let action: InstanceAction
    let expectedRevision: Int
    let expectedProfile: String
  }

  func requireIdleInstanceOperation() throws {
    guard !instanceOperationInProgress, !isShuttingDown else {
      throw RielaConfigurationGraphQLError(code: "INSTANCE_BUSY", message: "An instance operation is in progress. Try again.")
    }
  }

  func instanceEnvironment(_ instance: WorkflowInstance) -> [String: String] {
    var values = RielaAppEnvironmentFileStore(
      environmentFileURL: instance.preference.environmentFilePath.map { URL(fileURLWithPath: $0) },
      processEnvironment: environment
    ).mergedEnvironment()
    values.merge(instance.preference.environmentVariables) { _, configured in configured }
    return values
  }

  func instanceActionResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "actions" else { return nil }
    guard request.method == "POST" else { return instanceError("method_not_allowed", "Use POST.", status: 405) }
    guard let identity = parts[3].removingPercentEncoding,
          let input = try? JSONDecoder().decode(InstanceActionInput.self, from: request.body) else {
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
      let selectedProfile = profile
      var preference = instance.preference
      preference.sourceIdentity = instance.sourceIdentity
      switch input.action {
      case .start, .restart:
        preference.available = true
        preference.active = true
      case .stop: preference.active = false
      case .enableAtLaunch: preference.available = true
      case .disableAtLaunch: preference.available = false
      }
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

  private func startInstance(_ instance: WorkflowInstance) async {
    let root = sessionStoreRoot
    var configuration = instance.preference.configuration.serveConfiguration(inheritedEnvironment: instanceEnvironment(instance))
    if configuration.workingDirectory == nil { configuration.workingDirectory = instance.candidate.workingDirectory }
    await CLIRuntimeEnvironment.$overrides.withValue(environment) {
      await runtime.start(instance.candidate, configuration: configuration, sessionStoreRoot: root)
    }
  }

  private func instanceError(_ code: String, _ message: String, status: Int) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string(code), "message": .string(message)])]))
  }
}
