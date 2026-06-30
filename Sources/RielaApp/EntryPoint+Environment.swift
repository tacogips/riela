#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

extension RielaApp {
  func setDaemonWorkflowWorkingDirectory(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let existingPath = daemonState.preference(for: identity).workingDirectory
    switch workingDirectoryAction(candidate: candidate, existingPath: existingPath) {
    case .choose:
      chooseWorkingDirectory(for: candidate)
    case .clear:
      clearWorkingDirectory(for: candidate)
    case .cancel:
      return
    }
  }

  func setDaemonWorkflowEnvironment(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let existingPath = daemonState.preference(for: identity).environmentFilePath
    let action = environmentFileAction(candidate: candidate, existingPath: existingPath)
    switch action {
    case .choose:
      chooseEnvironmentFile(for: candidate)
    case .clear:
      clearEnvironmentFile(for: candidate)
    case .cancel:
      return
    }
  }

  func daemonEnvironmentSummary(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let summary = daemonEnvironmentStatus(for: candidate)
    let prefix = summary.fileDisplayName.map { ".env file \($0)" } ?? "no .env file"
    let inline = summary.inlineCount == 0 ? "no environment variables" : "\(summary.inlineCount) environment variables"
    guard !candidate.requiredEnvironment.isEmpty else {
      return "\(prefix), \(inline), no required environment variables"
    }
    if summary.missingNames.isEmpty {
      return "\(prefix), \(inline), all required environment variables set"
    }
    return "\(prefix), \(inline), missing required \(summary.missingNames.joined(separator: ", "))"
  }

  func daemonEnvironmentColumnStatus(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let summary = daemonEnvironmentStatus(for: candidate)
    guard !candidate.requiredEnvironment.isEmpty else {
      return summary.fileDisplayName == nil ? "No req" : "File"
    }
    return summary.missingNames.isEmpty ? "Ready" : "Missing \(summary.missingNames.count)"
  }

  func daemonEnvironment(for candidate: RielaAppDaemonWorkflowCandidate) -> [String: String] {
    var environment = daemonEnvironmentStore(for: candidate).mergedEnvironment()
    for (name, value) in daemonState.preference(for: candidate.id).environmentVariables {
      environment[name] = value
    }
    return environment
  }

  func daemonConfiguredEnvironmentValues(
    for candidate: RielaAppDaemonWorkflowCandidate
  ) -> [RielaAppConfiguredEnvironmentValue] {
    let preference = daemonState.preference(for: candidate.id)
    let fileValues = preference.environmentFilePath
      .map { RielaAppEnvironmentFileStore.parseEnvironmentFile(URL(fileURLWithPath: $0)) } ?? [:]
    let inlineValues = preference.environmentVariables
    let names = Set(fileValues.keys).union(inlineValues.keys)
    return names.map { name in
      if let inlineValue = inlineValues[name] {
        let source = fileValues[name] == nil ? "inline" : "inline override"
        return RielaAppConfiguredEnvironmentValue(
          name: name,
          value: inlineValue,
          source: source
        )
      }
      return RielaAppConfiguredEnvironmentValue(
        name: name,
        value: fileValues[name] ?? "",
        source: ".env"
      )
    }
  }

  func daemonRuntimeConfiguration(
    for candidate: RielaAppDaemonWorkflowCandidate
  ) -> WorkflowServeRuntimeConfiguration {
    var configuration = daemonState.preference(for: candidate.id).configuration.serveConfiguration(
      inheritedEnvironment: daemonEnvironment(for: candidate)
    )
    if configuration.workingDirectory == nil {
      configuration.workingDirectory = candidate.workingDirectory
    }
    return configuration
  }

  private enum EnvironmentFileAction {
    case choose
    case clear
    case cancel
  }

  private enum WorkingDirectoryAction {
    case choose
    case clear
    case cancel
  }

  private struct EnvironmentStatusSummary {
    var fileDisplayName: String?
    var inlineCount: Int
    var missingNames: [String]
  }

