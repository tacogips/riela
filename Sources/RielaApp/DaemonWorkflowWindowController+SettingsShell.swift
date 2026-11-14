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
      subview.layoutSubtreeIfNeeded()
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
    static let assistantExpandedHeight: CGFloat = 176
    static let assistantFoldedHeight: CGFloat = 42
    static let assistantBottomInset: CGFloat = 14
    static let contentAssistantSpacing: CGFloat = 12
  }

  let sidebar = NSVisualEffectView()
  let toolbar = NSView()
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
    contentHost.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: Layout.toolbarHeight,
      width: contentBodyWidth,
      height: max(0, assistantY - Layout.toolbarHeight - Layout.contentAssistantSpacing)
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
    for subview in assistantPanelHost.subviews {
      subview.frame = assistantPanelHost.bounds
    }
    sidebar.layoutSubtreeIfNeeded()
    toolbar.layoutSubtreeIfNeeded()
    contentHost.layoutSubtreeIfNeeded()
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
    root.assistantPanelHost.addSubview(buildAssistantPanel())

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
    addListButton.target = self
    addListButton.action = #selector(addListButtonPressed)
    addListButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    addListButton.bezelStyle = .toolbar
    addListButton.toolTip = "Add instance"
    addListButton.setAccessibilityLabel("Add Instance")
    emptyInstancesLabel.textColor = .secondaryLabelColor
    emptyInstancesLabel.alignment = .center
    emptyInstancesLabel.lineBreakMode = .byWordWrapping
    emptyInstancesLabel.maximumNumberOfLines = 2
    emptyInstancesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    emptyInstancesLabel.setAccessibilityLabel("No instances. Press Add Instance to select a workflow and create one.")
    profilePopup.toolTip = "Switch profiles or manage profiles."
    configureAssistantControls()
    detailTitleLabel.font = .boldSystemFont(ofSize: 18)
    for label in [
      detailTitleLabel,
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
    profiles.isHidden = true
    profilesOverviewView = profiles

    root.contentHost.addSubview(instancesList)
    root.contentHost.addSubview(detail)
    root.contentHost.addSubview(sources)
    root.contentHost.addSubview(assistant)
    root.contentHost.addSubview(profiles)
    updateAssistantPanel()
    showInstancesList()
  }

  private func configureNavigationControls() {
    configureToolbarButton(navigationBackButton, symbolName: "chevron.left", accessibilityLabel: "Back")
    configureToolbarButton(navigationForwardButton, symbolName: "chevron.right", accessibilityLabel: "Forward")
    navigationBackButton.target = self
    navigationBackButton.action = #selector(goBack)
    navigationForwardButton.target = self
    navigationForwardButton.action = #selector(goForward)
    navigationTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    navigationTitleLabel.lineBreakMode = .byTruncatingTail
  }

  private func buildNavigationToolbar() -> NSView {
    let separator = NSBox()
    separator.boxType = .separator
    let navGroup = NSStackView(views: [navigationBackButton, separator, navigationForwardButton])
    navGroup.orientation = .horizontal
    navGroup.alignment = .centerY
    navGroup.spacing = 8
    navGroup.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    navGroup.wantsLayer = true
    navGroup.layer?.cornerRadius = 18
    navGroup.layer?.borderColor = NSColor.separatorColor.cgColor
    navGroup.layer?.borderWidth = 1
    navGroup.translatesAutoresizingMaskIntoConstraints = false
    separator.heightAnchor.constraint(equalToConstant: 22).isActive = true

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
    for button in [sidebarInstancesButton, sidebarSourcesButton, sidebarAssistantButton, sidebarProfilesButton] {
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
      sidebarAssistantButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor),
      sidebarProfilesButton.widthAnchor.constraint(equalTo: menuStack.widthAnchor)
    ])
    return container
  }

  private func buildSourcesOverviewView() -> NSView {
    sourcesSummaryLabel.textColor = .secondaryLabelColor
    sourcesSummaryLabel.lineBreakMode = .byTruncatingTail
    let importRow = actionRow(
      title: "Import Directory",
      detail: "Add a workflow directory, package directory, .rielapkg, or .zip archive.",
      action: #selector(addDirectory)
    )
    let importURLRow = actionRow(
      title: "Import from URL",
      detail: "Add a workflow or package directory from a GitHub URL.",
      action: #selector(addURL)
    )
    let actionSection = rielaAppSettingsSection(rows: [importRow, importURLRow])
    let stack = settingsDocumentStack(views: [
      actionSection
    ])
    return overviewPane(
      title: "Workflow Sources",
      summaryLabel: sourcesSummaryLabel,
      documentStack: stack
    )
  }

  private func buildProfilesOverviewView() -> NSView {
    profilesSummaryLabel.textColor = .secondaryLabelColor
    profilesSummaryLabel.lineBreakMode = .byTruncatingTail
    let profileRows = profileNames.map { profileOverviewRow($0) }
    let profileSection = rielaAppSettingsSection(rows: profileRows)
    let addRow = actionRow(
      title: "Add Profile",
      detail: "Create a separate profile for another instance set.",
      action: #selector(addProfileFromOverview)
    )
    let editRow = actionRow(
      title: "Edit Profiles",
      detail: "Switch or remove profiles.",
      action: #selector(openProfilesFromSidebar)
    )
    let actionSection = rielaAppSettingsSection(rows: [addRow, editRow])
    let stack = settingsDocumentStack(views: [
      profileSection,
      actionSection
    ])
    return overviewPane(
      title: "Profiles",
      summaryLabel: profilesSummaryLabel,
      documentStack: stack
    )
  }

  func rebuildProfilesOverviewView() {
    let wasHidden = profilesOverviewView?.isHidden ?? true
    profilesOverviewView?.removeFromSuperview()
    let profiles = buildProfilesOverviewView()
    profiles.isHidden = wasHidden
    profilesOverviewView = profiles
    contentHost?.addSubview(profiles)
    contentHost?.needsLayout = true
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
    return actionRow(
      title: profileName.rawValue,
      detail: detail,
      action: #selector(openProfilesFromSidebar)
    )
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

  private func settingsDocumentStack(views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  private func overviewPane(
    title: String,
    summaryLabel: NSTextField,
    documentStack stack: NSStackView
  ) -> NSView {
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
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

  private func settingsScrollView(documentStack stack: NSStackView, topInset: CGFloat = 10) -> NSScrollView {
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
    RielaAssistantMiniChatStyle.configureHeaderLabels(
      title: assistantPanelTitleLabel,
      availability: assistantAvailabilityLabel,
      context: assistantContextLabel
    )

    let transcript = RielaAssistantMiniChatStyle.makeTranscriptTextView()
    assistantTranscriptTextView = transcript

    let transcriptScroll = NSScrollView()
    RielaAssistantMiniChatStyle.configureTranscriptScroll(transcriptScroll, transcript: transcript)
    assistantTranscriptScrollView = transcriptScroll

    let titleStack = NSStackView(views: [
      assistantPanelTitleLabel,
      assistantAvailabilityLabel,
      assistantContextLabel
    ])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 1
    titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let controls = NSStackView(views: [
      titleStack,
      assistantFoldButton
    ])
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false

    let input = NSStackView(views: [assistantPromptField, assistantSendButton])
    RielaAssistantMiniChatStyle.configureInputStack(input)
    assistantInputStackView = input
    assistantPromptField.heightAnchor.constraint(equalToConstant: 26).isActive = true
    assistantSendButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    assistantSendButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let panelStack = NSStackView(views: [controls, transcriptScroll, input])
    panelStack.orientation = .vertical
    panelStack.alignment = .width
    panelStack.spacing = 8
    panelStack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(panelStack)
    NSLayoutConstraint.activate([
      panelStack.topAnchor.constraint(equalTo: container.topAnchor, constant: RielaAssistantMiniChatStyle.verticalInset),
      panelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: RielaAssistantMiniChatStyle.horizontalInset),
      panelStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -RielaAssistantMiniChatStyle.horizontalInset),
      panelStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -RielaAssistantMiniChatStyle.verticalInset),
      input.heightAnchor.constraint(equalToConstant: RielaAssistantMiniChatStyle.inputHeight)
    ])
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
