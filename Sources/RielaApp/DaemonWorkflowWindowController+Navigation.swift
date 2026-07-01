#if os(macOS)
import AppKit

@MainActor
extension DaemonWorkflowWindowController {
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
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    addInstanceSelectionView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = false
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = true
    navigationTitleLabel.stringValue = "Workflow Sources"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showProfilesPane() {
    activeSidebarPane = .profiles
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    addInstanceSelectionView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = true
    profilesOverviewView?.isHidden = false
    navigationTitleLabel.stringValue = "Profiles"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showAssistantPane() {
    activeSidebarPane = .assistant
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    instancesListView?.isHidden = true
    instanceDetailView?.isHidden = true
    addInstanceSelectionView?.isHidden = true
    configurationEditorView?.isHidden = true
    sourcesOverviewView?.isHidden = true
    assistantOverviewView?.isHidden = false
    profilesOverviewView?.isHidden = true
    navigationTitleLabel.stringValue = "Assistant"
    updateNavigationState()
    updateSidebarSelection()
  }

  func updateNavigationState() {
    navigationBackButton.isEnabled = isShowingAddInstanceSelection || isShowingInstanceDetail || activeSidebarPane != .instances
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
