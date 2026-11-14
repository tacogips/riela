import RielaAddonSupport
import RielaCore
import RielaKaibaAddons

extension BuiltinGatewayRequestChecks {
  static func extendedIssues(_ addon: WorkflowNodeAddonRef, leaf: JSONObject) -> [WorkflowGatewayRequestIssue] {
    switch addon.name {
    case "riela/x-gateway-reader", "riela/x-gateway-read":
      return xReaderIssues(addon.name, leaf: leaf)
    case "riela/gmail-gateway-read":
      return gmailReaderIssues(addon.name, leaf: leaf)
    case "riela/google-service-gateway-read", "riela/google-service-gateway-write":
      return googleServiceIssues(addon.name, leaf: leaf, inputs: addon.inputs)
    default:
      guard KaibaAddonCatalog.handles(addon.name), leaf["arguments"] != nil else { return [] }
      return KaibaNestedArgumentRules.issues(addonName: addon.name, config: leaf, inputs: addon.inputs)
    }
  }

  private static func xReaderIssues(_ addonName: String, leaf: JSONObject) -> [WorkflowGatewayRequestIssue] {
    do {
      _ = try XGatewayProviderFailureMode.parse(leaf)
    } catch let error as AdapterExecutionError {
      return [issue("providerFailure", error.message)]
    } catch {
      return [issue("providerFailure", "config.providerFailure must be \"fail\" or \"output\"")]
    }

    let isEmbedded = addonName == "riela/x-gateway-reader"
    if !isEmbedded, leaf["operation"] == nil {
      do {
        try ContainerGatewayAddonExecutor.legacyModeIssue(config: leaf, addonName: addonName)
        return []
      } catch let error as AdapterExecutionError {
        return [issue("", error.message)]
      } catch {
        return [issue("", "\(addonName) config.queryTemplate is required; JSON arguments require operation")]
      }
    }

    let shape: XGatewayJSONShape?
    do {
      shape = try xGatewayJSONShape(config: leaf, addonName: addonName)
    } catch let error as AdapterExecutionError {
      return [issue("", error.message)]
    } catch {
      return [issue("", "\(addonName) JSON operation is invalid")]
    }

    guard let shape else {
      return []
    }
    if let operationNames = XGatewayOperationCatalog.queryOperationNames,
       !operationNames.contains(shape.operation) {
      return [issue("operation", "unknown operation '\(shape.operation)'")]
    }

    if !containsTemplate(leaf["arguments"]), !isExactPlaceholder(leaf["arguments"]) {
      do {
        guard let document = try xGatewayJSONDocument(config: leaf, variables: [:], addonName: addonName) else {
          return [issue("", "X JSON operation is missing")]
        }
        if isEmbedded { try xGatewayRejectHostMediaArguments(document) }
        if !isEmbedded, document.utf8.count > ContainerGatewayAddon.legacyDocumentByteLimit {
          return [issue("", "gateway JSON document exceeds the legacy container argument limit")]
        }
      } catch let error as AdapterExecutionError {
        let path = isEmbedded && error.message.contains("mediaRootDir") ? "arguments" : ""
        return [issue(path, error.message)]
      } catch {
        return [issue("", "\(addonName) JSON operation is invalid")]
      }
    } else if isEmbedded, shape.operation == "mediaRootDir" || containsMediaRootKey(leaf["arguments"])
      || containsMediaRootKey(leaf["select"]) || containsMediaRootPath(leaf["selection"]) {
      return [issue("arguments", "X reader does not accept mediaRootDir; media stays source-URL only")]
    }
    return []
  }

  private static func gmailReaderIssues(_ addonName: String, leaf: JSONObject) -> [WorkflowGatewayRequestIssue] {
    guard leaf["operation"] != nil else {
      do {
        try ContainerGatewayAddonExecutor.legacyModeIssue(config: leaf, addonName: addonName)
        return []
      } catch let error as AdapterExecutionError {
        return [issue("", error.message)]
      } catch {
        return [issue("", "\(addonName) config.queryTemplate is required; JSON arguments require operation")]
      }
    }
    guard let operation = stringValue(leaf["operation"]),
          let catalog = try? BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog?() else {
      return [issue("", "\(addonName) requires one literal operation without legacy query or command fields")]
    }
    if containsTemplate(leaf["operation"]) || containsTemplate(leaf["arguments"]) {
      guard catalog.operations.contains(where: { $0.name == operation }) else {
        return [issue("operation", "unknown operation '\(operation)'")]
      }
      for key in ["queryTemplate", "variablesTemplate", "command", "argsTemplate", "select"] where leaf[key] != nil {
        return [issue(key, "is not allowed in this mode")]
      }
      guard !isExactPlaceholder(leaf["arguments"]), case let .object(arguments)? = leaf["arguments"] else { return [] }
      return catalogArgumentNameIssues(arguments, operation: operation, catalog: catalog)
    }
    do {
      _ = try ContainerGatewayAddonExecutor.operationDocument(
        gateway: .gmailRead, config: leaf, variables: [:], addonName: addonName
      )
      return []
    } catch let error as AdapterExecutionError {
      return [issue("", error.message)]
    } catch {
      return [issue("", "\(addonName) JSON operation is invalid")]
    }
  }

  private static func googleServiceIssues(
    _ addonName: String,
    leaf: JSONObject,
    inputs: JSONObject?
  ) -> [WorkflowGatewayRequestIssue] {
    let capability: BuiltinGoogleServiceGatewayAddon = addonName == "riela/google-service-gateway-read" ? .read : .write
    do {
      try GoogleServiceGatewayAddonEngine.requestShapeIssue(
        capability: capability, config: leaf, inputs: inputs, addonName: addonName
      )
    } catch let error as AdapterExecutionError {
      return [issue("", error.message)]
    } catch {
      return [issue("", "\(addonName) request shape is invalid")]
    }
    guard leaf["arguments"] != nil, !containsTemplate(leaf["arguments"]), !isExactPlaceholder(leaf["arguments"]),
          let operation = stringValue(leaf["operation"]) else { return [] }
    do {
      let arguments = try renderGatewayJSONArguments(leaf["arguments"], variables: [:], addonName: addonName)
      let request = try GoogleServiceGatewayAddonEngine.parse(
        operation: operation, values: GatewayAddonValues(config: arguments, variables: [:]), addonName: addonName
      )
      if let error = request.deferredValueError { return [issue("arguments", error.message)] }
      return []
    } catch let error as AdapterExecutionError {
      return [issue("arguments", error.message)]
    } catch {
      return [issue("arguments", "\(addonName) arguments are invalid")]
    }
  }

  private static func containsMediaRootKey(_ value: JSONValue?) -> Bool {
    guard case let .object(fields)? = value else { return false }
    return fields.contains { key, child in key == "mediaRootDir" || containsMediaRootKey(child) }
  }

  private static func containsMediaRootPath(_ value: JSONValue?) -> Bool {
    guard case let .array(paths)? = value else { return false }
    return paths.contains { path in
      guard case let .string(text) = path else { return false }
      return text.split(separator: ".").contains("mediaRootDir")
    }
  }

  private static func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(text)? = value else { return nil }
    return text
  }

  private static func issue(_ path: String, _ message: String) -> WorkflowGatewayRequestIssue {
    WorkflowGatewayRequestIssue(relativePath: path, message: message)
  }
}
