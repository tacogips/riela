#if os(macOS)
import AppKit

@MainActor
extension DaemonWorkflowWindowController {
  func showContentPane(_ visiblePane: NSView?) {
    let panes = [
      instancesListView,
      instanceDetailView,
      addInstanceSelectionView,
      configurationEditorView,
      sourcesOverviewView,
      workflowSourceDetailView,
      assistantOverviewView,
      profilesOverviewView,
      profileDetailView
    ].compactMap { $0 }
    for pane in panes where pane !== visiblePane {
      pane.isHidden = true
    }
    guard let visiblePane else {
      contentHost?.needsLayout = true
      return
    }
    visiblePane.isHidden = false
    if visiblePane.superview !== contentHost {
      contentHost?.addSubview(visiblePane)
    }
    contentHost?.needsLayout = true
  }

  @objc func goBack() {
    if isShowingAddInstanceSelection {
      showInstancesList()
      return
    }
    if isShowingInstanceDetail, instanceDetailPane != .overview {
      showInstanceDetailOverview()
      return
    }
    if isShowingInstanceDetail {
      showInstancesList()
      return
    }
    if isShowingWorkflowSourceDetail {
      showSourcesPane()
      return
    }
    if isShowingProfileDetail, profileDetailMode == .removalConfirmation, let selectedProfileDetailName {
      showProfileDetail(selectedProfileDetailName)
      return
    }
    if isShowingProfileDetail {
      showProfilesPane()
      return
    }
    guard activeSidebarPane != .instances else {
      return
    }
    showInstancesPane()
  }

  @objc func goForward() {}

  @objc func showInstancesPane() {
    activeSidebarPane = .instances
    showInstancesList()
  }

  @objc func showSourcesPane() {
    activeSidebarPane = .sources
    rebuildSourcesOverviewView()
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    showContentPane(sourcesOverviewView)
    navigationTitleLabel.stringValue = "Workflow Sources"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showProfilesPane() {
    activeSidebarPane = .profiles
    rebuildProfilesOverviewView()
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    showContentPane(profilesOverviewView)
    navigationTitleLabel.stringValue = "Profiles"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showAssistantPane() {
    activeSidebarPane = .assistant
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    showContentPane(assistantOverviewView)
    navigationTitleLabel.stringValue = "Assistant"
    updateNavigationState()
    updateSidebarSelection()
  }

  func updateNavigationState() {
    navigationBackButton.isEnabled = isShowingAddInstanceSelection
      || isShowingInstanceDetail
      || isShowingWorkflowSourceDetail
      || activeSidebarPane != .instances
    navigationForwardButton.isEnabled = false
  }

  func updateSidebarSelection() {
    updateSidebarButton(sidebarInstancesButton, selected: activeSidebarPane == .instances)
    updateSidebarButton(sidebarSourcesButton, selected: activeSidebarPane == .sources)
    updateSidebarButton(sidebarAssistantButton, selected: activeSidebarPane == .assistant)
    updateSidebarButton(sidebarProfilesButton, selected: activeSidebarPane == .profiles)
  }

  private func updateSidebarButton(_ button: NSButton, selected: Bool) {
    button.wantsLayer = true
    button.layer?.cornerRadius = 10
    button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    button.contentTintColor = selected ? .white : .labelColor
  }
}
#endif
