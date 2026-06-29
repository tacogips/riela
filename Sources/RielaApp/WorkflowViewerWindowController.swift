#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaViewer

@MainActor
final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  let loader = WorkflowViewerLoader()
  private let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let templatePopup = NSPopUpButton()
  private let statusLabel = NSTextField(labelWithString: "No workflow loaded")
  private let currentDirectoryLabel = NSTextField(labelWithString: "-")
  private let environmentVariablesLabel = NSTextField(labelWithString: "-")
  private let workflowVariablesLabel = NSTextField(labelWithString: "-")
  private let detailTextView = NSTextView()
  private let logTextView = NSTextView()
  private let structureTextView = NSTextView()
  private let modelPopup = NSPopUpButton()
  private let backendPopup = NSPopUpButton()
  private let effortPopup = NSPopUpButton()
  private let saveNodePatchButton = NSButton(title: "Save Patch", target: nil, action: nil)
  private let clearNodePatchButton = NSButton(title: "Clear Patch", target: nil, action: nil)
  private let templateTextView = NSTextView()
  private let saveTemplateButton = NSButton(title: "Save", target: nil, action: nil)
  private let reloadTemplateButton = NSButton(title: "Reload", target: nil, action: nil)
  let timelineDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
  private let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private let detailTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
  private let detailBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
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
    updateCurrentDirectoryLabel()
    updateVariableLabels()
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
    outlineScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

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
    sessionPopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
    toolbar.addArrangedSubview(NSTextField(labelWithString: "Session"))
    toolbar.addArrangedSubview(sessionPopup)
    toolbar.addArrangedSubview(refreshButton)

    let patchToolbar = NSStackView()
    patchToolbar.orientation = .horizontal
    patchToolbar.alignment = .centerY
    patchToolbar.spacing = 8
    modelPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
    backendPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
    effortPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
    saveNodePatchButton.target = self
    saveNodePatchButton.action = #selector(saveNodePatchButtonPressed)
    clearNodePatchButton.target = self
    clearNodePatchButton.action = #selector(clearNodePatchButtonPressed)
    patchToolbar.addArrangedSubview(NSTextField(labelWithString: "Model"))
    patchToolbar.addArrangedSubview(modelPopup)
    patchToolbar.addArrangedSubview(NSTextField(labelWithString: "Backend"))
    patchToolbar.addArrangedSubview(backendPopup)
    patchToolbar.addArrangedSubview(NSTextField(labelWithString: "Effort"))
    patchToolbar.addArrangedSubview(effortPopup)
    patchToolbar.addArrangedSubview(saveNodePatchButton)
    patchToolbar.addArrangedSubview(clearNodePatchButton)

    let templateToolbar = NSStackView()
    templateToolbar.orientation = .horizontal
    templateToolbar.alignment = .centerY
    templateToolbar.spacing = 8
    templatePopup.target = self
    templatePopup.action = #selector(templateSelectionChanged)
    templatePopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
    saveTemplateButton.target = self
    saveTemplateButton.action = #selector(saveTemplateButtonPressed)
    reloadTemplateButton.target = self
    reloadTemplateButton.action = #selector(reloadTemplateButtonPressed)
    templateToolbar.addArrangedSubview(NSTextField(labelWithString: "Template"))
    templateToolbar.addArrangedSubview(templatePopup)
    templateToolbar.addArrangedSubview(saveTemplateButton)
    templateToolbar.addArrangedSubview(reloadTemplateButton)

    currentDirectoryLabel.lineBreakMode = .byTruncatingMiddle
    environmentVariablesLabel.lineBreakMode = .byTruncatingTail
    workflowVariablesLabel.lineBreakMode = .byTruncatingTail
    let instanceSettingsTitle = NSTextField(labelWithString: "Instance Settings")
    instanceSettingsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let instanceSettingsStack = NSStackView(views: [
      instanceSettingRow(
        title: "Current Directory",
        valueLabel: currentDirectoryLabel,
        action: #selector(currentDirectoryRowSelected)
      ),
      instanceSettingRow(
        title: "Environment Variables",
        valueLabel: environmentVariablesLabel,
        action: #selector(environmentVariablesRowSelected)
      ),
      instanceSettingRow(
        title: "Workflow Variables",
        valueLabel: workflowVariablesLabel,
        action: #selector(workflowVariablesRowSelected)
      )
    ])
    instanceSettingsStack.orientation = .vertical
    instanceSettingsStack.alignment = .leading
    instanceSettingsStack.spacing = 8
    let nodeOverrideTitle = NSTextField(labelWithString: "Node Overrides")
    nodeOverrideTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    statusLabel.lineBreakMode = .byTruncatingTail
    configureReadOnlyTextView(detailTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    configureReadOnlyTextView(logTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    configureReadOnlyTextView(structureTextView, textColor: detailTextColor, backgroundColor: detailBackgroundColor)
    let detailScroll = scrollView(for: detailTextView)
    let logScroll = scrollView(for: logTextView)
    let structureScroll = scrollView(for: structureTextView)

    templateTextView.isEditable = false
    templateTextView.isRichText = false
    templateTextView.font = templateFont
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
    templateScroll.borderType = .bezelBorder
    templateScroll.translatesAutoresizingMaskIntoConstraints = false

    let editStack = NSStackView(views: [
      detailScroll,
      templateToolbar,
      templateScroll
    ])
    editStack.orientation = .vertical
    editStack.alignment = .leading
    editStack.spacing = 8
    editStack.translatesAutoresizingMaskIntoConstraints = false

    let variablesStack = NSStackView(views: [
      instanceSettingsTitle,
      instanceSettingsStack,
      nodeOverrideTitle,
      patchToolbar
    ])
    variablesStack.orientation = .vertical
    variablesStack.alignment = .leading
    variablesStack.spacing = 8
    variablesStack.translatesAutoresizingMaskIntoConstraints = false

    let tabView = NSTabView()
    tabView.translatesAutoresizingMaskIntoConstraints = false
    tabView.addTabViewItem(tabItem(label: "Edit", view: editStack))
    tabView.addTabViewItem(tabItem(label: "Variables", view: variablesStack))
    tabView.addTabViewItem(tabItem(label: "Run Log", view: logScroll))
    tabView.addTabViewItem(tabItem(label: "Structure", view: structureScroll))

    rightStack.addArrangedSubview(toolbar)
    rightStack.addArrangedSubview(statusLabel)
    rightStack.addArrangedSubview(tabView)
    detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    logScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    structureScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    templateScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    templateScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    tabView.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
    tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true

    splitView.addArrangedSubview(outlineScroll)
    splitView.addArrangedSubview(rightStack)
    window.contentView = splitView
    splitView.setPosition(360, ofDividerAt: 0)
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
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
  }

  private func tabItem(label: String, view: NSView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: label)
    item.label = label
    item.view = view
    return item
  }

  private func instanceSettingRow(
    title: String,
    valueLabel: NSTextField,
    action: Selector
  ) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
    valueLabel.textColor = .labelColor
    valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [titleLabel, valueLabel, spacer, rielaAppDisclosureIndicator()])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    row.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    row.wantsLayer = true
    row.toolTip = "Open \(title)"
    row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
    return row
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
      statusLabel.stringValue = "Current directory editing is unavailable for this viewer"
      return
    }
    currentDirectory = onSetWorkingDirectory()
    updateCurrentDirectoryLabel()
  }

  @objc private func environmentVariablesRowSelected() {
    guard let onSetEnvironmentVariables else {
      statusLabel.stringValue = "Environment variable editing is unavailable for this viewer"
      return
    }
    environmentVariablesSummary = onSetEnvironmentVariables()
    updateVariableLabels()
  }

  @objc private func workflowVariablesRowSelected() {
    guard let onSetWorkflowVariables else {
      statusLabel.stringValue = "Workflow variable editing is unavailable for this viewer"
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
      statusLabel.stringValue = "Node patch editing is unavailable for this viewer"
      return
    }
    if onSaveNodePatch(selectedNode.nodeId, patch.isEmpty ? nil : patch) {
      if patch.isEmpty {
        nodePatches.removeValue(forKey: selectedNode.nodeId)
        statusLabel.stringValue = "Cleared node patch for \(selectedNode.nodeId)"
      } else {
        nodePatches[selectedNode.nodeId] = patch
        statusLabel.stringValue = "Saved node patch for \(selectedNode.nodeId)"
      }
      updateNodePatchControls(for: selectedNode)
    } else {
      statusLabel.stringValue = "Failed to save node patch for \(selectedNode.nodeId)"
    }
  }

  @objc private func clearNodePatchButtonPressed() {
    guard let selectedNode = selectedNode() else {
      return
    }
    guard let onSaveNodePatch else {
      statusLabel.stringValue = "Node patch editing is unavailable for this viewer"
      return
    }
    if onSaveNodePatch(selectedNode.nodeId, nil) {
      nodePatches.removeValue(forKey: selectedNode.nodeId)
      statusLabel.stringValue = "Cleared node patch for \(selectedNode.nodeId)"
      updateNodePatchControls(for: selectedNode)
    } else {
      statusLabel.stringValue = "Failed to clear node patch for \(selectedNode.nodeId)"
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
      statusLabel.stringValue = "Saved \(templateFile.relativePath)"
    } catch {
      statusLabel.stringValue = "Failed to save template: \(error)"
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
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      statusLabel.stringValue = "Failed to switch session: \(error)"
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
      sessionPopup.removeAllItems()
      if loaded.sessions.isEmpty {
        sessionPopup.addItem(withTitle: "No sessions")
        sessionPopup.isEnabled = false
      } else {
        sessionPopup.addItems(withTitles: loaded.sessions.map { sessionTitle($0) })
        sessionPopup.selectItem(at: 0)
        sessionPopup.isEnabled = true
      }
      outlineView.reloadData()
      expandAll()
      updateDetails()
    } catch {
      statusLabel.stringValue = "Failed to load viewer: \(error)"
      setDetailText("\(error)")
      setLogText("")
      setStructureText("")
    }
  }

  private func updateDetails() {
    guard let state else {
      statusLabel.stringValue = "No workflow loaded"
      setDetailText("")
      setLogText("")
      setStructureText("")
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
      return
    }
    let session = selectedSession(in: state)
    statusLabel.stringValue = [
      "Workflow: \(state.workflow.workflowId)",
      "Sessions: \(state.sessions.count)",
      session.map { "Selected: \($0.sessionId) (\($0.status.rawValue))" }
    ].compactMap { $0 }.joined(separator: " | ")
    guard let selectedNodeId else {
      setDetailText(workflowOverview(state: state))
      setLogText(renderRunLog(state: state, selectedStepId: nil, session: session).joined(separator: "\n"))
      setStructureText(renderWorkflowStructure(state: state).joined(separator: "\n"))
      updateTemplateControls(for: nil)
      updateNodePatchControls(for: nil)
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
      if let configuration = node.configuration {
        lines.append("Node file: \(configuration.nodeFile)")
        lines.append("Base model: \(configuration.model)")
        lines.append("Model freeze: \(configuration.modelFreeze)")
        lines.append("Base backend: \(configuration.executionBackend?.rawValue ?? "-")")
        lines.append("Base effort: \(configuration.effort?.rawValue ?? "-")")
        if let patch = nodePatches[node.nodeId], !patch.isEmpty {
          lines.append("Patch model: \(patch.model ?? "-")")
          lines.append("Patch backend: \(patch.executionBackend?.rawValue ?? "-")")
          lines.append("Patch effort: \(patch.effort?.rawValue ?? "-")")
        }
      }
      if !node.templateFiles.isEmpty {
        lines.append("Template files:")
        lines.append(contentsOf: node.templateFiles.map { templateFile in
          "- \(templateFile.displayName) [\(templateFile.fieldPath)]"
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
  }

  private func configurePopup(_ popup: NSPopUpButton, titles: [String]) {
    popup.removeAllItems()
    popup.addItems(withTitles: titles)
    popup.selectItem(at: 0)
  }

  private func selectPopupValue(_ popup: NSPopUpButton, value: String?, values: [String]) {
    guard let value, let index = values.firstIndex(of: value) else {
      popup.selectItem(at: 0)
      return
    }
    popup.selectItem(at: index + 1)
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
      statusLabel.stringValue = "Failed to load template: \(error)"
    }
  }

  private var detailScrollContentWidthFallback: CGFloat {
    520
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
      "[Running]"
    case .completed:
      "[Completed]"
    case .failed:
      "[Failed]"
    case .idle:
      "[Idle]"
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
#endif
