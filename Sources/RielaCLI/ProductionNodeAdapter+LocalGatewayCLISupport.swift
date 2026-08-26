import Foundation
import RielaAddonSupport
import RielaCore

/// How a local gateway CLI accepts a GraphQL document.
enum LocalGatewayGraphQLInvocationStyle {
  /// `<binary> graphql query <document> [--variables <compact-json>]`
  /// (wrike-gateway, google-analytics-gateway).
  case queryPositionalWithVariables
  /// `<binary> graphql --query <document>`; the CLI rejects `--variables`,
  /// so values must be rendered into the document text (gmail-gateway).
  case queryFlagInlineOnly
}

/// Static description of one local gateway CLI tier. The executable is pinned
/// per add-on so a workflow cannot swap in a broader tier through inputs or
/// payload data; capability boundaries are enforced by the binary itself.
struct LocalGatewayGraphQLCLIDescriptor {
  var providerName: String
  var payloadNamespaceKey: String
  var executableName: String
  var executableEnvironmentName: String
  var invocationStyle: LocalGatewayGraphQLInvocationStyle
  /// addon.env may only populate target names this predicate accepts, so the
  /// binding mechanism cannot inject arbitrary variables into the child
  /// process.
  var isAllowedEnvironmentTarget: (String) -> Bool
}

/// Shared engine for built-in add-ons that bridge to a locally installed
/// gateway CLI speaking the GraphQL JSON envelope contract on stdout.
struct LocalGatewayGraphQLCLIEngine {
  var environment: [String: String]
  var descriptor: LocalGatewayGraphQLCLIDescriptor

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    var variables = addonVariables(for: input)
    for (name, value) in try localGatewayNowVariables(config: config, addonName: input.addon.name) {
      variables[name] = .string(value)
    }
    let childEnvironment = try resolvedChildEnvironment(input)
    let document = try renderedDocument(config: config, variables: variables, addonName: input.addon.name)
    let resolvedBinary = try localGatewayResolvedBinary(
      executableName: descriptor.executableName,
      executableEnvironmentName: descriptor.executableEnvironmentName,
      config: config,
      environment: environment,
      addonName: input.addon.name
    )
    var arguments: [String]
    switch descriptor.invocationStyle {
    case .queryPositionalWithVariables:
      arguments = ["graphql", "query", document]
      if let variablesJSON = try renderedVariablesJSON(config: config, variables: variables, addonName: input.addon.name) {
        arguments.append(contentsOf: ["--variables", variablesJSON])
      }
    case .queryFlagInlineOnly:
      guard config["variablesTemplate"] == nil else {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) config.variablesTemplate is not supported; \(descriptor.executableName) rejects GraphQL variables, render values into config.queryTemplate instead"
        )
      }
      arguments = ["graphql", "--query", document]
    }
    var runner = AppleGatewayProcessRunner(runtimeEnvironment: environment)
    runner.toolLabel = descriptor.executableName
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
    if let selected = try localGatewaySelectedValue(
      config: config,
      variables: variables,
      payloadRoot: payloadRoot,
      addonName: input.addon.name
    ) {
      payloadRoot["selected"] = selected
    }
    let when = try localGatewayWhenFlags(config: config, payloadRoot: payloadRoot, addonName: input.addon.name)
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "data": .object(envelope.data),
      "requestId": .string(envelope.requestId ?? ""),
      "replyText": .string("\(descriptor.providerName) \(descriptor.executableName) query succeeded."),
      descriptor.payloadNamespaceKey: .object([
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
    for (key, value) in try localGatewayPayloadExtras(config: config, variables: variables, addonName: input.addon.name) {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: descriptor.providerName,
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func resolvedChildEnvironment(_ input: WorkflowAddonExecutionInput) throws -> [String: String] {
    if let env = input.addon.env {
      for targetName in env.keys where !descriptor.isAllowedEnvironmentTarget(targetName) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) addon.env target '\(targetName)' is not a \(descriptor.providerName) environment variable"
        )
      }
    }
    return try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
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
}

