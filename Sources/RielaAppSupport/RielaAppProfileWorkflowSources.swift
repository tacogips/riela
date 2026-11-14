import Foundation

public enum RielaAppProfileWorkflowSources {
  public static func discover(
    appRootURL: URL,
    profileName: RielaAppProfileName,
    state: RielaAppDaemonWorkflowState,
    projectRoot: URL?
  ) -> [RielaAppDaemonWorkflowCandidate] {
    RielaAppDaemonWorkflowDiscovery(projectRoot: projectRoot).discoverUserDaemonWorkflows(
      appWorkflowRoot: RielaAppProfileStore.workflowRootURL(
        appRootURL: appRootURL, profileName: profileName, storageDirectory: state.workflowStorageDirectory
      ),
      appPackageRoot: RielaAppProfileStore.packageRootURL(
        appRootURL: appRootURL, profileName: profileName, storageDirectory: state.workflowStorageDirectory
      ),
      projectDirectories: state.projectDirectories,
      additionalWorkflowDirectories: state.workflowDirectories
    )
  }

  public static func resolveSource(
    sourceIdentity: String,
    appRootURL: URL,
    profileName: RielaAppProfileName,
    state: RielaAppDaemonWorkflowState
  ) -> RielaAppDaemonWorkflowCandidate? {
    let prefix = "selected-workflow:"
    if sourceIdentity.hasPrefix(prefix) {
      return RielaAppDaemonWorkflowDiscovery(projectRoot: nil)
        .discoverSelectedWorkflowDirectory(String(sourceIdentity.dropFirst(prefix.count)))
    }
    return discover(appRootURL: appRootURL, profileName: profileName, state: state, projectRoot: nil)
      .first { $0.id == sourceIdentity }
  }
}

extension RielaAppProfileStore {
  public static func sessionStoreRootURL(homeDirectory: URL, profileName: RielaAppProfileName) -> URL {
    homeDirectory.appendingPathComponent(".riela/profiles/\(profileName.rawValue)/sessions", isDirectory: true)
  }
}
