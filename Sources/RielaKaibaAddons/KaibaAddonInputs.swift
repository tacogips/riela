import Foundation
import RielaAddonSupport
import RielaCore

public enum KaibaNestedArgumentRules {
  public static let connectionKeys: Set<String> = [
    "kaibaInstanceId", "endpoint", "apiKey", "apiKeyEnv", "allowUnauthenticated", "mode", "backend"
  ]
  public static let literalGraphQLKeys: [String] = ["query", "document", "operationName"]
  public static let graphQLDocumentAddonNames: Set<String> = [
    "kaiba/note-graphql-document", "kaiba/note-graphql-remote"
  ]

  public static func issues(
    addonName: String,
    config: JSONObject,
    inputs: JSONObject?
  ) -> [WorkflowGatewayRequestIssue] {
    guard config["arguments"] != nil else { return [] }
    guard Set(config.keys).isSubset(of: ["arguments", "kaibaInstanceId"]), inputs?.isEmpty != false else {
      return [issue(addonName, "arguments cannot be combined with flat config or addon.inputs")]
    }
    if exactPlaceholder(config["arguments"]) { return [] }
    guard case let .object(arguments)? = config["arguments"] else {
      return [issue(addonName, "arguments must be an object")]
    }
    guard Set(arguments.keys).isDisjoint(with: connectionKeys) else {
      return [issue(addonName, "arguments cannot change the captured Kaiba connection")]
    }
    if graphQLDocumentAddonNames.contains(addonName) {
      for key in literalGraphQLKeys where arguments[key] != nil {
        guard case let .string(value)? = arguments[key], !value.contains("{{") else {
          return [issue(addonName, "GraphQL document and operation name must remain literal; use variables for data")]
        }
      }
    }
    return []
  }

  private static func issue(_ addonName: String, _ detail: String) -> WorkflowGatewayRequestIssue {
    WorkflowGatewayRequestIssue(relativePath: "", message: "\(addonName) \(detail)")
  }

  private static func exactPlaceholder(_ value: JSONValue?) -> Bool {
    guard case let .string(template)? = value else { return false }
    return template.range(of: #"^\s*\{\{\s*[a-zA-Z0-9_.-]+\s*\}\}\s*$"#, options: .regularExpression) != nil
  }
}

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
      guard Set(arguments.keys).isDisjoint(with: KaibaNestedArgumentRules.connectionKeys) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments cannot change the captured Kaiba connection")
      }
      if KaibaNestedArgumentRules.graphQLDocumentAddonNames.contains(input.addon.name) {
        guard case let .object(rawArguments)? = rawConfig["arguments"] else {
          throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
        }
        for key in KaibaNestedArgumentRules.literalGraphQLKeys where rawArguments[key] != nil {
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
