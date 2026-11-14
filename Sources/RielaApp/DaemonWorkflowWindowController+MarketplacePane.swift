#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore

private struct MarketplaceWorkflowMetadata: Decodable {
  var workflowId: String
  var inheritance: MarketplaceWorkflowInheritance?

  private enum CodingKeys: String, CodingKey {
    case workflowId
    case inheritance = "extends"
  }
}

private struct MarketplaceWorkflowInheritance: Decodable {
  var workflowId: String
}

extension DaemonWorkflowWindowController {
  private static let marketplaceIdentifierSeparator = "\u{1f}"

  func buildMarketplaceOverviewView() -> NSView {
    marketplaceSummaryLabel.textColor = .secondaryLabelColor
    marketplaceSummaryLabel.lineBreakMode = .byTruncatingTail
    marketplaceSummaryLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    updateMarketplaceSummary()
    configureMarketplaceSearchField()
    let listContent = marketplaceListContent()
    return DaemonWorkflowSourcesPaneView(
      header: marketplaceHeader(),
      listScrollView: listContent.scrollView,
      emptyLabel: listContent.emptyLabel
    )
  }

  func rebuildMarketplaceOverviewView() {
    let fingerprint = marketplaceOverviewFingerprintValue()
    guard marketplaceOverviewFingerprint != fingerprint || marketplaceOverviewView == nil else {
      return
    }
    let wasVisible = marketplaceOverviewView?.isHidden == false
    marketplaceOverviewView?.removeFromSuperview()
    let marketplace = buildMarketplaceOverviewView()
    marketplace.isHidden = !wasVisible
    marketplaceOverviewView = marketplace
    marketplaceOverviewFingerprint = fingerprint
    if wasVisible {
      showContentPane(marketplace)
    }
  }

  func requestMarketplaceCatalogsIfNeeded() {
    let needsFetch = state.workflowRepositories.contains { repository in
      marketplaceCatalogs[repository.id] == nil
        && marketplaceErrors[repository.id] == nil
        && !marketplaceRefreshingRepositoryIds.contains(repository.id)
    }
    guard needsFetch else {
      return
    }
    onRefreshWorkflowRepositories(false)
  }

  private func marketplaceOverviewFingerprintValue() -> String {
    let installedIds = installedMarketplaceWorkflowIds().sorted().joined(separator: ",")
    let repositories = state.workflowRepositories.map { repository in
      let catalog = marketplaceCatalogs[repository.id]
      let workflows = (catalog?.workflows ?? []).map { listing in
        [listing.workflowId, listing.title, listing.summary, listing.relativePath].joined(separator: "\u{1f}")
      }.joined(separator: "\u{1e}")
      return [
        repository.id,
        marketplaceRefreshingRepositoryIds.contains(repository.id) ? "refreshing" : "",
        marketplaceErrors[repository.id] ?? "",
        workflows
      ].joined(separator: "\u{1d}")
    }
    return ([installedIds, marketplaceFilterText] + repositories).joined(separator: "\u{1c}")
  }

