import Foundation
import RielaCore
import RielaServer

public struct RielaAppInstanceControlService: Sendable {
  private let ports: any RielaAppInstanceControlPorts
  public init(ports: any RielaAppInstanceControlPorts) { self.ports = ports }

  public func handle(_ operation: RielaAppControlOperation, profile: String?) async -> RielaAppControlResult {
    switch operation {
    case .bootstrap:
      return encoded(await ports.bootstrap(), status: 200) ?? .error(status: 500, code: "invalid_response")
    case let .reload(identity, body):
      if let profile, profile != (await ports.profile()) { return reloadError(.init(code: .configurationConflict)) }
      guard body.count <= RielaAppControlLimits.reloadBodyMaxBytes,
            let input = try? RielaAppInstanceReloadRequest.decodeStrict(body) else {
        return reloadError(.init(code: .invalidReloadRequest))
      }
      return await ports.serialized {
        guard await !ports.isShuttingDown() else { return reloadError(.init(code: .instanceBusy)) }
        let result = await RielaAppInstanceReloadCoordinator(ports: ports.reloadPorts()).reload(identity: identity, request: input)
        switch result {
        case .success(let response):
          return encoded(response, status: 200) ?? reloadError(.init(code: .configurationIOFailure, committed: true))
        case .failure(let error): return reloadError(error)
        }
      }
    case let .cancel(identity, sessionId, body):
      if let profile, profile != (await ports.profile()) { return cancelError(.init(code: .configurationConflict)) }
      guard let input = try? RielaAppInstanceCancelRequest.decodeStrict(body) else {
        return cancelError(.init(code: .invalidCancelRequest))
      }
      return await ports.serialized {
        guard await !ports.isShuttingDown() else { return cancelError(.init(code: .instanceBusy)) }
        let coordinator = RielaAppInstanceCancelCoordinator(ports: ports.cancelPorts())
        let result = if let sessionId { await coordinator.cancel(identity: identity, sessionId: sessionId, request: input) } else { await coordinator.cancelSole(identity: identity, request: input) }
        switch result {
        case .success(let response): return encoded(response, status: 202) ?? cancelError(.init(code: .cancelUnavailable))
        case .failure(let error): return cancelError(error)
        }
      }
    case let .environmentStatus(identity):
      guard profile == (await ports.profile()), await ports.instanceExists(identity: identity) else {
        return .error(status: 409, code: "profile_or_instance_conflict", message: "Select the current profile and instance.")
      }
      return environmentResponse(await ports.environmentStatus(identity: identity))
    case let .environmentReload(identity, body):
      if let profile, profile != (await ports.profile()) {
        return .error(status: 409, code: "configuration_conflict", message: "Configuration changed. Refresh before continuing.")
      }
      guard let input = try? JSONDecoder().decode(WorkflowInstanceActionInput.self, from: body), input.action == .reloadEnvironment else {
        return .error(status: 400, code: "invalid_request", message: "Provide a valid configuration request, profile and revision.")
      }
      return await ports.serialized {
        guard await !ports.isShuttingDown() else {
          return .error(status: 409, code: "instance_busy", message: "The app is shutting down.")
        }
        if let conflict = await ports.validateRevision(expectedRevision: input.expectedRevision, expectedProfile: input.expectedProfile) {
          return .error(status: conflict.status, code: conflict.code, message: conflict.message)
        }
        guard await ports.instanceExists(identity: identity) else {
          return .error(status: 404, code: "instance_not_found", message: "Execution configuration was not found.")
        }
        switch await ports.reloadEnvironment(identity: identity) {
        case .notReady: return .error(status: 422, code: "instance_not_ready", message: "Configuration is not ready.")
        case .reloaded(let status): return environmentResponse(status)
        case .failed(let status): return environmentResponse(status, status: 422)
        }
      }
    case let .run(identity, body):
      guard body.count <= RielaAppControlLimits.runBodyMaxBytes, profile == (await ports.profile()),
            let object = try? JSONDecoder().decode(JSONObject.self, from: body),
            Set(object.keys).isSuperset(of: ["expectedProfile", "expectedRevision", "variables"]),
            Set(object.keys).isSubset(of: ["expectedProfile", "expectedRevision", "variables", "allowOverlap"]),
            object["allowOverlap"] == nil || object["allowOverlap"] == .bool(true) || object["allowOverlap"] == .bool(false),
            let input = try? JSONDecoder().decode(RunInput.self, from: body) else {
        return .error(status: 400, code: "invalid_configured_run")
      }
      let configured = RielaAppConfiguredRunInput(expectedProfile: input.expectedProfile, expectedRevision: input.expectedRevision,
                                                   variables: input.variables, allowOverlap: input.allowOverlap)
      return await ports.serialized { await ports.launchConfiguredRun(identity: identity, input: configured) }
    case let .launchStatus(launchId):
      return await ports.launchStatus(launchId: launchId, profile: profile ?? "")
    }
  }
}

private struct RunInput: Decodable {
  let expectedProfile: String
  let expectedRevision: Int
  let variables: JSONObject
  let allowOverlap: Bool?
}

private func encoded<T: Encodable>(_ value: T, status: Int) -> RielaAppControlResult? {
  guard let data = try? JSONEncoder().encode(value), let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
  return .init(status: status, body: body)
}

private func environmentResponse(_ value: RuntimeEnvironmentStatus, status: Int = 200) -> RielaAppControlResult {
  encoded(value, status: status) ?? .error(status: 500, code: "environment_status_unavailable", message: "Environment status unavailable.")
}

private func reloadError(_ error: RielaAppInstanceReloadError) -> RielaAppControlResult {
  var object: JSONObject = ["error": .object(["code": .string(error.code.rawValue),
    "message": .string(WorkflowWebProjectionPolicy().safeSummary(error.message))]), "committed": .bool(error.committed)]
  if let partial = error.partial { object["partial"] = .string(partial) }
  if let running = error.running { object["running"] = .number(Double(running)) }
  if let queued = error.queued { object["queued"] = .number(Double(queued)) }
  return .init(status: error.code.httpStatus, body: .object(object))
}

private func cancelError(_ error: RielaAppInstanceCancelError) -> RielaAppControlResult {
  var object: JSONObject = ["error": .object(["code": .string(error.code.rawValue),
    "message": .string(WorkflowWebProjectionPolicy().safeSummary(error.message))])]
  if let ids = error.sessionIds { object["sessionIds"] = .array(ids.map(JSONValue.string)) }
  if let pending = error.pendingRunCount { object["pendingRunCount"] = .number(Double(pending)) }
  return .init(status: error.code.httpStatus, body: .object(object))
}
