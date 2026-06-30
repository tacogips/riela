#if os(macOS)
import AppKit

extension DaemonWorkflowWindowController {
  func buildInstanceDetailView() -> NSView {
    let topSpacer = NSView()
    topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    topSpacer.setContentHuggingPriority(.required, for: .vertical)
    let topRow = NSStackView(views: [backToInstancesButton, topSpacer])
    topRow.orientation = .horizontal
    topRow.spacing = 8
    topRow.alignment = .centerY
    topRow.setContentHuggingPriority(.required, for: .vertical)
    topRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
    let settingsTitle = NSTextField(labelWithString: "Current Settings")
    settingsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let actionsTitle = NSTextField(labelWithString: "Manage Instance")
    actionsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let detailTitleRow = detailHeaderRow(label: detailTitleLabel)
    let settingsTitleRow = detailHeaderRow(label: settingsTitle)
    let actionsTitleRow = detailHeaderRow(label: actionsTitle)
    let relinkRow = actionRow(
      title: "Relink Source",
      detail: "Choose a workflow source for this saved instance.",
      action: #selector(relinkSelectedSource)
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
    nameSettingRow = nameRow
    environmentSettingRow = environmentRow
    inlineEnvironmentSettingRow = inlineEnvironmentRow
    workingDirectorySettingRow = workingDirectoryRow
    variablesSettingRow = variablesRow
    eventSourcesSettingRow = eventSourcesRow
    relinkSourceActionRow = relinkRow
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
      relinkRow,
      startRow,
      stopRow,
      restartRow,
      removeRow
    ])

    let stack = NSStackView(views: [
      topRow,
      detailTitleRow,
      settingsTitleRow,
      settingsSection,
      actionsTitleRow,
      actionsSection
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 10
    stack.setContentHuggingPriority(.required, for: .vertical)
    stack.translatesAutoresizingMaskIntoConstraints = false
    topRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
    topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
    ])

    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
    return scroll
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
