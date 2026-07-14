#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  private static let marketplaceIdentifierSeparator = "\u{1f}"

  func buildMarketplaceOverviewView() -> NSView {
    marketplaceSummaryLabel.textColor = .secondaryLabelColor
    marketplaceSummaryLabel.lineBreakMode = .byTruncatingTail
    updateMarketplaceSummary()
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
    return ([installedIds] + repositories).joined(separator: "\u{1c}")
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
    let stack = NSStackView(views: [topRow])
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
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
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
    return catalog.workflows.map { listing in
      marketplaceWorkflowRow(listing, installed: installedIds.contains(listing.workflowId))
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
    titleLabel.lineBreakMode = .byTruncatingTail
    let detailLabel = NSTextField(labelWithString: marketplaceWorkflowRowDetail(listing))
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byTruncatingTail
    detailLabel.maximumNumberOfLines = 2
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
    let row = RielaAppSettingsRow(views: [
      RielaAppSymbolTileView(symbolName: "shippingbox.fill", backgroundColor: .systemTeal),
      labelStack,
      spacer,
      installButton
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.toolTip = listing.summary.isEmpty ? listing.workflowId : listing.summary
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel(listing.title)
    row.setAccessibilityValue(listing.summary)
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
