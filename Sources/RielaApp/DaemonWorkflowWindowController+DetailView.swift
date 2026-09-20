#if os(macOS)
import AppKit
import RielaCore

extension DaemonWorkflowWindowController {
  func buildInstanceDetailView() -> NSView {
    let relinkRow = actionRow(
      title: "Relink Source",
      detail: "この実行設定で使うワークフローを選択します。",
      action: #selector(relinkSelectedSource)
    )
    let openWebUIRow = actionRow(
      title: "設定",
      detail: "作業フォルダ、環境変数、入力を設定します。",
      action: #selector(openSelectedInstanceInWebUI)
    )
    let startRow = actionRow(
      title: "Start",
      detail: "この実行設定で開始し、次回のアプリ起動時も自動で開始します。",
      action: #selector(startSelectedInstance)
    )
    let stopRow = actionRow(
      title: "Stop",
      detail: "設定を保存したまま停止します。",
      action: #selector(stopSelectedInstance)
    )
    let restartRow = actionRow(
      title: "Restart",
      detail: "この実行設定で再起動します。",
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
      title: "実行設定を削除",
      detail: "この実行設定を削除します。",
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
        title: "実行履歴",
        detail: "この実行設定の実行結果とログを表示します。",
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
      settingsSectionCaption("実行設定の管理"),
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
      labelWithString: "プロファイル \(row.profileName.rawValue) の実行設定を削除します。ワークフローは保持されます。"
    )
    scopeValue.lineBreakMode = .byWordWrapping
    scopeValue.maximumNumberOfLines = 3
    var messageRows = [
      settingRow(title: "Scope", valueLabel: scopeValue, action: nil)
    ]
    if row.state == .running || row.state == .starting || row.state == .reloading {
      let runningValue = NSTextField(labelWithString: "実行中の処理を停止します。")
      messageRows.append(settingRow(title: "Status", valueLabel: runningValue, action: nil))
    }
    let cancelRow = actionRow(
      title: "Cancel",
      detail: "実行設定に戻ります。",
      action: #selector(cancelRemoveSelectedInstance)
    )
    let removeRow = actionRow(
      title: "実行設定を削除",
      detail: "実行設定を削除します。ワークフローは保持されます。",
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
