#if os(macOS)
import AppKit
import RielaAppSupport
import RielaServer

extension RielaApp {
  func setDaemonWorkflowWorkingDirectory(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
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
      status = "Selected instance is no longer available"
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
    let prefix = summary.fileDisplayName.map { "file \($0)" } ?? "no file"
    let inline = summary.inlineCount == 0 ? "no inline env" : "\(summary.inlineCount) inline env"
    guard !candidate.requiredEnvironment.isEmpty else {
      return "\(prefix), \(inline), no required env"
    }
    if summary.missingNames.isEmpty {
      return "\(prefix), \(inline), all required env set"
    }
    return "\(prefix), \(inline), missing \(summary.missingNames.joined(separator: ", "))"
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
    let alert = NSAlert()
    alert.messageText = "Instance Environment File"
    alert.informativeText = "Choose a .env file for instance \(candidate.displayName), clear the current file, or cancel."
    alert.addButton(withTitle: "Choose File")
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .choose
    case .alertSecondButtonReturn:
      return .clear
    default:
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
    let alert = NSAlert()
    alert.messageText = "Instance Directory"
    alert.informativeText = "Choose the current directory for instance \(candidate.displayName), clear the override, or cancel."
    alert.addButton(withTitle: "Choose Directory")
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .choose
    case .alertSecondButtonReturn:
      return .clear
    default:
      return .cancel
    }
  }

  private func chooseWorkingDirectory(for candidate: RielaAppDaemonWorkflowCandidate) {
    let panel = NSOpenPanel()
    panel.title = "Select Instance Directory"
    panel.message = "Select the current directory to use when instance \(candidate.displayName) runs."
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
    status = "Set instance directory for \(candidate.displayName): \(url.standardizedFileURL.path)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "instance directory"
    )
  }

  private func clearWorkingDirectory(for candidate: RielaAppDaemonWorkflowCandidate) {
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.workingDirectory = nil
    }) else {
      return
    }
    status = "Cleared instance directory override for \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "instance directory"
    )
  }

  private func chooseEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    let panel = NSOpenPanel()
    panel.title = "Select .env File"
    panel.message = "Select the credential env file to pass to instance \(candidate.displayName)."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard isSupportedEnvironmentFile(url) else {
      status = "Select a .env file for instance \(candidate.displayName)"
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
    status = "Selected env file for instance \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "env file"
    )
  }

  private func clearEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.environmentFilePath = nil
    }) else {
      return
    }
    status = "Cleared env file for instance \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: candidate.id,
      changeDescription: "env file"
    )
  }

  private func confirmCredentialEnvironmentFile(_ url: URL, candidate: RielaAppDaemonWorkflowCandidate) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Use Credential Env File?"
    alert.informativeText = [
      "RielaApp will treat \(url.lastPathComponent) as credential material.",
      "Values will not be displayed in the app, but they will be passed to \(candidate.displayName) and its event source process."
    ].joined(separator: " ")
    alert.addButton(withTitle: "Use Env File")
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
