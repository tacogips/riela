#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

@MainActor
final class DaemonWorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  private enum Column {
    static let workflow = NSUserInterfaceItemIdentifier("workflow")
    static let source = NSUserInterfaceItemIdentifier("source")
    static let environment = NSUserInterfaceItemIdentifier("environment")
    static let active = NSUserInterfaceItemIdentifier("active")
    static let runtime = NSUserInterfaceItemIdentifier("runtime")
  }

  private let enabledTable = NSTableView()
  private let disabledTable = NSTableView()
  private let profilePopup = NSPopUpButton()
  private let profileField = NSTextField()
  private let statusLabel = NSTextField(labelWithString: "")
  private let actionStatusLabel = NSTextField(labelWithString: "Last Action: Ready")
  private let selectionDetailLabel = NSTextField(labelWithString: "")
  private let viewWorkflowButton = NSButton(title: "Edit Selected", target: nil, action: nil)
  private let revealSourceButton = NSButton(title: "Reveal Selected", target: nil, action: nil)
  private let duplicateButton = NSButton(title: "Duplicate Instance", target: nil, action: nil)
  private let renameButton = NSButton(title: "Rename ID...", target: nil, action: nil)
  private let addListButton = NSButton(title: "+", target: nil, action: nil)
  private let removeListButton = NSButton(title: "-", target: nil, action: nil)
  private let enableButton = NSButton(title: "Enable", target: nil, action: nil)
  private let disableButton = NSButton(title: "Disable", target: nil, action: nil)
  private let setEnvironmentButton = NSButton(title: "Env File...", target: nil, action: nil)
  private let setEnvironmentVariablesButton = NSButton(title: "Env Vars...", target: nil, action: nil)
  private let setWorkingDirectoryButton = NSButton(title: "Working Dir...", target: nil, action: nil)
  private let setVariablesButton = NSButton(title: "Variables...", target: nil, action: nil)
  private let onRefresh: () -> Void
  private let onSelectProfile: (String) -> Void
  private let onAddDirectory: () -> Void
  private let onAddProject: () -> Void
  private let onOpenProfileFolder: () -> Void
  private let onViewSelectedWorkflow: (String) -> Void
  private let onRevealSelectedSource: (String) -> Void
  private let onDuplicateWorkflow: (String) -> Void
  private let onRenameWorkflow: (String) -> Void
  private let onRemoveDirectory: (String) -> Void
  private let onSetEnabled: (String, Bool) -> Void
  private let onSetActive: (String, Bool) -> Void
  private let onSetEnvironment: (String) -> Void
  private let onSetEnvironmentVariables: (String) -> Void
  private let onSetWorkingDirectory: (String) -> Void
  private let onSetVariables: (String) -> Void
  private let environmentSummary: (RielaAppDaemonWorkflowCandidate) -> String
  private let environmentColumnStatus: (RielaAppDaemonWorkflowCandidate) -> String

  private var candidates: [RielaAppDaemonWorkflowCandidate] = []
  private var state = RielaAppDaemonWorkflowState()
  private var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]
  private var profileName = RielaAppProfileName.default
  private var profileNames: [RielaAppProfileName] = [.default]
  private var selectedIdentity: String?
  private var selectedIdentityByProfile: [RielaAppProfileName: String] = [:]
  private var isUpdatingProfileControls = false
  private var isUpdatingTableSelection = false

  init(
    onRefresh: @escaping () -> Void,
    onSelectProfile: @escaping (String) -> Void,
    onAddDirectory: @escaping () -> Void,
    onAddProject: @escaping () -> Void,
    onOpenProfileFolder: @escaping () -> Void,
    onViewSelectedWorkflow: @escaping (String) -> Void,
    onRevealSelectedSource: @escaping (String) -> Void,
    onDuplicateWorkflow: @escaping (String) -> Void,
    onRenameWorkflow: @escaping (String) -> Void,
    onRemoveDirectory: @escaping (String) -> Void,
    onSetEnabled: @escaping (String, Bool) -> Void,
    onSetActive: @escaping (String, Bool) -> Void,
    onSetEnvironment: @escaping (String) -> Void,
    onSetEnvironmentVariables: @escaping (String) -> Void,
    onSetWorkingDirectory: @escaping (String) -> Void,
    onSetVariables: @escaping (String) -> Void,
    environmentSummary: @escaping (RielaAppDaemonWorkflowCandidate) -> String,
    environmentColumnStatus: @escaping (RielaAppDaemonWorkflowCandidate) -> String
  ) {
    self.onRefresh = onRefresh
    self.onSelectProfile = onSelectProfile
    self.onAddDirectory = onAddDirectory
    self.onAddProject = onAddProject
    self.onOpenProfileFolder = onOpenProfileFolder
    self.onViewSelectedWorkflow = onViewSelectedWorkflow
    self.onRevealSelectedSource = onRevealSelectedSource
    self.onDuplicateWorkflow = onDuplicateWorkflow
    self.onRenameWorkflow = onRenameWorkflow
    self.onRemoveDirectory = onRemoveDirectory
    self.onSetEnabled = onSetEnabled
    self.onSetActive = onSetActive
    self.onSetEnvironment = onSetEnvironment
    self.onSetEnvironmentVariables = onSetEnvironmentVariables
    self.onSetWorkingDirectory = onSetWorkingDirectory
    self.onSetVariables = onSetVariables
    self.environmentSummary = environmentSummary
    self.environmentColumnStatus = environmentColumnStatus
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 560),
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
    snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot],
    statusMessage: String
  ) {
    let didChangeProfile = self.profileName != profileName
    self.profileName = profileName
    self.profileNames = profileNames
    self.candidates = candidates
    self.state = state
    self.snapshots = snapshots
    if didChangeProfile || selectedIdentity == nil {
      selectedIdentity = selectedIdentityByProfile[profileName]
    }
    updateProfileControls()
    enabledTable.reloadData()
    disabledTable.reloadData()
    restoreSelection()
    updateSelectionDetail()
    updateSelectionActionStates()
    actionStatusLabel.stringValue = "Last Action: \(statusMessage)"
    if candidates.isEmpty {
      statusLabel.stringValue = "Profile: \(profileName.rawValue) | no workflows | use + to add a workflow or project"
      return
    }
    let availableCount = enabledCandidates.count
    let runningCount = candidates.filter { candidate in
      snapshots[candidate.id]?.status == .running
    }.count
    let activeCount = candidates.filter { state.preference(for: $0.id).active }.count
    let profileScopedCount = candidates.filter(\.isRielaAppProfileScoped).count
    let externalCount = candidates.count - profileScopedCount
    statusLabel.stringValue = [
      "Profile: \(profileName.rawValue)",
      "\(runningCount) running",
      "\(availableCount) enabled",
      "\(activeCount) active",
      "\(disabledCandidates.count) disabled",
      "\(profileScopedCount) in profile",
      "\(externalCount) external"
    ].joined(separator: " | ")
  }

  private var enabledCandidates: [RielaAppDaemonWorkflowCandidate] {
    candidates.filter { state.preference(for: $0.id).available }
  }

  private var disabledCandidates: [RielaAppDaemonWorkflowCandidate] {
    candidates.filter { !state.preference(for: $0.id).available }
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
    let useProfileButton = NSButton(title: "Switch/Create", target: self, action: #selector(useTypedProfile))
    let openProfileButton = NSButton(title: "Open Profile Folder", target: self, action: #selector(openProfileFolder))
    let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
    viewWorkflowButton.target = self
    viewWorkflowButton.action = #selector(viewSelectedWorkflow)
    revealSourceButton.target = self
    revealSourceButton.action = #selector(revealSelectedSource)
    duplicateButton.target = self
    duplicateButton.action = #selector(duplicateSelectedWorkflow)
    renameButton.target = self
    renameButton.action = #selector(renameSelectedWorkflow)
    addListButton.target = self
    addListButton.action = #selector(addListButtonPressed)
    removeListButton.target = self
    removeListButton.action = #selector(removeSelectedDirectory)
    enableButton.target = self
    enableButton.action = #selector(enableSelected)
    disableButton.target = self
    disableButton.action = #selector(disableSelected)
    setEnvironmentButton.target = self
    setEnvironmentButton.action = #selector(setSelectedEnvironment)
    setEnvironmentVariablesButton.target = self
    setEnvironmentVariablesButton.action = #selector(setSelectedEnvironmentVariables)
    setWorkingDirectoryButton.target = self
    setWorkingDirectoryButton.action = #selector(setSelectedWorkingDirectory)
    setVariablesButton.target = self
    setVariablesButton.action = #selector(setSelectedVariables)
    useProfileButton.toolTip = "Switch to the typed profile name, creating it if needed."
    openProfileButton.toolTip = "Open this profile's workflows, packages, and daemon state in Finder."
    viewWorkflowButton.toolTip = "Open the selected workflow edit view."
    revealSourceButton.toolTip = "Reveal the selected workflow, package, or project source in Finder."
    duplicateButton.toolTip = "Create another managed instance from the selected source workflow."
    renameButton.toolTip = "Change the selected managed instance id and display name."
    addListButton.toolTip = "Add a workflow, package, or project to this profile."
    removeListButton.toolTip = "Remove the selected profile import or project reference."
    enableButton.toolTip = "Enable the selected disabled workflow or package for this profile."
    disableButton.toolTip = "Disable the selected enabled workflow or package for this profile."
    setEnvironmentButton.toolTip = "Select a credential .env file for the selected workflow."
    setEnvironmentVariablesButton.toolTip = "Edit inline environment variables for this managed workflow instance."
    setWorkingDirectoryButton.toolTip = "Choose the current directory used when this managed workflow runs."
    setVariablesButton.toolTip = "Edit workflow default variables for this managed workflow instance."
    statusLabel.lineBreakMode = .byTruncatingTail
    actionStatusLabel.lineBreakMode = .byTruncatingMiddle
    actionStatusLabel.textColor = .secondaryLabelColor
    selectionDetailLabel.lineBreakMode = .byTruncatingMiddle
    selectionDetailLabel.textColor = .secondaryLabelColor
    selectionDetailLabel.stringValue = "Selected: None"
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
      openProfileButton,
      viewWorkflowButton,
      revealSourceButton,
      duplicateButton,
      renameButton,
      refreshButton,
      enableButton,
      disableButton,
      setEnvironmentButton,
      setEnvironmentVariablesButton,
      setWorkingDirectoryButton,
      setVariablesButton
    ])
    actionRow.orientation = .horizontal
    actionRow.spacing = 10
    let actionStatusRow = NSStackView(views: [
      actionStatusLabel
    ])
    actionStatusRow.orientation = .horizontal
    actionStatusRow.spacing = 0
    let selectionRow = NSStackView(views: [
      selectionDetailLabel
    ])
    selectionRow.orientation = .horizontal
    selectionRow.spacing = 0
    let toolbar = NSStackView(views: [
      profileRow,
      actionRow,
      actionStatusRow,
      selectionRow
    ])
    toolbar.alignment = .leading
    toolbar.orientation = .vertical
    toolbar.spacing = 8
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let enabledList = workflowList(title: "Enabled Workflows / Packages", table: enabledTable)
    let disabledList = workflowList(title: "Disabled Workflows / Packages", table: disabledTable)
    let split = NSStackView(views: [enabledList, disabledList])
    split.orientation = .horizontal
    split.distribution = .fillEqually
    split.spacing = 14
    split.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(toolbar)
    root.addSubview(split)
    let listControls = buildListControls()
    root.addSubview(listControls)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      split.bottomAnchor.constraint(equalTo: listControls.topAnchor, constant: -8),
      listControls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      listControls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
    ])
  }

  private func buildListControls() -> NSStackView {
    addListButton.bezelStyle = .texturedRounded
    removeListButton.bezelStyle = .texturedRounded
    addListButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    removeListButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    let controls = NSStackView(views: [addListButton, removeListButton])
    controls.orientation = .horizontal
    controls.spacing = 4
    controls.translatesAutoresizingMaskIntoConstraints = false
    return controls
  }

  private func workflowList(title: String, table: NSTableView) -> NSView {
    table.delegate = self
    table.dataSource = self
    table.usesAlternatingRowBackgroundColors = true
    table.rowHeight = 28
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.action = #selector(tableClicked(_:))
    table.doubleAction = #selector(tableDoubleClicked(_:))
    table.target = self
    table.headerView = NSTableHeaderView()
    addColumn(Column.workflow, title: "Workflow", width: 170, to: table)
    addColumn(Column.source, title: "Source", width: 130, to: table)
    addColumn(Column.environment, title: "Env", width: 90, to: table)
    addColumn(Column.active, title: "Active", width: 85, to: table)
    addColumn(Column.runtime, title: "Status", width: 115, to: table)

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    let container = NSStackView(views: [label, scroll])
    container.orientation = .vertical
    container.spacing = 6
    container.alignment = .leading
    scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
    scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
    return container
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
    } else if tableColumn.identifier == Column.source || tableColumn.identifier == Column.environment {
      text.textColor = NSColor.secondaryLabelColor
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
    case Column.source:
      return candidate.sourceDescription
    case Column.environment:
      return environmentColumnStatus(candidate)
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

  @objc private func addProject() {
    onAddProject()
  }

  @objc private func addListButtonPressed() {
    let menu = NSMenu()
    let workflowItem = NSMenuItem(title: "Workflow or Package...", action: #selector(addDirectory), keyEquivalent: "")
    workflowItem.target = self
    let projectItem = NSMenuItem(title: "Project...", action: #selector(addProject), keyEquivalent: "")
    projectItem.target = self
    menu.addItem(workflowItem)
    menu.addItem(projectItem)
    menu.popUp(
      positioning: workflowItem,
      at: NSPoint(x: 0, y: addListButton.bounds.height + 2),
      in: addListButton
    )
  }

  @objc private func openProfileFolder() {
    onOpenProfileFolder()
  }

  @objc private func viewSelectedWorkflow() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onViewSelectedWorkflow(candidate.id)
  }

  @objc private func revealSelectedSource() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onRevealSelectedSource(candidate.id)
  }

  @objc private func duplicateSelectedWorkflow() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onDuplicateWorkflow(candidate.id)
  }

  @objc private func renameSelectedWorkflow() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onRenameWorkflow(candidate.id)
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

  @objc private func setSelectedEnvironment() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetEnvironment(candidate.id)
  }

  @objc private func setSelectedEnvironmentVariables() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetEnvironmentVariables(candidate.id)
  }

  @objc private func setSelectedWorkingDirectory() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetWorkingDirectory(candidate.id)
  }

  @objc private func setSelectedVariables() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      return
    }
    onSetVariables(candidate.id)
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

  @objc private func tableDoubleClicked(_ sender: NSTableView) {
    guard selectedCandidate(in: sender) != nil, sender.clickedColumn >= 0 else {
      return
    }
    let column = sender.tableColumns[sender.clickedColumn]
    guard column.identifier != Column.active else {
      return
    }
    viewSelectedWorkflow()
  }

  func selectCandidate(identity: String) {
    rememberSelection(identity)
    restoreSelection()
    updateSelectionDetail()
    updateSelectionActionStates()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdatingTableSelection, let tableView = notification.object as? NSTableView else {
      return
    }
    isUpdatingTableSelection = true
    if tableView == enabledTable, enabledTable.selectedRow >= 0 {
      disabledTable.deselectAll(nil)
    } else if tableView == disabledTable, disabledTable.selectedRow >= 0 {
      enabledTable.deselectAll(nil)
    }
    isUpdatingTableSelection = false
    rememberSelection((selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable))?.id)
    updateSelectionDetail()
    updateSelectionActionStates()
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

  private func updateSelectionDetail() {
    guard let candidate = selectedCandidate(in: enabledTable) ?? selectedCandidate(in: disabledTable) else {
      selectionDetailLabel.stringValue = "Selected: None"
      return
    }
    let preference = state.preference(for: candidate.id)
    let runtimeDetail = snapshots[candidate.id]?.detail ?? "Stopped"
    let scope = candidate.isRielaAppProfileScoped ? "profile" : "external"
    var details = [
      "Selected: \(candidate.displayName)",
      "Management ID: \(candidate.id)",
      "Source ID: \(candidate.sourceIdentity)",
      "Source: \(candidate.sourceDescription)",
      "Scope: \(scope)",
      "Active: \(preference.active ? "yes" : "no")",
      "Events: \(candidate.eventSourceSummary)",
      "Runtime: \(runtimeDetail)",
      "Path: \(candidate.sourceDirectory)"
    ]
    if candidate.startsEventSources {
      details.append("Event runner: \(RielaAppDaemonProcessEventSourceFactory().resolvedExecutableDescription())")
    }
    details.append("Environment: \(environmentSummary(candidate))")
    details.append("Current Dir: \(preference.workingDirectory ?? candidate.workingDirectory)")
    if !preference.defaultVariables.isEmpty {
      details.append("Variables: \(preference.defaultVariables.count)")
    }
    selectionDetailLabel.stringValue = details.joined(separator: " | ")
  }

  private func updateSelectionActionStates() {
    let selectedEnabled = selectedCandidate(in: enabledTable)
    let selectedDisabled = selectedCandidate(in: disabledTable)
    let selectedCandidate = selectedEnabled ?? selectedDisabled
    let hasSelection = selectedCandidate != nil
    viewWorkflowButton.isEnabled = hasSelection
    revealSourceButton.isEnabled = hasSelection
    duplicateButton.isEnabled = hasSelection
    renameButton.isEnabled = hasSelection
    removeListButton.isEnabled = selectedCandidate.map(canRemove) ?? false
    enableButton.isEnabled = selectedDisabled != nil
    disableButton.isEnabled = selectedEnabled != nil
    setEnvironmentButton.isEnabled = hasSelection
    setEnvironmentVariablesButton.isEnabled = hasSelection
    setWorkingDirectoryButton.isEnabled = hasSelection
    setVariablesButton.isEnabled = hasSelection
  }

  private func restoreSelection() {
    guard let selectedIdentity = selectedIdentity ?? selectedIdentityByProfile[profileName] ?? firstSelectableCandidateId() else {
      enabledTable.deselectAll(nil)
      disabledTable.deselectAll(nil)
      return
    }
    self.selectedIdentity = selectedIdentity
    if select(identity: selectedIdentity, in: enabledTable, rows: enabledCandidates) {
      disabledTable.deselectAll(nil)
      return
    }
    if select(identity: selectedIdentity, in: disabledTable, rows: disabledCandidates) {
      enabledTable.deselectAll(nil)
      return
    }
    rememberSelection(nil)
    enabledTable.deselectAll(nil)
    disabledTable.deselectAll(nil)
  }

  private func firstSelectableCandidateId() -> String? {
    (enabledCandidates.first ?? disabledCandidates.first)?.id
  }

  private func rememberSelection(_ identity: String?) {
    selectedIdentity = identity
    if let identity {
      selectedIdentityByProfile[profileName] = identity
    } else {
      selectedIdentityByProfile.removeValue(forKey: profileName)
    }
  }

  private func select(identity: String, in tableView: NSTableView, rows: [RielaAppDaemonWorkflowCandidate]) -> Bool {
    guard let row = rows.firstIndex(where: { $0.id == identity }) else {
      return false
    }
    isUpdatingTableSelection = true
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    isUpdatingTableSelection = false
    return true
  }

  private func canRemove(_ candidate: RielaAppDaemonWorkflowCandidate) -> Bool {
    candidate.isRielaAppProfileScoped
      || state.projectDirectory(containing: candidate.workflowDirectory) != nil
      || state.containsWorkflowDirectory(candidate.workflowDirectory)
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
