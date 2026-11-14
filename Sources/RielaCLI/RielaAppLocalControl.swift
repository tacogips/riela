import Foundation
import RielaAppSupport
import RielaCore
import RielaServer

protocol RielaAppInstanceControlClient: Sendable {
  var profile: String { get }
  func bootstrapRevision() async throws -> Int
  func reload(identity: String, body: [String: Any]) async throws -> Data
  func cancel(identity: String, sessionId: String?, body: [String: Any]) async throws -> Data
  func run(identity: String, body: [String: Any]) async throws -> Data
  func launchStatus(launchId: String) async throws -> Data
  func executions(identity: String) async throws -> Data
  func executionDetail(identity: String, sessionId: String) async throws -> Data
}

final class RielaAppHTTPInstanceControlClient: RielaAppInstanceControlClient, @unchecked Sendable {
  let profile: String
  private let client: RielaAppAPIClient
  private var bootstrap: RielaAppAPIClient.Bootstrap?
  private let bootstrapLock = NSLock()

  init(client: RielaAppAPIClient) { self.client = client; profile = client.profile }
  func bootstrapRevision() async throws -> Int {
    let value = try await client.bootstrap()
    bootstrapLock.withLock { bootstrap = value }
    return value.revision
  }
  private func path(_ identity: String) -> String {
    "/api/v1/instances" + "/" + (identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
  }
  private func post(_ path: String, body: [String: Any]) async throws -> Data {
    guard let bootstrap = bootstrapLock.withLock({ bootstrap }) else {
      throw RielaAppAPIFailure(code: "app_request_failed", status: 0, body: Data())
    }
    return try await client.post(path, body: body, bootstrap: bootstrap)
  }
  func reload(identity: String, body: [String: Any]) async throws -> Data {
    try await post(path(identity) + "/reload", body: body)
  }
  func cancel(identity: String, sessionId: String?, body: [String: Any]) async throws -> Data {
    let suffix = sessionId.map { "/executions/" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? ""
    return try await post(path(identity) + suffix + "/cancel", body: body)
  }
  func run(identity: String, body: [String: Any]) async throws -> Data { try await post(path(identity) + "/runs", body: body) }
  func launchStatus(launchId: String) async throws -> Data {
    try await client.get("/api/v1/workflow-editor/launches/" + (launchId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
  }
  func executions(identity: String) async throws -> Data {
    _ = try await client.bootstrap()
    return try await client.get(path(identity) + "/executions")
  }
  func executionDetail(identity: String, sessionId: String) async throws -> Data {
    try await client.get(path(identity) + "/executions/" + (sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
  }
}

#if os(macOS)
struct RielaAppLocalInstanceControlClient: RielaAppInstanceControlClient {
  let appRoot: URL
  let homeDirectory: URL
  let profile: String
  var probe: @Sendable (URL) throws -> RielaAppLocalControlProbe.Outcome = { try RielaAppLocalControlProbe.resolve(appRoot: $0) }
  var deadline: @Sendable () -> Date = { Date().addingTimeInterval(Double(RielaAppControlLimits.localReloadCapSeconds)) }

  private func resolve() throws -> RielaAppLocalControlProbe.Outcome {
    do { return try probe(appRoot) } catch let RielaAppControlChannelError.code(code) { throw RielaAppAPIFailure(code: code.rawValue, status: 0, body: Data()) }
  }
  private func result(_ value: RielaAppControlResult) throws -> Data {
    let data = try JSONEncoder().encode(value.body)
    guard (200..<300).contains(value.status) else { throw RielaAppAPIClient.failure(status: value.status, body: data) }
    return data
  }
  private func live(_ operation: RielaAppControlOperation) async throws -> Data {
    switch try resolve() {
    case .notRunning(let lock):
      defer { lock.release() }
      throw RielaAppAPIFailure(code: "app_not_running", status: 0, body: Data())
    case .channel(let client):
      do { return try result(await client.send(operation, profile: profile)) } catch let RielaAppControlChannelError.code(code) { throw RielaAppAPIFailure(code: code.rawValue, status: 0, body: Data()) }
    }
  }
  func bootstrapRevision() async throws -> Int {
    switch try resolve() {
    case .notRunning(let lock): lock.release(); return 0
    case .channel(let client):
      do {
        let data = try result(await client.send(.bootstrap, profile: profile))
        let bootstrap = try JSONDecoder().decode(RielaAppControlBootstrap.self, from: data)
        guard bootstrap.profile == profile else { throw RielaAppAPIFailure(code: "app_profile_conflict", status: 0, body: Data()) }
        return bootstrap.revision
      } catch let RielaAppControlChannelError.code(code) { throw RielaAppAPIFailure(code: code.rawValue, status: 0, body: Data()) }
    }
  }
  func reload(identity: String, body: [String: Any]) async throws -> Data {
    let operation = RielaAppControlOperation.reload(identity: identity, body: try JSONSerialization.data(withJSONObject: body))
    switch try resolve() {
    case .channel(let client):
      do { return try result(await client.send(operation, profile: profile)) } catch let RielaAppControlChannelError.code(code) { throw RielaAppAPIFailure(code: code.rawValue, status: 0, body: Data()) }
    case .notRunning(let lock):
      defer { lock.release() }
      let ports = RielaAppLocalReloadPorts(appRoot: appRoot, homeDirectory: homeDirectory, profileName: profile, deadline: deadline())
      let response = await RielaAppInstanceControlService(ports: RielaAppLocalControlPorts(ports: ports)).handle(operation, profile: profile)
      if ports.timedOut { throw RielaAppAPIFailure(code: "app_channel_timeout", status: 0, body: Data()) }
      return try result(response)
    }
  }
  func cancel(identity: String, sessionId: String?, body: [String: Any]) async throws -> Data {
    try await live(.cancel(identity: identity, sessionId: sessionId, body: JSONSerialization.data(withJSONObject: body)))
  }
  func run(identity: String, body: [String: Any]) async throws -> Data {
    try await live(.run(identity: identity, body: JSONSerialization.data(withJSONObject: body)))
  }
  func launchStatus(launchId: String) async throws -> Data { try await live(.launchStatus(launchId: launchId)) }
  private func source(identity: String) throws -> RielaAppDaemonWorkflowCandidate {
    let name = RielaAppProfileName(profile)
    let store = localStore(appRoot: appRoot, profile: name)
    guard let state = store.loadReadOnlyResult().state, let preference = state.preferences[identity],
          let id = preference.sourceIdentity,
          let source = RielaAppProfileWorkflowSources.resolveSource(sourceIdentity: id, appRootURL: appRoot, profileName: name, state: state) else {
      throw RielaAppAPIFailure(code: "invalid_workflow_source", status: 422, body: Data())
    }
    return source
  }
  func executions(identity: String) async throws -> Data {
    let source = try source(identity: identity)
    return try JSONEncoder().encode(RielaAppInstanceExecutionsProjection.list(identity: identity, workflowDirectory: source.workflowDirectory,
      sessionStoreRoot: RielaAppProfileStore.sessionStoreRootURL(homeDirectory: homeDirectory, profileName: .init(profile)).path, revision: nil))
  }
  func executionDetail(identity: String, sessionId: String) async throws -> Data {
    let source = try source(identity: identity)
    guard let detail = RielaAppInstanceExecutionsProjection.detailStatus(workflowDirectory: source.workflowDirectory,
      sessionStoreRoot: RielaAppProfileStore.sessionStoreRootURL(homeDirectory: homeDirectory, profileName: .init(profile)).path, sessionId: sessionId) else {
      throw RielaAppAPIFailure(code: "session_not_found", status: 404, body: Data())
    }
    return try JSONSerialization.data(withJSONObject: ["session": ["sessionId": detail.sessionId, "status": detail.status, "updatedAt": detail.updatedAt]])
  }
}

private func localStore(appRoot: URL, profile: RielaAppProfileName) -> RielaAppDaemonWorkflowStore {
  RielaAppDaemonWorkflowStore(stateURL: appRoot.appendingPathComponent("profiles/\(profile.rawValue)/daemon-workflows.json"), profileName: profile)
}

struct RielaAppLocalControlPorts: RielaAppInstanceControlPorts {
  let ports: RielaAppLocalReloadPorts
  func profile() async -> String { ports.profileName }
  func bootstrap() async -> RielaAppControlBootstrap { .init(profile: ports.profileName, revision: 0) }
  func isShuttingDown() async -> Bool { false }
  func serialized(_ body: @escaping @Sendable () async -> RielaAppControlResult) async -> RielaAppControlResult { await body() }
  func reloadPorts() -> any RielaAppInstanceReloadPorts { ports }
  func cancelPorts() -> any RielaAppInstanceCancelPorts { LocalCancelPorts() }
  func validateRevision(expectedRevision: Int, expectedProfile: String) async -> RielaAppControlConflict? { nil }
  func instanceExists(identity: String) async -> Bool { false }
  func environmentStatus(identity: String) async -> RuntimeEnvironmentStatus { .init() }
  func reloadEnvironment(identity: String) async -> RielaAppEnvironmentReloadOutcome { .notReady }
  func launchConfiguredRun(identity: String, input: RielaAppConfiguredRunInput) async -> RielaAppControlResult { .error(status: 409, code: "app_not_running") }
  func launchStatus(launchId: String, profile: String) async -> RielaAppControlResult { .error(status: 409, code: "app_not_running") }
}

private struct LocalCancelPorts: RielaAppInstanceCancelPorts {
  func profile() async -> String { "" }
  func instanceExists(identity: String) async -> Bool { false }
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome { .notFound }
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory { .init(sessionIds: [], pendingRunCount: 0) }
  func childRunning(identity: String) async -> Bool { false }
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement { throw RielaAppInstanceCancelError(code: .sessionNotFound) }
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState { .absent }
}

final class RielaAppLocalReloadPorts: RielaAppInstanceReloadPorts, @unchecked Sendable {
  let appRoot: URL
  let homeDirectory: URL
  let profileName: String
  let deadline: Date
  private(set) var timedOut = false
  init(appRoot: URL, homeDirectory: URL, profileName: String, deadline: Date) {
    self.appRoot = appRoot; self.homeDirectory = homeDirectory; self.profileName = profileName; self.deadline = deadline
  }
  private var name: RielaAppProfileName { .init(profileName) }
  private var store: RielaAppDaemonWorkflowStore { localStore(appRoot: appRoot, profile: name) }
  private func source(_ id: String) -> RielaAppDaemonWorkflowCandidate? {
    guard let state = store.loadReadOnlyResult().state else { return nil }
    return RielaAppProfileWorkflowSources.resolveSource(sourceIdentity: id, appRootURL: appRoot, profileName: name, state: state)
  }
  func currentInstance(identity: String) async -> RielaAppInstanceReloadInstance? {
    guard let state = store.loadReadOnlyResult().state, let id = state.preferences[identity]?.sourceIdentity,
          let candidate = source(id) else { return nil }
    return .init(identity: identity, workflowId: candidate.workflowId, sourceId: id, workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot)
  }
  func validateRevision(expectedRevision: Int, expectedProfile: String) async throws {
    guard expectedProfile == profileName else { throw RielaAppInstanceReloadError(code: .configurationConflict) }
  }
  func discoverCandidate(instance: RielaAppInstanceReloadInstance, requestedDirectory: String?) async throws -> RielaAppInstanceReloadCandidate {
    let candidate: RielaAppDaemonWorkflowCandidate?
    if let requestedDirectory { candidate = RielaAppDaemonWorkflowDiscovery(projectRoot: nil).discoverSelectedWorkflowDirectory(requestedDirectory) } else { candidate = source(instance.sourceId) }
    guard let candidate else {
      if let requestedDirectory,
         FileManager.default.fileExists(atPath: URL(fileURLWithPath: requestedDirectory).appendingPathComponent("workflow.json").path) {
        _ = try InstanceReloadSupport.validateCandidate(workflowDirectory: requestedDirectory, eventRoot: nil,
          expectedWorkflowId: instance.workflowId, nodePatches: [:], workingDirectory: requestedDirectory)
      }
      throw RielaAppInstanceReloadError(code: .invalidWorkflowSource)
    }
    return .init(sourceId: candidate.id, workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
                 sourceChanged: requestedDirectory != nil && candidate.id != instance.sourceId)
  }
  func validate(candidate: RielaAppInstanceReloadCandidate, instance: RielaAppInstanceReloadInstance) async throws -> RielaAppInstanceReloadValidated {
    guard let state = store.loadReadOnlyResult().state, let preference = state.preferences[instance.identity],
          let selected = candidateSource(candidate) else { throw RielaAppInstanceReloadError(code: .invalidWorkflowSource) }
    let value = try InstanceReloadSupport.validateCandidate(workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
      expectedWorkflowId: instance.workflowId, nodePatches: preference.configuration.nodePatches, workingDirectory: selected.workingDirectory)
    return .init(workflowId: value.bundle.workflow.workflowId, triggerDefaultsFingerprint: value.triggerDefaultsFingerprint, eventRootDigest: value.eventRootDigest)
  }
  private func candidateSource(_ candidate: RielaAppInstanceReloadCandidate) -> RielaAppDaemonWorkflowCandidate? {
    if candidate.sourceId.hasPrefix("selected-workflow:") { return RielaAppDaemonWorkflowDiscovery(projectRoot: nil).discoverSelectedWorkflowDirectory(candidate.workflowDirectory) }
    return source(candidate.sourceId)
  }
  func installedStartRecord(identity: String) async -> RielaAppInstanceStartRecord? { nil }
  func childRunning(identity: String) async -> Bool { false }
  func admission(identity: String, frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement { throw RielaAppInstanceReloadError(code: .instanceHandoffUnavailable) }
  func importDefinition(candidate: RielaAppInstanceReloadCandidate, reason: String) async throws -> RielaAppInstanceReloadResponse.Definition {
    guard Date() < deadline else { timedOut = true; throw RielaAppInstanceReloadError(code: .definitionStoreFailure) }
    guard let selected = candidateSource(candidate) else { throw RielaAppInstanceReloadError(code: .invalidWorkflowSource) }
    return try InstanceReloadSupport.importDefinition(storeRoot: RielaAppProfileStore.sessionStoreRootURL(homeDirectory: homeDirectory, profileName: name).path,
      workflowDirectory: candidate.workflowDirectory, workflowId: selected.workflowId, reason: reason, workingDirectory: selected.workingDirectory)
  }
  func relink(identity: String, candidate: RielaAppInstanceReloadCandidate) async throws -> Int {
    var state = store.load()
    if !state.workflowDirectories.contains(candidate.workflowDirectory) { state.workflowDirectories.append(candidate.workflowDirectory) }
    var preference = state.preference(for: identity); preference.identity = identity; preference.sourceIdentity = candidate.sourceId
    state.preferences[identity] = preference; try store.save(state); return 0
  }
  func refreshCache() async {}
  func replaceChild(identity: String, interrupt: Bool) async throws -> String { throw RielaAppInstanceReloadError(code: .instanceNotReady) }
  func profile() async -> String { profileName }
  func revision() async -> Int { 0 }
  func liveRevision() async -> Int? { nil }
}
#endif
