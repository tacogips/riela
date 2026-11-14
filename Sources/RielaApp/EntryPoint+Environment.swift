#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

extension RielaApp {
  func setDaemonWorkflowWorkingDirectory(identity: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    switch workingDirectoryAction(candidate: resolved.candidate, existingPath: resolved.preference.workingDirectory) {
    case .choose:
      chooseWorkingDirectory(for: resolved, rawIdentity: identity)
    case .clear:
      clearWorkingDirectory(for: resolved, rawIdentity: identity)
    case .cancel:
      return
    }
  }

  func setDaemonWorkflowEnvironment(identity: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let action = environmentFileAction(candidate: resolved.candidate, existingPath: resolved.preference.environmentFilePath)
    switch action {
    case .choose:
      chooseEnvironmentFile(for: resolved, rawIdentity: identity)
    case .clear:
      clearEnvironmentFile(for: resolved, rawIdentity: identity)
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
    daemonEnvironment(for: candidate, preference: daemonPreference(for: candidate))
  }

  func daemonEnvironment(
    for candidate: RielaAppDaemonWorkflowCandidate,
    preference: RielaAppDaemonWorkflowPreference
  ) -> [String: String] {
    var environment = daemonEnvironmentStore(preference: preference).mergedEnvironment()
    for (name, value) in preference.environmentVariables {
      environment[name] = value
    }
    return environment
  }

  func daemonConfiguredEnvironmentValues(
    for candidate: RielaAppDaemonWorkflowCandidate
  ) -> [RielaAppConfiguredEnvironmentValue] {
    let preference = daemonPreference(for: candidate)
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
    daemonRuntimeConfiguration(for: candidate, preference: daemonPreference(for: candidate))
  }

  func daemonRuntimeConfiguration(
    for candidate: RielaAppDaemonWorkflowCandidate,
    preference: RielaAppDaemonWorkflowPreference
  ) -> WorkflowServeRuntimeConfiguration {
    var configuration = preference.configuration.serveConfiguration(
      inheritedEnvironment: daemonEnvironment(for: candidate, preference: preference)
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

  private func chooseWorkingDirectory(for resolved: ResolvedDaemonWorkflowInstance, rawIdentity: String) {
    let panel = NSOpenPanel()
    panel.title = "Choose Working Directory"
    panel.message = "Choose the directory used when \(resolved.candidate.displayName) runs."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard updateDaemonPreference(identity: rawIdentity, mutate: { preference in
      preference.sourceIdentity = resolved.instance.instance.source.id
      preference.workingDirectory = url.standardizedFileURL.path
    }) else {
      return
    }
    status = "Set working directory for \(resolved.candidate.displayName): \(url.standardizedFileURL.path)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: rawIdentity,
      changeDescription: "working directory"
    )
  }

  private func clearWorkingDirectory(for resolved: ResolvedDaemonWorkflowInstance, rawIdentity: String) {
    guard updateDaemonPreference(identity: rawIdentity, mutate: { preference in
      preference.sourceIdentity = resolved.instance.instance.source.id
      preference.workingDirectory = nil
    }) else {
      return
    }
    status = "Cleared working directory for \(resolved.candidate.displayName)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: rawIdentity,
      changeDescription: "working directory"
    )
  }

  private func chooseEnvironmentFile(for resolved: ResolvedDaemonWorkflowInstance, rawIdentity: String) {
    let panel = NSOpenPanel()
    panel.title = "Choose .env File"
    panel.message = "Choose the .env file passed to \(resolved.candidate.displayName)."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard isSupportedEnvironmentFile(url) else {
      status = "Choose a .env file for \(resolved.candidate.displayName)"
      refreshDaemonWorkflowWindow()
      return
    }
    guard confirmCredentialEnvironmentFile(url, candidate: resolved.candidate) else {
      return
    }
    guard updateDaemonPreference(identity: rawIdentity, mutate: { preference in
      preference.sourceIdentity = resolved.instance.instance.source.id
      preference.environmentFilePath = url.standardizedFileURL.path
    }) else {
      return
    }
    status = "Set .env file for \(resolved.candidate.displayName): \(daemonEnvironmentSummary(for: resolved.candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: rawIdentity,
      changeDescription: ".env file"
    )
  }

  private func clearEnvironmentFile(for resolved: ResolvedDaemonWorkflowInstance, rawIdentity: String) {
    guard updateDaemonPreference(identity: rawIdentity, mutate: { preference in
      preference.sourceIdentity = resolved.instance.instance.source.id
      preference.environmentFilePath = nil
    }) else {
      return
    }
    status = "Cleared .env file for \(resolved.candidate.displayName): \(daemonEnvironmentSummary(for: resolved.candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: rawIdentity,
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
    let preference = daemonPreference(for: candidate)
    let environment = daemonEnvironment(for: candidate, preference: preference)
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
    daemonEnvironmentStore(preference: daemonPreference(for: candidate))
  }

  private func daemonEnvironmentStore(preference: RielaAppDaemonWorkflowPreference) -> RielaAppEnvironmentFileStore {
    let path = preference.environmentFilePath
    let url = path.map { URL(fileURLWithPath: $0) }
    return RielaAppEnvironmentFileStore(environmentFileURL: url)
  }

  private func daemonPreference(for candidate: RielaAppDaemonWorkflowCandidate) -> RielaAppDaemonWorkflowPreference {
    resolveDaemonWorkflowInstance(identity: candidate.id)?.preference ?? daemonState.preference(for: candidate.id)
  }

  private func isSupportedEnvironmentFile(_ url: URL) -> Bool {
    url.lastPathComponent == ".env" || url.pathExtension == "env"
  }
}
#endif
