#if os(macOS)
import AppKit

extension WorkflowViewerWindowController {
  func installViewerRoot(splitView: NSSplitView, in contentView: NSView) {
    assistantPanelHost.translatesAutoresizingMaskIntoConstraints = false
    let assistantPanel = buildAssistantPanel()
    assistantPanel.translatesAutoresizingMaskIntoConstraints = false
    assistantPanelHost.addSubview(assistantPanel)
    assistantPanelHeightConstraint = assistantPanelHost.heightAnchor.constraint(equalToConstant: 176)
    assistantPanelHeightConstraint?.isActive = true
    assistantPanelExpandedWidthConstraint = assistantPanel.leadingAnchor.constraint(
      equalTo: assistantPanelHost.leadingAnchor,
      constant: 12
    )
    assistantPanelFoldedWidthConstraint = assistantPanel.widthAnchor.constraint(
      equalToConstant: RielaAssistantMiniChatStyle.foldedPanelWidth
    )
    assistantPanelExpandedWidthConstraint?.isActive = true

    let rootStack = NSStackView(views: [splitView, assistantPanelHost])
    rootStack.orientation = .vertical
    rootStack.alignment = .width
    rootStack.spacing = 12
    rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
      rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      splitView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
      assistantPanelHost.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
      splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
      assistantPanel.topAnchor.constraint(equalTo: assistantPanelHost.topAnchor),
      assistantPanel.trailingAnchor.constraint(equalTo: assistantPanelHost.trailingAnchor, constant: -12),
      assistantPanel.bottomAnchor.constraint(equalTo: assistantPanelHost.bottomAnchor)
    ])
  }

  func configureReadOnlyTextView(
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

  func scrollView(for textView: NSTextView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    return scroll
  }

  func tabItem(label: String, view: NSView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: label)
    item.label = label
    item.view = view
    return item
  }

  func graphTabView() -> NSView {
    let container = NSView()
    workflowGraphPaneView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(workflowGraphPaneView)
    NSLayoutConstraint.activate([
      workflowGraphPaneView.topAnchor.constraint(equalTo: container.topAnchor),
      workflowGraphPaneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      workflowGraphPaneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      workflowGraphPaneView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    return container
  }

  func timelineTabView() -> NSView {
    let container = NSView()
    workflowTimelinePaneView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(workflowTimelinePaneView)
    NSLayoutConstraint.activate([
      workflowTimelinePaneView.topAnchor.constraint(equalTo: container.topAnchor),
      workflowTimelinePaneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      workflowTimelinePaneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      workflowTimelinePaneView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    return container
  }

  func managerResponseBarView() -> NSView {
    managerResponseBanner.orientation = .horizontal
    managerResponseBanner.alignment = .centerY
    managerResponseBanner.spacing = 8
    managerResponseBanner.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    managerResponseBanner.wantsLayer = true
    managerResponseBanner.layer?.cornerRadius = 8
    managerResponseBanner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    managerResponseBanner.isHidden = true
    managerResponseBanner.translatesAutoresizingMaskIntoConstraints = false

    managerResponseLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    managerResponseLabel.textColor = .labelColor
    managerResponseLabel.lineBreakMode = .byTruncatingMiddle
    managerResponseLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    managerResponseStatusLabel.font = .systemFont(ofSize: 11)
    managerResponseStatusLabel.textColor = .secondaryLabelColor
    managerResponseStatusLabel.lineBreakMode = .byTruncatingTail
    managerResponseStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    managerRespondButton.target = self
    managerRespondButton.action = #selector(respondToManager)
    managerRespondButton.bezelStyle = .rounded
    managerRespondButton.setAccessibilityLabel("Respond to Workflow Run")

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    managerResponseBanner.addArrangedSubview(managerResponseLabel)
    managerResponseBanner.addArrangedSubview(managerResponseStatusLabel)
    managerResponseBanner.addArrangedSubview(spacer)
    managerResponseBanner.addArrangedSubview(managerRespondButton)
    return managerResponseBanner
  }

  func applyPreferredHeight(_ height: CGFloat, to view: NSView) {
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    let preferredHeight = view.heightAnchor.constraint(equalToConstant: height)
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true
  }

  func instanceSettingRow(
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

  func updateInstanceSettingRows() {
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
}
#endif
