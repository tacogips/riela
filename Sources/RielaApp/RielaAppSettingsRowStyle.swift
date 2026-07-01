#if os(macOS)
import AppKit

@MainActor
class RielaAppSettingsRow: NSStackView {
  private(set) var isSettingsRowSelected = false
  private(set) var isGroupedSettingsRow = false

  var settingsRowBackgroundAlpha: CGFloat {
    if isGroupedSettingsRow {
      return isSettingsRowSelected ? 0.1 : 0
    }
    if isSettingsRowSelected {
      return 0.62
    }
    return 0.42
  }

  func setSettingsRowSelected(_ selected: Bool) {
    guard isSettingsRowSelected != selected else {
      return
    }
    isSettingsRowSelected = selected
    updateSettingsRowBackground()
  }

  func applySettingsRowStyle() {
    isGroupedSettingsRow = false
    edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
    wantsLayer = true
    layer?.cornerRadius = 12
    updateSettingsRowBackground()
  }

  func applyGroupedSettingsRowStyle() {
    isGroupedSettingsRow = true
    edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    wantsLayer = true
    layer?.cornerRadius = 0
    updateSettingsRowBackground()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSettingsRowBackground()
  }

  func updateSettingsRowBackground() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = settingsRowBackgroundAlpha > 0
        ? NSColor.controlBackgroundColor.withAlphaComponent(settingsRowBackgroundAlpha).cgColor
        : NSColor.clear.cgColor
    }
  }
}

@MainActor
final class RielaAppSelectableSettingsRow: RielaAppSettingsRow {
  private weak var actionTarget: AnyObject?
  private var action: Selector?
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isMouseDownInside = false
  private var isKeyboardFocused = false
  private(set) var rielaAccessibilityEnabled = true

  override var settingsRowBackgroundAlpha: CGFloat {
    if isGroupedSettingsRow {
      if isMouseDownInside {
        return 0.16
      }
      if isKeyboardFocused || isHovered {
        return 0.08
      }
      return super.settingsRowBackgroundAlpha
    }
    if isMouseDownInside {
      return 0.68
    }
    if isKeyboardFocused || isHovered {
      return 0.54
    }
    return super.settingsRowBackgroundAlpha
  }

  override var acceptsFirstResponder: Bool {
    rielaAccessibilityEnabled
  }

  func configureAction(target: AnyObject, action: Selector) {
    actionTarget = target
    self.action = action
  }

  func setRielaAccessibilityEnabled(_ enabled: Bool) {
    rielaAccessibilityEnabled = enabled
    setAccessibilityEnabled(enabled)
    alphaValue = enabled ? 1 : 0.55
    if !enabled {
      isHovered = false
      isMouseDownInside = false
      isKeyboardFocused = false
    }
    updateSettingsRowBackground()
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    guard rielaAccessibilityEnabled else {
      return
    }
    isHovered = true
    updateSettingsRowBackground()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    isMouseDownInside = false
    updateSettingsRowBackground()
  }

  override func mouseDown(with event: NSEvent) {
    guard rielaAccessibilityEnabled else {
      return
    }
    isMouseDownInside = true
    window?.makeFirstResponder(self)
    updateSettingsRowBackground()
  }

  override func mouseUp(with event: NSEvent) {
    guard rielaAccessibilityEnabled else {
      return
    }
    defer {
      isMouseDownInside = false
      updateSettingsRowBackground()
    }
    let location = convert(event.locationInWindow, from: nil)
    guard isMouseDownInside, bounds.contains(location) else {
      return
    }
    performRowAction()
  }

  override func keyDown(with event: NSEvent) {
    guard rielaAccessibilityEnabled else {
      return
    }
    switch event.charactersIgnoringModifiers {
    case " ", "\r", "\n":
      performRowAction()
    default:
      super.keyDown(with: event)
    }
  }

  override func becomeFirstResponder() -> Bool {
    isKeyboardFocused = true
    updateSettingsRowBackground()
    return true
  }

  override func resignFirstResponder() -> Bool {
    isKeyboardFocused = false
    updateSettingsRowBackground()
    return true
  }

  override func accessibilityPerformPress() -> Bool {
    performRowAction()
  }

  @discardableResult
  private func performRowAction() -> Bool {
    guard rielaAccessibilityEnabled else {
      return false
    }
    guard let actionTarget, let action else {
      return false
    }
    return NSApp.sendAction(action, to: actionTarget, from: self)
  }
}

@MainActor
final class RielaAppTableSelectionCellView: NSTableCellView {
  private enum GroupedListLayout {
    static let separatorHeight: CGFloat = 1
    static let selectedAlpha: CGFloat = 0
  }

  private weak var tableViewReference: NSTableView?
  private weak var actionTarget: AnyObject?
  private var action: Selector?
  private var rowIndex = -1
  private let groupedSeparator = NSView()
  private var isGroupedListCell = false
  private var groupedSeparatorLeadingInset: CGFloat = 0

