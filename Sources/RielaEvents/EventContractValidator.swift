import Foundation
import RielaCore

public enum EventContractValidator {
  public static func validate(sources: [EventSourceContract], bindings: [EventBindingContract]) -> [EventValidationDiagnostic] {
    var diagnostics: [EventValidationDiagnostic] = []
    var sourceIds = Set<String>()
    var sourcesById: [String: EventSourceContract] = [:]
    var routePaths = Set<String>()
    for (index, source) in sources.enumerated() {
      if source.id.isEmpty || !sourceIds.insert(source.id).inserted {
        diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].id", message: "event source id must be unique and non-empty"))
      } else {
        sourcesById[source.id] = source
      }
      if source.kind == .webhook, source.routePath?.isEmpty != false {
        diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].path", message: "webhook path must start with / and contain no whitespace, ? or #"))
      }
      if source.kind == .chatSdk {
        if !isSupportedChatSDKProvider(source.provider) {
          diagnostics.append(.init(
            code: "INVALID_EVENT_SOURCE",
            path: "sources[\(index)].provider",
            message: "chat-sdk provider must be one of \(supportedChatSDKProviderNames)"
          ))
        }
        if !source.hasChatWebhook {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].webhook", message: "chat-sdk webhook is required"))
        }
        if !isValidChatSDKRelativePath(source.routePath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].webhook.path", message: "chat-sdk webhook path must be relative and contain no traversal, whitespace, ? or #"))
        }
        if source.secretEnv == nil && source.chatWebhookBearerTokenEnv == nil {
          diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: "sources[\(index)].webhook", message: "chat-sdk webhook must configure signingSecretEnv or bearerTokenEnv"))
        }
      }
      if let routePath = eventHTTPPath(for: source) {
        let routePathLabel = eventHTTPPathLabel(for: source, index: index)
        if !isValidHTTPPath(routePath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: routePathLabel, message: "event route path must start with / and contain no whitespace, ? or #"))
        }
        if !routePaths.insert(routePath).inserted {
          diagnostics.append(.init(code: "EVENT_ROUTE_CONFLICT", path: routePathLabel, message: "event route path conflicts with another source"))
        }
      }
      if let secretEnv = source.secretEnv, !isValidEnvironmentName(secretEnv) {
        diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: eventSecretPathLabel(for: source, index: index), message: "event secret must reference an environment variable name"))
      }
      if let bearerTokenEnv = source.chatWebhookBearerTokenEnv, !isValidEnvironmentName(bearerTokenEnv) {
        diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: "sources[\(index)].webhook.bearerTokenEnv", message: "bearer token must reference an environment variable name"))
      }
      if source.kind == .s3Repository {
        if source.bucket?.isEmpty != false {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].bucket", message: "bucket is required"))
        }
        if !source.hasEventReceiver {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].eventReceiver", message: "event receiver is required"))
        }
        if let eventReceiverMode = source.eventReceiverMode, eventReceiverMode != .webhookBridge {
          diagnostics.append(.init(
            code: "INVALID_EVENT_SOURCE",
            path: "sources[\(index)].eventReceiver.mode",
            message: "\(eventReceiverMode.rawValue) receiver mode is not supported"
          ))
        }
        if source.objectAccessMode != .metadataOnly {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].objectAccess.mode", message: "object access must explicitly be metadata-only"))
        }
        if let eventReceiverPath = source.eventReceiverPath, !isValidHTTPPath(eventReceiverPath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].eventReceiver.path", message: "event receiver path must start with / and contain no whitespace, ? or #"))
        }
        if let rootPrefix = source.rootPrefix, rootPrefix.isEmpty || rootPrefix.hasPrefix("/") || rootPrefix.contains("..") {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].rootPrefix", message: "root prefix must be a safe object-key prefix"))
        }
      }
    }
    for (index, binding) in bindings.enumerated() {
      if binding.id.isEmpty {
        diagnostics.append(.init(code: "INVALID_EVENT_BINDING", path: "bindings[\(index)].id", message: "event binding id is required"))
      }
      if !sourceIds.contains(binding.sourceId) {
        diagnostics.append(.init(code: "UNKNOWN_EVENT_SOURCE", path: "bindings[\(index)].sourceId", message: "event binding references an unknown source"))
      }
      if binding.execution?.allowsMissingWorkflowName != true && binding.workflowName?.isEmpty != false {
        diagnostics.append(.init(code: "INVALID_EVENT_WORKFLOW", path: "bindings[\(index)].workflowName", message: "workflowName is required unless execution.mode is supervisor-dispatch or schedule-registration"))
      }
      if binding.inputMapping.mode == .template, let template = binding.inputMapping.template {
        validateTemplateValue(template, path: "bindings[\(index)].inputMapping.template", diagnostics: &diagnostics)
      }
      if let outputDestinations = binding.outputDestinations {
        if outputDestinations.isEmpty || outputDestinations.contains(where: { $0.isEmpty }) {
          diagnostics.append(.init(code: "INVALID_EVENT_OUTPUT_DESTINATION", path: "bindings[\(index)].outputDestinations", message: "outputDestinations must be a non-empty string array when set"))
        }
      }
      validateChatSDKBindingCapabilities(binding, source: sourcesById[binding.sourceId], index: index, diagnostics: &diagnostics)
      validateMailboxBridge(binding, index: index, diagnostics: &diagnostics)
    }
    return diagnostics
  }

  public static func validate(envelope: ExternalEventEnvelope, sources: [EventSourceContract]) -> [EventValidationDiagnostic] {
    guard let source = sources.first(where: { $0.id == envelope.sourceId }) else {
      return [.init(code: "UNKNOWN_EVENT_SOURCE", path: "envelope.sourceId", message: "event envelope references an unknown source")]
    }
    if source.kind == .chatSdk, !supportedChatSDKEventTypes.contains(envelope.eventType) {
      return [.init(
        code: "INVALID_EVENT_ENVELOPE",
        path: "envelope.eventType",
        message: "chat-sdk provider '\(source.provider?.rawValue ?? "")' does not support event type '\(envelope.eventType.rawValue)'"
      )]
    }
    return []
  }

  private static let supportedChatSDKProviderNames = EventProvider.supportedChatSDKProviders
    .map(\.rawValue)
    .joined(separator: ", ")

  private static let supportedChatSDKEventTypes: [EventType] = [.chatMessage]

  private static func isSupportedChatSDKProvider(_ provider: EventProvider?) -> Bool {
    guard let provider else {
      return false
    }
    return provider.isSupportedChatSDKProvider
  }

  private static func validateChatSDKBindingCapabilities(
    _ binding: EventBindingContract,
    source: EventSourceContract?,
    index: Int,
    diagnostics: inout [EventValidationDiagnostic]
  ) {
    guard source?.kind == .chatSdk,
      isSupportedChatSDKProvider(source?.provider)
    else {
      return
    }
    let eventTypeChecks = [
      (binding.eventType, "bindings[\(index)].eventType"),
      (binding.match?.eventType, "bindings[\(index)].match.eventType")
    ]
    for (eventType, path) in eventTypeChecks {
      guard let eventType, !supportedChatSDKEventTypes.contains(eventType) else {
        continue
      }
      diagnostics.append(.init(
        code: "INVALID_EVENT_BINDING",
        path: path,
        message: "chat-sdk provider '\(source?.provider?.rawValue ?? "")' does not support event type '\(eventType.rawValue)'"
      ))
    }
  }

  private static func validateMailboxBridge(_ binding: EventBindingContract, index: Int, diagnostics: inout [EventValidationDiagnostic]) {
    guard let consumer = binding.mailboxBridge?.input?.consumer else {
      return
    }
    let mode = binding.execution?.mode
    let supervisedLike = mode == .supervised || mode == .supervisorDispatch
    switch consumer {
    case .supervisor where !supervisedLike:
      diagnostics.append(.init(
        code: "INVALID_EVENT_MAILBOX_BRIDGE",
        path: "bindings[\(index)].mailboxBridge.input.consumer",
        message: "mailboxBridge.input.consumer supervisor requires execution.mode supervised or supervisor-dispatch"
      ))
    case .directWorkflow where supervisedLike:
      diagnostics.append(.init(
        code: "INVALID_EVENT_MAILBOX_BRIDGE",
        path: "bindings[\(index)].mailboxBridge.input.consumer",
        message: "mailboxBridge.input.consumer direct-workflow cannot be used with execution.mode supervised or supervisor-dispatch"
      ))
    default:
      return
    }
  }

  private static func isValidEnvironmentName(_ value: String) -> Bool {
    value.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
  }

  private static func isValidHTTPPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.range(of: #"\s|\?|#"#, options: .regularExpression) == nil
  }

  private static func isValidChatSDKRelativePath(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else {
      return false
    }
    return !value.hasPrefix("/") && !value.contains("..") && value.range(of: #"\s|\?|#"#, options: .regularExpression) == nil
  }

  private static func eventHTTPPath(for source: EventSourceContract) -> String? {
    switch source.kind {
    case .webhook:
      return source.routePath
    case .s3Repository:
      return source.eventReceiverPath ?? defaultEventSourceHTTPPath(source)
    case .chatSdk:
      return chatSDKHTTPPath(source.routePath)
    default:
      return nil
    }
  }

  private static func eventHTTPPathLabel(for source: EventSourceContract, index: Int) -> String {
    switch source.kind {
    case .s3Repository:
      return "sources[\(index)].eventReceiver.path"
    case .chatSdk:
      return "sources[\(index)].webhook.path"
    default:
      return "sources[\(index)].path"
    }
  }

  private static func eventSecretPathLabel(for source: EventSourceContract, index: Int) -> String {
    switch source.kind {
    case .chatSdk:
      return "sources[\(index)].webhook.signingSecretEnv"
    default:
      return "sources[\(index)].secretEnv"
    }
  }

  private static func defaultEventSourceHTTPPath(_ source: EventSourceContract) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    return "/events/\(source.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? source.id)"
  }

  private static func chatSDKHTTPPath(_ rawPath: String?) -> String? {
    guard let rawPath, !rawPath.isEmpty else {
      return nil
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    let encodedSegments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
    return "/events/\(encodedSegments.joined(separator: "/"))"
  }

  private static func validateTemplateValue(_ value: JSONValue, path: String, diagnostics: inout [EventValidationDiagnostic]) {
    switch value {
    case let .string(string):
      validateTemplateString(string, path: path, diagnostics: &diagnostics)
    case let .array(values):
      for (index, value) in values.enumerated() {
        validateTemplateValue(value, path: "\(path)[\(index)]", diagnostics: &diagnostics)
      }
    case let .object(object):
      for (key, value) in object {
        validateTemplateValue(value, path: "\(path).\(key)", diagnostics: &diagnostics)
      }
    default:
      return
    }
  }

  private static func validateTemplateString(_ value: String, path: String, diagnostics: inout [EventValidationDiagnostic]) {
    let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#
    let regex = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    regex?.enumerateMatches(in: value, range: range) { match, _, _ in
      guard let match, match.numberOfRanges > 1, let refRange = Range(match.range(at: 1), in: value) else {
        return
      }
      let reference = String(value[refRange])
      if !reference.hasPrefix("event.") && !reference.hasPrefix("source.") && !reference.hasPrefix("binding.") {
        diagnostics.append(.init(code: "INVALID_EVENT_TEMPLATE", path: path, message: "unsupported template reference '\(reference)'"))
      }
    }
  }
}
