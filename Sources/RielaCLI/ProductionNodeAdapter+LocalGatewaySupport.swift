import Foundation
import RielaAddonSupport
import RielaCore

/// Runs one GraphQL document against the gateway library backing an add-on
/// tier and returns the JSON envelope that gateway's CLI would have printed on
/// stdout. The gateway runs inside the riela process; `environment` is the
/// only environment it can observe.
typealias LocalGatewayGraphQLRunner = @Sendable (
  _ tier: String,
  _ document: String,
  _ variablesJSON: String?,
  _ environment: [String: String]
) async throws -> String

/// Static description of one local gateway tier.
///
/// The tier is pinned per add-on, so a workflow cannot widen it through inputs
/// or payload data. The gateways are linked as libraries rather than launched
/// as executables, so the boundary is the role and capability list this
/// descriptor hands the gateway's own capability registry — which refuses a
/// document naming a capability outside the tier — instead of which binary was
/// on `PATH`.
struct LocalGatewayGraphQLDescriptor {
  var providerName: String
  var payloadNamespaceKey: String
  /// Reported in the add-on payload so a run records which tier answered.
  var tier: String
  /// Whether the gateway accepts GraphQL variables. gmail-gateway does not, so
  /// values must be rendered into the document text and
  /// `config.variablesTemplate` is refused.
  var acceptsVariables: Bool
  /// addon.env may only populate target names this predicate accepts, so the
  /// binding mechanism cannot inject arbitrary variables into the gateway.
  var isAllowedEnvironmentTarget: (String) -> Bool
  var run: LocalGatewayGraphQLRunner
}

/// Shared engine for built-in add-ons that call a sibling gateway package's
/// GraphQL runtime and read its JSON envelope.
struct LocalGatewayGraphQLEngine {
  var environment: [String: String]
  var descriptor: LocalGatewayGraphQLDescriptor

  init(
    environment: [String: String],
    descriptor: LocalGatewayGraphQLDescriptor,
    runnerOverride: LocalGatewayGraphQLRunner? = nil
  ) {
    self.environment = environment
    self.descriptor = descriptor
    if let runnerOverride {
      self.descriptor.run = runnerOverride
    }
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
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
    let variablesJSON: String?
    if descriptor.acceptsVariables {
      variablesJSON = try renderedVariablesJSON(config: config, variables: variables, addonName: input.addon.name)
    } else {
      guard config["variablesTemplate"] == nil else {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) config.variablesTemplate is not supported; \(descriptor.providerName) rejects GraphQL variables, render values into config.queryTemplate instead"
        )
      }
      variablesJSON = nil
    }
    let gatewayEnvironment = sanitizedGatewayEnvironment(
      runtimeEnvironment: environment,
      bindings: childEnvironment
    )
    let run = descriptor.run
    let tier = descriptor.tier
    let stdout = try await localGatewayRunWithDeadline(
      deadline: context.deadline,
      addonName: input.addon.name,
      providerName: descriptor.providerName
    ) {
      try await run(tier, document, variablesJSON, gatewayEnvironment)
    }
    let envelope = try envelope(from: stdout, addonName: input.addon.name)
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
      "replyText": .string("\(descriptor.providerName) \(descriptor.tier) query succeeded."),
      descriptor.payloadNamespaceKey: .object([
        // The gateway is linked into this process, so there is no resolved
        // binary to report; the tier that answered is the useful fact.
        "runtime": .object([
          "mode": .string("in-process"),
          "tier": .string(descriptor.tier)
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
    from stdout: String,
    addonName: String
  ) throws -> AppleGatewayGraphQLEnvelope {
    try AppleGatewayGraphQLEnvelope(stdout: stdout, addonName: addonName)
  }
}

/// Applies the step deadline to an in-process gateway call. A linked gateway
/// has no process to terminate, so the call is cancelled and the same timeout
/// error a spawned gateway would have produced is raised.
func localGatewayRunWithDeadline(
  deadline: Date?,
  addonName: String,
  providerName: String,
  operation: @escaping @Sendable () async throws -> String
) async throws -> String {
  guard let deadline else { return try await operation() }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline before \(providerName) was called")
  }
  return try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(remaining))
      throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline while calling \(providerName)")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) produced no \(providerName) response")
    }
    return first
  }
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
