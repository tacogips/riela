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
    RielaAssistantMiniChatStyle.configureHeaderLabels(
      title: assistantPanelTitleLabel,
      availability: assistantAvailabilityLabel,
      context: assistantContextLabel
    )

    let transcript = RielaAssistantMiniChatStyle.makeTranscriptTextView()
    assistantTranscriptTextView = transcript

    let transcriptScroll = NSScrollView()
    RielaAssistantMiniChatStyle.configureTranscriptScroll(transcriptScroll, transcript: transcript)
    assistantTranscriptScrollView = transcriptScroll

    let titleStack = NSStackView(views: [
      assistantPanelTitleLabel,
      assistantAvailabilityLabel,
      assistantContextLabel
    ])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 1
    titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let controls = NSStackView(views: [
      titleStack,
      assistantFoldButton
    ])
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false
    let input = NSStackView(views: [assistantPromptField, assistantSendButton])
    RielaAssistantMiniChatStyle.configureInputStack(input)
    assistantInputStackView = input
    assistantPromptField.heightAnchor.constraint(equalToConstant: 26).isActive = true
    assistantSendButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    assistantSendButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let panelStack = NSStackView(views: [controls, transcriptScroll, input])
    panelStack.orientation = .vertical
    panelStack.alignment = .width
    panelStack.spacing = 8
    panelStack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(panelStack)
    NSLayoutConstraint.activate([
      panelStack.topAnchor.constraint(equalTo: container.topAnchor, constant: RielaAssistantMiniChatStyle.verticalInset),
      panelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: RielaAssistantMiniChatStyle.horizontalInset),
      panelStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -RielaAssistantMiniChatStyle.horizontalInset),
      panelStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -RielaAssistantMiniChatStyle.verticalInset),
      input.heightAnchor.constraint(equalToConstant: RielaAssistantMiniChatStyle.inputHeight)
    ])
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
