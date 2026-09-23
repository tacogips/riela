#if os(macOS)
import Foundation
import RielaAppSupport
import RielaKaibaSupport

private struct DaemonKaibaReadinessEvaluation: Sendable {
  let readiness: RielaAppKaibaWorkflowReadiness
  let catalog: KaibaInstanceCatalog?
}

extension RielaApp {
  func daemonKaibaWorkflowReadiness(identity: String) async -> RielaAppKaibaWorkflowReadiness {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      return .blocked(.openKaibaSettings)
    }
    return await evaluateDaemonKaibaReadiness(
      candidate: resolved.candidate,
      preference: resolved.preference
    ).readiness
  }

  /// Performs preflight and confirms that no preference, workflow source, or
  /// catalog change invalidated it before a runtime receives its configuration.
  func approvedDaemonWorkflowInstance(identity: String) async -> ResolvedDaemonWorkflowInstance? {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance needs a workflow source"
      refreshDaemonWorkflowWindow()
      return nil
    }
    let evaluation = await evaluateDaemonKaibaReadiness(
      candidate: resolved.candidate,
      preference: resolved.preference
    )
    guard evaluation.readiness.isStartAllowed, let catalog = evaluation.catalog else {
      status = evaluation.readiness.statusText ?? "Kaiba is not ready."
      refreshDaemonWorkflowWindow()
      return nil
    }
    let approval = RielaAppKaibaStartApproval(
      preference: resolved.preference,
      candidate: resolved.candidate,
      catalog: catalog
    )
    guard let current = await currentDaemonWorkflowInstance(identity: identity, for: approval) else {
      status = "Kaiba configuration changed during readiness check. Try again."
      refreshDaemonWorkflowWindow()
      return nil
    }
    return current
  }

  /// Keeps a blocked launch from being retried automatically with the same invalid configuration.
  func disableDaemonWorkflowAutostart(identity: String) {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else { return }
    var state = resolved.state
    var preference = resolved.preference
    guard preference.active else { return }
    preference.active = false
    state.preferences[resolved.localIdentity] = preference
    _ = saveDaemonState(state, profileName: resolved.profileName)
  }

  private func evaluateDaemonKaibaReadiness(
    candidate: RielaAppDaemonWorkflowCandidate,
    preference: RielaAppDaemonWorkflowPreference
  ) async -> DaemonKaibaReadinessEvaluation {
    let workflowDirectory = candidate.workflowDirectory
    let environment = daemonEnvironment(for: candidate, preference: preference)
    let homeURL = appHomeDirectory
    let catalogLoader = kaibaCatalogLoader
    return await Task.detached(priority: .userInitiated) {
      guard let workflow = DaemonWorkflowWindowController.workflowDefinition(at: workflowDirectory) else {
        return DaemonKaibaReadinessEvaluation(readiness: .blocked(.openKaibaSettings), catalog: nil)
      }
      do {
        let catalog = try await catalogLoader(homeURL)
        let readiness = await RielaAppKaibaWorkflowReadiness.evaluate(
          workflow: workflow,
          preference: preference,
          catalog: catalog,
          environment: environment
        )
        return DaemonKaibaReadinessEvaluation(readiness: readiness, catalog: catalog)
      } catch {
        return DaemonKaibaReadinessEvaluation(readiness: .blocked(.openKaibaSettings), catalog: nil)
      }
    }.value
  }

  private func currentDaemonWorkflowInstance(
    identity: String,
    for approval: RielaAppKaibaStartApproval
  ) async -> ResolvedDaemonWorkflowInstance? {
    let homeURL = appHomeDirectory
    let catalogLoader = kaibaCatalogLoader
    let currentCatalog = await Task.detached(priority: .userInitiated) {
      try? await catalogLoader(homeURL)
    }.value
    // Re-resolve only after the final await. This keeps a preference or source
    // edit that occurred while the catalog loaded from starting stale work.
    guard let currentCatalog,
          let current = resolveDaemonWorkflowInstance(identity: identity),
          approval.matches(
            preference: current.preference,
            candidate: current.candidate,
            catalog: currentCatalog
          ) else {
      return nil
    }
    return current
  }
}
#endif
