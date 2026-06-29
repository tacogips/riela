#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

struct DaemonWorkflowAddInstanceRequest {
  var sourceIdentity: String
  var identity: String
  var displayName: String?
  var environmentFilePath: String?
  var workingDirectory: String?
  var startsImmediately: Bool
}

@MainActor
final class DaemonWorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  private enum Column {
    static let instance = NSUserInterfaceItemIdentifier("instance")
    static let workflow = NSUserInterfaceItemIdentifier("source")
    static let environment = NSUserInterfaceItemIdentifier("environment")
    static let state = NSUserInterfaceItemIdentifier("state")
  }

  private enum InstanceState: String {
    case running = "Running"
    case starting = "Starting"
    case reloading = "Reloading"
    case stopping = "Stopping"
    case stopped = "Stopped"
    case failed = "Failed"
    case needsSource = "Needs Source"

    var sortOrder: Int {
      switch self {
      case .failed: 0
      case .needsSource: 1
      case .starting, .reloading, .stopping: 2
      case .running: 3
      case .stopped: 4
      }
    }
  }

  private struct ConfiguredWorkflowInstanceRow {
    var id: String
    var preference: RielaAppDaemonWorkflowPreference
    var candidate: RielaAppDaemonWorkflowCandidate?
    var sourceIdentity: String
    var instanceName: String
    var workflowName: String
    var sourceDescription: String
    var state: InstanceState
  }

  private struct WorkflowSourceOption {
    var sourceIdentity: String
    var candidate: RielaAppDaemonWorkflowCandidate
    var title: String
  }

  private let instanceTable = NSTableView()
  private let profilePopup = NSPopUpButton()
  private let addListButton = NSButton(title: "+ Add Instance", target: nil, action: nil)
  private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
  private let backToInstancesButton = NSButton(title: "Back to Instances", target: nil, action: nil)
  private let detailTitleLabel = NSTextField(labelWithString: "")
  private let detailNameValueLabel = NSTextField(labelWithString: "")
  private let detailWorkflowValueLabel = NSTextField(labelWithString: "")
  private let detailEnvironmentValueLabel = NSTextField(labelWithString: "")
  private let detailInlineEnvironmentValueLabel = NSTextField(labelWithString: "")
  private let detailWorkingDirectoryValueLabel = NSTextField(labelWithString: "")
  private let detailVariablesValueLabel = NSTextField(labelWithString: "")
  private let detailEventSourcesValueLabel = NSTextField(labelWithString: "")
  private let onRefresh: () -> Void
  private let onSelectProfile: (String) -> Void
  private let onCreateProfile: (String) -> RielaAppProfileName?
  private let onRemoveProfile: (RielaAppProfileName) -> Bool
  private let onAddDirectory: () -> Void
  private let onAddProject: () -> Void
  private let onAddInstance: (DaemonWorkflowAddInstanceRequest) -> Void
  private let onRevealSelectedSource: (String) -> Void
  private let onDuplicateWorkflow: (String) -> Void
  private let onRenameWorkflow: (String) -> Void
  private let onRemoveInstance: (String) -> Void
  private let onStartInstance: (String) -> Void
  private let onStopInstance: (String) -> Void
  private let onRestartInstance: (String) -> Void
  private let onSetEnvironment: (String) -> Void
  private let onSetEnvironmentVariables: (String) -> Void
  private let onSetWorkingDirectory: (String) -> Void
  private let onSetVariables: (String) -> Void
  private let environmentSummary: (RielaAppDaemonWorkflowCandidate) -> String
  private let environmentColumnStatus: (RielaAppDaemonWorkflowCandidate) -> String
  private let onWindowWillClose: () -> Void

  private var candidates: [RielaAppDaemonWorkflowCandidate] = []
  private var workflowSources: [RielaAppDaemonWorkflowCandidate] = []
  private var state = RielaAppDaemonWorkflowState()
  private var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]
  private var profileName = RielaAppProfileName.default
  private var profileNames: [RielaAppProfileName] = [.default]
  private var selectedIdentity: String?
  private var selectedIdentityByProfile: [RielaAppProfileName: String] = [:]
  private var isUpdatingProfileControls = false
  private var isUpdatingTableSelection = false
  private var profileSelectController: ProfileSelectWindowController?
  private weak var instancesListView: NSView?
  private weak var instanceDetailView: NSView?
  private var isShowingInstanceDetail = false

  init(
    onRefresh: @escaping () -> Void,
    onSelectProfile: @escaping (String) -> Void,
    onCreateProfile: @escaping (String) -> RielaAppProfileName?,
    onRemoveProfile: @escaping (RielaAppProfileName) -> Bool,
    onAddDirectory: @escaping () -> Void,
    onAddProject: @escaping () -> Void,
    onAddInstance: @escaping (DaemonWorkflowAddInstanceRequest) -> Void,
    onRevealSelectedSource: @escaping (String) -> Void,
    onDuplicateWorkflow: @escaping (String) -> Void,
    onRenameWorkflow: @escaping (String) -> Void,
    onRemoveInstance: @escaping (String) -> Void,
    onStartInstance: @escaping (String) -> Void,
    onStopInstance: @escaping (String) -> Void,
    onRestartInstance: @escaping (String) -> Void,
    onSetEnvironment: @escaping (String) -> Void,
    onSetEnvironmentVariables: @escaping (String) -> Void,
    onSetWorkingDirectory: @escaping (String) -> Void,
    onSetVariables: @escaping (String) -> Void,
    environmentSummary: @escaping (RielaAppDaemonWorkflowCandidate) -> String,
    environmentColumnStatus: @escaping (RielaAppDaemonWorkflowCandidate) -> String,
    onWindowWillClose: @escaping () -> Void
  ) {
    self.onRefresh = onRefresh
    self.onSelectProfile = onSelectProfile
    self.onCreateProfile = onCreateProfile
    self.onRemoveProfile = onRemoveProfile
    self.onAddDirectory = onAddDirectory
    self.onAddProject = onAddProject
    self.onAddInstance = onAddInstance
    self.onRevealSelectedSource = onRevealSelectedSource
    self.onDuplicateWorkflow = onDuplicateWorkflow
    self.onRenameWorkflow = onRenameWorkflow
    self.onRemoveInstance = onRemoveInstance
    self.onStartInstance = onStartInstance
    self.onStopInstance = onStopInstance
    self.onRestartInstance = onRestartInstance
    self.onSetEnvironment = onSetEnvironment
    self.onSetEnvironmentVariables = onSetEnvironmentVariables
    self.onSetWorkingDirectory = onSetWorkingDirectory
    self.onSetVariables = onSetVariables
    self.environmentSummary = environmentSummary
    self.environmentColumnStatus = environmentColumnStatus
    self.onWindowWillClose = onWindowWillClose
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Workflow Instances"
    super.init(window: window)
    window.delegate = self
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(
    profileName: RielaAppProfileName,
    profileNames: [RielaAppProfileName],
    candidates: [RielaAppDaemonWorkflowCandidate],
    workflowSources: [RielaAppDaemonWorkflowCandidate],
    state: RielaAppDaemonWorkflowState,
    snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot],
    statusMessage: String
  ) {
    let didChangeProfile = self.profileName != profileName
    self.profileName = profileName
    self.profileNames = profileNames
    self.candidates = candidates
    self.workflowSources = workflowSources
    self.state = state
    self.snapshots = snapshots
    if didChangeProfile || selectedIdentity == nil {
      selectedIdentity = selectedIdentityByProfile[profileName]
    }
    updateProfileControls()
    instanceTable.reloadData()
    restoreSelection()
    updateInstanceDetail()
  }

  private func buildContent(in window: NSWindow) {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = root

    let profileLabel = NSTextField(labelWithString: "Profile")
    profilePopup.target = self
    profilePopup.action = #selector(profilePopupChanged)
    profilePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
    refreshButton.target = self
    refreshButton.action = #selector(refresh)
    addListButton.target = self
    addListButton.action = #selector(addListButtonPressed)
    backToInstancesButton.target = self
    backToInstancesButton.action = #selector(showInstancesList)
    profilePopup.toolTip = "Switch profiles or open Profile Select."
    addListButton.toolTip = "Create an instance from a workflow source."
    detailTitleLabel.font = .boldSystemFont(ofSize: 18)
    for label in [
      detailTitleLabel,
      detailNameValueLabel,
      detailWorkflowValueLabel,
      detailEnvironmentValueLabel,
      detailInlineEnvironmentValueLabel,
      detailWorkingDirectoryValueLabel,
      detailVariablesValueLabel,
      detailEventSourcesValueLabel
    ] {
      label.lineBreakMode = .byTruncatingMiddle
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    let profileRow = NSStackView(views: [
      profileLabel,
      profilePopup
    ])
    profileRow.orientation = .horizontal
    profileRow.spacing = 8
    let toolbar = NSStackView(views: [
      profileRow
    ])
    toolbar.alignment = .leading
    toolbar.orientation = .vertical
    toolbar.spacing = 8
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let instancesList = workflowList(title: "Instances", table: instanceTable)
    instancesList.translatesAutoresizingMaskIntoConstraints = false
    instancesListView = instancesList
    let detail = buildInstanceDetailView()
    detail.translatesAutoresizingMaskIntoConstraints = false
    detail.isHidden = true
    instanceDetailView = detail

    root.addSubview(toolbar)
    root.addSubview(instancesList)
    root.addSubview(detail)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      instancesList.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
      instancesList.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      instancesList.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      instancesList.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      detail.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
      detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
    ])
  }

  private func buildInstanceDetailView() -> NSView {
    let startDetailButton = NSButton(title: "Start", target: self, action: #selector(startSelectedInstance))
    let stopDetailButton = NSButton(title: "Stop", target: self, action: #selector(stopSelectedInstance))
    let restartDetailButton = NSButton(title: "Restart", target: self, action: #selector(restartSelectedInstance))
    let removeDetailButton = NSButton(title: "Remove Instance", target: self, action: #selector(removeSelectedInstance))

    let topRow = NSStackView(views: [backToInstancesButton, NSView(), removeDetailButton])
    topRow.orientation = .horizontal
    topRow.spacing = 8
    let runRow = NSStackView(views: [startDetailButton, stopDetailButton, restartDetailButton])
    runRow.orientation = .horizontal
    runRow.spacing = 8
    let settingsTitle = NSTextField(labelWithString: "Current Settings")
    settingsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    let stack = NSStackView(views: [
      topRow,
      detailTitleLabel,
      runRow,
      settingsTitle,
      settingRow(title: "Workflow", valueLabel: detailWorkflowValueLabel, action: #selector(revealSelectedSource)),
      settingRow(title: "Name", valueLabel: detailNameValueLabel, action: #selector(renameSelectedWorkflow)),
      settingRow(title: "Env File", valueLabel: detailEnvironmentValueLabel, action: #selector(setSelectedEnvironment)),
      settingRow(
        title: "Inline Env",
        valueLabel: detailInlineEnvironmentValueLabel,
        action: #selector(setSelectedEnvironmentVariables)
      ),
      settingRow(
        title: "Working Directory",
        valueLabel: detailWorkingDirectoryValueLabel,
        action: #selector(setSelectedWorkingDirectory)
      ),
      settingRow(title: "Variables", valueLabel: detailVariablesValueLabel, action: #selector(setSelectedVariables)),
      settingRow(title: "Event Sources", valueLabel: detailEventSourcesValueLabel, action: nil)
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    topRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
    topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    return stack
  }

  private func settingRow(
    title: String,
    valueLabel: NSTextField,
    action: Selector?
  ) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
    valueLabel.textColor = .labelColor
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    var views: [NSView] = [titleLabel, valueLabel, spacer]
    if action != nil {
      let chevron = NSTextField(labelWithString: ">")
      chevron.textColor = .tertiaryLabelColor
      views.append(chevron)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    if let action {
      row.wantsLayer = true
      row.toolTip = "Open \(title)"
      row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
    }
    return row
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
    addColumn(Column.instance, title: "Instance", width: 150, to: table)
    addColumn(Column.workflow, title: "Workflow", width: 160, to: table)
    addColumn(Column.environment, title: "Env", width: 70, to: table)
    addColumn(Column.state, title: "State", width: 105, to: table)

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [
      label,
      headerSpacer,
      addListButton,
      refreshButton
    ])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY

    let container = NSStackView(views: [header, scroll])
    container.orientation = .vertical
    container.spacing = 6
    container.alignment = .leading
    header.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
    header.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
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
    instanceRows.count
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
    if tableColumn.identifier == Column.workflow || tableColumn.identifier == Column.environment {
      text.textColor = NSColor.secondaryLabelColor
    } else if tableColumn.identifier == Column.state {
      text.textColor = stateColor(for: instanceRows[row].state)
    }
    return cell
  }

  private func value(for tableView: NSTableView, column: NSUserInterfaceItemIdentifier, row: Int) -> String {
    let row = instanceRows[row]
    switch column {
    case Column.instance:
      return row.instanceName
    case Column.workflow:
      return row.workflowName
    case Column.environment:
      guard let candidate = row.candidate else {
        return "Missing"
      }
      return environmentColumnStatus(candidate)
    case Column.state:
      return row.state.rawValue
    default:
      return ""
    }
  }

  private func stateColor(for state: InstanceState) -> NSColor {
    switch state {
    case .running:
      .systemGreen
    case .failed:
      .systemRed
    case .starting, .reloading, .stopping:
      .systemOrange
    case .needsSource:
      .systemYellow
    case .stopped:
      .secondaryLabelColor
    }
  }

  @objc private func refresh() {
    onRefresh()
  }

  @objc private func profilePopupChanged() {
    guard !isUpdatingProfileControls, let title = profilePopup.selectedItem?.title else {
      return
    }
    if title == ProfileSelectWindowController.menuTitle {
      updateProfileControls()
      openProfileSelect()
      return
    }
    onSelectProfile(title)
  }

  @objc private func addDirectory() {
    onAddDirectory()
  }

  @objc private func addProject() {
    onAddProject()
  }

  @objc private func addListButtonPressed() {
    guard let request = promptForAddInstance() else {
      return
    }
    onAddInstance(request)
  }

  private func openProfileSelect() {
    if profileSelectController == nil {
      profileSelectController = ProfileSelectWindowController(
        onSelectProfile: onSelectProfile,
        onCreateProfile: onCreateProfile,
        onRemoveProfile: onRemoveProfile
      )
    }
    profileSelectController?.show(
      currentProfile: profileName,
      profileNames: profileNames,
      parentWindow: window
    )
  }

  @objc private func viewSelectedWorkflow() {
    showInstanceDetail()
  }

  @objc private func revealSelectedSource() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRevealSelectedSource(identity)
  }

  @objc private func duplicateSelectedWorkflow() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onDuplicateWorkflow(identity)
  }

  @objc private func renameSelectedWorkflow() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRenameWorkflow(identity)
  }

  @objc private func removeSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRemoveInstance(identity)
  }

  @objc private func startSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onStartInstance(identity)
  }

  @objc private func stopSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onStopInstance(identity)
  }

  @objc private func restartSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRestartInstance(identity)
  }

  @objc private func setSelectedEnvironment() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetEnvironment(identity)
  }

  @objc private func setSelectedEnvironmentVariables() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetEnvironmentVariables(identity)
  }

  @objc private func setSelectedWorkingDirectory() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetWorkingDirectory(identity)
  }

  @objc private func setSelectedVariables() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetVariables(identity)
  }

  @objc private func tableClicked(_ sender: NSTableView) {
    guard sender == instanceTable, selectedRow() != nil else {
      return
    }
    showInstanceDetail()
  }

  @objc private func tableDoubleClicked(_ sender: NSTableView) {
    guard selectedRow() != nil, sender.clickedColumn >= 0 else {
      return
    }
    showInstanceDetail()
  }

  @objc private func showInstancesList() {
    isShowingInstanceDetail = false
    instancesListView?.isHidden = false
    instanceDetailView?.isHidden = true
  }

  private func showInstanceDetail() {
    guard selectedRow() != nil else {
      return
    }
    isShowingInstanceDetail = true
    updateInstanceDetail()
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = false
  }

  func selectCandidate(identity: String) {
    rememberSelection(identity)
    restoreSelection()
    updateInstanceDetail()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdatingTableSelection, let tableView = notification.object as? NSTableView else {
      return
    }
    guard tableView == instanceTable else {
      return
    }
    rememberSelection(selectedRow()?.id)
    updateInstanceDetail()
  }

  private func selectedRow() -> ConfiguredWorkflowInstanceRow? {
    let row = instanceTable.selectedRow
    guard row >= 0 else {
      return nil
    }
    let rows = instanceRows
    guard rows.indices.contains(row) else {
      return nil
    }
    return rows[row]
  }

  private func updateInstanceDetail() {
    guard isShowingInstanceDetail else {
      return
    }
    guard let row = selectedRow() else {
      showInstancesList()
      return
    }
    detailTitleLabel.stringValue = row.instanceName
    detailNameValueLabel.stringValue = row.instanceName
    detailWorkflowValueLabel.stringValue = "\(row.workflowName) | \(row.sourceDescription)"
    if let candidate = row.candidate {
      detailEnvironmentValueLabel.stringValue = environmentSummary(candidate)
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? candidate.workingDirectory
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = candidate.eventSourceSummary
    } else {
      detailEnvironmentValueLabel.stringValue = "Unavailable"
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? "Unavailable"
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = "Workflow source is missing"
    }
  }

  private func restoreSelection() {
    guard let selectedIdentity = selectedIdentity ?? selectedIdentityByProfile[profileName] ?? firstSelectableCandidateId() else {
      instanceTable.deselectAll(nil)
      return
    }
    self.selectedIdentity = selectedIdentity
    if select(identity: selectedIdentity, in: instanceTable, rows: instanceRows) {
      return
    }
    rememberSelection(nil)
    instanceTable.deselectAll(nil)
  }

  private func firstSelectableCandidateId() -> String? {
    instanceRows.first?.id
  }

  private func rememberSelection(_ identity: String?) {
    selectedIdentity = identity
    if let identity {
      selectedIdentityByProfile[profileName] = identity
    } else {
      selectedIdentityByProfile.removeValue(forKey: profileName)
    }
  }

  private func select(identity: String, in tableView: NSTableView, rows: [ConfiguredWorkflowInstanceRow]) -> Bool {
    guard let row = rows.firstIndex(where: { $0.id == identity }) else {
      return false
    }
    isUpdatingTableSelection = true
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    isUpdatingTableSelection = false
    return true
  }

  private var instanceRows: [ConfiguredWorkflowInstanceRow] {
    let allCandidates = candidates + workflowSources
    let candidatesById = Dictionary(allCandidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let candidatesBySourceIdentity = Dictionary(
      allCandidates.map { ($0.sourceIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return state.preferences
      .sorted { lhs, rhs in lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending }
      .map { identity, preference in
        let storedIdentity = preference.identity.isEmpty ? identity : preference.identity
        let sourceIdentity = preference.sourceIdentity ?? storedIdentity
        let sourceCandidate = candidatesById[sourceIdentity] ?? candidatesBySourceIdentity[sourceIdentity]
        let directCandidate = candidatesById[storedIdentity]
        let candidate = directCandidate ?? sourceCandidate?.managedInstance(
          identity: storedIdentity,
          displayName: preference.displayName
        )
        let instanceName = preference.displayName?.isEmpty == false
          ? preference.displayName ?? storedIdentity
          : candidate?.displayName ?? storedIdentity
        return ConfiguredWorkflowInstanceRow(
          id: storedIdentity,
          preference: preference,
          candidate: candidate,
          sourceIdentity: sourceIdentity,
          instanceName: instanceName,
          workflowName: sourceCandidate?.displayName ?? candidate?.workflowId ?? "Missing source",
          sourceDescription: sourceCandidate?.sourceDescription ?? candidate?.sourceDescription ?? "Missing source",
          state: instanceState(identity: storedIdentity, hasSource: candidate != nil)
        )
      }
  }

  private func instanceState(identity: String, hasSource: Bool) -> InstanceState {
    guard hasSource else {
      return .needsSource
    }
    switch snapshots[identity]?.status {
    case .running:
      return .running
    case .starting:
      return .starting
    case .reloading:
      return .reloading
    case .stopping:
      return .stopping
    case .failed:
      return .failed
    case .stopped, nil:
      return .stopped
    }
  }

  private func workflowSourceOptions() -> [WorkflowSourceOption] {
    let sources = workflowSources.isEmpty ? candidates : workflowSources
    var seen = Set<String>()
    return sources.compactMap { candidate in
      let identity = candidate.sourceIdentity
      guard !seen.contains(identity) else {
        return nil
      }
      seen.insert(identity)
      let env = environmentColumnStatus(candidate)
      return WorkflowSourceOption(
        sourceIdentity: identity,
        candidate: candidate,
        title: "\(candidate.displayName) | \(candidate.sourceDescription) | \(env)"
      )
    }
  }

  private func promptForAddInstance() -> DaemonWorkflowAddInstanceRequest? {
    let options = workflowSourceOptions()
    guard !options.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Selectable Workflows"
      alert.informativeText = "Import a workflow, package, or project source."
      alert.addButton(withTitle: "Import Workflow or Package...")
      alert.addButton(withTitle: "Add Project Source...")
      alert.addButton(withTitle: "Cancel")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        onAddDirectory()
      } else if response == .alertSecondButtonReturn {
        onAddProject()
      }
      return nil
    }

    let workflowPopup = NSPopUpButton()
    workflowPopup.addItems(withTitles: options.map(\.title))
    let idField = NSTextField(string: "")
    idField.placeholderString = "instance-id"
    let nameField = NSTextField(string: "")
    nameField.placeholderString = "Display name"
    let envField = NSTextField(string: "")
    envField.placeholderString = "Optional .env path"
    let directoryField = NSTextField(string: "")
    directoryField.placeholderString = "Optional working directory"
    let startCheckbox = NSButton(checkboxWithTitle: "Start now", target: nil, action: nil)
    startCheckbox.state = .on
    let stack = NSStackView(views: [
      NSTextField(labelWithString: "Workflow"),
      workflowPopup,
      NSTextField(labelWithString: "Instance ID"),
      idField,
      NSTextField(labelWithString: "Display Name"),
      nameField,
      NSTextField(labelWithString: "Env File"),
      envField,
      NSTextField(labelWithString: "Working Directory"),
      directoryField,
      startCheckbox
    ])
    stack.orientation = .vertical
    stack.spacing = 6
    stack.frame = NSRect(x: 0, y: 0, width: 520, height: 260)

    let alert = NSAlert()
    alert.messageText = "Add Instance"
    alert.informativeText = "Select a workflow and enter instance parameters."
    alert.accessoryView = stack
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Import Workflow or Package...")
    alert.addButton(withTitle: "Add Project Source...")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
      onAddDirectory()
      return nil
    }
    if response == .alertThirdButtonReturn {
      onAddProject()
      return nil
    }
    guard response == .alertFirstButtonReturn else {
      return nil
    }
    let option = options[max(0, workflowPopup.indexOfSelectedItem)]
    let rawIdentity = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let envPath = envField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let workingDirectory = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return DaemonWorkflowAddInstanceRequest(
      sourceIdentity: option.sourceIdentity,
      identity: rawIdentity,
      displayName: displayName.isEmpty ? nil : displayName,
      environmentFilePath: envPath.isEmpty ? nil : envPath,
      workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
      startsImmediately: startCheckbox.state == .on
    )
  }

  private func updateProfileControls() {
    isUpdatingProfileControls = true
    profilePopup.removeAllItems()
    profilePopup.addItems(withTitles: profileNames.map(\.rawValue))
    profilePopup.menu?.addItem(.separator())
    profilePopup.addItem(withTitle: ProfileSelectWindowController.menuTitle)
    profilePopup.selectItem(withTitle: profileName.rawValue)
    isUpdatingProfileControls = false
  }

  func windowWillClose(_ notification: Notification) {
    onWindowWillClose()
  }
}