  func configureSelection(
    tableView: NSTableView,
    row: Int,
    role: NSAccessibility.Role,
    accessibilityLabel: String,
    accessibilityValue: String? = nil,
    accessibilityHelp: String? = nil,
    actionTarget: AnyObject? = nil,
    action: Selector? = nil
  ) {
    tableViewReference = tableView
    rowIndex = row
    self.actionTarget = actionTarget
    self.action = action
    setAccessibilityElement(true)
    setAccessibilityRole(role)
    setAccessibilityLabel(accessibilityLabel)
    if let accessibilityValue {
      setAccessibilityValue(accessibilityValue)
    }
    if let accessibilityHelp {
      setAccessibilityHelp(accessibilityHelp)
    }
    updateGroupedListAppearance()
  }

  func configureGroupedListStyle(separatorLeadingInset: CGFloat, showsSeparator: Bool) {
    isGroupedListCell = true
    groupedSeparatorLeadingInset = separatorLeadingInset
    wantsLayer = true
    layer?.cornerRadius = 0
    layer?.masksToBounds = false
    if groupedSeparator.superview == nil {
      groupedSeparator.wantsLayer = true
      addSubview(groupedSeparator)
    }
    groupedSeparator.isHidden = !showsSeparator
    updateGroupedListAppearance()
    needsLayout = true
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    updateSettingsRowSelection()
  }

  override func layout() {
    super.layout()
    guard isGroupedListCell else {
      return
    }
    groupedSeparator.frame = NSRect(
      x: groupedSeparatorLeadingInset,
      y: 0,
      width: max(0, bounds.width - groupedSeparatorLeadingInset - 12),
      height: GroupedListLayout.separatorHeight
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateGroupedListAppearance()
    needsDisplay = true
  }

  override func addSubview(_ view: NSView) {
    super.addSubview(view)
    updateSettingsRowSelection()
  }

  override func accessibilityPerformPress() -> Bool {
    guard let tableViewReference, rowIndex >= 0 else {
      return false
    }
    tableViewReference.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    tableViewReference.scrollRowToVisible(rowIndex)
    tableViewReference.needsDisplay = true
    updateSettingsRowSelection()
    guard let actionTarget, let action else {
      return true
    }
    return NSApp.sendAction(action, to: actionTarget, from: tableViewReference)
  }

  private func updateSettingsRowSelection() {
    guard let tableViewReference, rowIndex >= 0 else {
      return
    }
    let selected = tableViewReference.selectedRowIndexes.contains(rowIndex)
    setSettingsRowSelection(in: self, selected: selected)
    updateGroupedListAppearance(selected: selected)
  }

  private func setSettingsRowSelection(in view: NSView, selected: Bool) {
    if let row = view as? RielaAppSettingsRow {
      row.setSettingsRowSelected(selected)
    }
    for subview in view.subviews {
      setSettingsRowSelection(in: subview, selected: selected)
    }
  }

  private func updateGroupedListAppearance(selected explicitSelection: Bool? = nil) {
    guard isGroupedListCell else {
      return
    }
    let selected = explicitSelection ?? tableViewReference?.selectedRowIndexes.contains(rowIndex) ?? false
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = selected
        ? NSColor.selectedContentBackgroundColor.withAlphaComponent(GroupedListLayout.selectedAlpha).cgColor
        : NSColor.clear.cgColor
      groupedSeparator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
    needsDisplay = true
  }
}

@MainActor
final class RielaAppSymbolTileView: NSView {
  private enum Layout {
    static let tileSize: CGFloat = 32
    static let imageSize: CGFloat = 18
  }

  private let imageView: NSImageView
  private let backgroundColor: NSColor

  init(symbolName: String, backgroundColor: NSColor, symbolColor: NSColor = .white) {
    self.imageView = NSImageView(
      image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
    )
    self.backgroundColor = backgroundColor
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    imageView.contentTintColor = symbolColor
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setAccessibilityElement(false)
    addSubview(imageView)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Layout.tileSize),
      heightAnchor.constraint(equalToConstant: Layout.tileSize),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: Layout.imageSize),
      imageView.heightAnchor.constraint(equalToConstant: Layout.imageSize)
    ])
    updateBackgroundColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = backgroundColor.cgColor
    }
  }
}

@MainActor
final class RielaAppSettingsSectionView: NSStackView {
  private enum Layout {
    static let cornerRadius: CGFloat = 12
    static let separatorHeight: CGFloat = 1
    static let rowMinimumHeight: CGFloat = 62
  }

  private let rowViews: [NSView]
  private var separatorViews: [NSView] = []

