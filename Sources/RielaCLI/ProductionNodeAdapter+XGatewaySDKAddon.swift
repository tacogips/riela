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
    let document = try builtinGatewayXJSONDocument(input)
    let descriptor = LocalGatewayGraphQLDescriptor(providerName: "x-gateway", payloadNamespaceKey: "xGateway",
      tier: "x-gateway-reader", acceptsVariables: false,
      isAllowedEnvironmentTarget: { xGatewayReaderEnvironment.contains($0) },
      run: { _, document, _, environment in
        try xGatewayReaderQuery(document: document, environment: environment, deadline: deadline)
      })
    return try await LocalGatewayGraphQLEngine(environment: environment, descriptor: descriptor,
      runnerOverride: localGatewayGraphQLRunner).execute(input, context: context, documentOverride: document)
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
