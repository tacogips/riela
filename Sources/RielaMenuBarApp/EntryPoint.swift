#if os(macOS)
import AppKit
import Foundation
import RielaServer
import RielaViewer

@main
@MainActor
final class RielaMenuBarApp: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let controller = WorkflowServingController()
  private var selectedWorkflow: WorkflowServeSelection?
  private var selectedWorkingDirectory = FileManager.default.currentDirectoryPath
  private var status = "Stopped"
  private var viewerWindowController: WorkflowViewerWindowController?

  static func main() {
    let app = NSApplication.shared
    let delegate = RielaMenuBarApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureStatusItem()
    rebuildMenu()
    openInitialViewerIfRequested()
  }

  private func configureStatusItem() {
    statusItem.button?.title = "Riela"
    statusItem.button?.toolTip = "Riela workflow serving client"
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Select Workflow...", action: #selector(selectWorkflow)))
    menu.addItem(menuItem("Serve", action: #selector(serveWorkflow), enabled: selectedWorkflow != nil))
    menu.addItem(menuItem("Stop", action: #selector(stopWorkflow)))
    menu.addItem(menuItem("Restart", action: #selector(restartWorkflow)))
    menu.addItem(menuItem("Update", action: #selector(updateWorkflow)))
    menu.addItem(menuItem("Open Viewer", action: #selector(openViewer), enabled: selectedWorkflow?.path != nil))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Status: \(status)", action: nil, keyEquivalent: ""))
    if let selectedWorkflow {
      menu.addItem(NSMenuItem(title: "Workflow: \(selectedWorkflow.identifier)", action: nil, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Quit", action: #selector(quit)))
    statusItem.menu = menu
  }

  private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    return item
  }

  @objc private func selectWorkflow() {
    let panel = NSOpenPanel()
    panel.title = "Select Riela Workflow"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    selectedWorkflow = .directDirectory(url.path, identifier: url.lastPathComponent)
    selectedWorkingDirectory = url.deletingLastPathComponent().path
    status = "Selected"
    rebuildMenu()
  }

  @objc private func serveWorkflow() {
    guard let selectedWorkflow else {
      return
    }
    Task { @MainActor in
      do {
        let state = try await controller.start(WorkflowServeStartRequest(
          selection: selectedWorkflow,
          workingDirectory: selectedWorkingDirectory
        ))
        apply(state)
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func stopWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.stop())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func restartWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.restart())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func updateWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.reload(WorkflowServeReloadRequest()))
      } catch {
        let current = await controller.currentState()
        status = current.status == .running ? "Update failed, still running" : "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func openViewer() {
    guard let path = selectedWorkflow?.path else {
      selectWorkflow()
      return
    }
    let sessionStoreRoot = URL(fileURLWithPath: selectedWorkingDirectory, isDirectory: true)
      .appendingPathComponent(".riela/sessions", isDirectory: true)
      .path
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(workflowDirectory: path, sessionStoreRoot: sessionStoreRoot)
  }

  private func openInitialViewerIfRequested() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let optionIndex = arguments.firstIndex(of: "--open-viewer"),
      arguments.indices.contains(optionIndex + 1)
    else {
      return
    }
    let path = arguments[optionIndex + 1]
    selectedWorkflow = .directDirectory(path, identifier: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent)
    selectedWorkingDirectory = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent().path
    status = "Selected"
    rebuildMenu()
    openViewer()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func apply(_ state: WorkflowServeState) {
    switch state.status {
    case .running:
      status = "Running"
    case .stopped:
      status = "Stopped"
    case .starting:
      status = "Starting"
    case .reloading:
      status = "Updating"
    case .stopping:
      status = "Stopping"
    case .failed:
      status = state.diagnostics.first?.message ?? "Failed"
    }
    rebuildMenu()
  }
}

@MainActor
private final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  private let loader = WorkflowViewerLoader()
  private let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let statusLabel = NSTextField(labelWithString: "No workflow loaded")
  private let detailTextView = NSTextView()
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

  func show(workflowDirectory: String, sessionStoreRoot: String) {
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
    toolbar.addArrangedSubview(NSTextField(labelWithString: "Session"))
    toolbar.addArrangedSubview(sessionPopup)
    toolbar.addArrangedSubview(refreshButton)

    statusLabel.lineBreakMode = .byTruncatingTail
    detailTextView.isEditable = false
    detailTextView.isRichText = false
    detailTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let detailScroll = NSScrollView()
    detailScroll.documentView = detailTextView
    detailScroll.hasVerticalScroller = true
    detailScroll.hasHorizontalScroller = true
    detailScroll.translatesAutoresizingMaskIntoConstraints = false

    rightStack.addArrangedSubview(toolbar)
    rightStack.addArrangedSubview(statusLabel)
    rightStack.addArrangedSubview(detailScroll)
    detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true

    splitView.addArrangedSubview(outlineScroll)
    splitView.addArrangedSubview(rightStack)
    window.contentView = splitView
  }

  @objc private func refreshButtonPressed() {
    refresh()
  }

  @objc private func sessionSelectionChanged() {
    guard let workflowDirectory, let sessionStoreRoot, let state, sessionPopup.indexOfSelectedItem >= 0 else {
      return
    }
    let selected = state.sessions[sessionPopup.indexOfSelectedItem]
    do {
      self.state = try loader.load(WorkflowViewerLoadRequest(
        workflowDirectory: workflowDirectory,
        sessionStoreRoot: sessionStoreRoot,
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
    guard let workflowDirectory, let sessionStoreRoot else {
      return
    }
    do {
      let loaded = try loader.load(WorkflowViewerLoadRequest(workflowDirectory: workflowDirectory, sessionStoreRoot: sessionStoreRoot))
      state = loaded
      selectedNodeId = selectedNodeId ?? loaded.workflow.entryStepId
      sessionPopup.removeAllItems()
      sessionPopup.addItems(withTitles: loaded.sessions.map { sessionTitle($0) })
      if !loaded.sessions.isEmpty {
        sessionPopup.selectItem(at: 0)
      }
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      statusLabel.stringValue = "Failed to load viewer: \(error)"
      detailTextView.string = "\(error)"
    }
  }

  private func updateDetails() {
    guard let state else {
      statusLabel.stringValue = "No workflow loaded"
      detailTextView.string = ""
      return
    }
    let session = selectedSession(in: state)
    statusLabel.stringValue = [
      "Workflow: \(state.workflow.workflowId)",
      "Sessions: \(state.sessions.count)",
      session.map { "Selected: \($0.sessionId) (\($0.status.rawValue))" }
    ].compactMap { $0 }.joined(separator: " | ")
    guard let selectedNodeId else {
      detailTextView.string = workflowOverview(state: state)
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
    detailTextView.string = lines.joined(separator: "\n")
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
      "RUN"
    case .completed:
      "OK"
    case .failed:
      "FAIL"
    case .idle:
      "--"
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

#else
@main
struct RielaMenuBarAppUnsupported {
  static func main() {
    print("RielaMenuBarApp is available on macOS only.")
  }
}
#endif
