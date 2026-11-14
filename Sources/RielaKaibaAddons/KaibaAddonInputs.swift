import Foundation
import RielaAddonSupport
import RielaCore

/// Config/input lookup shared by every kaiba add-on, local or remote.
///
/// A node may carry a value either in `addon.config` (authored, template
/// rendered) or in the resolved node inputs (AI or upstream produced), and both
/// families read them the same way. The remote add-on uses this alone: unlike
/// `NoteAddonContext` it never opens a store.
struct KaibaAddonInputs {
  let addonName: String
  let config: JSONObject
  let variables: JSONObject
  let environment: [String: String]

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) {
    addonName = input.addon.name
    config = input.addon.config ?? [:]
    variables = addonVariables(for: input)
    self.environment = environment
  }

  func string(_ keys: [String]) -> String? {
    for key in keys {
      if let value = noteString(key, config: config, variables: variables) {
        return value
      }
    }
    return nil
  }

  func requiredString(_ keys: [String], fieldName: String) throws -> String {
    guard let value = string(keys) else {
      throw noteAddonInvalidInput("\(addonName) \(fieldName) is required")
    }
    return value
  }

  func bool(_ key: String, default defaultValue: Bool) -> Bool {
    boolValue(config[key]) ?? boolValue(variables[key]) ?? defaultValue
  }

  func int(_ key: String, default defaultValue: Int) -> Int {
    noteIntValue(config[key], variables: variables)
      ?? noteIntValue(variables[key], variables: variables)
      ?? defaultValue
  }

  func value(_ key: String) -> JSONValue? {
    config[key] ?? variables[key]
  }

  /// Bearer token for a `kaiba serve` call. Kaiba authenticates by default, so
  /// a node that holds no key has to say so explicitly rather than discovering
  /// it as a 401: `allowUnauthenticated` is the opt-in for a server started
  /// with `--allow-unauthenticated`.
  func remoteAPIKey() throws -> String? {
    let envName = string(["apiKeyEnv"]) ?? "KAIBA_API_KEY"
    if let key = environment[envName], !key.isEmpty {
      return key
    }
    guard bool("allowUnauthenticated", default: false) else {
      throw noteAddonInvalidInput(
        "\(addonName) requires the API key env var '\(envName)' (issue one with `kaiba client issue`) or allowUnauthenticated: true"
      )
    }
    return nil
  }
}