@MainActor
private final class ProfileSelectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  static let menuTitle = "Profile Select..."

  private let tableView = NSTableView()
  private let addButton = NSButton(title: "+", target: nil, action: nil)
  private let removeButton = NSButton(title: "-", target: nil, action: nil)
  private let openButton = NSButton(title: "Open", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let statusLabel = NSTextField(labelWithString: "")
  private let onSelectProfile: (String) -> Void
  private let onCreateProfile: (String) -> RielaAppProfileName?
  private let onRemoveProfile: (RielaAppProfileName) -> Bool
  private var currentProfile = RielaAppProfileName.default
  private var profileNames: [RielaAppProfileName] = [.default]

  init(
    onSelectProfile: @escaping (String) -> Void,
    onCreateProfile: @escaping (String) -> RielaAppProfileName?,
    onRemoveProfile: @escaping (RielaAppProfileName) -> Bool
  ) {
    self.onSelectProfile = onSelectProfile
    self.onCreateProfile = onCreateProfile
    self.onRemoveProfile = onRemoveProfile
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Profile Select"
    super.init(window: window)
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func show(
    currentProfile: RielaAppProfileName,
    profileNames: [RielaAppProfileName],
    parentWindow: NSWindow?
  ) {
    self.currentProfile = currentProfile
    self.profileNames = profileNames
    tableView.reloadData()
    selectProfile(currentProfile)
    updateButtons()
    statusLabel.stringValue = ""
    guard let window else {
      return
    }
    if let parentWindow {
      parentWindow.beginSheet(window)
    } else {
      showWindow(nil)
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func buildContent(in window: NSWindow) {
    guard let root = window.contentView else {
      return
    }
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
    column.title = "Profile"
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.delegate = self
    tableView.dataSource = self
    tableView.doubleAction = #selector(openSelectedProfile)
    tableView.target = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    addButton.target = self
    addButton.action = #selector(addProfile)
    addButton.bezelStyle = .texturedRounded
    addButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    removeButton.target = self
    removeButton.action = #selector(removeProfile)
    removeButton.bezelStyle = .texturedRounded
    removeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    openButton.target = self
    openButton.action = #selector(openSelectedProfile)
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle

    let listControls = NSStackView(views: [addButton, removeButton])
    listControls.orientation = .horizontal
    listControls.spacing = 4
    let buttonRow = NSStackView(views: [listControls, NSView(), cancelButton, openButton])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 8
    let stack = NSStackView(views: [scrollView, statusLabel, buttonRow])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    ])
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    profileNames.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: profileNames[row].rawValue)
    if profileNames[row] == currentProfile {
      label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    }
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateButtons()
  }

  @objc private func addProfile() {
    guard let rawName = promptForProfileName() else {
      return
    }
    guard let profileName = onCreateProfile(rawName) else {
      statusLabel.stringValue = "Failed to add profile"
      return
    }
    if !profileNames.contains(profileName) {
      profileNames.append(profileName)
      profileNames.sort { lhs, rhs in
        lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
      }
    }
    tableView.reloadData()
    selectProfile(profileName)
    statusLabel.stringValue = "Added profile \(profileName.rawValue)"
  }

  @objc private func removeProfile() {
    guard let profileName = selectedProfile() else {
      return
    }
    guard profileName != .default else {
      statusLabel.stringValue = "Default profile cannot be removed"
      return
    }
    guard profileName != currentProfile else {
      statusLabel.stringValue = "Current profile cannot be removed"
      return
    }
    guard confirmProfileRemoval(profileName) else {
      return
    }
    guard onRemoveProfile(profileName) else {
      statusLabel.stringValue = "Failed to remove profile \(profileName.rawValue)"
      return
    }
    profileNames.removeAll { $0 == profileName }
    tableView.reloadData()
    selectProfile(currentProfile)
    statusLabel.stringValue = "Removed profile \(profileName.rawValue)"
  }

  @objc private func openSelectedProfile() {
    guard let profileName = selectedProfile() else {
      return
    }
    closeSheet()
    onSelectProfile(profileName.rawValue)
  }

  @objc private func cancel() {
    closeSheet()
  }

  private func promptForProfileName() -> String? {
    let field = NSTextField(string: "")
    field.placeholderString = RielaAppProfileName.defaultRawValue
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    let alert = NSAlert()
    alert.messageText = "Add Profile"
    alert.accessoryView = field
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return field.stringValue
  }

  private func confirmProfileRemoval(_ profileName: RielaAppProfileName) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Remove Profile"
    alert.informativeText = "Remove profile \(profileName.rawValue) and its workflow sources, packages, and instance state?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func selectedProfile() -> RielaAppProfileName? {
    let row = tableView.selectedRow
    guard profileNames.indices.contains(row) else {
      return nil
    }
    return profileNames[row]
  }

  private func selectProfile(_ profileName: RielaAppProfileName) {
    guard let row = profileNames.firstIndex(of: profileName) else {
      return
    }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  private func updateButtons() {
    let selected = selectedProfile()
    openButton.isEnabled = selected != nil
    removeButton.isEnabled = selected != nil && selected != .default && selected != currentProfile
  }

  private func closeSheet() {
    guard let window else {
      return
    }
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
  }
}
#endif
