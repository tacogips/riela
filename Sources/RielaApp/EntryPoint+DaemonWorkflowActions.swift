#if os(macOS)
import AppKit
import Foundation

extension RielaApp {
  func revealDaemonWorkflowSource(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let sourceURL = URL(fileURLWithPath: candidate.packageDirectory ?? candidate.workflowDirectory, isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    status = "Revealed \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  func openDaemonWorkflowViewer(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(
      workflowDirectory: candidate.workflowDirectory,
      sessionStoreRoot: nil,
      currentDirectory: daemonState.preference(for: candidate.id).workingDirectory ?? candidate.workingDirectory,
      environmentVariablesSummary: "\(daemonState.preference(for: candidate.id).environmentVariables.count) inline",
      workflowVariablesSummary: "\(daemonState.preference(for: candidate.id).defaultVariables.count) values",
      nodePatches: daemonState.preference(for: candidate.id).nodePatches,
      onSaveNodePatch: { [weak self] nodeId, patch in
        self?.saveDaemonNodePatch(identity: identity, nodeId: nodeId, patch: patch) ?? false
      },
      onSetWorkingDirectory: { [weak self] in
        self?.setDaemonWorkflowWorkingDirectory(identity: identity)
        guard let self,
          let candidate = self.daemonCandidates.first(where: { $0.id == identity })
        else {
          return nil
        }
        return self.daemonState.preference(for: identity).workingDirectory ?? candidate.workingDirectory
      },
      onSetEnvironmentVariables: { [weak self] in
        self?.setDaemonWorkflowEnvironmentVariables(identity: identity)
        guard let self else {
          return nil
        }
        return "\(self.daemonState.preference(for: identity).environmentVariables.count) inline"
      },
      onSetWorkflowVariables: { [weak self] in
        self?.setDaemonWorkflowDefaultVariables(identity: identity)
        guard let self else {
          return nil
        }
        return "\(self.daemonState.preference(for: identity).defaultVariables.count) values"
      }
    )
    status = "Opened viewer: \(candidate.displayName)"
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