  private func marketplaceHeader() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let addRepositoryButton = marketplaceHeaderButton(
      title: "Add Repository",
      symbolName: "plus.circle",
      accessibilityLabel: "Add GitHub repository",
      action: #selector(addWorkflowRepositoryFromPrompt)
    )
    let refreshButton = marketplaceHeaderButton(
      title: "Refresh",
      symbolName: "arrow.clockwise",
      accessibilityLabel: "Refresh repository workflows",
      action: #selector(refreshMarketplaceRepositories)
    )
    let topRow = NSStackView(views: [
      marketplaceSummaryLabel,
      spacer,
      addRepositoryButton,
      refreshButton
    ])
    topRow.orientation = .horizontal
    topRow.spacing = 8
    topRow.alignment = .centerY
    let stack = NSStackView(views: [topRow, marketplaceSearchField])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .width
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.autoresizingMask = []
    return stack
  }

  private func marketplaceHeaderButton(
    title: String,
    symbolName: String,
    accessibilityLabel: String,
    action: Selector
  ) -> NSButton {
    let button = NSButton(title: "", target: self, action: action)
    button.bezelStyle = .rounded
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.imagePosition = .imageOnly
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
    button.setAccessibilityHelp(title)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  private func configureMarketplaceSearchField() {
    marketplaceSearchField.placeholderString = "Filter marketplace workflows"
    marketplaceSearchField.target = self
    marketplaceSearchField.action = #selector(marketplaceSearchChanged)
    marketplaceSearchField.sendsSearchStringImmediately = true
    marketplaceSearchField.controlSize = .large
    marketplaceSearchField.stringValue = marketplaceFilterText
    marketplaceSearchField.setAccessibilityLabel("Filter Marketplace Workflows")
    marketplaceSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    marketplaceSearchField.frame.size.width = 220
  }

  func rebuildMarketplaceOverviewViewForSearch() {
    let wasEditing = marketplaceSearchField.currentEditor() === window?.firstResponder
    marketplaceFilterText = marketplaceSearchField.stringValue
    guard let marketplacePane = marketplaceOverviewView as? DaemonWorkflowSourcesPaneView else {
      marketplaceOverviewFingerprint = nil
      rebuildMarketplaceOverviewView()
      if wasEditing {
        window?.makeFirstResponder(marketplaceSearchField)
      }
      return
    }
    let listContent = marketplaceListContent()
    marketplacePane.replaceListScrollView(listContent.scrollView, emptyLabel: listContent.emptyLabel)
    marketplaceOverviewFingerprint = marketplaceOverviewFingerprintValue()
  }

  @objc func marketplaceSearchChanged() {
    guard activeSidebarPane == .marketplace, !isShowingMarketplaceWorkflowDetail else {
      return
    }
    rebuildMarketplaceOverviewViewForSearch()
  }

  private func updateMarketplaceSummary() {
    let repositoryCount = state.workflowRepositories.count
    let workflowCount = state.workflowRepositories.reduce(0) { total, repository in
      total + (marketplaceCatalogs[repository.id]?.workflows.count ?? 0)
    }
    marketplaceSummaryLabel.stringValue = rielaAppMetadataText([
      "\(repositoryCount) \(repositoryCount == 1 ? "repository" : "repositories")",
      "\(workflowCount) \(workflowCount == 1 ? "workflow" : "workflows")"
    ])
  }

  private func marketplaceListContent() -> (scrollView: NSScrollView, emptyLabel: NSTextField) {
    var sections: [NSView] = []
    let installedIds = installedMarketplaceWorkflowIds()
    for repository in state.workflowRepositories {
      sections.append(marketplaceRepositoryCaption(repository))
      sections.append(rielaAppSettingsSection(rows: marketplaceRepositoryRows(
        repository,
        installedIds: installedIds
      )))
    }
    let stack = settingsDocumentStack(views: sections)
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    rielaAppConfigureGroupedListScroll(scroll)
    let emptyLabel = NSTextField(
      labelWithString: "No repositories registered. Add a GitHub repository that contains riela workflows to browse and install them."
    )
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 3
    emptyLabel.isHidden = !state.workflowRepositories.isEmpty
    return (scroll, emptyLabel)
  }

  private func marketplaceRepositoryCaption(_ repository: RielaAppWorkflowRepositoryReference) -> NSView {
    let label = NSTextField(labelWithString: repository.id)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let removeButton = NSButton(
      title: "Remove",
      target: self,
      action: #selector(removeWorkflowRepositoryFromButton(_:))
    )
    removeButton.bezelStyle = .inline
    removeButton.controlSize = .small
    removeButton.identifier = NSUserInterfaceItemIdentifier(repository.id)
    removeButton.toolTip = "Remove repository \(repository.id). Installed workflows are kept."
    removeButton.setAccessibilityLabel("Remove repository \(repository.id)")
    let row = NSStackView(views: [label, spacer, removeButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    row.setContentHuggingPriority(.required, for: .vertical)
    return row
  }

  private func marketplaceRepositoryRows(
    _ repository: RielaAppWorkflowRepositoryReference,
    installedIds: Set<String>
  ) -> [NSView] {
    if marketplaceRefreshingRepositoryIds.contains(repository.id) {
      return [marketplaceMessageRow("Loading workflows from \(repository.webURL)…")]
    }
    if let error = marketplaceErrors[repository.id] {
      return [marketplaceMessageRow(error, isError: true)]
    }
    guard let catalog = marketplaceCatalogs[repository.id] else {
      return [marketplaceMessageRow("Workflows have not been fetched yet. Use Refresh to fetch them.")]
    }
    guard !catalog.workflows.isEmpty else {
      return [marketplaceMessageRow("No workflows were found in this repository.")]
    }
    let workflows = filteredMarketplaceWorkflows(catalog.workflows, repository: repository)
    guard !workflows.isEmpty else {
      return [marketplaceMessageRow("No workflows in this repository match the current filter.")]
    }
    return workflows.map { listing in
      marketplaceWorkflowRow(listing, installed: installedIds.contains(listing.workflowId))
    }
  }

  private func filteredMarketplaceWorkflows(
    _ workflows: [RielaAppRemoteWorkflowListing],
    repository: RielaAppWorkflowRepositoryReference
  ) -> [RielaAppRemoteWorkflowListing] {
    let query = marketplaceFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return workflows
    }
    return workflows.filter { listing in
      [
        listing.title,
        listing.workflowId,
        listing.summary,
        listing.packageName ?? "",
        listing.relativePath,
        repository.id
      ].joined(separator: " ")
        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func marketplaceMessageRow(_ message: String, isError: Bool = false) -> NSView {
    let label = NSTextField(labelWithString: message)
    label.textColor = isError ? .systemRed : .secondaryLabelColor
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 3
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [label, spacer])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    return rielaAppSettingsRow(row)
  }

  private func marketplaceWorkflowRow(
    _ listing: RielaAppRemoteWorkflowListing,
    installed: Bool
  ) -> NSView {
    let titleLabel = NSTextField(labelWithString: listing.title)
    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let detailLabel = NSTextField(labelWithString: marketplaceWorkflowRowDetail(listing))
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byTruncatingTail
    detailLabel.maximumNumberOfLines = 2
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let labelStack = NSStackView(views: [titleLabel, detailLabel])
    labelStack.orientation = .vertical
    labelStack.alignment = .leading
    labelStack.spacing = 2
    labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let installButton = NSButton(
      title: installed ? "Installed" : "Install",
      target: self,
      action: #selector(installMarketplaceWorkflowFromButton(_:))
    )
    installButton.bezelStyle = .rounded
    installButton.isEnabled = !installed
    installButton.identifier = NSUserInterfaceItemIdentifier(
      [listing.repositoryId, listing.relativePath].joined(separator: Self.marketplaceIdentifierSeparator)
    )
    installButton.toolTip = installed
      ? "\(listing.workflowId) is already installed in this profile"
      : "Install \(listing.workflowId) into this profile"
    installButton.setAccessibilityLabel(installed ? "Installed \(listing.workflowId)" : "Install \(listing.workflowId)")
    installButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = RielaAppSelectableSettingsRow(views: [
      RielaAppSymbolTileView(symbolName: "shippingbox.fill", backgroundColor: .systemTeal),
      labelStack,
      spacer,
      installButton,
      rielaAppDisclosureIndicator()
    ])
    row.identifier = NSUserInterfaceItemIdentifier(
      [listing.repositoryId, listing.relativePath].joined(separator: Self.marketplaceIdentifierSeparator)
    )
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.toolTip = listing.summary.isEmpty ? listing.workflowId : listing.summary
    return rielaAppSelectableSettingsRow(
      row,
      target: self,
      action: #selector(openMarketplaceWorkflowDetailFromRow(_:)),
      accessibilityLabel: listing.title,
      accessibilityHelp: "Show workflow description and steps"
    )
  }

  @objc private func openMarketplaceWorkflowDetailFromRow(_ sender: RielaAppSelectableSettingsRow) {
    guard let identifier = sender.identifier?.rawValue,
      let listing = marketplaceListing(identifier: identifier) else {
      return
    }
    selectedMarketplaceWorkflowIdentifier = identifier
    activeSidebarPane = .marketplace
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    isShowingMarketplaceWorkflowDetail = true
    marketplaceWorkflowDetailView?.removeFromSuperview()
    marketplaceWorkflowDetailView = buildMarketplaceWorkflowDetailView(listing)
    showContentPane(marketplaceWorkflowDetailView)
    navigationTitleLabel.stringValue = listing.title
    updateNavigationState()
  }

  private func marketplaceListing(identifier: String) -> RielaAppRemoteWorkflowListing? {
    let parts = identifier.components(separatedBy: Self.marketplaceIdentifierSeparator)
    guard parts.count == 2 else {
      return nil
    }
    return marketplaceCatalogs[parts[0]]?.workflows.first { $0.relativePath == parts[1] }
  }

  private func buildMarketplaceWorkflowDetailView(_ listing: RielaAppRemoteWorkflowListing) -> NSView {
    let summaryLabel = NSTextField(labelWithString: listing.kind == .packageWorkflow ? "Package workflow" : "Workflow")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingMiddle
    var views: [NSView] = [
      settingsSectionCaption("Description"),
      rielaAppSettingsSection(rows: [marketplaceDetailTextRow(
        listing.summary.isEmpty ? "No description provided." : listing.summary
      )])
    ]
    do {
      let stepSource = try marketplaceStepSource(for: listing)
      let graphPane = DaemonWorkflowGraphPaneView()
      graphPane.update(model: try DaemonWorkflowGraphModel.load(
        workflowDirectory: stepSource.directory.path
      ))
      views.append(settingsSectionCaption(stepSource.inheritedWorkflowId.map {
        "Steps (inherited from \($0))"
      } ?? "Steps"))
      views.append(graphPane)
      views.append(contentsOf: marketplaceStepViews(directory: stepSource.directory))
    } catch {
      views.append(settingsSectionCaption("Steps"))
      views.append(rielaAppSettingsSection(rows: [
        marketplaceDetailTextRow("Workflow steps are unavailable: \(error)")
      ]))
    }
    views.append(settingsSectionCaption("Install"))
    views.append(rielaAppSettingsSection(rows: [marketplaceDetailInstallRow(listing)]))
    return overviewPane(
      title: listing.title,
      summaryLabel: summaryLabel,
      documentStack: settingsDocumentStack(views: views)
    )
  }

  private func marketplaceStepSource(
    for listing: RielaAppRemoteWorkflowListing
  ) throws -> (directory: URL, inheritedWorkflowId: String?) {
    let workflowURL = listing.workflowDirectoryURL.appendingPathComponent("workflow.json")
    guard let data = try? Data(contentsOf: workflowURL),
      let metadata = try? JSONDecoder().decode(MarketplaceWorkflowMetadata.self, from: data),
      let inheritedWorkflowId = metadata.inheritance?.workflowId else {
      return (listing.workflowDirectoryURL, nil)
    }
    let repositoryRoot = marketplaceRepositoryRoot(for: listing)
    guard let inheritedDirectory = marketplaceWorkflowDirectory(
      workflowId: inheritedWorkflowId,
      repositoryRoot: repositoryRoot
    ) else {
      throw DaemonWorkflowGraphLoadError.invalidWorkflow(
        "inherited workflow '\(inheritedWorkflowId)' was not found in the repository"
      )
    }
    return (inheritedDirectory, inheritedWorkflowId)
  }

  private func marketplaceRepositoryRoot(for listing: RielaAppRemoteWorkflowListing) -> URL {
    listing.relativePath.split(separator: "/").reduce(listing.installSourceURL) { root, _ in
      root.deletingLastPathComponent()
    }
  }

  private func marketplaceWorkflowDirectory(workflowId: String, repositoryRoot: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
      at: repositoryRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return nil
    }
    for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "workflow.json" {
      guard let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink != true,
        let data = try? Data(contentsOf: fileURL),
        let metadata = try? JSONDecoder().decode(MarketplaceWorkflowMetadata.self, from: data),
        metadata.workflowId == workflowId else {
        continue
      }
      return fileURL.deletingLastPathComponent()
    }
    return nil
  }

  private func marketplaceStepViews(directory: URL) -> [NSView] {
    let workflowURL = directory.appendingPathComponent("workflow.json")
    guard let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data) else {
      return []
    }
    let steps = workflow.steps ?? workflow.nodes.map { WorkflowStepRef(id: $0.id, nodeId: $0.id) }
    guard !steps.isEmpty else {
      return []
    }
    let rows = steps.map { step in
      marketplaceStepRow(step)
    }
    return [rielaAppSettingsSection(rows: rows)]
  }

  private func marketplaceStepRow(_ step: WorkflowStepRef) -> NSView {
    let title = NSTextField(labelWithString: step.id)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingMiddle
    let transitionTargets = (step.transitions ?? []).map { transition in
      transition.toWorkflowId ?? transition.toStepId
    }
    let detail = rielaAppMetadataText([
      step.description,
      step.role?.rawValue,
      transitionTargets.isEmpty ? "Final step" : "Next: \(transitionTargets.joined(separator: ", "))"
    ].compactMap { $0 })
    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.maximumNumberOfLines = 4
    let labels = NSStackView(views: [title, detailLabel])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [labels])
    row.orientation = .vertical
    row.alignment = .width
    return rielaAppSettingsRow(row)
  }

  private func marketplaceDetailTextRow(_ text: String) -> NSView {
    let label = NSTextField(wrappingLabelWithString: text)
    label.maximumNumberOfLines = 0
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [label])
    row.orientation = .vertical
    row.alignment = .width
    return rielaAppSettingsRow(row)
  }

  private func marketplaceDetailInstallRow(_ listing: RielaAppRemoteWorkflowListing) -> NSView {
    let installed = installedMarketplaceWorkflowIds().contains(listing.workflowId)
    let button = NSButton(
      title: installed ? "Installed" : "Install",
      target: self,
      action: #selector(installMarketplaceWorkflowFromButton(_:))
    )
    button.bezelStyle = .rounded
    button.isEnabled = !installed
    button.identifier = NSUserInterfaceItemIdentifier(
      [listing.repositoryId, listing.relativePath].joined(separator: Self.marketplaceIdentifierSeparator)
    )
    button.setAccessibilityLabel(installed ? "Installed \(listing.workflowId)" : "Install \(listing.workflowId)")
    let label = NSTextField(labelWithString: installed
      ? "This workflow is installed in the current profile."
      : "Install this workflow and its required child workflows.")
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byWordWrapping
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [label, spacer, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return rielaAppSettingsRow(row)
  }

  private func marketplaceWorkflowRowDetail(_ listing: RielaAppRemoteWorkflowListing) -> String {
    rielaAppMetadataText([
      listing.summary,
      listing.kind == .packageWorkflow ? "package \(listing.packageName ?? listing.relativePath)" : "workflow",
      listing.workflowId
    ])
  }

  private func installedMarketplaceWorkflowIds() -> Set<String> {
    Set(workflowSources.map(\.workflowId))
  }

  @objc private func addWorkflowRepositoryFromPrompt() {
    let field = NSTextField(string: "")
    field.placeholderString = "https://github.com/owner/repo"
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 320).isActive = true
    let alert = NSAlert()
    alert.messageText = "Add Workflow Repository"
    alert.informativeText = "Enter a public GitHub repository that contains riela workflows. "
      + "A branch can be pinned with https://github.com/owner/repo/tree/branch."
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: "Add Repository")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return
    }
    onAddWorkflowRepository(value)
  }

  @objc private func refreshMarketplaceRepositories() {
    onRefreshWorkflowRepositories(true)
  }

  @objc private func removeWorkflowRepositoryFromButton(_ sender: NSButton) {
    guard let repositoryId = sender.identifier?.rawValue, !repositoryId.isEmpty else {
      return
    }
    onRemoveWorkflowRepository(repositoryId)
  }

  @objc private func installMarketplaceWorkflowFromButton(_ sender: NSButton) {
    guard let rawValue = sender.identifier?.rawValue else {
      return
    }
    let parts = rawValue.components(separatedBy: Self.marketplaceIdentifierSeparator)
    guard parts.count == 2 else {
      return
    }
    sender.isEnabled = false
    sender.title = "Installing…"
    onInstallMarketplaceWorkflow(parts[0], parts[1])
  }
}
#endif
