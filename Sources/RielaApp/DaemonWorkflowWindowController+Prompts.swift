#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  @objc func addDirectory() {
    onAddDirectory()
  }

  @objc func addURL() {
    guard let rawURL = promptForImportURL() else {
      return
    }
    onAddURL(rawURL)
  }

  @objc func addListButtonPressed() {
    showAddInstanceSelectionPane()
  }

  @objc func addProfileFromOverview() {
    guard let rawName = promptForProfileName(message: "Create a saved profile for another instance set.") else {
      return
    }
    _ = onCreateProfile(rawName)
  }

  func showAddInstanceSelectionPane() {
    activeSidebarPane = .instances
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = true
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    instanceDetailPane = .overview
    let selectionView = buildInlineAddInstanceSelectionView(options: workflowSourceOptions())
    selectionView.translatesAutoresizingMaskIntoConstraints = true
    addInstanceSelectionView?.removeFromSuperview()
    addInstanceSelectionView = selectionView
    showContentPane(selectionView)
    navigationTitleLabel.stringValue = "Choose Workflow"
    updateNavigationState()
    updateSidebarSelection()
  }

  func confirmInlineAddInstanceSelection() {
    guard
      let selectedIndex = inlineAddInstanceSourceSelectionTarget?.selectedIndex,
      inlineAddInstanceSourceOptions.indices.contains(selectedIndex),
      let request = promptForInstanceParameters(sourceOption: inlineAddInstanceSourceOptions[selectedIndex])
    else {
      return
    }
    onAddInstance(request)
    showInstancesList()
  }

  func controlTextDidChange(_ notification: Notification) {
    if notification.object as? NSTextField === eventSourceIdField {
      eventSourceFormValueChanged()
      return
    }
    if notification.object as? NSSearchField === inlineAddInstanceSearchField,
      isShowingAddInstanceSelection {
      rebuildInlineAddInstanceSelectionForSearch()
      return
    }
    if let searchField = notification.object as? NSSearchField,
      isShowingAddInstanceSelection {
      inlineAddInstanceSearchField.stringValue = searchField.stringValue
      rebuildInlineAddInstanceSelectionForSearch()
      return
    }
    if notification.object as? NSSearchField === workflowSourceSearchField,
      activeSidebarPane == .sources,
      !isShowingWorkflowSourceDetail {
      rebuildSourcesOverviewViewForSearch()
      return
    }
    if notification.object as? NSSearchField === marketplaceSearchField,
      activeSidebarPane == .marketplace {
      rebuildMarketplaceOverviewViewForSearch()
      return
    }
    if notification.object as? NSSearchField === instanceSearchField,
      activeSidebarPane == .instances,
      !isShowingInstanceDetail,
      !isShowingAddInstanceSelection {
      instanceSearchChanged()
    }
  }

  private func buildInlineAddInstanceSelectionView(options: [WorkflowSourceOption]) -> NSView {
    inlineAddInstanceAllSourceOptions = options
    let filteredOptions = filteredInlineAddInstanceOptions()
    inlineAddInstanceSourceOptions = filteredOptions
    let titleLabel = NSTextField(labelWithString: "Choose Workflow")
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let countLabel = NSTextField(
      labelWithString: addInstanceSourceCountText(visibleCount: filteredOptions.count, totalCount: options.count)
    )
    countLabel.textColor = .secondaryLabelColor
    countLabel.lineBreakMode = .byTruncatingTail
    countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [titleLabel, headerSpacer, countLabel])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY
    header.translatesAutoresizingMaskIntoConstraints = true
    header.autoresizingMask = []
    configureInlineAddInstanceSearchField()

    let stack: NSStackView
    if options.isEmpty {
      inlineAddInstanceSourceSelectionTarget = nil
      let emptyLabel = NSTextField(labelWithString: "No workflows. Import a workflow or package source.")
      emptyLabel.textColor = .secondaryLabelColor
      emptyLabel.alignment = .center
      emptyLabel.lineBreakMode = .byWordWrapping
      emptyLabel.maximumNumberOfLines = 2
      let actionsTitle = NSTextField(labelWithString: "Manage Sources")
      actionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      stack = inlineAddInstanceDocumentStack(views: [emptyLabel, actionsTitle, inlineSourceActionStack()])
    } else if filteredOptions.isEmpty {
      inlineAddInstanceSourceSelectionTarget = nil
      let emptyLabel = NSTextField(labelWithString: "No workflows match the current filter.")
      emptyLabel.textColor = .secondaryLabelColor
      emptyLabel.alignment = .center
      emptyLabel.lineBreakMode = .byWordWrapping
      emptyLabel.maximumNumberOfLines = 2
      let actionsTitle = NSTextField(labelWithString: "Manage Sources")
      actionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      stack = inlineAddInstanceDocumentStack(views: [
        inlineAddInstanceSearchField,
        emptyLabel,
        actionsTitle,
        inlineSourceActionStack()
      ])
    } else {
      let sourceSelection = workflowSourceSelectionStack(options: filteredOptions) {
        self.confirmInlineAddInstanceSelection()
      }
      inlineAddInstanceSourceSelectionTarget = sourceSelection.target
      let actionsTitle = NSTextField(labelWithString: "Manage Sources")
      actionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      stack = inlineAddInstanceDocumentStack(views: [
        inlineAddInstanceSearchField,
        sourceSelection.stack,
        actionsTitle,
        inlineSourceActionStack()
      ])
    }
    let scroll = inlineAddInstanceScrollView(documentStack: stack)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    return DaemonWorkflowOverviewPaneView(header: header, contentView: scroll)
  }

  private func configureInlineAddInstanceSearchField() {
    inlineAddInstanceSearchField.placeholderString = "Filter workflows"
    inlineAddInstanceSearchField.target = self
    inlineAddInstanceSearchField.delegate = self
    inlineAddInstanceSearchField.sendsSearchStringImmediately = true
    inlineAddInstanceSearchField.controlSize = .large
    inlineAddInstanceSearchField.setAccessibilityLabel("Filter Workflows")
  }

  private func filteredInlineAddInstanceOptions() -> [WorkflowSourceOption] {
    let query = inlineAddInstanceSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return inlineAddInstanceAllSourceOptions
    }
    return inlineAddInstanceAllSourceOptions.filter { option in
      workflowSourceOptionSearchText(option)
        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func workflowSourceOptionSearchText(_ option: WorkflowSourceOption) -> String {
    [
      option.candidate.displayName,
      option.candidate.workflowId,
      option.candidate.sourceDescription,
      requiredEnvironmentSummary(for: option.candidate),
      option.environmentStatus,
      option.location
    ].joined(separator: " ")
  }

  private func addInstanceSourceCountText(visibleCount: Int, totalCount: Int) -> String {
    let totalText = totalCount == 1 ? "1 workflow source" : "\(totalCount) workflow sources"
    guard visibleCount != totalCount else {
      return totalText
    }
    return "\(visibleCount) of \(totalText)"
  }

  private func rebuildInlineAddInstanceSelectionForSearch() {
    let selectionView = buildInlineAddInstanceSelectionView(options: inlineAddInstanceAllSourceOptions)
    selectionView.translatesAutoresizingMaskIntoConstraints = true
    addInstanceSelectionView?.removeFromSuperview()
    addInstanceSelectionView = selectionView
    showContentPane(selectionView)
    window?.makeFirstResponder(inlineAddInstanceSearchField)
  }

  private func inlineSourceActionStack() -> NSStackView {
    let stack = NSStackView(views: [
      actionRow(
        title: ImportSourceCopy.fileOrDirectoryTitle,
        detail: ImportSourceCopy.fileOrDirectoryDetail,
        action: #selector(addDirectory)
      ),
      actionRow(
        title: "Import from URL",
        detail: "Add a workflow or package directory from a GitHub tree URL.",
        action: #selector(addURL)
      )
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    return stack
  }

  private func inlineAddInstanceDocumentStack(views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  private func inlineAddInstanceScrollView(documentStack stack: NSStackView) -> NSScrollView {
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -DaemonWorkflowOverviewPaneView.contentBottomPadding)
    ])

    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.backgroundColor = .clear
    scroll.contentView.drawsBackground = false
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    return scroll
  }

  func promptForRelinkSourceOption(
    _ options: [WorkflowSourceOption],
    retryMessage: String? = nil
  ) -> WorkflowSourceSelection {
    guard !options.isEmpty else {
      let emptyMessage = retryMessage ?? "No workflows. Import a workflow or package source."
      let stack = AddInstancePromptViewFactory().emptyWorkflowSelectionStack(
        message: emptyMessage,
        sourceActions: sourceActionStack(context: .relink),
        size: AddInstancePromptLayout.relinkSize
      )
      pendingAddInstanceSheetAction = nil
      _ = runAddInstancePromptWindow(
        title: "Relink Source",
        message: "No workflow sources are available.",
        content: stack,
        contentSize: AddInstancePromptLayout.relinkSize,
        primaryTitle: nil
      )
      if let action = handlePendingAddInstanceSheetAction() {
        return .retry(relinkRetryMessage(for: action))
      }
      return .cancelled
    }

    let sourceSelection = workflowSourceSelectionStack(options: options) {
      self.activeAddInstanceWindow?.orderOut(nil)
      NSApp.stopModal(withCode: .OK)
    }
    var views: [NSView] = []
    if let retryMessage {
      let messageLabel = NSTextField(labelWithString: retryMessage)
      messageLabel.textColor = .secondaryLabelColor
      messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
      messageLabel.lineBreakMode = .byWordWrapping
      messageLabel.maximumNumberOfLines = 2
      messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      views.append(messageLabel)
    }
    views.append(sourceSelection.stack)
    let stack = AddInstancePromptViewFactory().accessoryStack(
      views: views,
      size: AddInstancePromptLayout.relinkSize
    )

    let response = withExtendedLifetime(sourceSelection.target) {
      runAddInstancePromptWindow(
        title: "Relink Source",
        message: "Choose a workflow source for this saved instance.",
        content: stack,
        contentSize: AddInstancePromptLayout.relinkSize,
        primaryTitle: nil
      )
    }
    guard response == .OK else {
      return .cancelled
    }
    return .selected(options[sourceSelection.target.selectedIndex])
  }

  private func promptForInstanceParameters(sourceOption option: WorkflowSourceOption) -> DaemonWorkflowAddInstanceRequest? {
    let generatedId = defaultInstanceId(option.sourceIdentity)
    let idField = NSTextField(string: generatedId)
    idField.placeholderString = "instance-id"
    let nameField = NSTextField(string: option.candidate.displayName)
    nameField.placeholderString = "Display name"
    let envField = NSTextField(string: "")
    envField.placeholderString = "Optional /path/to/.env"
    let directoryField = NSTextField(string: option.candidate.workingDirectory)
    directoryField.placeholderString = "Optional working directory"
    [idField, nameField, envField, directoryField].forEach(configureAddInstanceTextField)
    let envTarget = AddInstancePathFieldTarget(field: envField, choosesDirectories: false)
    let directoryTarget = AddInstancePathFieldTarget(field: directoryField, choosesDirectories: true)
    activeAddInstancePathTargets = [envTarget, directoryTarget]
    let startCheckbox = NSButton(checkboxWithTitle: "Start immediately after creating", target: nil, action: nil)
    startCheckbox.state = .on
    startCheckbox.setAccessibilityLabel("Start immediately")
    startCheckbox.setAccessibilityHelp("Create the instance and start its workflow process immediately.")
    startCheckbox.setContentHuggingPriority(.required, for: .horizontal)
    let parameterTitle = NSTextField(labelWithString: "Configure Instance")
    parameterTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    parameterTitle.alignment = .left
    let workflowValue = NSTextField(labelWithString: option.title)
    workflowValue.lineBreakMode = .byTruncatingMiddle
    workflowValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let helperLabel = NSTextField(
      labelWithString: generatedId.isEmpty
        ? "Use a stable lowercase ID for this instance."
        : "Generated from the source name. Edit it before creating if needed."
    )
    helperLabel.textColor = .secondaryLabelColor
    helperLabel.font = .systemFont(ofSize: 11)
    let idStack = NSStackView(views: [idField, helperLabel])
    idStack.orientation = .vertical
    idStack.alignment = .width
    idStack.spacing = 4
    let envStack = pathFieldStack(field: envField, target: envTarget)
    let directoryStack = pathFieldStack(field: directoryField, target: directoryTarget)
    var rows: [NSView] = [
      addInstanceValueRow(title: "Workflow", valueLabel: workflowValue)
    ]
    if !option.candidate.requiredEnvironment.isEmpty {
      let required = requiredEnvironmentChecklistText(for: option.candidate)
      let requiredLabel = NSTextField(labelWithString: required)
      requiredLabel.lineBreakMode = .byWordWrapping
      requiredLabel.maximumNumberOfLines = 6
      requiredLabel.toolTip = required
      rows.append(addInstanceValueRow(title: "Required Environment", valueLabel: requiredLabel))
    }
    rows.append(contentsOf: [
      addInstanceFieldRow(title: "Instance ID", control: idStack),
      addInstanceFieldRow(title: "Display Name", control: nameField),
      addInstanceFieldRow(title: ".env File", control: envStack),
      addInstanceFieldRow(title: "Working Directory", control: directoryStack),
      addInstanceToggleRow(title: "Start", checkbox: startCheckbox)
    ])
    let stack = AddInstancePromptViewFactory().scrollingParameterStack(
      title: parameterTitle,
      rows: rows
    )

    let response = runAddInstancePromptWindow(
      title: "Configure Instance",
      message: "Enter instance parameters.",
      content: stack,
      contentSize: AddInstancePromptLayout.parameterSize,
      primaryTitle: "Create",
      initialFirstResponder: idField
    )
    guard response == .OK else {
      activeAddInstancePathTargets = []
      return nil
    }
    let rawIdentity = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let envPath = envField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let workingDirectory = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = DaemonWorkflowAddInstanceRequest(
      sourceIdentity: option.sourceIdentity,
      identity: rawIdentity,
      displayName: displayName.isEmpty ? nil : displayName,
      environmentFilePath: envPath.isEmpty ? nil : envPath,
      workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
      startsImmediately: startCheckbox.state == .on
    )
    activeAddInstancePathTargets = []
    return request
  }

  private func pathFieldStack(field: NSTextField, target: AddInstancePathFieldTarget) -> NSStackView {
    let browseButton = NSButton(title: "Browse...", target: target, action: #selector(target.browse))
    browseButton.bezelStyle = .rounded
    let row = NSStackView(views: [field, browseButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    let stack = NSStackView(views: [row, target.caption])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 4
    return stack
  }

  @discardableResult
  private func handlePendingAddInstanceSheetAction() -> AddInstanceSheetAction? {
    guard let pendingAddInstanceSheetAction else {
      return nil
    }
    self.pendingAddInstanceSheetAction = nil
    switch pendingAddInstanceSheetAction {
    case .importWorkflowOrPackageFromFile:
      onAddDirectory()
    case .importWorkflowOrPackageFromURL:
      addURL()
    }
    return pendingAddInstanceSheetAction
  }

  private func relinkRetryMessage(for action: AddInstanceSheetAction) -> String {
    switch action {
    case .importWorkflowOrPackageFromFile:
      return "Imported source. Select it below to relink this instance."
    case .importWorkflowOrPackageFromURL:
      return "Import requested. When the source appears below, select it to relink this instance."
    }
  }

  @objc private func importWorkflowOrPackageFromAddInstanceSheet() {
    finishAddInstanceSheet(with: .importWorkflowOrPackageFromFile)
  }

  @objc private func importWorkflowOrPackageFromURLFromAddInstanceSheet() {
    finishAddInstanceSheet(with: .importWorkflowOrPackageFromURL)
  }

  private func finishAddInstanceSheet(with action: AddInstanceSheetAction) {
    pendingAddInstanceSheetAction = action
    activeAddInstanceWindow?.orderOut(nil)
    NSApp.stopModal(withCode: .cancel)
  }

  private func addInstanceFieldRow(title: String, control: NSView) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 145)
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel, control])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    return rielaAppSettingsRow(row)
  }

  private func configureAddInstanceTextField(_ field: NSTextField) {
    field.bezelStyle = .roundedBezel
    field.controlSize = .large
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  private func addInstanceValueRow(title: String, valueLabel: NSTextField) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 145)
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    valueLabel.textColor = .labelColor
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel, valueLabel])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    return rielaAppSettingsRow(row)
  }

  private func addInstanceToggleRow(title: String, checkbox: NSButton) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 145)
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    let helperLabel = NSTextField(labelWithString: "Turn this off to configure secrets or paths before any process starts.")
    helperLabel.textColor = .secondaryLabelColor
    helperLabel.font = .systemFont(ofSize: 11)
    helperLabel.lineBreakMode = .byWordWrapping
    helperLabel.maximumNumberOfLines = 2
    let checkboxStack = NSStackView(views: [checkbox, helperLabel])
    checkboxStack.orientation = .vertical
    checkboxStack.alignment = .leading
    checkboxStack.spacing = 4
    checkboxStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel, spacer, checkboxStack])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    return rielaAppSettingsRow(row)
  }

  private func promptForImportURL() -> String? {
    let field = NSTextField(string: "")
    field.placeholderString = "https://github.com/owner/repo/tree/main/path"
    configurePromptTextField(field)
    let response = runAddInstancePromptWindow(
      title: "Import from URL",
      message: "Enter a GitHub tree URL for a workflow or package directory. Other hosts are not supported yet.",
      content: promptFieldStack(title: "GitHub URL", control: field),
      contentSize: NSSize(width: 468, height: 190),
      primaryTitle: "Import GitHub URL",
      initialFirstResponder: field
    )
    guard response == .OK else {
      return nil
    }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func promptForProfileName(message: String) -> String? {
    let field = NSTextField(string: "")
    field.placeholderString = RielaAppProfileName.defaultRawValue
    configurePromptTextField(field)
    let stack = promptFieldStack(title: "Name", control: field)
    let alert = NSAlert()
    alert.messageText = "Profile Name"
    alert.informativeText = message
    alert.accessoryView = stack
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func promptFieldStack(title: String, control: NSView) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 70)
    let row = RielaAppSettingsRow(views: [titleLabel, control])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    let stack = NSStackView(views: [rielaAppSettingsRow(row)])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 420, height: 44)
    stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    return stack
  }

  private func configurePromptTextField(_ field: NSTextField) {
    field.bezelStyle = .roundedBezel
    field.controlSize = .large
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  private func runAddInstancePromptWindow(
    title: String,
    message: String,
    content: NSView,
    contentSize: NSSize,
    primaryTitle: String?,
    initialFirstResponder: NSView? = nil
  ) -> NSApplication.ModalResponse {
    let target = AddInstancePromptModalTarget()
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: min(420, contentSize.width), height: min(280, contentSize.height))
    target.window = window
    window.delegate = target
    window.contentView = buildAddInstancePromptWindowContent(
      title: title,
      message: message,
      content: content,
      primaryTitle: primaryTitle,
      target: target
    )
    activeAddInstanceWindow = window
    positionAddInstancePromptWindow(window)
    window.makeKeyAndOrderFront(nil)
    if let initialFirstResponder {
      window.makeFirstResponder(initialFirstResponder)
    }
    let response = withExtendedLifetime(target) {
      NSApp.runModal(for: window)
    }
    activeAddInstanceWindow = nil
    window.delegate = nil
    return response
  }

  private func buildAddInstancePromptWindowContent(
    title: String,
    message: String,
    content: NSView,
    primaryTitle: String?,
    target: AddInstancePromptModalTarget
  ) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.alignment = .left

    let messageLabel = NSTextField(labelWithString: message)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.lineBreakMode = .byWordWrapping
    messageLabel.maximumNumberOfLines = 2
    messageLabel.alignment = .left

    content.translatesAutoresizingMaskIntoConstraints = false
    let contentStack = NSStackView(views: [titleLabel, messageLabel, content])
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 12
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    let cancelButton = NSButton(title: "Cancel", target: target, action: #selector(AddInstancePromptModalTarget.cancel))
    cancelButton.keyEquivalent = "\u{1b}"
    var buttons = [cancelButton]
    if let primaryTitle {
      let primaryButton = NSButton(
        title: primaryTitle,
        target: target,
        action: #selector(AddInstancePromptModalTarget.confirm)
      )
      primaryButton.keyEquivalent = "\r"
      primaryButton.bezelStyle = .rounded
      buttons.append(primaryButton)
    }
    let buttonStack = NSStackView(views: buttons)
    buttonStack.orientation = .horizontal
    buttonStack.alignment = .centerY
    buttonStack.spacing = 8
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    let backdrop = NSVisualEffectView()
    backdrop.material = .windowBackground
    backdrop.blendingMode = .withinWindow
    backdrop.state = .active
    backdrop.addSubview(contentStack)
    backdrop.addSubview(buttonStack)
    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 26),
      contentStack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
      contentStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -24),
      content.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      buttonStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -24),
      buttonStack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -22),
      contentStack.bottomAnchor.constraint(lessThanOrEqualTo: buttonStack.topAnchor, constant: -18)
    ])
    return backdrop
  }

  private func positionAddInstancePromptWindow(_ promptWindow: NSWindow) {
    guard let parentFrame = window?.frame else {
      promptWindow.center()
      return
    }
    let promptFrame = promptWindow.frame
    promptWindow.setFrameOrigin(NSPoint(
      x: parentFrame.midX - (promptFrame.width / 2),
      y: parentFrame.midY - (promptFrame.height / 2)
    ))
  }

  private func sourceActionStack(context: SourceActionContext) -> NSStackView {
    let stack = NSStackView(views: [
      actionRow(
        title: ImportSourceCopy.fileOrDirectoryTitle,
        detail: context.importDetail,
        action: #selector(importWorkflowOrPackageFromAddInstanceSheet)
      ),
      actionRow(
        title: "Import from URL",
        detail: "Add a workflow or package directory from a GitHub tree URL.",
        action: #selector(importWorkflowOrPackageFromURLFromAddInstanceSheet)
      )
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    return stack
  }

  private func workflowSourceSelectionStack(
    options: [WorkflowSourceOption],
    onConfirm: (() -> Void)? = nil
  ) -> (stack: NSStackView, target: WorkflowSourceSelectionTarget) {
    let target = WorkflowSourceSelectionTarget(onConfirm: onConfirm)
    let title = NSTextField(labelWithString: "Workflow Sources")
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    title.alignment = .left
    let optionRows = options.enumerated().map { index, option in
      workflowSourceOptionRow(option: option, index: index, selectionTarget: target)
    }
    target.attach(
      checkmarks: optionRows.map(\.checkmark),
      rowTargets: optionRows.map(\.rowTarget)
    )
    let sourceList = NSStackView(views: optionRows.map(\.row))
    sourceList.orientation = .vertical
    sourceList.alignment = .width
    sourceList.spacing = 8
    sourceList.translatesAutoresizingMaskIntoConstraints = false
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(sourceList)
    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(options.count) * 70, 220))
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true
    NSLayoutConstraint.activate([
      sourceList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      sourceList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      sourceList.topAnchor.constraint(equalTo: document.topAnchor),
      sourceList.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      sourceList.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
    let stack = NSStackView(views: [title, scroll])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    return (stack, target)
  }

  private func workflowSourceOptionRow(
    option: WorkflowSourceOption,
    index: Int,
    selectionTarget: WorkflowSourceSelectionTarget
  ) -> WorkflowSourceOptionRow {
    let titleLabel = NSTextField(labelWithString: option.candidate.displayName)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    let detailLabel = NSTextField(
      labelWithString: rielaAppMetadataText([
        option.candidate.sourceDescription,
        requiredEnvironmentSummary(for: option.candidate),
        option.environmentStatus
      ])
    )
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail
    let locationLabel = NSTextField(labelWithString: option.location)
    locationLabel.font = .systemFont(ofSize: 11)
    locationLabel.textColor = .secondaryLabelColor
    locationLabel.lineBreakMode = .byTruncatingMiddle
    let labelStack = NSStackView(views: [titleLabel, detailLabel, locationLabel])
    labelStack.orientation = .vertical
    labelStack.spacing = 2
    labelStack.alignment = .leading
    labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let checkmark = NSImageView(
      image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage()
    )
    checkmark.setAccessibilityElement(false)
    checkmark.contentTintColor = .controlAccentColor
    let row = RielaAppSelectableSettingsRow(views: [labelStack, spacer, checkmark])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.toolTip = option.title
    let rowTarget = WorkflowSourceSelectionRowTarget(selectionTarget: selectionTarget, index: index)
    return WorkflowSourceOptionRow(
      row: rielaAppSelectableSettingsRow(
        row,
        target: rowTarget,
        action: #selector(rowTarget.select),
        accessibilityLabel: option.title,
        accessibilityHelp: "Choose \(option.candidate.displayName)"
      ),
      checkmark: checkmark,
      rowTarget: rowTarget
    )
  }

  private func requiredEnvironmentSummary(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let count = candidate.requiredEnvironment.count
    switch count {
    case 0:
      return "No required environment"
    case 1:
      return "1 required environment variable"
    default:
      return "\(count) required environment variables"
    }
  }

  private func requiredEnvironmentChecklistText(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let configuredValues = configuredEnvironmentValues(candidate)
    return candidate.requiredEnvironment
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .map { requirement in
        if let value = configuredValues.first(where: {
          $0.name == requirement.name &&
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
          return "\(requirement.name): Set from \(value.source)"
        }
        return "\(requirement.name): Missing"
      }
      .joined(separator: "\n")
  }
}

#endif
