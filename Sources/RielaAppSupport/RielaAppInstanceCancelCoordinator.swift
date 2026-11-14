import Foundation
import RielaServer

public struct RielaAppInstanceCancelCoordinator: Sendable {
  private let ports: any RielaAppInstanceCancelPorts
  private let makeRequestId: @Sendable () -> String

  public init(ports: any RielaAppInstanceCancelPorts, makeRequestId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
    self.ports = ports
    self.makeRequestId = makeRequestId
  }

  public func cancel(identity: String, sessionId: String, request: RielaAppInstanceCancelRequest) async -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError> {
    let profile = await ports.profile()
    guard request.expectedProfile == profile else { return failure(.configurationConflict) }
    guard await ports.instanceExists(identity: identity) else { return failure(.instanceNotFound) }
    let actor = RielaAppInstanceCancelActor.actor(profile: profile)
    let app = await ports.cancelAppLaunch(identity: identity, sessionId: sessionId, reason: request.reason, actor: actor)
    if app != .notFound { return success(identity, profile, sessionId, "app", app) }
    var channelError = false
    if await ports.childRunning(identity: identity) {
      do {
        let outcome = try await cancelChild(identity, sessionId, request.reason, actor)
        if outcome != .notFound { return success(identity, profile, sessionId, "eventServe", outcome) }
      } catch { channelError = true }
    }
    switch await ports.storedSessionState(identity: identity, sessionId: sessionId) {
    case .absent: return failure(.sessionNotFound)
    case .terminal: return failure(.notRunning)
    case .nonTerminal: return failure(channelError ? .cancelUnavailable : .sessionNotOwned)
    }
  }

  public func cancelSole(identity: String, request: RielaAppInstanceCancelRequest) async -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError> {
    let profile = await ports.profile()
    guard request.expectedProfile == profile else { return failure(.configurationConflict) }
    guard await ports.instanceExists(identity: identity) else { return failure(.instanceNotFound) }
    let app = await ports.appInventory(identity: identity)
    var child = RielaAppLiveSessionInventory(sessionIds: [], pendingRunCount: 0)
    if await ports.childRunning(identity: identity) {
      do {
        let ack = try await ports.childSessionControl(identity: identity, frame: .init(type: "session-list", requestId: makeRequestId()))
        guard let ids = ack.sessionIds, let pending = ack.pendingRunCount, pending >= 0 else { return failure(.cancelUnavailable) }
        child = .init(sessionIds: ids, pendingRunCount: pending)
      } catch { return failure(.cancelUnavailable) }
    }
    let ids = Set(app.sessionIds + child.sessionIds).sorted()
    let pending = app.pendingRunCount + child.pendingRunCount
    if ids.isEmpty && pending == 0 { return failure(.noRunningExecution) }
    if ids.count + pending > 1 {
      return .failure(.init(code: .ambiguousRunningSessions, sessionIds: ids, pendingRunCount: pending))
    }
    guard let sessionId = ids.first else { return failure(.sessionNotOwned) }
    let actor = RielaAppInstanceCancelActor.actor(profile: profile)
    if app.sessionIds.contains(sessionId) {
      let outcome = await ports.cancelAppLaunch(identity: identity, sessionId: sessionId, reason: request.reason, actor: actor)
      return outcome == .notFound ? failure(.notRunning) : success(identity, profile, sessionId, "app", outcome)
    }
    do {
      let outcome = try await cancelChild(identity, sessionId, request.reason, actor)
      return outcome == .notFound ? failure(.notRunning) : success(identity, profile, sessionId, "eventServe", outcome)
    } catch { return failure(.cancelUnavailable) }
  }

  private func cancelChild(_ identity: String, _ sessionId: String, _ reason: String, _ actor: String) async throws -> WorkflowServeSessionCancelOutcome {
    let frame = WorkflowServeSessionControlFrame(type: "session-cancel", requestId: makeRequestId(), sessionId: sessionId, reason: reason, actor: actor)
    let ack = try await ports.childSessionControl(identity: identity, frame: frame)
    guard let outcome = ack.outcome else { throw WorkflowServeSessionControlError.noAcknowledgement }
    return outcome
  }

  private func failure(_ code: RielaAppInstanceCancelCode) -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError> {
    .failure(.init(code: code))
  }

  private func success(_ identity: String, _ profile: String, _ sessionId: String, _ owner: String, _ outcome: WorkflowServeSessionCancelOutcome) -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError> {
    .success(.init(identity: identity, profile: profile, sessionId: sessionId, owner: owner, outcome: outcome.rawValue))
  }
}
