#if os(macOS)
import AppKit

final class DaemonWorkflowInstanceListView: NSView {
  static let listBottomPadding: CGFloat = 18

  private enum Layout {
    static let headerHeight: CGFloat = 28
    static let verticalSpacing: CGFloat = 12
    static let footerHeight: CGFloat = 44
    static let footerHorizontalInset: CGFloat = 12
    static let emptyLabelWidth: CGFloat = 360
    static let emptyLabelHeight: CGFloat = 44
  }

  let header: NSView
  let scrollView: NSScrollView
  let footer: NSView
  let emptyLabel: NSTextField
  private let scrollBackgroundView = NSView()

  init(header: NSView, scrollView: NSScrollView, footer: NSView, emptyLabel: NSTextField) {
    self.header = header
    self.scrollView = scrollView
    self.footer = footer
    self.emptyLabel = emptyLabel
    super.init(frame: .zero)
    scrollBackgroundView.wantsLayer = true
    scrollBackgroundView.layer?.cornerRadius = 14
    scrollBackgroundView.layer?.masksToBounds = true
    updateScrollBackgroundColor()
    addSubview(header)
    addSubview(scrollBackgroundView)
    addSubview(scrollView)
    addSubview(footer)
    addSubview(emptyLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateScrollBackgroundColor()
  }

  override func layout() {
    super.layout()
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Layout.headerHeight)
    let panelY = Layout.headerHeight + Layout.verticalSpacing
    let availablePanelHeight = max(0, bounds.height - panelY)
    let panelHeight = min(availablePanelHeight, preferredPanelHeight(defaultHeight: availablePanelHeight))
    let footerHeight = min(Layout.footerHeight, panelHeight)
    let scrollHeight = max(0, panelHeight - footerHeight)
    scrollView.frame = NSRect(
      x: 0,
      y: panelY,
      width: bounds.width,
      height: scrollHeight
    )
    scrollBackgroundView.frame = NSRect(x: 0, y: panelY, width: bounds.width, height: panelHeight)
    footer.frame = NSRect(x: 0, y: panelY + scrollHeight, width: bounds.width, height: footerHeight)
    if let footerStack = footer as? NSStackView {
      footerStack.edgeInsets = NSEdgeInsets(
        top: 0,
        left: Layout.footerHorizontalInset,
        bottom: 0,
        right: Layout.footerHorizontalInset
      )
    }
    footer.layoutSubtreeIfNeeded()
    let emptyWidth = min(Layout.emptyLabelWidth, max(0, scrollView.bounds.width - 32))
    emptyLabel.frame = NSRect(
      x: scrollView.frame.minX + max(16, (scrollView.bounds.width - emptyWidth) / 2),
      y: scrollView.frame.minY + max(0, (scrollView.bounds.height - Layout.emptyLabelHeight) / 2),
      width: emptyWidth,
      height: Layout.emptyLabelHeight
    )
  }

  private func preferredPanelHeight(defaultHeight: CGFloat) -> CGFloat {
    guard
      let table = scrollView.documentView as? NSTableView,
      table.numberOfRows > 0
    else {
      return defaultHeight
    }
    let rowHeight = table.rowHeight + table.intercellSpacing.height
    return max(rowHeight, CGFloat(table.numberOfRows) * rowHeight)
      + Self.listBottomPadding
      + Layout.footerHeight
  }

  private func updateScrollBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let surfaceColor = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor)
        ?? NSColor.controlBackgroundColor
      scrollBackgroundView.layer?.backgroundColor = surfaceColor.cgColor
    }
  }
}

final class DaemonWorkflowOverviewPaneView: NSView {
  static let contentBottomPadding: CGFloat = 18

  private enum Layout {
    static let headerHeight: CGFloat = 28
    static let verticalSpacing: CGFloat = 12
  }

  let header: NSView
  let contentView: NSView

