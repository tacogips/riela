#if os(macOS)
import AppKit
import Foundation

extension RielaApp {
  @objc func openViewer() {
    guard let path = selectedWorkflow?.path else {
      selectWorkflow()
      return
    }
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(
      workflowDirectory: path,
      sessionStoreRoot: selectedSessionStoreRoot,
      currentDirectory: selectedWorkingDirectory,
      assistantProfileName: daemonProfileName,
      assistantSettings: daemonState.assistant,
      onSaveAssistantSettings: { [weak self] settings in
        self?.saveAssistantSettings(settings) ?? "RielaApp is not available"
      },
      onSubmitAssistantMessage: { [weak self] message, workingDirectory in
        self?.submitAssistantMessage(message, workingDirectory: workingDirectory)
      }
    )
  }
}
#endif
