#if os(macOS)
import AppKit
import RielaCore

struct DaemonWorkflowGraphModel: Equatable {
  struct Node: Equatable, Identifiable {
    var id: String
    var nodeId: String
    var title: String
    var description: String?
    var role: NodeRole?
    var depth: Int
    var outgoingSummary: String
  }

  struct Edge: Equatable, Hashable {
    var from: String
    var to: String
    var label: String?
  }

  var workflowId: String
  var nodes: [Node]
  var edges: [Edge]

  init(workflow: WorkflowDefinition) {
    self.init(
      workflowId: workflow.workflowId,
      entryStepId: workflow.entryStepId,
      steps: workflow.steps
    )
  }

  init(authoredWorkflow: AuthoredWorkflowJSON) throws {
    let steps = authoredWorkflow.steps ?? authoredWorkflow.nodes.map { WorkflowStepRef(id: $0.id, nodeId: $0.id) }
    guard !authoredWorkflow.workflowId.isEmpty else {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow("workflow.workflowId: must be a non-empty string")
    }
    guard let entryStepId = authoredWorkflow.entryStepId ?? steps.first?.id, !entryStepId.isEmpty else {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow("workflow.entryStepId: must be a non-empty string")
    }
    guard !steps.isEmpty else {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow("workflow.steps: must contain at least one step")
    }
    if let emptyStepIndex = Self.firstEmptyStepIndex(in: steps) {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow("workflow.steps[\(emptyStepIndex)].id: must be a non-empty string")
    }
    if let duplicateStepId = Self.firstDuplicateStepId(in: steps) {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow("workflow.steps: step id '\(duplicateStepId)' must be unique")
    }
    self.init(
      workflowId: authoredWorkflow.workflowId,
      entryStepId: entryStepId,
      steps: steps
    )
  }

  private init(workflowId: String, entryStepId: String, steps: [WorkflowStepRef]) {
    self.workflowId = workflowId
    let depths = Self.depths(entryStepId: entryStepId, steps: steps)
    let edges = Self.edges(steps: steps)
    let outgoingByStepId = Dictionary(grouping: edges, by: \.from)
    nodes = steps.map { step in
      let outgoing = outgoingByStepId[step.id] ?? []
      return Node(
        id: step.id,
        nodeId: step.nodeId,
        title: step.id,
        description: step.description,
        role: step.role,
        depth: depths[step.id] ?? 0,
        outgoingSummary: Self.outgoingSummary(outgoing)
      )
    }
    self.edges = edges
  }

  private static func firstEmptyStepIndex(in steps: [WorkflowStepRef]) -> Int? {
    steps.firstIndex { $0.id.isEmpty }
  }

  private static func firstDuplicateStepId(in steps: [WorkflowStepRef]) -> String? {
    var seenStepIds = Set<String>()
    for step in steps where !seenStepIds.insert(step.id).inserted {
      return step.id
    }
    return nil
  }

  var summary: String {
    "\(nodes.count) nodes, \(edges.count) transitions"
  }

