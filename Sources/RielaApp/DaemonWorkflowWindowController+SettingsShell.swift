#if os(macOS)
import AppKit
import RielaAppSupport

final class DaemonWorkflowWindowContentHostView: NSView {
  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    for subview in subviews {
      subview.frame = bounds
      if subview.isHidden {
        subview.needsLayout = false
      } else {
        subview.needsLayout = true
        subview.layoutSubtreeIfNeeded()
      }
    }
  }
}

final class DaemonWorkflowSettingsRootView: NSView {
  private enum Layout {
    static let sidebarWidth: CGFloat = 280
    static let sidebarInset: CGFloat = 8
    static let sidebarContentGap: CGFloat = 18
    static let sidebarCornerRadius: CGFloat = 22
    static let contentGutter: CGFloat = 28
    static let toolbarHeight: CGFloat = 72
    static let bannerHeight: CGFloat = 36
    static let bannerSpacing: CGFloat = 8
    static let assistantExpandedHeight: CGFloat = 176
    static let assistantFoldedHeight: CGFloat = 42
    static let assistantBottomInset: CGFloat = 14
    static let contentAssistantSpacing: CGFloat = 12
  }

  let sidebar = NSVisualEffectView()
  let toolbar = NSView()
  let statusBannerHost = NSView()
  let contentHost = DaemonWorkflowWindowContentHostView()
  let assistantPanelHost = NSView()
  var assistantPanelCollapsed = false

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    sidebar.material = .windowBackground
    sidebar.blendingMode = .withinWindow
    sidebar.state = .active
    sidebar.wantsLayer = true
    sidebar.layer?.cornerRadius = Layout.sidebarCornerRadius
    sidebar.layer?.masksToBounds = true
    sidebar.layer?.borderWidth = 1
    sidebar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    wantsLayer = true
    updateBackgroundColor()
    addSubview(sidebar)
    addSubview(toolbar)
    addSubview(statusBannerHost)
    addSubview(contentHost)
    addSubview(assistantPanelHost)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  override func layout() {
    super.layout()
    sidebar.frame = NSRect(
      x: Layout.sidebarInset,
      y: Layout.sidebarInset,
      width: Layout.sidebarWidth,
      height: max(0, bounds.height - (Layout.sidebarInset * 2))
    )
    let contentX = sidebar.frame.maxX + Layout.sidebarContentGap
    let contentWidth = max(0, bounds.width - contentX)
    let assistantHeight = assistantPanelCollapsed ? Layout.assistantFoldedHeight : Layout.assistantExpandedHeight
    let contentBodyWidth = max(0, contentWidth - (Layout.contentGutter * 2))
    let assistantY = max(
      Layout.toolbarHeight,
      bounds.height - Layout.assistantBottomInset - assistantHeight
    )
    toolbar.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: 0,
      width: contentBodyWidth,
      height: Layout.toolbarHeight
    )
    let bannerHeight = statusBannerHost.subviews.contains { !$0.isHidden } ? Layout.bannerHeight : 0
    let bannerSpacing = bannerHeight > 0 ? Layout.bannerSpacing : 0
    statusBannerHost.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: Layout.toolbarHeight,
      width: contentBodyWidth,
      height: bannerHeight
    )
    contentHost.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: Layout.toolbarHeight + bannerHeight + bannerSpacing,
      width: contentBodyWidth,
      height: max(0, assistantY - Layout.toolbarHeight - bannerHeight - bannerSpacing - Layout.contentAssistantSpacing)
    )
    assistantPanelHost.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: assistantY,
      width: contentBodyWidth,
      height: assistantHeight
    )
    for subview in sidebar.subviews {
      subview.frame = sidebar.bounds
    }
    for subview in toolbar.subviews {
      subview.frame = toolbar.bounds
    }
    for subview in statusBannerHost.subviews {
      subview.frame = statusBannerHost.bounds
    }
    for subview in assistantPanelHost.subviews {
      subview.frame = assistantPanelHost.bounds
    }
    sidebar.layoutSubtreeIfNeeded()
    toolbar.layoutSubtreeIfNeeded()
    statusBannerHost.layoutSubtreeIfNeeded()
    contentHost.needsLayout = true
    assistantPanelHost.layoutSubtreeIfNeeded()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      sidebar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }
  }
}

