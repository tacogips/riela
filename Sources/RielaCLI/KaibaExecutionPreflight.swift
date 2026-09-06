import Foundation
import RielaCore
import RielaKaibaSupport

/// CLI composition for the shared immutable Kaiba snapshot. This is the only
/// place that knows how a resolved workflow exposes authored add-on bindings;
/// the support target remains independent of CLI discovery and execution.
enum KaibaExecutionPreflight {
  static func workflow(
    nodes: [WorkflowNodeRef],
    environment: [String: String],
    workflow: WorkflowDefinition? = nil,
    calleeResolver: (any WorkflowCalleeResolving)? = nil
  ) async throws -> KaibaExecutionSnapshot? {
    let reachableNodes = try await nodesIncludingReachableCallees(
      nodes: nodes,
      workflow: workflow,
      calleeResolver: calleeResolver
    )
    let addons = reachableNodes.compactMap(\.addon).filter { $0.name.hasPrefix("kaiba/") }
    let requests = try reachableNodes.compactMap { node in
      try request(for: node.addon)
    }
    return try await run(requests: requests, addons: addons, environment: environment)
  }

  /// Resolves the finite, statically declared cross-workflow call graph before
  /// any session is created. The runner can then only consume clients captured
  /// by this immutable execution snapshot.
  private static func nodesIncludingReachableCallees(
    nodes: [WorkflowNodeRef],
    workflow: WorkflowDefinition?,
    calleeResolver: (any WorkflowCalleeResolving)?
  ) async throws -> [WorkflowNodeRef] {
    guard let workflow, let calleeResolver else { return nodes }
    var visitedWorkflowIDs = Set([workflow.workflowId])
    return try await appendReachableCalleeNodes(
      from: workflow,
      nodes: nodes,
      calleeResolver: calleeResolver,
      visitedWorkflowIDs: &visitedWorkflowIDs
    )
  }

  private static func appendReachableCalleeNodes(
    from workflow: WorkflowDefinition,
    nodes: [WorkflowNodeRef],
    calleeResolver: any WorkflowCalleeResolving,
    visitedWorkflowIDs: inout Set<String>
  ) async throws -> [WorkflowNodeRef] {
    var collected = nodes
    for reference in DeterministicWorkflowRunner.crossWorkflowDispatchReferences(in: workflow) {
      guard visitedWorkflowIDs.insert(reference.workflowId).inserted else { continue }
      let callee = try await calleeResolver.resolveCallee(workflowId: reference.workflowId)
      collected = try await appendReachableCalleeNodes(
        from: callee.workflow,
        nodes: collected + callee.workflow.nodes,
        calleeResolver: calleeResolver,
        visitedWorkflowIDs: &visitedWorkflowIDs
      )
    }
    return collected
  }

  static func direct(
    addon: WorkflowNodeAddonRef,
    environment: [String: String]
  ) async throws -> KaibaExecutionSnapshot? {
    guard let request = try request(for: addon) else { return nil }
    return try await run(requests: [request], addons: [addon], environment: environment)
  }

  private static func request(
    for addon: WorkflowNodeAddonRef?
  ) throws -> KaibaExecutionSnapshot.BindingRequest? {
    guard let addon, addon.name.hasPrefix("kaiba/") else { return nil }
    let instanceID: String?
    if let configured = addon.config?["kaibaInstanceId"] {
      guard case let .string(value) = configured,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Failure.invalidInstance
      }
      instanceID = value
    } else {
      instanceID = nil
    }
    return .init(
      instanceID: instanceID,
      requiresLongTermMemory: addon.name == "kaiba/memory-consolidate"
        || addon.name == "kaiba/memory-recall"
    )
  }

  private static func run(
    requests: [KaibaExecutionSnapshot.BindingRequest],
    addons: [WorkflowNodeAddonRef],
    environment: [String: String]
  ) async throws -> KaibaExecutionSnapshot? {
    guard !requests.isEmpty else { return nil }
    do {
      let home = URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment),
        isDirectory: true
      )
      let snapshot = try KaibaExecutionSnapshot(
        requests: requests,
        catalog: try KaibaInstanceStore(homeURL: home).load(),
        environment: environment
      )
      try validateLegacyCompatibility(addons: addons, environment: environment, snapshot: snapshot)
      _ = try await snapshot.preflight(requests: requests)
      return snapshot
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as KaibaExecutionSnapshot.PreflightError {
      throw Failure(error)
    } catch let error as KaibaLegacyInputCompatibility.Error {
      throw Failure(error)
    } catch let error as KaibaInstanceStoreError {
      throw Failure(error)
    }
  }

  private static func validateLegacyCompatibility(
    addons: [WorkflowNodeAddonRef],
    environment: [String: String],
    snapshot: KaibaExecutionSnapshot
  ) throws {
    for addon in addons {
      guard let request = try request(for: addon) else { continue }
      _ = try KaibaLegacyInputCompatibility.diagnostics(
        addon: addon,
        environment: environment,
        instance: snapshot.client(bindingID: request.instanceID).instance
      )
    }
  }

  fileprivate enum Failure: Error {
    case invalidInstance
    case store(KaibaInstanceStoreError)
    case preflight(KaibaExecutionSnapshot.PreflightError)
    case legacyCompatibility(KaibaLegacyInputCompatibility.Error)

    init(_ error: KaibaInstanceStoreError) { self = .store(error) }
    init(_ error: KaibaExecutionSnapshot.PreflightError) { self = .preflight(error) }
    init(_ error: KaibaLegacyInputCompatibility.Error) { self = .legacyCompatibility(error) }

    var message: String {
      switch self {
      case .invalidInstance, .store(.invalidStore), .store(.invalidInstance):
        return "kaiba preflight failed: invalid_kaiba_instance. Update the selected named Kaiba instance."
      case .store(.missingInstance):
        return "kaiba preflight failed: unknown_kaiba_instance. Select an existing named Kaiba instance."
      case .store(.defaultInvariant):
        return "kaiba preflight failed: missing_kaiba_instance. Configure a default named Kaiba instance."
      case .store(.unavailable):
        return "kaiba preflight failed: kaiba_instance_store_unavailable. Retry after the catalog is available."
      case .store:
        return "kaiba preflight failed: invalid_kaiba_instance. Update the selected named Kaiba instance."
      case .legacyCompatibility(.connectionMismatch):
        return "kaiba preflight failed: \(KaibaLegacyInputCompatibility.connectionMismatch). "
          + KaibaLegacyInputCompatibility.connectionMismatchRecoveryInstruction
      case let .preflight(.readinessFailed(_, .incompatible, code)):
        let detail = code == "server_rejected" ? "server_rejected" : "incompatible_response"
        return "kaiba preflight failed: incompatible_kaiba_instance (\(detail)). Update Kaiba or select a compatible instance."
      case let .preflight(.readinessFailed(_, status, _)):
        return "kaiba preflight failed: \(status.rawValue). Test the selected named Kaiba instance."
      case .preflight(.longTermMemoryAuthenticationFailed):
        return "kaiba preflight failed: auth_failed. Use an authorized named Kaiba instance."
      case .preflight(.longTermMemoryUnavailable):
        return "kaiba preflight failed: incompatible_kaiba_instance (long_term_memory_unavailable). Use an instance with long-term-memory access."
      }
    }
  }
}

extension CLIUsageError {
  static func kaibaPreflight(_ error: Error) -> CLIUsageError? {
    guard let failure = error as? KaibaExecutionPreflight.Failure else { return nil }
    return CLIUsageError(failure.message)
  }
}
