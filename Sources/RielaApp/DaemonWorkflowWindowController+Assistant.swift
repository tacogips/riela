#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport

extension DaemonWorkflowWindowController {
  @objc func saveAssistantAssistance() {
    let assistance = assistantAssistanceTextView?.string ?? ""
    var settings = state.assistant
    settings.assistance = assistance
    if let error = onSaveAssistantAssistance(assistance) ?? onSaveAssistantSettings(settings) {
      assistantSaveStatusLabel.textColor = .systemRed
      assistantSaveStatusLabel.stringValue = error
      NSApp.requestUserAttention(.informationalRequest)
      return
    }
    state.assistant = settings
    assistantSaveStatusLabel.textColor = .secondaryLabelColor
    assistantSaveStatusLabel.stringValue = "Saved assistance"
    updateAssistantPanel()
    updateOverviewSummaries()
  }

  @objc func toggleAssistantFolded() {
    var settings = state.assistant
    settings.isFolded.toggle()
    saveAssistantSettings(settings)
  }

  @objc func sendAssistantMessage() {
    let message = assistantPromptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      return
    }
    assistantPromptField.stringValue = ""
    onSubmitAssistantMessage(message, assistantWorkingDirectory())
  }

  func updateAssistantPanel() {
    let settings = state.assistant
    guard renderedAssistantSettings != settings else {
      return
    }
    assistantContextLabel.stringValue = ""
    assistantTranscriptTextView?.textStorage?.setAttributedString(
      RielaAssistantMiniChatStyle.transcriptAttributedString(from: settings.messages)
    )
    assistantTranscriptTextView?.scrollToEndOfDocument(nil)
    assistantTranscriptScrollView?.isHidden = settings.isFolded
    assistantInputStackView?.isHidden = settings.isFolded
    RielaAssistantMiniChatStyle.updateFoldPresentation(
      isFolded: settings.isFolded,
      title: assistantPanelTitleLabel,
      availability: assistantAvailabilityLabel,
      context: assistantContextLabel,
      button: assistantFoldButton
    )
    assistantAvailabilityLabel.stringValue = ""
    assistantSelectionSummaryLabel.stringValue = assistantSettingsSummary(for: settings)
    settingsRootView?.assistantPanelCollapsed = settings.isFolded
    settingsRootView?.needsLayout = true
    settingsRootView?.layoutSubtreeIfNeeded()
    renderedAssistantSettings = settings
  }

  private func saveAssistantSettings(_ settings: RielaAppAssistantSettings) {
    if let error = onSaveAssistantSettings(settings) {
      assistantAvailabilityLabel.textColor = .systemRed
      assistantAvailabilityLabel.stringValue = error
      NSApp.requestUserAttention(.informationalRequest)
      return
    }
    state.assistant = settings
    updateAssistantPanel()
    updateOverviewSummaries()
  }

  private func assistantWorkingDirectory() -> String? {
    if let row = selectedRow(), let candidate = row.candidate {
      return row.preference.workingDirectory ?? candidate.workingDirectory
    }
    return state.projectDirectories.first ?? state.workflowDirectories.first
  }

  func assistantSettingsSummary(for settings: RielaAppAssistantSettings) -> String {
    let vendor = settings.vendor.settingsSelectableVendor
    return "\(vendor.displayName) / \(settings.selectedModel(for: vendor))"
  }

}
#endif
