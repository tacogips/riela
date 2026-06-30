#if os(macOS)
import AppKit

@MainActor
class RielaAppSettingsRow: NSStackView {
  private(set) var isSettingsRowSelected = false

  var settingsRowBackgroundAlpha: CGFloat {
    if isSettingsRowSelected {
      return 0.58
    }
    return 0.35
  }

  func setSettingsRowSelected(_ selected: Bool) {
    guard isSettingsRowSelected != selected else {
      return
    }
    isSettingsRowSelected = selected
    updateSettingsRowBackground()
  }

  func applySettingsRowStyle() {
    edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
    wantsLayer = true
    layer?.cornerRadius = 8
    updateSettingsRowBackground()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSettingsRowBackground()
  }

  func updateSettingsRowBackground() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(settingsRowBackgroundAlpha).cgColor
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
    if isMouseDownInside {
      return 0.62
    }
    if isKeyboardFocused || isHovered {
      return 0.48
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
  private weak var tableViewReference: NSTableView?
  private weak var actionTarget: AnyObject?
  private var action: Selector?
  private var rowIndex = -1

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
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    updateSettingsRowSelection()
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
    setSettingsRowSelection(
      in: self,
      selected: tableViewReference.selectedRowIndexes.contains(rowIndex)
    )
  }

  private func setSettingsRowSelection(in view: NSView, selected: Bool) {
    if let row = view as? RielaAppSettingsRow {
      row.setSettingsRowSelected(selected)
    }
    for subview in view.subviews {
      setSettingsRowSelection(in: subview, selected: selected)
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
  row.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
  row.wantsLayer = true
  row.layer?.cornerRadius = 8
  row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
  return row
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
}

@MainActor
func rielaAppConfigureGroupedTextScroll(_ scroll: NSScrollView) {
  scroll.borderType = .noBorder
  scroll.drawsBackground = false
  scroll.wantsLayer = true
  scroll.layer?.cornerRadius = 8
  scroll.layer?.masksToBounds = true
}

#endif
