import Foundation
import RielaAddonSupport
import RielaCore
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

/// Built-in add-ons that run the sibling wrike-gateway package's GraphQL
/// runtime inside this process. Capability boundaries (read / write / delete)
/// are enforced by the tier each add-on pins: the role and capability list go
/// to wrike-gateway's own `CapabilityRegistry`, which refuses a document
/// naming a capability outside that tier, so a workflow cannot widen the tier
/// through inputs or payload data.
enum BuiltinWrikeGatewayAddon: String {
  case read = "riela/wrike-gateway-read"
  case write = "riela/wrike-gateway-write"
  case admin = "riela/wrike-gateway-admin"

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

  /// The exact wrike-gateway credential contract. addon.env may only populate
  /// these target names, so a workflow cannot use the binding mechanism to
  /// inject arbitrary variables into the gateway.
  static let allowedTargetEnvironmentNames: Set<String> = [
    "WRIKE_GATEWAY_API_CLIENT_ID",
    "WRIKE_GATEWAY_API_CLIENT_SECRET",
    "WRIKE_GATEWAY_ACCESS_TOKEN",
    "WRIKE_GATEWAY_API_BASE_URL",
    "WRIKE_GATEWAY_OAUTH_CALLBACK_PORT"
  ]

  var descriptor: LocalGatewayGraphQLDescriptor {
    let role = role
    let capabilities = capabilities
    return LocalGatewayGraphQLDescriptor(
      providerName: "wrike-gateway",
      payloadNamespaceKey: "wrikeGateway",
      tier: role.executableName,
      acceptsVariables: true,
      isAllowedEnvironmentTarget: { Self.allowedTargetEnvironmentNames.contains($0) },
      run: { _, document, variablesJSON, environment in
        let frame = try GatewayComposition.makeCommandFrame(
          role: role,
          definitions: capabilities,
          environment: StaticEnvironmentReader(extra: environment)
        )
        var arguments = ["graphql", "query", document]
        if let variablesJSON {
          arguments += ["--variables", variablesJSON]
        }
        let outcome = await frame.run(arguments: arguments)
        guard !outcome.standardOutput.isEmpty else {
          throw AdapterExecutionError(
            .providerError,
            "wrike-gateway \(role.executableName) failed: \(appleGatewayCompactText(outcome.standardError))"
          )
        }
        return outcome.standardOutput
      }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeWrikeGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinWrikeGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    try await LocalGatewayGraphQLEngine(
      environment: environment,
      descriptor: operation.descriptor,
      runnerOverride: localGatewayGraphQLRunner
    ).execute(input, context: context)
  }
}
