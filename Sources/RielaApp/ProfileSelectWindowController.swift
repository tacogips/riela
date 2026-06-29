#if os(macOS)
import AppKit
import RielaAppSupport

@MainActor
final class ProfileSelectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  static let menuTitle = "Profile Select..."

  private let tableView = NSTableView()
  private let addButton = NSButton(title: "+", target: nil, action: nil)
  private let removeButton = NSButton(title: "-", target: nil, action: nil)
  private let openButton = NSButton(title: "Open", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let statusLabel = NSTextField(labelWithString: "")
  private let onSelectProfile: (String) -> Void
  private let onCreateProfile: (String) -> RielaAppProfileName?
  private let onRemoveProfile: (RielaAppProfileName) -> Bool
  private var currentProfile = RielaAppProfileName.default
  private var profileNames: [RielaAppProfileName] = [.default]

  init(
    onSelectProfile: @escaping (String) -> Void,
    onCreateProfile: @escaping (String) -> RielaAppProfileName?,
    onRemoveProfile: @escaping (RielaAppProfileName) -> Bool
  ) {
    self.onSelectProfile = onSelectProfile
    self.onCreateProfile = onCreateProfile
    self.onRemoveProfile = onRemoveProfile
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Profile Select"
    super.init(window: window)
    buildContent(in: window)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func show(
    currentProfile: RielaAppProfileName,
    profileNames: [RielaAppProfileName],
    parentWindow: NSWindow?
  ) {
    self.currentProfile = currentProfile
    self.profileNames = profileNames
    tableView.reloadData()
    selectProfile(currentProfile)
    updateButtons()
    statusLabel.stringValue = ""
    guard let window else {
      return
    }
    if let parentWindow {
      parentWindow.beginSheet(window)
    } else {
      showWindow(nil)
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func buildContent(in window: NSWindow) {
    guard let root = window.contentView else {
      return
    }
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
    column.title = "Profile"
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.delegate = self
    tableView.dataSource = self
    tableView.doubleAction = #selector(openSelectedProfile)
    tableView.target = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    addButton.target = self
    addButton.action = #selector(addProfile)
    addButton.bezelStyle = .texturedRounded
    addButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    removeButton.target = self
    removeButton.action = #selector(removeProfile)
    removeButton.bezelStyle = .texturedRounded
    removeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    openButton.target = self
    openButton.action = #selector(openSelectedProfile)
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle

    let listControls = NSStackView(views: [addButton, removeButton])
    listControls.orientation = .horizontal
    listControls.spacing = 4
    let buttonRow = NSStackView(views: [listControls, NSView(), cancelButton, openButton])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 8
    let stack = NSStackView(views: [scrollView, statusLabel, buttonRow])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    ])
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    profileNames.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: profileNames[row].rawValue)
    if profileNames[row] == currentProfile {
      label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    }
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateButtons()
  }

  @objc private func addProfile() {
    guard let rawName = promptForProfileName() else {
      return
    }
    guard let profileName = onCreateProfile(rawName) else {
      statusLabel.stringValue = "Failed to add profile"
      return
    }
    if !profileNames.contains(profileName) {
      profileNames.append(profileName)
      profileNames.sort { lhs, rhs in
        lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
      }
    }
    tableView.reloadData()
    selectProfile(profileName)
    statusLabel.stringValue = "Added profile \(profileName.rawValue)"
  }

  @objc private func removeProfile() {
    guard let profileName = selectedProfile() else {
      return
    }
    guard profileName != .default else {
      statusLabel.stringValue = "Default profile cannot be removed"
      return
    }
    guard profileName != currentProfile else {
      statusLabel.stringValue = "Current profile cannot be removed"
      return
    }
    guard confirmProfileRemoval(profileName) else {
      return
    }
    guard onRemoveProfile(profileName) else {
      statusLabel.stringValue = "Failed to remove profile \(profileName.rawValue)"
      return
    }
    profileNames.removeAll { $0 == profileName }
    tableView.reloadData()
    selectProfile(currentProfile)
    statusLabel.stringValue = "Removed profile \(profileName.rawValue)"
  }

  @objc private func openSelectedProfile() {
    guard let profileName = selectedProfile() else {
      return
    }
    closeSheet()
    onSelectProfile(profileName.rawValue)
  }

  @objc private func cancel() {
    closeSheet()
  }

  private func promptForProfileName() -> String? {
    let field = NSTextField(string: "")
    field.placeholderString = RielaAppProfileName.defaultRawValue
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    let alert = NSAlert()
    alert.messageText = "Add Profile"
    alert.accessoryView = field
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return field.stringValue
  }

  private func confirmProfileRemoval(_ profileName: RielaAppProfileName) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Remove Profile"
    alert.informativeText = "Remove profile \(profileName.rawValue) and its workflow sources, packages, and instance state?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func selectedProfile() -> RielaAppProfileName? {
    let row = tableView.selectedRow
    guard profileNames.indices.contains(row) else {
      return nil
    }
    return profileNames[row]
  }

  private func selectProfile(_ profileName: RielaAppProfileName) {
    guard let row = profileNames.firstIndex(of: profileName) else {
      return
    }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  private func updateButtons() {
    let selected = selectedProfile()
    openButton.isEnabled = selected != nil
    removeButton.isEnabled = selected != nil && selected != .default && selected != currentProfile
  }

  private func closeSheet() {
    guard let window else {
      return
    }
    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.close()
    }
  }
}
#endif
