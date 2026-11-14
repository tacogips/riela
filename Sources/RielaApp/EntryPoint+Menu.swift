#if os(macOS)
import AppKit

extension RielaApp: NSMenuDelegate {
  func configureStatusItem() {
    guard let button = statusItem.button else {
      return
    }
    button.image = RielaAppIcon.railTemplateImage()
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Riela Workflows"
    button.setAccessibilityLabel("Riela Workflows")
  }

  func rebuildMenu() {
    guard !isStatusMenuOpen else {
      statusMenuNeedsRebuild = true
      return
    }
    // Everything the console Settings can do (workflows, worker controller,
    // web server) lives there; the menu keeps only app-level actions.
    let menu = NSMenu()
    menu.addItem(menuItem("Open Console...", action: #selector(openDesktopFromMenu)))
    let launchAtLoginItem = menuItem("Launch on Login", action: #selector(toggleLaunchAtLogin))
    launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
    menu.addItem(launchAtLoginItem)
    if let launchAtLoginDetail = launchAtLogin.menuSupplementaryStatusDescription {
      menu.addItem(supplementaryMenuItem(launchAtLoginDetail))
    }
    menu.addItem(.separator())
    menu.addItem(supplementaryMenuItem(
      rielaAppMetadataText(["Run configurations \(daemonSummary())", "Profile \(daemonProfileName.rawValue)"])
    ))
    for line in failedDaemonInstanceMenuLines() {
      menu.addItem(supplementaryMenuItem(line))
    }
    if let webServerSetupError {
      menu.addItem(supplementaryMenuItem(webServerSetupError))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("About Riela", action: #selector(showAboutPanel)))
    menu.addItem(menuItem("Quit", action: #selector(quitFromStatusMenu)))
    menu.delegate = self
    statusItem.menu = menu
    statusMenuNeedsRebuild = false
  }

  func menuWillOpen(_ menu: NSMenu) {
    isStatusMenuOpen = true
    refreshLaunchAtLoginStatus()
  }

  func menuDidClose(_ menu: NSMenu) {
    isStatusMenuOpen = false
    guard statusMenuNeedsRebuild else {
      return
    }
    Task { @MainActor [weak self] in
      self?.rebuildMenu()
    }
  }

  private func supplementaryMenuItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.toolTip = title
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
      ]
    )
    return item
  }

  private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func failedDaemonInstanceMenuLines() -> [String] {
    let failed = daemonProfileInstances.compactMap { profiledInstance -> String? in
      let snapshot = daemonRuntime.snapshot(for: profiledInstance.id)
      guard snapshot.status == .failed else {
        return nil
      }
      return "Warning: \(profiledInstance.instance.displayName): Failed"
    }
    guard failed.count > 3 else {
      return failed
    }
    return Array(failed.prefix(3)) + ["+\(failed.count - 3) more failing"]
  }

  @objc private func showAboutPanel() {
    NSApplication.shared.orderFrontStandardAboutPanel(nil)
  }

  @objc private func quitFromStatusMenu() {
    NSApplication.shared.terminate(nil)
  }
}
#endif