  static func load(workflowDirectory: String) throws -> DaemonWorkflowGraphModel {
    let workflowURL = URL(fileURLWithPath: workflowDirectory, isDirectory: true).appendingPathComponent("workflow.json")
    let data = try Data(contentsOf: workflowURL)
    let validation = validateAuthoredWorkflowData(data)
    if let workflow = validation.workflow {
      return DaemonWorkflowGraphModel(workflow: workflow)
    }
    if let authoredWorkflow = try? JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data) {
      return try DaemonWorkflowGraphModel(authoredWorkflow: authoredWorkflow)
    }
    let messages = validation.diagnostics.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
    throw DaemonWorkflowGraphLoadError.invalidWorkflow(messages)
  }

  private static func depths(entryStepId: String, steps: [WorkflowStepRef]) -> [String: Int] {
    let stepById = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
    var result: [String: Int] = [:]
    assignDepths(startingAt: entryStepId, depth: 0, stepById: stepById, result: &result)
    for step in steps where result[step.id] == nil {
      let nextDepth = (result.values.max() ?? -1) + 1
      assignDepths(startingAt: step.id, depth: nextDepth, stepById: stepById, result: &result)
    }
    return result
  }

  private static func assignDepths(
    startingAt stepId: String,
    depth: Int,
    stepById: [String: WorkflowStepRef],
    result: inout [String: Int]
  ) {
    guard result[stepId] == nil, let step = stepById[stepId] else {
      return
    }
    result[stepId] = depth
    for transition in step.transitions ?? [] where transition.toWorkflowId == nil {
      assignDepths(startingAt: transition.toStepId, depth: depth + 1, stepById: stepById, result: &result)
      if let joinStepId = transition.fanout?.joinStepId, joinStepId != transition.toStepId {
        assignDepths(startingAt: joinStepId, depth: depth + 2, stepById: stepById, result: &result)
      }
    }
  }

  private static func edges(steps: [WorkflowStepRef]) -> [Edge] {
    let stepIds = Set(steps.map(\.id))
    var result: [Edge] = []
    for step in steps {
      for transition in step.transitions ?? [] {
        if stepIds.contains(transition.toStepId) {
          result.append(Edge(from: step.id, to: transition.toStepId, label: transitionLabel(transition)))
        }
        if let joinStepId = transition.fanout?.joinStepId,
          stepIds.contains(joinStepId),
          joinStepId != transition.toStepId {
          result.append(Edge(from: transition.toStepId, to: joinStepId, label: "join"))
        }
      }
    }
    if result.isEmpty, steps.count > 1 {
      result = zip(steps, steps.dropFirst()).map { previous, next in
        Edge(from: previous.id, to: next.id, label: nil)
      }
    }
    var seen: Set<Edge> = []
    return result.filter { seen.insert($0).inserted }
  }

  private static func transitionLabel(_ transition: WorkflowStepTransition) -> String? {
    var parts: [String] = []
    if let label = transition.label, !label.isEmpty {
      parts.append(label)
    }
    if transition.fanout != nil {
      parts.append("fanout")
    }
    if let toWorkflowId = transition.toWorkflowId, !toWorkflowId.isEmpty {
      parts.append(toWorkflowId)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " / ")
  }

  private static func outgoingSummary(_ edges: [Edge]) -> String {
    guard !edges.isEmpty else {
      return "No outgoing transitions"
    }
    return edges
      .map { edge in
        if let label = edge.label, !label.isEmpty {
          return "\(edge.to) (\(label))"
        }
        return edge.to
      }
      .joined(separator: ", ")
  }
}

enum DaemonWorkflowGraphLoadError: Error, CustomStringConvertible {
  case invalidWorkflow(String)

  var description: String {
    switch self {
    case let .invalidWorkflow(message):
      "Invalid workflow: \(message)"
    }
  }
}

final class DaemonWorkflowGraphPaneView: NSView {
  private enum Layout {
    static let height: CGFloat = 300
    static let headerHeight: CGFloat = 24
    static let headerSpacing: CGFloat = 8
    static let controlWidth: CGFloat = 28
    static let controlSpacing: CGFloat = 4
    static let legendHeight: CGFloat = 18
    static let canvasCornerRadius: CGFloat = 10
  }

  let titleLabel = NSTextField(labelWithString: "Graph")
  let summaryLabel = NSTextField(labelWithString: "")
  let legendLabel = NSTextField(
    labelWithString: "Legend: boxes are workflow steps, arrows are transitions, badges label fanout, join, or routed transitions."
  )
  let zoomOutButton = NSButton(title: "", target: nil, action: nil)
  let resetZoomButton = NSButton(title: "", target: nil, action: nil)
  let zoomInButton = NSButton(title: "", target: nil, action: nil)
  let scrollView = NSScrollView()
  let canvasView = DaemonWorkflowGraphCanvasView()
  let statusLabel = NSTextField(labelWithString: "No workflow graph")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    titleLabel.alignment = .left
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    legendLabel.textColor = .secondaryLabelColor
    legendLabel.font = .systemFont(ofSize: 11)
    legendLabel.lineBreakMode = .byTruncatingTail
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 3
    configureZoomButton(
      zoomOutButton,
      symbolName: "minus.magnifyingglass",
      label: "Zoom Out Graph",
      action: #selector(zoomOut)
    )
    configureZoomButton(
      resetZoomButton,
      symbolName: "1.magnifyingglass",
      label: "Reset Graph Zoom",
      action: #selector(resetZoom)
    )
    configureZoomButton(
      zoomInButton,
      symbolName: "plus.magnifyingglass",
      label: "Zoom In Graph",
      action: #selector(zoomIn)
    )

    scrollView.documentView = canvasView
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = Layout.canvasCornerRadius
    scrollView.layer?.masksToBounds = true
    scrollView.layer?.borderWidth = 1

