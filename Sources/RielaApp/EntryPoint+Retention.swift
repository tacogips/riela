#if os(macOS)
import Foundation
import RielaCLI

func rielaAppRetentionRequest(
  homeDirectory: URL,
  projectRoot: URL?,
  environment: [String: String]
) -> RielaRetentionRequest {
  RielaRetentionRequest(
    trigger: .automatic,
    homeDirectory: homeDirectory,
    projectDirectory: projectRoot,
    explicitSessionStore: nil,
    environment: environment,
    scope: .all,
    overrides: RielaRetentionOverrides(),
    dryRun: false
  )
}

extension RielaApp {
  func startRetention() {
    let request = rielaAppRetentionRequest(
      homeDirectory: appHomeDirectory,
      projectRoot: launchOptions.projectRoot,
      environment: launchOptions.environment
    )
    retentionScheduler = RielaRetentionScheduler(runImmediately: true) {
      for warning in RielaAutomaticStoragePass.runScheduled(request) {
        let prefix = "riela retention warning: "
        let detail = warning.hasPrefix(prefix) ? String(warning.dropFirst(prefix.count)) : warning
        let message = "RielaApp retention warning: \(detail)\n"
        FileHandle.standardError.write(Data(message.utf8))
      }
    }
    retentionScheduler?.start()
  }
}
#endif
