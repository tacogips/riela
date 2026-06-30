#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  func saveAssistantAssistance(_ assistance: String) -> String? {
    daemonState.assistant.assistance = assistance
    guard saveDaemonState() else {
      return status
    }
    status = "Updated assistant assistance"
    refreshDaemonWorkflowWindow()
    return nil
  }
}
#endif