@MainActor
enum DaemonWorkflowWindowLayout {
  static let initialWindowSize = NSSize(width: 920, height: 680)
  static let minimumWindowSize = NSSize(width: 760, height: 520)
}

extension DaemonWorkflowWindowController {
  func buildContent(in window: NSWindow) {
    let root = DaemonWorkflowSettingsRootView()
    settingsRootView = root
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.contentView = root

    configureNavigationControls()
    root.sidebar.addSubview(buildSidebar())
    root.toolbar.addSubview(buildNavigationToolbar())
    root.statusBannerHost.addSubview(statusBannerView)
    root.assistantPanelHost.addSubview(buildAssistantPanel())
    statusBannerView.isHidden = true
    statusBannerView.onDismiss = { [weak self] in
      self?.dismissStatusBanner()
    }

    profilePopup.target = self
    profilePopup.action = #selector(profilePopupChanged)
    profilePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
    profilePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    profilePopup.setAccessibilityLabel("Profile")
    refreshButton.target = self
    refreshButton.action = #selector(refresh)
    refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    refreshButton.bezelStyle = .toolbar
    refreshButton.toolTip = "Refresh instances"
    refreshButton.setAccessibilityLabel("Refresh Instances")
    instanceSearchField.placeholderString = "Filter instances"
    instanceSearchField.target = self
    instanceSearchField.delegate = self
    instanceSearchField.sendsSearchStringImmediately = true
    instanceSearchField.controlSize = .large
    instanceSearchField.setAccessibilityLabel("Filter Instances")
    instanceSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    instanceSearchField.action = #selector(instanceSearchChanged)
    addListButton.target = self
    addListButton.action = #selector(addListButtonPressed)
    addListButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    addListButton.bezelStyle = .toolbar
    addListButton.toolTip = "Add instance"
    addListButton.setAccessibilityLabel("Add Instance")
    addProfileButton.target = self
    addProfileButton.action = #selector(addProfileFromOverview)
    addProfileButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    addProfileButton.bezelStyle = .toolbar
    addProfileButton.toolTip = "Add profile"
    addProfileButton.setAccessibilityLabel("Add Profile")
    emptyInstancesLabel.textColor = .secondaryLabelColor
    emptyInstancesLabel.alignment = .center
    emptyInstancesLabel.lineBreakMode = .byWordWrapping
    emptyInstancesLabel.maximumNumberOfLines = 2
    emptyInstancesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    emptyInstancesLabel.setAccessibilityLabel("No instances. Press Add Instance to select a workflow and create one.")
    emptyInstancesGuideView.onViewWorkflowSources = { [weak self] in
      self?.showSourcesPane()
    }
    emptyInstancesGuideView.onCreateInstance = { [weak self] in
      self?.showAddInstanceSelectionPane()
    }
    emptyInstancesGuideView.translatesAutoresizingMaskIntoConstraints = true
    emptyInstancesGuideView.autoresizingMask = []
    profilePopup.toolTip = "Switch profiles or manage profiles."
    configureAssistantControls()
    configureInstanceStateProgressIndicator(detailStatusProgressIndicator, accessibilityLabel: "Instance status progress")
    detailSummaryLabel.textColor = .secondaryLabelColor
    detailSummaryLabel.lineBreakMode = .byTruncatingTail
    for label in [
      detailTitleLabel,
      detailStatusValueLabel,
      detailNameValueLabel,
      detailWorkflowValueLabel,
      detailEnvironmentValueLabel,
      detailInlineEnvironmentValueLabel,
      detailWorkingDirectoryValueLabel,
      detailVariablesValueLabel,
      detailEventSourcesValueLabel
    ] {
      label.lineBreakMode = .byTruncatingMiddle
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    let instancesList = workflowList(title: "Instances", table: instanceTable)
    instancesList.translatesAutoresizingMaskIntoConstraints = true
    instancesList.setContentHuggingPriority(.defaultLow, for: .vertical)
    instancesListView = instancesList
    contentHost = root.contentHost
    let detail = buildInstanceDetailView()
    detail.translatesAutoresizingMaskIntoConstraints = true
    detail.isHidden = true
    instanceDetailView = detail
    let sources = buildSourcesOverviewView()
    sources.isHidden = true
    sourcesOverviewView = sources
    let assistant = buildAssistantOverviewView()
    assistant.isHidden = true
    assistantOverviewView = assistant
    let profiles = buildProfilesOverviewView()
    profilesOverviewFingerprint = profilesOverviewFingerprintValue()
    profiles.isHidden = true
    profilesOverviewView = profiles

    updateAssistantPanel()
    showInstancesList()
  }

  private func configureNavigationControls() {
    configureToolbarButton(navigationBackButton, symbolName: "chevron.left", accessibilityLabel: "Back")
    navigationBackButton.target = self
    navigationBackButton.action = #selector(goBack)
    navigationTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    navigationTitleLabel.lineBreakMode = .byTruncatingTail
  }

  private func buildNavigationToolbar() -> NSView {
    let navGroup = NSStackView(views: [navigationBackButton])
    navGroup.orientation = .horizontal
    navGroup.alignment = .centerY
    navGroup.spacing = 8
    navGroup.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    navGroup.wantsLayer = true
    navGroup.layer?.cornerRadius = 18
    navGroup.layer?.borderColor = NSColor.separatorColor.cgColor
    navGroup.layer?.borderWidth = 1
    navGroup.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [navGroup, navigationTitleLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      navGroup.heightAnchor.constraint(equalToConstant: 36)
    ])
    return container
  }

