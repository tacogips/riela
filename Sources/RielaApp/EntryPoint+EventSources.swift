#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  func registerDaemonWorkflowEventSource(identity: String, sourceJSON: String, bindingJSON: String) -> String? {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      return "Instance could not be found"
    }
    let candidate = resolved.candidate
    do {
      let sourceId = try RielaWorkflowEventRegistration.register(
        candidate: candidate, sourceJSON: sourceJSON, bindingJSON: bindingJSON
      )
      status = "Registered event source \(sourceId) for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(identity: identity, changeDescription: "event source")
      return nil
    } catch {
      return "Invalid event source registration: \(error.localizedDescription)"
    }
  }

}
#endif
