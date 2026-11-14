#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaViewer

@MainActor
final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
  private enum Layout {
    static let initialWindowSize = NSSize(width: 640, height: 560)
    static let minimumWindowSize = NSSize(width: 560, height: 380)
    static let sidebarWidth: CGFloat = 180
    static let assistantExpandedHeight: CGFloat = 176
    static let assistantFoldedHeight: CGFloat = 42
    static let liveRefreshInterval: TimeInterval = 2
  }

  let loader = WorkflowViewerLoader()
  let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let viewerModeControl = NSSegmentedControl(labels: ["Outline", "Timeline"], trackingMode: .selectOne, target: nil, action: nil)
  private let templatePopup = NSPopUpButton()
  private let workflowTitleLabel = NSTextField(labelWithString: "Select Workflow")
  let workflowSubtitleLabel = NSTextField(labelWithString: "")
  let currentDirectoryLabel = NSTextField(labelWithString: "-")
  let environmentVariablesLabel = NSTextField(labelWithString: "-")
  let workflowVariablesLabel = NSTextField(labelWithString: "-")
  weak var currentDirectorySettingRow: RielaAppSelectableSettingsRow?
  weak var environmentVariablesSettingRow: RielaAppSelectableSettingsRow?
  weak var workflowVariablesSettingRow: RielaAppSelectableSettingsRow?
  private let detailTextView = NSTextView()
  private let logTextView = NSTextView()
  private let structureTextView = NSTextView()
  let workflowGraphPaneView = DaemonWorkflowGraphPaneView()
  lazy var workflowTimelinePaneView = WorkflowExecutionTimelinePaneView(
    dateFormatter: timelineDateFormatter,
    durationFormatter: { [weak self] duration in
      self?.timelineDuration(duration) ?? (duration.map { String(format: "%.2fs", max(0, $0)) } ?? "running")
    }
  )
  private weak var contentTabView: NSTabView?
  let managerResponseBanner = NSStackView()
  let managerResponseLabel = NSTextField(labelWithString: "")
  let managerResponseStatusLabel = NSTextField(labelWithString: "")
  let managerRespondButton = NSButton(title: "Respond", target: nil, action: nil)
  private let modelPopup = NSPopUpButton()
  private let backendPopup = NSPopUpButton()
  private let effortPopup = NSPopUpButton()
  weak var modelOverrideRow: RielaAppSettingsRow?
  weak var backendOverrideRow: RielaAppSettingsRow?
  weak var effortOverrideRow: RielaAppSettingsRow?
  weak var nodePatchOverrideRow: RielaAppSettingsRow?
  private let saveNodePatchButton = NSButton(title: "", target: nil, action: nil)
  private let clearNodePatchButton = NSButton(title: "", target: nil, action: nil)
  private let templateTextView = NSTextView()
  private let saveTemplateButton = NSButton(title: "", target: nil, action: nil)
  private let reloadTemplateButton = NSButton(title: "", target: nil, action: nil)
  let assistantPanelHost = NSView()
  let assistantPanelTitleLabel = NSTextField(labelWithString: "Riela Setup Assistant")
  let assistantAvailabilityLabel = NSTextField(labelWithString: "")
  let assistantContextLabel = NSTextField(labelWithString: "")
  let assistantFoldButton = NSButton(title: "", target: nil, action: nil)
  let assistantClearButton = NSButton(title: "", target: nil, action: nil)
  let assistantPromptField = NSTextField(string: "")
  let assistantSendButton = NSButton(title: "", target: nil, action: nil)
  var assistantTranscriptTextView: NSTextView?
  weak var assistantTranscriptScrollView: NSScrollView?
  weak var assistantInputStackView: NSStackView?
  var assistantPanelHeightConstraint: NSLayoutConstraint?
  var assistantPanelExpandedWidthConstraint: NSLayoutConstraint?
  var assistantPanelFoldedWidthConstraint: NSLayoutConstraint?
  let timelineDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
  let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  let detailTextColor = NSColor.labelColor
  let detailBackgroundColor = NSColor.controlBackgroundColor
  private let templateFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  var workflowDirectory: String?
  private var sessionStoreRoot: String?
  var state: WorkflowViewerState?
  var selectedNodeId: String?
  private var selectedTemplateFileId: String?
  var currentDirectory: String?
  private var environmentVariablesSummary: String?
  private var workflowVariablesSummary: String?
  private var nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:]
  private var onSaveNodePatch: ((String, RielaAppDaemonWorkflowNodePatch?) -> Bool)?
  var onSetWorkingDirectory: (() -> String?)?
  var onSetEnvironmentVariables: (() -> String?)?
  var onSetWorkflowVariables: (() -> String?)?
  var onSendManagerMessage: ((String, String, String, String) -> String?)?
  var assistantProfileName = RielaAppProfileName.default
  var assistantSettings = RielaAppAssistantSettings()
  var onSaveAssistantSettings: ((RielaAppAssistantSettings) -> String?)?
  var onSubmitAssistantMessage: ((String, String?) -> Void)?
  private var liveRefreshTask: Task<Void, Never>?

  var hasLiveRefreshTimerForTesting: Bool {
    liveRefreshTask != nil
  }

  init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Layout.initialWindowSize),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Riela Workflow Viewer"
    window.minSize = Layout.minimumWindowSize
    super.init(window: window)
    window.delegate = self
    buildContent(in: window)
  }

  deinit {
    liveRefreshTask?.cancel()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func show(
    workflowDirectory: String,
    sessionStoreRoot: String?,
    currentDirectory: String? = nil,
    environmentVariablesSummary: String? = nil,
    workflowVariablesSummary: String? = nil,
    nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:],
    onSaveNodePatch: ((String, RielaAppDaemonWorkflowNodePatch?) -> Bool)? = nil,
    onSetWorkingDirectory: (() -> String?)? = nil,
    onSetEnvironmentVariables: (() -> String?)? = nil,
    onSetWorkflowVariables: (() -> String?)? = nil,
    onSendManagerMessage: ((String, String, String, String) -> String?)? = nil,
    assistantProfileName: RielaAppProfileName = .default,
    assistantSettings: RielaAppAssistantSettings = RielaAppAssistantSettings(),
    onSaveAssistantSettings: ((RielaAppAssistantSettings) -> String?)? = nil,
    onSubmitAssistantMessage: ((String, String?) -> Void)? = nil,
    openTimeline: Bool = false
  ) {
    if self.workflowDirectory != workflowDirectory {
      selectedNodeId = nil
    }
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.currentDirectory = currentDirectory
    self.environmentVariablesSummary = environmentVariablesSummary
    self.workflowVariablesSummary = workflowVariablesSummary
    self.nodePatches = nodePatches
    self.onSaveNodePatch = onSaveNodePatch
    self.onSetWorkingDirectory = onSetWorkingDirectory
    self.onSetEnvironmentVariables = onSetEnvironmentVariables
    self.onSetWorkflowVariables = onSetWorkflowVariables
    self.onSendManagerMessage = onSendManagerMessage
    self.assistantProfileName = assistantProfileName
    self.assistantSettings = assistantSettings
    self.onSaveAssistantSettings = onSaveAssistantSettings
    self.onSubmitAssistantMessage = onSubmitAssistantMessage
    updateInstanceSettingRows()
    updateCurrentDirectoryLabel()
    updateVariableLabels()
    updateAssistantPanel()
    refresh()
    if openTimeline {
      selectTimelineMode()
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func buildContent(in window: NSWindow) {
    guard let contentView = window.contentView else {
      return
    }
    let splitView = NSSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.translatesAutoresizingMaskIntoConstraints = false

    outlineView.headerView = nil
    outlineView.dataSource = self
    outlineView.delegate = self
    rielaAppConfigureSettingsTableSelection(outlineView)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workflow-node"))
    column.title = "Workflow"
    column.width = Layout.sidebarWidth
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column

    let outlineScroll = NSScrollView()
    outlineScroll.documentView = outlineView
    outlineScroll.hasVerticalScroller = true
    outlineScroll.hasHorizontalScroller = false
    outlineScroll.translatesAutoresizingMaskIntoConstraints = false
    let sidebarWidth = outlineScroll.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth)
    sidebarWidth.priority = .defaultHigh
    sidebarWidth.isActive = true

    let rightStack = NSStackView()
    rightStack.orientation = .vertical
    rightStack.alignment = .width
    rightStack.spacing = 8
    rightStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    rightStack.translatesAutoresizingMaskIntoConstraints = false

    let refreshButton = iconButton(
      symbolName: "arrow.clockwise",
      accessibilityLabel: "Refresh Viewer",
      action: #selector(refreshButtonPressed)
    )
    sessionPopup.target = self
    sessionPopup.action = #selector(sessionSelectionChanged)
    configureCompactPopup(sessionPopup, maximumWidth: 260)
    viewerModeControl.selectedSegment = 0
    viewerModeControl.target = self
    viewerModeControl.action = #selector(viewerModeChanged)
    viewerModeControl.setAccessibilityLabel("Viewer Mode")
    let sessionRow = workflowViewerControlRow(title: "Session", views: [sessionPopup, refreshButton, viewerModeControl])

    configureCompactPopup(modelPopup, maximumWidth: 220)
    configureCompactPopup(backendPopup, maximumWidth: 180)
    configureCompactPopup(effortPopup, maximumWidth: 150)
    saveNodePatchButton.target = self
    saveNodePatchButton.action = #selector(saveNodePatchButtonPressed)
    configureIconButton(saveNodePatchButton, symbolName: "square.and.arrow.down", accessibilityLabel: "Save Node Patch")
    clearNodePatchButton.target = self
    clearNodePatchButton.action = #selector(clearNodePatchButtonPressed)
    configureIconButton(clearNodePatchButton, symbolName: "trash", accessibilityLabel: "Clear Node Patch")
    let modelOverrideRow = workflowViewerControlRow(title: "Model", views: [modelPopup])
    let backendOverrideRow = workflowViewerControlRow(title: "Backend", views: [backendPopup])
    let effortOverrideRow = workflowViewerControlRow(title: "Reasoning Effort", views: [effortPopup])
    let nodePatchOverrideRow = workflowViewerControlRow(
      title: "Runtime Overrides",
      views: [saveNodePatchButton, clearNodePatchButton]
    )
    self.modelOverrideRow = modelOverrideRow
    self.backendOverrideRow = backendOverrideRow
    self.effortOverrideRow = effortOverrideRow
    self.nodePatchOverrideRow = nodePatchOverrideRow
    let nodeOverrideStack = NSStackView(views: [
      modelOverrideRow,
      backendOverrideRow,
      effortOverrideRow,
      nodePatchOverrideRow
    ])
    nodeOverrideStack.orientation = .vertical
    nodeOverrideStack.alignment = .width
    nodeOverrideStack.spacing = 8

    templatePopup.target = self
    templatePopup.action = #selector(templateSelectionChanged)
    configureCompactPopup(templatePopup, maximumWidth: 260)
    saveTemplateButton.target = self
    saveTemplateButton.action = #selector(saveTemplateButtonPressed)
    configureIconButton(saveTemplateButton, symbolName: "square.and.arrow.down", accessibilityLabel: "Save Template")
    reloadTemplateButton.target = self
    reloadTemplateButton.action = #selector(reloadTemplateButtonPressed)
    configureIconButton(reloadTemplateButton, symbolName: "arrow.clockwise", accessibilityLabel: "Reload Template")
    let templateRow = workflowViewerControlRow(
      title: "Template",
      views: [templatePopup, saveTemplateButton, reloadTemplateButton]
    )

    currentDirectoryLabel.lineBreakMode = .byTruncatingMiddle
    environmentVariablesLabel.lineBreakMode = .byTruncatingTail
    workflowVariablesLabel.lineBreakMode = .byTruncatingTail
    let instanceSettingsTitle = NSTextField(labelWithString: "Instance Settings")
    instanceSettingsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let currentDirectoryRow = instanceSettingRow(
      title: "Current Directory",
      valueLabel: currentDirectoryLabel,
      action: #selector(currentDirectoryRowSelected)
    )
    let environmentVariablesRow = instanceSettingRow(
      title: "Environment Variables",
      valueLabel: environmentVariablesLabel,
      action: #selector(environmentVariablesRowSelected)
    )
    let workflowVariablesRow = instanceSettingRow(
      title: "Workflow Variables",
      valueLabel: workflowVariablesLabel,
      action: #selector(workflowVariablesRowSelected)
    )
    currentDirectorySettingRow = currentDirectoryRow
    environmentVariablesSettingRow = environmentVariablesRow
    workflowVariablesSettingRow = workflowVariablesRow
    let instanceSettingsStack = NSStackView(views: [
      currentDirectoryRow,
      environmentVariablesRow,
      workflowVariablesRow
    ])
    instanceSettingsStack.orientation = .vertical
    instanceSettingsStack.alignment = .width
    instanceSettingsStack.spacing = 8
    let nodeOverrideTitle = NSTextField(labelWithString: "Node Overrides")
    nodeOverrideTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    workflowTitleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
    workflowTitleLabel.lineBreakMode = .byTruncatingMiddle
    workflowSubtitleLabel.textColor = .secondaryLabelColor
    workflowSubtitleLabel.lineBreakMode = .byTruncatingMiddle
    let headerStack = NSStackView(views: [workflowTitleLabel, workflowSubtitleLabel])
    headerStack.orientation = .vertical
    headerStack.alignment = .leading
    headerStack.spacing = 2
    configureReadOnlyTextView(detailTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    configureReadOnlyTextView(logTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    configureReadOnlyTextView(structureTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    let detailScroll = scrollView(for: detailTextView)
    let logScroll = scrollView(for: logTextView)
    let structureScroll = scrollView(for: structureTextView)
    let graphView = graphTabView()
    let timelineView = timelineTabView()
    let managerResponseView = managerResponseBarView()

    templateTextView.isEditable = false
    templateTextView.isRichText = false
    templateTextView.font = templateFont
    templateTextView.textColor = .labelColor
    templateTextView.backgroundColor = detailBackgroundColor
    templateTextView.drawsBackground = true
    templateTextView.textContainerInset = NSSize(width: 10, height: 10)
    templateTextView.isVerticallyResizable = true
    templateTextView.isHorizontallyResizable = true
    templateTextView.autoresizingMask = [.width]
    templateTextView.textContainer?.widthTracksTextView = true
    templateTextView.textContainer?.containerSize = NSSize(
      width: detailScrollContentWidthFallback,
      height: CGFloat.greatestFiniteMagnitude
    )
    let templateScroll = NSScrollView()
    templateScroll.documentView = templateTextView
    templateScroll.hasVerticalScroller = true
    templateScroll.hasHorizontalScroller = true
    templateScroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(templateScroll)

    let editStack = NSStackView(views: [
      managerResponseView,
      detailScroll,
      templateRow,
      templateScroll
    ])
    editStack.orientation = .vertical
    editStack.alignment = .width
    editStack.spacing = 8
    editStack.translatesAutoresizingMaskIntoConstraints = false

    let variablesStack = NSStackView(views: [
      instanceSettingsTitle,
      instanceSettingsStack,
      nodeOverrideTitle,
      nodeOverrideStack
    ])
    variablesStack.orientation = .vertical
    variablesStack.alignment = .width
    variablesStack.spacing = 8
    variablesStack.translatesAutoresizingMaskIntoConstraints = false

    let tabView = NSTabView()
    contentTabView = tabView
    tabView.translatesAutoresizingMaskIntoConstraints = false
    tabView.addTabViewItem(tabItem(label: "Overview", view: editStack))
    tabView.addTabViewItem(tabItem(label: "Variables", view: variablesStack))
    tabView.addTabViewItem(tabItem(label: "Graph", view: graphView))
    tabView.addTabViewItem(tabItem(label: "Timeline", view: timelineView))
    tabView.addTabViewItem(tabItem(label: "Run Log", view: logScroll))
    tabView.addTabViewItem(tabItem(label: "Structure", view: structureScroll))

    rightStack.addArrangedSubview(headerStack)
    rightStack.addArrangedSubview(sessionRow)
    rightStack.addArrangedSubview(tabView)
    applyPreferredHeight(140, to: detailScroll)
    applyPreferredHeight(180, to: templateScroll)
    applyPreferredHeight(300, to: tabView)

    splitView.addArrangedSubview(outlineScroll)
    splitView.addArrangedSubview(rightStack)
    installViewerRoot(splitView: splitView, in: contentView)
    splitView.setPosition(Layout.sidebarWidth, ofDividerAt: 0)
    updateAssistantPanel()
  }

  @objc private func refreshButtonPressed() {
    refresh()
  }

  func windowWillClose(_ notification: Notification) {
    stopLiveRefreshTimer()
  }

  private func startLiveRefreshTimer() {
    guard liveRefreshTask == nil else {
      return
    }
    liveRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: UInt64(Layout.liveRefreshInterval * 1_000_000_000))
        } catch {
          break
        }
        guard !Task.isCancelled else {
          break
        }
        self?.refresh()
      }
    }
  }

  private func stopLiveRefreshTimer() {
    liveRefreshTask?.cancel()
    liveRefreshTask = nil
  }

  @objc private func templateSelectionChanged() {
    selectedTemplateFileId = selectedTemplateFile()?.id
    loadSelectedTemplateFile()
  }

  @objc private func reloadTemplateButtonPressed() {
    loadSelectedTemplateFile()
  }

  @objc private func currentDirectoryRowSelected() {
    guard let onSetWorkingDirectory else {
      setViewerMessage("Current directory cannot be edited here")
      return
    }
    currentDirectory = onSetWorkingDirectory()
    updateCurrentDirectoryLabel()
  }

  @objc private func environmentVariablesRowSelected() {
    guard let onSetEnvironmentVariables else {
      setViewerMessage("Environment variables cannot be edited here")
      return
    }
    environmentVariablesSummary = onSetEnvironmentVariables()
    updateVariableLabels()
  }

  @objc private func workflowVariablesRowSelected() {
    guard let onSetWorkflowVariables else {
      setViewerMessage("Workflow variables cannot be edited here")
      return
    }
    workflowVariablesSummary = onSetWorkflowVariables()
    updateVariableLabels()
  }

  private func updateCurrentDirectoryLabel() {
    let path = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    currentDirectoryLabel.stringValue = (path?.isEmpty == false ? path : nil) ?? "-"
  }

  private func updateVariableLabels() {
    environmentVariablesLabel.stringValue = environmentVariablesSummary ?? "-"
    workflowVariablesLabel.stringValue = workflowVariablesSummary ?? "-"
  }

  @objc private func saveNodePatchButtonPressed() {
    guard let selectedNode = selectedNode(), let patch = selectedNodePatchFromControls(for: selectedNode) else {
      return
    }
    guard let onSaveNodePatch else {
      setViewerMessage("Node patches cannot be edited here")
      return
    }
    if onSaveNodePatch(selectedNode.nodeId, patch.isEmpty ? nil : patch) {
      if patch.isEmpty {
        nodePatches.removeValue(forKey: selectedNode.nodeId)
        setViewerMessage("Cleared node patch for \(selectedNode.nodeId)")
      } else {
        nodePatches[selectedNode.nodeId] = patch
        setViewerMessage("Saved node patch for \(selectedNode.nodeId)")
      }
      updateNodePatchControls(for: selectedNode)
    } else {
      setViewerMessage("Failed to save node patch for \(selectedNode.nodeId)")
    }
  }

  @objc private func clearNodePatchButtonPressed() {
    guard let selectedNode = selectedNode() else {
      return
    }
    guard let onSaveNodePatch else {
      setViewerMessage("Node patches cannot be edited here")
      return
    }
    if onSaveNodePatch(selectedNode.nodeId, nil) {
      nodePatches.removeValue(forKey: selectedNode.nodeId)
      setViewerMessage("Cleared node patch for \(selectedNode.nodeId)")
      updateNodePatchControls(for: selectedNode)
    } else {
      setViewerMessage("Failed to clear node patch for \(selectedNode.nodeId)")
    }
  }

  @objc private func saveTemplateButtonPressed() {
    guard let workflowDirectory, let templateFile = selectedTemplateFile() else {
      return
    }
    do {
      try loader.saveTemplateFile(
        templateTextView.string,
        templateFile: templateFile,
        workflowDirectory: workflowDirectory
      )
      setViewerMessage("Saved \(templateFile.relativePath)")
    } catch {
      setViewerMessage("Failed to save template: \(error)")
    }
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
      updateSessionPopup(for: self.state)
      outlineView.reloadData()
      expandAll()
      updateDetails()
      updateLiveRefreshTimer()
    } catch {
      setViewerMessage("Failed to switch session: \(error)")
    }
  }

  func refresh() {
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
      updateGraphPane(for: loaded)
      updateTimelinePane(for: loaded)
      updateSessionPopup(for: loaded)
      outlineView.reloadData()
      expandAll()
      updateDetails()
      updateLiveRefreshTimer()
    } catch {
      workflowTitleLabel.stringValue = "Unable to load workflow"
      setViewerMessage("\(error)")
      setDetailText("\(error)")
      setLogText("")
      setStructureText("")
      updateManagerResponseControls(state: nil, session: nil)
      workflowGraphPaneView.showUnavailable("\(error)")
      workflowTimelinePaneView.showUnavailable("\(error)")
      updateLiveRefreshTimer()
    }
  }

  private func updateGraphPane(for state: WorkflowViewerState) {
    workflowGraphPaneView.update(model: DaemonWorkflowGraphModel(workflow: state.workflow))
  }

  private func updateSessionPopup(for state: WorkflowViewerState?) {
    sessionPopup.removeAllItems()
    guard let state, !state.sessions.isEmpty else {
      sessionPopup.addItem(withTitle: "No Sessions")
      sessionPopup.isEnabled = false
      return
    }
    sessionPopup.addItems(withTitles: state.sessions.map { sessionTitle($0) })
    sessionPopup.selectItem(at: state.selectedSessionIndex)
    sessionPopup.isEnabled = true
  }

  func updateDetails() {
    guard let state else {
      workflowTitleLabel.stringValue = "Select Workflow"
      setViewerMessage("")
      setDetailText("")
      setLogText("")
      setStructureText("")
      updateManagerResponseControls(state: nil, session: nil)
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
      return
    }
    let session = selectedSession(in: state)
    workflowTitleLabel.stringValue = state.workflow.workflowId
    setViewerMessage(sessionSummary(state: state, session: session))
    updateManagerResponseControls(state: state, session: session)
    guard let selectedNodeId else {
      setDetailText(workflowOverview(state: state))
      setLogText(renderRunLog(state: state, selectedStepId: nil, session: session).joined(separator: "\n"))
      setStructureText(renderWorkflowStructure(state: state).joined(separator: "\n"))
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
      return
    }
    var lines: [String] = []
    lines.append(selectedNodeId)
    if let node = flattenedNodes(state.nodes).first(where: { $0.id == selectedNodeId }) {
      lines.append(rielaAppMetadataText([
        "State \(workflowViewerStateText(node.state.rawValue))",
        "Node \(node.nodeId)",
        node.detail.map { "Detail \($0)" } ?? ""
      ]))
      if let configuration = node.configuration {
        lines.append("Configuration")
        lines.append(rielaAppMetadataText([
          "File \(configuration.nodeFile)",
          "Model \(configuration.model)",
          "Freeze \(configuration.modelFreeze ? "On" : "Off")",
          "Backend \(configuration.executionBackend?.rawValue ?? "-")",
          "Reasoning Effort \(configuration.effort?.rawValue ?? "-")"
        ]))
        if let patch = nodePatches[node.nodeId], !patch.isEmpty {
          lines.append("Patch")
          lines.append(rielaAppMetadataText([
            "Model \(patch.model ?? "-")",
            "Backend \(patch.executionBackend?.rawValue ?? "-")",
            "Reasoning Effort \(patch.effort?.rawValue ?? "-")"
          ]))
        }
      }
      if !node.templateFiles.isEmpty {
        lines.append("Template Files")
        lines.append(contentsOf: node.templateFiles.map { templateFile in
          let metadata = rielaAppMetadataText([
            templateFile.displayName,
            "Field \(templateFile.fieldPath)",
            "Role \(templateFile.role.label)",
            "Used by Step \(templateFile.isActiveForStep ? "Yes" : "No")"
          ])
          return "- \(metadata)"
        })
      }
      updateTemplateControls(for: node)
      updateNodePatchControls(for: node)
    } else {
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
    }
    lines.append("")
    lines.append("Workflow")
    lines.append(workflowOverview(state: state))
    if !state.diagnostics.isEmpty {
      lines.append("")
      lines.append("Diagnostics")
      lines.append(contentsOf: state.diagnostics.map { "- \($0)" })
    }
    setDetailText(lines.joined(separator: "\n"))
    setLogText(renderRunLog(state: state, selectedStepId: selectedNodeId, session: session).joined(separator: "\n"))
    setStructureText(renderWorkflowStructure(state: state).joined(separator: "\n"))
  }

  private func updateNodePatchControls(for node: WorkflowViewerNode?) {
    guard let configuration = node?.configuration else {
      configurePopup(modelPopup, titles: ["No node model"])
      configurePopup(backendPopup, titles: ["No backend"])
      configurePopup(effortPopup, titles: ["No effort"])
      modelPopup.isEnabled = false
      backendPopup.isEnabled = false
      effortPopup.isEnabled = false
      saveNodePatchButton.isEnabled = false
      clearNodePatchButton.isEnabled = false
      updateNodeOverrideRows(
        canEdit: false,
        modelCanEdit: false,
        reason: "Choose a node to edit overrides",
        modelReason: "Choose a node to edit overrides"
      )
      return
    }

    let patch = node.flatMap { nodePatches[$0.nodeId] }
    let modelOptions: [String]
    if configuration.modelFreeze {
      modelOptions = []
      configurePopup(modelPopup, titles: ["Frozen: \(configuration.model)"])
    } else {
      modelOptions = modelChoices(configuration: configuration, patch: patch)
      configurePopup(modelPopup, titles: ["Workflow default: \(configuration.model)"] + modelOptions)
      selectPopupValue(modelPopup, value: patch?.model, values: modelOptions)
    }

    let backendOptions = NodeExecutionBackend.allCases.map(\.rawValue)
    configurePopup(
      backendPopup,
      titles: ["Workflow default: \(configuration.executionBackend?.rawValue ?? "-")"] + backendOptions
    )
    selectPopupValue(backendPopup, value: patch?.executionBackend?.rawValue, values: backendOptions)

    let effortOptions = NodeReasoningEffort.allCases.map(\.rawValue)
    configurePopup(effortPopup, titles: ["Workflow default: \(configuration.effort?.rawValue ?? "-")"] + effortOptions)
    selectPopupValue(effortPopup, value: patch?.effort?.rawValue, values: effortOptions)

    let canEdit = onSaveNodePatch != nil
    modelPopup.isEnabled = canEdit && !configuration.modelFreeze
    backendPopup.isEnabled = canEdit
    effortPopup.isEnabled = canEdit
    saveNodePatchButton.isEnabled = canEdit
    clearNodePatchButton.isEnabled = canEdit && patch != nil
    updateNodeOverrideRows(
      canEdit: canEdit,
      modelCanEdit: canEdit && !configuration.modelFreeze,
      reason: canEdit ? "Change node override" : "Node overrides cannot be edited here",
      modelReason: configuration.modelFreeze
        ? "Model is frozen by workflow"
        : (canEdit ? "Change node model override" : "Node overrides cannot be edited here")
    )
  }

  private func modelChoices(
    configuration: WorkflowViewerNodeConfiguration,
    patch: RielaAppDaemonWorkflowNodePatch?
  ) -> [String] {
    uniqueValues([
      patch?.model,
      configuration.model,
      "gpt-5.5",
      "gpt-5.4-mini",
      "gpt-5.3-codex-spark",
      "gpt-5",
      "gpt-5-mini",
      "gpt-5-nano",
      "claude-sonnet-4-5",
      "claude-haiku-4-5",
      "claude-sonnet",
      "riela/chat-reply-worker"
    ].compactMap { $0 })
  }

  private func uniqueValues(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { value in
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !seen.contains(normalized) else {
        return false
      }
      seen.insert(normalized)
      return true
    }
  }

  private func selectedNodePatchFromControls(for node: WorkflowViewerNode) -> RielaAppDaemonWorkflowNodePatch? {
    guard node.configuration != nil else {
      return nil
    }
    let selectedModel = node.configuration?.modelFreeze == true ? nil : selectedPatchValue(from: modelPopup)
    let selectedBackend = selectedPatchValue(from: backendPopup).flatMap(NodeExecutionBackend.init(rawValue:))
    let selectedEffort = selectedPatchValue(from: effortPopup).flatMap(NodeReasoningEffort.init(rawValue:))
    return RielaAppDaemonWorkflowNodePatch(
      executionBackend: selectedBackend,
      model: selectedModel,
      effort: selectedEffort
    )
  }

  private func selectedPatchValue(from popup: NSPopUpButton) -> String? {
    guard popup.indexOfSelectedItem > 0 else {
      return nil
    }
    return popup.titleOfSelectedItem
  }

  private func updateTemplateControls(for node: WorkflowViewerNode?) {
    let templateFiles = node?.templateFiles ?? []
    templatePopup.removeAllItems()
    guard !templateFiles.isEmpty else {
      templatePopup.addItem(withTitle: "No template files")
      templatePopup.isEnabled = false
      saveTemplateButton.isEnabled = false
      reloadTemplateButton.isEnabled = false
      templateTextView.isEditable = false
      selectedTemplateFileId = nil
      setTemplateText("")
      return
    }

    templatePopup.addItems(withTitles: templateFiles.map(\.displayName))
    let selectedIndex = selectedTemplateIndex(in: templateFiles)
    templatePopup.selectItem(at: selectedIndex)
    selectedTemplateFileId = templateFiles[selectedIndex].id
    templatePopup.isEnabled = true
    saveTemplateButton.isEnabled = true
    reloadTemplateButton.isEnabled = true
    templateTextView.isEditable = true
    loadSelectedTemplateFile()
  }

  private func selectedTemplateIndex(in templateFiles: [WorkflowViewerTemplateFile]) -> Int {
    if let selectedTemplateFileId,
      let index = templateFiles.firstIndex(where: { $0.id == selectedTemplateFileId }) {
      return index
    }
    return templateFiles.firstIndex(where: \.isActiveForStep) ?? 0
  }

  private func selectedTemplateFile() -> WorkflowViewerTemplateFile? {
    guard let selectedNode = selectedNode(),
      templatePopup.indexOfSelectedItem >= 0,
      templatePopup.indexOfSelectedItem < selectedNode.templateFiles.count
    else {
      return nil
    }
    return selectedNode.templateFiles[templatePopup.indexOfSelectedItem]
  }

  private func selectedNode() -> WorkflowViewerNode? {
    guard let state, let selectedNodeId else {
      return nil
    }
    return flattenedNodes(state.nodes).first { $0.id == selectedNodeId }
  }

  private func loadSelectedTemplateFile() {
    guard let workflowDirectory, let templateFile = selectedTemplateFile() else {
      setTemplateText("")
      return
    }
    do {
      setTemplateText(try loader.templateFileContent(templateFile, workflowDirectory: workflowDirectory))
    } catch {
      setTemplateText("")
      setViewerMessage("Failed to load template: \(error)")
    }
  }

}

extension WorkflowViewerWindowController {
  @objc func viewerModeChanged() {
    guard let contentTabView else {
      return
    }
    let targetLabel = viewerModeControl.selectedSegment == 1 ? "Timeline" : "Run Log"
    if let item = contentTabView.tabViewItems.first(where: { $0.label == targetLabel }) {
      contentTabView.selectTabViewItem(item)
    }
    updateLiveRefreshTimer()
  }

  func selectTimelineMode() {
    viewerModeControl.selectedSegment = 1
    viewerModeChanged()
  }

  func updateTimelinePane(for state: WorkflowViewerState) {
    workflowTimelinePaneView.update(state: state)
  }

  func updateLiveRefreshTimer() {
    guard let state,
      selectedSession(in: state)?.status == .running
    else {
      stopLiveRefreshTimer()
      return
    }
    startLiveRefreshTimer()
  }

  func setDetailText(_ text: String) {
    detailTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  func setLogText(_ text: String) {
    logTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  func setStructureText(_ text: String) {
    structureTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  func setTemplateText(_ text: String) {
    templateTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [.font: templateFont]
    ))
  }
}

#endif
