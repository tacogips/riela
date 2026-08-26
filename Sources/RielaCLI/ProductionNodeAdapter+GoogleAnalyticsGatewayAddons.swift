import Foundation
import RielaAddonSupport
import RielaCore

/// Built-in add-ons that run the locally installed google-analytics-gateway
/// CLI tier binaries (GA4 Admin/Data APIs plus Tag Manager). Capability tiers
/// are separated at link boundaries in the gateway itself — the reader binary
/// physically contains no write or admin code — so each add-on pins one tier
/// and the workflow cannot escalate through inputs or payload data.
enum BuiltinGoogleAnalyticsGatewayAddon: String {
  case read = "riela/google-analytics-gateway-read"
  case write = "riela/google-analytics-gateway-write"
  case admin = "riela/google-analytics-gateway-admin"

  var executableName: String {
    switch self {
    case .read:
      "google-analytics-gateway-reader"
    case .write:
      "google-analytics-gateway-writer"
    case .admin:
      "google-analytics-gateway-admin"
    }
  }

  var executableEnvironmentName: String {
    switch self {
    case .read:
      "GOOGLE_ANALYTICS_GATEWAY_READER_BIN"
    case .write:
      "GOOGLE_ANALYTICS_GATEWAY_WRITER_BIN"
    case .admin:
      "GOOGLE_ANALYTICS_GATEWAY_ADMIN_BIN"
    }
  }

  /// The gateway's fixed non-interactive credential contract: with no config
  /// file a synthesized profile reads the access token from
  /// GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN; GOOGLE_ANALYTICS_GATEWAY_CONFIG
  /// selects a credential-profile file that itself names environment
  /// variables, never secret values.
  static let allowedTargetEnvironmentNames: Set<String> = [
    "GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN",
    "GOOGLE_ANALYTICS_GATEWAY_CONFIG"
  ]

  var descriptor: LocalGatewayGraphQLCLIDescriptor {
    LocalGatewayGraphQLCLIDescriptor(
      providerName: "google-analytics-gateway",
      payloadNamespaceKey: "googleAnalyticsGateway",
      executableName: executableName,
      executableEnvironmentName: executableEnvironmentName,
      invocationStyle: .queryPositionalWithVariables,
      isAllowedEnvironmentTarget: { Self.allowedTargetEnvironmentNames.contains($0) }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeGoogleAnalyticsGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGoogleAnalyticsGatewayAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try LocalGatewayGraphQLCLIEngine(environment: environment, descriptor: operation.descriptor)
      .execute(input, context: context)
  }
}
