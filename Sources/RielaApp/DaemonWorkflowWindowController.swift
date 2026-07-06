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
  NSTextViewDelegate,
  NSTableViewDataSource,
  NSTableViewDelegate,
  NSWindowDelegate {
  let instanceTable = NSTableView()
  let profilePopup = NSPopUpButton()
  let instanceSearchField = NSSearchField()
  let addListButton = NSButton(title: "", target: nil, action: nil)
  let addProfileButton = NSButton(title: "", target: nil, action: nil)
  let refreshButton = NSButton(title: "", target: nil, action: nil)
  let navigationBackButton = NSButton(title: "", target: nil, action: nil)
  let navigationTitleLabel = NSTextField(labelWithString: "Instances")
  let sidebarInstancesButton = NSButton(title: "Instances", target: nil, action: nil)
  let sidebarSourcesButton = NSButton(title: "Workflow Sources", target: nil, action: nil)
  let sidebarAssistantButton = NSButton(title: "Assistant", target: nil, action: nil)
  let sidebarProfilesButton = NSButton(title: "Profiles", target: nil, action: nil)
  let sourcesSummaryLabel = NSTextField(labelWithString: "")
  let workflowSourceSearchField = NSSearchField()
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
  let emptyInstancesGuideView = DaemonWorkflowEmptyStateView()
  let statusBannerView = RielaAppStatusBannerView()
  private let statusMessageHistoryLimit = 8
  let detailTitleLabel = NSTextField(labelWithString: "")
  let detailSummaryLabel = NSTextField(labelWithString: "")
  let detailStatusProgressIndicator = NSProgressIndicator()
  let detailStatusValueLabel = NSTextField(labelWithString: "")
  let detailNameValueLabel = NSTextField(labelWithString: "")
  let detailWorkflowValueLabel = NSTextField(labelWithString: "")
  let detailEnvironmentValueLabel = NSTextField(labelWithString: "")
  let detailInlineEnvironmentValueLabel = NSTextField(labelWithString: "")
  let detailWorkingDirectoryValueLabel = NSTextField(labelWithString: "")
  let detailVariablesValueLabel = NSTextField(labelWithString: "")
  let detailEventSourcesValueLabel = NSTextField(labelWithString: "")
  let detailMissingSourceValueLabel = NSTextField(labelWithString: "")
  let workflowGraphPaneView = DaemonWorkflowGraphPaneView()
  private let onRefresh: () -> Void
  let onSelectProfile: (String) -> Void
  let onCreateProfile: (String) -> RielaAppProfileName?
  let onRemoveProfile: (RielaAppProfileName) -> Bool
  let onAddDirectory: () -> Void
  let onAddURL: (String) -> Void
  let onAddInstance: (DaemonWorkflowAddInstanceRequest) -> Void
  private let onRevealSelectedSource: (String) -> Void
  private let onRelinkInstance: (String, String) -> Void
  private let onRenameWorkflow: (String) -> Void
  private let onRemoveInstance: (String) -> Void
  private let onOpenViewer: (String) -> Void
  private let onOpenExecutionLog: (String) -> Void
  private let onOpenWorkflowSourceViewer: (String) -> Void
  let defaultInstanceId: (String) -> String
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

  var candidates: [RielaAppDaemonWorkflowCandidate] = []
  var workflowSources: [RielaAppDaemonWorkflowCandidate] = []
  var profileWorkflowSources: [RielaAppProfileName: [RielaAppDaemonWorkflowCandidate]] = [:]
  var profileInstances: [RielaAppProfiledWorkflowInstance] = []
  var state = RielaAppDaemonWorkflowState()
  var snapshots: [String: RielaAppDaemonWorkflowRuntime.RuntimeSnapshot] = [:]
  var profileName = RielaAppProfileName.default
  var profileNames: [RielaAppProfileName] = [.default]
  var profileFilterName: RielaAppProfileName? = .default
  private var selectedIdentity: String?
  private var selectedIdentityByProfile: [RielaAppProfileName: String] = [:]
  private var isUpdatingProfileControls = false
  private var profileControlsFingerprint = ""
  weak var activeAddInstanceWindow: NSWindow?
  var pendingAddInstanceSheetAction: AddInstanceSheetAction?
  var activeAddInstancePathTargets: [AnyObject] = []
  var activeConfigurationEditorTargets: [AnyObject] = []
  private var isUpdatingTableSelection = false
  var cachedInstanceRows: [ConfiguredWorkflowInstanceRow] = []
  var instanceRowsFingerprint = ""
  var renderedAssistantSettings: RielaAppAssistantSettings?
  var instancesListView: NSView?
  weak var contentHost: DaemonWorkflowWindowContentHostView?
  var instanceDetailView: NSView?
  var addInstanceSelectionView: NSView?
  var configurationEditorView: NSView?
  var sourcesOverviewView: NSView?
  var workflowSourceDetailView: NSView?
  var assistantOverviewView: NSView?
  var profilesOverviewView: NSView?
  var profileDetailView: NSView?
  var profilesOverviewFingerprint: String?
  var sourcesOverviewFingerprint: String?
  weak var workflowSettingRow: NSView?
  weak var missingSourceSettingRow: NSView?
  weak var statusSettingRow: NSView?
  weak var nameSettingRow: NSView?
  weak var environmentSettingRow: NSView?
  weak var inlineEnvironmentSettingRow: NSView?
  weak var workingDirectorySettingRow: NSView?
  weak var variablesSettingRow: NSView?
  weak var eventSourcesSettingRow: NSView?
  weak var relinkSourceActionRow: NSView?
  weak var openViewerActionRow: NSView?
  weak var openExecutionLogActionRow: NSView?
  weak var startInstanceActionRow: NSView?
  weak var stopInstanceActionRow: NSView?
  weak var restartInstanceActionRow: NSView?
  weak var configurationEditorStatusLabel: NSTextField?
  var inlineEnvironmentTextView: NSTextView?
  var workflowVariablesTextView: NSTextView?
  var eventSourceTextView: NSTextView?
  var eventBindingTextView: NSTextView?
  var eventSourceModeControl: NSSegmentedControl?
  var eventSourceKindPopup: NSPopUpButton?
  var eventSourceIdField: NSTextField?
  weak var eventSourceFormView: NSView?
  weak var eventSourceJSONView: NSView?
  var configurationEditorInitialSignature: String?
  var configurationEditorDiscardArmed = false
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
  var isShowingProfileDetail = false
  var isShowingWorkflowSourceDetail = false
  var selectedProfileDetailName: RielaAppProfileName?
  var profileDetailMode: ProfileDetailMode = .overview
  var activeSidebarPane: SidebarPane = .instances
  var selectedWorkflowSourceId: String?
  var workflowSourceFilterText = ""
  var instanceFilterText = ""
  var rawInstanceRowsCount = 0
  private(set) var statusMessageHistory: [SequencedRielaAppStatusMessage] = []
  private var lastStatusMessageSequence: Int?
  private var dismissedStatusMessageSequence: Int?
  private var statusDismissTimer: Timer?

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
    onOpenViewer: @escaping (String) -> Void = { _ in },
    onOpenExecutionLog: @escaping (String) -> Void = { _ in },
    onOpenWorkflowSourceViewer: @escaping (String) -> Void = { _ in },
    defaultInstanceId: @escaping (String) -> String = { _ in "" },
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
    self.onOpenViewer = onOpenViewer
    self.onOpenExecutionLog = onOpenExecutionLog
    self.onOpenWorkflowSourceViewer = onOpenWorkflowSourceViewer
    self.defaultInstanceId = defaultInstanceId
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
    let sequencedMessage = statusMessage.isEmpty
      ? nil
      : SequencedRielaAppStatusMessage(sequence: 0, message: .classified(statusMessage))
    update(
      profileName: profileName,
      profileNames: profileNames,
      candidates: candidates,
      workflowSources: workflowSources,
      profileWorkflowSources: profileWorkflowSources,
      profileInstances: profileInstances,
      state: state,
      snapshots: snapshots,
      assistantAssistance: assistantAssistance,
      statusMessage: sequencedMessage
    )
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
    statusMessage: SequencedRielaAppStatusMessage?
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
    updateStatusBanner(statusMessage)
    if didChangeProfile {
      profileFilterName = profileName
    }
    if didChangeProfile || selectedIdentity == nil {
      selectedIdentity = selectedIdentityByProfile[profileName]
    }
    let rowsChanged = rebuildInstanceRows()
    updateProfileControls()
    rebuildSourcesOverviewView()
    if isShowingWorkflowSourceDetail {
      showWorkflowSourceDetail()
    }
    rebuildProfilesOverviewView()
    updateOverviewSummaries()
    updateAssistantPanel()
    if isShowingProfileDetail, let selectedProfileDetailName {
      if profileNames.contains(selectedProfileDetailName) {
        showProfileDetail(selectedProfileDetailName, mode: profileDetailMode)
      } else {
        showProfilesPane()
      }
    }
    if rowsChanged || didChangeProfile {
      instanceTable.reloadData()
    }
    updateInstancesEmptyStateVisibility()
    if isShowingAddInstanceSelection {
      showAddInstanceSelectionPane()
    }
    if rowsChanged || didChangeProfile || selectedIdentity == nil {
      restoreSelection(scrollToSelection: didChangeProfile)
    }
    updateInstanceDetail()
  }
}

