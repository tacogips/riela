import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeAppleNotificationsList(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    let engine = AppleGatewayNotificationsEngine(environment: environment)
    return try engine.execute(.list, input: input, context: context)
  }

  func executeAppleNotificationPost(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    let engine = AppleGatewayNotificationsEngine(environment: environment)
    return try engine.execute(.post, input: input, context: context)
  }

  func executeAppleNotificationsDismiss(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    let engine = AppleGatewayNotificationsEngine(environment: environment)
    return try engine.execute(.dismiss, input: input, context: context)
  }
}

private enum AppleGatewayNotificationsOperation {
  case list
  case post
  case dismiss
}

private struct AppleGatewayNotificationsEngine {
  private static let defaultFirst = 25
  private static let maxFirst = 100
  private static let maxWaitSeconds = 300
  private static let allowedSources = ["GATEWAY_HELPER", "SYSTEM_DB"]

  var environment: [String: String]

  func execute(
    _ operation: AppleGatewayNotificationsOperation,
    input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: config,
      environment: environment
    ).resolvedBinary()
    let document = try graphQLDocument(operation: operation, input: input, config: config, variables: variables)
    let processOutput: AppleGatewayProcessOutput
    do {
      processOutput = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
        executablePath: resolvedBinary.path,
        arguments: ["graphql", "--query", document],
        deadline: context.deadline
      )
    } catch let error as AdapterExecutionError where error.code == .providerError {
      throw AdapterExecutionError(error.code, notificationGuidanceMessage(error.message))
    }

    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      let errors = appleGatewayCompactText(envelope.errors.joined(separator: "; "))
      throw AdapterExecutionError(
        .providerError,
        notificationGuidanceMessage("\(input.addon.name) GraphQL errors: \(errors)")
      )
    }

    switch operation {
    case .list:
      return try listOutput(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    case .post:
      return try postOutput(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    case .dismiss:
      return try dismissOutput(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    }
  }

  private func graphQLDocument(
    operation: AppleGatewayNotificationsOperation,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> String {
    switch operation {
    case .list:
      return try listDocument(input: input, config: config, variables: variables)
    case .post:
      return try postDocument(input: input, config: config, variables: variables)
    case .dismiss:
      return try dismissDocument(input: input, config: config, variables: variables).document
    }
  }

  private func listDocument(input: WorkflowAddonExecutionInput, config: JSONObject, variables: JSONObject) throws -> String {
    var fields = ["first: \(try intField("first", input: input, config: config, variables: variables, defaultValue: Self.defaultFirst, range: 1...Self.maxFirst))"]
    if let source = stringField("source", config: config, variables: variables) {
      guard Self.allowedSources.contains(source) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) source must be GATEWAY_HELPER or SYSTEM_DB")
      }
      fields.append("source: \(source)")
    }
    appendStringField("appBundleId", config: config, variables: variables, to: &fields)
    appendStringField("deliveredAfter", config: config, variables: variables, to: &fields)
    appendStringField("deliveredBefore", config: config, variables: variables, to: &fields)
    appendStringField("after", config: config, variables: variables, to: &fields)
    return """
    query RielaAppleNotificationsList {
      notifications(input: {\(fields.joined(separator: ", "))}) {
        totalCount
        pageInfo {
          hasNextPage
          endCursor
        }
        edges {
          cursor
          node {
            id
            source
            appBundleId
            title
            subtitle
            body
            deliveredAt
          }
        }
      }
    }
    """
  }

  private func postDocument(input: WorkflowAddonExecutionInput, config: JSONObject, variables: JSONObject) throws -> String {
    guard let title = nonBlankStringField("title", config: config, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) title is required")
    }
    var fields = ["title: \(appleGatewayGraphQLString(title))"]
    appendStringField("subtitle", config: config, variables: variables, to: &fields)
    appendStringField("body", config: config, variables: variables, to: &fields)
    if let sound = try optionalBool("sound", input: input, config: config, variables: variables) {
      fields.append("sound: \(sound ? "true" : "false")")
    }
    if let actions = try stringArrayField("actions", input: input, config: config, variables: variables) {
      let renderedActions = actions.map(appleGatewayGraphQLString).joined(separator: ", ")
      fields.append("actions: [\(renderedActions)]")
    }
    if let allowReply = try optionalBool("allowReply", input: input, config: config, variables: variables) {
      fields.append("allowReply: \(allowReply ? "true" : "false")")
    }
    if let waitSeconds = try optionalInt("waitSeconds", input: input, config: config, variables: variables, range: 0...Self.maxWaitSeconds) {
      fields.append("waitSeconds: \(waitSeconds)")
    }
    if let allowFallback = try optionalBool("allowFallback", input: input, config: config, variables: variables) {
      fields.append("allowFallback: \(allowFallback ? "true" : "false")")
    }
    return """
    mutation RielaAppleNotificationPost {
      postNotification(input: {\(fields.joined(separator: ", "))}) {
        id
        delivered
        usedFallback
        activation {
          kind
          actionLabel
          replyText
        }
      }
    }
    """
  }

  private func dismissDocument(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> AppleNotificationsDismissDocument {
    let ids = try stringArrayField("ids", input: input, config: config, variables: variables)?
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty } ?? []
    let all = try optionalBool("all", input: input, config: config, variables: variables) ?? false
    let hasIDs = !ids.isEmpty
    guard hasIDs != all else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires exactly one of non-empty ids or all: true")
    }
    if all {
      return AppleNotificationsDismissDocument(
        mode: "all",
        document: """
        mutation RielaAppleNotificationsDismissAll {
          dismissAllGatewayNotifications {
            dismissedCount
          }
        }
        """
      )
    }
    let renderedIds = ids.map(appleGatewayGraphQLString).joined(separator: ", ")
    return AppleNotificationsDismissDocument(
      mode: "ids",
      document: """
      mutation RielaAppleNotificationsDismiss {
        dismissNotifications(ids: [\(renderedIds)]) {
          dismissedCount
        }
      }
      """
    )
  }

  private func listOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    let notificationsPayload = try AppleGatewayNotificationsPayload(data: envelope.data, addonName: input.addon.name)
    let requestId = envelope.requestId ?? ""
    let appleNotifications: JSONObject = [
      "notifications": .array(notificationsPayload.notifications.map(JSONValue.object)),
      "pageInfo": .object(notificationsPayload.pageInfo),
      "totalCount": notificationsPayload.totalCount,
      "requestId": .string(requestId)
    ]
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["appleNotifications"] = .object(appleNotifications)
    payload["notificationCount"] = .integer(Int64(notificationsPayload.notifications.count))
    payload["replyText"] = .string("Listed \(notificationsPayload.notifications.count) Apple Notifications.")
    return output(input: input, when: ["always": true, "has_notifications": !notificationsPayload.notifications.isEmpty], payload: payload)
  }

  private func postOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    let posted = try envelope.mutationField("postNotification", addonName: input.addon.name)
    guard let notificationId = nonEmptyString(posted["id"]) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.postNotification.id is missing")
    }
    guard let delivered = boolValue(posted["delivered"]) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.postNotification.delivered must be a boolean")
    }
    guard let usedFallback = boolValue(posted["usedFallback"]) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.postNotification.usedFallback must be a boolean")
    }
    var normalizedPosted = posted
    if normalizedPosted["activation"] == nil {
      normalizedPosted["activation"] = .null
    }
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["appleNotification"] = .object(["posted": .object(normalizedPosted)])
    payload["postedNotificationId"] = .string(notificationId)
    payload["replyText"] = .string("Posted Apple notification \(notificationId).")
    return output(
      input: input,
      when: ["always": true, "delivered": delivered, "used_fallback": usedFallback],
      payload: payload
    )
  }

  private func dismissOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    let dismissDocument = try dismissDocument(input: input, config: config, variables: addonVariables(for: input))
    let fieldName = dismissDocument.mode == "all" ? "dismissAllGatewayNotifications" : "dismissNotifications"
    let result = try envelope.mutationField(fieldName, addonName: input.addon.name)
    let dismissedCount = try appleGatewayRequiredNumber(
      result["dismissedCount"],
      field: "\(input.addon.name) GraphQL data.\(fieldName).dismissedCount"
    )
    let requestId = envelope.requestId ?? ""
    let appleNotifications: JSONObject = [
      "dismissedCount": dismissedCount,
      "mode": .string(dismissDocument.mode),
      "requestId": .string(requestId)
    ]
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["appleNotifications"] = .object(appleNotifications)
    payload["dismissedCount"] = dismissedCount
    payload["replyText"] = .string("Dismissed Apple notifications: \(dismissedCount.compactJSONStringOrEmpty()).")
    return output(input: input, when: ["always": true, "dismissed": true], payload: payload)
  }

  private func commonPayload(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) -> JSONObject {
    let requestId = envelope.requestId ?? ""
    return [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(envelope.data)
      ])
    ]
  }

  private func output(input: WorkflowAddonExecutionInput, when: [String: Bool], payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func appendStringField(
    _ key: String,
    config: JSONObject,
    variables: JSONObject,
    to fields: inout [String]
  ) {
    guard let value = stringField(key, config: config, variables: variables) else {
      return
    }
    fields.append("\(key): \(appleGatewayGraphQLString(value))")
  }

  private func nonBlankStringField(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    guard let value = stringField(key, config: config, variables: variables) else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func stringField(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    guard let value = nonEmptyString(variables[key])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    return value.isEmpty ? nil : value
  }

  private func stringArrayField(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> [String]? {
    let value = config[key] ?? variables[key]
    guard let value else {
      return nil
    }
    guard case let .array(rawValues) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be an array of strings")
    }
    return try rawValues.enumerated().map { index, rawValue in
      guard case let .string(template) = rawValue else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)] must be a string")
      }
      return renderPromptTemplate(template, variables: variables)
    }
  }

  private func intField(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject,
    defaultValue: Int,
    range: ClosedRange<Int>
  ) throws -> Int {
    try optionalInt(key, input: input, config: config, variables: variables, range: range) ?? defaultValue
  }

  private func optionalInt(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject,
    range: ClosedRange<Int>
  ) throws -> Int? {
    let value = config[key] ?? variables[key]
    guard let value else {
      return nil
    }
    guard let int = intValue(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be an integer")
    }
    guard range.contains(int) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be between \(range.lowerBound) and \(range.upperBound)")
    }
    return int
  }

  private func optionalBool(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> Bool? {
    let value = config[key] ?? variables[key]
    guard let value else {
      return nil
    }
    guard let bool = boolValue(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
    }
    return bool
  }

  private func notificationGuidanceMessage(_ message: String) -> String {
    let lowercased = message.lowercased()
    var suffixes: [String] = []
    if lowercased.contains("notifier") || lowercased.contains("applegatewaynotifier")
      || lowercased.contains("helper") {
      suffixes.append("install and authorize AppleGatewayNotifier.app; run `apple-gateway permissions status --json`")
    }
    if lowercased.contains("full disk access") || lowercased.contains("notification db") {
      suffixes.append("grant Full Disk Access to the apple-gateway host to read SYSTEM_DB notifications")
    }
    guard !suffixes.isEmpty else {
      return message
    }
    return message + " Guidance: " + suffixes.joined(separator: " ")
  }
}

