import Foundation
import RielaAddonSupport
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

  /// The exact wrike-gateway credential contract. addon.env may only populate
  /// these target names, so a workflow cannot use the binding mechanism to
  /// inject arbitrary variables into the child process.
  static let allowedTargetEnvironmentNames: Set<String> = [
    "WRIKE_GATEWAY_API_CLIENT_ID",
    "WRIKE_GATEWAY_API_CLIENT_SECRET",
    "WRIKE_GATEWAY_ACCESS_TOKEN",
    "WRIKE_GATEWAY_API_BASE_URL",
    "WRIKE_GATEWAY_OAUTH_CALLBACK_PORT"
  ]

  var descriptor: LocalGatewayGraphQLCLIDescriptor {
    LocalGatewayGraphQLCLIDescriptor(
      providerName: "wrike-gateway",
      payloadNamespaceKey: "wrikeGateway",
      executableName: executableName,
      executableEnvironmentName: executableEnvironmentName,
      invocationStyle: .queryPositionalWithVariables,
      isAllowedEnvironmentTarget: { Self.allowedTargetEnvironmentNames.contains($0) }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeWrikeGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinWrikeGatewayAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try LocalGatewayGraphQLCLIEngine(environment: environment, descriptor: operation.descriptor)
      .execute(input, context: context)
  }
}
