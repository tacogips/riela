#if os(macOS)
import AppKit
import RielaViewer

extension WorkflowViewerWindowController {
  var detailScrollContentWidthFallback: CGFloat {
    360
  }

  func configurePopup(_ popup: NSPopUpButton, titles: [String]) {
    popup.removeAllItems()
    popup.addItems(withTitles: titles)
    popup.selectItem(at: 0)
  }

  func selectPopupValue(_ popup: NSPopUpButton, value: String?, values: [String]) {
    guard let value, let index = values.firstIndex(of: value) else {
      popup.selectItem(at: 0)
      return
    }
    popup.selectItem(at: index + 1)
  }

  func updateNodeOverrideRows(
    canEdit: Bool,
    modelCanEdit: Bool,
    reason: String,
    modelReason: String
  ) {
    updateWorkflowViewerControlRow(modelOverrideRow, isEnabled: modelCanEdit, help: modelReason)
    updateWorkflowViewerControlRow(backendOverrideRow, isEnabled: canEdit, help: reason)
    updateWorkflowViewerControlRow(effortOverrideRow, isEnabled: canEdit, help: reason)
    updateWorkflowViewerControlRow(nodePatchOverrideRow, isEnabled: canEdit, help: reason)
  }

  func updateWorkflowViewerControlRow(_ row: RielaAppSettingsRow?, isEnabled: Bool, help: String) {
    row?.alphaValue = isEnabled ? 1 : 0.55
    row?.setAccessibilityEnabled(isEnabled)
    row?.setAccessibilityHelp(help)
    row?.toolTip = help
  }

  func workflowViewerControlRow(title: String, views: [NSView]) -> RielaAppSettingsRow {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 120)
    for view in views {
      if let popup = view as? NSPopUpButton {
        popup.setAccessibilityLabel(title)
      }
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel] + views + [spacer])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel(title)
    rielaAppSettingsRow(row)
    return row
  }

  func setViewerMessage(_ message: String) {
    workflowSubtitleLabel.stringValue = message
  }

  func sessionSummary(state: WorkflowViewerState, session: WorkflowViewerSessionSummary?) -> String {
    let count = state.sessions.count
    let countSummary = count == 1 ? "1 session" : "\(count) sessions"
    guard let session else {
      return countSummary
    }
    return "\(countSummary) · \(session.status.rawValue.capitalized) \(session.sessionId)"
  }

  func iconButton(symbolName: String, accessibilityLabel: String, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: self, action: action)
    configureIconButton(button, symbolName: symbolName, accessibilityLabel: accessibilityLabel)
    return button
  }

  func configureIconButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    button.bezelStyle = .toolbar
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }

  func configureCompactPopup(_ popup: NSPopUpButton, maximumWidth: CGFloat) {
    popup.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth).isActive = true
    popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }
}
#endif
