#if os(macOS)
import AppKit
import RielaCore

extension DaemonWorkflowWindowController {
  func buildInstanceDetailView() -> NSView {
    let relinkRow = actionRow(
      title: "Relink Source",
      detail: "Choose the workflow this run configuration uses.",
      action: #selector(relinkSelectedSource)
    )
    let openWebUIRow = actionRow(
      title: "Settings",
      detail: "Set the working folder, environment variables, and input.",
      action: #selector(openSelectedInstanceInWebUI)
    )
    let startRow = actionRow(
      title: "Start",
      detail: "Start with this run configuration and start it again automatically on the next app launch.",
      action: #selector(startSelectedInstance)
    )
    let stopRow = actionRow(
      title: "Stop",
      detail: "Stop while keeping the saved settings.",
      action: #selector(stopSelectedInstance)
    )
    let restartRow = actionRow(
      title: "Restart",
      detail: "Restart with this run configuration.",
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
    let statusRow = makeStatusSettingRow()
    let nameRow = settingRow(title: "Name", valueLabel: detailNameValueLabel, action: #selector(renameSelectedWorkflow))
    let environmentRow = settingRow(title: ".env File", valueLabel: detailEnvironmentValueLabel, action: nil)
    let inlineEnvironmentRow = settingRow(
      title: "Environment Variables",
      valueLabel: detailInlineEnvironmentValueLabel,
      action: nil
    )
    let workingDirectoryRow = settingRow(
      title: "Working Directory",
      valueLabel: detailWorkingDirectoryValueLabel,
      action: nil
    )
    let variablesRow = settingRow(
      title: "Workflow Variables",
      valueLabel: detailVariablesValueLabel,
      action: nil
    )
    let eventSourcesRow = settingRow(
      title: "Event Sources",
      valueLabel: detailEventSourcesValueLabel,
      action: nil
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
    openWebUIActionRow = openWebUIRow
    startInstanceActionRow = startRow
    stopInstanceActionRow = stopRow
    restartInstanceActionRow = restartRow
    let removeRow = actionRow(
      title: "Remove run configuration",
      detail: "Remove this run configuration.",
      style: .destructive,
      action: #selector(removeSelectedInstance)
    )
    removeInstanceActionRow = removeRow
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
      openWebUIRow,
      actionRow(
        title: "Run history",
        detail: "Show the results and logs of this run configuration.",
        action: #selector(openSelectedConfigurationHistory)
      ),
      relinkRow,
      startRow,
      stopRow,
      restartRow,
      removeRow
    ])
    let kaibaBindingViews = buildKaibaNodeBindingViews()

    let stack = settingsDocumentStack(views: [
      workflowGraphPaneView,
      settingsSectionCaption("Current Settings"),
      settingsSection
    ] + kaibaBindingViews + [
      settingsSectionCaption("Manage run configuration"),
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
      labelWithString: "Remove this run configuration from profile \(row.profileName.rawValue). The workflow is kept."
    )
    scopeValue.lineBreakMode = .byWordWrapping
    scopeValue.maximumNumberOfLines = 3
    var messageRows = [
      settingRow(title: "Scope", valueLabel: scopeValue, action: nil)
    ]
    if row.state == .running || row.state == .starting || row.state == .reloading {
      let runningValue = NSTextField(labelWithString: "Running work will be stopped.")
      messageRows.append(settingRow(title: "Status", valueLabel: runningValue, action: nil))
    }
    let cancelRow = actionRow(
      title: "Cancel",
      detail: "Return to the run configuration.",
      action: #selector(cancelRemoveSelectedInstance)
    )
    let removeRow = actionRow(
      title: "Remove run configuration",
      detail: "Remove the run configuration. The workflow is kept.",
      style: .destructive,
      action: #selector(confirmRemoveSelectedInstance)
    )
    let stack = settingsDocumentStack(views: [
      rielaAppSettingsSection(rows: messageRows),
      rielaAppSettingsSection(rows: [cancelRow, removeRow])
    ])
    return overviewPane(title: row.instanceName, summaryLabel: summaryLabel, documentStack: stack)
  }

  private func makeStatusSettingRow() -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel("Status", maxWidth: 130)
    detailStatusValueLabel.textColor = .labelColor
    detailStatusValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [
      titleLabel,
      detailStatusProgressIndicator,
      detailStatusValueLabel,
      spacer
    ])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel("Status")
    row.setAccessibilityValue(detailStatusValueLabel.stringValue)
    return rielaAppSettingsRow(row)
  }
}
#endif
