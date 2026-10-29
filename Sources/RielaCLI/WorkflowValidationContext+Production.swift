import GatewaySDKKit
import RielaCore
#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif
#if canImport(GoogleDocumentsGatewayCore)
import GoogleDocumentsGatewayCore
#endif

extension WorkflowValidationContext {
  static func production() -> WorkflowValidationContext {
    WorkflowValidationContext(gatewayCatalog: productionGatewayCatalog, postprocessCompiler: { program in
      do {
        _ = try JSONDataTransform.compile(program)
        return nil
      } catch {
        return "invalid postprocess program: \(error)"
      }
    }, addonRequestChecker: { BuiltinGatewayRequestChecks.issues($0) })
  }

  private static func productionGatewayCatalog(
    _ provider: WorkflowGatewayProvider,
    _ tier: String
  ) -> WorkflowGatewayCatalogProjection? {
    do {
      let catalog: GatewaySchemaCatalog
      switch provider {
      case .wrike:
        let name = ["reader": "riela/wrike-gateway-read", "writer": "riela/wrike-gateway-write", "admin": "riela/wrike-gateway-admin"][tier]
        guard let name, let addon = BuiltinWrikeGatewayAddon(rawValue: name),
              let factory = addon.descriptor.catalog else { return nil }
        catalog = try factory()
      case .analytics:
        let name = ["reader": "riela/google-analytics-gateway-read", "writer": "riela/google-analytics-gateway-write", "admin": "riela/google-analytics-gateway-admin"][tier]
        guard let name, let addon = BuiltinGoogleAnalyticsGatewayAddon(rawValue: name),
              let factory = addon.descriptor.catalog else { return nil }
        catalog = try factory()
      case .gmail:
        let name = ["reader": "riela/gmail-gateway-reader", "draft": "riela/gmail-gateway-draft", "sender": "riela/gmail-gateway-sender"][tier]
        guard let name, let addon = BuiltinGmailGatewayCLIAddon(rawValue: name),
              let factory = addon.descriptor.catalog else { return nil }
        catalog = try factory()
      case .notion:
        let name = ["reader": "riela/notion-gateway-read", "writer": "riela/notion-gateway-write"][tier]
        guard let name, let addon = BuiltinNotionGatewayAddon(rawValue: name),
              let factory = addon.descriptor.catalog else { return nil }
        catalog = try factory()
      case .documents:
        #if canImport(GoogleDocumentsGatewayCore)
        let role: GatewayRole
        switch tier {
        case "docs-read": role = .init(service: .docs, accessMode: .read)
        case "docs-write": role = .init(service: .docs, accessMode: .write)
        case "sheets-read": role = .init(service: .sheets, accessMode: .read)
        case "sheets-write": role = .init(service: .sheets, accessMode: .write)
        case "drive-read": role = .init(service: .drive, accessMode: .read)
        case "drive-write": role = .init(service: .drive, accessMode: .write)
        default: return nil
        }
        catalog = GoogleDocumentsGatewaySDK(role: role).catalog
        #else
        return nil
        #endif
      case .apple:
        #if canImport(AppleGatewayCore)
        guard tier == "full" else { return nil }
        catalog = AppleGatewaySDK(role: .full).catalog
        #else
        return nil
        #endif
      }
      var operationNames = Set(catalog.operations.map(\.name))
      if provider == .notion, tier == "writer" { operationNames.insert("uploadLocalFile") }
      return WorkflowGatewayCatalogProjection(provider: provider, tier: tier, operationNames: operationNames)
    } catch {
      return nil
    }
  }
}
