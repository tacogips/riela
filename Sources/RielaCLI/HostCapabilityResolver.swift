import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaWork

protocol HostCapabilityResolving: Sendable {
  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot]
}

extension HostCapabilityResolving {
  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool
  ) async throws -> [HostCapabilitySnapshot] {
    try await resolve(
      host: host,
      scope: scope,
      workingDirectory: workingDirectory,
      readOnly: readOnly,
      localAddonExecutables: [:]
    )
  }
}

enum HostCapabilityResolverError: Error, Equatable {
  case unsupportedHost(String)
  case invalidProfile(String)
}

struct HostCapabilityResolver: HostCapabilityResolving, Sendable {
  var profileStore: RielaAppDaemonWorkflowStore
  var runner: any LocalProcessRunning
  var environment: [String: String]

  init(
    profileStore: RielaAppDaemonWorkflowStore? = nil,
    activeProfileStore: RielaAppProfileStore = RielaAppProfileStore(),
    runner: any LocalProcessRunning = FoundationLocalProcessRunner(),
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) {
    let activeProfile = activeProfileStore.loadActiveProfileName()
    self.profileStore = profileStore ?? RielaAppDaemonWorkflowStore(
      stateURL: RielaAppProfileStore.profilesRootURL(appRootURL: activeProfileStore.appRootURL)
        .appendingPathComponent(activeProfile.rawValue, isDirectory: true)
        .appendingPathComponent("daemon-workflows.json"),
      profileName: activeProfile
    )
    self.runner = runner
    self.environment = environment
  }

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    if host != "local" {
      let snapshots = try runtimeStore(scope: scope, workingDirectory: workingDirectory).loadHostSnapshots()
      if let exact = snapshots.first(where: { isLive($0) && $0.hostId == host }) {
        return [exact]
      }
      let group = snapshots.filter { isLive($0) && $0.groups.contains(host) }
        .sorted { $0.hostId < $1.hostId }
      guard !group.isEmpty else { throw HostCapabilityResolverError.unsupportedHost(host) }
      return group
    }
    let load = profileStore.loadReadOnlyResult()
    guard let state = load.state else {
      throw HostCapabilityResolverError.invalidProfile(load.error ?? "profile is unreadable")
    }
    var declarations: [NodeExecutionBackend: BackendCapabilityDeclaration] = [:]
    for (name, declaration) in state.backends {
      guard let backend = NodeExecutionBackend(rawValue: name), declarations[backend] == nil else {
        throw HostCapabilityResolverError.invalidProfile("profile contains an unknown or duplicate backend")
      }
      declarations[backend] = declaration
    }
    let observed = await BackendCapabilityProbe(runner: runner).probeAll(environment: environment)
    let snapshot = HostCapabilitySnapshot(
      hostId: "local",
      backends: BackendCapabilityMerger.merge(observations: observed, declarations: declarations),
      addonExecutables: localAddonExecutables,
      environment: environment.mapValues { !$0.isEmpty },
      refreshedAt: Date()
    )
    if !readOnly {
      try runtimeStore(scope: scope, workingDirectory: workingDirectory).saveHostSnapshot(snapshot)
    }
    return [snapshot]
  }

  private func runtimeStore(scope: WorkflowScope, workingDirectory: String) -> WorkStore {
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: nil,
      scope: scope,
      workingDirectory: workingDirectory,
      environment: environment
    )
    return WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
  }

  private func isLive(_ snapshot: HostCapabilitySnapshot, now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(snapshot.refreshedAt)
    return snapshot.live && (snapshot.capacity ?? 0) > 0
      && age >= 0 && age < 30
  }
}