  private func buildSidebar() -> NSView {
    for button in [
      sidebarInstancesButton,
      sidebarSourcesButton,
      sidebarMarketplaceButton,
      sidebarAssistantButton,
      sidebarProfilesButton
    ] {
      button.target = self
      button.bezelStyle = .regularSquare
      button.isBordered = false
      button.alignment = .left
      button.imagePosition = .imageLeading
      button.contentTintColor = .labelColor
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 38).isActive = true
    }
    sidebarInstancesButton.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
    sidebarInstancesButton.action = #selector(showInstancesPane)
    sidebarSourcesButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    sidebarSourcesButton.action = #selector(showSourcesPane)
    sidebarMarketplaceButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
    sidebarMarketplaceButton.action = #selector(showMarketplacePane)
    sidebarAssistantButton.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
    sidebarAssistantButton.action = #selector(showAssistantPane)
    sidebarProfilesButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
    sidebarProfilesButton.action = #selector(showProfilesPane)

    let appTitle = NSTextField(labelWithString: "Riela")
    appTitle.font = .systemFont(ofSize: 20, weight: .bold)
    appTitle.alignment = .left
    let menuStack = NSStackView(views: [
      appTitle,
      sidebarInstancesButton,
      sidebarSourcesButton,
      sidebarMarketplaceButton,
      sidebarAssistantButton,
      sidebarProfilesButton
    ])
    menuStack.orientation = .vertical
    menuStack.alignment = .width
    menuStack.spacing = 10
    menuStack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(menuStack)
    NSLayoutConstraint.activate([
      menuStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 56),
      menuStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
      menuStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      appTitle.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarInstancesButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarSourcesButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarMarketplaceButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarAssistantButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarProfilesButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor)
    ])
    return container
  }

  private func buildProfilesOverviewView() -> NSView {
    profilesSummaryLabel.textColor = .secondaryLabelColor
    profilesSummaryLabel.lineBreakMode = .byTruncatingTail
    let profileRows = profileNames.map { profileOverviewRow($0) }
    let profileSection = rielaAppSettingsSection(rows: profileRows)
    let stack = settingsDocumentStack(views: [
      profileSection
    ])
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    rielaAppConfigureGroupedListScroll(scroll)
    let titleLabel = NSTextField(labelWithString: "Profiles")
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    titleLabel.alignment = .left
    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [titleLabel, headerSpacer, profilesSummaryLabel])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY
    header.translatesAutoresizingMaskIntoConstraints = true
    header.autoresizingMask = []
    let footerSpacer = NSView()
    footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let footer = NSStackView(views: [footerSpacer, addProfileButton])
    footer.orientation = .horizontal
    footer.spacing = 8
    footer.alignment = .centerY
    footer.translatesAutoresizingMaskIntoConstraints = true
    footer.autoresizingMask = []
    let emptyLabel = NSTextField(labelWithString: "No profiles.")
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = !profileRows.isEmpty
    return DaemonWorkflowInstanceListView(
      header: header,
      scrollView: scroll,
      footer: footer,
      emptyLabel: emptyLabel
    )
  }

  func rebuildProfilesOverviewView() {
    let fingerprint = profilesOverviewFingerprintValue()
    guard profilesOverviewFingerprint != fingerprint || profilesOverviewView == nil else {
      return
    }
    let wasVisible = profilesOverviewView?.isHidden == false
    profilesOverviewView?.removeFromSuperview()
    let profiles = buildProfilesOverviewView()
    profiles.isHidden = !wasVisible
    profilesOverviewView = profiles
    profilesOverviewFingerprint = fingerprint
    if wasVisible {
      showContentPane(profiles)
    }
  }

  func profilesOverviewFingerprintValue() -> String {
    ([profileName.rawValue] + profileNames.map(\.rawValue)).joined(separator: "\u{0}")
  }

  private func profileOverviewRow(_ profileName: RielaAppProfileName) -> NSView {
    let detail: String
    if profileName == self.profileName {
      detail = "Current"
    } else if profileName == .default {
      detail = "Default profile"
    } else {
      detail = "Profile"
    }
    let row = actionRow(
      title: profileName.rawValue,
      detail: detail,
      action: #selector(openProfileDetailFromRow(_:))
    )
    row.identifier = NSUserInterfaceItemIdentifier(profileName.rawValue)
    return row
  }

  @objc func openProfileDetailFromRow(_ sender: Any) {
    guard
      let row = sender as? NSView,
      let rawValue = row.identifier?.rawValue
    else {
      return
    }
    showProfileDetail(RielaAppProfileName(rawValue))
  }

  func showProfileDetail(
    _ profileName: RielaAppProfileName,
    mode: ProfileDetailMode = .overview
  ) {
    activeSidebarPane = .profiles
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = true
    isShowingWorkflowSourceDetail = false
    selectedProfileDetailName = profileName
    profileDetailMode = mode
    profileDetailView?.removeFromSuperview()
    let detail = mode == .removalConfirmation
      ? buildProfileRemovalConfirmationView(profileName)
      : buildProfileDetailView(profileName)
    detail.translatesAutoresizingMaskIntoConstraints = true
    detail.isHidden = false
    profileDetailView = detail
    showContentPane(detail)
    navigationTitleLabel.stringValue = profileName.rawValue
    updateNavigationState()
    updateSidebarSelection()
  }

  private func buildProfileDetailView(_ profileName: RielaAppProfileName) -> NSView {
    let summaryLabel = NSTextField(labelWithString: profileName == self.profileName ? "Current" : "Available")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    let statusValue = NSTextField(labelWithString: profileName == self.profileName ? "Current profile" : "Available profile")
    let statusSection = rielaAppSettingsSection(rows: [
      settingRow(title: "Status", valueLabel: statusValue, action: nil)
    ])
    let useRow = actionRow(
      title: "Use Profile",
      detail: "Switch to this profile's workflow instances.",
      action: #selector(useSelectedProfileDetail)
    )
    setActionRow(useRow, enabled: profileName != self.profileName, disabledHelp: "This profile is already current.")
    let removeRow = actionRow(
      title: "Remove Profile",
      detail: "Review removal for this profile's sources, packages, and instance state.",
      style: .destructive,
      action: #selector(confirmRemoveSelectedProfileDetail)
    )
    setActionRow(removeRow, enabled: canRemoveProfile(profileName), disabledHelp: removeProfileUnavailableHelp(for: profileName))
    let actionsSection = rielaAppSettingsSection(rows: [useRow, removeRow])
    let stack = settingsDocumentStack(views: [statusSection, actionsSection])
    return overviewPane(title: profileName.rawValue, summaryLabel: summaryLabel, documentStack: stack)
  }

  private func buildProfileRemovalConfirmationView(_ profileName: RielaAppProfileName) -> NSView {
    let summaryLabel = NSTextField(labelWithString: "Confirm Removal")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    let messageValue = NSTextField(
      labelWithString: "Removes only this profile's workflow sources, packages, and instance state."
    )
    messageValue.lineBreakMode = .byWordWrapping
    messageValue.maximumNumberOfLines = 2
    let messageSection = rielaAppSettingsSection(rows: [
      settingRow(title: "Scope", valueLabel: messageValue, action: nil)
    ])
    let cancelRow = actionRow(
      title: "Cancel",
      detail: "Return to this profile without removing it.",
      action: #selector(cancelRemoveSelectedProfileDetail)
    )
    let removeRow = actionRow(
      title: "Remove Profile",
      detail: "Remove this profile. Other profiles are unchanged.",
      style: .destructive,
      action: #selector(removeSelectedProfileDetail)
    )
    let actionsSection = rielaAppSettingsSection(rows: [cancelRow, removeRow])
    let stack = settingsDocumentStack(views: [messageSection, actionsSection])
    return overviewPane(title: profileName.rawValue, summaryLabel: summaryLabel, documentStack: stack)
  }

  private func setActionRow(_ row: NSStackView, enabled: Bool, disabledHelp: String) {
    guard let selectableRow = row as? RielaAppSelectableSettingsRow else {
      return
    }
    selectableRow.setRielaAccessibilityEnabled(enabled)
    if !enabled {
      selectableRow.toolTip = disabledHelp
      selectableRow.setAccessibilityHelp(disabledHelp)
    }
  }

  @objc func useSelectedProfileDetail() {
    guard let selectedProfileDetailName, selectedProfileDetailName != profileName else {
      return
    }
    onSelectProfile(selectedProfileDetailName.rawValue)
  }

  @objc func confirmRemoveSelectedProfileDetail() {
    guard let selectedProfileDetailName, canRemoveProfile(selectedProfileDetailName) else {
      return
    }
    showProfileDetail(selectedProfileDetailName, mode: .removalConfirmation)
  }

  @objc func cancelRemoveSelectedProfileDetail() {
    guard let selectedProfileDetailName else {
      showProfilesPane()
      return
    }
    showProfileDetail(selectedProfileDetailName)
  }

  @objc func removeSelectedProfileDetail() {
    guard let selectedProfileDetailName, canRemoveProfile(selectedProfileDetailName) else {
      return
    }
    guard onRemoveProfile(selectedProfileDetailName) else {
      showProfileDetail(selectedProfileDetailName)
      return
    }
    showProfilesPane()
  }

  private func canRemoveProfile(_ profileName: RielaAppProfileName) -> Bool {
    profileName != .default && profileName != self.profileName
  }

  private func removeProfileUnavailableHelp(for profileName: RielaAppProfileName) -> String {
    if profileName == .default {
      return "Default profile cannot be removed."
    }
    if profileName == self.profileName {
      return "Current profile cannot be removed."
    }
    return "Choose a removable profile first."
  }

  private func buildAssistantOverviewView() -> NSView {
    assistantSummaryLabel.textColor = .secondaryLabelColor
    assistantSummaryLabel.lineBreakMode = .byTruncatingTail
    assistantAssistanceTextView = nil
    configureAssistantSettingsControls()
    let vendorRow = controlSettingRow(title: "Vendor", control: assistantSettingsVendorPopup)
    let modelRow = controlSettingRow(title: "Model", control: assistantSettingsModelPopup)
    let actionSection = rielaAppSettingsSection(rows: [vendorRow, modelRow])
    let stack = settingsDocumentStack(views: [
      actionSection
    ])
    return overviewPane(
      title: "Assistant",
      summaryLabel: assistantSummaryLabel,
      documentStack: stack
    )
  }

  func settingsDocumentStack(views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func overviewPane(
    title: String,
    summaryLabel: NSTextField,
    documentStack stack: NSStackView
  ) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    return overviewPane(titleLabel: titleLabel, summaryLabel: summaryLabel, documentStack: stack)
  }

  func overviewPane(
    titleLabel: NSTextField,
    summaryLabel: NSTextField,
    documentStack stack: NSStackView
  ) -> NSView {
    titleLabel.alignment = .left
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    titleLabel.lineBreakMode = .byTruncatingTail
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [titleLabel, spacer, summaryLabel])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY
    header.translatesAutoresizingMaskIntoConstraints = true
    header.autoresizingMask = []
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    return DaemonWorkflowOverviewPaneView(header: header, contentView: scroll)
  }

  func settingsScrollView(documentStack stack: NSStackView, topInset: CGFloat = 10) -> NSScrollView {
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: topInset),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(
        equalTo: document.bottomAnchor,
        constant: -DaemonWorkflowOverviewPaneView.contentBottomPadding
      )
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

  private func configureToolbarButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.bezelStyle = .toolbar
    button.isBordered = false
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }

  private func configureAssistantControls() {
    assistantFoldButton.target = self
    assistantFoldButton.action = #selector(toggleAssistantFolded)
    RielaAssistantMiniChatStyle.configureFoldButton(assistantFoldButton)

    assistantPromptField.target = self
    assistantPromptField.action = #selector(sendAssistantMessage)
    RielaAssistantMiniChatStyle.configurePromptField(assistantPromptField)

    assistantSendButton.target = self
    assistantSendButton.action = #selector(sendAssistantMessage)
    RielaAssistantMiniChatStyle.configureSendButton(assistantSendButton)
  }

  private func configureAssistantSettingsControls() {
    assistantSettingsVendorPopup.target = self
    assistantSettingsVendorPopup.action = #selector(assistantVendorChanged)
    assistantSettingsVendorPopup.setAccessibilityLabel("Assistant Vendor")
    assistantSettingsVendorPopup.toolTip = "Assistant vendor"
    assistantSettingsModelPopup.target = self
    assistantSettingsModelPopup.action = #selector(assistantModelChanged)
    assistantSettingsModelPopup.setAccessibilityLabel("Assistant Model")
    assistantSettingsModelPopup.toolTip = "Assistant model"
    RielaAssistantMiniChatStyle.configurePickerControls(
      vendorPopup: assistantSettingsVendorPopup,
      modelField: assistantSettingsModelPopup
    )
  }

  private func buildAssistantPanel() -> NSView {
    let container = NSView()
    RielaAssistantMiniChatStyle.configurePanelContainer(container)
    let titleStack = RielaAssistantMiniChatStyle.makeTitleStack(
      title: assistantPanelTitleLabel,
      availability: assistantAvailabilityLabel,
      context: assistantContextLabel
    )

    let transcript = RielaAssistantMiniChatStyle.makeTranscriptTextView()
    assistantTranscriptTextView = transcript

    let transcriptScroll = NSScrollView()
    RielaAssistantMiniChatStyle.configureTranscriptScroll(transcriptScroll, transcript: transcript)
    assistantTranscriptScrollView = transcriptScroll

    let controls = RielaAssistantMiniChatStyle.makeHeaderStack(titleStack: titleStack, trailingControls: [
      assistantFoldButton
    ])

    let input = RielaAssistantMiniChatStyle.makeInputStack(
      promptField: assistantPromptField,
      sendButton: assistantSendButton
    )
    assistantInputStackView = input

    let panelStack = RielaAssistantMiniChatStyle.makePanelStack(header: controls, transcriptScroll: transcriptScroll, input: input)
    RielaAssistantMiniChatStyle.installPanelStack(panelStack, input: input, in: container)
    return container
  }

  private func controlSettingRow(title: String, control: NSControl) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 130)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel, control, spacer])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel(title)
    return rielaAppSettingsRow(row)
  }
}
#endif
