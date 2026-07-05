#if os(macOS)
import Foundation

extension RielaApp {
  func restartActiveDaemonWorkflowAfterConfigurationChange(identity: String, changeDescription: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      return
    }
    let candidate = resolved.candidate
    let preference = resolved.preference
    guard preference.available, preference.active else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: resolved.runtimeIdentity)
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate, preference: preference),
        server: daemonServerConfiguration(profileName: resolved.profileName)
      )
      status = "Applied \(changeDescription) and restarted \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }
}
#endif
