import Foundation
import KaibaClient

/// Immutable per-execution projection of the Kaiba instances selected by a
/// workflow or direct node invocation. It captures resolved clients once so a
/// later catalog edit cannot change an in-flight execution's destination.
public struct KaibaExecutionSnapshot: Sendable {
  /// A declared Kaiba node binding captured before workflow scheduling. The
  /// capability bit is deliberately derived from the add-on name by callers,
  /// never from workflow variables or transport responses.
  public struct BindingRequest: Equatable, Sendable {
    public let instanceID: String?
    public let requiresLongTermMemory: Bool

    public init(instanceID: String?, requiresLongTermMemory: Bool = false) {
      self.instanceID = instanceID
      self.requiresLongTermMemory = requiresLongTermMemory
    }
  }

  public struct PreflightResult: Equatable, Sendable {
    public let instanceID: String
    public let readiness: KaibaInstanceLastTest
    public let longTermMemoryAvailable: Bool

    public init(
      instanceID: String,
      readiness: KaibaInstanceLastTest,
      longTermMemoryAvailable: Bool
    ) {
      self.instanceID = instanceID
      self.readiness = readiness
      self.longTermMemoryAvailable = longTermMemoryAvailable
    }
  }

  public enum PreflightError: Error, Equatable, Sendable {
    case readinessFailed(instanceID: String, status: KaibaInstanceLastTestStatus, code: String?)
    case longTermMemoryAuthenticationFailed(instanceID: String)
    case longTermMemoryUnavailable(instanceID: String)
  }

  public struct ResolvedClient: Sendable {
    public let instance: KaibaInstance
    public let client: KaibaClient

    public init(instance: KaibaInstance, client: KaibaClient) {
      self.instance = instance
      self.client = client
    }
  }

  public let clients: [ResolvedClient]
  private let defaultInstanceID: String?
  private let clientsByInstanceID: [String: ResolvedClient]

  /// Captures every distinct explicit binding and the default requested by an
  /// unbound node. Binding resolution and client construction happen before
  /// execution begins and never consult the catalog again.
  public init(
    bindingIDs: [String?],
    catalog: KaibaInstanceCatalog,
    environment: [String: String],
    clientFactory: KaibaClientFactory = .init()
  ) throws {
    try self.init(
      requests: bindingIDs.map { BindingRequest(instanceID: $0) },
      catalog: catalog,
      environment: environment,
      clientFactory: clientFactory
    )
  }

  /// Captures the resolved clients once before any network I/O. Callers retain
  /// the accompanying requests for capability preflight; the catalog is never
  /// consulted after this initializer returns.
  public init(
    requests: [BindingRequest],
    catalog: KaibaInstanceCatalog,
    environment: [String: String],
    clientFactory: KaibaClientFactory = .init()
  ) throws {
    let validatedCatalog = try KaibaInstanceValidation.validated(catalog)
    let defaultID = validatedCatalog.instances.first(where: \.isDefault)?.id
    var orderedInstanceIDs: [String] = []
    var seenInstanceIDs = Set<String>()

    for request in requests {
      let instance = try KaibaInstanceResolver.resolve(
        bindingID: request.instanceID,
        catalog: validatedCatalog
      )
      if seenInstanceIDs.insert(instance.id).inserted {
        orderedInstanceIDs.append(instance.id)
      }
    }

    var resolvedClients: [ResolvedClient] = []
    var clientsByID: [String: ResolvedClient] = [:]
    for instanceID in orderedInstanceIDs {
      guard let instance = validatedCatalog.instances.first(where: { $0.id == instanceID }) else {
        throw KaibaInstanceStoreError.missingInstance
      }
      let resolved = ResolvedClient(
        instance: instance,
        client: try clientFactory.makeClient(instance: instance, environment: environment)
      )
      resolvedClients.append(resolved)
      clientsByID[instanceID] = resolved
    }

    clients = resolvedClients
    defaultInstanceID = defaultID
    clientsByInstanceID = clientsByID
  }

  /// Returns the already-resolved client for the exact explicit binding or for
  /// the captured default when the node did not supply a binding.
  public func client(bindingID: String?) throws -> ResolvedClient {
    let instanceID: String
    if let bindingID {
      instanceID = bindingID
    } else if let defaultInstanceID {
      instanceID = defaultInstanceID
    } else {
      throw KaibaInstanceStoreError.defaultInvariant
    }
    guard let client = clientsByInstanceID[instanceID] else {
      throw KaibaInstanceStoreError.missingInstance
    }
    return client
  }

  /// Runs the generic readiness probe once per captured instance. Results
  /// retain capture order for deterministic caller diagnostics.
  public func readiness(using service: KaibaReadinessService = .init()) async throws
    -> [(instanceID: String, result: KaibaInstanceLastTest)] {
    try await clients.asyncMap { resolved in
      (resolved.instance.id, try await service.test(resolved.client))
    }
  }

  /// Gates business work with one ordinary readiness probe per captured
  /// instance and one side-effect-free memory capability probe only where a
  /// selected node requires it. Cancellation remains cancellation; diagnostics
  /// intentionally contain only Riela-owned status values and instance IDs.
  public func preflight(
    requests: [BindingRequest],
    using service: KaibaReadinessService = .init()
  ) async throws -> [PreflightResult] {
    var memoryInstanceIDs = Set<String>()
    for request in requests where request.requiresLongTermMemory {
      memoryInstanceIDs.insert(try client(bindingID: request.instanceID).instance.id)
    }

    var results: [PreflightResult] = []
    results.reserveCapacity(clients.count)
    for resolved in clients {
      let readiness = try await service.test(resolved.client)
      guard readiness.status == .ready else {
        throw PreflightError.readinessFailed(
          instanceID: resolved.instance.id,
          status: readiness.status,
          code: readiness.code
        )
      }
      let needsMemory = memoryInstanceIDs.contains(resolved.instance.id)
      if needsMemory {
        do {
          let response = try await resolved.client.longTermMemoryNotebook()
          guard response.result.accepted, response.value != nil else {
            throw PreflightError.longTermMemoryUnavailable(instanceID: resolved.instance.id)
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as PreflightError {
          throw error
        } catch let error as KaibaClientError {
          if case .authFailed = error {
            throw PreflightError.longTermMemoryAuthenticationFailed(instanceID: resolved.instance.id)
          }
          throw PreflightError.longTermMemoryUnavailable(instanceID: resolved.instance.id)
        } catch {
          throw PreflightError.longTermMemoryUnavailable(instanceID: resolved.instance.id)
        }
      }
      results.append(.init(
        instanceID: resolved.instance.id,
        readiness: readiness,
        longTermMemoryAvailable: needsMemory
      ))
    }
    return results
  }
}

private extension Array {
  func asyncMap<Value: Sendable>(
    _ transform: @Sendable (Element) async throws -> Value
  ) async throws -> [Value] where Element: Sendable {
    var values: [Value] = []
    values.reserveCapacity(count)
    for element in self {
      values.append(try await transform(element))
    }
    return values
  }
}
