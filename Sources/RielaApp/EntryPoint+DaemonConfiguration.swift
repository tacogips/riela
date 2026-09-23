#if os(macOS)
import Foundation

extension RielaApp {
  func restartActiveDaemonWorkflowAfterConfigurationChange(identity: String, changeDescription: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      return
    }
    guard resolved.preference.available, resolved.preference.active else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: resolved.runtimeIdentity)
      guard let approved = await approvedDaemonWorkflowInstance(identity: identity),
            approved.preference.available, approved.preference.active else { return }
      await daemonRuntime.start(
        approved.candidate,
        configuration: daemonRuntimeConfiguration(for: approved.candidate, preference: approved.preference),
        server: daemonServerConfiguration(profileName: approved.profileName),
        sessionStoreRoot: daemonSessionStoreRoot(profileName: approved.profileName)
      )
      status = "Applied \(changeDescription) and restarted \(approved.candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }
}
#endif
