#if os(macOS)
import Foundation
import RielaCore

extension RielaApp {
  func startGarbageCollection() {
    let homeDirectory = appHomeDirectory
    let projectDirectory = launchOptions.projectRoot
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let environment = launchOptions.environment
    Task.detached(priority: .utility) {
      do {
        let configuration = try RielaGarbageCollectionConfiguration.load(
          homeDirectory: homeDirectory,
          environment: environment
        )
        guard configuration.gc.retentionDays != nil else { return }
        let report = RielaDataGarbageCollector().collect(
          retentionDays: configuration.gc.retentionDays,
          scope: .user,
          homeDirectory: homeDirectory,
          projectDirectory: projectDirectory
        )
        let message = "RielaApp GC removed \(report.removedSessionCount) session(s), "
          + "\(report.removedEntryCount) entries, and reclaimed \(report.reclaimedBytes) bytes"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        for diagnostic in report.diagnostics {
          FileHandle.standardError.write(Data(("RielaApp GC warning: \(diagnostic)\n").utf8))
        }
      } catch {
        FileHandle.standardError.write(Data(("RielaApp GC warning: \(error.localizedDescription)\n").utf8))
      }
    }
  }
}
#endif
