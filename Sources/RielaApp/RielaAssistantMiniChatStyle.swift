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

  static func configurePanelContainer(_ container: NSView) {
    container.wantsLayer = true
    container.layer?.cornerRadius = panelCornerRadius
    container.layer?.borderWidth = 1
    container.layer?.borderColor = NSColor(calibratedWhite: 0.22, alpha: 1).cgColor
    container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
  }

  static func configureHeaderLabels(
    title: NSTextField,
    availability: NSTextField,
    context: NSTextField
  ) {
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.textColor = .white
    title.lineBreakMode = .byTruncatingTail
    availability.font = .systemFont(ofSize: 11)
    availability.textColor = mutedTextColor
    availability.lineBreakMode = .byTruncatingTail
    context.font = .systemFont(ofSize: 11)
    context.textColor = mutedTextColor
    context.lineBreakMode = .byTruncatingMiddle
  }

  static func makeTranscriptTextView() -> NSTextView {
    let transcript = NSTextView(frame: .zero)
    transcript.isEditable = false
    transcript.isSelectable = true
    transcript.isRichText = true
    transcript.importsGraphics = false
    transcript.font = .systemFont(ofSize: 12)
    transcript.textColor = .white
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
    input.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
    input.layer?.borderWidth = 1
    input.layer?.borderColor = NSColor(calibratedWhite: 0.27, alpha: 1).cgColor
  }

  static func configurePromptField(_ field: NSTextField) {
    field.placeholderString = "Ask for follow-up changes"
    field.setAccessibilityLabel("Assistant Message")
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.backgroundColor = .clear
    field.textColor = .white
    field.font = .systemFont(ofSize: 13)
    field.focusRingType = .none
  }

  static func configureSendButton(_ button: NSButton) {
    button.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
    button.bezelStyle = .circular
    button.imagePosition = .imageOnly
    button.contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 1)
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
    NSColor(calibratedWhite: 0.64, alpha: 1)
  }

  private static func assistantAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = 1.5
    paragraph.paragraphSpacing = 5
    return [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor(calibratedWhite: 0.90, alpha: 1),
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
      .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
      .backgroundColor: NSColor(calibratedWhite: 0.17, alpha: 1),
      .paragraphStyle: paragraph
    ]
  }
}
#endif
