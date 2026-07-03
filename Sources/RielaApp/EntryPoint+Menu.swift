#if os(macOS)
import AppKit

extension RielaApp {
  func configureStatusItem() {
    guard let button = statusItem.button else {
      return
    }
    button.image = RielaAppIcon.workflowTemplateImage()
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Riela workflow instances"
    button.setAccessibilityLabel("Riela workflow instances")
  }

  func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Instances...", action: #selector(openDaemonInstances)))
    let launchAtLoginItem = menuItem("Launch on Login", action: #selector(toggleLaunchAtLogin))
    launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
    menu.addItem(launchAtLoginItem)
    if let launchAtLoginDetail = launchAtLogin.menuSupplementaryStatusDescription {
      menu.addItem(supplementaryMenuItem(launchAtLoginDetail))
    }
    menu.addItem(.separator())
    menu.addItem(supplementaryMenuItem(
      rielaAppMetadataText(["Instances \(daemonSummary())", "Profile \(daemonProfileName.rawValue)"])
    ))
    for line in failedDaemonInstanceMenuLines() {
      menu.addItem(supplementaryMenuItem(line))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("About Riela", action: #selector(showAboutPanel)))
    menu.addItem(menuItem("Quit", action: #selector(quitFromStatusMenu)))
    statusItem.menu = menu
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

  private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
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
