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
      marketplaceOverviewView,
      marketplaceWorkflowDetailView,
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
    if isShowingInstanceDetail, instanceDetailPane == .removalConfirmation {
      showInstanceDetailOverview()
      return
    }
    if isShowingInstanceDetail, instanceDetailPane != .overview {
      guard dismissConfigurationEditorOrWarn() else {
        return
      }
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
    if isShowingMarketplaceWorkflowDetail {
      showMarketplacePane()
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
    isShowingMarketplaceWorkflowDetail = false
    showContentPane(sourcesOverviewView)
    navigationTitleLabel.stringValue = "Workflow Sources"
    updateNavigationState()
    updateSidebarSelection()
  }

  @objc func showMarketplacePane() {
    activeSidebarPane = .marketplace
    rebuildMarketplaceOverviewView()
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    isShowingMarketplaceWorkflowDetail = false
    showContentPane(marketplaceOverviewView)
    navigationTitleLabel.stringValue = "Install Workflow"
    updateNavigationState()
    updateSidebarSelection()
    requestMarketplaceCatalogsIfNeeded()
  }

  @objc func showProfilesPane() {
    activeSidebarPane = .profiles
    rebuildProfilesOverviewView()
    isShowingInstanceDetail = false
    isShowingAddInstanceSelection = false
    isShowingProfileDetail = false
    isShowingWorkflowSourceDetail = false
    isShowingMarketplaceWorkflowDetail = false
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
    isShowingMarketplaceWorkflowDetail = false
    showContentPane(assistantOverviewView)
    navigationTitleLabel.stringValue = "Assistant"
    updateNavigationState()
    updateSidebarSelection()
  }

  func updateNavigationState() {
    navigationBackButton.isEnabled = isShowingAddInstanceSelection
      || isShowingInstanceDetail
      || isShowingWorkflowSourceDetail
      || isShowingMarketplaceWorkflowDetail
      || activeSidebarPane != .instances
  }

  func updateSidebarSelection() {
    updateSidebarButton(sidebarInstancesButton, selected: activeSidebarPane == .instances)
    updateSidebarButton(sidebarSourcesButton, selected: activeSidebarPane == .sources)
    updateSidebarButton(sidebarMarketplaceButton, selected: activeSidebarPane == .marketplace)
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
