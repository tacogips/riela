#if os(macOS)
import AppKit
import RielaAppSupport

@MainActor
enum ProfilePromptLayout {
  static let nameSize = NSSize(width: 360, height: 72)
}

@MainActor
struct ProfilePromptViewFactory {
  func accessoryStack(views: [NSView], size: NSSize) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .width
    stack.frame = NSRect(origin: .zero, size: size)
    stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width).isActive = true
    return stack
  }
}

@MainActor
final class ProfileSelectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  static let menuTitle = "Profiles..."

  private let tableView = NSTableView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let useProfileTitleLabel = NSTextField(labelWithString: "Use Profile")
  private let useProfileDetailLabel = NSTextField(labelWithString: "Show this profile's workflow instances.")
  private let removeProfileTitleLabel = NSTextField(labelWithString: "Remove Profile")
  private let removeProfileDetailLabel = NSTextField(
    labelWithString: "Remove this profile's sources, packages, and instance state. Other profiles are unchanged."
  )
  private weak var useProfileActionRow: RielaAppSelectableSettingsRow?
  private weak var removeProfileActionRow: RielaAppSelectableSettingsRow?
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
    window.title = "Profiles"
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
    tableView.rowHeight = 52
    tableView.intercellSpacing = NSSize(width: 0, height: 4)
    rielaAppConfigureSettingsTableSelection(tableView)

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    let removeProfileRow = profileActionRow(
      titleLabel: removeProfileTitleLabel,
      detailLabel: removeProfileDetailLabel,
      action: #selector(removeProfile)
    )
    let useProfileRow = profileActionRow(
      titleLabel: useProfileTitleLabel,
      detailLabel: useProfileDetailLabel,
      action: #selector(openSelectedProfile)
    )
    useProfileActionRow = useProfileRow
    removeProfileActionRow = removeProfileRow
    let actionRows = NSStackView(views: [
      useProfileRow,
      profileActionRow(
        title: "Add Profile",
        detail: "Create a separate profile for another instance set.",
        action: #selector(addProfile)
      ),
      removeProfileRow
    ])
    actionRows.orientation = .vertical
    actionRows.spacing = 8
    actionRows.alignment = .width

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle

    let stack = NSStackView(views: [scrollView, actionRows, statusLabel])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    let preferredHeight = scrollView.heightAnchor.constraint(equalToConstant: 220)
    preferredHeight.priority = .defaultLow

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      preferredHeight
    ])
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    profileNames.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = RielaAppTableSelectionCellView()
    let profileName = profileNames[row]
    cell.configureSelection(
      tableView: tableView,
      row: row,
      role: .radioButton,
      accessibilityLabel: profileName.rawValue,
      accessibilityValue: profileName == currentProfile ? "Current" : "Profile",
      accessibilityHelp: "Use \(profileName.rawValue) profile"
    )
    let title = NSTextField(labelWithString: profileName.rawValue)
    title.font = .systemFont(ofSize: 13, weight: profileName == currentProfile ? .semibold : .regular)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let detail = NSTextField(labelWithString: profileName == currentProfile ? "Current" : "Profile")
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let textStack = NSStackView(views: [title, detail])
    textStack.orientation = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let checkmarkImage = profileName == currentProfile
      ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
      : NSImage()
    let checkmark = NSImageView(image: checkmarkImage ?? NSImage())
    checkmark.contentTintColor = .controlAccentColor
    checkmark.imageScaling = .scaleProportionallyDown
    checkmark.widthAnchor.constraint(equalToConstant: 18).isActive = true
    checkmark.heightAnchor.constraint(equalToConstant: 14).isActive = true
    checkmark.setAccessibilityElement(false)

    let rowStack = RielaAppSettingsRow(views: [textStack, spacer, checkmark])
    rowStack.orientation = .horizontal
    rowStack.spacing = 10
    rowStack.alignment = .centerY
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    rielaAppSettingsRow(rowStack)
    cell.addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  private func profileActionRow(
    title: String,
    detail: String,
    action: Selector
  ) -> RielaAppSelectableSettingsRow {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let detailLabel = NSTextField(labelWithString: detail)
    return profileActionRow(titleLabel: titleLabel, detailLabel: detailLabel, action: action)
  }

  private func profileActionRow(
    titleLabel: NSTextField,
    detailLabel: NSTextField,
    action: Selector
  ) -> RielaAppSelectableSettingsRow {
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

    let row = RielaAppSelectableSettingsRow(views: [labelStack, spacer, rielaAppDisclosureIndicator()])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.toolTip = detailLabel.stringValue
    return rielaAppSelectableSettingsRow(
      row,
      target: self,
      action: action,
      accessibilityLabel: titleLabel.stringValue,
      accessibilityHelp: detailLabel.stringValue
    )
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateActionRows()
  }

  private func updateActionRows() {
    guard let selected = selectedProfile() else {
      useProfileTitleLabel.textColor = .disabledControlTextColor
      useProfileDetailLabel.textColor = .disabledControlTextColor
      useProfileActionRow?.setRielaAccessibilityEnabled(false)
      useProfileActionRow?.setAccessibilityHelp("Choose a profile first.")
      removeProfileTitleLabel.textColor = .disabledControlTextColor
      removeProfileDetailLabel.textColor = .disabledControlTextColor
      removeProfileActionRow?.setRielaAccessibilityEnabled(false)
      removeProfileActionRow?.setAccessibilityHelp("Choose a removable profile first.")
      return
    }
    let canUse = selected != currentProfile
    useProfileTitleLabel.textColor = canUse ? .labelColor : .disabledControlTextColor
    useProfileDetailLabel.textColor = canUse ? .secondaryLabelColor : .disabledControlTextColor
    useProfileActionRow?.setRielaAccessibilityEnabled(canUse)
    useProfileActionRow?.setAccessibilityHelp(canUse
      ? useProfileDetailLabel.stringValue
      : "This profile is already current.")
    let canRemove = selected != .default && selected != currentProfile
    removeProfileTitleLabel.textColor = canRemove ? .systemRed : .disabledControlTextColor
    removeProfileDetailLabel.textColor = canRemove ? .secondaryLabelColor : .disabledControlTextColor
    removeProfileActionRow?.setRielaAccessibilityEnabled(canRemove)
    removeProfileActionRow?.setAccessibilityHelp(canRemove
      ? removeProfileDetailLabel.stringValue
      : removeProfileUnavailableHelp(for: selected))
  }

  private func removeProfileUnavailableHelp(for selected: RielaAppProfileName) -> String {
    if selected == .default {
      return "Default profile cannot be removed here."
    }
    if selected == currentProfile {
      return "Current profile cannot be removed here."
    }
    return "Choose a removable profile first."
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
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let title = NSTextField(labelWithString: "Profile Name")
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let stack = ProfilePromptViewFactory().accessoryStack(
      views: [
        title,
        profileFieldRow(title: "Name", control: field)
      ],
      size: ProfilePromptLayout.nameSize
    )
    let alert = NSAlert()
    alert.messageText = "Profile Name"
    alert.informativeText = "Create a saved profile for another instance set."
    alert.accessoryView = stack
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return field.stringValue
  }

  private func profileFieldRow(title: String, control: NSView) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 90)
    let row = RielaAppSettingsRow(views: [titleLabel, control])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    return rielaAppSettingsRow(row)
  }

  private func confirmProfileRemoval(_ profileName: RielaAppProfileName) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Remove \(profileName.rawValue)?"
    alert.informativeText = [
      "This removes only this profile's workflow sources, packages, and instance state.",
      "Other profiles are unchanged."
    ].joined(separator: " ")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove Profile")
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