  init(header: NSView, contentView: NSView) {
    self.header = header
    self.contentView = contentView
    super.init(frame: .zero)
    addSubview(header)
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Layout.headerHeight)
    let contentY = Layout.headerHeight + Layout.verticalSpacing
    let availableContentHeight = max(0, bounds.height - contentY)
    contentView.frame = NSRect(
      x: 0,
      y: contentY,
      width: bounds.width,
      height: preferredContentHeight(defaultHeight: availableContentHeight)
    )
  }

  private func preferredContentHeight(defaultHeight: CGFloat) -> CGFloat {
    guard
      let scroll = contentView as? NSScrollView,
      let stack = scroll.documentView?.subviews.first as? NSStackView
    else {
      return defaultHeight
    }
    stack.layoutSubtreeIfNeeded()
    let visibleViews = stack.arrangedSubviews.filter { !$0.isHidden }
    let estimatedStackHeight = visibleViews.enumerated().reduce(CGFloat(0)) { partial, item in
      let spacing = item.offset == 0 ? CGFloat(0) : stack.spacing
      return partial + spacing + preferredHeight(for: item.element)
    }
    let contentHeight = max(stack.fittingSize.height, estimatedStackHeight) + Self.contentBottomPadding
    scroll.hasVerticalScroller = contentHeight > defaultHeight + 0.5
    return min(defaultHeight, max(1, contentHeight))
  }

  private func preferredHeight(for view: NSView) -> CGFloat {
    if let section = view as? RielaAppSettingsSectionView {
      return section.preferredGroupedListHeight
    }
    return max(view.fittingSize.height, view.frame.height)
  }
}

