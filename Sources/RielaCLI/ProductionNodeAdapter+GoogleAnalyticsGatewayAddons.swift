import Foundation
import GoogleAnalyticsGatewayAdmin
import GoogleAnalyticsGatewayCore
import GoogleAnalyticsGatewayRead
import GoogleAnalyticsGatewayWrite
import RielaAddonSupport
import RielaCore

/// Built-in add-ons that run the sibling google-analytics-gateway package's
/// GraphQL runtime inside this process (GA4 Admin/Data APIs plus Tag Manager).
/// Each add-on pins one tier: the role and capability list go to the gateway's
/// own `CapabilityRegistry`, which refuses a document naming a capability
/// outside that tier, so the workflow cannot escalate through inputs or
/// payload data.
enum BuiltinGoogleAnalyticsGatewayAddon: String {
  case read = "riela/google-analytics-gateway-read"
  case write = "riela/google-analytics-gateway-write"
  case admin = "riela/google-analytics-gateway-admin"

  var role: RoleDescriptor {
    switch self {
    case .read:
      .reader
    case .write:
      .writer
    case .admin:
      .admin
    }
  }

  var capabilities: [CapabilityDefinition] {
    switch self {
    case .read:
      ReadCapabilities.all
    case .write:
      WriteCapabilities.all
    case .admin:
      AdminCapabilities.all
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

  var descriptor: LocalGatewayGraphQLDescriptor {
    let role = role
    let capabilities = capabilities
    return LocalGatewayGraphQLDescriptor(
      providerName: "google-analytics-gateway",
      payloadNamespaceKey: "googleAnalyticsGateway",
      tier: role.executableName,
      acceptsVariables: true,
      isAllowedEnvironmentTarget: { Self.allowedTargetEnvironmentNames.contains($0) },
      run: { _, document, variablesJSON, environment in
        let frame = try GatewayComposition.makeCommandFrame(
          role: role,
          definitions: capabilities,
          environment: environment
        )
        var arguments = ["graphql", "query", document]
        if let variablesJSON {
          arguments += ["--variables", variablesJSON]
        }
        let outcome = await frame.run(arguments: arguments)
        guard !outcome.standardOutput.isEmpty else {
          throw AdapterExecutionError(
            .providerError,
            "google-analytics-gateway \(role.executableName) failed: \(appleGatewayCompactText(outcome.standardError))"
          )
        }
        return outcome.standardOutput
      }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeGoogleAnalyticsGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGoogleAnalyticsGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    try await LocalGatewayGraphQLEngine(
      environment: environment,
      descriptor: operation.descriptor,
      runnerOverride: localGatewayGraphQLRunner
    ).execute(input, context: context)
  }
}
