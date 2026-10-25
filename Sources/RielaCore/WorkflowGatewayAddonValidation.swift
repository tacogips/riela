import Foundation

public enum WorkflowGatewayProvider: String, CaseIterable, Sendable {
  case wrike = "wrike-gateway"
  case analytics = "google-analytics-gateway"
  case gmail = "gmail-gateway"
  case notion = "notion-gateway"
  case documents = "google-documents-gateway"
  case apple = "apple-gateway"

  public var tiers: Set<String> {
    switch self {
    case .wrike, .analytics: ["reader", "writer", "admin"]
    case .notion: ["reader", "writer"]
    case .gmail: ["reader", "draft", "sender", "threads", "message-box"]
    case .documents: ["docs-read", "docs-write", "sheets-read", "sheets-write", "drive-read", "drive-write"]
    case .apple: ["full", "reader"]
    }
  }
}

public struct WorkflowGatewayCatalogProjection: Sendable {
  public let provider: WorkflowGatewayProvider
  public let tier: String
  public let operationNames: Set<String>

  public init(provider: WorkflowGatewayProvider, tier: String, operationNames: Set<String>) {
    self.provider = provider
    self.tier = tier
    self.operationNames = operationNames
  }
}

public struct WorkflowGatewayRequestIssue: Equatable, Sendable {
  public var relativePath: String
  public var message: String

  public init(relativePath: String, message: String) {
    self.relativePath = relativePath
    self.message = message
  }
}

public struct WorkflowValidationContext: Sendable {
  public var gatewayCatalog: (@Sendable (WorkflowGatewayProvider, String) -> WorkflowGatewayCatalogProjection?)?
  public var postprocessCompiler: (@Sendable (JSONValue) -> String?)?
  public var addonRequestChecker: (@Sendable (WorkflowNodeAddonRef) -> [WorkflowGatewayRequestIssue])?

  public init(
    gatewayCatalog: (@Sendable (WorkflowGatewayProvider, String) -> WorkflowGatewayCatalogProjection?)? = nil,
    postprocessCompiler: (@Sendable (JSONValue) -> String?)? = nil,
    addonRequestChecker: (@Sendable (WorkflowNodeAddonRef) -> [WorkflowGatewayRequestIssue])? = nil
  ) {
    self.gatewayCatalog = gatewayCatalog
    self.postprocessCompiler = postprocessCompiler
    self.addonRequestChecker = addonRequestChecker
  }
}

