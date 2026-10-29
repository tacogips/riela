import Foundation
import GatewaySDKKit
#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif
#if canImport(GoogleDocumentsGatewayCore)
import GoogleDocumentsGatewayCore
#endif
import RielaCore

/// Pure request checks shared by production workflow validation and runtime builders.
enum BuiltinGatewayRequestChecks {
  static func issues(_ addon: WorkflowNodeAddonRef) -> [WorkflowGatewayRequestIssue] {
    let leaf = leafConfig(addon)
    guard leaf["operation"] != nil else { return extendedIssues(addon, leaf: leaf) }

    if let (provider, tier) = graphQLAddons[addon.name] {
      if addon.name == "riela/notion-gateway-write", leaf["operation"] == .string("uploadLocalFile") {
        return localFileUploadIssues(addonName: addon.name, leaf: leaf)
      }
      guard let catalog = graphQLCatalog(provider: provider, tier: tier) else { return [] }
      return operationIssues(addonName: addon.name, leaf: leaf, catalog: catalog)
    }
    if addon.name == "riela/apple-gateway-graphql" {
      guard addon.inputs?.isEmpty != false else { return [] }
      #if canImport(AppleGatewayCore)
      return operationIssues(
        addonName: addon.name,
        leaf: leaf,
        catalog: AppleGatewaySDK(role: .full).catalog,
        argumentsAlreadyRendered: true
      )
      #else
      return []
      #endif
    }
    if let tier = documentAddons[addon.name] {
      #if canImport(GoogleDocumentsGatewayCore)
      guard let role = documentRole(tier) else { return [] }
      let catalog = GoogleDocumentsGatewaySDK(role: role).catalog
      if isExactPlaceholder(leaf["arguments"]) { return [] }
      if containsTemplate(leaf["arguments"]) {
        guard case let .object(arguments)? = leaf["arguments"] else { return [] }
        return catalogArgumentNameIssues(arguments, operation: stringValue(leaf["operation"]) ?? "", catalog: catalog)
      }
      do {
        _ = try GoogleDocumentsGatewayAddonEngine.operationArgv(
          config: leaf, variables: [:], addonName: addon.name, role: role
        )
        return []
      } catch let error as AdapterExecutionError {
        return [WorkflowGatewayRequestIssue(relativePath: "", message: error.message)]
      } catch {
        return [WorkflowGatewayRequestIssue(relativePath: "", message: "\(addon.name) JSON operation is invalid")]
      }
      #else
      return []
      #endif
    }
    return extendedIssues(addon, leaf: leaf)
  }

  private static func localFileUploadIssues(addonName: String, leaf: JSONObject) -> [WorkflowGatewayRequestIssue] {
    if isExactPlaceholder(leaf["arguments"]) { return [] }
    guard case let .object(arguments)? = leaf["arguments"] else {
      return [WorkflowGatewayRequestIssue(relativePath: "arguments", message: "must be an object")]
    }
    let supported: Set<String> = ["path", "filename", "contentType", "kind", "caption"]
    var issues = arguments.keys.sorted().compactMap { key -> WorkflowGatewayRequestIssue? in
      guard !supported.contains(key) else { return nil }
      return WorkflowGatewayRequestIssue(relativePath: "arguments.\(key)", message: "is not an argument of operation 'uploadLocalFile'")
    }
    if arguments["path"] == nil {
      issues.append(WorkflowGatewayRequestIssue(relativePath: "arguments", message: "is missing required argument 'path'"))
    }
    if case let .string(kind)? = arguments["kind"], kind != "image", kind != "file" {
      issues.append(WorkflowGatewayRequestIssue(relativePath: "arguments.kind", message: "must be image or file"))
    }
    return issues
  }

  static func leafConfig(_ addon: WorkflowNodeAddonRef) -> JSONObject {
    var config = addon.config ?? [:]
    config.removeValue(forKey: "postprocess")
    return config
  }

  static func containsTemplate(_ value: JSONValue?) -> Bool {
    guard let value else { return false }
    switch value {
    case let .string(text):
      return text.contains("{{")
    case let .array(values):
      return values.contains(where: { containsTemplate($0) })
    case let .object(values):
      return values.contains { key, value in key.contains("{{") || containsTemplate(value) }
    default:
      return false
    }
  }