  private func environmentFileAction(
    candidate: RielaAppDaemonWorkflowCandidate,
    existingPath: String?
  ) -> EnvironmentFileAction {
    guard existingPath?.isEmpty == false else {
      return .choose
    }
    let action = RielaAppSettingsEditorWindowController.chooseAction(
      title: ".env File",
      message: "Choose or clear the .env file for \(candidate.displayName).",
      currentTitle: "Current .env File",
      currentValue: existingPath ?? "-",
      actions: [
        ("Choose File", "Choose a different .env file for this instance."),
        ("Clear .env File", "Use Environment Variables and inherited process environment only.")
      ]
    )
    switch action {
    case 0:
      return .choose
    case 1:
      return .clear
    case nil, _:
      return .cancel
    }
  }

  private func workingDirectoryAction(
    candidate: RielaAppDaemonWorkflowCandidate,
    existingPath: String?
  ) -> WorkingDirectoryAction {
    guard existingPath?.isEmpty == false else {
      return .choose
    }
    let action = RielaAppSettingsEditorWindowController.chooseAction(
      title: "Working Directory",
      message: "Choose or clear the working directory for \(candidate.displayName).",
      currentTitle: "Current Directory",
      currentValue: existingPath ?? "-",
      actions: [
        ("Choose Directory", "Choose the directory used when this instance runs."),
        ("Clear Directory Override", "Use the workflow source's natural working directory.")
      ]
    )
    switch action {
    case 0:
      return .choose
    case 1:
      return .clear
    case nil, _:
      return .cancel
    }
  }

  private func chooseWorkingDirectory(for candidate: RielaAppDaemonWorkflowCandidate) {
    let panel = NSOpenPanel()
    panel.title = "Choose Working Directory"
    panel.message = "Choose the directory used when \(candidate.displayName) runs."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.workingDirectory = url.standardizedFileURL.path
    }) else {
      return
    }
    status = "Set working directory for \(candidate.displayName): \(url.standardizedFileURL.path)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "working directory"
    )
  }

  private func clearWorkingDirectory(for candidate: RielaAppDaemonWorkflowCandidate) {
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.workingDirectory = nil
    }) else {
      return
    }
    status = "Cleared working directory for \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "working directory"
    )
  }

  private func chooseEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    let panel = NSOpenPanel()
    panel.title = "Choose .env File"
    panel.message = "Choose the .env file passed to \(candidate.displayName)."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard isSupportedEnvironmentFile(url) else {
      status = "Choose a .env file for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      return
    }
    guard confirmCredentialEnvironmentFile(url, candidate: candidate) else {
      return
    }
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.environmentFilePath = url.standardizedFileURL.path
    }) else {
      return
    }
    status = "Set .env file for \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: ".env file"
    )
  }

  private func clearEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.environmentFilePath = nil
    }) else {
      return
    }
    status = "Cleared .env file for \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: ".env file"
    )
  }

  private func confirmCredentialEnvironmentFile(_ url: URL, candidate: RielaAppDaemonWorkflowCandidate) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Use .env File?"
    alert.informativeText = [
      "\(url.lastPathComponent) may contain credentials.",
      "Values stay hidden in the app and are passed to \(candidate.displayName) and its event source process."
    ].joined(separator: " ")
    alert.addButton(withTitle: "Use .env File")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func daemonEnvironmentStatus(for candidate: RielaAppDaemonWorkflowCandidate) -> EnvironmentStatusSummary {
    let preference = daemonState.preference(for: candidate.id)
    let environment = daemonEnvironment(for: candidate)
    let missingNames = candidate.requiredEnvironment.map(\.name).filter { name in
      environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
    return EnvironmentStatusSummary(
      fileDisplayName: preference.environmentFilePath.map { URL(fileURLWithPath: $0).lastPathComponent },
      inlineCount: preference.environmentVariables.count,
      missingNames: missingNames
    )
  }

  private func daemonEnvironmentStore(for candidate: RielaAppDaemonWorkflowCandidate) -> RielaAppEnvironmentFileStore {
    let path = daemonState.preference(for: candidate.id).environmentFilePath
    let url = path.map { URL(fileURLWithPath: $0) }
    return RielaAppEnvironmentFileStore(environmentFileURL: url)
  }

  private func isSupportedEnvironmentFile(_ url: URL) -> Bool {
    url.lastPathComponent == ".env" || url.pathExtension == "env"
  }
}
#endif
