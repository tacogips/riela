#if os(macOS)
import AppKit

@MainActor
final class RielaAppSettingsEditorWindowController: NSWindowController {
  enum Result: Equatable {
    case confirmed
    case cancelled
    case action(Int)
  }

  @MainActor
  private final class Target: NSObject {
    weak var window: NSWindow?
    var result: Result = .cancelled
    var shouldCancel: (() -> Bool)?

    @objc func confirm() {
      result = .confirmed
      stop()
    }

    @objc func cancel() {
      guard shouldCancel?() ?? true else {
        return
      }
      result = .cancelled
      stop()
    }

    @objc func chooseAction(_ sender: NSButton) {
      result = .action(sender.tag)
      stop()
    }

    private func stop() {
      guard let window else {
        return
      }
      window.orderOut(nil)
      NSApp.stopModal()
    }
  }

  private let target = Target()

  static func editMultiline(title: String, message: String, value: String) -> String? {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .controlBackgroundColor
    textView.drawsBackground = true
    textView.string = value

    let scrollView = NSScrollView(frame: textView.frame)
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scrollView)
    let statusLabel = NSTextField(labelWithString: "")
    statusLabel.textColor = .systemRed
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 2
    let editorStack = NSStackView(views: [statusLabel, scrollView])
    editorStack.orientation = .vertical
    editorStack.alignment = .width
    editorStack.spacing = 8

    let controller = RielaAppSettingsEditorWindowController(
      title: title,
      message: message,
      content: editorStack,
      contentSize: NSSize(width: 560, height: 360),
      primaryTitle: "Done"
    )
    var discardArmed = false
    controller.target.shouldCancel = {
      guard textView.string != value else {
        return true
      }
      guard discardArmed else {
        discardArmed = true
        statusLabel.stringValue = "Unsaved changes. Press Cancel again to discard them, or Done to keep your edits."
        return false
      }
      return true
    }
    guard controller.runModal() == .confirmed else {
      return nil
    }
    return textView.string
  }

  static func chooseAction(
    title: String,
    message: String,
    currentTitle: String,
    currentValue: String,
    actions: [(title: String, detail: String)]
  ) -> Int? {
    let currentValueLabel = NSTextField(labelWithString: currentValue)
    currentValueLabel.lineBreakMode = .byTruncatingMiddle
    currentValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let currentRow = RielaAppSettingsRow(views: [
      rielaAppSettingsTitleLabel(currentTitle, maxWidth: 150),
      currentValueLabel
    ])
    currentRow.orientation = .horizontal
    currentRow.alignment = .firstBaseline
    currentRow.spacing = 8
    _ = rielaAppSettingsRow(currentRow)

    let controller = RielaAppSettingsEditorWindowController(
      title: title,
      message: message,
      content: NSStackView(views: [currentRow]),
      contentSize: NSSize(width: 520, height: 250),
      actionRows: actions
    )
    switch controller.runModal() {
    case let .action(index):
      return index
    case .confirmed, .cancelled:
      return nil
    }
  }

  init(
    title: String,
    message: String,
    content: NSView,
    contentSize: NSSize,
    primaryTitle: String? = nil,
    actionRows: [(title: String, detail: String)] = []
  ) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    super.init(window: window)
    target.window = window
    window.contentView = buildContent(
      title: title,
      message: message,
      content: content,
      primaryTitle: primaryTitle,
      actionRows: actionRows
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  func runModal() -> Result {
    guard let window else {
      return .cancelled
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.runModal(for: window)
    return target.result
  }

  private func buildContent(
    title: String,
    message: String,
    content: NSView,
    primaryTitle: String?,
    actionRows: [(title: String, detail: String)]
  ) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    let messageLabel = NSTextField(labelWithString: message)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.lineBreakMode = .byWordWrapping
    messageLabel.maximumNumberOfLines = 2

    let contentStack = NSStackView(views: [titleLabel, messageLabel, content])
    contentStack.orientation = .vertical
    contentStack.alignment = .width
    contentStack.spacing = 12
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    if !actionRows.isEmpty {
      for (index, action) in actionRows.enumerated() {
        contentStack.addArrangedSubview(actionRow(title: action.title, detail: action.detail, index: index))
      }
    }

    let cancelButton = NSButton(title: "Cancel", target: target, action: #selector(Target.cancel))
    var buttons = [cancelButton]
    if let primaryTitle {
      buttons.insert(NSButton(title: primaryTitle, target: target, action: #selector(Target.confirm)), at: 0)
    }
    let buttonStack = NSStackView(views: buttons)
    buttonStack.orientation = .horizontal
    buttonStack.alignment = .centerY
    buttonStack.spacing = 8
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(contentStack)
    container.addSubview(buttonStack)
    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
      contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      contentStack.bottomAnchor.constraint(lessThanOrEqualTo: buttonStack.topAnchor, constant: -16)
    ])
    return container
  }

  private func actionRow(title: String, detail: String, index: Int) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail
    let textStack = NSStackView(views: [titleLabel, detailLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    let button = NSButton(title: "Choose", target: target, action: #selector(Target.chooseAction(_:)))
    button.tag = index
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [textStack, spacer, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    return rielaAppSettingsRow(row)
  }
}
#endif