extension DaemonWorkflowWindowController {
  func settingRow(
    title: String,
    valueLabel: NSTextField,
    action: Selector?
  ) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 130)
    valueLabel.textColor = .labelColor
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    var views: [NSView] = [titleLabel, valueLabel, spacer]
    if action != nil {
      views.append(rielaAppDisclosureIndicator())
    }
    if let action {
      let row = RielaAppSelectableSettingsRow(views: views)
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
    let row = RielaAppSettingsRow(views: views)
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel(title)
    row.setAccessibilityValue(valueLabel.stringValue)
    return rielaAppSettingsRow(row)
  }

  func actionRow(
    title: String,
    detail: String,
    style: DetailActionStyle = .normal,
    action: Selector
  ) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.textColor = style.titleColor
    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byTruncatingTail
    let labelStack = NSStackView(views: [titleLabel, detailLabel])
    labelStack.orientation = .vertical
    labelStack.spacing = 2
    labelStack.alignment = .leading
    labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSelectableSettingsRow(views: [labelStack, spacer, rielaAppDisclosureIndicator()])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.toolTip = detail
    return rielaAppSelectableSettingsRow(
      row,
      target: self,
      action: action,
      accessibilityLabel: title,
      accessibilityHelp: detail
    )
  }

  func workflowList(title: String, table: NSTableView) -> NSView {
    table.delegate = self
    table.dataSource = self
    table.rowHeight = 62
    table.intercellSpacing = .zero
    rielaAppConfigureSettingsTableSelection(table)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.action = #selector(tableClicked(_:))
    table.doubleAction = #selector(tableDoubleClicked(_:))
    table.target = self
    table.headerView = nil
    addColumn(Column.instance, title: "", initialWidth: 360, to: table)

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(
      top: 0,
      left: 0,
      bottom: DaemonWorkflowInstanceListView.listBottomPadding,
      right: 0
    )
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    rielaAppConfigureGroupedListScroll(scroll)
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [
      label,
      headerSpacer,
      profilePopup,
      refreshButton
    ])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY
    header.translatesAutoresizingMaskIntoConstraints = true
    header.autoresizingMask = []
    let footerSpacer = NSView()
    footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let footer = NSStackView(views: [footerSpacer, addListButton])
    footer.orientation = .horizontal
    footer.spacing = 8
    footer.alignment = .centerY
    footer.translatesAutoresizingMaskIntoConstraints = true
    footer.autoresizingMask = []
    emptyInstancesLabel.translatesAutoresizingMaskIntoConstraints = true
    emptyInstancesLabel.autoresizingMask = []
    return DaemonWorkflowInstanceListView(
      header: header,
      scrollView: scroll,
      footer: footer,
      emptyLabel: emptyInstancesLabel
    )
  }

  func makeInstanceRowView(
    for row: ConfiguredWorkflowInstanceRow,
    in tableView: NSTableView,
    tableRow: Int
  ) -> NSView {
    let cell = RielaAppTableSelectionCellView()
    cell.configureSelection(
      tableView: tableView,
      row: tableRow,
      role: .button,
      accessibilityLabel: row.instanceName,
      accessibilityValue: row.state.rawValue,
      accessibilityHelp: "Show instance details",
      actionTarget: self,
      action: #selector(tableClicked(_:))
    )
    cell.wantsLayer = true
    cell.configureGroupedListStyle(
      separatorLeadingInset: 60,
      showsSeparator: tableRow < instanceRows.count - 1
    )

    let tile = RielaAppSymbolTileView(
      symbolName: "rectangle.stack.fill",
      backgroundColor: stateColor(for: row.state)
    )

    let title = NSTextField(labelWithString: row.instanceName)
    title.font = .systemFont(ofSize: 14, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let subtitle = NSTextField(labelWithString: instanceSubtitle(for: row))
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingMiddle
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let textStack = NSStackView(views: [title, subtitle])
    textStack.orientation = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stateIcon = NSImageView(
      image: NSImage(systemSymbolName: stateSymbolName(for: row.state), accessibilityDescription: nil) ?? NSImage()
    )
    stateIcon.contentTintColor = stateColor(for: row.state)
    stateIcon.setAccessibilityElement(false)
    let state = NSTextField(labelWithString: row.state.rawValue)
    state.font = .systemFont(ofSize: 12, weight: .medium)
    state.textColor = stateColor(for: row.state)
    state.alignment = .right
    state.lineBreakMode = .byTruncatingTail
    state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let stateStack = NSStackView(views: [stateIcon, state])
    stateStack.orientation = .horizontal
    stateStack.spacing = 4
    stateStack.alignment = .centerY
    stateStack.setAccessibilityLabel(row.state.rawValue)
    stateStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let rowStack = NSStackView(views: [tile, textStack, spacer, stateStack, rielaAppDisclosureIndicator()])
    rowStack.orientation = .horizontal
    rowStack.spacing = 12
    rowStack.alignment = .centerY
    rowStack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
      rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
      rowStack.topAnchor.constraint(equalTo: cell.topAnchor),
      rowStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
    ])
    return cell
  }

  private func addColumn(
    _ identifier: NSUserInterfaceItemIdentifier,
    title: String,
    initialWidth: CGFloat,
    to table: NSTableView
  ) {
    let column = NSTableColumn(identifier: identifier)
    column.title = title
    column.minWidth = 180
    column.width = initialWidth
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
  }

  private func instanceSubtitle(for row: ConfiguredWorkflowInstanceRow) -> String {
    guard let candidate = row.candidate else {
      return rielaAppMetadataText([row.workflowName, "Missing source", row.sourceIdentity])
    }
    return rielaAppMetadataText([row.workflowName, environmentColumnStatus(candidate), row.sourceDescription])
  }

  private func stateColor(for state: InstanceState) -> NSColor {
    switch state {
    case .running:
      .systemGreen
    case .failed:
      .systemRed
    case .starting, .reloading, .stopping:
      .systemOrange
    case .needsSource:
      .systemYellow
    case .stopped:
      .secondaryLabelColor
    }
  }

  private func stateSymbolName(for state: InstanceState) -> String {
    switch state {
    case .running:
      "play.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    case .starting, .reloading, .stopping:
      "arrow.triangle.2.circlepath.circle.fill"
    case .needsSource:
      "questionmark.circle.fill"
    case .stopped:
      "pause.circle.fill"
    }
  }
}

#endif