  init(rows: [NSView]) {
    self.rowViews = rows
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .width
    spacing = 0
    wantsLayer = true
    layer?.cornerRadius = Layout.cornerRadius
    layer?.masksToBounds = true
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for (index, row) in rows.enumerated() {
      applyGroupedRowStyle(to: row)
      let rowHeight = row.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.rowMinimumHeight)
      rowHeight.priority = .defaultHigh
      rowHeight.isActive = true
      addArrangedSubview(row)
      guard index < rows.count - 1 else {
        continue
      }
      let separator = separatorView()
      separatorViews.append(separator)
      addArrangedSubview(separator)
    }
    updateBackgroundColor()
    updateSeparatorColors()
    updateSeparatorVisibility()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    updateSeparatorVisibility()
    super.layout()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
    updateSeparatorColors()
  }

  var preferredGroupedListHeight: CGFloat {
    let visibleRowCount = rowViews.filter { !$0.isHidden }.count
    let separatorCount = max(0, visibleRowCount - 1)
    return (CGFloat(visibleRowCount) * Layout.rowMinimumHeight)
      + (CGFloat(separatorCount) * Layout.separatorHeight)
  }

  private func applyGroupedRowStyle(to row: NSView) {
    if let settingsRow = row as? RielaAppSettingsRow {
      settingsRow.applyGroupedSettingsRowStyle()
    }
  }

  private func separatorView() -> NSView {
    let separator = NSView()
    separator.wantsLayer = true
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.heightAnchor.constraint(equalToConstant: Layout.separatorHeight).isActive = true
    return separator
  }

  private func updateSeparatorVisibility() {
    for (index, separator) in separatorViews.enumerated() {
      let hasPreviousVisibleRow = !rowViews[index].isHidden
      let hasFollowingVisibleRow = rowViews[(index + 1)...].contains { !$0.isHidden }
      separator.isHidden = !(hasPreviousVisibleRow && hasFollowingVisibleRow)
    }
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let surfaceColor = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor)
        ?? NSColor.controlBackgroundColor
      layer?.backgroundColor = surfaceColor.cgColor
    }
  }

  private func updateSeparatorColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for separator in separatorViews {
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
      }
    }
  }
}

@discardableResult
@MainActor
func rielaAppSettingsRow(_ row: NSStackView) -> NSStackView {
  if let settingsRow = row as? RielaAppSettingsRow {
    settingsRow.applySettingsRowStyle()
    return settingsRow
  }
  row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
  row.wantsLayer = true
  row.layer?.cornerRadius = 12
  row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
  return row
}

@MainActor
func rielaAppSettingsSection(rows: [NSView]) -> RielaAppSettingsSectionView {
  RielaAppSettingsSectionView(rows: rows)
}

@discardableResult
@MainActor
func rielaAppSelectableSettingsRow(
  _ row: RielaAppSelectableSettingsRow,
  target: AnyObject,
  action: Selector,
  accessibilityLabel: String,
  accessibilityHelp: String? = nil
) -> RielaAppSelectableSettingsRow {
  rielaAppSettingsRow(row)
  row.configureAction(target: target, action: action)
  row.setAccessibilityElement(true)
  row.setAccessibilityRole(.button)
  row.setAccessibilityLabel(accessibilityLabel)
  if let accessibilityHelp {
    row.setAccessibilityHelp(accessibilityHelp)
  }
  return row
}

@MainActor
func rielaAppSettingsTitleLabel(_ title: String, maxWidth: CGFloat) -> NSTextField {
  let label = NSTextField(labelWithString: title)
  label.textColor = .secondaryLabelColor
  label.lineBreakMode = .byTruncatingTail
  label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
  return label
}

func rielaAppMetadataText(_ parts: [String]) -> String {
  parts
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: ", ")
}

@MainActor
func rielaAppConfigureSettingsTableSelection(_ tableView: NSTableView) {
  tableView.usesAlternatingRowBackgroundColors = false
  tableView.gridStyleMask = []
  tableView.selectionHighlightStyle = .none
  tableView.backgroundColor = .clear
}

@MainActor
func rielaAppConfigureGroupedTextScroll(_ scroll: NSScrollView) {
  scroll.borderType = .noBorder
  scroll.drawsBackground = false
  scroll.wantsLayer = true
  scroll.layer?.cornerRadius = 12
  scroll.layer?.masksToBounds = true
}

@MainActor
func rielaAppConfigureGroupedListScroll(_ scroll: NSScrollView, cornerRadius: CGFloat = 14) {
  scroll.borderType = .noBorder
  scroll.drawsBackground = false
  scroll.backgroundColor = .clear
  scroll.contentView.drawsBackground = false
  scroll.wantsLayer = true
  scroll.layer?.cornerRadius = cornerRadius
  scroll.layer?.masksToBounds = true
  scroll.effectiveAppearance.performAsCurrentDrawingAppearance {
    let surfaceColor = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor)
      ?? NSColor.controlBackgroundColor
    scroll.layer?.backgroundColor = surfaceColor.cgColor
  }
}

#endif
