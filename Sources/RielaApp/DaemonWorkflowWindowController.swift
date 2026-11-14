#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

@MainActor
final class DaemonWorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  private enum Column {
    static let workflow = NSUserInterfaceItemIdentifier("workflow")
    static let sources = NSUserInterfaceItemIdentifier("sources")
    static let active = NSUserInterfaceItemIdentifier("active")
    static let runtime = NSUserInterfaceItemIdentifier("runtime")
  }

  private let enabledTable = NSTableView()
  private let disabledTable = NSTableView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let onRefresh: () -> Void
  private let onSetEnabled: (String, Bool) -> Void
  private let onToggleActive: (String) -> Void

  private var candidates: [RielaAppDaemonWorkflowCandidate] = []
  private var state = RielaAppDaemonWorkflowState()
  private var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]

  init(
    onRefresh: @escaping () -> Void,
    onSetEnabled: @escaping (String, Bool) -> Void,
    onToggleActive: @escaping (String) -> Void
  ) {
    self.onRefresh = onRefresh
    self.onSetEnabled = onSetEnabled
    self.onToggleActive = onToggleActive
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Daemon Workflows"
    super.init(window: window)
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(
    candidates: [RielaAppDaemonWorkflowCandidate],
    state: RielaAppDaemonWorkflowState,
    snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot]
  ) {
    self.candidates = candidates
    self.state = state
    self.snapshots = snapshots
    enabledTable.reloadData()
    disabledTable.reloadData()
    let enabledCount = enabledCandidates.count
    let activeCount = enabledCandidates.filter { state.preference(for: $0.id).active }.count
    statusLabel.stringValue = "\(activeCount) active / \(enabledCount) enabled / \(disabledCandidates.count) disabled"
  }

  private var enabledCandidates: [RielaAppDaemonWorkflowCandidate] {
    candidates.filter { state.preference(for: $0.id).enabledAtLaunch }
  }

  private var disabledCandidates: [RielaAppDaemonWorkflowCandidate] {
    candidates.filter { !state.preference(for: $0.id).enabledAtLaunch }
  }

  private func buildContent(in window: NSWindow) {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = root

    let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
    let enableButton = NSButton(title: "Enable", target: self, action: #selector(enableSelected))
    let disableButton = NSButton(title: "Disable", target: self, action: #selector(disableSelected))
    let toggleButton = NSButton(title: "Toggle Active", target: self, action: #selector(toggleSelectedActive))
    let toolbar = NSStackView(views: [refreshButton, enableButton, disableButton, toggleButton, statusLabel])
    toolbar.orientation = .horizontal
    toolbar.spacing = 10
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let enabledBox = box(title: "Enabled at Launch", table: enabledTable)
    let disabledBox = box(title: "Disabled", table: disabledTable)
    let split = NSStackView(views: [enabledBox, disabledBox])
    split.orientation = .horizontal
    split.distribution = .fillEqually
    split.spacing = 14
    split.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(toolbar)
    root.addSubview(split)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
    ])
  }

  private func box(title: String, table: NSTableView) -> NSBox {
    table.delegate = self
    table.dataSource = self
    table.usesAlternatingRowBackgroundColors = true
    table.rowHeight = 28
    table.action = #selector(tableClicked(_:))
    table.target = self
    table.headerView = NSTableHeaderView()
    addColumn(Column.workflow, title: "Workflow", width: 150, to: table)
    addColumn(Column.sources, title: "Sources", width: 190, to: table)
    addColumn(Column.active, title: "Active", width: 82, to: table)
    addColumn(Column.runtime, title: "Runtime", width: 160, to: table)

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let box = NSBox()
    box.title = title
    box.contentView = scroll
    return box
  }

  private func addColumn(
    _ identifier: NSUserInterfaceItemIdentifier,
    title: String,
    width: CGFloat,
    to table: NSTableView
  ) {
    let column = NSTableColumn(identifier: identifier)
    column.title = title
    column.width = width
    table.addTableColumn(column)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows(for: tableView).count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let tableColumn else {
      return nil
    }
    let cell = NSTableCellView()
    let text = NSTextField(labelWithString: value(for: tableView, column: tableColumn.identifier, row: row))
    text.lineBreakMode = .byTruncatingMiddle
    text.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    if tableColumn.identifier == Column.active, tableView == enabledTable {
      text.textColor = NSColor.controlAccentColor
    } else if tableColumn.identifier == Column.runtime {
      text.textColor = runtimeColor(for: rows(for: tableView)[row].id)
    }
    return cell
  }

  private func value(for tableView: NSTableView, column: NSUserInterfaceItemIdentifier, row: Int) -> String {
    let candidate = rows(for: tableView)[row]
    switch column {
    case Column.workflow:
      return candidate.displayName
    case Column.sources:
      return candidate.eventSourceSummary
    case Column.active:
      return state.preference(for: candidate.id).active ? "Active" : "Inactive"
    case Column.runtime:
      return snapshots[candidate.id]?.detail ?? "Inactive"
    default:
      return ""
    }
  }

  private func runtimeColor(for identity: String) -> NSColor {
    switch snapshots[identity]?.status {
    case .running:
      .systemGreen
    case .failed:
      .systemRed
    case .starting, .reloading, .stopping:
      .systemOrange
    case .stopped, nil:
      .secondaryLabelColor
    }
  }

  private func rows(for tableView: NSTableView) -> [RielaAppDaemonWorkflowCandidate] {
    tableView == enabledTable ? enabledCandidates : disabledCandidates
  }

  @objc private func refresh() {
    onRefresh()
  }

  @objc private func enableSelected() {
    guard let candidate = selectedCandidate(in: disabledTable) else {
      return
    }
    onSetEnabled(candidate.id, true)
  }

  @objc private func disableSelected() {
    guard let candidate = selectedCandidate(in: enabledTable) else {
      return
    }
    onSetEnabled(candidate.id, false)
  }

  @objc private func toggleSelectedActive() {
    guard let candidate = selectedCandidate(in: enabledTable) else {
      return
    }
    onToggleActive(candidate.id)
  }

  @objc private func tableClicked(_ sender: NSTableView) {
    guard sender == enabledTable, sender.clickedColumn >= 0 else {
      return
    }
    let column = sender.tableColumns[sender.clickedColumn]
    guard column.identifier == Column.active, let candidate = selectedCandidate(in: sender) else {
      return
    }
    onToggleActive(candidate.id)
  }

  private func selectedCandidate(in tableView: NSTableView) -> RielaAppDaemonWorkflowCandidate? {
    let row = tableView.selectedRow
    guard row >= 0 else {
      return nil
    }
    let candidates = rows(for: tableView)
    guard candidates.indices.contains(row) else {
      return nil
    }
    return candidates[row]
  }
}
#endif
