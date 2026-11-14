#if os(macOS)
import AppKit
import RielaAppSupport

final class RielaAppStatusBannerView: NSView {
  var onDismiss: (() -> Void)?

  private let iconView = NSImageView()
  private let messageLabel = NSTextField(labelWithString: "")
  private let closeButton = NSButton(title: "", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    messageLabel.lineBreakMode = .byTruncatingTail
    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    iconView.setAccessibilityElement(false)
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    closeButton.bezelStyle = .toolbar
    closeButton.target = self
    closeButton.action = #selector(dismiss)
    closeButton.toolTip = "Dismiss"
    closeButton.setAccessibilityLabel("Dismiss Status Message")
    addSubview(iconView)
    addSubview(messageLabel)
    addSubview(closeButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    iconView.frame = NSRect(x: inset, y: 10, width: 16, height: 16)
    closeButton.frame = NSRect(x: bounds.maxX - 34, y: 4, width: 28, height: 28)
    messageLabel.frame = NSRect(
      x: iconView.frame.maxX + 8,
      y: 8,
      width: max(0, closeButton.frame.minX - iconView.frame.maxX - 16),
      height: 20
    )
  }

  func configure(message: RielaAppStatusMessage) {
    messageLabel.stringValue = message.text
    switch message.severity {
    case .info:
      iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
      iconView.contentTintColor = .controlAccentColor
      messageLabel.textColor = .labelColor
      layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
      closeButton.isHidden = true
    case .error:
      iconView.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
      iconView.contentTintColor = .systemRed
      messageLabel.textColor = .labelColor
      layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
      layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.7).cgColor
      closeButton.isHidden = false
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(message.text)
  }

  @objc private func dismiss() {
    onDismiss?()
  }
}
#endif
