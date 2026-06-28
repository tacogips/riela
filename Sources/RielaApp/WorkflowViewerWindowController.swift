#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaViewer

@MainActor
final class WorkflowViewerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  private let loader = WorkflowViewerLoader()
  private let outlineView = NSOutlineView()
  private let sessionPopup = NSPopUpButton()
  private let templatePopup = NSPopUpButton()
  private let statusLabel = NSTextField(labelWithString: "No workflow loaded")
  private let detailTextView = NSTextView()
  private let modelPopup = NSPopUpButton()
  private let backendPopup = NSPopUpButton()
  private let effortPopup = NSPopUpButton()
  private let saveNodePatchButton = NSButton(title: "Save Patch", target: nil, action: nil)
  private let clearNodePatchButton = NSButton(title: "Clear Patch", target: nil, action: nil)
  private let templateTextView = NSTextView()
  private let saveTemplateButton = NSButton(title: "Save", target: nil, action: nil)
  private let reloadTemplateButton = NSButton(title: "Reload", target: nil, action: nil)
  private let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private let detailTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
  private let detailBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
  private let templateFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private var workflowDirectory: String?
  private var sessionStoreRoot: String?
  private var state: WorkflowViewerState?
  private var selectedNodeId: String?
  private var selectedTemplateFileId: String?
  private var nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:]
  private var onSaveNodePatch: ((String, RielaAppDaemonWorkflowNodePatch?) -> Bool)?

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
    nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:],
    onSaveNodePatch: ((String, RielaAppDaemonWorkflowNodePatch?) -> Bool)? = nil
  ) {
    if self.workflowDirectory != workflowDirectory {
      selectedNodeId = nil
    }
    self.workflowDirectory = workflowDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.nodePatches = nodePatches
    self.onSaveNodePatch = onSaveNodePatch
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

    statusLabel.lineBreakMode = .byTruncatingTail
    detailTextView.isEditable = false
    detailTextView.isRichText = false
    detailTextView.font = detailFont
    detailTextView.textColor = detailTextColor
    detailTextView.backgroundColor = detailBackgroundColor
    detailTextView.drawsBackground = true
    detailTextView.textContainerInset = NSSize(width: 10, height: 10)
    detailTextView.isVerticallyResizable = true
    detailTextView.isHorizontallyResizable = true
    detailTextView.autoresizingMask = [.width]
    detailTextView.textContainer?.widthTracksTextView = true
    detailTextView.textContainer?.containerSize = NSSize(
      width: detailScrollContentWidthFallback,
      height: CGFloat.greatestFiniteMagnitude
    )
    let detailScroll = NSScrollView()
    detailScroll.documentView = detailTextView
    detailScroll.hasVerticalScroller = true
    detailScroll.hasHorizontalScroller = true
    detailScroll.borderType = .bezelBorder
    detailScroll.translatesAutoresizingMaskIntoConstraints = false

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

    rightStack.addArrangedSubview(toolbar)
    rightStack.addArrangedSubview(statusLabel)
    rightStack.addArrangedSubview(detailScroll)
    rightStack.addArrangedSubview(patchToolbar)
    rightStack.addArrangedSubview(templateToolbar)
    rightStack.addArrangedSubview(templateScroll)
    detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    templateScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
    templateScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

    splitView.addArrangedSubview(outlineScroll)
    splitView.addArrangedSubview(rightStack)
    window.contentView = splitView
    splitView.setPosition(360, ofDividerAt: 0)
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
    }
  }

  private func updateDetails() {
    guard let state else {
      statusLabel.stringValue = "No workflow loaded"
      setDetailText("")
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
    if state.sessions.isEmpty {
      lines.append("")
      lines.append("Sessions")
      lines.append("No persisted sessions found for this workflow.")
      lines.append("Searched:")
      lines.append(contentsOf: state.sessionStoreCandidates.map { "- \($0)" })
    }
    if !state.diagnostics.isEmpty {
      lines.append("")
      lines.append("Diagnostics")
      lines.append(contentsOf: state.diagnostics.map { "- \($0)" })
    }
    if let session {
      do {
        let messages = try loader.nodeMessages(
          stepId: selectedNodeId,
          sessionId: session.sessionId,
          sessionStoreRoot: state.sessionStoreRoot
        )
        lines.append("")
        lines.append("Inbox")
        lines.append(contentsOf: render(messages.inbox))
        lines.append("")
        lines.append("Outbox")
        lines.append(contentsOf: render(messages.outbox))
      } catch {
        lines.append("")
        lines.append("Messages failed to load: \(error)")
      }
    }
    setDetailText(lines.joined(separator: "\n"))
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

  private func selectedSession(in state: WorkflowViewerState) -> WorkflowViewerSessionSummary? {
    guard let selectedSessionId = state.selectedSessionId else {
      return nil
    }
    return state.sessions.first { $0.sessionId == selectedSessionId }
  }

  private func workflowOverview(state: WorkflowViewerState) -> String {
    [
      "id: \(state.workflow.workflowId)",
      "entry: \(state.workflow.entryStepId)",
      "description: \(state.workflow.description.isEmpty ? "-" : state.workflow.description)",
      "steps: \(state.workflow.steps.count)",
      "sessionStore: \(state.sessionStoreRoot)"
    ].joined(separator: "\n")
  }

  private func render(_ messages: [WorkflowViewerMessage]) -> [String] {
    guard !messages.isEmpty else {
      return ["(none)"]
    }
    return messages.map { message in
      [
        "- \(message.id) [\(message.status.rawValue)]",
        "  from: \(message.fromStepId ?? "-")",
        "  to: \(message.toStepId ?? "-")",
        "  payload: \(message.payloadPreview)"
      ].joined(separator: "\n")
    }
  }

  private func sessionTitle(_ summary: WorkflowViewerSessionSummary) -> String {
    let active = summary.activeStepIds.isEmpty ? "" : " active: \(summary.activeStepIds.joined(separator: ","))"
    return "\(summary.sessionId) - \(summary.status.rawValue)\(active)"
  }

  private func flattenedNodes(_ nodes: [WorkflowViewerNode]) -> [WorkflowViewerNode] {
    nodes.flatMap { [$0] + flattenedNodes($0.children) }
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
