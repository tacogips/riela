#if os(macOS)
import AppKit
import RielaAppSupport

@MainActor
enum RielaAssistantMiniChatStyle {
  static let panelCornerRadius: CGFloat = 18
  static let inputCornerRadius: CGFloat = 18
  static let horizontalInset: CGFloat = 14
  static let verticalInset: CGFloat = 10
  static let inputHeight: CGFloat = 42
  static let promptFieldHeight: CGFloat = 26
  static let sendButtonSize: CGFloat = 30

  static func configurePanelContainer(_ container: NSView) {
    container.wantsLayer = true
    container.layer?.cornerRadius = panelCornerRadius
    container.layer?.borderWidth = 1
    container.layer?.borderColor = NSColor.separatorColor.cgColor
    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }

  static func configureHeaderLabels(
    title: NSTextField,
    availability: NSTextField,
    context: NSTextField
  ) {
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.textColor = .labelColor
    title.lineBreakMode = .byTruncatingTail
    availability.font = .systemFont(ofSize: 11)
    availability.textColor = mutedTextColor
    availability.lineBreakMode = .byTruncatingTail
    context.font = .systemFont(ofSize: 11)
    context.textColor = mutedTextColor
    context.lineBreakMode = .byTruncatingMiddle
  }

  static func makeTitleStack(
    title: NSTextField,
    availability: NSTextField,
    context: NSTextField
  ) -> NSStackView {
    configureHeaderLabels(title: title, availability: availability, context: context)
    let titleStack = NSStackView(views: [title, availability, context])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 1
    titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return titleStack
  }

  static func makeHeaderStack(titleStack: NSView, trailingControls: [NSView]) -> NSStackView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for control in trailingControls {
      control.setContentHuggingPriority(.required, for: .horizontal)
    }
    let controls = NSStackView(views: [titleStack, spacer] + trailingControls)
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false
    return controls
  }

  static func makeTranscriptTextView() -> NSTextView {
    let transcript = NSTextView(frame: .zero)
    transcript.isEditable = false
    transcript.isSelectable = true
    transcript.isRichText = true
    transcript.importsGraphics = false
    transcript.font = .systemFont(ofSize: 12)
    transcript.textColor = .labelColor
    transcript.backgroundColor = .clear
    transcript.drawsBackground = false
    transcript.textContainerInset = NSSize(width: 4, height: 8)
    transcript.textContainer?.lineFragmentPadding = 0
    return transcript
  }

  static func configureTranscriptScroll(_ scroll: NSScrollView, transcript: NSTextView) {
    scroll.documentView = transcript
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 12
    scroll.layer?.masksToBounds = true
  }

  static func configureInputStack(_ input: NSStackView) {
    input.orientation = .horizontal
    input.alignment = .centerY
    input.spacing = 8
    input.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
    input.translatesAutoresizingMaskIntoConstraints = false
    input.wantsLayer = true
    input.layer?.cornerRadius = inputCornerRadius
    input.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    input.layer?.borderWidth = 1
    input.layer?.borderColor = NSColor.separatorColor.cgColor
  }

  static func makeInputStack(promptField: NSTextField, sendButton: NSButton) -> NSStackView {
    let input = NSStackView(views: [promptField, sendButton])
    configureInputStack(input)
    promptField.heightAnchor.constraint(equalToConstant: promptFieldHeight).isActive = true
    promptField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    sendButton.widthAnchor.constraint(equalToConstant: sendButtonSize).isActive = true
    sendButton.heightAnchor.constraint(equalToConstant: sendButtonSize).isActive = true
    return input
  }

  static func makePanelStack(header: NSView, transcriptScroll: NSView, input: NSView) -> NSStackView {
    let panelStack = NSStackView(views: [header, transcriptScroll, input])
    panelStack.orientation = .vertical
    panelStack.alignment = .width
    panelStack.spacing = 8
    panelStack.translatesAutoresizingMaskIntoConstraints = false
    return panelStack
  }

  static func installPanelStack(_ panelStack: NSStackView, input: NSView, in container: NSView) {
    container.addSubview(panelStack)
    NSLayoutConstraint.activate([
      panelStack.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
      panelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
      panelStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalInset),
      panelStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
      input.heightAnchor.constraint(equalToConstant: inputHeight)
    ])
  }

  static func configurePromptField(_ field: NSTextField) {
    field.placeholderString = "Ask for follow-up changes"
    field.setAccessibilityLabel("Assistant Message")
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.backgroundColor = .clear
    field.textColor = .labelColor
    field.font = .systemFont(ofSize: 13)
    field.focusRingType = .none
  }

  static func configureSendButton(_ button: NSButton) {
    button.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
    button.bezelStyle = .circular
    button.imagePosition = .imageOnly
    button.contentTintColor = .controlAccentColor
    button.toolTip = "Send"
    button.setAccessibilityLabel("Send Assistant Message")
  }

  static func configureFoldButton(_ button: NSButton) {
    button.bezelStyle = .toolbar
    button.isBordered = false
    button.contentTintColor = mutedTextColor
  }

  static func configurePickerControls(vendorPopup: NSPopUpButton, modelField: NSPopUpButton) {
    vendorPopup.controlSize = .small
    vendorPopup.font = .systemFont(ofSize: 11)
    modelField.controlSize = .small
    modelField.font = .systemFont(ofSize: 11)
  }

  static func transcriptAttributedString(from messages: [RielaAppAssistantMessage]) -> NSAttributedString {
    guard !messages.isEmpty else {
      return NSAttributedString(string: "")
    }

    let transcript = NSMutableAttributedString()
    for message in messages {
      if transcript.length > 0 {
        transcript.append(NSAttributedString(string: "\n\n"))
      }
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      switch message.role {
      case .user:
        transcript.append(NSAttributedString(
          string: "  \(content)  ",
          attributes: userAttributes()
        ))
      case .assistant, .system:
        transcript.append(NSAttributedString(
          string: content,
          attributes: assistantAttributes(alignment: .left)
        ))
      }
    }
    return transcript
  }

  private static var mutedTextColor: NSColor {
    .secondaryLabelColor
  }

  private static func assistantAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = 1.5
    paragraph.paragraphSpacing = 5
    return [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph
    ]
  }

  private static func userAttributes() -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    paragraph.lineSpacing = 1.5
    paragraph.paragraphSpacing = 5
    return [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.labelColor,
      .backgroundColor: NSColor.controlBackgroundColor,
      .paragraphStyle: paragraph
    ]
  }
}
#endif
