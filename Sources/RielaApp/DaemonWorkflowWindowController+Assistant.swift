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

  @objc func assistantVendorChanged() {
    var settings = state.assistant
    settings.vendor = selectedAssistantVendor()
    populateAssistantModelPopup(for: settings.vendor, settings: settings)
    settings.setSelectedModel(settings.vendor.defaultModel, for: settings.vendor)
    saveAssistantSettings(settings)
  }

  @objc func assistantModelChanged() {
    var settings = state.assistant
    settings.vendor = selectedAssistantVendor()
    settings.setSelectedModel(selectedAssistantModel(for: settings.vendor), for: settings.vendor)
    saveAssistantSettings(settings)
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
    var settings = state.assistant
    guard renderedAssistantSettings != settings else {
      return
    }
    let settingsVendor = settings.vendor.settingsSelectableVendor
    assistantPanelTitleLabel.stringValue = "Riela Assistant"
    assistantContextLabel.stringValue = ""
    populateAssistantVendorPopupIfNeeded()
    assistantSettingsVendorPopup.selectItem(withTitle: settingsVendor.displayName)
    settings.vendor = settingsVendor
    populateAssistantModelPopup(for: settingsVendor, settings: settings)
    assistantTranscriptTextView?.textStorage?.setAttributedString(
      RielaAssistantMiniChatStyle.transcriptAttributedString(from: settings.messages)
    )
    assistantTranscriptTextView?.scrollToEndOfDocument(nil)
    assistantTranscriptScrollView?.isHidden = settings.isFolded
    assistantInputStackView?.isHidden = settings.isFolded
    assistantFoldButton.image = NSImage(
      systemSymbolName: settings.isFolded ? "chevron.up" : "chevron.down",
      accessibilityDescription: nil
    )
    assistantFoldButton.toolTip = settings.isFolded ? "Open assistant" : "Fold assistant"
    assistantFoldButton.setAccessibilityLabel(settings.isFolded ? "Open Assistant" : "Fold Assistant")
    assistantAvailabilityLabel.stringValue = ""
    assistantSelectionSummaryLabel.stringValue = assistantSettingsSummary(for: settings)
    settingsRootView?.assistantPanelCollapsed = settings.isFolded
    settingsRootView?.needsLayout = true
    settingsRootView?.layoutSubtreeIfNeeded()
    renderedAssistantSettings = settings
  }

  private func selectedAssistantVendor() -> RielaAppAssistantVendor {
    guard let item = assistantSettingsVendorPopup.selectedItem,
      let rawValue = item.representedObject as? String,
      let vendor = RielaAppAssistantVendor(rawValue: rawValue)
    else {
      return state.assistant.vendor.settingsSelectableVendor
    }
    return vendor.settingsSelectableVendor
  }

  private func selectedAssistantModel(for vendor: RielaAppAssistantVendor) -> String {
    guard let item = assistantSettingsModelPopup.selectedItem,
      let model = item.representedObject as? String,
      vendor.modelSuggestions.contains(model)
    else {
      return vendor.defaultModel
    }
    return model
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

  private func populateAssistantVendorPopupIfNeeded() {
    guard assistantSettingsVendorPopup.numberOfItems == 0 else {
      return
    }
    for vendor in RielaAppAssistantVendor.selectableVendors {
      assistantSettingsVendorPopup.addItem(withTitle: vendor.displayName)
      assistantSettingsVendorPopup.lastItem?.representedObject = vendor.rawValue
    }
  }

  private func populateAssistantModelPopup(
    for vendor: RielaAppAssistantVendor,
    settings: RielaAppAssistantSettings
  ) {
    assistantSettingsModelPopup.removeAllItems()
    for model in vendor.modelSuggestions {
      assistantSettingsModelPopup.addItem(withTitle: model)
      assistantSettingsModelPopup.lastItem?.representedObject = model
    }
    assistantSettingsModelPopup.selectItem(withTitle: settings.selectedModel(for: vendor))
  }

  func assistantSettingsSummary(for settings: RielaAppAssistantSettings) -> String {
    let vendor = settings.vendor.settingsSelectableVendor
    return "\(vendor.displayName) / \(settings.selectedModel(for: vendor))"
  }

}
#endif
