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

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) throws {
    addonName = input.addon.name
    let templateVariables = try addonVariables(for: input)
    let rawConfig = input.addon.config ?? [:]
    if rawConfig["arguments"] != nil {
      guard Set(rawConfig.keys).isSubset(of: ["arguments", "kaibaInstanceId"]), input.addon.inputs?.isEmpty != false else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments cannot be combined with flat config or addon.inputs")
      }
      let arguments = try renderGatewayJSONArguments(rawConfig["arguments"], variables: templateVariables, addonName: addonName)
      guard Set(arguments.keys).isDisjoint(with: ["kaibaInstanceId", "endpoint", "apiKey", "apiKeyEnv", "allowUnauthenticated", "mode", "backend"]) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments cannot change the captured Kaiba connection")
      }
      if input.addon.name == "kaiba/note-graphql-document" || input.addon.name == "kaiba/note-graphql-remote" {
        guard case let .object(rawArguments)? = rawConfig["arguments"] else {
          throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
        }
        for key in ["query", "document", "operationName"] where rawArguments[key] != nil {
          guard case .string? = rawArguments[key], rawArguments[key] == arguments[key] else {
            throw AdapterExecutionError(.policyBlocked, "\(addonName) GraphQL document and operation name must remain literal; use variables for data")
          }
        }
      }
      config = arguments
      variables = [:]
    } else {
      guard case let .object(renderedConfig) = try renderAddonConfig(.object(rawConfig), variables: templateVariables) else {
        throw noteAddonInvalidInput("\(input.addon.name) config must be an object")
      }
      config = renderedConfig
      variables = templateVariables
    }
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