/// Binary resolution order shared by every local gateway CLI add-on:
/// `addon.config.binaryPath` (literal, never rendered), then the per-tier
/// environment fallback, then `PATH` lookup of the fixed executable name.
func localGatewayResolvedBinary(
  executableName: String,
  executableEnvironmentName: String,
  config: JSONObject,
  environment: [String: String],
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
  if let envPath = environmentValue(executableEnvironmentName, environment: environment) {
    guard let path = resolveExecutable(envPath, searchPath: searchPath) else {
      throw AdapterExecutionError(.policyBlocked, "\(executableEnvironmentName) is not executable: \(envPath)")
    }
    return AppleGatewayResolvedBinary(path: path, source: .environment)
  }
  guard let path = resolveExecutable(executableName, searchPath: searchPath) else {
    throw AdapterExecutionError(
      .policyBlocked,
      "\(addonName) requires \(executableName); set config.binaryPath, \(executableEnvironmentName), or PATH"
    )
  }
  return AppleGatewayResolvedBinary(path: path, source: .path)
}

func localGatewayNowVariables(config: JSONObject, addonName: String) throws -> [String: String] {
  guard let value = config["nowVariables"] else {
    return [:]
  }
  guard case let .object(offsets) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables must be an object")
  }
  let now = Date()
  var resolved: [String: String] = [:]
  for (name, offsetValue) in offsets {
    guard let offsetSeconds = intValue(offsetValue) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables.\(name) must be an integer second offset")
    }
    resolved[name] = localGatewayInstantString(now.addingTimeInterval(TimeInterval(offsetSeconds)))
  }
  return resolved
}

func localGatewaySelectedValue(
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
  guard case let .array(candidates)? = localGatewayLookupPath(path, in: payloadRoot) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) config.selectFirst.path '\(path)' did not resolve to an array")
  }
  var conditions: JSONObject = [:]
  if let whereValue = selector["where"] {
    guard case let .object(rendered) = renderJSONTemplates(whereValue, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.where must be an object")
    }
    conditions = rendered
  }
  let position = nonEmptyString(selector["position"]) ?? "first"
  guard position == "first" || position == "last" else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.position must be 'first' or 'last'")
  }
  let ordered: [JSONValue] = position == "last" ? candidates.reversed() : candidates
  let match = ordered.first { candidate in
    guard case let .object(entry) = candidate else {
      return false
    }
    return conditions.allSatisfy { key, expected in
      localGatewayConditionMatches(entry[key], expected)
    }
  }
  return match ?? JSONValue.null
}

func localGatewayWhenFlags(
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
    flags[flagName] = localGatewayTruthy(localGatewayLookupPath(path, in: payloadRoot))
  }
  return flags
}

func localGatewayPayloadExtras(
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

/// Dot-path lookup over a JSON object that also understands numeric array
/// indexes, so paths like `data.tasks.nodes.0.id` address the first node.
func localGatewayLookupPath(_ path: String, in root: JSONObject) -> JSONValue? {
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

func localGatewayTruthy(_ value: JSONValue?) -> Bool {
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

private func localGatewayValuesMatch(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
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

/// A where condition is either a plain value (equality) or an operator object
/// combining `contains`, `notContains`, and `ne`, all of which must hold.
private func localGatewayConditionMatches(_ actual: JSONValue?, _ condition: JSONValue) -> Bool {
  guard case let .object(operators) = condition,
        !operators.isEmpty,
        operators.keys.allSatisfy({ ["contains", "notContains", "ne"].contains($0) }) else {
    return localGatewayValuesMatch(actual, condition)
  }
  for (name, operand) in operators {
    switch name {
    case "contains", "notContains":
      guard case let .string(needle) = operand, case let .string(haystack)? = actual else {
        return false
      }
      let contains = haystack.contains(needle)
      if (name == "contains") != contains {
        return false
      }
    case "ne":
      if localGatewayValuesMatch(actual, operand) {
        return false
      }
    default:
      return false
    }
  }
  return true
}

private func localGatewayInstantString(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}
