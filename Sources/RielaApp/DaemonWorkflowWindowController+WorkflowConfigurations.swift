#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  enum ConfigurationPage: String {
    case settings
    case history
  }

  func workflowConfigurationRows(for source: RielaAppDaemonWorkflowCandidate) -> [ConfiguredWorkflowInstanceRow] {
    instanceRows.filter { $0.sourceIdentity == source.id && $0.profileName == profileName }
      .sorted { lhs, rhs in
        let leftDefault = lhs.localIdentity == source.id
        let rightDefault = rhs.localIdentity == source.id
        if leftDefault != rightDefault { return leftDefault }
        return lhs.instanceName.localizedStandardCompare(rhs.instanceName) == .orderedAscending
      }
  }

  func workflowConfigurationsSection(_ source: RielaAppDaemonWorkflowCandidate) -> RielaAppSettingsSectionView {
    rielaAppSettingsSection(rows: workflowConfigurationRows(for: source).map { configuration in
      let row = actionRow(
        title: configuration.instanceName,
        detail: configuration.state.rawValue,
        action: #selector(openWorkflowConfiguration(_:))
      )
      row.identifier = NSUserInterfaceItemIdentifier(configuration.id)
      return row
    })
  }

  func workflowConfigurationActionsSection() -> RielaAppSettingsSectionView {
    rielaAppSettingsSection(rows: [
      actionRow(
        title: "実行設定を追加",
        detail: "別の作業フォルダや入力で使う設定に名前を付けて保存します。",
        action: #selector(addWorkflowConfiguration)
      )
    ])
  }

  @objc func openWorkflowConfiguration(_ sender: Any) {
    guard let view = sender as? NSView, let identity = view.identifier?.rawValue else { return }
    selectCandidate(identity: identity)
    showInstanceDetail()
  }

  @objc func addWorkflowConfiguration() {
    guard let option = workflowSourceOptions().first(where: { $0.candidate.id == selectedWorkflowSourceId }),
          let request = promptForInstanceParameters(sourceOption: option) else { return }
    onAddInstance(request)
    showWorkflowSourceDetail()
  }

  @objc func openSelectedConfigurationHistory() {
    guard let row = selectedRow(), row.state != .needsSource else { return }
    openConfigurationPage(row, page: .history)
  }

  func openConfigurationPage(_ row: ConfiguredWorkflowInstanceRow, page: ConfigurationPage) {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let source = row.sourceIdentity.addingPercentEncoding(withAllowedCharacters: allowed),
          let identity = row.localIdentity.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
    onOpenWebUI("#/workflows/\(source)/configurations/\(identity)/\(page.rawValue)")
  }

  func returnToWorkflow() {
    if workflowSources.contains(where: { $0.id == selectedWorkflowSourceId }) {
      showWorkflowSourceDetail()
    } else {
      showSourcesPane()
    }
  }
}
#endif