    addSubview(titleLabel)
    addSubview(summaryLabel)
    addSubview(legendLabel)
    addSubview(zoomOutButton)
    addSubview(resetZoomButton)
    addSubview(zoomInButton)
    addSubview(scrollView)
    addSubview(statusLabel)
    updateColors()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Workflow Graph")
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

  override var fittingSize: NSSize {
    NSSize(width: 1, height: Layout.height)
  }

  func update(model: DaemonWorkflowGraphModel) {
    summaryLabel.stringValue = model.summary
    statusLabel.isHidden = !model.nodes.isEmpty
    statusLabel.stringValue = model.nodes.isEmpty ? "No workflow steps" : ""
    canvasView.model = model
    needsLayout = true
    setAccessibilityValue(model.summary)
  }

  @objc private func zoomOut() {
    setZoom(canvasView.zoomScale - 0.25)
  }

  @objc private func resetZoom() {
    setZoom(1)
  }

  @objc private func zoomIn() {
    setZoom(canvasView.zoomScale + 0.25)
  }

  private func setZoom(_ scale: CGFloat) {
    let boundedScale = min(1.75, max(0.5, scale))
    guard abs(canvasView.zoomScale - boundedScale) > 0.001 else {
      return
    }
    canvasView.zoomScale = boundedScale
    needsLayout = true
  }

  func showUnavailable(_ message: String) {
    summaryLabel.stringValue = "Unavailable"
    statusLabel.stringValue = message
    statusLabel.isHidden = false
    canvasView.model = nil
    needsLayout = true
    setAccessibilityValue(message)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func layout() {
    super.layout()
    let headerY = CGFloat(0)
    let controlsWidth = Layout.controlWidth * 3 + Layout.controlSpacing * 2
    let summaryWidth = min(220, max(0, bounds.width * 0.32))
    titleLabel.frame = NSRect(
      x: 0,
      y: headerY,
      width: max(0, bounds.width - summaryWidth - controlsWidth - (Layout.headerSpacing * 2)),
      height: Layout.headerHeight
    )
    let controlsX = max(0, bounds.width - summaryWidth - controlsWidth - Layout.headerSpacing)
    zoomOutButton.frame = NSRect(x: controlsX, y: headerY, width: Layout.controlWidth, height: Layout.headerHeight)
    resetZoomButton.frame = NSRect(
      x: zoomOutButton.frame.maxX + Layout.controlSpacing,
      y: headerY,
      width: Layout.controlWidth,
      height: Layout.headerHeight
    )
    zoomInButton.frame = NSRect(
      x: resetZoomButton.frame.maxX + Layout.controlSpacing,
      y: headerY,
      width: Layout.controlWidth,
      height: Layout.headerHeight
    )
    summaryLabel.frame = NSRect(
      x: max(0, bounds.width - summaryWidth),
      y: headerY,
      width: summaryWidth,
      height: Layout.headerHeight
    )
    let legendY = Layout.headerHeight + 2
    legendLabel.frame = NSRect(x: 0, y: legendY, width: bounds.width, height: Layout.legendHeight)
    let canvasY = legendY + Layout.legendHeight + Layout.headerSpacing
    scrollView.frame = NSRect(x: 0, y: canvasY, width: bounds.width, height: max(1, bounds.height - canvasY))
    let contentSize = canvasView.contentSize(minVisibleSize: scrollView.contentView.bounds.size)
    canvasView.frame = NSRect(origin: .zero, size: contentSize)
    let statusInsetX = min(CGFloat(24), scrollView.frame.width / 2)
    let statusInsetY = min(CGFloat(24), scrollView.frame.height / 2)
    let statusFrame = scrollView.frame.insetBy(dx: statusInsetX, dy: statusInsetY)
    statusLabel.frame = NSRect(
      x: statusFrame.minX,
      y: statusFrame.minY,
      width: max(1, statusFrame.width),
      height: max(1, statusFrame.height)
    )
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.48).cgColor
      scrollView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }
    canvasView.needsDisplay = true
  }

  private func configureZoomButton(_ button: NSButton, symbolName: String, label: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.title = ""
    button.bezelStyle = .toolbar
    button.target = self
    button.action = action
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }
}

final class DaemonWorkflowGraphCanvasView: NSView {
  private enum Layout {
    static let margin: CGFloat = 24
    static let columnWidth: CGFloat = 200
    static let rowHeight: CGFloat = 92
    static let nodeWidth: CGFloat = 150
    static let nodeHeight: CGFloat = 54
    static let arrowSize: CGFloat = 7
    static let labelHeight: CGFloat = 16
  }

