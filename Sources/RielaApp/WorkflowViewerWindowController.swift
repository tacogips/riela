#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaViewer

@MainActor
final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  private enum Layout {
    static let initialWindowSize = NSSize(width: 640, height: 560)
    static let minimumWindowSize = NSSize(width: 420, height: 380)
    static let sidebarWidth: CGFloat = 180
  }

  let loader = WorkflowViewerLoader()
  private let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let templatePopup = NSPopUpButton()
  private let workflowTitleLabel = NSTextField(labelWithString: "Choose Workflow")
  private let workflowSubtitleLabel = NSTextField(labelWithString: "")
  private let currentDirectoryLabel = NSTextField(labelWithString: "-")
  private let environmentVariablesLabel = NSTextField(labelWithString: "-")
  private let workflowVariablesLabel = NSTextField(labelWithString: "-")
  private weak var currentDirectorySettingRow: RielaAppSelectableSettingsRow?
  private weak var environmentVariablesSettingRow: RielaAppSelectableSettingsRow?
  private weak var workflowVariablesSettingRow: RielaAppSelectableSettingsRow?
  private let detailTextView = NSTextView()
  private let logTextView = NSTextView()
  private let structureTextView = NSTextView()
  private let modelPopup = NSPopUpButton()
  private let backendPopup = NSPopUpButton()
  private let effortPopup = NSPopUpButton()
  private weak var modelOverrideRow: RielaAppSettingsRow?
  private weak var backendOverrideRow: RielaAppSettingsRow?
  private weak var effortOverrideRow: RielaAppSettingsRow?
  private weak var nodePatchOverrideRow: RielaAppSettingsRow?
  private let saveNodePatchButton = NSButton(title: "", target: nil, action: nil)
  private let clearNodePatchButton = NSButton(title: "", target: nil, action: nil)
  private let templateTextView = NSTextView()
  private let saveTemplateButton = NSButton(title: "", target: nil, action: nil)
  private let reloadTemplateButton = NSButton(title: "", target: nil, action: nil)
  let timelineDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
  private let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private let detailTextColor = NSColor.labelColor
  private let detailBackgroundColor = NSColor.controlBackgroundColor
  private let templateFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private var workflowDirectory: String?
  private var sessionStoreRoot: String?
  private var state: WorkflowViewerState?
  private var selectedNodeId: String?
  private var selectedTemplateFileId: String?
  private var currentDirectory: String?
  private var environmentVariablesSummary: String?
  private var workflowVariablesSummary: String?
  private var nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:]
  private var onSaveNodePatch: ((String, RielaAppDaemonWorkflowNodePatch?) -> Bool)?
  private var onSetWorkingDirectory: (() -> String?)?
  private var onSetEnvironmentVariables: (() -> String?)?
  private var onSetWorkflowVariables: (() -> String?)?

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
    buildContent(in: window)
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
    onSetWorkflowVariables: (() -> String?)? = nil
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
    updateInstanceSettingRows()
    updateCurrentDirectoryLabel()
    updateVariableLabels()
    refresh()
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
    let sessionRow = workflowViewerControlRow(title: "Session", views: [sessionPopup, refreshButton])

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
    let effortOverrideRow = workflowViewerControlRow(title: "Effort", views: [effortPopup])
    let nodePatchOverrideRow = workflowViewerControlRow(
      title: "Node Patch",
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
    tabView.translatesAutoresizingMaskIntoConstraints = false
    tabView.addTabViewItem(tabItem(label: "Edit", view: editStack))
    tabView.addTabViewItem(tabItem(label: "Variables", view: variablesStack))
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
    contentView.addSubview(splitView)
    NSLayoutConstraint.activate([
      splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
      splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    ])
    splitView.setPosition(Layout.sidebarWidth, ofDividerAt: 0)
  }

  private func configureReadOnlyTextView(
    _ textView: NSTextView,
    textColor: NSColor,
    backgroundColor: NSColor
  ) {
    textView.isEditable = false
    textView.isRichText = false
    textView.font = detailFont
    textView.textColor = textColor
    textView.backgroundColor = backgroundColor
    textView.drawsBackground = true
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: detailScrollContentWidthFallback,
      height: CGFloat.greatestFiniteMagnitude
    )
  }

  private func scrollView(for textView: NSTextView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    return scroll
  }

  private func tabItem(label: String, view: NSView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: label)
    item.label = label
    item.view = view
    return item
  }

  private func applyPreferredHeight(_ height: CGFloat, to view: NSView) {
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    let preferredHeight = view.heightAnchor.constraint(equalToConstant: height)
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true
  }

  private func instanceSettingRow(
    title: String,
    valueLabel: NSTextField,
    action: Selector
  ) -> RielaAppSelectableSettingsRow {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 150)
    valueLabel.textColor = .labelColor
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSelectableSettingsRow(views: [titleLabel, valueLabel, spacer, rielaAppDisclosureIndicator()])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    row.toolTip = "Change \(title)"
    return rielaAppSelectableSettingsRow(
      row,
      target: self,
      action: action,
      accessibilityLabel: title,
      accessibilityHelp: "Change \(title)"
    )
  }

  private func updateInstanceSettingRows() {
    updateInstanceSettingRow(
      currentDirectorySettingRow,
      title: "Current Directory",
      isEnabled: onSetWorkingDirectory != nil
    )
    updateInstanceSettingRow(
      environmentVariablesSettingRow,
      title: "Environment Variables",
      isEnabled: onSetEnvironmentVariables != nil
    )
    updateInstanceSettingRow(
      workflowVariablesSettingRow,
      title: "Workflow Variables",
      isEnabled: onSetWorkflowVariables != nil
    )
  }

  private func updateInstanceSettingRow(
    _ row: RielaAppSelectableSettingsRow?,
    title: String,
    isEnabled: Bool
  ) {
    let help = isEnabled ? "Change \(title)" : "\(title) cannot be edited here"
    row?.setRielaAccessibilityEnabled(isEnabled)
    row?.setAccessibilityHelp(help)
    row?.toolTip = help
  }

  @objc private func refreshButtonPressed() {
    refresh()
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
    } catch {
      setViewerMessage("Failed to switch session: \(error)")
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
      updateSessionPopup(for: loaded)
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      workflowTitleLabel.stringValue = "Unable to load workflow"
      setViewerMessage("\(error)")
      setDetailText("\(error)")
      setLogText("")
      setStructureText("")
    }
  }

  private func updateSessionPopup(for state: WorkflowViewerState?) {
    sessionPopup.removeAllItems()
    guard let state, !state.sessions.isEmpty else {
      sessionPopup.addItem(withTitle: "No Runs")
      sessionPopup.isEnabled = false
      return
    }
    sessionPopup.addItems(withTitles: state.sessions.map { sessionTitle($0) })
    sessionPopup.selectItem(at: state.selectedSessionIndex)
    sessionPopup.isEnabled = true
  }

  private func updateDetails() {
    guard let state else {
      workflowTitleLabel.stringValue = "Choose Workflow"
      setViewerMessage("")
      setDetailText("")
      setLogText("")
      setStructureText("")
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
      return
    }
    let session = selectedSession(in: state)
    workflowTitleLabel.stringValue = state.workflow.workflowId
    setViewerMessage(sessionSummary(state: state, session: session))
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
          "Effort \(configuration.effort?.rawValue ?? "-")"
        ]))
        if let patch = nodePatches[node.nodeId], !patch.isEmpty {
          lines.append("Patch")
          lines.append(rielaAppMetadataText([
            "Model \(patch.model ?? "-")",
            "Backend \(patch.executionBackend?.rawValue ?? "-")",
            "Effort \(patch.effort?.rawValue ?? "-")"
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

  private func setLogText(_ text: String) {
    logTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  private func setStructureText(_ text: String) {
    structureTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [
        .font: detailFont,
        .foregroundColor: detailTextColor,
        .backgroundColor: detailBackgroundColor
      ]
    ))
  }

  private func setTemplateText(_ text: String) {
    templateTextView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [.font: templateFont]
    ))
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
  private var detailScrollContentWidthFallback: CGFloat {
    360
  }

  func expandAll() {
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
    let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? RielaAppTableSelectionCellView
      ?? RielaAppTableSelectionCellView()
    cell.identifier = identifier
    cell.configureSelection(
      tableView: outlineView,
      row: outlineView.row(forItem: node),
      role: .button,
      accessibilityLabel: node.title,
      accessibilityValue: stateAccessibilityLabel(node.state),
      accessibilityHelp: "Show workflow node details",
      actionTarget: self,
      action: #selector(workflowTreeRowPressed(_:))
    )
    let imageView = cell.imageView ?? NSImageView()
    let field = cell.textField ?? NSTextField(labelWithString: "")
    imageView.translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    if imageView.superview == nil {
      cell.addSubview(imageView)
      cell.imageView = imageView
      NSLayoutConstraint.activate([
        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        imageView.widthAnchor.constraint(equalToConstant: 12),
        imageView.heightAnchor.constraint(equalToConstant: 12)
      ])
    }
    if field.superview == nil {
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }
    imageView.image = NSImage(
      systemSymbolName: stateSymbolName(node.state),
      accessibilityDescription: stateAccessibilityLabel(node.state)
    )
    imageView.contentTintColor = color(for: node.state)
    field.stringValue = node.title
    field.textColor = .labelColor
    field.font = node.state == .active ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
    return cell
  }

  @objc private func workflowTreeRowPressed(_ sender: NSOutlineView) {
    outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: sender))
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? WorkflowViewerNode else {
      return
    }
    selectedNodeId = node.id
    updateDetails()
  }

  func stateSymbolName(_ state: WorkflowViewerNodeRuntimeState) -> String {
    switch state {
    case .active:
      "circle.fill"
    case .completed:
      "checkmark.circle.fill"
    case .failed:
      "xmark.circle.fill"
    case .idle:
      "circle"
    }
  }

  func stateAccessibilityLabel(_ state: WorkflowViewerNodeRuntimeState) -> String {
    switch state {
    case .active:
      "Running"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .idle:
      "Idle"
    }
  }

  func color(for state: WorkflowViewerNodeRuntimeState) -> NSColor {
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

private extension WorkflowViewerWindowController {
  func configurePopup(_ popup: NSPopUpButton, titles: [String]) {
    popup.removeAllItems()
    popup.addItems(withTitles: titles)
    popup.selectItem(at: 0)
  }

  func selectPopupValue(_ popup: NSPopUpButton, value: String?, values: [String]) {
    guard let value, let index = values.firstIndex(of: value) else {
      popup.selectItem(at: 0)
      return
    }
    popup.selectItem(at: index + 1)
  }

  func updateNodeOverrideRows(
    canEdit: Bool,
    modelCanEdit: Bool,
    reason: String,
    modelReason: String
  ) {
    updateWorkflowViewerControlRow(modelOverrideRow, isEnabled: modelCanEdit, help: modelReason)
    updateWorkflowViewerControlRow(backendOverrideRow, isEnabled: canEdit, help: reason)
    updateWorkflowViewerControlRow(effortOverrideRow, isEnabled: canEdit, help: reason)
    updateWorkflowViewerControlRow(nodePatchOverrideRow, isEnabled: canEdit, help: reason)
  }

  func updateWorkflowViewerControlRow(_ row: RielaAppSettingsRow?, isEnabled: Bool, help: String) {
    row?.alphaValue = isEnabled ? 1 : 0.55
    row?.setAccessibilityEnabled(isEnabled)
    row?.setAccessibilityHelp(help)
    row?.toolTip = help
  }

  func workflowViewerControlRow(title: String, views: [NSView]) -> RielaAppSettingsRow {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 86)
    for view in views {
      if let popup = view as? NSPopUpButton {
        popup.setAccessibilityLabel(title)
      }
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel] + views + [spacer])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel(title)
    rielaAppSettingsRow(row)
    return row
  }

  func setViewerMessage(_ message: String) {
    workflowSubtitleLabel.stringValue = message
  }

  func sessionSummary(state: WorkflowViewerState, session: WorkflowViewerSessionSummary?) -> String {
    let count = state.sessions.count
    let countSummary = count == 1 ? "1 session" : "\(count) sessions"
    guard let session else {
      return countSummary
    }
    return "\(countSummary) · \(session.status.rawValue.capitalized) \(session.sessionId)"
  }

  func iconButton(symbolName: String, accessibilityLabel: String, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: self, action: action)
    configureIconButton(button, symbolName: symbolName, accessibilityLabel: accessibilityLabel)
    return button
  }

  func configureIconButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.bezelStyle = .toolbar
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }

  func configureCompactPopup(_ popup: NSPopUpButton, maximumWidth: CGFloat) {
    popup.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth).isActive = true
    popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

}

#endif
