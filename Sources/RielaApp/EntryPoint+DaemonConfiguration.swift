#if os(macOS)
import Foundation

extension RielaApp {
  func restartActiveDaemonWorkflowAfterConfigurationChange(identity: String, changeDescription: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      return
    }
    let preference = daemonState.preference(for: identity)
    guard preference.available, preference.active else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate)
      )
      status = "Applied \(changeDescription) and restarted \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }
}
#endif
