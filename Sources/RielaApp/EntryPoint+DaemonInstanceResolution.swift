#if os(macOS)
import Foundation
import RielaAppSupport

struct ResolvedDaemonWorkflowInstance {
  var profileName: RielaAppProfileName
  var localIdentity: String
  var state: RielaAppDaemonWorkflowState
  var preference: RielaAppDaemonWorkflowPreference
  var instance: RielaAppProfiledWorkflowInstance

  var candidate: RielaAppDaemonWorkflowCandidate {
    instance.runtimeCandidate
  }

  var runtimeIdentity: String {
    instance.id
  }
}

extension RielaApp {
  func resolvedProfileIdentity(_ rawIdentity: String) -> (profileName: RielaAppProfileName, localIdentity: String) {
    if let parsed = RielaAppProfileInstanceIdentity(rawValue: rawIdentity) {
      return (parsed.profileName, parsed.identity)
    }
    return (daemonProfileName, rawIdentity)
  }

  func profileRuntimeIdentity(profileName: RielaAppProfileName, localIdentity: String) -> String {
    RielaAppProfileInstanceIdentity(profileName: profileName, identity: localIdentity).rawValue
  }

  func resolveDaemonWorkflowInstance(identity rawIdentity: String) -> ResolvedDaemonWorkflowInstance? {
    let identity = resolvedProfileIdentity(rawIdentity)
    let state = daemonState(profileName: identity.profileName)
    let sources = daemonWorkflowSourcesForResolution(profileName: identity.profileName, state: state)
    guard let instance = state.workflowInstances(from: sources).first(where: { $0.identity == identity.localIdentity }) else {
      return nil
    }
    return ResolvedDaemonWorkflowInstance(
      profileName: identity.profileName,
      localIdentity: identity.localIdentity,
      state: state,
      preference: state.preference(for: identity.localIdentity),
      instance: RielaAppProfiledWorkflowInstance(profileName: identity.profileName, instance: instance)
    )
  }

  func daemonState(profileName: RielaAppProfileName) -> RielaAppDaemonWorkflowState {
    if profileName == daemonProfileName {
      return daemonState
    }
    return makeDaemonStore(profileName: profileName).load()
  }

  func daemonWorkflowSourcesForResolution(
    profileName: RielaAppProfileName,
    state: RielaAppDaemonWorkflowState
  ) -> [RielaAppDaemonWorkflowCandidate] {
    let cachedSources: [RielaAppDaemonWorkflowCandidate]
    if profileName == daemonProfileName {
      cachedSources = daemonWorkflowSources + daemonCandidates
    } else {
      cachedSources = daemonProfileWorkflowSources[profileName] ?? []
    }
    return uniqueDaemonWorkflowSources(cachedSources + daemonWorkflowSources(profileName: profileName, state: state))
  }

  private func uniqueDaemonWorkflowSources(
    _ candidates: [RielaAppDaemonWorkflowCandidate]
  ) -> [RielaAppDaemonWorkflowCandidate] {
    var seen = Set<String>()
    return candidates.filter { candidate in
      guard !seen.contains(candidate.id) else {
        return false
      }
      seen.insert(candidate.id)
      return true
    }
  }

  func saveDaemonState(_ state: RielaAppDaemonWorkflowState, profileName: RielaAppProfileName) -> Bool {
    do {
      try makeDaemonStore(profileName: profileName).save(state)
      if profileName == daemonProfileName {
        daemonState = state
      }
      return true
    } catch {
      status = "Failed to save instance profile state: \(error.localizedDescription)"
      return false
    }
  }
}
#endif
