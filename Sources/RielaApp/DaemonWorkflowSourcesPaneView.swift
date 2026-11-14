#if os(macOS)
import AppKit

final class DaemonWorkflowSourcesPaneView: NSView {
  private enum Layout {
    static let headerHeight: CGFloat = 72
    static let verticalSpacing: CGFloat = 12
    static let emptyLabelHeight: CGFloat = 44
  }

  let header: NSView
  private(set) var listScrollView: NSScrollView
  private(set) var emptyLabel: NSTextField

  init(header: NSView, listScrollView: NSScrollView, emptyLabel: NSTextField) {
    self.header = header
    self.listScrollView = listScrollView
    self.emptyLabel = emptyLabel
    super.init(frame: .zero)
    addSubview(header)
    addSubview(listScrollView)
    addSubview(emptyLabel)
  }

  func replaceListScrollView(_ newListScrollView: NSScrollView, emptyLabel newEmptyLabel: NSTextField) {
    listScrollView.removeFromSuperview()
    emptyLabel.removeFromSuperview()
    listScrollView = newListScrollView
    emptyLabel = newEmptyLabel
    addSubview(listScrollView)
    addSubview(emptyLabel)
    needsLayout = true
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
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Layout.headerHeight)
    let bodyY = Layout.headerHeight + Layout.verticalSpacing
    let bodyHeight = max(0, bounds.height - bodyY)
    listScrollView.frame = NSRect(x: 0, y: bodyY, width: bounds.width, height: bodyHeight)
    layoutEmptyLabel()
  }

  private func layoutEmptyLabel() {
    let width = min(CGFloat(260), max(1, listScrollView.bounds.width - 28))
    emptyLabel.frame = NSRect(
      x: listScrollView.frame.minX + max(14, (listScrollView.bounds.width - width) / 2),
      y: listScrollView.frame.minY + max(0, (listScrollView.bounds.height - Layout.emptyLabelHeight) / 2),
      width: width,
      height: Layout.emptyLabelHeight
    )
  }
}
#endif
