#if os(macOS)
import RielaCore
import RielaKaibaSupport

/// Immutable identity of the App configuration that completed Kaiba preflight.
/// The App re-resolves these fields after asynchronous catalog work and starts
/// only when all three remain identical.
public struct RielaAppKaibaStartApproval: Equatable, Sendable {
  public let preference: RielaAppDaemonWorkflowPreference
  public let candidate: RielaAppDaemonWorkflowCandidate
  public let catalog: KaibaInstanceCatalog

  public init(
    preference: RielaAppDaemonWorkflowPreference,
    candidate: RielaAppDaemonWorkflowCandidate,
    catalog: KaibaInstanceCatalog
  ) {
    self.preference = preference
    self.candidate = candidate
    self.catalog = catalog
  }

  public func matches(
    preference: RielaAppDaemonWorkflowPreference,
    candidate: RielaAppDaemonWorkflowCandidate,
    catalog: KaibaInstanceCatalog
  ) -> Bool {
    self.preference == preference && self.candidate == candidate && self.catalog == catalog
  }
}

/// The workflow-effective Kaiba readiness decision used by App start entry points.
public enum RielaAppKaibaWorkflowReadiness: Equatable, Sendable {
  case notApplicable
  case ready
  case blocked(RielaAppKaibaRecoveryAction)

  public var isStartAllowed: Bool {
    switch self {
    case .notApplicable, .ready: true
    case .blocked: false
    }
  }

  public var statusText: String? {
    guard case let .blocked(action) = self else { return nil }
    return "Kaiba is not ready. \(action.instruction)"
  }

  public static func evaluate(
    workflow: WorkflowDefinition,
    preference: RielaAppDaemonWorkflowPreference,
    catalog: KaibaInstanceCatalog,
    environment: [String: String]
  ) async -> Self {
    let requests = RielaAppKaibaBindingController.bindingRequests(workflow: workflow, preference: preference)
    guard !requests.isEmpty else { return .notApplicable }
    do {
      let snapshot = try KaibaExecutionSnapshot(requests: requests, catalog: catalog, environment: environment)
      try validateLegacyCompatibility(
        workflow: workflow,
        environment: environment,
        requests: requests,
        snapshot: snapshot
      )
      _ = try await snapshot.preflight(requests: requests)
      return .ready
    } catch is CancellationError {
      return .blocked(.testSelectedInstance)
    } catch let error as KaibaClientFactoryError {
      switch error {
      case .missingCredential, .invalidCredential: return .blocked(.configureWorkflowEnvironment)
      case .invalidConfiguration: return .blocked(.openKaibaSettings)
      }
    } catch let error as KaibaInstanceStoreError {
      switch error {
      case .missingInstance, .defaultInvariant: return .blocked(.selectEnabledInstance)
      case .invalidStore, .unavailable, .invalidInstance, .duplicateName, .changedInstance:
        return .blocked(.openKaibaSettings)
      }
    } catch let error as KaibaExecutionSnapshot.PreflightError {
      switch error {
      case .longTermMemoryUnavailable, .longTermMemoryAuthenticationFailed, .readinessFailed:
        return .blocked(.testSelectedInstance)
      }
    } catch KaibaLegacyInputCompatibility.Error.connectionMismatch {
      return .blocked(.repairLegacyConnectionConfiguration)
    } catch {
      return .blocked(.testSelectedInstance)
    }
  }

  private static func validateLegacyCompatibility(
    workflow: WorkflowDefinition,
    environment: [String: String],
    requests: [KaibaExecutionSnapshot.BindingRequest],
    snapshot: KaibaExecutionSnapshot
  ) throws {
    let addons = workflow.nodes.compactMap { node -> WorkflowNodeAddonRef? in
      guard let addon = node.addon, addon.name.hasPrefix("kaiba/") else { return nil }
      return addon
    }
    guard addons.count == requests.count else {
      throw KaibaLegacyInputCompatibility.Error.connectionMismatch
    }
    for (addon, request) in zip(addons, requests) {
      _ = try KaibaLegacyInputCompatibility.diagnostics(
        addon: addon,
        environment: environment,
        instance: snapshot.client(bindingID: request.instanceID).instance
      )
    }
  }
}
#endif
