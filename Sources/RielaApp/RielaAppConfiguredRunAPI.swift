#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaGraphQL
import RielaServer

private struct ConfiguredRunInput: Decodable {
  let expectedProfile: String
  let expectedRevision: Int
  let variables: JSONObject
}

extension RielaApp {
  func webConfiguredRunResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "runs" else { return nil }
    guard request.method == "POST", request.body.count <= 524_288,
          request.headers["x-riela-profile"] == daemonProfileName.rawValue,
          let identity = parts[3].removingPercentEncoding,
          let object = try? JSONDecoder().decode(JSONObject.self, from: request.body),
          Set(object.keys) == ["expectedProfile", "expectedRevision", "variables"],
          let input = try? JSONDecoder().decode(ConfiguredRunInput.self, from: request.body) else {
      return .json(status: 400, .object(["error": .object(["code": .string("invalid_configured_run")])]))
    }
    return await distributedControllerOperations.run { [self] in
      do {
        try validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
        guard !terminationShutdownStarted,
              let approved = await approvedDaemonWorkflowInstance(identity: profileRuntimeIdentity(profileName: daemonProfileName, localIdentity: identity)) else {
          return .json(status: 422, .object(["error": .object(["code": .string("instance_not_ready")])]))
        }
        try validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
        guard !terminationShutdownStarted, approved.profileName == daemonProfileName else {
          return .json(status: 409, .object(["error": .object(["code": .string("configuration_conflict")])]))
        }
        let runtimeConfiguration = daemonRuntimeConfiguration(for: approved.candidate, preference: approved.preference)
        let snapshot = try await daemonRuntime.prepareEnvironment(for: approved.candidate, configuration: runtimeConfiguration)
        let context = RielaWebWorkflowContext(
          profile: daemonProfileName, assistant: daemonState.assistant, sources: daemonWorkflowSources,
          workingDirectory: appHomeDirectory, appRoot: profileStore.appRootURL,
          sessionStoreRoot: daemonSessionStoreRoot(profileName: daemonProfileName),
          principalId: RielaAppWebRegistryAuthorizer.principalId,
          environment: snapshot.runtimeEnvironment()
        )
        return webWorkflowRuntime.handler(context: context).launchConfiguredWorkflow(
          identity: identity, source: approved.candidate, configuration: approved.preference.configuration, variables: input.variables
        )
      } catch let error as RuntimeEnvironmentError {
        return .json(status: 422, .object(["error": .object(["code": .string(error.rawValue)])]))
      } catch {
        return .json(status: 409, .object(["error": .object(["code": .string("configuration_conflict")])]))
      }
    }
  }
}
#endif
