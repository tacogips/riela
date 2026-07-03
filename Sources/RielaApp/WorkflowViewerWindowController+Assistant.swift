#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport

extension WorkflowViewerWindowController {
  private enum AssistantLayout {
    static let expandedHeight: CGFloat = 176
    static let foldedHeight: CGFloat = 42
  }

  func buildAssistantPanel() -> NSView {
    configureAssistantControls()
    let container = NSView()
    RielaAssistantMiniChatStyle.configurePanelContainer(container)
    let titleStack = RielaAssistantMiniChatStyle.makeTitleStack(
      title: assistantPanelTitleLabel,
      availability: assistantAvailabilityLabel,
      context: assistantContextLabel
    )

    let transcript = RielaAssistantMiniChatStyle.makeTranscriptTextView()
    assistantTranscriptTextView = transcript

    let transcriptScroll = NSScrollView()
    RielaAssistantMiniChatStyle.configureTranscriptScroll(transcriptScroll, transcript: transcript)
    assistantTranscriptScrollView = transcriptScroll

    let controls = RielaAssistantMiniChatStyle.makeHeaderStack(titleStack: titleStack, trailingControls: [
      assistantClearButton,
      assistantFoldButton
    ])
    let input = RielaAssistantMiniChatStyle.makeInputStack(
      promptField: assistantPromptField,
      sendButton: assistantSendButton
    )
    assistantInputStackView = input

    let panelStack = RielaAssistantMiniChatStyle.makePanelStack(header: controls, transcriptScroll: transcriptScroll, input: input)
    RielaAssistantMiniChatStyle.installPanelStack(panelStack, input: input, in: container)
    return container
  }

  func updateAssistantPanel(settings: RielaAppAssistantSettings, profileName: RielaAppProfileName) {
    assistantSettings = settings
    assistantProfileName = profileName
    updateAssistantPanel()
  }

  func updateAssistantPanel() {
    let settings = assistantSettings
    assistantPanelTitleLabel.stringValue = "Riela Assistant"
    assistantContextLabel.stringValue = ""
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
    assistantClearButton.isEnabled = !settings.messages.isEmpty
    assistantClearButton.isHidden = settings.isFolded
    assistantAvailabilityLabel.stringValue = ""
    assistantPanelHeightConstraint?.constant = settings.isFolded
      ? AssistantLayout.foldedHeight
      : AssistantLayout.expandedHeight
    window?.contentView?.layoutSubtreeIfNeeded()
  }

  @objc func toggleAssistantFolded() {
    var settings = assistantSettings
    settings.isFolded.toggle()
    saveAssistantSettings(settings)
  }

  @objc func clearAssistantMessages() {
    guard !assistantSettings.messages.isEmpty else {
      return
    }
    let alert = NSAlert()
    alert.messageText = "Clear Assistant History?"
    alert.informativeText = "This removes the saved assistant transcript for this profile."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }
    var settings = assistantSettings
    settings.clearMessages()
    saveAssistantSettings(settings)
  }

  @objc func sendAssistantMessage() {
    let message = assistantPromptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      return
    }
    assistantPromptField.stringValue = ""
    onSubmitAssistantMessage?(message, assistantWorkingDirectory())
  }

  private func configureAssistantControls() {
    assistantFoldButton.target = self
    assistantFoldButton.action = #selector(toggleAssistantFolded)
    RielaAssistantMiniChatStyle.configureFoldButton(assistantFoldButton)

    assistantClearButton.target = self
    assistantClearButton.action = #selector(clearAssistantMessages)
    assistantClearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    assistantClearButton.bezelStyle = .toolbar
    assistantClearButton.isBordered = false
    assistantClearButton.toolTip = "Clear assistant history"
    assistantClearButton.setAccessibilityLabel("Clear Assistant History")

    assistantPromptField.target = self
    assistantPromptField.action = #selector(sendAssistantMessage)
    RielaAssistantMiniChatStyle.configurePromptField(assistantPromptField)

    assistantSendButton.target = self
    assistantSendButton.action = #selector(sendAssistantMessage)
    RielaAssistantMiniChatStyle.configureSendButton(assistantSendButton)
  }

  private func saveAssistantSettings(_ settings: RielaAppAssistantSettings) {
    if let error = onSaveAssistantSettings?(settings) {
      assistantAvailabilityLabel.textColor = .systemRed
      assistantAvailabilityLabel.stringValue = error
      NSApp.requestUserAttention(.informationalRequest)
      return
    }
    assistantSettings = settings
    updateAssistantPanel()
  }

  private func assistantWorkingDirectory() -> String? {
    if let currentDirectory, !currentDirectory.isEmpty {
      return currentDirectory
    }
    return workflowDirectory.map {
      URL(fileURLWithPath: $0, isDirectory: true).deletingLastPathComponent().path
    }
  }

}
#endif