private struct AppleNotificationsDismissDocument {
  var mode: String
  var document: String
}

private struct AppleGatewayNotificationsPayload {
  var notifications: [JSONObject]
  var pageInfo: JSONObject
  var totalCount: JSONValue

  init(data: JSONObject, addonName: String) throws {
    let connection = try appleGatewayRequiredObject(
      data["notifications"],
      field: "\(addonName) GraphQL data.notifications"
    )
    let edges = try appleGatewayRequiredArray(
      connection["edges"],
      field: "\(addonName) GraphQL data.notifications.edges"
    )
    self.notifications = try edges.enumerated().map { index, edge in
      try Self.notification(fromEdge: edge, index: index, addonName: addonName)
    }
    self.pageInfo = try appleGatewayRequiredObject(
      connection["pageInfo"],
      field: "\(addonName) GraphQL data.notifications.pageInfo"
    )
    self.totalCount = try appleGatewayRequiredNumber(
      connection["totalCount"],
      field: "\(addonName) GraphQL data.notifications.totalCount"
    )
  }

  private static func notification(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
    guard case let .object(edge) = value else {
      throw AdapterExecutionError(
        .invalidOutput,
        "\(addonName) GraphQL data.notifications.edges[\(index)] must be an object"
      )
    }
    guard case var .object(node)? = edge["node"] else {
      throw AdapterExecutionError(
        .invalidOutput,
        "\(addonName) GraphQL data.notifications.edges[\(index)].node must be an object"
      )
    }
    if let cursor = nonEmptyString(edge["cursor"]) {
      node["cursor"] = .string(cursor)
    }
    return node
  }
}
