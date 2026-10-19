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
      do {
        let report = try RielaRetentionService().run(request)
        for target in report.targets where target.status == "failed" && !target.warnings.isEmpty {
          let message = "RielaApp retention warning: \(target.warnings[0])\n"
          FileHandle.standardError.write(Data(message.utf8))
        }
      } catch {
        let message = "RielaApp retention warning: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
      }
    }
    retentionScheduler?.start()
  }
}
#endif
