#if os(macOS)
import AppKit
import RielaCore
import RielaViewer

final class WorkflowExecutionTimelinePaneView: NSView {
  private enum Layout {
    static let height: CGFloat = 330
    static let headerHeight: CGFloat = 24
    static let controlWidth: CGFloat = 28
    static let controlSpacing: CGFloat = 4
    static let gutterWidth: CGFloat = 180
    static let canvasCornerRadius: CGFloat = 10
  }

  private let titleLabel = NSTextField(labelWithString: "Timeline")
  private let summaryLabel = NSTextField(labelWithString: "")
  private let zoomOutButton = NSButton(title: "", target: nil, action: nil)
  private let fitButton = NSButton(title: "", target: nil, action: nil)
  private let zoomInButton = NSButton(title: "", target: nil, action: nil)
  private let gutterView = WorkflowExecutionTimelineGutterView()
  private let scrollView = NSScrollView()
  private let canvasView = WorkflowExecutionTimelineCanvasView()
  private let statusLabel = NSTextField(labelWithString: "No node executions recorded")
  private var entries: [WorkflowViewerTimelineEntry] = []
  private var messages: [WorkflowViewerMessage] = []
  private var workflow: WorkflowDefinition?
  private let dateFormatter: DateFormatter
  private let durationFormatter: (TimeInterval?) -> String

  init(
    dateFormatter: DateFormatter,
    durationFormatter: @escaping (TimeInterval?) -> String
  ) {
    self.dateFormatter = dateFormatter
    self.durationFormatter = durationFormatter
    super.init(frame: .zero)
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: Layout.height)
  }

  func update(state: WorkflowViewerState, now: Date = Date()) {
    entries = state.timeline
    messages = state.messages
    workflow = state.workflow
    let layout = WorkflowExecutionTimelineLayout(
      entries: state.timeline,
      messages: state.messages,
      workflow: state.workflow,
      now: now
    )
    gutterView.layoutModel = layout
    canvasView.update(
      layout: layout,
      entries: state.timeline,
      messages: state.messages,
      messageLogAvailable: state.messageLogAvailable,
      dateFormatter: dateFormatter,
      durationFormatter: durationFormatter
    )
    summaryLabel.stringValue = state.timeline.isEmpty
      ? "No executions"
      : "\(layout.rows.count) rows, \(layout.bars.count) log boxes, \(state.timeline.reduce(0) { $0 + $1.backendEvents.count }) recent events"
    statusLabel.isHidden = !state.timeline.isEmpty
    statusLabel.stringValue = state.sessions.isEmpty ? "No executions recorded yet for this instance." : "No node executions recorded."
    refreshCanvasSize()
    setAccessibilityValue(summaryLabel.stringValue)
  }

  func showUnavailable(_ message: String) {
    entries = []
    messages = []
    workflow = nil
    summaryLabel.stringValue = "Unavailable"
    statusLabel.stringValue = message
    statusLabel.isHidden = false
    let empty = WorkflowExecutionTimelineLayout(entries: [], now: Date())
    gutterView.layoutModel = empty
    canvasView.update(
      layout: empty,
      entries: [],
      messages: [],
      messageLogAvailable: false,
      dateFormatter: dateFormatter,
      durationFormatter: durationFormatter
    )
    refreshCanvasSize()
    setAccessibilityValue(message)
  }

  @objc private func zoomOut() {
    setZoom(canvasView.zoomScale / 1.25)
  }

  @objc private func fitZoom() {
    canvasView.zoomScale = 1
    refreshCanvasSize()
  }

  @objc private func zoomIn() {
    setZoom(canvasView.zoomScale * 1.25)
  }

  private func setZoom(_ scale: CGFloat) {
    canvasView.zoomScale = min(8, max(0.5, scale))
    refreshCanvasSize()
  }

  private func build() {
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 3
    configureButton(zoomOutButton, symbolName: "minus.magnifyingglass", label: "Zoom Out Timeline", action: #selector(zoomOut))
    configureButton(fitButton, symbolName: "arrow.up.left.and.down.right.magnifyingglass", label: "Fit Timeline", action: #selector(fitZoom))
    configureButton(zoomInButton, symbolName: "plus.magnifyingglass", label: "Zoom In Timeline", action: #selector(zoomIn))

    scrollView.documentView = canvasView
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollBoundsChanged),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    wantsLayer = true
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = Layout.canvasCornerRadius
    scrollView.layer?.masksToBounds = true
    scrollView.layer?.borderWidth = 1

    addSubview(titleLabel)
    addSubview(summaryLabel)
    addSubview(zoomOutButton)
    addSubview(fitButton)
    addSubview(zoomInButton)
    addSubview(gutterView)
    addSubview(scrollView)
    addSubview(statusLabel)
    updateColors()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Workflow Execution Timeline")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func layout() {
    super.layout()
    let controlsWidth = Layout.controlWidth * 3 + Layout.controlSpacing * 2
    let summaryWidth = min(260, max(0, bounds.width * 0.35))
    titleLabel.frame = NSRect(
      x: 0,
      y: 0,
      width: max(0, bounds.width - summaryWidth - controlsWidth - 18),
      height: Layout.headerHeight
    )
    let controlsX = max(0, bounds.width - summaryWidth - controlsWidth - 8)
    zoomOutButton.frame = NSRect(x: controlsX, y: 0, width: Layout.controlWidth, height: Layout.headerHeight)
    fitButton.frame = NSRect(
      x: zoomOutButton.frame.maxX + Layout.controlSpacing,
      y: 0,
      width: Layout.controlWidth,
      height: Layout.headerHeight
    )
    zoomInButton.frame = NSRect(
      x: fitButton.frame.maxX + Layout.controlSpacing,
      y: 0,
      width: Layout.controlWidth,
      height: Layout.headerHeight
    )
    summaryLabel.frame = NSRect(x: bounds.width - summaryWidth, y: 0, width: summaryWidth, height: Layout.headerHeight)
    let chartY = Layout.headerHeight + 8
    let chartHeight = max(1, bounds.height - chartY)
    gutterView.frame = NSRect(x: 0, y: chartY, width: Layout.gutterWidth, height: chartHeight)
    scrollView.frame = NSRect(
      x: Layout.gutterWidth,
      y: chartY,
      width: max(1, bounds.width - Layout.gutterWidth),
      height: chartHeight
    )
    refreshCanvasSize()
    statusLabel.frame = scrollView.frame.insetBy(dx: min(24, scrollView.frame.width / 2), dy: min(24, scrollView.frame.height / 2))
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  @objc private func scrollBoundsChanged() {
    gutterView.verticalOffset = scrollView.contentView.bounds.origin.y
  }

  private func refreshCanvasSize() {
    let size = canvasView.contentSize(minVisibleSize: scrollView.contentView.bounds.size)
    canvasView.frame = NSRect(origin: .zero, size: size)
    gutterView.contentHeight = size.height
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.48).cgColor
      scrollView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }
    gutterView.needsDisplay = true
    canvasView.needsDisplay = true
  }

  private func configureButton(_ button: NSButton, symbolName: String, label: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.title = ""
    button.bezelStyle = .toolbar
    button.target = self
    button.action = action
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }
}

