import Foundation
import KaibaClient
import RielaCore
import RielaKaibaSupport

/// Runtime-owned immutable Kaiba selection. Catalog dispatch cannot reload the
/// instance catalog or substitute another server after preflight.
public enum KaibaAddonExecutionContext {
  @TaskLocal public static var snapshot: KaibaExecutionSnapshot?
  @TaskLocal public static var allowsMockExecution = false
  @TaskLocal static var mockClient: KaibaClient?
  @TaskLocal static var mockInstance: KaibaInstance?

  public enum Error: Swift.Error, Equatable, Sendable {
    case missingSnapshot
    case invalidBinding
  }

  public static func resolvedClient(
    for input: WorkflowAddonExecutionInput
  ) throws -> KaibaExecutionSnapshot.ResolvedClient? {
    guard input.addon.name.hasPrefix("kaiba/") else {
      throw Error.invalidBinding
    }
    guard let snapshot else {
      guard allowsMockExecution else {
        throw Error.missingSnapshot
      }
      return mockClient.map {
        .init(
          instance: mockInstance ?? KaibaInstance(
            id: "test-kaiba-instance",
            name: "Test Kaiba",
            endpoint: "http://127.0.0.1:8787/graphql",
            authentication: .unauthenticated
          ),
          client: $0
        )
      }
    }
    let bindingID: String?
    if let value = input.addon.config?["kaibaInstanceId"] {
      guard case let .string(identifier) = value,
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Error.invalidBinding
      }
      bindingID = identifier
    } else {
      bindingID = nil
    }
    return try snapshot.client(bindingID: bindingID)
  }

  public static func withSnapshot<Value: Sendable>(
    _ snapshot: KaibaExecutionSnapshot?,
    allowsMockExecution: Bool,
    operation: () async throws -> Value
  ) async rethrows -> Value {
    try await $snapshot.withValue(snapshot) {
      try await $allowsMockExecution.withValue(allowsMockExecution) {
        try await operation()
      }
    }
  }

  /// Test-only compatibility seam for legacy unit fixtures. Production callers
  /// cannot access this internal symbol and must supply a validated snapshot.
  static func withMockExecutionForTesting<Value: Sendable>(
    client: KaibaClient? = nil,
    instance: KaibaInstance? = nil,
    operation: () async throws -> Value
  ) async rethrows -> Value {
    if instance != nil, client == nil {
      preconditionFailure("a mock Kaiba instance requires a mock client")
    }
    return try await $mockClient.withValue(client) {
      try await $mockInstance.withValue(instance) {
        try await withSnapshot(nil, allowsMockExecution: true, operation: operation)
      }
    }
  }
}
