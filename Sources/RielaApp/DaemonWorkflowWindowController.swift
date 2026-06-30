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

final class FlippedDocumentView: NSView {
  override var isFlipped: Bool {
    true
  }
}

@MainActor
final class DaemonWorkflowWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  enum Column {
    static let instance = NSUserInterfaceItemIdentifier("instance")
  }

  enum InstanceState: String {
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

  enum DetailActionStyle {
    case normal
    case destructive

    var titleColor: NSColor {
      switch self {
      case .normal:
        .labelColor
      case .destructive:
        .systemRed
      }
    }
  }

  enum AddInstanceSheetAction {
    case importWorkflowOrPackage
    case addProjectSource
  }

  enum SourceActionContext {
    case addInstance
    case relink

    var importDetail: String {
      switch self {
      case .addInstance:
        "Add a workflow or package source, then return to instance creation."
      case .relink:
        "Add a workflow or package source, then return to relink this instance."
      }
    }

    var projectDetail: String {
      switch self {
      case .addInstance:
        "Make project workflows selectable for new instances."
      case .relink:
        "Make project workflows selectable for relinking this instance."
      }
    }
  }

  enum WorkflowSourceSelection {
    case selected(WorkflowSourceOption)
    case retry
    case cancelled
  }

  enum InstanceDetailPane {
    case overview
    case inlineEnvironment
    case workflowVariables
    case eventSources
  }

  struct ConfiguredWorkflowInstanceRow {
    var id: String
    var preference: RielaAppDaemonWorkflowPreference
    var candidate: RielaAppDaemonWorkflowCandidate?
    var sourceIdentity: String
    var instanceName: String
    var workflowName: String
    var sourceDescription: String
    var state: InstanceState
  }

  struct WorkflowSourceOption {
    var sourceIdentity: String
    var candidate: RielaAppDaemonWorkflowCandidate
    var title: String
    var environmentStatus: String
    var location: String
  }

  let instanceTable = NSTableView()
  let profilePopup = NSPopUpButton()
  let addListButton = NSButton(title: "", target: nil, action: nil)
  let refreshButton = NSButton(title: "", target: nil, action: nil)
  let navigationBackButton = NSButton(title: "", target: nil, action: nil)
  let navigationForwardButton = NSButton(title: "", target: nil, action: nil)
  let navigationTitleLabel = NSTextField(labelWithString: "Instances")
  let sidebarInstancesButton = NSButton(title: "Instances", target: nil, action: nil)
  let sidebarSourcesButton = NSButton(title: "Workflow Sources", target: nil, action: nil)
  let sidebarAssistantButton = NSButton(title: "Assistant", target: nil, action: nil)
  let sidebarProfilesButton = NSButton(title: "Profiles", target: nil, action: nil)
  let sidebarSearchField = NSSearchField()
  let sourcesSummaryLabel = NSTextField(labelWithString: "")
  let assistantSummaryLabel = NSTextField(labelWithString: "")
  let assistantSaveStatusLabel = NSTextField(labelWithString: "")
  let profilesSummaryLabel = NSTextField(labelWithString: "")
  let emptyInstancesLabel = NSTextField(
    labelWithString: "No instances. Press + to select a workflow and create one."
  )
  let backToInstancesButton = NSButton(title: "Instances", target: nil, action: nil)
  let detailTitleLabel = NSTextField(labelWithString: "")
  let detailNameValueLabel = NSTextField(labelWithString: "")
  let detailWorkflowValueLabel = NSTextField(labelWithString: "")
  let detailEnvironmentValueLabel = NSTextField(labelWithString: "")
  let detailInlineEnvironmentValueLabel = NSTextField(labelWithString: "")
  let detailWorkingDirectoryValueLabel = NSTextField(labelWithString: "")
  let detailVariablesValueLabel = NSTextField(labelWithString: "")
  let detailEventSourcesValueLabel = NSTextField(labelWithString: "")
  let detailMissingSourceValueLabel = NSTextField(labelWithString: "")
  private let onRefresh: () -> Void
  private let onSelectProfile: (String) -> Void
  private let onCreateProfile: (String) -> RielaAppProfileName?
  private let onRemoveProfile: (RielaAppProfileName) -> Bool
  let onAddDirectory: () -> Void
  let onAddProject: () -> Void
  private let onAddInstance: (DaemonWorkflowAddInstanceRequest) -> Void
  private let onRevealSelectedSource: (String) -> Void
  private let onRelinkInstance: (String, String) -> Void
  private let onRenameWorkflow: (String) -> Void
  private let onRemoveInstance: (String) -> Void
  private let onStartInstance: (String) -> Void
  private let onStopInstance: (String) -> Void
  private let onRestartInstance: (String) -> Void
  private let onSetEnvironment: (String) -> Void
  private let onSetWorkingDirectory: (String) -> Void
  let onSaveEnvironmentVariables: (String, String) -> String?
  let onSaveWorkflowVariables: (String, String) -> String?
  let onRegisterEventSource: (String, String, String) -> String?
  let configuredEnvironmentValues: (RielaAppDaemonWorkflowCandidate) -> [RielaAppConfiguredEnvironmentValue]
  let onSaveAssistantAssistance: (String) -> String?
  private let environmentSummary: (RielaAppDaemonWorkflowCandidate) -> String
  let environmentColumnStatus: (RielaAppDaemonWorkflowCandidate) -> String
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
  weak var activeAddInstanceWindow: NSWindow?
  var pendingAddInstanceSheetAction: AddInstanceSheetAction?
  private var isUpdatingTableSelection = false
  private var profileSelectController: ProfileSelectWindowController?
  weak var instancesListView: NSView?
  weak var contentHost: DaemonWorkflowWindowContentHostView?
  weak var instanceDetailView: NSView?
  weak var configurationEditorView: NSView?
  weak var sourcesOverviewView: NSView?
  weak var assistantOverviewView: NSView?
  weak var profilesOverviewView: NSView?
  weak var workflowSettingRow: NSView?
  weak var missingSourceSettingRow: NSView?
  weak var nameSettingRow: NSView?
  weak var environmentSettingRow: NSView?
  weak var inlineEnvironmentSettingRow: NSView?
  weak var workingDirectorySettingRow: NSView?
  weak var variablesSettingRow: NSView?
  weak var eventSourcesSettingRow: NSView?
  weak var relinkSourceActionRow: NSView?
  weak var startInstanceActionRow: NSView?
  weak var stopInstanceActionRow: NSView?
  weak var restartInstanceActionRow: NSView?
  weak var configurationEditorStatusLabel: NSTextField?
  var inlineEnvironmentTextView: NSTextView?
  var workflowVariablesTextView: NSTextView?
  var eventSourceTextView: NSTextView?
  var eventBindingTextView: NSTextView?
  var assistantAssistanceTextView: NSTextView?
  var instanceDetailPane: InstanceDetailPane = .overview
  private var isShowingInstanceDetail = false
  private var activeSidebarPane: SidebarPane = .instances

  private enum SidebarPane {
    case instances
    case sources
    case assistant
    case profiles
  }

  init(
    onRefresh: @escaping () -> Void,
    onSelectProfile: @escaping (String) -> Void,
    onCreateProfile: @escaping (String) -> RielaAppProfileName?,
    onRemoveProfile: @escaping (RielaAppProfileName) -> Bool,
    onAddDirectory: @escaping () -> Void,
    onAddProject: @escaping () -> Void,
    onAddInstance: @escaping (DaemonWorkflowAddInstanceRequest) -> Void,
    onRevealSelectedSource: @escaping (String) -> Void,
    onRelinkInstance: @escaping (String, String) -> Void,
    onRenameWorkflow: @escaping (String) -> Void,
    onRemoveInstance: @escaping (String) -> Void,
    onStartInstance: @escaping (String) -> Void,
    onStopInstance: @escaping (String) -> Void,
    onRestartInstance: @escaping (String) -> Void,
    onSetEnvironment: @escaping (String) -> Void,
    onSetWorkingDirectory: @escaping (String) -> Void,
    onSaveEnvironmentVariables: @escaping (String, String) -> String?,
    onSaveWorkflowVariables: @escaping (String, String) -> String?,
    onRegisterEventSource: @escaping (String, String, String) -> String?,
    configuredEnvironmentValues: @escaping (RielaAppDaemonWorkflowCandidate) -> [RielaAppConfiguredEnvironmentValue],
    onSaveAssistantAssistance: @escaping (String) -> String?,
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
    self.onRelinkInstance = onRelinkInstance
    self.onRenameWorkflow = onRenameWorkflow
    self.onRemoveInstance = onRemoveInstance
    self.onStartInstance = onStartInstance
    self.onStopInstance = onStopInstance
    self.onRestartInstance = onRestartInstance
    self.onSetEnvironment = onSetEnvironment
    self.onSetWorkingDirectory = onSetWorkingDirectory
    self.onSaveEnvironmentVariables = onSaveEnvironmentVariables
    self.onSaveWorkflowVariables = onSaveWorkflowVariables
    self.onRegisterEventSource = onRegisterEventSource
    self.configuredEnvironmentValues = configuredEnvironmentValues
    self.onSaveAssistantAssistance = onSaveAssistantAssistance
    self.environmentSummary = environmentSummary
    self.environmentColumnStatus = environmentColumnStatus
    self.onWindowWillClose = onWindowWillClose
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: DaemonWorkflowWindowLayout.initialWindowSize),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Workflow Instances"
    window.minSize = DaemonWorkflowWindowLayout.minimumWindowSize
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
    assistantAssistance: String,
    statusMessage: String
  ) {
    let didChangeProfile = self.profileName != profileName
    self.profileName = profileName
    self.profileNames = profileNames
    self.candidates = candidates
    self.workflowSources = workflowSources
    self.state = state
    self.snapshots = snapshots
    if activeSidebarPane != .assistant {
      assistantAssistanceTextView?.string = assistantAssistance
    }
    if didChangeProfile || selectedIdentity == nil {
      selectedIdentity = selectedIdentityByProfile[profileName]
    }
    updateProfileControls()
    updateOverviewSummaries()
    instanceTable.reloadData()
    emptyInstancesLabel.isHidden = !instanceRows.isEmpty
    restoreSelection()
    updateInstanceDetail()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    instanceRows.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard tableColumn?.identifier == Column.instance, instanceRows.indices.contains(row) else {
      return nil
    }
    return makeInstanceRowView(for: instanceRows[row], in: tableView, tableRow: row)
  }

  @objc func refresh() {
    onRefresh()
  }

  @objc func goBack() {
    if isShowingInstanceDetail, instanceDetailPane != .overview {
      showInstanceDetailOverview()
      return
    }
    if isShowingInstanceDetail {
      showInstancesList()
      return
    }
    guard activeSidebarPane != .instances else {
      return
    }
    showInstancesPane()
  }

  @objc func goForward() {}

  @objc func showInstancesPane() {
    activeSidebarPane = .instances
    showInstancesList()
  }

  @objc func showSourcesPane() {
    activeSidebarPane = .sources
    isShowingInstanceDetail = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = false
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = true
    navigationTitleLabel.stringValue = "Workflow Sources"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showProfilesPane() {
    activeSidebarPane = .profiles
    isShowingInstanceDetail = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = false
    navigationTitleLabel.stringValue = "Profiles"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showAssistantPane() {
    activeSidebarPane = .assistant
    isShowingInstanceDetail = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = false
    profilesOverviewView?.isHidden = true
    navigationTitleLabel.stringValue = "Assistant"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func openProfilesFromSidebar() {
    openProfileSelect()
  }

  @objc func saveAssistantAssistance() {
    let assistance = assistantAssistanceTextView?.string ?? ""
    if let error = onSaveAssistantAssistance(assistance) {
      assistantSaveStatusLabel.textColor = .systemRed
      assistantSaveStatusLabel.stringValue = error
      NSApp.requestUserAttention(.informationalRequest)
      return
    }
    assistantSaveStatusLabel.textColor = .secondaryLabelColor
    assistantSaveStatusLabel.stringValue = "Saved assistance"
    updateOverviewSummaries()
  }

  private func updateOverviewSummaries() {
    let sourceCount = workflowSources.count
    sourcesSummaryLabel.stringValue = sourceCount == 1 ? "1 workflow source" : "\(sourceCount) workflow sources"
    let assistance = state.assistant.normalizedAssistance
    assistantSummaryLabel.stringValue = assistance.isEmpty
      ? "No assistance configured"
      : "\(assistance.count) characters configured"
    let profileCount = profileNames.count
    profilesSummaryLabel.stringValue = profileCount == 1 ? "1 profile" : "\(profileCount) profiles"
  }

  func updateNavigationState() {
    navigationBackButton.isEnabled = isShowingInstanceDetail || activeSidebarPane != .instances
    navigationForwardButton.isEnabled = false
  }

  func updateSidebarSelection() {
    updateSidebarButton(sidebarInstancesButton, selected: activeSidebarPane == .instances)
    updateSidebarButton(sidebarSourcesButton, selected: activeSidebarPane == .sources)
    updateSidebarButton(sidebarAssistantButton, selected: activeSidebarPane == .assistant)
    updateSidebarButton(sidebarProfilesButton, selected: activeSidebarPane == .profiles)
  }

  private func updateSidebarButton(_ button: NSButton, selected: Bool) {
    button.wantsLayer = true
    button.layer?.cornerRadius = 10
    button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    button.contentTintColor = selected ? .white : .labelColor
  }

  @objc func profilePopupChanged() {
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

  @objc func addDirectory() {
    onAddDirectory()
  }

  @objc func addProject() {
    onAddProject()
  }

  @objc func addListButtonPressed() {
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

  @objc func revealSelectedSource() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRevealSelectedSource(identity)
  }

  @objc func relinkSelectedSource() {
    guard let identity = selectedRow()?.id else {
      return
    }
    while true {
      switch promptForRelinkSourceOption(workflowSourceOptions()) {
      case let .selected(option):
        onRelinkInstance(identity, option.sourceIdentity)
        return
      case .retry:
        continue
      case .cancelled:
        return
      }
    }
  }

  @objc func renameSelectedWorkflow() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRenameWorkflow(identity)
  }

  @objc func removeSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRemoveInstance(identity)
  }

  @objc func startSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onStartInstance(identity)
  }

  @objc func stopSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onStopInstance(identity)
  }

  @objc func restartSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRestartInstance(identity)
  }

  @objc func setSelectedEnvironment() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetEnvironment(identity)
  }

  @objc func setSelectedEnvironmentVariables() {
    guard selectedRow()?.id != nil else {
      return
    }
    showInlineEnvironmentEditor()
  }

  @objc func setSelectedWorkingDirectory() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onSetWorkingDirectory(identity)
  }

  @objc func setSelectedVariables() {
    guard selectedRow()?.id != nil else {
      return
    }
    showWorkflowVariablesEditor()
  }

  @objc func setSelectedEventSources() {
    guard selectedRow()?.id != nil else {
      return
    }
    showEventSourceEditor()
  }

  @objc func tableClicked(_ sender: NSTableView) {
    guard sender == instanceTable, selectedRow() != nil else {
      return
    }
    showInstanceDetail()
  }

  @objc func tableDoubleClicked(_ sender: NSTableView) {
    guard selectedRow() != nil, sender.clickedColumn >= 0 else {
      return
    }
    showInstanceDetail()
  }

  @objc func showInstancesList() {
    activeSidebarPane = .instances
    isShowingInstanceDetail = false
    instanceDetailPane = .overview
    instancesListView?.isHidden = false
    instanceDetailView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = true
    navigationTitleLabel.stringValue = "Instances"
    updateNavigationState()
    updateSidebarSelection()
  }

  private func showInstanceDetail() {
    guard selectedRow() != nil else {
      return
    }
    activeSidebarPane = .instances
    isShowingInstanceDetail = true
    instanceDetailPane = .overview
    updateInstanceDetail()
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = false
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = true
    updateNavigationState()
    updateSidebarSelection()
  }

  func selectCandidate(identity: String) {
    rememberSelection(identity)
    restoreSelection()
    if instanceDetailPane != .overview {
      showInstanceDetailOverview()
    }
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
    guard instanceDetailPane == .overview else {
      return
    }
    guard let row = selectedRow() else {
      showInstancesList()
      return
    }
    navigationTitleLabel.stringValue = row.instanceName
    detailTitleLabel.stringValue = row.instanceName
    detailNameValueLabel.stringValue = row.instanceName
    detailWorkflowValueLabel.stringValue = rielaAppMetadataText([row.workflowName, row.sourceDescription])
    detailMissingSourceValueLabel.stringValue = rielaAppMetadataText(["Missing source", row.sourceIdentity])
    if let candidate = row.candidate {
      detailEnvironmentValueLabel.stringValue = environmentSummary(candidate)
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? candidate.workingDirectory
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = candidate.eventSourceSummary
    } else {
      detailEnvironmentValueLabel.stringValue = "Needs source"
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? "Needs source"
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = "Workflow source is missing"
    }
    updateDetailRowAccessibilityValues()
    updateDetailActions(for: row.state)
  }

  private func updateDetailRowAccessibilityValues() {
    workflowSettingRow?.setAccessibilityValue(detailWorkflowValueLabel.stringValue)
    missingSourceSettingRow?.setAccessibilityValue(detailMissingSourceValueLabel.stringValue)
    nameSettingRow?.setAccessibilityValue(detailNameValueLabel.stringValue)
    environmentSettingRow?.setAccessibilityValue(detailEnvironmentValueLabel.stringValue)
    inlineEnvironmentSettingRow?.setAccessibilityValue(detailInlineEnvironmentValueLabel.stringValue)
    workingDirectorySettingRow?.setAccessibilityValue(detailWorkingDirectoryValueLabel.stringValue)
    variablesSettingRow?.setAccessibilityValue(detailVariablesValueLabel.stringValue)
    eventSourcesSettingRow?.setAccessibilityValue(detailEventSourcesValueLabel.stringValue)
  }

  private func updateDetailActions(for state: InstanceState) {
    let needsSource = state == .needsSource
    workflowSettingRow?.isHidden = needsSource
    missingSourceSettingRow?.isHidden = !needsSource
    nameSettingRow?.isHidden = needsSource
    environmentSettingRow?.isHidden = needsSource
    inlineEnvironmentSettingRow?.isHidden = needsSource
    workingDirectorySettingRow?.isHidden = needsSource
    variablesSettingRow?.isHidden = needsSource
    eventSourcesSettingRow?.isHidden = needsSource
    relinkSourceActionRow?.isHidden = !needsSource
    startInstanceActionRow?.isHidden = !showsStartAction(for: state)
    stopInstanceActionRow?.isHidden = !showsStopAction(for: state)
    restartInstanceActionRow?.isHidden = !showsRestartAction(for: state)
  }

  func showInstanceDetailOverview() {
    instanceDetailPane = .overview
    updateInstanceDetail()
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = false
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = true
    updateNavigationState()
    updateSidebarSelection()
  }

  private func showsStartAction(for state: InstanceState) -> Bool {
    switch state {
    case .stopped, .failed:
      true
    case .running, .starting, .reloading, .stopping, .needsSource:
      false
    }
  }

  private func showsStopAction(for state: InstanceState) -> Bool {
    switch state {
    case .running, .starting, .reloading, .stopping:
      true
    case .stopped, .failed, .needsSource:
      false
    }
  }

  private func showsRestartAction(for state: InstanceState) -> Bool {
    switch state {
    case .running, .reloading:
      true
    case .starting, .stopping, .stopped, .failed, .needsSource:
      false
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
    if row == 0, let scrollView = tableView.enclosingScrollView {
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    isUpdatingTableSelection = false
    return true
  }

  var instanceRows: [ConfiguredWorkflowInstanceRow] {
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

  func workflowSourceOptions() -> [WorkflowSourceOption] {
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
        title: rielaAppMetadataText([candidate.displayName, candidate.sourceDescription, env]),
        environmentStatus: env,
        location: candidate.workflowDirectory
      )
    }
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

#endif
