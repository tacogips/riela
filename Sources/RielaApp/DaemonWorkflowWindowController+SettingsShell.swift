#if os(macOS)
import AppKit

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
    static let dividerWidth: CGFloat = 1
    static let contentGutter: CGFloat = 28
    static let toolbarHeight: CGFloat = 72
  }

  let sidebar = NSVisualEffectView()
  let toolbar = NSView()
  let contentHost = DaemonWorkflowWindowContentHostView()

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    sidebar.material = .windowBackground
    sidebar.blendingMode = .withinWindow
    sidebar.state = .active
    wantsLayer = true
    updateBackgroundColor()
    addSubview(sidebar)
    addSubview(toolbar)
    addSubview(contentHost)
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
    sidebar.frame = NSRect(x: 0, y: 0, width: Layout.sidebarWidth, height: bounds.height)
    let contentX = Layout.sidebarWidth + Layout.dividerWidth
    let contentWidth = max(0, bounds.width - contentX)
    toolbar.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: 0,
      width: max(0, contentWidth - (Layout.contentGutter * 2)),
      height: Layout.toolbarHeight
    )
    contentHost.frame = NSRect(
      x: contentX + Layout.contentGutter,
      y: Layout.toolbarHeight,
      width: max(0, contentWidth - (Layout.contentGutter * 2)),
      height: max(0, bounds.height - Layout.toolbarHeight - 18)
    )
    for subview in sidebar.subviews {
      subview.frame = sidebar.bounds
    }
    for subview in toolbar.subviews {
      subview.frame = toolbar.bounds
    }
    sidebar.layoutSubtreeIfNeeded()
    toolbar.layoutSubtreeIfNeeded()
    contentHost.layoutSubtreeIfNeeded()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.contentView = root

    configureNavigationControls()
    root.sidebar.addSubview(buildSidebar())
    root.toolbar.addSubview(buildNavigationToolbar())

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
    backToInstancesButton.target = self
    backToInstancesButton.action = #selector(showInstancesList)
    backToInstancesButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
    backToInstancesButton.imagePosition = .imageLeading
    backToInstancesButton.toolTip = "Back to instances"
    backToInstancesButton.setAccessibilityLabel("Back to Instances")
    profilePopup.toolTip = "Switch profiles or manage profiles."
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
    sidebarSearchField.placeholderString = "Search"
    sidebarSearchField.isEnabled = false
    sidebarSearchField.translatesAutoresizingMaskIntoConstraints = false
    sidebarSearchField.heightAnchor.constraint(equalToConstant: 36).isActive = true

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
      sidebarSearchField,
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
      menuStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 88),
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
    let title = NSTextField(labelWithString: "Workflow Sources")
    title.font = .systemFont(ofSize: 18, weight: .bold)
    sourcesSummaryLabel.textColor = .secondaryLabelColor
    let importRow = actionRow(
      title: "Import Workflow or Package",
      detail: "Add a workflow, package directory, or archive to this profile.",
      action: #selector(addDirectory)
    )
    let projectRow = actionRow(
      title: "Add Project Source",
      detail: "Make project workflows available to saved instances.",
      action: #selector(addProject)
    )
    let stack = settingsDocumentStack(views: [
      title,
      sourcesSummaryLabel,
      importRow,
      projectRow
    ])
    return settingsScrollView(documentStack: stack)
  }

  private func buildProfilesOverviewView() -> NSView {
    let title = NSTextField(labelWithString: "Profiles")
    title.font = .systemFont(ofSize: 18, weight: .bold)
    profilesSummaryLabel.textColor = .secondaryLabelColor
    let manageRow = actionRow(
      title: "Manage Profiles",
      detail: "Switch, create, or remove RielaApp profiles.",
      action: #selector(openProfilesFromSidebar)
    )
    let stack = settingsDocumentStack(views: [
      title,
      profilesSummaryLabel,
      manageRow
    ])
    return settingsScrollView(documentStack: stack)
  }

  private func buildAssistantOverviewView() -> NSView {
    let title = NSTextField(labelWithString: "Assistant")
    title.font = .systemFont(ofSize: 18, weight: .bold)
    assistantSummaryLabel.textColor = .secondaryLabelColor
    assistantSaveStatusLabel.textColor = .secondaryLabelColor
    assistantSaveStatusLabel.lineBreakMode = .byWordWrapping
    assistantSaveStatusLabel.maximumNumberOfLines = 2

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .controlBackgroundColor
    textView.drawsBackground = true
    assistantAssistanceTextView = textView

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true

    let saveRow = actionRow(
      title: "Save Assistance",
      detail: "Update the assistant assistance text for this profile.",
      action: #selector(saveAssistantAssistance)
    )
    let stack = settingsDocumentStack(views: [
      title,
      assistantSummaryLabel,
      scroll,
      assistantSaveStatusLabel,
      saveRow
    ])
    return settingsScrollView(documentStack: stack)
  }

  private func settingsDocumentStack(views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  private func settingsScrollView(documentStack stack: NSStackView) -> NSScrollView {
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
    ])

    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
    return scroll
  }

  private func configureToolbarButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.bezelStyle = .toolbar
    button.isBordered = false
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }
}
#endif
