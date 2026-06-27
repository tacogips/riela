#if os(macOS)
import AppKit
import RielaAppSupport

extension RielaApp {
  func setDaemonWorkflowEnvironment(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
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
    guard !candidate.requiredEnvironment.isEmpty else {
      return "\(prefix), no required env"
    }
    if summary.missingNames.isEmpty {
      return "\(prefix), all required env set"
    }
    return "\(prefix), missing \(summary.missingNames.joined(separator: ", "))"
  }

  func daemonEnvironmentColumnStatus(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let summary = daemonEnvironmentStatus(for: candidate)
    guard !candidate.requiredEnvironment.isEmpty else {
      return summary.fileDisplayName == nil ? "No req" : "File"
    }
    return summary.missingNames.isEmpty ? "Ready" : "Missing \(summary.missingNames.count)"
  }

  func daemonEnvironment(for candidate: RielaAppDaemonWorkflowCandidate) -> [String: String] {
    daemonEnvironmentStore(for: candidate).mergedEnvironment()
  }

  private enum EnvironmentFileAction {
    case choose
    case clear
    case cancel
  }

  private struct EnvironmentStatusSummary {
    var fileDisplayName: String?
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
    alert.messageText = "Environment File"
    alert.informativeText = "Choose a .env file for \(candidate.displayName), clear the current file, or cancel."
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

  private func chooseEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    let panel = NSOpenPanel()
    panel.title = "Select .env File"
    panel.message = "Select the credential env file to pass to \(candidate.displayName)."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    guard isSupportedEnvironmentFile(url) else {
      status = "Select a .env file for \(candidate.displayName)"
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
    status = "Selected env file for \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
  }

  private func clearEnvironmentFile(for candidate: RielaAppDaemonWorkflowCandidate) {
    guard updateDaemonPreference(identity: candidate.id, mutate: { preference in
      preference.environmentFilePath = nil
    }) else {
      return
    }
    status = "Cleared env file for \(candidate.displayName): \(daemonEnvironmentSummary(for: candidate))"
    refreshDaemonWorkflowWindow()
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
    let store = daemonEnvironmentStore(for: candidate)
    let statuses = store.statuses(for: candidate.requiredEnvironment.map(\.name))
    let missingNames = statuses.filter { !$0.configured }.map(\.name)
    return EnvironmentStatusSummary(
      fileDisplayName: preference.environmentFilePath.map { URL(fileURLWithPath: $0).lastPathComponent },
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
