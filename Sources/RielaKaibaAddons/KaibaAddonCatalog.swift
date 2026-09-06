import Foundation
import KaibaClient
import RielaCore
import RielaKaibaSupport

/// The riela ↔ kaiba boundary.
///
/// Kaiba is an external note store with its own service API, its own typed
/// identifiers, and its own JSON model. All of that stops inside this target:
/// RielaCLI asks this catalog whether an add-on name belongs to kaiba and hands
/// it a `WorkflowAddonExecutionInput`, and everything crossing the API is
/// RielaCore's own model. Nothing outside this target imports `AppCore` or
/// `AppGraphQL`.
///
public enum KaibaAddonCatalog {
  /// Add-ons served exclusively through the configured Kaiba HTTP API.
  public static let localAddonNames: [String] =
    BuiltinNoteAddon.allCases.map(\.rawValue)
    + BuiltinKaibaLongTermMemoryAddon.allCases.map(\.rawValue)

  /// Add-ons that call a running `kaiba serve` instead of a local store.
  public static let remoteAddonNames: [String] = []

  public static var addonNames: [String] { localAddonNames + remoteAddonNames }

  public static func handles(_ addonName: String) -> Bool {
    BuiltinNoteAddon(rawValue: addonName) != nil
      || BuiltinKaibaLongTermMemoryAddon(rawValue: addonName) != nil
      || addonName == KaibaRemoteGraphQLAddon.addonName
  }

  public static func execute(
    _ input: WorkflowAddonExecutionInput,
    environment: [String: String]
  ) async throws -> AdapterExecutionOutput {
    guard handles(input.addon.name) else {
      throw AdapterExecutionError(
        .providerError,
        "missing kaiba add-on resolver for '\(input.addon.name)'"
      )
    }
    // A Kaiba add-on is never permitted to choose or reload a route. The
    // snapshot client is the only transport capability that may cross this
    // boundary into an HTTP-backed operation.
    let resolvedClient: KaibaExecutionSnapshot.ResolvedClient?
    do {
      resolvedClient = try KaibaAddonExecutionContext.resolvedClient(for: input)
    } catch KaibaAddonExecutionContext.Error.missingSnapshot {
      throw AdapterExecutionError(.policyBlocked, "kaiba execution requires validated instance preflight")
    } catch KaibaAddonExecutionContext.Error.invalidBinding {
      throw AdapterExecutionError(.policyBlocked, "kaiba execution has an invalid instance binding")
    }
    let compatibilityDiagnostics = try KaibaLegacyCompatibility.diagnostics(
      input: input,
      environment: environment,
      resolvedClient: resolvedClient
    )
    if let noteAddon = BuiltinNoteAddon(rawValue: input.addon.name) {
      if noteAddon == .graphQLDocument {
        guard let resolvedClient else {
          throw AdapterExecutionError(.policyBlocked, "kaiba GraphQL execution requires a resolved client")
        }
        return KaibaLegacyCompatibility.applying(
          compatibilityDiagnostics,
          to: try await KaibaRemoteGraphQLAddon.execute(input, client: resolvedClient.client)
        )
      }
      if noteAddon == .graphQLRemote {
        guard let resolvedClient else {
          throw AdapterExecutionError(.policyBlocked, "kaiba GraphQL execution requires a resolved client")
        }
        return KaibaLegacyCompatibility.applying(
          compatibilityDiagnostics,
          to: try await KaibaRemoteGraphQLAddon.execute(input, client: resolvedClient.client)
        )
      }
      guard let resolvedClient else {
        throw AdapterExecutionError(.policyBlocked, "kaiba execution requires a resolved client")
      }
      return KaibaLegacyCompatibility.applying(
        compatibilityDiagnostics,
        to: try await executeNoteAddon(input, client: resolvedClient.client, operation: noteAddon)
      )
    }
    if let memoryAddon = BuiltinKaibaLongTermMemoryAddon(rawValue: input.addon.name) {
      guard let resolvedClient else {
        throw AdapterExecutionError(.policyBlocked, "kaiba execution requires a resolved client")
      }
      return KaibaLegacyCompatibility.applying(
        compatibilityDiagnostics,
        to: try await executeLongTermMemoryAddon(input, client: resolvedClient.client, operation: memoryAddon)
      )
    }
    if input.addon.name == KaibaRemoteGraphQLAddon.addonName {
      guard let resolvedClient else {
        throw AdapterExecutionError(.policyBlocked, "kaiba GraphQL execution requires a resolved client")
      }
      return KaibaLegacyCompatibility.applying(
        compatibilityDiagnostics,
        to: try await KaibaRemoteGraphQLAddon.execute(input, client: resolvedClient.client)
      )
    }
    throw AdapterExecutionError(.providerError, "missing kaiba add-on resolver")
  }

  /// Test-only dispatch seam. It never opens a local Kaiba store; tests must
  /// provide an in-memory HTTP transport through a `KaibaClient`.
  static func executeForTesting(
    _ input: WorkflowAddonExecutionInput,
    client: KaibaClient? = nil,
    environment: [String: String]
  ) async throws -> AdapterExecutionOutput {
    try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await execute(input, environment: environment)
    }
  }
}
