import Foundation
import GatewaySDKKit
import RielaAddonSupport
import RielaCore
#if canImport(NotionGatewayCore)
import NotionGatewayCore
#endif

/// Role-scoped, linked SDK execution. Documents cannot widen reader capabilities.
enum BuiltinNotionGatewayAddon: String {
  case read = "riela/notion-gateway-read"
  case write = "riela/notion-gateway-write"

  var tier: String { self == .read ? "reader" : "writer" }

  private var operationCatalog: (() throws -> GatewaySchemaCatalog)? {
    #if canImport(NotionGatewayCore)
    let role: NotionRole = self == .read ? .reader : .writer
    return { NotionGatewaySDK(role: role).catalog }
    #else
    return nil
    #endif
  }

  var descriptor: LocalGatewayGraphQLDescriptor {
    LocalGatewayGraphQLDescriptor(
      providerName: "notion-gateway", payloadNamespaceKey: "notionGateway", tier: tier,
      acceptsVariables: true, isAllowedEnvironmentTarget: { $0 == "NOTION_API_KEY" }, catalog: operationCatalog, run: runner
    )
  }

  private var runner: LocalGatewayGraphQLRunner {
    #if canImport(NotionGatewayCore)
    let role: NotionRole = self == .read ? .reader : .writer
    return { _, document, variablesJSON, environment in
      let variables = try JSONDecoder().decode([String: NotionJSON].self, from: Data((variablesJSON ?? "{}").utf8))
      return await NotionGatewaySDK(role: role).execute(
        document: document, variables: variables, environment: environment
      ).rawOutput
    }
    #else
    return { _, _, _, _ in
      throw AdapterExecutionError(.policyBlocked, "notion-gateway requires macOS")
    }
    #endif
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeNotionGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinNotionGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    try await LocalGatewayGraphQLEngine(
      environment: environment, descriptor: operation.descriptor, runnerOverride: localGatewayGraphQLRunner,
      workingDirectory: workingDirectory
    ).execute(input, context: context)
  }
}
