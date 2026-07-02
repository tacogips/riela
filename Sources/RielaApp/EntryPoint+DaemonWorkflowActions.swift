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

  func openDaemonWorkflowViewer(identity: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let candidate = resolved.candidate
    let preference = resolved.preference
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(
      workflowDirectory: candidate.workflowDirectory,
      sessionStoreRoot: RielaAppDaemonWorkflowRuntime.defaultSessionStoreRootPath,
      currentDirectory: preference.workingDirectory ?? candidate.workingDirectory,
      environmentVariablesSummary: "\(preference.environmentVariables.count) inline",
      workflowVariablesSummary: "\(preference.defaultVariables.count) values",
      nodePatches: preference.nodePatches,
      onSaveNodePatch: { [weak self] nodeId, patch in
        self?.saveDaemonNodePatch(identity: identity, nodeId: nodeId, patch: patch) ?? false
      },
      onSetWorkingDirectory: { [weak self] in
        self?.setDaemonWorkflowWorkingDirectory(identity: identity)
        guard let self,
          let resolved = self.resolveDaemonWorkflowInstance(identity: identity)
        else {
          return nil
        }
        return resolved.preference.workingDirectory ?? resolved.candidate.workingDirectory
      },
      onSetEnvironmentVariables: { [weak self] in
        self?.setDaemonWorkflowEnvironmentVariables(identity: identity)
        guard let resolved = self?.resolveDaemonWorkflowInstance(identity: identity) else {
          return nil
        }
        return "\(resolved.preference.environmentVariables.count) inline"
      },
      onSetWorkflowVariables: { [weak self] in
        self?.setDaemonWorkflowDefaultVariables(identity: identity)
        guard let resolved = self?.resolveDaemonWorkflowInstance(identity: identity) else {
          return nil
        }
        return "\(resolved.preference.defaultVariables.count) values"
      },
      assistantProfileName: resolved.profileName,
      assistantSettings: resolved.state.assistant,
      onSaveAssistantSettings: { [weak self] settings in
        self?.saveAssistantSettings(settings) ?? "RielaApp is not available"
      },
      onSubmitAssistantMessage: { [weak self] message, workingDirectory in
        self?.submitAssistantMessage(message, workingDirectory: workingDirectory)
      }
    )
    status = "Opened viewer: \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  func openWorkflowSourceViewer(sourceId: String) {
    guard let source = daemonWorkflowSources.first(where: { $0.id == sourceId || $0.sourceIdentity == sourceId }) else {
      status = "Workflow source could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    selectedWorkflow = .directDirectory(source.workflowDirectory, identifier: source.workflowId)
    selectedWorkingDirectory = source.workingDirectory
    selectedSessionStoreRoot = RielaAppDaemonWorkflowRuntime.defaultSessionStoreRootPath
    openViewer()
    status = "Opened viewer: \(source.displayName)"
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