  var model: DaemonWorkflowGraphModel? {
    didSet {
      selectedNodeId = nil
      nodePopover?.close()
      needsDisplay = true
    }
  }

  var zoomScale: CGFloat = 1 {
    didSet {
      needsDisplay = true
    }
  }

  private var selectedNodeId: String?
  private var nodePopover: NSPopover?

  var selectedNodeIdForTesting: String? {
    selectedNodeId
  }

  var hasNodePopoverForTesting: Bool {
    nodePopover != nil
  }

  override var isFlipped: Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  func contentSize(minVisibleSize: NSSize) -> NSSize {
    let visibleWidth = min(max(minVisibleSize.width, 1), 4_000)
    let visibleHeight = min(max(minVisibleSize.height, 1), 2_400)
    guard let model else {
      return NSSize(width: visibleWidth, height: visibleHeight)
    }
    let depths = model.nodes.map(\.depth)
    let columnCount = (depths.max() ?? 0) + 1
    let maxRows = Dictionary(grouping: model.nodes, by: \.depth).values.map(\.count).max() ?? 1
    let baseSize = NSSize(
      width: max(
        visibleWidth,
        Layout.margin * 2 + CGFloat(columnCount) * Layout.nodeWidth + CGFloat(max(0, columnCount - 1)) * (Layout.columnWidth - Layout.nodeWidth)
      ),
      height: max(
        visibleHeight,
        Layout.margin * 2 + CGFloat(maxRows) * Layout.nodeHeight + CGFloat(max(0, maxRows - 1)) * (Layout.rowHeight - Layout.nodeHeight)
      )
    )
    return NSSize(width: baseSize.width * zoomScale, height: baseSize.height * zoomScale)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawBackground()
    guard let model else {
      return
    }
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.scaleX(by: zoomScale, yBy: zoomScale)
    transform.concat()
    let frames = nodeFrames(for: model)
    for edge in model.edges {
      draw(edge: edge, frames: frames)
    }
    for node in model.nodes {
      guard let frame = frames[node.id] else {
        continue
      }
      draw(node: node, in: frame, selected: node.id == selectedNodeId)
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let model else {
      return
    }
    let rawLocation = convert(event.locationInWindow, from: nil)
    let location = NSPoint(x: rawLocation.x / zoomScale, y: rawLocation.y / zoomScale)
    let frames = nodeFrames(for: model)
    guard let node = model.nodes.first(where: { frames[$0.id]?.contains(location) == true }),
      let frame = frames[node.id]
    else {
      selectedNodeId = nil
      nodePopover?.close()
      needsDisplay = true
      return
    }
    selectedNodeId = node.id
    needsDisplay = true
    showPopover(for: node, relativeTo: scaledFrame(frame))
  }

  private func scaledFrame(_ frame: NSRect) -> NSRect {
    NSRect(
      x: frame.minX * zoomScale,
      y: frame.minY * zoomScale,
      width: frame.width * zoomScale,
      height: frame.height * zoomScale
    )
  }

  private func drawBackground() {
    NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
    bounds.fill()
    NSColor.separatorColor.withAlphaComponent(0.08).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 0.5
    let spacing = CGFloat(24)
    var x = CGFloat(0)
    while x <= bounds.width {
      path.move(to: NSPoint(x: x, y: 0))
      path.line(to: NSPoint(x: x, y: bounds.height))
      x += spacing
    }
    var y = CGFloat(0)
    while y <= bounds.height {
      path.move(to: NSPoint(x: 0, y: y))
      path.line(to: NSPoint(x: bounds.width, y: y))
      y += spacing
    }
    path.stroke()
  }

  private func nodeFrames(for model: DaemonWorkflowGraphModel) -> [String: NSRect] {
    var frames: [String: NSRect] = [:]
    let grouped = Dictionary(grouping: model.nodes, by: \.depth)
    for depth in grouped.keys.sorted() {
      let nodes = (grouped[depth] ?? []).sorted { first, second in
        (model.nodes.firstIndex(of: first) ?? 0) < (model.nodes.firstIndex(of: second) ?? 0)
      }
      for (row, node) in nodes.enumerated() {
        frames[node.id] = NSRect(
          x: Layout.margin + CGFloat(depth) * Layout.columnWidth,
          y: Layout.margin + CGFloat(row) * Layout.rowHeight,
          width: Layout.nodeWidth,
          height: Layout.nodeHeight
        )
      }
    }
    return frames
  }

  private func draw(edge: DaemonWorkflowGraphModel.Edge, frames: [String: NSRect]) {
    guard let from = frames[edge.from], let to = frames[edge.to] else {
      return
    }
    let start = NSPoint(x: from.maxX, y: from.midY)
    let end = NSPoint(x: to.minX, y: to.midY)
    let path = NSBezierPath()
    path.lineWidth = 1.6
    let forward = end.x >= start.x
    let controlOffset = forward ? max(42, (end.x - start.x) * 0.45) : 56
    path.move(to: start)
    path.curve(
      to: end,
      controlPoint1: NSPoint(x: start.x + controlOffset, y: start.y),
      controlPoint2: NSPoint(x: end.x - controlOffset, y: end.y)
    )
    NSColor.secondaryLabelColor.withAlphaComponent(forward ? 0.72 : 0.5).setStroke()
    path.stroke()
    drawArrowHead(at: end, from: NSPoint(x: end.x - (forward ? 12 : -12), y: end.y))
    if let label = edge.label, !label.isEmpty {
      draw(edgeLabel: label, start: start, end: end)
    }
  }

  private func drawArrowHead(at tip: NSPoint, from previous: NSPoint) {
    let angle = atan2(tip.y - previous.y, tip.x - previous.x)
    let first = NSPoint(
      x: tip.x - Layout.arrowSize * cos(angle - .pi / 6),
      y: tip.y - Layout.arrowSize * sin(angle - .pi / 6)
    )
    let second = NSPoint(
      x: tip.x - Layout.arrowSize * cos(angle + .pi / 6),
      y: tip.y - Layout.arrowSize * sin(angle + .pi / 6)
    )
    let path = NSBezierPath()
    path.move(to: tip)
    path.line(to: first)
    path.line(to: second)
    path.close()
    NSColor.secondaryLabelColor.withAlphaComponent(0.72).setFill()
    path.fill()
  }

  private func draw(edgeLabel label: String, start: NSPoint, end: NSPoint) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph
    ]
    let center = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - Layout.labelHeight - 2)
    let rect = NSRect(x: center.x - 54, y: center.y, width: 108, height: Layout.labelHeight)
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -1), xRadius: 5, yRadius: 5)
    NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
    background.fill()
    label.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
  }

  private func draw(node: DaemonWorkflowGraphModel.Node, in rect: NSRect, selected: Bool) {
    let body = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
    let fillColor = selected
      ? NSColor.controlAccentColor.withAlphaComponent(0.22)
      : NSColor.windowBackgroundColor.withAlphaComponent(0.92)
    fillColor.setFill()
    body.fill()
    (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    body.lineWidth = selected ? 2 : 1
    body.stroke()

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.labelColor
    ]
    node.title.draw(
      with: rect.insetBy(dx: 10, dy: 8),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: titleAttributes
    )

    let detail = [node.role?.rawValue, node.nodeId == node.id ? nil : node.nodeId].compactMap { $0 }.joined(separator: " - ")
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    detail.draw(
      with: NSRect(x: rect.minX + 10, y: rect.minY + 30, width: rect.width - 20, height: 16),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: detailAttributes
    )
  }

  private func showPopover(for node: DaemonWorkflowGraphModel.Node, relativeTo rect: NSRect) {
    nodePopover?.close()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 320, height: 150)
    popover.contentViewController = NSViewController()
    popover.contentViewController?.view = nodeDetailView(for: node)
    nodePopover = popover
    popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
  }

  private func nodeDetailView(for node: DaemonWorkflowGraphModel.Node) -> NSView {
    let title = NSTextField(labelWithString: node.title)
    title.font = .systemFont(ofSize: 14, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    let metadata = NSTextField(labelWithString: [node.role?.rawValue, "node: \(node.nodeId)"].compactMap { $0 }.joined(separator: " - "))
    metadata.textColor = .secondaryLabelColor
    metadata.font = .systemFont(ofSize: 11)
    let description = NSTextField(wrappingLabelWithString: node.description?.isEmpty == false ? node.description ?? "" : "No description")
    description.font = .systemFont(ofSize: 12)
    let outgoing = NSTextField(wrappingLabelWithString: "Outgoing: \(node.outgoingSummary)")
    outgoing.textColor = .secondaryLabelColor
    outgoing.font = .systemFont(ofSize: 11)
    let stack = NSStackView(views: [title, metadata, description, outgoing])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    return container
  }
}
#endif
