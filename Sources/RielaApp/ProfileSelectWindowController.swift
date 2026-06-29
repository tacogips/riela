#if os(macOS)
import AppKit
import RielaAppSupport

@MainActor
final class ProfileSelectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  static let menuTitle = "Profile Select..."

  private let tableView = NSTableView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let removeProfileTitleLabel = NSTextField(labelWithString: "Remove Selected Profile")
  private let removeProfileDetailLabel = NSTextField(labelWithString: "Delete this profile's sources, packages, and instance state.")
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
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
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
    updateActionRows()
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
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.rowHeight = 44
    tableView.intercellSpacing = NSSize(width: 0, height: 4)
    tableView.gridStyleMask = []
    tableView.selectionHighlightStyle = .regular

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let actionRows = NSStackView(views: [
      profileActionRow(
        title: "Use Selected Profile",
        detail: "Switch the instance window to this profile.",
        action: #selector(openSelectedProfile)
      ),
      profileActionRow(
        title: "Add Profile",
        detail: "Create a separate profile for another instance set.",
        action: #selector(addProfile)
      ),
      profileActionRow(
        titleLabel: removeProfileTitleLabel,
        detailLabel: removeProfileDetailLabel,
        action: #selector(removeProfile)
      )
    ])
    actionRows.orientation = .vertical
    actionRows.spacing = 8
    actionRows.alignment = .leading

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle

    let stack = NSStackView(views: [scrollView, actionRows, statusLabel])
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
    let profileName = profileNames[row]
    let title = NSTextField(labelWithString: profileName.rawValue)
    title.font = .systemFont(ofSize: 13, weight: profileName == currentProfile ? .semibold : .regular)
    title.lineBreakMode = .byTruncatingTail

    let detail = NSTextField(labelWithString: profileName == currentProfile ? "Current" : "Available")
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor

    let textStack = NSStackView(views: [title, detail])
    textStack.orientation = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let checkmark = NSTextField(labelWithString: profileName == currentProfile ? "✓" : "")
    checkmark.textColor = .controlAccentColor
    checkmark.font = .systemFont(ofSize: 13, weight: .semibold)
    checkmark.widthAnchor.constraint(equalToConstant: 18).isActive = true

    let rowStack = NSStackView(views: [textStack, spacer, checkmark])
    rowStack.orientation = .horizontal
    rowStack.spacing = 10
    rowStack.alignment = .centerY
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  private func profileActionRow(
    title: String,
    detail: String,
    action: Selector
  ) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let detailLabel = NSTextField(labelWithString: detail)
    return profileActionRow(titleLabel: titleLabel, detailLabel: detailLabel, action: action)
  }

  private func profileActionRow(
    titleLabel: NSTextField,
    detailLabel: NSTextField,
    action: Selector
  ) -> NSStackView {
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail

    let labelStack = NSStackView(views: [titleLabel, detailLabel])
    labelStack.orientation = .vertical
    labelStack.spacing = 2
    labelStack.alignment = .leading
    labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [labelStack, spacer, rielaAppDisclosureIndicator()])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.wantsLayer = true
    row.toolTip = titleLabel.stringValue
    row.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
    row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
    return row
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateActionRows()
  }

  private func updateActionRows() {
    guard let selected = selectedProfile() else {
      removeProfileTitleLabel.textColor = .disabledControlTextColor
      removeProfileDetailLabel.textColor = .disabledControlTextColor
      return
    }
    let canRemove = selected != .default && selected != currentProfile
    removeProfileTitleLabel.textColor = canRemove ? .systemRed : .disabledControlTextColor
    removeProfileDetailLabel.textColor = canRemove ? .secondaryLabelColor : .disabledControlTextColor
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
