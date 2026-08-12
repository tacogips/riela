#if os(macOS)
import Foundation
import RielaAppSupport
import RielaServer

extension RielaApp {
  func setDaemonWorkflowWorkingDirectory(identity: String) {
    _ = identity
    openWebUI(context: "Web Config")
  }

  func setDaemonWorkflowEnvironment(identity: String) {
    _ = identity
    openWebUI(context: "Web Config")
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

  func daemonServerConfiguration(profileName: RielaAppProfileName? = nil) -> RielaServerConfiguration {
    RielaServerConfiguration()
  }

  private struct EnvironmentStatusSummary {
    var fileDisplayName: String?
    var inlineCount: Int
    var missingNames: [String]
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

}

#endif
