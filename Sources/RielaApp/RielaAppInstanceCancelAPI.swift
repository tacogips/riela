#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaServer
import RielaViewer

extension RielaApp {
  func webInstanceCancelResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard Array(parts.prefix(3)) == ["api", "v1", "instances"] else { return nil }
    let explicit = parts.count == 7 && parts[4] == "executions" && parts[6] == "cancel"
    let sole = parts.count == 5 && parts[4] == "cancel"
    guard explicit || sole else { return nil }
    guard request.method == "POST" else {
      return .json(status: 405, .object(["error": .object(["code": .string("method_not_allowed"), "message": .string("Use POST.")])]))
    }
    let identity = parts[3].removingPercentEncoding
    let sessionId = explicit ? parts[5].removingPercentEncoding : nil
    let validPath = identity != nil && (!explicit || sessionId != nil)
    return await controlService.handle(.cancel(identity: identity ?? "", sessionId: sessionId,
      body: validPath ? request.body : Data()), profile: request.headers["x-riela-profile"] ?? "").httpResponse
  }

}

@MainActor
struct RielaAppCancelPorts: RielaAppInstanceCancelPorts {
  let app: RielaApp
  let profileName: RielaAppProfileName

  func profile() async -> String { profileName.rawValue }
  func instanceExists(identity: String) async -> Bool { app.daemonInstances.contains { $0.identity == identity } }
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome {
    app.webWorkflowRuntime.cancelLaunch(identity: identity, sessionId: sessionId, reason: reason, actor: actor)
  }
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory {
    let inventory = app.webWorkflowRuntime.liveLaunchInventory(identity: identity)
    return .init(sessionIds: inventory.sessionIds, pendingRunCount: inventory.pendingRunCount)
  }
  private func runtimeIdentity(_ identity: String) -> String {
    app.profileRuntimeIdentity(profileName: profileName, localIdentity: identity)
  }
  func childRunning(identity: String) async -> Bool { app.daemonRuntime.isChildRunning(identity: runtimeIdentity(identity)) }
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement {
    try await app.daemonRuntime.sessionControl(identity: runtimeIdentity(identity), frame: frame)
  }
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState {
    guard let instance = app.daemonInstances.first(where: { $0.identity == identity }),
          let state = try? WorkflowViewerLoader().loadBounded(
            WorkflowViewerLoadRequest(workflowDirectory: instance.source.workflowDirectory,
              sessionStoreRoot: app.daemonSessionStoreRoot(profileName: profileName), selectedSessionId: sessionId),
            maximumSessionCount: 1),
          state.selectedSessionId == sessionId,
          let summary = state.sessions.first(where: { $0.sessionId == sessionId }) else { return .absent }
    switch summary.status {
    case .completed, .failed, .cancelled: return .terminal
    case .created, .running, .suspended: return .nonTerminal
    }
  }
}
#endif
