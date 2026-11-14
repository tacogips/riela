#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport

extension RielaApp {
  func revealDaemonWorkflowSource(identity: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let candidate = resolved.candidate
    let sourceURL = URL(fileURLWithPath: candidate.packageDirectory ?? candidate.workflowDirectory, isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    status = "Revealed \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  func isRielaWorkflowProject(_ projectRoot: URL) -> Bool {
    let workflowRoot = projectRoot.appendingPathComponent(".riela/workflows", isDirectory: true)
    let packageRoot = projectRoot.appendingPathComponent(".riela/packages", isDirectory: true)
    return FileManager.default.fileExists(atPath: workflowRoot.path)
      || FileManager.default.fileExists(atPath: packageRoot.path)
  }

  func daemonSummary() -> String {
    guard !daemonState.preferences.isEmpty else {
      return "none"
    }
    var counts: [String: Int] = [:]
    for (identity, preference) in daemonState.preferences {
      let sourceIdentity = preference.sourceIdentity ?? identity
      let hasSource = daemonCandidates.contains { $0.id == identity || $0.sourceIdentity == sourceIdentity }
        || daemonWorkflowSources.contains { $0.id == sourceIdentity || $0.sourceIdentity == sourceIdentity }
      counts[daemonStateLabel(identity: identity, hasSource: hasSource), default: 0] += 1
    }
    let order = ["failed", "needs source", "starting", "reloading", "stopping", "running", "stopped"]
    return order.compactMap { label in
      guard let count = counts[label] else {
        return nil
      }
      return "\(count) \(label)"
    }.joined(separator: " / ")
  }

  private func daemonStateLabel(identity: String, hasSource: Bool) -> String {
    guard hasSource else {
      return "needs source"
    }
    switch daemonRuntime.snapshot(for: identity).status {
    case .running:
      return "running"
    case .starting:
      return "starting"
    case .reloading:
      return "reloading"
    case .stopping:
      return "stopping"
    case .failed:
      return "failed"
    case .stopped:
      return "stopped"
    }
  }
}
#endif
