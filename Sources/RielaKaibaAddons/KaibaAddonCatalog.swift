import Foundation
import RielaCore

/// The riela ↔ kaiba boundary.
///
/// Kaiba is an external note store with its own service API, its own typed
/// identifiers, and its own JSON model. All of that stops inside this target:
/// RielaCLI asks this catalog whether an add-on name belongs to kaiba and hands
/// it a `WorkflowAddonExecutionInput`, and everything crossing the API is
/// RielaCore's own model. Nothing outside this target imports `AppCore` or
/// `AppGraphQL`.
///
/// Two families live behind it, and they are deliberately separate node kinds:
///
/// - Local add-ons reach the store through kaiba's library API (`NoteService`),
///   with no credential — the operator view of a store this host owns.
/// - `kaiba/note-graphql-remote` speaks to a running `kaiba serve` over HTTP and
///   opens nothing locally, so kaiba's own authentication and library access
///   control decide what it may reach.
public enum KaibaAddonCatalog {
  /// Add-ons served from the local store through kaiba's library API.
  public static let localAddonNames: [String] =
    BuiltinNoteAddon.allCases.map(\.rawValue)
    + BuiltinKaibaLongTermMemoryAddon.allCases.map(\.rawValue)

  /// Add-ons that call a running `kaiba serve` instead of a local store.
  public static let remoteAddonNames: [String] = [KaibaRemoteGraphQLAddon.addonName]

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
    if let noteAddon = BuiltinNoteAddon(rawValue: input.addon.name) {
      return try await executeNoteAddon(input, environment: environment, operation: noteAddon)
    }
    if let memoryAddon = BuiltinKaibaLongTermMemoryAddon(rawValue: input.addon.name) {
      return try executeLongTermMemoryAddon(input, environment: environment, operation: memoryAddon)
    }
    if input.addon.name == KaibaRemoteGraphQLAddon.addonName {
      return try await KaibaRemoteGraphQLAddon.execute(input, environment: environment)
    }
    throw AdapterExecutionError(
      .providerError,
      "missing kaiba add-on resolver for '\(input.addon.name)'"
    )
  }
}
