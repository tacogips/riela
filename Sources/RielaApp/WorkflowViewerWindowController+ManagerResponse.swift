#if os(macOS)
import AppKit
import Foundation
import RielaViewer

extension WorkflowViewerWindowController {
  private struct ManagerResponseContext {
    var workflowId: String
    var sessionId: String
    var stepId: String
  }

  @objc func respondToManager() {
    let alert = NSAlert()
    alert.messageText = "Respond to Workflow"
    alert.informativeText = "Send a manager message to the selected running session."
    alert.addButton(withTitle: "Send")
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
    input.placeholderString = "Message"
    alert.accessoryView = input
    if let window {
      alert.beginSheetModal(for: window) { [weak self, weak input] response in
        guard response == .alertFirstButtonReturn else {
          return
        }
        Task { @MainActor in
          self?.submitManagerResponse(input?.stringValue ?? "")
        }
      }
      return
    }
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }
    submitManagerResponse(input.stringValue)
  }

  func submitManagerResponse(_ rawMessage: String) {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      managerResponseStatusLabel.textColor = .secondaryLabelColor
      managerResponseStatusLabel.stringValue = "Enter a response before sending."
      return
    }
    guard let context = managerResponseContext() else {
      managerResponseStatusLabel.textColor = .systemRed
      managerResponseStatusLabel.stringValue = "No running session is selected."
      return
    }
    if let error = onSendManagerMessage?(
      context.workflowId,
      context.sessionId,
      context.stepId,
      message
    ) {
      managerResponseStatusLabel.textColor = .systemRed
      managerResponseStatusLabel.stringValue = error
      return
    }
    managerResponseStatusLabel.textColor = .secondaryLabelColor
    managerResponseStatusLabel.stringValue = "Response sent."
    refresh()
  }

  func updateManagerResponseControls(
    state: WorkflowViewerState?,
    session: WorkflowViewerSessionSummary?
  ) {
    guard let state,
      let session,
      session.status == .running,
      let stepId = session.currentStepId,
      !stepId.isEmpty
    else {
      managerResponseBanner.isHidden = true
      managerRespondButton.isEnabled = false
      return
    }
    managerResponseBanner.isHidden = false
    managerResponseLabel.stringValue = "Awaiting response at \(stepId)"
    managerRespondButton.isEnabled = onSendManagerMessage != nil
    managerRespondButton.toolTip = onSendManagerMessage == nil
      ? "This viewer cannot send manager messages"
      : "Send manager message to \(state.workflow.workflowId)"
  }

  private func managerResponseContext() -> ManagerResponseContext? {
    guard let state,
      let session = selectedSession(in: state),
      session.status == .running,
      let stepId = session.currentStepId,
      !stepId.isEmpty
    else {
      return nil
    }
    return ManagerResponseContext(
      workflowId: state.workflow.workflowId,
      sessionId: session.sessionId,
      stepId: stepId
    )
  }
}
#endif
