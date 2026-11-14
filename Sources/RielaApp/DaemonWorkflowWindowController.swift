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
  private let profilePopup = NSPopUpButton()
  private let profileField = NSTextField()
  private let statusLabel = NSTextField(labelWithString: "")
  private let onRefresh: () -> Void
  private let onSelectProfile: (String) -> Void
  private let onAddDirectory: () -> Void
  private let onRemoveDirectory: (String) -> Void
  private let onSetEnabled: (String, Bool) -> Void
  private let onSetActive: (String, Bool) -> Void

  private var candidates: [RielaAppDaemonWorkflowCandidate] = []
  private var state = RielaAppDaemonWorkflowState()
  private var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]
  private var profileName = RielaAppProfileName.default
  private var profileNames: [RielaAppProfileName] = [.default]
  private var isUpdatingProfileControls = false

  init(
    onRefresh: @escaping () -> Void,
    onSelectProfile: @escaping (String) -> Void,
    onAddDirectory: @escaping () -> Void,
    onRemoveDirectory: @escaping (String) -> Void,
    onSetEnabled: @escaping (String, Bool) -> Void,
    onSetActive: @escaping (String, Bool) -> Void
  ) {
    self.onRefresh = onRefresh
    self.onSelectProfile = onSelectProfile
    self.onAddDirectory = onAddDirectory
    self.onRemoveDirectory = onRemoveDirectory
    self.onSetEnabled = onSetEnabled
    self.onSetActive = onSetActive
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Workflows"
    super.init(window: window)
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(
    profileName: RielaAppProfileName,
    profileNames: [RielaAppProfileName],
    candidates: [RielaAppDaemonWorkflowCandidate],
    state: RielaAppDaemonWorkflowState,
    snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot]
  ) {
    self.profileName = profileName
    self.profileNames = profileNames
    self.candidates = candidates
    self.state = state
    self.snapshots = snapshots
    updateProfileControls()
    enabledTable.reloadData()
    disabledTable.reloadData()
    let startWithAppCount = enabledCandidates.count
    let runningCount = candidates.filter { state.preference(for: $0.id).active }.count
    statusLabel.stringValue = [
      "Profile: \(profileName.rawValue)",
      "\(runningCount) running now",
      "\(startWithAppCount) start with RielaApp",
      "\(disabledCandidates.count) available"
    ].joined(separator: " | ")
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

    let profileLabel = NSTextField(labelWithString: "Profile")
    profilePopup.target = self
    profilePopup.action = #selector(profilePopupChanged)
    profilePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
    profileField.placeholderString = RielaAppProfileName.defaultRawValue
    profileField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    let useProfileButton = NSButton(title: "Use Profile", target: self, action: #selector(useTypedProfile))
    let addButton = NSButton(title: "Add Workflow...", target: self, action: #selector(addDirectory))
    let removeButton = NSButton(title: "Remove Workflow", target: self, action: #selector(removeSelectedDirectory))
    let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
    let startButton = NSButton(title: "Start Now", target: self, action: #selector(startSelectedNow))
    let stopButton = NSButton(title: "Stop Now", target: self, action: #selector(stopSelectedNow))
    let enableButton = NSButton(title: "Start with App", target: self, action: #selector(enableSelected))
    let disableButton = NSButton(title: "Do Not Start with App", target: self, action: #selector(disableSelected))
    statusLabel.lineBreakMode = .byTruncatingTail
    let profileRow = NSStackView(views: [
      profileLabel,
      profilePopup,
      profileField,
      useProfileButton,
      statusLabel
    ])
    profileRow.orientation = .horizontal
    profileRow.spacing = 10
    let actionRow = NSStackView(views: [
      addButton,
      removeButton,
      refreshButton,
      startButton,
      stopButton,
      enableButton,
      disableButton
    ])
    actionRow.orientation = .horizontal
    actionRow.spacing = 10
    let toolbar = NSStackView(views: [
      profileRow,
      actionRow
    ])
    toolbar.alignment = .leading
    toolbar.orientation = .vertical
    toolbar.spacing = 8
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let enabledBox = box(title: "Starts with RielaApp", table: enabledTable)
    let disabledBox = box(title: "Available Workflows", table: disabledTable)
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
    addColumn(Column.sources, title: "Event Sources", width: 190, to: table)
    addColumn(Column.active, title: "Running Now", width: 110, to: table)
    addColumn(Column.runtime, title: "Status", width: 160, to: table)

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
      return state.preference(for: candidate.id).active ? "Yes" : "No"
    case Column.runtime:
      return snapshots[candidate.id]?.detail ?? "Stopped"
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

  @objc private func profilePopupChanged() {
    guard !isUpdatingProfileControls, let title = profilePopup.selectedItem?.title else {
      return
    }
    onSelectProfile(title)
  }

  @objc private func useTypedProfile() {
    onSelectProfile(profileField.stringValue)
  }

  @objc private func addDirectory() {
    onAddDirectory()
  }

  @objc private func removeSelectedDirectory() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onRemoveDirectory(candidate.id)
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

  @objc private func startSelectedNow() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetActive(candidate.id, true)
  }

  @objc private func stopSelectedNow() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetActive(candidate.id, false)
  }

  @objc private func tableClicked(_ sender: NSTableView) {
    guard sender == enabledTable, sender.clickedColumn >= 0 else {
      return
    }
    let column = sender.tableColumns[sender.clickedColumn]
    guard column.identifier == Column.active, let candidate = selectedCandidate(in: sender) else {
      return
    }
    onSetActive(candidate.id, !state.preference(for: candidate.id).active)
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

  private func updateProfileControls() {
    isUpdatingProfileControls = true
    profilePopup.removeAllItems()
    profilePopup.addItems(withTitles: profileNames.map(\.rawValue))
    profilePopup.selectItem(withTitle: profileName.rawValue)
    profileField.stringValue = profileName.rawValue
    isUpdatingProfileControls = false
  }
}
#endif
