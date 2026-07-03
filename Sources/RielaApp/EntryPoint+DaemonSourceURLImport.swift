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
        status = "Failed to import URL: \(githubImportErrorMessage(error))"
        refreshDaemonWorkflowWindow()
      }
    }
  }

  private func githubImportErrorMessage(_ error: Error) -> String {
    guard let importError = error as? RielaAppGitHubSourceMaterializerError else {
      return error.localizedDescription
    }
    switch importError {
    case .unsupportedURL:
      return "Only GitHub tree URLs are supported. Use https://github.com/owner/repo/tree/branch/path."
    case .unsafeURL:
      return "The GitHub URL contains unsafe path components."
    case let .gitFailed(message):
      return "GitHub checkout failed. Confirm the repository, branch, path, and network access. \(message)"
    case let .missingCheckout(path):
      return "GitHub checkout finished, but the requested directory was not found: \(path)"
    }
  }
}
#endif
