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
    let userCache = try XGatewayUserCacheExchange(input: input, workingDirectory: workingDirectory, environment: environment)
    let usageCache = try XGatewayUsageCacheExchange(input: input, workingDirectory: workingDirectory, environment: environment)
    let descriptor = LocalGatewayGraphQLDescriptor(providerName: "x-gateway", payloadNamespaceKey: "xGateway",
      tier: "x-gateway-reader", acceptsVariables: false,
      isAllowedEnvironmentTarget: { xGatewayReaderEnvironment.contains($0) },
      observationMetadata: xGatewayUsageMetadata,
      run: { _, document, _, environment in
        let bindings = try userCache?.bindings() ?? [:]
        return try xGatewayReaderQuery(document: document, environment: environment.merging(bindings) { _, memory in memory },
          deadline: deadline, userCache: userCache, usageCache: usageCache)
      })
    return try await LocalGatewayGraphQLEngine(environment: environment, descriptor: descriptor,
      runnerOverride: localGatewayGraphQLRunner).execute(input, context: context, documentOverride: document)
  }
}

func xGatewayUsageMetadata(_ stdout: String) -> JSONObject {
  guard stdout.utf8.count <= 8_000_000,
        let graphQL = try? JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8)),
        case let .object(extensions)? = graphQL["extensions"] else { return [:] }
  var result: JSONObject = [:]
  if let raw = extensions["resourceUsage"], let data = try? raw.compactJSONString(),
     let observation = try? JSONDecoder().decode(XGatewayUsageCacheExchange.Observation.self, from: Data(data.utf8)),
     observation.valid, let encoded = try? JSONEncoder().encode(observation),
     let normalized = try? JSONDecoder().decode(JSONValue.self, from: encoded) {
    result["resourceUsage"] = normalized
  }
  if let status = nonEmptyString(extensions["usageCacheStatus"]),
     ["stored", "unavailable", "unsupported", "invalid"].contains(status) {
    result["usageCacheStatus"] = .string(status)
  }
  return result
}

private let xGatewayReaderEnvironment: Set<String> = [
  "X_GW_TOKEN", "X_GW_APP_TOKEN", "X_GW_CONSUMER_KEY", "X_GW_CONSUMER_SECRET",
  "X_GW_ACCESS_TOKEN", "X_GW_ACCESS_TOKEN_SECRET"
]

func xGatewayReaderQuery(document: String, environment: [String: String], deadline: Date?,
                         userCache: XGatewayUserCacheExchange? = nil,
                         usageCache: XGatewayUsageCacheExchange? = nil) throws -> String {
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
  let usageStatus = usageCache?.record(stdout: result.stdout, stderr: result.stderr, environment: environment)
  let stdout = try result.exitCode == 0 ? (userCache?.consume(result.stdout) ?? result.stdout) : result.stdout
  guard result.exitCode == 0, let data = stdout.data(using: .utf8),
        case let .object(envelope)? = try? JSONDecoder().decode(JSONValue.self, from: data),
        envelope["ok"] == .bool(true), case var .object(graphQL)? = envelope["data"] else {
    // Provider diagnostics may contain private source data; the worker keeps
    // them out of the enclosing workflow's error/result channel.
    throw AdapterExecutionError(.providerError, "X reader SDK query failed"
      + (usageStatus.map { " usageCacheStatus=\($0.rawValue)" } ?? "")
      + GatewayFailureDiagnostics.suffix(stdout: result.stdout, stderr: result.stderr))
  }
  if let usageStatus {
    var extensions: JSONObject = [:]
    if case let .object(current)? = graphQL["extensions"] { extensions = current }
    extensions["usageCacheStatus"] = .string(usageStatus.rawValue)
    graphQL["extensions"] = .object(extensions)
  }
  return try JSONValue.object(graphQL).compactJSONString()
}
