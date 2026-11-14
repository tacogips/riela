import Foundation
import RielaAddonSupport
import RielaCore
import XGatewayCore

/// The read-only X SDK executes in this process, including inside a private
/// workflow guest. It never launches a gateway CLI or another container.
extension BuiltinWorkflowAddonResolver {
  func executeXGatewaySDKAddon(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let deadline = context.deadline
    let document = try xGatewayJSONDocument(input)
    let descriptor = LocalGatewayGraphQLDescriptor(providerName: "x-gateway", payloadNamespaceKey: "xGateway",
      tier: "x-gateway-reader", acceptsVariables: false,
      isAllowedEnvironmentTarget: { xGatewayReaderEnvironment.contains($0) },
      run: { _, document, _, environment in
        try xGatewayReaderQuery(document: document, environment: environment, deadline: deadline)
      })
    var output = try await LocalGatewayGraphQLEngine(environment: environment, descriptor: descriptor,
      runnerOverride: localGatewayGraphQLRunner).execute(input, context: context, documentOverride: document)
    if let steps = input.addon.config?["postprocess"] {
      let rendered = try renderAddonConfig(steps, variables: addonVariables(for: input))
      output.payload["processed"] = try JSONDataTransform.run(.object(output.payload), steps: rendered)
    }
    return output
  }
}

/// JSON mode never interprets argument strings as query source or templates a
/// second time. The SDK schema remains the authority for operations and types.
private func xGatewayJSONDocument(_ input: WorkflowAddonExecutionInput) throws -> String? {
  let config = input.addon.config ?? [:]
  guard config["operation"] != nil else {
    guard config["arguments"] == nil, config["select"] == nil else {
      throw AdapterExecutionError(.invalidInput, "X JSON arguments and select require operation")
    }
    return nil
  }
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["nowVariables"] == nil else {
    throw AdapterExecutionError(.invalidInput, "X JSON operation cannot be combined with query templates")
  }
  let variables = try addonVariables(for: input)
  let rendered = try renderAddonConfig(.object(config), variables: variables)
  guard case let .object(value) = rendered, case let .string(operation)? = value["operation"],
        case let .object(selection)? = value["select"] else {
    throw AdapterExecutionError(.invalidInput, "X JSON mode requires operation and select")
  }
  let arguments: JSONObject
  if let supplied = value["arguments"] {
    guard case let .object(object) = supplied else {
      throw AdapterExecutionError(.invalidInput, "X JSON arguments must be an object")
    }
    arguments = object
  } else { arguments = [:] }
  let name = try xGraphQLName(operation)
  let args = try arguments.keys.sorted().map { key in
    try "\(xGraphQLName(key)): \(xGraphQLLiteral(arguments[key]!, depth: 0))"
  }.joined(separator: ", ")
  let fields = try xGraphQLSelection(selection, depth: 0)
  let document = "query { \(name)\(args.isEmpty ? "" : "(\(args))") { \(fields) } }"
  guard document.utf8.count <= 1_000_000 else {
    throw AdapterExecutionError(.invalidInput, "X JSON query exceeds the size limit")
  }
  return document
}

private func xGraphQLName(_ name: String) throws -> String {
  guard name.range(of: #"^[_A-Za-z][_0-9A-Za-z]*$"#, options: .regularExpression) != nil,
        !name.hasPrefix("__"), name.utf8.count <= 128 else {
    throw AdapterExecutionError(.invalidInput, "X JSON contains an invalid field name")
  }
  return name
}

private func xGraphQLSelection(_ fields: JSONObject, depth: Int) throws -> String {
  guard depth < 16, !fields.isEmpty, fields.count <= 256 else {
    throw AdapterExecutionError(.invalidInput, "X JSON select is empty or exceeds its limits")
  }
  return try fields.keys.sorted().map { key in
    let name = try xGraphQLName(key)
    switch fields[key]! {
    case .bool(true): return name
    case let .object(nested): return try "\(name) { \(xGraphQLSelection(nested, depth: depth + 1)) }"
    default: throw AdapterExecutionError(.invalidInput, "X JSON select expects true or a nested object")
    }
  }.joined(separator: " ")
}

private func xGraphQLLiteral(_ value: JSONValue, depth: Int) throws -> String {
  guard depth < 16 else { throw AdapterExecutionError(.invalidInput, "X JSON arguments exceed the depth limit") }
  switch value {
  case let .array(items):
    return try "[" + items.map { try xGraphQLLiteral($0, depth: depth + 1) }.joined(separator: ", ") + "]"
  case let .object(fields):
    return try "{" + fields.keys.sorted().map {
      try "\(xGraphQLName($0)): \(xGraphQLLiteral(fields[$0]!, depth: depth + 1))"
    }.joined(separator: ", ") + "}"
  default: return try value.compactJSONString()
  }
}

private let xGatewayReaderEnvironment: Set<String> = [
  "X_GW_TOKEN", "X_GW_APP_TOKEN", "X_GW_CONSUMER_KEY", "X_GW_CONSUMER_SECRET",
  "X_GW_ACCESS_TOKEN", "X_GW_ACCESS_TOKEN_SECRET"
]

func xGatewayReaderQuery(document: String, environment: [String: String], deadline: Date?) throws -> String {
  guard (try? XGatewayCLI.classifyGraphQLOperation(document)) == .query else {
    throw AdapterExecutionError(.policyBlocked, "X reader requires a query operation")
  }
  let remaining = deadline?.timeIntervalSinceNow ?? 30
  guard remaining > 0 else { throw AdapterExecutionError(.timeout, "X reader deadline expired") }
  // One bounded SDK attempt. The surrounding workflow owns retry/pagination.
  let milliseconds = max(1, Int(min(30, remaining) * 1000))
  let result = XGatewayCLI(commandName: "x-gateway-reader", surface: .read).run(
    arguments: ["graphql", "query", document, "--json", "--retry", "0", "--timeout-ms", String(milliseconds)],
    environment: environment)
  guard result.exitCode == 0, let data = result.stdout.data(using: .utf8),
        case let .object(envelope)? = try? JSONDecoder().decode(JSONValue.self, from: data),
        envelope["ok"] == .bool(true), case let .object(graphQL)? = envelope["data"] else {
    // Provider diagnostics may contain private source data; the worker keeps
    // them out of the enclosing workflow's error/result channel.
    throw AdapterExecutionError(.providerError, "X reader SDK query failed")
  }
  return try JSONValue.object(graphQL).compactJSONString()
}
