#if os(macOS)
import AppKit
import RielaViewer

@MainActor
final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  private let loader = WorkflowViewerLoader()
  private let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let statusLabel = NSTextField(labelWithString: "No workflow loaded")
  private let detailTextView = NSTextView()
  private let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private let detailTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
  private let detailBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
  private var workflowDirectory: String?
  private var sessionStoreRoot: String?
  private var state: WorkflowViewerState?
  private var selectedNodeId: String?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Workflow Viewer"
    super.init(window: window)
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func show(workflowDirectory: String, sessionStoreRoot: String?) {
    if self.workflowDirectory != workflowDirectory {
      selectedNodeId = nil
    }
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    refresh()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func buildContent(in window: NSWindow) {
    let splitView = NSSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.translatesAutoresizingMaskIntoConstraints = false

    outlineView.headerView = nil
    outlineView.dataSource = self
    outlineView.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workflow-node"))
    column.title = "Workflow"
    column.width = 360
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column

    let outlineScroll = NSScrollView()
    outlineScroll.documentView = outlineView
    outlineScroll.hasVerticalScroller = true
    outlineScroll.hasHorizontalScroller = true
    outlineScroll.translatesAutoresizingMaskIntoConstraints = false
    outlineScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

    let rightStack = NSStackView()
    rightStack.orientation = .vertical
    rightStack.alignment = .leading
    rightStack.spacing = 8
    rightStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    rightStack.translatesAutoresizingMaskIntoConstraints = false

    let toolbar = NSStackView()
    toolbar.orientation = .horizontal
    toolbar.alignment = .centerY
    toolbar.spacing = 8
    let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshButtonPressed))
    sessionPopup.target = self
    sessionPopup.action = #selector(sessionSelectionChanged)
    sessionPopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
    toolbar.addArrangedSubview(NSTextField(labelWithString: "Session"))
    toolbar.addArrangedSubview(sessionPopup)
    toolbar.addArrangedSubview(refreshButton)

    statusLabel.lineBreakMode = .byTruncatingTail
    detailTextView.isEditable = false
    detailTextView.isRichText = false
    detailTextView.font = detailFont
    detailTextView.textColor = detailTextColor
    detailTextView.backgroundColor = detailBackgroundColor
    detailTextView.drawsBackground = true
    detailTextView.textContainerInset = NSSize(width: 10, height: 10)
    detailTextView.isVerticallyResizable = true
    detailTextView.isHorizontallyResizable = true
    detailTextView.autoresizingMask = [.width]
    detailTextView.textContainer?.widthTracksTextView = true
    detailTextView.textContainer?.containerSize = NSSize(
      width: detailScrollContentWidthFallback,
      height: CGFloat.greatestFiniteMagnitude
    )
    let detailScroll = NSScrollView()
    detailScroll.documentView = detailTextView
    detailScroll.hasVerticalScroller = true
    detailScroll.hasHorizontalScroller = true
    detailScroll.borderType = .bezelBorder
    detailScroll.translatesAutoresizingMaskIntoConstraints = false

    rightStack.addArrangedSubview(toolbar)
    rightStack.addArrangedSubview(statusLabel)
    rightStack.addArrangedSubview(detailScroll)
    detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true

    splitView.addArrangedSubview(outlineScroll)
    splitView.addArrangedSubview(rightStack)
    window.contentView = splitView
    splitView.setPosition(360, ofDividerAt: 0)
  }

  @objc private func refreshButtonPressed() {
    refresh()
  }

  @objc private func sessionSelectionChanged() {
    guard let workflowDirectory, let state, sessionPopup.indexOfSelectedItem >= 0,
      sessionPopup.indexOfSelectedItem < state.sessions.count
    else {
      return
    }
    let selected = state.sessions[sessionPopup.indexOfSelectedItem]
    do {
      self.state = try loader.load(WorkflowViewerLoadRequest(
        workflowDirectory: workflowDirectory,
        sessionStoreRoot: state.sessionStoreRoot,
        selectedSessionId: selected.sessionId
      ))
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      statusLabel.stringValue = "Failed to switch session: \(error)"
    }
  }

  private func refresh() {
    guard let workflowDirectory else {
      return
    }
    do {
      let previouslySelectedSessionId = state?.selectedSessionId
      let loaded = try loader.load(WorkflowViewerLoadRequest(
        workflowDirectory: workflowDirectory,
        sessionStoreRoot: sessionStoreRoot,
        selectedSessionId: previouslySelectedSessionId
      ))
      state = loaded
      selectedNodeId = selectedNodeId ?? loaded.workflow.entryStepId
      sessionPopup.removeAllItems()
      if loaded.sessions.isEmpty {
        sessionPopup.addItem(withTitle: "No sessions")
        sessionPopup.isEnabled = false
      } else {
        sessionPopup.addItems(withTitles: loaded.sessions.map { sessionTitle($0) })
        sessionPopup.selectItem(at: 0)
        sessionPopup.isEnabled = true
      }
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      statusLabel.stringValue = "Failed to load viewer: \(error)"
      setDetailText("\(error)")
    }
  }

  private func updateDetails() {
    guard let state else {
      statusLabel.stringValue = "No workflow loaded"
      setDetailText("")
      return
    }
    let session = selectedSession(in: state)
    statusLabel.stringValue = [
      "Workflow: \(state.workflow.workflowId)",
      "Sessions: \(state.sessions.count)",
      session.map { "Selected: \($0.sessionId) (\($0.status.rawValue))" }
    ].compactMap { $0 }.joined(separator: " | ")
    guard let selectedNodeId else {
      setDetailText(workflowOverview(state: state))
      return
    }
    var lines: [String] = []
    lines.append("Node: \(selectedNodeId)")
    if let node = flattenedNodes(state.nodes).first(where: { $0.id == selectedNodeId }) {
      lines.append("Runtime: \(node.state.rawValue)")
      lines.append("Node ID: \(node.nodeId)")
      if let detail = node.detail {
        lines.append("Detail: \(detail)")
      }
    }
    lines.append("")
    lines.append("Workflow")
    lines.append(workflowOverview(state: state))
    if state.sessions.isEmpty {
      lines.append("")
      lines.append("Sessions")
      lines.append("No persisted sessions found for this workflow.")
      lines.append("Searched:")
      lines.append(contentsOf: state.sessionStoreCandidates.map { "- \($0)" })
    }
    if !state.diagnostics.isEmpty {
      lines.append("")
      lines.append("Diagnostics")
      lines.append(contentsOf: state.diagnostics.map { "- \($0)" })
    }
    if let session {
      do {
        let messages = try loader.nodeMessages(
          stepId: selectedNodeId,
          sessionId: session.sessionId,
          sessionStoreRoot: state.sessionStoreRoot
        )
        lines.append("")
        lines.append("Inbox")
        lines.append(contentsOf: render(messages.inbox))
        lines.append("")
        lines.append("Outbox")
        lines.append(contentsOf: render(messages.outbox))
      } catch {
        lines.append("")
        lines.append("Messages failed to load: \(error)")
      }
    }
    setDetailText(lines.joined(separator: "\n"))
  }

  private func setDetailText(_ text: String) {
    detailTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  private var detailScrollContentWidthFallback: CGFloat {
    520
  }

  private func selectedSession(in state: WorkflowViewerState) -> WorkflowViewerSessionSummary? {
    guard let selectedSessionId = state.selectedSessionId else {
      return nil
    }
    return state.sessions.first { $0.sessionId == selectedSessionId }
  }

  private func workflowOverview(state: WorkflowViewerState) -> String {
    [
      "id: \(state.workflow.workflowId)",
      "entry: \(state.workflow.entryStepId)",
      "description: \(state.workflow.description.isEmpty ? "-" : state.workflow.description)",
      "steps: \(state.workflow.steps.count)",
      "sessionStore: \(state.sessionStoreRoot)"
    ].joined(separator: "\n")
  }

  private func render(_ messages: [WorkflowViewerMessage]) -> [String] {
    guard !messages.isEmpty else {
      return ["(none)"]
    }
    return messages.map { message in
      [
        "- \(message.id) [\(message.status.rawValue)]",
        "  from: \(message.fromStepId ?? "-")",
        "  to: \(message.toStepId ?? "-")",
        "  payload: \(message.payloadPreview)"
      ].joined(separator: "\n")
    }
  }

  private func sessionTitle(_ summary: WorkflowViewerSessionSummary) -> String {
    let active = summary.activeStepIds.isEmpty ? "" : " active: \(summary.activeStepIds.joined(separator: ","))"
    return "\(summary.sessionId) - \(summary.status.rawValue)\(active)"
  }

  private func flattenedNodes(_ nodes: [WorkflowViewerNode]) -> [WorkflowViewerNode] {
    nodes.flatMap { [$0] + flattenedNodes($0.children) }
  }

  private func expandAll() {
    for node in state?.nodes ?? [] {
      outlineView.expandItem(node, expandChildren: true)
    }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let node = item as? WorkflowViewerNode {
      return node.children.count
    }
    return state?.nodes.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let node = item as? WorkflowViewerNode {
      return node.children[index]
    }
    return state?.nodes[index] ?? WorkflowViewerNode(id: "missing", nodeId: "missing", title: "missing", state: .failed)
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? WorkflowViewerNode)?.children.isEmpty == false
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? WorkflowViewerNode else {
      return nil
    }
    let identifier = NSUserInterfaceItemIdentifier("workflow-node-cell")
    let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
    cell.identifier = identifier
    let field = cell.textField ?? NSTextField(labelWithString: "")
    field.translatesAutoresizingMaskIntoConstraints = false
    if field.superview == nil {
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }
    field.stringValue = "\(stateMarker(node.state)) \(node.title)"
    field.textColor = color(for: node.state)
    field.font = node.state == .active ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
    return cell
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? WorkflowViewerNode else {
      return
    }
    selectedNodeId = node.id
    updateDetails()
  }

  private func stateMarker(_ state: WorkflowViewerNodeRuntimeState) -> String {
    switch state {
    case .active:
      "[Running]"
    case .completed:
      "[Completed]"
    case .failed:
      "[Failed]"
    case .idle:
      "[Idle]"
    }
  }

  private func color(for state: WorkflowViewerNodeRuntimeState) -> NSColor {
    switch state {
    case .active:
      .systemGreen
    case .completed:
      .secondaryLabelColor
    case .failed:
      .systemRed
    case .idle:
      .labelColor
    }
  }
}
#endif
