#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  func addDaemonWorkflowSourceOnlyURL(_ rawURL: String) {
    let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return
    }
    status = "Importing \(value)"
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      do {
        let materialized = try await Task.detached {
          try RielaAppGitHubSourceMaterializer().materialize(value)
        }.value
        defer {
          try? FileManager.default.removeItem(at: materialized.temporaryRoot)
        }
        importDaemonWorkflowOrPackageSourcesOnly([materialized.sourceURL])
      } catch {
        status = "Failed to import URL: \(error.localizedDescription)"
        refreshDaemonWorkflowWindow()
      }
    }
  }
}
#endif