extension DaemonWorkflowWindowController {
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

  @objc func instanceSearchChanged() {
    instanceFilterText = instanceSearchField.stringValue
    let rowsChanged = rebuildInstanceRows()
    if rowsChanged {
      instanceTable.reloadData()
    }
    updateInstancesEmptyStateVisibility()
    restoreSelection()
    updateInstanceDetail()
    window?.makeFirstResponder(instanceSearchField)
  }

  func updateInstancesEmptyStateVisibility() {
    emptyInstancesGuideView.isHidden = rawInstanceRowsCount != 0
    emptyInstancesLabel.stringValue = rawInstanceRowsCount == 0
      ? ""
      : "No instances match the current filter."
    emptyInstancesLabel.isHidden = rawInstanceRowsCount == 0 || !instanceRows.isEmpty
  }

  private func updateStatusBanner(_ sequencedMessage: SequencedRielaAppStatusMessage?) {
    guard let sequencedMessage else {
      statusBannerView.isHidden = true
      settingsRootView?.needsLayout = true
      return
    }
    guard sequencedMessage.sequence != lastStatusMessageSequence else {
      return
    }
    lastStatusMessageSequence = sequencedMessage.sequence
    appendStatusMessageHistory(sequencedMessage)
    guard dismissedStatusMessageSequence != sequencedMessage.sequence else {
      return
    }
    statusDismissTimer?.invalidate()
    statusBannerView.configure(message: sequencedMessage.message, history: statusMessageHistory.map(\.message))
    statusBannerView.isHidden = false
    settingsRootView?.needsLayout = true
    guard sequencedMessage.message.severity == .info else {
      return
    }
    statusDismissTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.dismissStatusBanner()
      }
    }
  }

  func dismissStatusBanner() {
    dismissedStatusMessageSequence = lastStatusMessageSequence
    statusDismissTimer?.invalidate()
    statusDismissTimer = nil
    statusBannerView.isHidden = true
    settingsRootView?.needsLayout = true
  }

  private func appendStatusMessageHistory(_ sequencedMessage: SequencedRielaAppStatusMessage) {
    statusMessageHistory.removeAll { $0.sequence == sequencedMessage.sequence }
    statusMessageHistory.append(sequencedMessage)
    statusMessageHistory = Array(statusMessageHistory.suffix(statusMessageHistoryLimit))
  }

  @objc func openProfilesFromSidebar() {
    showProfilesPane()
  }

  @objc func profilePopupChanged() {
    guard !isUpdatingProfileControls, let title = profilePopup.selectedItem?.title else {
      return
    }
    if title == Self.allProfilesMenuTitle {
      profileFilterName = nil
      selectedIdentity = nil
      _ = rebuildInstanceRows()
      updateProfileControls()
      instanceTable.reloadData()
      updateInstancesEmptyStateVisibility()
      restoreSelection()
      updateInstanceDetail()
      return
    }
    onSelectProfile(title)
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
    var retryMessage: String?
    while true {
      switch promptForRelinkSourceOption(workflowSourceOptions(profileName: row.profileName), retryMessage: retryMessage) {
      case let .selected(option):
        onRelinkInstance(row.id, option.sourceIdentity)
        return
      case let .retry(message):
        retryMessage = message
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
    showInstanceRemovalConfirmation()
  }

  @objc func confirmRemoveSelectedInstance() {
    guard let identity = selectedRow()?.id else {
      return
    }
    onRemoveInstance(identity)
    showInstancesList()
  }

  @objc func cancelRemoveSelectedInstance() {
    showInstanceDetailOverview()
  }

  @objc func openSelectedInstanceViewer() {
    guard let row = selectedRow(), row.state != .needsSource else {
      return
    }
    onOpenViewer(row.id)
  }

  @objc func openSelectedInstanceExecutionLog() {
    guard let row = selectedRow(), row.state != .needsSource else {
      return
    }
    onOpenExecutionLog(row.id)
  }

  @objc func openSelectedWorkflowSourceViewer() {
    guard let selectedWorkflowSourceId else {
      return
    }
    onOpenWorkflowSourceViewer(selectedWorkflowSourceId)
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
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
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
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    instanceDetailPane = .overview
    updateInstanceDetail()
    showContentPane(instanceDetailView)
    updateNavigationState()
    updateSidebarSelection()
  }

  func selectCandidate(identity: String) {
    rememberSelection(identity)
    restoreSelection(scrollToSelection: true)
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
    detailSummaryLabel.stringValue = rielaAppMetadataText([
      row.state.rawValue,
      "Profile \(row.profileName.rawValue)"
    ])
    detailStatusValueLabel.stringValue = stateStatusText(for: row)
    updateDetailStatusIndicator(for: row.state)
    detailNameValueLabel.stringValue = row.instanceName
    detailWorkflowValueLabel.stringValue = rielaAppMetadataText([
      "Profile \(row.profileName.rawValue)",
      row.workflowName
    ])
    detailMissingSourceValueLabel.stringValue = rielaAppMetadataText(["Missing source", row.sourceIdentity])
    if let candidate = row.candidate {
      updateWorkflowGraph(candidate: candidate)
      detailEnvironmentValueLabel.stringValue = row.hasMissingRequiredEnvironment
        ? environmentColumnStatus(candidate)
        : environmentSummary(candidate)
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? candidate.workingDirectory
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = candidate.eventSourceSummary
    } else {
      workflowGraphPaneView.showUnavailable("Workflow source is missing")
      detailEnvironmentValueLabel.stringValue = "Needs source"
      detailInlineEnvironmentValueLabel.stringValue = "\(row.preference.environmentVariables.count) values"
      detailWorkingDirectoryValueLabel.stringValue = row.preference.workingDirectory ?? "Needs source"
      detailVariablesValueLabel.stringValue = "\(row.preference.defaultVariables.count) values"
      detailEventSourcesValueLabel.stringValue = "Workflow source is missing"
    }
    updateDetailRowAccessibilityValues()
    updateDetailActions(for: row.state)
  }

  private func stateStatusText(for row: ConfiguredWorkflowInstanceRow) -> String {
    guard !row.stateDetail.isEmpty else {
      return row.state.rawValue
    }
    return "\(row.state.rawValue) - \(row.stateDetail)"
  }

  private func updateDetailStatusIndicator(for state: InstanceState) {
    detailStatusProgressIndicator.isHidden = !state.isTransitional
    if state.isTransitional {
      detailStatusProgressIndicator.startAnimation(nil)
    } else {
      detailStatusProgressIndicator.stopAnimation(nil)
    }
  }

  private func updateWorkflowGraph(candidate: RielaAppDaemonWorkflowCandidate) {
    do {
      workflowGraphPaneView.update(model: try DaemonWorkflowGraphModel.load(workflowDirectory: candidate.workflowDirectory))
    } catch {
      workflowGraphPaneView.showUnavailable("Workflow graph unavailable: \(error)")
    }
  }

  private func updateDetailRowAccessibilityValues() {
    workflowSettingRow?.setAccessibilityValue(detailWorkflowValueLabel.stringValue)
    missingSourceSettingRow?.setAccessibilityValue(detailMissingSourceValueLabel.stringValue)
    statusSettingRow?.setAccessibilityValue(detailStatusValueLabel.stringValue)
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
    statusSettingRow?.isHidden = needsSource
    nameSettingRow?.isHidden = needsSource
    environmentSettingRow?.isHidden = needsSource
    inlineEnvironmentSettingRow?.isHidden = needsSource
    workingDirectorySettingRow?.isHidden = needsSource
    variablesSettingRow?.isHidden = needsSource
    eventSourcesSettingRow?.isHidden = needsSource
    relinkSourceActionRow?.isHidden = !needsSource
    openViewerActionRow?.isHidden = needsSource
    openExecutionLogActionRow?.isHidden = needsSource
    startInstanceActionRow?.isHidden = !showsStartAction(for: state)
    stopInstanceActionRow?.isHidden = !showsStopAction(for: state)
    restartInstanceActionRow?.isHidden = !showsRestartAction(for: state)
  }

  func showInstanceDetailOverview() {
    isShowingAddInstanceSelection = false
    isShowingWorkflowSourceDetail = false
    instanceDetailPane = .overview
    updateInstanceDetail()
    showContentPane(instanceDetailView)
    updateNavigationState()
    updateSidebarSelection()
  }

  func showInstanceRemovalConfirmation() {
    guard let row = selectedRow() else {
      return
    }
    isShowingAddInstanceSelection = false
    isShowingWorkflowSourceDetail = false
    instanceDetailPane = .removalConfirmation
    instanceDetailView?.removeFromSuperview()
    let detail = buildInstanceRemovalConfirmationView(row)
    detail.translatesAutoresizingMaskIntoConstraints = true
    detail.isHidden = false
    instanceDetailView = detail
    showContentPane(detail)
    navigationTitleLabel.stringValue = row.instanceName
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

  private func restoreSelection(scrollToSelection: Bool = false) {
    guard let selectedIdentity = selectedIdentity ?? selectedIdentityByProfile[profileName] ?? firstSelectableCandidateId() else {
      instanceTable.deselectAll(nil)
      return
    }
    self.selectedIdentity = selectedIdentity
    if select(
      identity: selectedIdentity,
      in: instanceTable,
      rows: instanceRows,
      scrollToSelection: scrollToSelection
    ) {
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

  private func select(
    identity: String,
    in tableView: NSTableView,
    rows: [ConfiguredWorkflowInstanceRow],
    scrollToSelection: Bool = false
  ) -> Bool {
    guard let row = rows.firstIndex(where: { $0.id == identity }) else {
      return false
    }
    isUpdatingTableSelection = true
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    if scrollToSelection {
      tableView.scrollRowToVisible(row)
    }
    if scrollToSelection, row == 0, let scrollView = tableView.enclosingScrollView {
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    isUpdatingTableSelection = false
    return true
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
    let fingerprint = profileNames.map(\.rawValue).joined(separator: "\u{1f}")
    if fingerprint != profileControlsFingerprint {
      profileControlsFingerprint = fingerprint
      profilePopup.removeAllItems()
      profilePopup.addItem(withTitle: Self.allProfilesMenuTitle)
      profilePopup.menu?.addItem(.separator())
      profilePopup.addItems(withTitles: profileNames.map(\.rawValue))
    }
    let selectedTitle = profileFilterName?.rawValue ?? Self.allProfilesMenuTitle
    if profilePopup.selectedItem?.title != selectedTitle {
      profilePopup.selectItem(withTitle: selectedTitle)
    }
    isUpdatingProfileControls = false
  }

  func windowWillClose(_ notification: Notification) {
    statusDismissTimer?.invalidate()
    statusDismissTimer = nil
    onWindowWillClose()
  }
}

#endif