private final class WorkflowExecutionTimelineGutterView: NSView {
  private enum Layout {
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 58
  }

  var layoutModel = WorkflowExecutionTimelineLayout(entries: [], now: Date()) {
    didSet { needsDisplay = true }
  }

  var verticalOffset: CGFloat = 0 {
    didSet { needsDisplay = true }
  }

  var contentHeight: CGFloat = 1 {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool {
    true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    let headerAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    "Step".draw(with: NSRect(x: 12, y: 7, width: bounds.width - 24, height: 16), options: [.truncatesLastVisibleLine], attributes: headerAttributes)
    NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
    NSBezierPath.strokeLine(from: NSPoint(x: bounds.maxX - 0.5, y: 0), to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
    NSBezierPath.strokeLine(from: NSPoint(x: 0, y: Layout.headerHeight - 0.5), to: NSPoint(x: bounds.maxX, y: Layout.headerHeight - 0.5))

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.labelColor
    ]
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    for row in layoutModel.rows {
      let y = Layout.headerHeight + CGFloat(row.index) * Layout.rowHeight - verticalOffset
      guard y + Layout.rowHeight >= 0, y <= bounds.maxY else {
        continue
      }
      if row.index.isMultiple(of: 2) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: Layout.rowHeight).fill()
      }
      row.stepId.draw(
        with: NSRect(x: 12, y: y + 7, width: bounds.width - 24, height: 16),
        options: [.truncatesLastVisibleLine],
        attributes: titleAttributes
      )
      row.nodeId.draw(
        with: NSRect(x: 12, y: y + 25, width: bounds.width - 24, height: 14),
        options: [.truncatesLastVisibleLine],
        attributes: detailAttributes
      )
      NSColor.separatorColor.withAlphaComponent(0.16).setStroke()
      NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y + Layout.rowHeight - 0.5), to: NSPoint(x: bounds.maxX, y: y + Layout.rowHeight - 0.5))
    }
  }
}