  static func isExactPlaceholder(_ value: JSONValue?) -> Bool {
    guard case let .string(template)? = value else { return false }
    return template.range(of: #"^\s*\{\{\s*[a-zA-Z0-9_.-]+\s*\}\}\s*$"#, options: .regularExpression) != nil
  }

  static func catalogArgumentNameIssues(
    _ arguments: JSONObject,
    operation: String,
    catalog: GatewaySchemaCatalog
  ) -> [WorkflowGatewayRequestIssue] {
    guard let catalogOperation = catalog.operations.first(where: { $0.name == operation }) else { return [] }
    let knownNames = Set(catalogOperation.arguments.map(\.name))
    var issues = arguments.keys.sorted().compactMap { key -> WorkflowGatewayRequestIssue? in
      guard !knownNames.contains(key) else { return nil }
      return WorkflowGatewayRequestIssue(
        relativePath: "arguments.\(key)",
        message: "is not an argument of operation '\(operation)'"
      )
    }
    for argument in catalogOperation.arguments where argument.isRequired && arguments[argument.name] == nil {
      issues.append(WorkflowGatewayRequestIssue(
        relativePath: "arguments",
        message: "is missing required argument '\(argument.name)'"
      ))
    }
    return issues
  }

  private static let graphQLAddons: [String: (WorkflowGatewayProvider, String)] = [
    "riela/wrike-gateway-read": (.wrike, "reader"),
    "riela/wrike-gateway-write": (.wrike, "writer"),
    "riela/wrike-gateway-admin": (.wrike, "admin"),
    "riela/google-analytics-gateway-read": (.analytics, "reader"),
    "riela/google-analytics-gateway-write": (.analytics, "writer"),
    "riela/google-analytics-gateway-admin": (.analytics, "admin"),
    "riela/gmail-gateway-reader": (.gmail, "reader"),
    "riela/gmail-gateway-draft": (.gmail, "draft"),
    "riela/gmail-gateway-sender": (.gmail, "sender"),
    "riela/notion-gateway-read": (.notion, "reader"),
    "riela/notion-gateway-write": (.notion, "writer")
  ]

  private static let documentAddons: [String: String] = [
    "riela/google-docs-gateway-read": "docs-read",
    "riela/google-docs-gateway-write": "docs-write",
    "riela/google-sheet-gateway-read": "sheets-read",
    "riela/google-sheet-gateway-write": "sheets-write",
    "riela/google-drive-gateway-read": "drive-read",
    "riela/google-drive-gateway-write": "drive-write"
  ]

  private static func operationIssues(
    addonName: String,
    leaf: JSONObject,
    catalog: GatewaySchemaCatalog,
    argumentsAlreadyRendered: Bool = false
  ) -> [WorkflowGatewayRequestIssue] {
    if isExactPlaceholder(leaf["arguments"]) { return [] }
    if containsTemplate(leaf["arguments"]) {
      guard case let .object(arguments)? = leaf["arguments"] else { return [] }
      return catalogArgumentNameIssues(
        arguments,
        operation: stringValue(leaf["operation"]) ?? "",
        catalog: catalog
      )
    }
    do {
      _ = try BuiltinGatewayJSONRequest.document(
        config: leaf,
        variables: [:],
        catalog: catalog,
        addonName: addonName,
        argumentsAlreadyRendered: argumentsAlreadyRendered
      )
      return []
    } catch let error as AdapterExecutionError {
      return [WorkflowGatewayRequestIssue(relativePath: "", message: error.message)]
    } catch {
      return [WorkflowGatewayRequestIssue(relativePath: "", message: "\(addonName) JSON operation is invalid")]
    }
  }

  private static func graphQLCatalog(provider: WorkflowGatewayProvider, tier: String) -> GatewaySchemaCatalog? {
    do {
      switch provider {
      case .wrike:
        guard let addon = BuiltinWrikeGatewayAddon(rawValue: graphQLName(provider, tier)),
              let factory = addon.descriptor.catalog else { return nil }
        return try factory()
      case .analytics:
        guard let addon = BuiltinGoogleAnalyticsGatewayAddon(rawValue: graphQLName(provider, tier)),
              let factory = addon.descriptor.catalog else { return nil }
        return try factory()
      case .gmail:
        guard let addon = BuiltinGmailGatewayCLIAddon(rawValue: graphQLName(provider, tier)),
              let factory = addon.descriptor.catalog else { return nil }
        return try factory()
      case .notion:
        guard let addon = BuiltinNotionGatewayAddon(rawValue: graphQLName(provider, tier)),
              let factory = addon.descriptor.catalog else { return nil }
        return try factory()
      case .documents, .apple:
        return nil
      }
    } catch {
      return nil
    }
  }

  private static func graphQLName(_ provider: WorkflowGatewayProvider, _ tier: String) -> String {
    switch (provider, tier) {
    case (.wrike, "reader"): "riela/wrike-gateway-read"
    case (.wrike, "writer"): "riela/wrike-gateway-write"
    case (.wrike, "admin"): "riela/wrike-gateway-admin"
    case (.analytics, "reader"): "riela/google-analytics-gateway-read"
    case (.analytics, "writer"): "riela/google-analytics-gateway-write"
    case (.analytics, "admin"): "riela/google-analytics-gateway-admin"
    case (.gmail, "reader"): "riela/gmail-gateway-reader"
    case (.gmail, "draft"): "riela/gmail-gateway-draft"
    case (.gmail, "sender"): "riela/gmail-gateway-sender"
    case (.notion, "reader"): "riela/notion-gateway-read"
    case (.notion, "writer"): "riela/notion-gateway-write"
    default: ""
    }
  }

  #if canImport(GoogleDocumentsGatewayCore)
  private static func documentRole(_ tier: String) -> GatewayRole? {
    switch tier {
    case "docs-read": GatewayRole(service: .docs, accessMode: .read)
    case "docs-write": GatewayRole(service: .docs, accessMode: .write)
    case "sheets-read": GatewayRole(service: .sheets, accessMode: .read)
    case "sheets-write": GatewayRole(service: .sheets, accessMode: .write)
    case "drive-read": GatewayRole(service: .drive, accessMode: .read)
    case "drive-write": GatewayRole(service: .drive, accessMode: .write)
    default: nil
    }
  }
  #endif

  private static func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(text)? = value else { return nil }
    return text
  }
}
