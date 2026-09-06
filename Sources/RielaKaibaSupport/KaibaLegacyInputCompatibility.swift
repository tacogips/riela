import RielaCore

/// Validates legacy Kaiba node fields as value-free compatibility assertions.
/// These fields can never select a client, endpoint, credential, or store.
public enum KaibaLegacyInputCompatibility {
  public static let localConfigurationIgnored = "legacy_kaiba_local_config_ignored"
  public static let connectionConfigurationMatched = "legacy_kaiba_connection_config_matched"
  public static let connectionMismatch = "legacy_kaiba_connection_mismatch"
  public static let connectionMismatchRecoveryInstruction =
    "Bind the intended named instance and remove legacy fields."

  private static let localConfigurationKeys: Set<String> = [
    "noteRoot", "configPath", "databasePath"
  ]
  private static let remoteAssertionKeys: Set<String> = [
    "endpoint", "apiKeyEnv", "allowUnauthenticated", "allowInsecureHTTP",
    "allowRemoteUnauthenticated"
  ]
  private static let localConfigurationEnvironmentKeys: Set<String> = [
    "KAIBA_NOTE_ROOT", "RIELA_NOTE_ROOT"
  ]

  public static func diagnostics(
    addon: WorkflowNodeAddonRef,
    environment: [String: String],
    instance: KaibaInstance
  ) throws -> [String] {
    let configuration = addon.config ?? [:]
    var diagnostics: [String] = []

    if !localConfigurationKeys.isDisjoint(with: configuration.keys)
      || !localConfigurationEnvironmentKeys.isDisjoint(with: environment.keys) {
      diagnostics.append(localConfigurationIgnored)
    }

    let assertionKeys = Set(configuration.keys).intersection(remoteAssertionKeys)
    guard !assertionKeys.isEmpty else { return diagnostics }
    guard assertionsMatch(configuration, instance: instance) else {
      throw Error.connectionMismatch
    }
    diagnostics.append(connectionConfigurationMatched)
    return diagnostics
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case connectionMismatch
  }

  private static func assertionsMatch(
    _ configuration: JSONObject,
    instance: KaibaInstance
  ) -> Bool {
    if let endpoint = configuration["endpoint"] {
      guard case let .string(rawEndpoint) = endpoint,
            let normalizedEndpoint = normalizedLegacyEndpoint(rawEndpoint, instance: instance),
            normalizedEndpoint == instance.endpoint else {
        return false
      }
    }

    if let apiKeyEnv = configuration["apiKeyEnv"] {
      guard case let .string(environmentVariable) = apiKeyEnv,
            case let .bearer(expectedEnvironmentVariable) = instance.authentication,
            environmentVariable == expectedEnvironmentVariable else {
        return false
      }
    }

    if let allowUnauthenticated = configuration["allowUnauthenticated"] {
      guard case .bool(let allowsUnauthenticated) = allowUnauthenticated else { return false }
      let isUnauthenticated: Bool
      if case .unauthenticated = instance.authentication {
        isUnauthenticated = true
      } else {
        isUnauthenticated = false
      }
      guard allowsUnauthenticated == isUnauthenticated else { return false }
    }

    if let allowInsecureHTTP = configuration["allowInsecureHTTP"] {
      guard case .bool(let allowsInsecureHTTP) = allowInsecureHTTP,
            allowsInsecureHTTP == instance.allowInsecureHTTP else {
        return false
      }
    }

    if let allowRemoteUnauthenticated = configuration["allowRemoteUnauthenticated"] {
      guard case .bool(let allowsRemoteUnauthenticated) = allowRemoteUnauthenticated,
            allowsRemoteUnauthenticated == instance.allowRemoteUnauthenticated else {
        return false
      }
    }
    return true
  }

  private static func normalizedLegacyEndpoint(
    _ endpoint: String,
    instance: KaibaInstance
  ) -> String? {
    var assertion = instance
    assertion.endpoint = endpoint
    return try? KaibaInstanceValidation.normalizedEndpoint(assertion)
  }
}
