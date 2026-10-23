import Foundation
import RielaCore

/// Build with the host's role catalog, then use the existing exact-argument
/// bridge grant. Linux workers need no Apple SDK or catalog copy.
func prepareAppleGatewayContainerOperation(
  _ input: WorkflowAddonExecutionInput, workingDirectory: URL
) throws -> WorkflowAddonExecutionInput {
  guard input.addon.name == BuiltinAppleGatewayAdminAddon.graphql.rawValue,
        input.addon.inputs?["operation"] != nil || input.addon.config?["operation"] != nil else { return input }
  try refuseAppleGatewayBinaryPath(input)
  guard input.addon.env?.isEmpty != false else {
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
  }
  let arguments = try AppleGatewayAdminContext(input: input, currentDirectory: workingDirectory).arguments(for: .graphql)
  let offset = arguments.first == "--config" ? 2 : 0
  guard arguments.count == offset + 5, arguments[offset] == "graphql",
        arguments[offset + 1] == "--query", arguments[offset + 3] == "--variables" else {
    throw AdapterExecutionError(.policyBlocked, "Apple operation did not produce a complete request")
  }
  let queryIndex = offset + 1
  let variablesIndex = offset + 3
  // Retry policy is execution metadata, not part of the GraphQL document.
  let retryEnvironment = try gatewayWriteRetryEnvironment(input, prefix: "APPLE_GATEWAY_")
  // Exact placeholders substitute once. A literal {{...}} inside argument data
  // must not be interpreted when the worker reconstructs its argv. Choose a
  // namespace absent from all caller-controlled top-level variable sources.
  var key: String
  repeat {
    key = "_rielaApple" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  } while input.variables[key] != nil || input.resolvedInputPayload[key] != nil || input.addon.inputs?[key] != nil
  var prepared = input
  prepared.variables[key] = .object([
    "query": .string(arguments[queryIndex + 1]), "variables": .string(arguments[variablesIndex + 1])
  ])
  prepared.addon.inputs = [:]
  prepared.addon.config = ["query": .string("{{\(key).query}}"), "variables": .string("{{\(key).variables}}")]
  if offset == 2 {
    prepared.variables[key] = .object([
      "query": .string(arguments[queryIndex + 1]), "variables": .string(arguments[variablesIndex + 1]),
      "configPath": .string(arguments[1])
    ])
    prepared.addon.config?["configPath"] = .string("{{\(key).configPath}}")
  }
  if !retryEnvironment.isEmpty {
    guard let waitText = retryEnvironment["APPLE_GATEWAY_WRITE_RETRY_INITIAL_WAIT_SECONDS"],
          let retriesText = retryEnvironment["APPLE_GATEWAY_WRITE_RETRY_MAX_RETRIES"],
          let wait = Int64(waitText), let retries = Int64(retriesText) else {
      throw AdapterExecutionError(.invalidInput, "Apple write retry policy did not produce complete metadata")
    }
    prepared.addon.config?["writeRetry"] = .object([
      "initialWaitSeconds": .integer(wait), "maxRetries": .integer(retries)
    ])
  }
  return prepared
}
