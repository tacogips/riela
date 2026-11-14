#if os(macOS)
import AppKit
import RielaAppSupport

final class RielaAppStatusBannerView: NSView {
  var onDismiss: (() -> Void)?

  private let iconView = NSImageView()
  private let messageLabel = NSTextField(labelWithString: "")
  private let historyButton = NSButton(title: "", target: nil, action: nil)
  private let closeButton = NSButton(title: "", target: nil, action: nil)
  private var history: [RielaAppStatusMessage] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    messageLabel.lineBreakMode = .byTruncatingTail
    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    iconView.setAccessibilityElement(false)
    historyButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
    historyButton.bezelStyle = .toolbar
    historyButton.target = self
    historyButton.action = #selector(showHistoryMenu)
    historyButton.toolTip = "Show status history"
    historyButton.setAccessibilityLabel("Show Status History")
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    closeButton.bezelStyle = .toolbar
    closeButton.target = self
    closeButton.action = #selector(dismiss)
    closeButton.toolTip = "Dismiss"
    closeButton.setAccessibilityLabel("Dismiss Status Message")
    addSubview(iconView)
    addSubview(messageLabel)
    addSubview(historyButton)
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
    let historyMaxX = closeButton.isHidden ? bounds.maxX - 6 : closeButton.frame.minX
    historyButton.frame = NSRect(x: historyMaxX - 28, y: 4, width: 28, height: 28)
    let trailingControlX = historyButton.isHidden ? historyMaxX : historyButton.frame.minX
    messageLabel.frame = NSRect(
      x: iconView.frame.maxX + 8,
      y: 8,
      width: max(0, trailingControlX - iconView.frame.maxX - 16),
      height: 20
    )
  }

  func configure(message: RielaAppStatusMessage, history: [RielaAppStatusMessage] = []) {
    self.history = history
    messageLabel.stringValue = message.text
    historyButton.isHidden = history.count < 2
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

  @objc private func showHistoryMenu() {
    let menu = NSMenu()
    for message in history.reversed() {
      let item = NSMenuItem(title: message.text, action: nil, keyEquivalent: "")
      item.isEnabled = false
      switch message.severity {
      case .info:
        item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
      case .error:
        item.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
      }
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: historyButton.bounds.maxY + 2), in: historyButton)
  }
}
#endif
