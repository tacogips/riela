import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeAppleReminderAddon(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    let operation = try BuiltinAppleReminderAddon(addonName: input.addon.name)
    return try AppleReminderEngine(environment: environment).execute(operation, input: input, context: context)
  }
}

enum BuiltinAppleReminderAddon: String, CaseIterable {
  case lists = "riela/apple-reminder-lists"
  case remindersList = "riela/apple-reminders-list"
  case get = "riela/apple-reminder-get"
  case listCreate = "riela/apple-reminder-list-create"
  case create = "riela/apple-reminder-create"
  case update = "riela/apple-reminder-update"
  case delete = "riela/apple-reminder-delete"
  case complete = "riela/apple-reminder-complete"
  case alarmsSet = "riela/apple-reminder-alarms-set"

  init(addonName: String) throws {
    guard let operation = Self(rawValue: addonName) else {
      throw AdapterExecutionError(.providerError, "missing Apple Reminders add-on resolver for '\(addonName)'")
    }
    self = operation
  }
}

private struct AppleReminderEngine {
  private static let defaultFirst = 25
  private static let maxFirst = 100

  var environment: [String: String]

  func execute(
    _ operation: BuiltinAppleReminderAddon,
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
    let templateVariables = appleReminderTemplateVariables(for: input)
    let operationInputs = renderAppleReminderInputs(input.addon.inputs, variables: templateVariables)
    let request = try graphQLRequest(
      operation: operation,
      input: input,
      config: config,
      operationInputs: operationInputs,
      templateVariables: templateVariables
    )
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: config,
      environment: environment
    ).resolvedBinary()
    let processOutput = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
      executablePath: resolvedBinary.path,
      arguments: ["graphql", "--query", request.document, "--variables", request.variables.compactJSONString()],
      deadline: context.deadline
    )
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw AdapterExecutionError(
        .providerError,
        "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
      )
    }
    return try output(
      operation: operation,
      input: input,
      request: request,
      resolvedBinary: resolvedBinary,
      envelope: envelope
    )
  }

  private func appleReminderTemplateVariables(for input: WorkflowAddonExecutionInput) -> JSONObject {
    var variables = input.variables
    for (key, value) in input.resolvedInputPayload {
      variables[key] = value
    }
    variables["input"] = .object(input.resolvedInputPayload)
    variables["workflowId"] = .string(input.workflowId)
    variables["stepId"] = .string(input.stepId)
    variables["nodeId"] = .string(input.nodeId)
    variables["addonName"] = .string(input.addon.name)
    return variables
  }

  private func renderAppleReminderInputs(_ inputs: JSONObject?, variables: JSONObject) -> JSONObject {
    guard let inputs else {
      return [:]
    }
    return inputs.mapValues { renderJSONTemplates($0, variables: variables) }
  }

  private func graphQLRequest(
    operation: BuiltinAppleReminderAddon,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> AppleReminderGraphQLRequest {
    switch operation {
    case .lists:
      return AppleReminderGraphQLRequest(document: Self.listsDocument, variables: .object([:]))
    case .remindersList:
      let searchInput = try reminderSearchInput(
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      return AppleReminderGraphQLRequest(document: Self.remindersListDocument, variables: .object(["input": .object(searchInput)]))
    case .get:
      let reminderId = try requiredString("reminderId", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
      return AppleReminderGraphQLRequest(document: Self.getDocument, variables: .object(["reminderId": .string(reminderId)]))
    case .listCreate:
      var createInput: JSONObject = [
        "title": .string(try requiredString("title", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables))
      ]
      try appendOptionalString(
        "sourceTitle",
        to: &createInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      try appendOptionalString(
        "colorHex",
        to: &createInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      return AppleReminderGraphQLRequest(document: Self.listCreateDocument, variables: .object(["input": .object(createInput)]))
    case .create:
      var createInput: JSONObject = [
        "title": .string(try requiredString("title", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)),
        "priority": .integer(Int64(try boundedInt(
          "priority",
          input: input,
          config: config,
          operationInputs: operationInputs,
          defaultValue: 0,
          range: 0...9,
          templateVariables: templateVariables
        )))
      ]
      try appendReminderOptionalFields(
        to: &createInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      try appendOptionalBool(
        "dueDateHasTime",
        to: &createInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      if let alarms = try optionalAlarms(input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables) {
        createInput["alarms"] = .array(alarms)
      }
      return AppleReminderGraphQLRequest(document: Self.createDocument, variables: .object(["input": .object(createInput)]))
    case .update:
      var updateInput: JSONObject = [
        "reminderId": .string(try requiredString("reminderId", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables))
      ]
      try appendReminderOptionalFields(
        to: &updateInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      try appendOptionalInt(
        "priority",
        to: &updateInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        range: 0...9,
        templateVariables: templateVariables
      )
      try appendOptionalBool(
        "dueDateHasTime",
        to: &updateInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
      if let alarms = try optionalAlarms(input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables) {
        updateInput["alarms"] = .array(alarms)
      }
      return AppleReminderGraphQLRequest(document: Self.updateDocument, variables: .object(["input": .object(updateInput)]))
    case .delete:
      let reminderId = try requiredString("reminderId", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
      return AppleReminderGraphQLRequest(document: Self.deleteDocument, variables: .object(["reminderId": .string(reminderId)]))
    case .complete:
      let reminderId = try requiredString("reminderId", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
      let completed = try bool(
        "completed",
        input: input,
        config: config,
        operationInputs: operationInputs,
        defaultValue: true,
        templateVariables: templateVariables
      )
      return AppleReminderGraphQLRequest(
        document: Self.completeDocument,
        variables: .object(["reminderId": .string(reminderId), "completed": .bool(completed)])
      )
    case .alarmsSet:
      let reminderId = try requiredString("reminderId", input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
      let alarms = try requiredAlarms(input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
      return AppleReminderGraphQLRequest(
        document: Self.alarmsSetDocument,
        variables: .object(["reminderId": .string(reminderId), "alarms": .array(alarms)])
      )
    }
  }

  private func output(
    operation: BuiltinAppleReminderAddon,
    input: WorkflowAddonExecutionInput,
    request: AppleReminderGraphQLRequest,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    var appleReminders: JSONObject
    var when = ["always": true]
    switch operation {
    case .lists:
      let lists = try appleGatewayRequiredArray(
        envelope.data["reminderLists"],
        field: "\(input.addon.name) GraphQL data.reminderLists"
      )
      appleReminders = ["lists": .array(lists), "listCount": .integer(Int64(lists.count))]
    case .remindersList:
      let connection = try appleGatewayRequiredObject(
        envelope.data["reminders"],
        field: "\(input.addon.name) GraphQL data.reminders"
      )
      let payload = try remindersConnection(connection, addonName: input.addon.name)
      appleReminders = payload.appleReminders
      when["has_reminders"] = payload.reminderCount > 0
    case .get:
      switch envelope.data["reminder"] {
      case let .object(reminder)?:
        appleReminders = ["reminder": .object(reminder), "found": .bool(true)]
      case .null?:
        appleReminders = ["reminder": .null, "found": .bool(false)]
      case nil:
        throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.reminder is missing")
      default:
        throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.reminder must be an object or null")
      }
    case .listCreate:
      appleReminders = ["list": .object(try envelope.mutationField("createReminderList", addonName: input.addon.name))]
    case .create:
      appleReminders = ["reminder": .object(try envelope.mutationField("createReminder", addonName: input.addon.name))]
    case .update:
      appleReminders = ["reminder": .object(try envelope.mutationField("updateReminder", addonName: input.addon.name))]
    case .delete:
      let result = try envelope.mutationField("deleteReminder", addonName: input.addon.name)
      guard let success = boolValue(result["success"]) else {
        throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.deleteReminder.success must be a boolean")
      }
      guard success else {
        throw AdapterExecutionError(
          .providerError,
          "\(input.addon.name) GraphQL data.deleteReminder.success was false"
        )
      }
      let reminderId = reminderId(from: request.variables)
      appleReminders = [
        "deleted": .object([
          "reminderId": .string(reminderId),
          "success": .bool(success)
        ])
      ]
    case .complete:
      appleReminders = ["reminder": .object(try envelope.mutationField("setReminderCompleted", addonName: input.addon.name))]
    case .alarmsSet:
      appleReminders = ["reminder": .object(try envelope.mutationField("setReminderAlarms", addonName: input.addon.name))]
    }

    let requestId = envelope.requestId ?? ""
    let payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleReminders": .object(appleReminders),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(envelope.data)
      ])
    ]
    return AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func reminderSearchInput(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> JSONObject {
    var searchInput: JSONObject = [
      "listIds": .array(try stringArray(
        "listIds",
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      ) ?? []),
      "status": .string(try status(input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)),
      "first": .integer(Int64(try boundedInt(
        "first",
        input: input,
        config: config,
        operationInputs: operationInputs,
        defaultValue: Self.defaultFirst,
        range: 1...Self.maxFirst,
        templateVariables: templateVariables
      )))
    ]
    for key in ["dueAfter", "dueBefore", "query", "after"] {
      try appendOptionalString(
        key,
        to: &searchInput,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
    }
    return searchInput
  }

  private func remindersConnection(_ connection: JSONObject, addonName: String) throws -> AppleReminderConnectionPayload {
    let edges = try appleGatewayRequiredArray(connection["edges"], field: "\(addonName) GraphQL data.reminders.edges")
    let reminders = try edges.enumerated().map { index, edge in
      try reminderNode(fromEdge: edge, index: index, addonName: addonName)
    }
    let pageInfo = try appleGatewayRequiredObject(connection["pageInfo"], field: "\(addonName) GraphQL data.reminders.pageInfo")
    let totalCount = try appleGatewayRequiredNumber(connection["totalCount"], field: "\(addonName) GraphQL data.reminders.totalCount")
    return AppleReminderConnectionPayload(
      appleReminders: [
        "reminders": .array(reminders.map(JSONValue.object)),
        "pageInfo": .object(pageInfo),
        "totalCount": totalCount,
        "reminderCount": .integer(Int64(reminders.count))
      ],
      reminderCount: reminders.count
    )
  }

  private func reminderNode(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
    guard case let .object(edge) = value else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.reminders.edges[\(index)] must be an object")
    }
    guard case var .object(node)? = edge["node"] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.reminders.edges[\(index)].node must be an object")
    }
    if let cursor = nonEmptyString(edge["cursor"]) {
      node["cursor"] = .string(cursor)
    }
    return node
  }

  private func requiredString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> String {
    guard let value = try string(
      key,
      addonName: input.addon.name,
      config: config,
      operationInputs: operationInputs,
      templateVariables: templateVariables
    ) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    return value
  }

  private func appendReminderOptionalFields(
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws {
    for key in ["listId", "notes", "url", "startDate", "dueDate", "title"] {
      try appendOptionalString(
        key,
        to: &object,
        input: input,
        config: config,
        operationInputs: operationInputs,
        templateVariables: templateVariables
      )
    }
  }

  private func appendOptionalString(
    _ key: String,
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws {
    if let value = try string(
      key,
      addonName: input.addon.name,
      config: config,
      operationInputs: operationInputs,
      templateVariables: templateVariables
    ) {
      object[key] = .string(value)
    }
  }

  private func appendOptionalInt(
    _ key: String,
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    range: ClosedRange<Int>,
    templateVariables: JSONObject
  ) throws {
    guard config[key] != nil || operationInputs[key] != nil else {
      return
    }
    let value = try boundedInt(
      key,
      input: input,
      config: config,
      operationInputs: operationInputs,
      defaultValue: range.lowerBound,
      range: range,
      templateVariables: templateVariables
    )
    object[key] = .integer(Int64(value))
  }

  private func appendOptionalBool(
    _ key: String,
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws {
    guard config[key] != nil || operationInputs[key] != nil else {
      return
    }
    let value = try bool(
      key,
      input: input,
      config: config,
      operationInputs: operationInputs,
      defaultValue: false,
      templateVariables: templateVariables
    )
    object[key] = .bool(value)
  }

  private func string(
    _ key: String,
    addonName: String,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> String? {
    if let inputValue = operationInputs[key] {
      switch inputValue {
      case let .string(value):
        return nonEmptyInputString(value)
      case .null:
        break
      default:
        throw AdapterExecutionError(.policyBlocked, "\(addonName) \(key) must be a string")
      }
    }
    guard let configValue = config[key] else {
      return nil
    }
    switch configValue {
    case let .string(value):
      return renderedNonEmptyString(value, templateVariables: templateVariables)
    case .null:
      return nil
    default:
      throw AdapterExecutionError(.policyBlocked, "\(addonName) \(key) must be a string")
    }
  }

  private func renderedNonEmptyString(_ value: String, templateVariables: JSONObject) -> String? {
    let rendered = renderPromptTemplate(value, variables: templateVariables)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return rendered.isEmpty ? nil : rendered
  }

  private func nonEmptyInputString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func status(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> String {
    let raw = try string(
      "status",
      addonName: input.addon.name,
      config: config,
      operationInputs: operationInputs,
      templateVariables: templateVariables
    ) ?? "INCOMPLETE"
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard ["ALL", "INCOMPLETE", "COMPLETED"].contains(normalized) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) status must be ALL, INCOMPLETE, or COMPLETED")
    }
    return normalized
  }

  private func boundedInt(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    defaultValue: Int,
    range: ClosedRange<Int>,
    templateVariables: JSONObject
  ) throws -> Int {
    let raw = operationValue(key, config: config, operationInputs: operationInputs)
    let materialized = try raw.map {
      try materializedJSONValue($0.value, templateVariables: templateVariables, renderTemplates: $0.renderTemplates)
    }
    if let value = intValue(materialized) {
      guard range.contains(value) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be between \(range.lowerBound) and \(range.upperBound)")
      }
      return value
    }
    guard materialized == nil else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be an integer")
    }
    return defaultValue
  }

  private func bool(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    defaultValue: Bool,
    templateVariables: JSONObject
  ) throws -> Bool {
    let raw = operationValue(key, config: config, operationInputs: operationInputs)
    let materialized = try raw.map {
      try materializedJSONValue($0.value, templateVariables: templateVariables, renderTemplates: $0.renderTemplates)
    }
    if let value = boolValue(materialized) {
      return value
    }
    guard materialized == nil else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
    }
    return defaultValue
  }

  private func operationValue(
    _ key: String,
    config: JSONObject,
    operationInputs: JSONObject
  ) -> AppleReminderOperationValue? {
    if let value = operationInputs[key] {
      if case let .string(text) = value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return config[key].map { AppleReminderOperationValue(value: $0, renderTemplates: true) }
      }
      if case .null = value {
        return config[key].map { AppleReminderOperationValue(value: $0, renderTemplates: true) }
      }
      return AppleReminderOperationValue(value: value, renderTemplates: false)
    }
    return config[key].map { AppleReminderOperationValue(value: $0, renderTemplates: true) }
  }

  private func stringArray(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> [JSONValue]? {
    let raw = operationValue(key, config: config, operationInputs: operationInputs)
    guard let raw else {
      return nil
    }
    let value = try materializedJSONValue(
      raw.value,
      templateVariables: templateVariables,
      renderTemplates: raw.renderTemplates
    )
    if case .null = value {
      return nil
    }
    guard case let .array(values) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be an array of strings")
    }
    return try values.enumerated().map { index, value in
      guard let item = nonEmptyString(value) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)] must be a string")
      }
      return .string(item)
    }
  }

  private func optionalAlarms(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> [JSONValue]? {
    guard config["alarms"] != nil || operationInputs["alarms"] != nil else {
      return nil
    }
    return try requiredAlarms(input: input, config: config, operationInputs: operationInputs, templateVariables: templateVariables)
  }

  private func requiredAlarms(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    operationInputs: JSONObject,
    templateVariables: JSONObject
  ) throws -> [JSONValue] {
    let raw = operationValue("alarms", config: config, operationInputs: operationInputs)
    guard let raw else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms is required")
    }
    let value = try materializedJSONValue(
      raw.value,
      templateVariables: templateVariables,
      renderTemplates: raw.renderTemplates
    )
    guard case let .array(values) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms must be an array")
    }
    return try values.enumerated().map { index, value in
      guard case let .object(object) = value else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms[\(index)] must be an object")
      }
      var alarm: JSONObject = [:]
      if let absoluteDate = nonEmptyString(object["absoluteDate"]) {
        alarm["absoluteDate"] = .string(absoluteDate)
      } else if object["absoluteDate"] != nil {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms[\(index)].absoluteDate must be a string")
      }
      if let offset = intValue(object["relativeOffsetSeconds"]) {
        alarm["relativeOffsetSeconds"] = .integer(Int64(offset))
      } else if object["relativeOffsetSeconds"] != nil {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms[\(index)].relativeOffsetSeconds must be an integer")
      }
      guard !alarm.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) alarms[\(index)] must include absoluteDate or relativeOffsetSeconds")
      }
      return .object(alarm)
    }
  }

  private func materializedJSONValue(
    _ value: JSONValue,
    templateVariables: JSONObject,
    renderTemplates: Bool
  ) throws -> JSONValue {
    guard case let .string(template) = value else {
      return value
    }
    let rendered = (renderTemplates ? renderPromptTemplate(template, variables: templateVariables) : template)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rendered.isEmpty else {
      return .null
    }
    guard let data = rendered.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      return .string(rendered)
    }
    return decoded
  }

  private func reminderId(from variables: JSONValue) -> String {
    guard case let .object(object) = variables else {
      return ""
    }
    return nonEmptyString(object["reminderId"]) ?? ""
  }

  private static let reminderFields = """
      id
      listId
      title
      notes
      url
      completed: isCompleted
      priority
      startDate
      dueDate
      dueDateHasTime
      completionDate
      creationDate
      modificationDate: lastModifiedDate
      alarms {
        relativeOffsetSeconds
        absoluteDate
      }
  """

  private static let listFields = """
      id
      title
      entityType
      sourceTitle
      sourceType
      colorHex
      allowsModifications
      isSubscribed
      isDefault
  """

  private static let listsDocument = """
  query RielaAppleReminderLists {
    reminderLists {
  \(listFields)
    }
  }
  """

  private static let remindersListDocument = """
  query RielaAppleRemindersList($input: ReminderSearchInput!) {
    reminders(input: $input) {
      totalCount
      pageInfo {
        hasNextPage
        endCursor
      }
      edges {
        cursor
        node {
  \(reminderFields)
        }
      }
    }
  }
  """

  private static let getDocument = """
  query RielaAppleReminderGet($reminderId: ID!) {
    reminder(reminderId: $reminderId) {
  \(reminderFields)
    }
  }
  """

  private static let listCreateDocument = """
  mutation RielaAppleReminderListCreate($input: CreateReminderListInput!) {
    createReminderList(input: $input) {
  \(listFields)
    }
  }
  """

  private static let createDocument = """
  mutation RielaAppleReminderCreate($input: CreateReminderInput!) {
    createReminder(input: $input) {
  \(reminderFields)
    }
  }
  """

  private static let updateDocument = """
  mutation RielaAppleReminderUpdate($input: UpdateReminderInput!) {
    updateReminder(input: $input) {
  \(reminderFields)
    }
  }
  """

  private static let deleteDocument = """
  mutation RielaAppleReminderDelete($reminderId: ID!) {
    deleteReminder(reminderId: $reminderId) {
      success
    }
  }
  """

  private static let completeDocument = """
  mutation RielaAppleReminderComplete($reminderId: ID!, $completed: Boolean!) {
    setReminderCompleted(reminderId: $reminderId, completed: $completed) {
  \(reminderFields)
    }
  }
  """

  private static let alarmsSetDocument = """
  mutation RielaAppleReminderAlarmsSet($reminderId: ID!, $alarms: [AlarmInput!]!) {
    setReminderAlarms(reminderId: $reminderId, alarms: $alarms) {
  \(reminderFields)
    }
  }
  """
}

private struct AppleReminderGraphQLRequest {
  var document: String
  var variables: JSONValue
}

private struct AppleReminderOperationValue {
  var value: JSONValue
  var renderTemplates: Bool
}

private struct AppleReminderConnectionPayload {
  var appleReminders: JSONObject
  var reminderCount: Int
}