private let graphQLAddons: [String: (WorkflowGatewayProvider, String)] = [
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

private let documentAddons: [String: String] = [
  "riela/google-docs-gateway-read": "docs-read",
  "riela/google-docs-gateway-write": "docs-write",
  "riela/google-sheet-gateway-read": "sheets-read",
  "riela/google-sheet-gateway-write": "sheets-write",
  "riela/google-drive-gateway-read": "drive-read",
  "riela/google-drive-gateway-write": "drive-write"
]

func validateGatewayAddon(
  _ addon: WorkflowNodeAddonRef,
  path: String,
  context: WorkflowValidationContext
) -> [WorkflowValidationDiagnostic] {
  let config = addon.config ?? [:]
  let effective: JSONObject
  if addon.name == "riela/apple-gateway-graphql" || addon.name == "riela/apple-gateway-schema" {
    effective = config.merging(addon.inputs ?? [:]) { _, input in input }
  } else {
    effective = config
  }
  let fieldPath = "\(path).addon.config"
  var diagnostics: [WorkflowValidationDiagnostic] = []
  if addon.name.hasPrefix("riela/") || addon.name.hasPrefix("kaiba/"),
     let postprocess = addon.config?["postprocess"],
     !containsTemplatePlaceholder(postprocess),
     let message = context.postprocessCompiler?(postprocess) {
    diagnostics.append(gatewayError("\(fieldPath).postprocess", message))
  }
  if let (provider, tier) = graphQLAddons[addon.name] {
    validateGatewayModes(effective, passthrough: "queryTemplate", provider: provider, tier: tier,
                         path: fieldPath, context: context, diagnostics: &diagnostics)
  } else if let tier = documentAddons[addon.name] {
    validateGatewayModes(effective, passthrough: "command", provider: .documents, tier: tier,
                         path: fieldPath, context: context, diagnostics: &diagnostics)
  } else if addon.name == "riela/apple-gateway-graphql" {
    validateAppleGateway(effective, path: fieldPath, context: context, diagnostics: &diagnostics)
    if addon.config?["binaryPath"] != nil {
      diagnostics.append(gatewayError("\(fieldPath).binaryPath", "is not allowed"))
    }
    if addon.env?.isEmpty == false {
      diagnostics.append(gatewayError("\(path).addon.env", "is not allowed"))
    }
  } else if addon.name == "riela/gateway-schema" {
    validateGatewaySchema(effective, path: fieldPath, diagnostics: &diagnostics)
  } else if addon.name == "riela/apple-gateway-schema" {
    validateGatewaySearchOptions(effective, path: fieldPath, diagnostics: &diagnostics)
  }
  if diagnostics.isEmpty,
     addon.name.hasPrefix("riela/") || addon.name.hasPrefix("kaiba/"),
     let issues = context.addonRequestChecker?(addon) {
    diagnostics.append(contentsOf: issues.map { issue in
      let issuePath = issue.relativePath.isEmpty ? fieldPath : "\(fieldPath).\(issue.relativePath)"
      return gatewayError(issuePath, issue.message)
    })
  }
  return diagnostics
}

private func gatewayError(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
  WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
}

private func containsTemplatePlaceholder(_ value: JSONValue) -> Bool {
  switch value {
  case let .string(text): text.contains("{{")
  case let .array(values): values.contains(where: containsTemplatePlaceholder)
  case let .object(values): values.values.contains(where: containsTemplatePlaceholder)
  default: false
  }
}

private func requiredString(_ value: JSONValue?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) -> String? {
  guard case let .string(text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    diagnostics.append(gatewayError(path, "must be a non-empty string"))
    return nil
  }
  return text
}

private func literalOperation(
  _ value: JSONValue?, path: String, commandOperation: Bool = false,
  diagnostics: inout [WorkflowValidationDiagnostic]
) -> String? {
  guard let operation = requiredString(value, path: path, diagnostics: &diagnostics) else { return nil }
  let pattern = commandOperation ? #"^[A-Za-z][A-Za-z0-9_-]*( [A-Za-z][A-Za-z0-9_-]*)*$"# : #"^[_A-Za-z][_0-9A-Za-z]*$"#
  if operation.utf8.count > 256 || operation.contains("{{") || operation.range(of: pattern, options: .regularExpression) == nil {
    diagnostics.append(gatewayError(path, "must be a literal catalog operation name"))
    return nil
  }
  return operation
}

private func requireObject(_ value: JSONValue?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard case .object? = value else {
    diagnostics.append(gatewayError(path, "must be an object"))
    return
  }
}

private func requireArguments(_ value: JSONValue?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  // Exact references preserve the object's type; interpolation remains a string.
  if case let .string(template)? = value,
     template.range(of: #"^\s*\{\{\s*[a-zA-Z0-9_.-]+\s*\}\}\s*$"#, options: .regularExpression) != nil {
    return
  }
  requireObject(value, path: path, diagnostics: &diagnostics)
}

/// Runtime treats a missing `arguments` value as an empty object
/// (`renderGatewayJSONArguments`), so only a present non-object is an error.
private func optionalArgumentsObject(_ values: JSONObject, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  if let arguments = values["arguments"] {
    requireArguments(arguments, path: "\(path).arguments", diagnostics: &diagnostics)
  }
}

private func forbid(_ keys: [String], in values: JSONObject, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  for key in keys where values[key] != nil {
    diagnostics.append(gatewayError("\(path).\(key)", "is not allowed in this mode"))
  }
}

private func validateSelection(_ value: JSONValue, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  switch value {
  case let .string(raw) where raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"):
    if raw.utf8.count > 65_536 || raw.contains("{{") {
      diagnostics.append(gatewayError(path, "must be a bounded literal selection set"))
    }
  case let .array(fields):
    if fields.isEmpty || fields.count > 256 {
      diagnostics.append(gatewayError(path, "must contain 1 to 256 dot-path strings"))
    }
    for (index, field) in fields.enumerated() {
      guard case let .string(text) = field, text.utf8.count <= 4_096,
            text.range(of: #"^[_A-Za-z][_0-9A-Za-z]*(\.[_A-Za-z][_0-9A-Za-z]*)*$"#, options: .regularExpression) != nil else {
        diagnostics.append(gatewayError("\(path)[\(index)]", "must be a literal field path of at most 4096 bytes"))
        continue
      }
    }
  default:
    diagnostics.append(gatewayError(path, "must be a brace-leading raw string or an array of dot-path strings"))
  }
}

private func validateGatewayModes(
  _ values: JSONObject,
  passthrough: String,
  provider: WorkflowGatewayProvider,
  tier: String,
  path: String,
  context: WorkflowValidationContext,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let hasOperation = values["operation"] != nil
  let hasPassthrough = values[passthrough] != nil
  if hasOperation == hasPassthrough {
    diagnostics.append(gatewayError(path, "must specify exactly one of \(passthrough) or operation"))
  }
  if hasOperation {
    let operation = literalOperation(values["operation"], path: "\(path).operation", commandOperation: passthrough == "command", diagnostics: &diagnostics)
    optionalArgumentsObject(values, path: path, diagnostics: &diagnostics)
    forbid(["queryTemplate", "variablesTemplate", "command", "argsTemplate", "select"], in: values,
           path: path, diagnostics: &diagnostics)
    if passthrough == "command" {
      forbid(["selection"], in: values, path: path, diagnostics: &diagnostics)
    } else if let selection = values["selection"] {
      validateSelection(selection, path: "\(path).selection", diagnostics: &diagnostics)
    }
    validateKnownOperation(operation, provider: provider, tier: tier, path: path, context: context,
                           diagnostics: &diagnostics)
  } else {
    _ = requiredString(values[passthrough], path: "\(path).\(passthrough)", diagnostics: &diagnostics)
    forbid(["arguments", "selection"], in: values, path: path, diagnostics: &diagnostics)
    if passthrough == "command" {
      if let args = values["argsTemplate"] {
        requireObject(args, path: "\(path).argsTemplate", diagnostics: &diagnostics)
      }
    } else if let variables = values["variablesTemplate"] {
      requireObject(variables, path: "\(path).variablesTemplate", diagnostics: &diagnostics)
      if provider == .gmail {
        diagnostics.append(gatewayError("\(path).variablesTemplate", "is not supported; use operation with arguments"))
      }
    }
  }
}

private func sharedPrefixLength(_ lhs: String, _ rhs: String) -> Int {
  zip(lhs.lowercased(), rhs.lowercased()).prefix { $0 == $1 }.count
}

private func validateKnownOperation(
  _ operation: String?,
  provider: WorkflowGatewayProvider,
  tier: String,
  path: String,
  context: WorkflowValidationContext,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let operation, let catalog = context.gatewayCatalog?(provider, tier),
        !catalog.operationNames.contains(operation) else { return }
  let suggestions = catalog.operationNames.sorted { lhs, rhs in
    let lhsScore = sharedPrefixLength(lhs, operation)
    let rhsScore = sharedPrefixLength(rhs, operation)
    return lhsScore == rhsScore ? lhs < rhs : lhsScore > rhsScore
  }.prefix(3)
  diagnostics.append(gatewayError("\(path).operation", "unknown operation '\(operation)'; closest: \(suggestions.joined(separator: ", "))"))
}

private func validateAppleGateway(
  _ values: JSONObject,
  path: String,
  context: WorkflowValidationContext,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let passthroughKeys = ["queryFile", "query", "variablesFile", "variables"]
  if values["operation"] != nil {
    let operation = literalOperation(values["operation"], path: "\(path).operation", diagnostics: &diagnostics)
    optionalArgumentsObject(values, path: path, diagnostics: &diagnostics)
    forbid(passthroughKeys + ["queryTemplate", "variablesTemplate", "command", "argsTemplate", "select"], in: values, path: path, diagnostics: &diagnostics)
    if let selection = values["selection"] {
      validateSelection(selection, path: "\(path).selection", diagnostics: &diagnostics)
    }
    validateKnownOperation(operation, provider: .apple, tier: "full", path: path, context: context,
                           diagnostics: &diagnostics)
  } else {
    forbid(["arguments", "selection"], in: values, path: path, diagnostics: &diagnostics)
    if values["queryFile"] == nil, values["query"] == nil {
      diagnostics.append(gatewayError(path, "requires queryFile or query"))
    }
    let activeKeys = [values["queryFile"] == nil ? "query" : "queryFile",
                      values["variablesFile"] == nil ? "variables" : "variablesFile"]
    for key in activeKeys {
      if let value = values[key] {
        if key == "variables", case .object = value {
          continue
        }
        _ = requiredString(value, path: "\(path).\(key)", diagnostics: &diagnostics)
      }
    }
  }
}

private func validateGatewaySchema(_ values: JSONObject, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  let gateway = requiredString(values["gateway"], path: "\(path).gateway", diagnostics: &diagnostics)
  let tier = requiredString(values["tier"], path: "\(path).tier", diagnostics: &diagnostics)
  if let gateway, let provider = WorkflowGatewayProvider(rawValue: gateway) {
    if let tier, !provider.tiers.contains(tier) {
      diagnostics.append(gatewayError("\(path).tier", "unknown tier '\(tier)'; known: \(provider.tiers.sorted().joined(separator: ", "))"))
    }
  } else if let gateway {
    diagnostics.append(gatewayError("\(path).gateway", "unknown gateway '\(gateway)'; known: \(WorkflowGatewayProvider.allCases.map(\.rawValue).sorted().joined(separator: ", "))"))
  }
  validateGatewaySearchOptions(values, path: path, diagnostics: &diagnostics)
}

private func validateGatewaySearchOptions(_ values: JSONObject, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  if let pattern = values["pattern"], case .string = pattern {} else if values["pattern"] != nil {
    diagnostics.append(gatewayError("\(path).pattern", "must be a string"))
  }
  let kinds = Set(["query", "mutation", "command", "object", "inputObject", "enumeration", "scalar"])
  if let value = values["kinds"] {
    if case let .array(elements) = value {
      for (index, element) in elements.enumerated() {
        guard case let .string(kind) = element, kinds.contains(kind) else {
          diagnostics.append(gatewayError("\(path).kinds[\(index)]", "must be a known definition kind"))
          continue
        }
      }
    } else {
      diagnostics.append(gatewayError("\(path).kinds", "must be an array"))
    }
  }
  if let value = values["includeReferencedTypes"], case .bool = value {} else if values["includeReferencedTypes"] != nil {
    diagnostics.append(gatewayError("\(path).includeReferencedTypes", "must be a Boolean"))
  }
  if let value = values["limit"], case let .integer(number) = value, number > 0 {} else if values["limit"] != nil {
    diagnostics.append(gatewayError("\(path).limit", "must be a positive integer"))
  }
}
