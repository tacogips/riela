#if os(macOS)
import AppKit

final class DaemonWorkflowEmptyStateView: NSView {
  var onViewWorkflowSources: (() -> Void)?
  var onCreateInstance: (() -> Void)?

  private let titleLabel = NSTextField(labelWithString: "Set up your first instance")
  private let stepsLabel = NSTextField(labelWithString: [
    "1  Riela ships with starter workflows - find them under Workflow Sources, or import your own.",
    "2  Press + to create an instance from a source.",
    "3  Give it a name, point it at a .env file if needed, and start it."
  ].joined(separator: "\n"))
  private let sourcesButton = NSButton(title: "View Workflow Sources", target: nil, action: nil)
  private let createButton = NSButton(title: "Create Instance", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.alignment = .center
    stepsLabel.textColor = .secondaryLabelColor
    stepsLabel.lineBreakMode = .byWordWrapping
    stepsLabel.maximumNumberOfLines = 5
    stepsLabel.alignment = .left
    sourcesButton.bezelStyle = .rounded
    createButton.bezelStyle = .rounded
    sourcesButton.target = self
    sourcesButton.action = #selector(viewWorkflowSources)
    createButton.target = self
    createButton.action = #selector(createInstance)
    addSubview(titleLabel)
    addSubview(stepsLabel)
    addSubview(sourcesButton)
    addSubview(createButton)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Set up your first instance")
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
    titleLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 24)
    stepsLabel.frame = NSRect(x: 0, y: 34, width: bounds.width, height: 74)
    let buttonWidth: CGFloat = 160
    let totalWidth = buttonWidth * 2 + 10
    sourcesButton.frame = NSRect(
      x: max(0, (bounds.width - totalWidth) / 2),
      y: 122,
      width: buttonWidth,
      height: 30
    )
    createButton.frame = NSRect(x: sourcesButton.frame.maxX + 10, y: 122, width: buttonWidth, height: 30)
  }

  override var fittingSize: NSSize {
    NSSize(width: 420, height: 160)
  }

  @objc private func viewWorkflowSources() {
    onViewWorkflowSources?()
  }

  @objc private func createInstance() {
    onCreateInstance?()
  }
}
#endif
