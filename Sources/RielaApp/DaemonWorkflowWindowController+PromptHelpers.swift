#if os(macOS)
import AppKit

@MainActor
final class WorkflowSourceSelectionTarget: NSObject {
  private var checkmarks: [NSImageView] = []
  private var rowTargets: [WorkflowSourceSelectionRowTarget] = []
  private let onConfirm: (() -> Void)?
  private(set) var selectedIndex = 0

  init(onConfirm: (() -> Void)? = nil) {
    self.onConfirm = onConfirm
  }

  func attach(checkmarks: [NSImageView], rowTargets: [WorkflowSourceSelectionRowTarget]) {
    self.checkmarks = checkmarks
    self.rowTargets = rowTargets
    updateSelection(index: selectedIndex)
  }

  func updateSelection(index: Int, confirm: Bool = false) {
    selectedIndex = max(0, min(index, checkmarks.count - 1))
    for (checkmarkIndex, checkmark) in checkmarks.enumerated() {
      checkmark.isHidden = checkmarkIndex != selectedIndex
    }
    if confirm {
      onConfirm?()
    }
  }
}

@MainActor
final class AddInstancePathFieldTarget: NSObject, NSTextFieldDelegate {
  let field: NSTextField
  let caption = NSTextField(labelWithString: "")
  private let choosesDirectories: Bool

  init(field: NSTextField, choosesDirectories: Bool) {
    self.field = field
    self.choosesDirectories = choosesDirectories
    super.init()
    field.delegate = self
    caption.textColor = .systemRed
    caption.font = .systemFont(ofSize: 11)
    caption.isHidden = true
  }

  func controlTextDidChange(_ obj: Notification) {
    updateCaption()
  }

  @objc func browse() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !choosesDirectories
    panel.canChooseDirectories = choosesDirectories
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    field.stringValue = url.path
    updateCaption()
  }

  private func updateCaption() {
    let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    caption.isHidden = path.isEmpty || FileManager.default.fileExists(atPath: path)
    caption.stringValue = caption.isHidden ? "" : "File not found"
  }
}

@MainActor
final class WorkflowSourceSelectionRowTarget: NSObject {
  private weak var selectionTarget: WorkflowSourceSelectionTarget?
  private let index: Int

  init(selectionTarget: WorkflowSourceSelectionTarget, index: Int) {
    self.selectionTarget = selectionTarget
    self.index = index
  }

  @objc func select() {
    selectionTarget?.updateSelection(index: index, confirm: true)
  }
}

@MainActor
struct WorkflowSourceOptionRow {
  var row: NSStackView
  var checkmark: NSImageView
  var rowTarget: WorkflowSourceSelectionRowTarget
}

@MainActor
enum AddInstancePromptLayout {
  static let windowWidth: CGFloat = 560
  static let relinkSize = NSSize(width: windowWidth, height: 360)
  static let workflowSelectionSize = NSSize(width: windowWidth, height: 500)
  static let parameterSize = NSSize(width: windowWidth, height: 440)
  static let parameterRowsPreferredHeight: CGFloat = 280
}

@MainActor
final class AddInstancePromptModalTarget: NSObject, NSWindowDelegate {
  weak var window: NSWindow?
  private var hasStoppedModal = false

  @objc func confirm() {
    stop(with: .OK)
  }

  @objc func cancel() {
    stop(with: .cancel)
  }

  func windowWillClose(_ notification: Notification) {
    stop(with: .cancel)
  }

  private func stop(with response: NSApplication.ModalResponse) {
    guard !hasStoppedModal else {
      return
    }
    hasStoppedModal = true
    window?.orderOut(nil)
    NSApp.stopModal(withCode: response)
  }
}

@MainActor
struct AddInstancePromptViewFactory {
  func accessoryStack(views: [NSView], size: NSSize) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.frame = NSRect(origin: .zero, size: size)
    stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width).isActive = true
    return stack
  }

  func scrollingParameterStack(title: NSTextField, rows: [NSView]) -> NSStackView {
    let rowsStack = NSStackView(views: rows)
    rowsStack.orientation = .vertical
    rowsStack.alignment = .width
    rowsStack.spacing = 8
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(rowsStack)

    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: AddInstancePromptLayout.parameterRowsPreferredHeight)
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true

    NSLayoutConstraint.activate([
      rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])

    return accessoryStack(
      views: [title, scroll],
      size: AddInstancePromptLayout.parameterSize
    )
  }

  func emptyWorkflowSelectionStack(message: String, sourceActions: NSView, size: NSSize) -> NSStackView {
    let emptyLabel = NSTextField(labelWithString: message)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 2
    emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    emptyLabel.setAccessibilityLabel(message)

    let sourceActionsTitle = NSTextField(labelWithString: "Manage Sources")
    sourceActionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    sourceActionsTitle.alignment = .left

    return accessoryStack(views: [emptyLabel, sourceActionsTitle, sourceActions], size: size)
  }
}
#endif