private final class WorkflowExecutionTimelineCanvasView: NSView {
  private enum Layout {
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 58
    static let chartInsetX: CGFloat = 18
    static let barHeight: CGFloat = 34
    static let minimumBarWidth: CGFloat = 96
  }

  var zoomScale: CGFloat = 1 {
    didSet { needsDisplay = true }
  }

  private var layoutModel = WorkflowExecutionTimelineLayout(entries: [], now: Date())
  private var entriesById: [String: WorkflowViewerTimelineEntry] = [:]
  private var messages: [WorkflowViewerMessage] = []
  private var messageLogAvailable = true
  private var dateFormatter: DateFormatter?
  private var durationFormatter: ((TimeInterval?) -> String)?
  private var selectedEntryId: String?
  private var popover: NSPopover?

  override var isFlipped: Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  func update(
    layout: WorkflowExecutionTimelineLayout,
    entries: [WorkflowViewerTimelineEntry],
    messages: [WorkflowViewerMessage],
    messageLogAvailable: Bool,
    dateFormatter: DateFormatter,
    durationFormatter: @escaping (TimeInterval?) -> String
  ) {
    layoutModel = layout
    entriesById = Dictionary(uniqueKeysWithValues: entries.map { ($0.executionId, $0) })
    self.messages = messages
    self.messageLogAvailable = messageLogAvailable
    self.dateFormatter = dateFormatter
    self.durationFormatter = durationFormatter
    if selectedEntryId.flatMap({ entriesById[$0] }) == nil {
      selectedEntryId = nil
      popover?.close()
    }
    needsDisplay = true
    refreshAccessibilityChildren()
  }

