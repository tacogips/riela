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
final class DaemonWorkflowWindowController: NSWindowController,
  NSSearchFieldDelegate,
  NSTextFieldDelegate,
  NSTableViewDataSource,
  NSTableViewDelegate,
  NSWindowDelegate {
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
    case importWorkflowOrPackageFromFile
    case importWorkflowOrPackageFromURL
  }

  enum SourceActionContext {
    case addInstance
    case relink

    var importDetail: String {
      switch self {
      case .addInstance:
        "Import a workflow or package directory, then return to instance creation."
      case .relink:
        "Import a workflow or package directory, then return to relink this instance."
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
    var profileName: RielaAppProfileName
    var localIdentity: String
    var preference: RielaAppDaemonWorkflowPreference
    var candidate: RielaAppDaemonWorkflowCandidate?
    var sourceIdentity: String
    var instanceName: String
    var workflowName: String
    var hasMissingRequiredEnvironment: Bool
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
  let sourcesSummaryLabel = NSTextField(labelWithString: "")
  let assistantSummaryLabel = NSTextField(labelWithString: "")
  let assistantSaveStatusLabel = NSTextField(labelWithString: "")
  let assistantPanelTitleLabel = NSTextField(labelWithString: "Riela Assistant")
  let assistantAvailabilityLabel = NSTextField(labelWithString: "")
  let assistantSelectionSummaryLabel = NSTextField(labelWithString: "")
  let assistantContextLabel = NSTextField(labelWithString: "")
  let assistantFoldButton = NSButton(title: "", target: nil, action: nil)
  let assistantSettingsVendorPopup = NSPopUpButton()
  let assistantSettingsModelPopup = NSPopUpButton()
  let assistantPromptField = NSTextField(string: "")
  let assistantSendButton = NSButton(title: "", target: nil, action: nil)
  let profilesSummaryLabel = NSTextField(labelWithString: "")
  let emptyInstancesLabel = NSTextField(
    labelWithString: "No instances. Press + to select a workflow and create one."
  )
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
  let onCreateProfile: (String) -> RielaAppProfileName?
  private let onRemoveProfile: (RielaAppProfileName) -> Bool
  let onAddDirectory: () -> Void
  let onAddURL: (String) -> Void
  let onAddInstance: (DaemonWorkflowAddInstanceRequest) -> Void
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
  let onSaveAssistantSettings: (RielaAppAssistantSettings) -> String?
  let onSubmitAssistantMessage: (String, String?) -> Void
  private let environmentSummary: (RielaAppDaemonWorkflowCandidate) -> String
  let environmentColumnStatus: (RielaAppDaemonWorkflowCandidate) -> String
  private let onWindowWillClose: () -> Void

  private static let allProfilesMenuTitle = "All Profiles"

  private var candidates: [RielaAppDaemonWorkflowCandidate] = []
  var workflowSources: [RielaAppDaemonWorkflowCandidate] = []
  var profileWorkflowSources: [RielaAppProfileName: [RielaAppDaemonWorkflowCandidate]] = [:]
  var profileInstances: [RielaAppProfiledWorkflowInstance] = []
  var state = RielaAppDaemonWorkflowState()
  private var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]
  var profileName = RielaAppProfileName.default
  var profileNames: [RielaAppProfileName] = [.default]
  var profileFilterName: RielaAppProfileName? = .default
  private var selectedIdentity: String?
  private var selectedIdentityByProfile: [RielaAppProfileName: String] = [:]
  private var isUpdatingProfileControls = false
  weak var activeAddInstanceWindow: NSWindow?
  var pendingAddInstanceSheetAction: AddInstanceSheetAction?
  private var isUpdatingTableSelection = false
  private var profileSelectController: ProfileSelectWindowController?
  var instancesListView: NSView?
  weak var contentHost: DaemonWorkflowWindowContentHostView?
  var instanceDetailView: NSView?
  var addInstanceSelectionView: NSView?
  var configurationEditorView: NSView?
  var sourcesOverviewView: NSView?
  var assistantOverviewView: NSView?
  var profilesOverviewView: NSView?
  var profilesOverviewFingerprint: String?
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
  var assistantTranscriptTextView: NSTextView?
  weak var assistantTranscriptScrollView: NSScrollView?
  weak var assistantInputStackView: NSStackView?
  weak var settingsRootView: DaemonWorkflowSettingsRootView?
  var inlineAddInstanceSourceSelectionTarget: WorkflowSourceSelectionTarget?
  var inlineAddInstanceSourceOptions: [WorkflowSourceOption] = []
  var inlineAddInstanceAllSourceOptions: [WorkflowSourceOption] = []
  let inlineAddInstanceSearchField = NSSearchField()
  var instanceDetailPane: InstanceDetailPane = .overview
  var isShowingInstanceDetail = false
  var isShowingAddInstanceSelection = false
  var activeSidebarPane: SidebarPane = .instances

  enum SidebarPane {
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
    onAddURL: @escaping (String) -> Void,
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
    onSaveAssistantSettings: @escaping (RielaAppAssistantSettings) -> String? = { _ in nil },
    onSubmitAssistantMessage: @escaping (String, String?) -> Void = { _, _ in },
    environmentSummary: @escaping (RielaAppDaemonWorkflowCandidate) -> String,
    environmentColumnStatus: @escaping (RielaAppDaemonWorkflowCandidate) -> String,
    onWindowWillClose: @escaping () -> Void
  ) {
    self.onRefresh = onRefresh
    self.onSelectProfile = onSelectProfile
    self.onCreateProfile = onCreateProfile
    self.onRemoveProfile = onRemoveProfile
    self.onAddDirectory = onAddDirectory
    self.onAddURL = onAddURL
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
    self.onSaveAssistantSettings = onSaveAssistantSettings
    self.onSubmitAssistantMessage = onSubmitAssistantMessage
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
    profileWorkflowSources: [RielaAppProfileName: [RielaAppDaemonWorkflowCandidate]] = [:],
    profileInstances: [RielaAppProfiledWorkflowInstance] = [],
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
    self.profileWorkflowSources = profileWorkflowSources
    self.profileInstances = profileInstances
    self.state = state
    self.snapshots = snapshots
    if activeSidebarPane != .assistant {
      assistantAssistanceTextView?.string = assistantAssistance
    }
    if didChangeProfile {
      profileFilterName = profileName
    }
    if didChangeProfile || selectedIdentity == nil {
      selectedIdentity = selectedIdentityByProfile[profileName]
    }
    updateProfileControls()
    rebuildProfilesOverviewView()
    updateOverviewSummaries()
    updateAssistantPanel()
    instanceTable.reloadData()
    emptyInstancesLabel.isHidden = !instanceRows.isEmpty
    if isShowingAddInstanceSelection {
      showAddInstanceSelectionPane()
    }
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

  @objc func openProfilesFromSidebar() {
    openProfileSelect()
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
    if title == Self.allProfilesMenuTitle {
      profileFilterName = nil
      selectedIdentity = nil
      updateProfileControls()
      instanceTable.reloadData()
      emptyInstancesLabel.isHidden = !instanceRows.isEmpty
      restoreSelection()
      updateInstanceDetail()
      return
    }
    onSelectProfile(title)
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
    guard let row = selectedRow() else {
      return
    }
    while true {
      switch promptForRelinkSourceOption(workflowSourceOptions(profileName: row.profileName)) {
      case let .selected(option):
        onRelinkInstance(row.id, option.sourceIdentity)
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
    isShowingAddInstanceSelection = false
    instanceDetailPane = .overview
    showContentPane(instancesListView)
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
    isShowingAddInstanceSelection = false
    instanceDetailPane = .overview
    updateInstanceDetail()
    showContentPane(instanceDetailView)
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

  func selectedRow() -> ConfiguredWorkflowInstanceRow? {
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
    detailWorkflowValueLabel.stringValue = rielaAppMetadataText([
      "Profile \(row.profileName.rawValue)",
      row.workflowName
    ])
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
    isShowingAddInstanceSelection = false
    instanceDetailPane = .overview
    updateInstanceDetail()
    showContentPane(instanceDetailView)
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
    if !profileInstances.isEmpty {
      return profiledInstanceRows()
    }
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
          profileName: profileName,
          localIdentity: storedIdentity,
          preference: preference,
          candidate: candidate,
          sourceIdentity: sourceIdentity,
          instanceName: instanceName,
          workflowName: sourceCandidate?.displayName ?? candidate?.workflowId ?? "Missing source",
          hasMissingRequiredEnvironment: candidate.map(hasMissingRequiredEnvironment) ?? false,
          state: instanceState(identity: storedIdentity, hasSource: candidate != nil)
        )
      }
  }

  private func profiledInstanceRows() -> [ConfiguredWorkflowInstanceRow] {
    profileInstances
      .filter { profileFilterName == nil || $0.profileName == profileFilterName }
      .sorted { lhs, rhs in
        let profileCompare = lhs.profileName.rawValue.localizedCaseInsensitiveCompare(rhs.profileName.rawValue)
        if profileCompare != .orderedSame {
          return profileCompare == .orderedAscending
        }
        return lhs.instance.displayName.localizedCaseInsensitiveCompare(rhs.instance.displayName) == .orderedAscending
      }
      .map { profiledInstance in
        let instance = profiledInstance.instance
        let runtimeCandidate = profiledInstance.runtimeCandidate
        return ConfiguredWorkflowInstanceRow(
          id: profiledInstance.id,
          profileName: profiledInstance.profileName,
          localIdentity: instance.identity,
          preference: instance.preference,
          candidate: runtimeCandidate,
          sourceIdentity: instance.sourceIdentity,
          instanceName: instance.displayName,
          workflowName: instance.source.displayName,
          hasMissingRequiredEnvironment: hasMissingRequiredEnvironment(runtimeCandidate),
          state: instanceState(identity: profiledInstance.id, hasSource: true)
        )
      }
  }

  private func hasMissingRequiredEnvironment(_ candidate: RielaAppDaemonWorkflowCandidate) -> Bool {
    environmentColumnStatus(candidate).hasPrefix("Missing ")
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
    workflowSourceOptions(profileName: profileName)
  }

  func workflowSourceOptions(profileName: RielaAppProfileName) -> [WorkflowSourceOption] {
    let profileSources = profileWorkflowSources[profileName] ?? []
    let sources = profileSources.isEmpty ? (workflowSources.isEmpty ? candidates : workflowSources) : profileSources
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
    profilePopup.addItem(withTitle: Self.allProfilesMenuTitle)
    profilePopup.menu?.addItem(.separator())
    profilePopup.addItems(withTitles: profileNames.map(\.rawValue))
    profilePopup.menu?.addItem(.separator())
    profilePopup.addItem(withTitle: ProfileSelectWindowController.menuTitle)
    profilePopup.selectItem(withTitle: profileFilterName?.rawValue ?? Self.allProfilesMenuTitle)
    isUpdatingProfileControls = false
  }

  func windowWillClose(_ notification: Notification) {
    onWindowWillClose()
  }
}

#endif
