import Foundation
import RielaCore

/// Built-in add-ons that run the locally installed wrike-gateway CLI tier
/// binaries. Capability boundaries (read / write / delete) are enforced by the
/// selected binary itself, so each add-on pins one tier and never lets the
/// workflow swap in a broader executable through inputs or payload data.
enum BuiltinWrikeGatewayAddon: String {
  case read = "riela/wrike-gateway-read"
  case write = "riela/wrike-gateway-write"
  case admin = "riela/wrike-gateway-admin"

  var executableName: String {
    switch self {
    case .read:
      "wrike-gateway-reader"
    case .write:
      "wrike-gateway-writer"
    case .admin:
      "wrike-gateway-admin"
    }
  }

  var executableEnvironmentName: String {
    switch self {
    case .read:
      "WRIKE_GATEWAY_READER_BIN"
    case .write:
      "WRIKE_GATEWAY_WRITER_BIN"
    case .admin:
      "WRIKE_GATEWAY_ADMIN_BIN"
    }
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeWrikeGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinWrikeGatewayAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try WrikeGatewayAddonEngine(environment: environment).execute(input, operation: operation, context: context)
  }
}

private struct WrikeGatewayAddonEngine {
  /// The exact wrike-gateway credential contract. addon.env may only populate
  /// these target names, so a workflow cannot use the binding mechanism to
  /// inject arbitrary variables into the child process.
  private static let allowedTargetEnvironmentNames: Set<String> = [
    "WRIKE_GATEWAY_API_CLIENT_ID",
    "WRIKE_GATEWAY_API_CLIENT_SECRET",
    "WRIKE_GATEWAY_ACCESS_TOKEN",
    "WRIKE_GATEWAY_API_BASE_URL",
    "WRIKE_GATEWAY_OAUTH_CALLBACK_PORT"
  ]

  var environment: [String: String]

