#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  func buildSourcesOverviewView() -> NSView {
    sourcesSummaryLabel.textColor = .secondaryLabelColor
    sourcesSummaryLabel.lineBreakMode = .byTruncatingTail
    let sources = workflowSources.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    configureWorkflowSourceSearchField()
    let listContent = workflowSourceListContent(sources: sources)
    return DaemonWorkflowSourcesPaneView(
      header: workflowSourcesHeader(),
      listScrollView: listContent.scrollView,
      emptyLabel: listContent.emptyLabel
    )
  }

  func rebuildSourcesOverviewView() {
    let fingerprint = sourcesOverviewFingerprintValue()
    guard sourcesOverviewFingerprint != fingerprint || sourcesOverviewView == nil else {
      return
    }
    let wasVisible = sourcesOverviewView?.isHidden == false
    sourcesOverviewView?.removeFromSuperview()
    let sources = buildSourcesOverviewView()
    sources.isHidden = !wasVisible
    sourcesOverviewView = sources
    sourcesOverviewFingerprint = fingerprint
    if wasVisible {
      showContentPane(sources)
    }
  }

  private func sourcesOverviewFingerprintValue() -> String {
    ([selectedWorkflowSourceId ?? "", workflowSourceFilterText] + workflowSources.map { source in
      [
        source.id,
        source.displayName,
        source.sourceDescription,
        source.workflowDirectory,
        source.packageDirectory ?? "",
        source.eventSourceSummary,
        String(source.requiredEnvironment.count)
      ].joined(separator: "\u{1f}")
    }).joined(separator: "\u{1e}")
  }

  private func workflowSourcesHeader() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let importFileButton = workflowSourceImportButton(
      title: "Import File/Directory",
      symbolName: "folder",
      accessibilityLabel: ImportSourceCopy.fileOrDirectoryTitle,
      action: #selector(addDirectory)
    )
    let importURLButton = workflowSourceImportButton(
      title: "Import URL",
      symbolName: "link",
      accessibilityLabel: "Import from URL",
      action: #selector(addURL)
    )
    let topRow = NSStackView(views: [
      sourcesSummaryLabel,
      spacer,
      importFileButton,
      importURLButton
    ])
    topRow.orientation = .horizontal
    topRow.spacing = 8
    topRow.alignment = .centerY
    let stack = NSStackView(views: [
      topRow,
      workflowSourceSearchField
    ])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .width
    stack.translatesAutoresizingMaskIntoConstraints = true
    stack.autoresizingMask = []
    return stack
  }

  private func configureWorkflowSourceSearchField() {
    workflowSourceSearchField.placeholderString = "Filter workflow sources"
    workflowSourceSearchField.target = self
    workflowSourceSearchField.delegate = self
    workflowSourceSearchField.sendsSearchStringImmediately = true
    workflowSourceSearchField.controlSize = .large
    workflowSourceSearchField.stringValue = workflowSourceFilterText
    workflowSourceSearchField.setAccessibilityLabel("Filter Workflow Sources")
    workflowSourceSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    workflowSourceSearchField.frame.size.width = 220
  }

  private func filteredWorkflowSources(
    _ sources: [RielaAppDaemonWorkflowCandidate]
  ) -> [RielaAppDaemonWorkflowCandidate] {
    let query = workflowSourceFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return sources
    }
    return sources.filter { source in
      workflowSourceSearchText(source)
        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func workflowSourceSearchText(_ source: RielaAppDaemonWorkflowCandidate) -> String {
    [
      source.displayName,
      source.workflowId,
      source.sourceDescription,
      source.workflowDirectory,
      source.packageDirectory ?? "",
      source.eventSourceSummary
    ].joined(separator: " ")
  }

  func rebuildSourcesOverviewViewForSearch() {
    workflowSourceFilterText = workflowSourceSearchField.stringValue
    guard let sourcesPane = sourcesOverviewView as? DaemonWorkflowSourcesPaneView else {
      sourcesOverviewFingerprint = nil
      rebuildSourcesOverviewView()
      window?.makeFirstResponder(workflowSourceSearchField)
      return
    }
    let sources = workflowSources.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    let listContent = workflowSourceListContent(sources: sources)
    sourcesPane.replaceListScrollView(listContent.scrollView, emptyLabel: listContent.emptyLabel)
    sourcesOverviewFingerprint = sourcesOverviewFingerprintValue()
    window?.makeFirstResponder(workflowSourceSearchField)
  }

  private func workflowSourceImportButton(
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

  private func workflowSourceListScrollView(
    sources: [RielaAppDaemonWorkflowCandidate],
    selectedSourceId: String?
  ) -> NSScrollView {
    let rows = sources.map { workflowSourceRow($0, selected: $0.id == selectedSourceId) }
    let stack = settingsDocumentStack(views: rows.isEmpty ? [] : [rielaAppSettingsSection(rows: rows)])
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    rielaAppConfigureGroupedListScroll(scroll)
    return scroll
  }

  private func workflowSourceListContent(
    sources: [RielaAppDaemonWorkflowCandidate]
  ) -> (scrollView: NSScrollView, emptyLabel: NSTextField) {
    let filteredSources = filteredWorkflowSources(sources)
    let selectedSourceId = filteredSources.contains { $0.id == selectedWorkflowSourceId } ? selectedWorkflowSourceId : nil
    let scrollView = workflowSourceListScrollView(sources: filteredSources, selectedSourceId: selectedSourceId)
    let emptyText = workflowSources.isEmpty ? "No workflow sources." : "No workflow sources match the current filter."
    let emptyLabel = NSTextField(labelWithString: emptyText)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 2
    emptyLabel.isHidden = !filteredSources.isEmpty
    return (scrollView, emptyLabel)
  }

  private func workflowSourceRow(
    _ source: RielaAppDaemonWorkflowCandidate,
    selected: Bool
  ) -> RielaAppSelectableSettingsRow {
    let titleLabel = NSTextField(labelWithString: source.displayName)
    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    let detailLabel = NSTextField(labelWithString: workflowSourceRowDetail(source))
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byTruncatingMiddle
    let labelStack = NSStackView(views: [titleLabel, detailLabel])
    labelStack.orientation = .vertical
    labelStack.alignment = .leading
    labelStack.spacing = 2
    labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSelectableSettingsRow(views: [
      RielaAppSymbolTileView(symbolName: "rectangle.stack.fill", backgroundColor: .systemBlue),
      labelStack,
      spacer,
      rielaAppDisclosureIndicator()
    ])
    row.identifier = NSUserInterfaceItemIdentifier(source.id)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.toolTip = source.workflowDirectory
    let styled = rielaAppSelectableSettingsRow(
      row,
      target: self,
      action: #selector(openWorkflowSourceDetailFromRow(_:)),
      accessibilityLabel: source.displayName,
      accessibilityHelp: "Show workflow source detail"
    )
    styled.setSettingsRowSelected(selected)
    return styled
  }

  private func workflowSourceRowDetail(_ source: RielaAppDaemonWorkflowCandidate) -> String {
    rielaAppMetadataText([
      source.sourceDescription,
      source.packageDirectory == nil ? "workflow" : "package",
      source.workflowId
    ])
  }

  private func buildWorkflowSourceDetailView(_ source: RielaAppDaemonWorkflowCandidate) -> NSView {
    let graphPane = DaemonWorkflowGraphPaneView()
    do {
      graphPane.update(model: try DaemonWorkflowGraphModel.load(workflowDirectory: source.workflowDirectory))
    } catch {
      graphPane.showUnavailable("Workflow graph unavailable: \(error)")
    }
    let summaryLabel = NSTextField(labelWithString: workflowSourceRowDetail(source))
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    return overviewPane(
      title: source.displayName,
      summaryLabel: summaryLabel,
      documentStack: settingsDocumentStack(views: [
        workflowSourceSummarySection(source),
        graphPane
      ])
    )
  }

  func showWorkflowSourceDetail() {
    let sources = workflowSources.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    guard let source = selectedWorkflowSource(from: sources) else {
      showSourcesPane()
      return
    }
    workflowSourceDetailView?.removeFromSuperview()
    let detail = buildWorkflowSourceDetailView(source)
    workflowSourceDetailView = detail
    activeSidebarPane = .sources
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = true
    showContentPane(detail)
    navigationTitleLabel.stringValue = source.displayName
    updateNavigationState()
    updateSidebarSelection()
  }

  private func selectedWorkflowSource(from sources: [RielaAppDaemonWorkflowCandidate]) -> RielaAppDaemonWorkflowCandidate? {
    if let selectedWorkflowSourceId,
      let selected = sources.first(where: { $0.id == selectedWorkflowSourceId }) {
      return selected
    }
    return nil
  }

  @objc func openWorkflowSourceDetailFromRow(_ sender: Any) {
    guard
      let row = sender as? NSView,
      let rawValue = row.identifier?.rawValue
    else {
      return
    }
    selectedWorkflowSourceId = rawValue
    sourcesOverviewFingerprint = nil
    rebuildSourcesOverviewView()
    showWorkflowSourceDetail()
  }

  private func workflowSourceSummarySection(_ source: RielaAppDaemonWorkflowCandidate) -> RielaAppSettingsSectionView {
    let locationLabel = sourceDetailLabel(source.workflowDirectory)
    let kindLabel = sourceDetailLabel(source.packageDirectory == nil ? "Workflow directory" : "Package workflow")
    let eventLabel = sourceDetailLabel(source.eventSourceSummary)
    let environmentLabel = sourceDetailLabel("\(source.requiredEnvironment.count) required")
    return rielaAppSettingsSection(rows: [
      settingRow(title: "Source", valueLabel: kindLabel, action: nil),
      settingRow(title: "Location", valueLabel: locationLabel, action: nil),
      settingRow(title: "Event Sources", valueLabel: eventLabel, action: nil),
      settingRow(title: "Environment", valueLabel: environmentLabel, action: nil)
    ])
  }

  private func sourceDetailLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }
}
#endif
