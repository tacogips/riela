import Foundation
import RielaAppSupport
import RielaGraphQL
import RielaServer

extension ServeWebHost {
  func instanceCreationResponse(for request: RielaHTTPRequest) -> RielaHTTPResponse? {
    guard request.path == "/api/v1/instances", request.method == "POST" else { return nil }
    guard let input = try? JSONDecoder().decode(WorkflowInstanceCreationInput.self, from: request.body) else {
      return instanceError("invalid_request", "Provide a source, name, profile and revision.", status: 400)
    }
    do {
      try requireIdleInstanceOperation()
      try validateRevision(input.expectedRevision, profile: input.expectedProfile)
      let preference = try input.preference(sources: sources, existingIdentities: Set(state.preferences.keys))
      var updated = state
      updated.preferences[preference.identity] = preference
      try stateStore.save(updated)
      refreshConfigurationState()
      return .json(status: 201, .object([
        "profile": .string(profile.rawValue), "revision": .number(Double(revision)),
        "identity": .string(preference.identity)
      ]))
    } catch let error as RielaConfigurationGraphQLError {
      let status = error.code == "SOURCE_NOT_FOUND" ? 404 : error.code == "INVALID_CONFIGURATION" ? 400 : 409
      return instanceError(error.code.lowercased(), error.message, status: status)
    } catch {
      return instanceError("configuration_io_failure", "Could not save execution configuration.", status: 500)
    }
  }
}