  func execute(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinWrikeGatewayAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let childEnvironment = try resolvedChildEnvironment(input)
    let resolvedBinary = try resolvedBinary(operation: operation, config: config, addonName: input.addon.name)
    let document = try renderedDocument(config: config, variables: variables, addonName: input.addon.name)
    var arguments = ["graphql", "query", document]
    if let variablesJSON = try renderedVariablesJSON(config: config, variables: variables, addonName: input.addon.name) {
      arguments.append(contentsOf: ["--variables", variablesJSON])
    }
    var runner = AppleGatewayProcessRunner(runtimeEnvironment: environment)
    runner.toolLabel = operation.executableName
    runner.extraChildEnvironment = childEnvironment
    let processOutput = try runner.run(
      executablePath: resolvedBinary.path,
      arguments: arguments,
      deadline: context.deadline,
      allowNonzeroExit: true
    )
    let envelope = try envelope(from: processOutput, addonName: input.addon.name)
    guard envelope.errors.isEmpty else {
      let detail = appleGatewayCompactText(envelope.errors.joined(separator: "; "))
      throw AdapterExecutionError(.providerError, "\(input.addon.name) GraphQL errors: \(detail)")
    }
    var payloadRoot: JSONObject = ["data": .object(envelope.data)]
    if let selected = try selectedValue(config: config, variables: variables, payloadRoot: payloadRoot, addonName: input.addon.name) {
      payloadRoot["selected"] = selected
    }
    let when = try whenFlags(config: config, payloadRoot: payloadRoot, addonName: input.addon.name)
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "data": .object(envelope.data),
      "requestId": .string(envelope.requestId ?? ""),
      "replyText": .string("wrike-gateway \(operation.executableName) query succeeded."),
      "wrikeGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(envelope.requestId ?? "")
      ])
    ]
    if let selected = payloadRoot["selected"] {
      payload["selected"] = selected
    }
    for (key, value) in try payloadExtras(config: config, variables: variables, addonName: input.addon.name) {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "wrike-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func resolvedChildEnvironment(_ input: WorkflowAddonExecutionInput) throws -> [String: String] {
    if let env = input.addon.env {
      for targetName in env.keys where !Self.allowedTargetEnvironmentNames.contains(targetName) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) addon.env target '\(targetName)' is not a wrike-gateway environment variable"
        )
      }
    }
    return try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
  }

  private func resolvedBinary(
    operation: BuiltinWrikeGatewayAddon,
    config: JSONObject,
    addonName: String
  ) throws -> AppleGatewayResolvedBinary {
    let searchPath = executableSearchPath(environment: environment)
    if let configured = nonEmptyString(config["binaryPath"])?.trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
      guard let path = resolveExecutable(configured, searchPath: searchPath) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) config.binaryPath is not executable: \(configured)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .config)
    }
    if let envPath = environmentValue(operation.executableEnvironmentName, environment: environment) {
      guard let path = resolveExecutable(envPath, searchPath: searchPath) else {
        throw AdapterExecutionError(.policyBlocked, "\(operation.executableEnvironmentName) is not executable: \(envPath)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .environment)
    }
    guard let path = resolveExecutable(operation.executableName, searchPath: searchPath) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) requires \(operation.executableName); set config.binaryPath, \(operation.executableEnvironmentName), or PATH"
      )
    }
    return AppleGatewayResolvedBinary(path: path, source: .path)
  }

  private func renderedDocument(config: JSONObject, variables: JSONObject, addonName: String) throws -> String {
    guard let template = nonEmptyString(config["queryTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate is required")
    }
    let document = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !document.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate rendered to an empty document")
    }
    return document
  }

  private func renderedVariablesJSON(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> String? {
    guard let value = config["variablesTemplate"] else {
      return nil
    }
    guard case let .object(template) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate must be an object")
    }
    let rendered = template.mapValues { renderJSONTemplates($0, variables: variables) }
    do {
      return try JSONValue.object(rendered).compactJSONString()
    } catch {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate failed to encode: \(error.localizedDescription)")
    }
  }

  private func envelope(
    from processOutput: AppleGatewayProcessOutput,
    addonName: String
  ) throws -> AppleGatewayGraphQLEnvelope {
    do {
      return try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: addonName)
    } catch {
      guard processOutput.terminationStatus != 0 else {
        throw error
      }
      let detail = appleGatewayCompactText(
        processOutput.stderr.isEmpty ? processOutput.stdout : processOutput.stderr
      )
      throw AdapterExecutionError(
        .providerError,
        "\(addonName) failed with exit code \(processOutput.terminationStatus): \(detail)"
      )
    }
  }

  private func selectedValue(
    config: JSONObject,
    variables: JSONObject,
    payloadRoot: JSONObject,
    addonName: String
  ) throws -> JSONValue? {
    guard let value = config["selectFirst"] else {
      return nil
    }
    guard case let .object(selector) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst must be an object")
    }
    guard let path = nonEmptyString(selector["path"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.path is required")
    }
    guard case let .array(candidates)? = wrikeGatewayLookupPath(path, in: payloadRoot) else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) config.selectFirst.path '\(path)' did not resolve to an array")
    }
    var conditions: JSONObject = [:]
    if let whereValue = selector["where"] {
      guard case let .object(rendered) = renderJSONTemplates(whereValue, variables: variables) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.where must be an object")
      }
      conditions = rendered
    }
    let match = candidates.first { candidate in
      guard case let .object(entry) = candidate else {
        return false
      }
      return conditions.allSatisfy { key, expected in
        wrikeGatewayValuesMatch(entry[key], expected)
      }
    }
    return match ?? JSONValue.null
  }

  private func whenFlags(
    config: JSONObject,
    payloadRoot: JSONObject,
    addonName: String
  ) throws -> [String: Bool] {
    var flags: [String: Bool] = ["always": true, "ok": true]
    guard let value = config["whenFlags"] else {
      return flags
    }
    guard case let .object(flagPaths) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags must be an object")
    }
    for (flagName, pathValue) in flagPaths {
      guard case let .string(path) = pathValue, !path.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags.\(flagName) must be a non-empty path string")
      }
      flags[flagName] = wrikeGatewayTruthy(wrikeGatewayLookupPath(path, in: payloadRoot))
    }
    return flags
  }

  private func payloadExtras(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> JSONObject {
    guard let value = config["payloadExtras"] else {
      return [:]
    }
    guard case let .object(template) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.payloadExtras must be an object")
    }
    return template.mapValues { renderJSONTemplates($0, variables: variables) }
  }
}

/// Dot-path lookup over a JSON object that also understands numeric array
/// indexes, so paths like `data.tasks.nodes.0.id` address the first node.
func wrikeGatewayLookupPath(_ path: String, in root: JSONObject) -> JSONValue? {
  let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
  guard !keys.isEmpty else {
    return nil
  }
  var current: JSONValue? = .object(root)
  for key in keys {
    switch current {
    case let .object(object):
      current = object[key]
    case let .array(values):
      guard let index = Int(key), values.indices.contains(index) else {
        return nil
      }
      current = values[index]
    default:
      return nil
    }
  }
  return current
}

func wrikeGatewayTruthy(_ value: JSONValue?) -> Bool {
  switch value {
  case nil, .null:
    return false
  case let .bool(flag):
    return flag
  case let .string(text):
    return !text.isEmpty
  case let .integer(number):
    return number != 0
  case let .number(number):
    return number != 0
  case let .array(values):
    return !values.isEmpty
  case let .object(object):
    return !object.isEmpty
  }
}

private func wrikeGatewayValuesMatch(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
  guard let actual else {
    return expected == .null
  }
  if actual == expected {
    return true
  }
  if case let .string(expectedText) = expected, case let .integer(number) = actual {
    return String(number) == expectedText
  }
  return false
}