  func contentSize(minVisibleSize: NSSize) -> NSSize {
    let rowHeight = Layout.headerHeight + CGFloat(layoutModel.rows.count) * Layout.rowHeight + 12
    let baseWidth = max(minVisibleSize.width, 640)
    return NSSize(width: baseWidth * zoomScale, height: max(minVisibleSize.height, rowHeight))
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawBackground()
    guard !layoutModel.bars.isEmpty else {
      return
    }
    drawAxis()
    for bar in layoutModel.bars {
      draw(bar: bar)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let location = convert(event.locationInWindow, from: nil)
    guard let hit = hitBar(at: location) else {
      selectedEntryId = nil
      popover?.close()
      needsDisplay = true
      return
    }
    selectedEntryId = hit.entryId
    needsDisplay = true
    showPopover(for: hit.entryId, relativeTo: barFrame(hit))
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36:
      if let selectedEntryId, let bar = layoutModel.bars.first(where: { $0.entryId == selectedEntryId }) {
        showPopover(for: selectedEntryId, relativeTo: barFrame(bar))
      }
    case 123, 125:
      moveSelection(offset: -1)
    case 124, 126:
      moveSelection(offset: 1)
    default:
      super.keyDown(with: event)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    toolTip = "Click a bar to inspect logs and messages."
  }

  private func moveSelection(offset: Int) {
    guard !layoutModel.bars.isEmpty else {
      return
    }
    let current = selectedEntryId.flatMap { selected in layoutModel.bars.firstIndex { $0.entryId == selected } } ?? -1
    let next = min(layoutModel.bars.count - 1, max(0, current + offset))
    selectedEntryId = layoutModel.bars[next].entryId
    needsDisplay = true
  }

  private func drawBackground() {
    NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
    bounds.fill()
    for row in layoutModel.rows where row.index.isMultiple(of: 2) {
      let y = Layout.headerHeight + CGFloat(row.index) * Layout.rowHeight
      NSColor.windowBackgroundColor.withAlphaComponent(0.34).setFill()
      NSRect(x: 0, y: y, width: bounds.width, height: Layout.rowHeight).fill()
    }
  }

  private func drawAxis() {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
    NSBezierPath.strokeLine(from: NSPoint(x: 0, y: Layout.headerHeight - 0.5), to: NSPoint(x: bounds.maxX, y: Layout.headerHeight - 0.5))
    for tick in layoutModel.axisTicks {
      let x = xPosition(for: tick.fraction)
      NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
      NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: bounds.maxY))
      tick.label.draw(
        with: NSRect(x: x + 4, y: 7, width: 60, height: 14),
        options: [.truncatesLastVisibleLine],
        attributes: attributes
      )
    }
  }

  private func draw(bar: WorkflowExecutionTimelineLayout.Bar) {
    let frame = barFrame(bar)
    let fillColor = statusColor(bar.status).withAlphaComponent(0.14)
    let strokeColor = statusColor(bar.status).withAlphaComponent(0.86)
    let path = NSBezierPath(rect: frame)
    fillColor.setFill()
    path.fill()
    strokeColor.setStroke()
    path.lineWidth = 1
    path.stroke()
    strokeColor.setFill()
    NSRect(x: frame.minX, y: frame.minY, width: 4, height: frame.height).fill()
    if selectedEntryId == bar.entryId {
      NSColor.controlAccentColor.setStroke()
      path.lineWidth = 2
      path.stroke()
    }
    let labels = barLabels(bar)
    guard frame.width > 44, !labels.title.isEmpty else {
      return
    }
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
      .foregroundColor: NSColor.labelColor
    ]
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    labels.title.draw(
      with: NSRect(x: frame.minX + 9, y: frame.minY + 4, width: frame.width - 14, height: 13),
      options: [.truncatesLastVisibleLine],
      attributes: titleAttributes
    )
    labels.detail.draw(
      with: NSRect(x: frame.minX + 9, y: frame.minY + 19, width: frame.width - 14, height: 12),
      options: [.truncatesLastVisibleLine],
      attributes: detailAttributes
    )
  }

  private func barLabels(_ bar: WorkflowExecutionTimelineLayout.Bar) -> (title: String, detail: String) {
    guard let entry = entriesById[bar.entryId] else {
      return ("", "")
    }
    let attempt = entry.attempt > 1 ? " attempt \(entry.attempt)" : ""
    let duration = durationFormatter?(entry.duration) ?? ""
    let status = entry.status.rawValue.replacingOccurrences(of: "_", with: " ")
    return (
      entry.ganttLogSummary(maxLength: 88),
      [status, duration, attempt.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: "  ")
    )
  }

  private func statusColor(_ status: WorkflowStepExecutionStatus) -> NSColor {
    switch status {
    case .running:
      .systemBlue
    case .completed:
      .systemGreen
    case .failed:
      .systemRed
    case .skipped:
      .systemGray
    }
  }

  private func hitBar(at point: NSPoint) -> WorkflowExecutionTimelineLayout.Bar? {
    layoutModel.bars.first { barFrame($0).insetBy(dx: -2, dy: -5).contains(point) }
  }

  private func barFrame(_ bar: WorkflowExecutionTimelineLayout.Bar) -> NSRect {
    let startX = xPosition(for: bar.startFraction)
    let endX = xPosition(for: bar.endFraction)
    let width = max(Layout.minimumBarWidth, endX - startX)
    let y = Layout.headerHeight + CGFloat(bar.rowIndex) * Layout.rowHeight + (Layout.rowHeight - Layout.barHeight) / 2
    return NSRect(x: startX, y: y, width: width, height: Layout.barHeight)
  }

  private func xPosition(for fraction: Double) -> CGFloat {
    let width = max(1, bounds.width - Layout.chartInsetX * 2)
    return Layout.chartInsetX + CGFloat(fraction) * width
  }

  private func showPopover(for entryId: String, relativeTo rect: NSRect) {
    guard let entry = entriesById[entryId],
      let dateFormatter,
      let durationFormatter
    else {
      return
    }
    popover?.close()
    let next = WorkflowExecutionDetailPopover.make(
      entry: entry,
      messages: messages,
      messageLogAvailable: messageLogAvailable,
      dateFormatter: dateFormatter,
      durationFormatter: durationFormatter
    )
    popover = next
    next.show(relativeTo: rect, of: self, preferredEdge: .maxY)
  }

  private func refreshAccessibilityChildren() {
    let elements: [NSAccessibilityElement] = layoutModel.bars.compactMap { bar in
      guard let entry = entriesById[bar.entryId] else {
        return nil
      }
      let element = NSAccessibilityElement()
      element.setAccessibilityRole(.button)
      element.setAccessibilityParent(self)
      element.setAccessibilityFrameInParentSpace(barFrame(bar))
      element.setAccessibilityLabel(accessibilityLabel(for: entry))
      return element
    }
    setAccessibilityChildren(elements.isEmpty ? nil : elements)
  }

  private func accessibilityLabel(for entry: WorkflowViewerTimelineEntry) -> String {
    let status = entry.status.rawValue.replacingOccurrences(of: "_", with: " ")
    let started = dateFormatter?.string(from: entry.startedAt) ?? ""
    let duration = durationFormatter?(entry.duration) ?? ""
    return "\(entry.stepId), \(status), started \(started), duration \(duration)"
  }
}
#endif
