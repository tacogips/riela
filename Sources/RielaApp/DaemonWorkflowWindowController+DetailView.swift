#if os(macOS)
import AppKit

extension DaemonWorkflowWindowController {
  func buildInstanceDetailView() -> NSView {
    let settingsTitle = NSTextField(labelWithString: "Current Settings")
    settingsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let actionsTitle = NSTextField(labelWithString: "Manage Instance")
    actionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let settingsTitleRow = detailHeaderRow(label: settingsTitle)
    let actionsTitleRow = detailHeaderRow(label: actionsTitle)
    let relinkRow = actionRow(
      title: "Relink Source",
      detail: "Choose a workflow source for this saved instance.",
      action: #selector(relinkSelectedSource)
    )
    let openViewerRow = actionRow(
      title: "Open in Viewer",
      detail: "Inspect sessions, logs, and node structure for this instance.",
      action: #selector(openSelectedInstanceViewer)
    )
    let startRow = actionRow(
      title: "Start",
      detail: "Run this instance and include it in future app launches.",
      action: #selector(startSelectedInstance)
    )
    let stopRow = actionRow(
      title: "Stop",
      detail: "Stop this instance while keeping it visible.",
      action: #selector(stopSelectedInstance)
    )
    let restartRow = actionRow(
      title: "Restart",
      detail: "Stop and start this instance again.",
      action: #selector(restartSelectedInstance)
    )
    let workflowRow = settingRow(
      title: "Workflow",
      valueLabel: detailWorkflowValueLabel,
      action: #selector(revealSelectedSource)
    )
    detailMissingSourceValueLabel.lineBreakMode = .byTruncatingMiddle
    detailMissingSourceValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let missingSourceRow = settingRow(title: "Workflow", valueLabel: detailMissingSourceValueLabel, action: nil)
    let statusRow = settingRow(title: "Status", valueLabel: detailStatusValueLabel, action: nil)
    let nameRow = settingRow(title: "Name", valueLabel: detailNameValueLabel, action: #selector(renameSelectedWorkflow))
    let environmentRow = settingRow(
      title: ".env File",
      valueLabel: detailEnvironmentValueLabel,
      action: #selector(setSelectedEnvironment)
    )
    let inlineEnvironmentRow = settingRow(
      title: "Environment Variables",
      valueLabel: detailInlineEnvironmentValueLabel,
      action: #selector(setSelectedEnvironmentVariables)
    )
    let workingDirectoryRow = settingRow(
      title: "Working Directory",
      valueLabel: detailWorkingDirectoryValueLabel,
      action: #selector(setSelectedWorkingDirectory)
    )
    let variablesRow = settingRow(
      title: "Workflow Variables",
      valueLabel: detailVariablesValueLabel,
      action: #selector(setSelectedVariables)
    )
    let eventSourcesRow = settingRow(
      title: "Event Sources",
      valueLabel: detailEventSourcesValueLabel,
      action: #selector(setSelectedEventSources)
    )
    workflowSettingRow = workflowRow
    missingSourceSettingRow = missingSourceRow
    statusSettingRow = statusRow
    nameSettingRow = nameRow
    environmentSettingRow = environmentRow
    inlineEnvironmentSettingRow = inlineEnvironmentRow
    workingDirectorySettingRow = workingDirectoryRow
    variablesSettingRow = variablesRow
    eventSourcesSettingRow = eventSourcesRow
    relinkSourceActionRow = relinkRow
    openViewerActionRow = openViewerRow
    startInstanceActionRow = startRow
    stopInstanceActionRow = stopRow
    restartInstanceActionRow = restartRow
    let removeRow = actionRow(
      title: "Remove Instance",
      detail: "Delete only this instance.",
      style: .destructive,
      action: #selector(removeSelectedInstance)
    )
    let settingsSection = rielaAppSettingsSection(rows: [
      statusRow,
      workflowRow,
      missingSourceRow,
      nameRow,
      environmentRow,
      inlineEnvironmentRow,
      workingDirectoryRow,
      variablesRow,
      eventSourcesRow
    ])
    let actionsSection = rielaAppSettingsSection(rows: [
      openViewerRow,
      relinkRow,
      startRow,
      stopRow,
      restartRow,
      removeRow
    ])

    let stack = settingsDocumentStack(views: [
      workflowGraphPaneView,
      settingsTitleRow,
      settingsSection,
      actionsTitleRow,
      actionsSection
    ])
    return overviewPane(
      titleLabel: detailTitleLabel,
      summaryLabel: detailSummaryLabel,
      documentStack: stack
    )
  }

  func buildInstanceRemovalConfirmationView(_ row: ConfiguredWorkflowInstanceRow) -> NSView {
    let summaryLabel = NSTextField(labelWithString: "Confirm Removal")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    let scopeValue = NSTextField(
      labelWithString: "Removes only this instance from profile \(row.profileName.rawValue). The workflow source is not deleted."
    )
    scopeValue.lineBreakMode = .byWordWrapping
    scopeValue.maximumNumberOfLines = 3
    var messageRows = [
      settingRow(title: "Scope", valueLabel: scopeValue, action: nil)
    ]
    if row.state == .running || row.state == .starting || row.state == .reloading {
      let runningValue = NSTextField(labelWithString: "This instance is running and will be stopped.")
      messageRows.append(settingRow(title: "Status", valueLabel: runningValue, action: nil))
    }
    let cancelRow = actionRow(
      title: "Cancel",
      detail: "Return to this instance without removing it.",
      action: #selector(cancelRemoveSelectedInstance)
    )
    let removeRow = actionRow(
      title: "Remove Instance",
      detail: "Remove this instance. The workflow source is unchanged.",
      style: .destructive,
      action: #selector(confirmRemoveSelectedInstance)
    )
    let stack = settingsDocumentStack(views: [
      rielaAppSettingsSection(rows: messageRows),
      rielaAppSettingsSection(rows: [cancelRow, removeRow])
    ])
    return overviewPane(title: row.instanceName, summaryLabel: summaryLabel, documentStack: stack)
  }

  private func detailHeaderRow(label: NSTextField) -> NSStackView {
    label.alignment = .left
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [label, spacer])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 8
    row.setContentHuggingPriority(.required, for: .vertical)
    return row
  }
}
#endif
