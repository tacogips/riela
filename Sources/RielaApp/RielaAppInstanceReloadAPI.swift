#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaServer

extension RielaApp {
  nonisolated static func reloadStartRecord(candidate: RielaAppDaemonWorkflowCandidate, storeRoot: String) -> RielaAppInstanceStartRecord? {
    InstanceReloadSupport.startRecord(candidateDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
      storeRoot: storeRoot, workflowId: candidate.workflowId, workingDirectory: candidate.workingDirectory)
  }

  func webInstanceReloadResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "reload" else { return nil }
    guard request.method == "POST" else { return .json(status: 405, .object(["error": .object(["code": .string("method_not_allowed"), "message": .string("Use POST.")])])) }
    let identity = parts[3].removingPercentEncoding
    return await controlService.handle(.reload(identity: identity ?? "", body: identity == nil ? Data() : request.body),
      profile: request.headers["x-riela-profile"] ?? "").httpResponse
  }

}

@MainActor
struct RielaAppReloadPorts: RielaAppInstanceReloadPorts {
  let app: RielaApp
  let profileName: RielaAppProfileName

  func currentInstance(identity: String) async -> RielaAppInstanceReloadInstance? {
    guard let instance = app.daemonInstances.first(where: { $0.identity == identity }) else { return nil }
    return .init(identity: identity, workflowId: instance.source.workflowId, sourceId: instance.source.id,
                 workflowDirectory: instance.source.workflowDirectory, eventRoot: instance.source.eventRoot)
  }

  func validateRevision(expectedRevision: Int, expectedProfile: String) async throws {
    do { try app.validateGraphQLConfigurationRevision(expectedRevision, expectedProfile: expectedProfile) } catch { throw RielaAppInstanceReloadError(code: .configurationConflict) }
  }

  func discoverCandidate(instance: RielaAppInstanceReloadInstance, requestedDirectory: String?) async throws -> RielaAppInstanceReloadCandidate {
    let discovery = RielaAppDaemonWorkflowDiscovery(projectRoot: app.launchOptions.projectRoot)
    let source: RielaAppDaemonWorkflowCandidate?
    if let requestedDirectory {
      source = discovery.discoverSelectedWorkflowDirectory(requestedDirectory)
    } else if instance.sourceId.hasPrefix("selected-workflow:") {
      source = discovery.discoverSelectedWorkflowDirectory(instance.workflowDirectory)
    } else {
      source = app.daemonWorkflowSources(profileName: profileName, state: app.daemonState).first { $0.id == instance.sourceId }
    }
    guard let source else { throw RielaAppInstanceReloadError(code: .invalidWorkflowSource) }
    return .init(sourceId: source.id, workflowDirectory: source.workflowDirectory, eventRoot: source.eventRoot,
                 sourceChanged: requestedDirectory != nil && source.id != instance.sourceId)
  }

  func validate(candidate: RielaAppInstanceReloadCandidate, instance: RielaAppInstanceReloadInstance) async throws -> RielaAppInstanceReloadValidated {
    guard let current = app.daemonInstances.first(where: { $0.identity == instance.identity }) else {
      throw RielaAppInstanceReloadError(code: .instanceNotFound)
    }
    let source = sourceCandidate(candidate)
    guard let source else { throw RielaAppInstanceReloadError(code: .invalidWorkflowSource) }
    let result = try InstanceReloadSupport.validateCandidate(workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
      expectedWorkflowId: instance.workflowId, nodePatches: current.preference.configuration.nodePatches, workingDirectory: source.workingDirectory)
    return .init(workflowId: result.bundle.workflow.workflowId, triggerDefaultsFingerprint: result.triggerDefaultsFingerprint,
                 eventRootDigest: result.eventRootDigest)
  }

  private func sourceCandidate(_ candidate: RielaAppInstanceReloadCandidate) -> RielaAppDaemonWorkflowCandidate? {
    if candidate.sourceId.hasPrefix("selected-workflow:") {
      return RielaAppDaemonWorkflowDiscovery(projectRoot: app.launchOptions.projectRoot).discoverSelectedWorkflowDirectory(candidate.workflowDirectory)
    }
    return app.daemonWorkflowSources(profileName: profileName, state: app.daemonState).first { $0.id == candidate.sourceId }
  }

  private func runtimeIdentity(_ identity: String) -> String { app.profileRuntimeIdentity(profileName: profileName, localIdentity: identity) }
  func installedStartRecord(identity: String) async -> RielaAppInstanceStartRecord? { app.daemonRuntime.installedStartRecord(identity: runtimeIdentity(identity)) }
  func childRunning(identity: String) async -> Bool { app.daemonRuntime.isChildRunning(identity: runtimeIdentity(identity)) }
  func admission(identity: String, frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement {
    try await app.daemonRuntime.admissionControl(identity: runtimeIdentity(identity), frame: frame)
  }
  func importDefinition(candidate: RielaAppInstanceReloadCandidate, reason: String) async throws -> RielaAppInstanceReloadResponse.Definition {
    guard let source = sourceCandidate(candidate) else { throw RielaAppInstanceReloadError(code: .invalidWorkflowSource) }
    return try InstanceReloadSupport.importDefinition(storeRoot: app.daemonSessionStoreRoot(profileName: profileName),
      workflowDirectory: candidate.workflowDirectory, workflowId: source.workflowId, reason: reason, workingDirectory: source.workingDirectory)
  }
  func relink(identity: String, candidate: RielaAppInstanceReloadCandidate) async throws -> Int {
    var state = app.daemonState
    if !state.workflowDirectories.contains(candidate.workflowDirectory) { state.workflowDirectories.append(candidate.workflowDirectory) }
    var preference = state.preference(for: identity)
    preference.identity = identity
    preference.sourceIdentity = candidate.sourceId
    state.preferences[identity] = preference
    try app.makeDaemonStore(profileName: profileName).save(state)
    app.daemonState = state
    app.webRevision += 1
    return app.webRevision
  }
  func refreshCache() async { app.refreshDaemonWorkflowWindow() }
  func replaceChild(identity: String, interrupt: Bool) async throws -> String {
    guard let approved = await app.approvedDaemonWorkflowInstance(identity: runtimeIdentity(identity)) else {
      throw RielaAppInstanceReloadError(code: .instanceNotReady)
    }
    let snapshot = await app.daemonRuntime.replaceChild(approved.candidate,
      configuration: app.daemonRuntimeConfiguration(for: approved.candidate, preference: approved.preference),
      server: app.daemonServerConfiguration(profileName: profileName), sessionStoreRoot: app.daemonSessionStoreRoot(profileName: profileName))
    guard snapshot.status != .failed else { throw RielaAppInstanceReloadError(code: .instanceStartFailed) }
    return snapshot.status.rawValue
  }
  func profile() async -> String { profileName.rawValue }
  func revision() async -> Int { app.webRevision }
}
#endif
