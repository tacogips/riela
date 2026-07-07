import Foundation
import RielaCore

enum BuiltinCalendarAddon: String {
  case calendarList = "riela/calendar-list"
  case eventSearch = "riela/event-search"
  case eventGet = "riela/event-get"
  case eventCreate = "riela/event-create"
  case eventUpdate = "riela/event-update"
  case eventDelete = "riela/event-delete"
  case eventAlarmsSet = "riela/event-alarms-set"
}

extension BuiltinWorkflowAddonResolver {
  func executeCalendarAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinCalendarAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try AppleCalendarAddonEngine(environment: environment).execute(operation, input: input, context: context)
  }
}

struct AppleCalendarAddonEngine {
  private static let eventSearchDefaultFirst = 25
  private static let eventSearchMaxFirst = 100
  private static let calendarEntityTypes = Set(["EVENT", "REMINDER"])
  private static let eventAvailabilityValues = Set(["NOT_SUPPORTED", "BUSY", "FREE", "TENTATIVE", "UNAVAILABLE"])
  private static let recurrenceSpanValues = Set(["THIS_EVENT", "FUTURE_EVENTS"])
  private static let recurrenceFrequencyValues = Set(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])

  var environment: [String: String]

  func execute(
    _ operation: BuiltinCalendarAddon,
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
    let inputValues = renderedInputValues(for: input)
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: config,
      environment: environment
    ).resolvedBinary()
    let request = try graphQLRequest(operation, input: input, config: config, inputValues: inputValues)
    let processOutput = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
      executablePath: resolvedBinary.path,
      arguments: ["graphql", "--query", request.document, "--variables", try request.variables.compactJSONString()],
      deadline: context.deadline
    )
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw AdapterExecutionError(
        .providerError,
        "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
      )
    }
    return try output(operation, input: input, resolvedBinary: resolvedBinary, envelope: envelope)
  }

  func commonPayload(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope,
    appleCalendar: JSONObject,
    replyText: String
  ) -> JSONObject {
    let requestId = envelope.requestId ?? ""
    return [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "requestId": .string(requestId),
      "appleCalendar": .object(appleCalendar.merging(["requestId": .string(requestId)]) { current, _ in current }),
      "replyText": .string(replyText),
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

  func adapterOutput(
    input: WorkflowAddonExecutionInput,
    when: [String: Bool],
    payload: JSONObject
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func graphQLRequest(
    _ operation: BuiltinCalendarAddon,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> AppleCalendarGraphQLRequest {
    switch operation {
    case .calendarList:
      let entityType = try enumString(
        "entityType",
        input: input,
        config: config,
        inputValues: inputValues,
        allowed: Self.calendarEntityTypes,
        defaultValue: "EVENT"
      )
      return AppleCalendarGraphQLRequest(
        document: Self.calendarListDocument,
        variables: .object(["entityType": .string(entityType)])
      )
    case .eventSearch:
      let calendarIds = try requiredStringArray("calendarIds", input: input, config: config, inputValues: inputValues)
      guard !calendarIds.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) calendarIds must not be empty")
      }
      var eventSearchInput: JSONObject = ["calendarIds": .array(calendarIds.map(JSONValue.string))]
      appendOptionalString("startDate", to: &eventSearchInput, input: input, config: config, inputValues: inputValues)
      appendOptionalString("endDate", to: &eventSearchInput, input: input, config: config, inputValues: inputValues)
      appendOptionalString("query", to: &eventSearchInput, input: input, config: config, inputValues: inputValues)
      appendOptionalString("after", to: &eventSearchInput, input: input, config: config, inputValues: inputValues)
      eventSearchInput["first"] = .integer(Int64(try first(input: input, config: config, inputValues: inputValues)))
      return AppleCalendarGraphQLRequest(
        document: Self.eventSearchDocument,
        variables: .object(["input": .object(eventSearchInput)])
      )
    case .eventGet:
      let eventId = try requiredString("eventId", input: input, config: config, inputValues: inputValues)
      var requestVariables: JSONObject = ["eventId": .string(eventId)]
      appendOptionalString("occurrenceDate", to: &requestVariables, input: input, config: config, inputValues: inputValues)
      return AppleCalendarGraphQLRequest(document: Self.eventGetDocument, variables: .object(requestVariables))
    case .eventCreate, .eventUpdate, .eventDelete, .eventAlarmsSet:
      return try writeGraphQLRequest(operation, input: input, config: config, inputValues: inputValues)
    }
  }

  private func output(
    _ operation: BuiltinCalendarAddon,
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    switch operation {
    case .calendarList:
      let calendars = try appleGatewayRequiredArray(
        envelope.data["calendars"],
        field: "\(input.addon.name) GraphQL data.calendars"
      )
      let appleCalendar: JSONObject = [
        "calendars": .array(calendars),
        "calendarCount": .integer(Int64(calendars.count))
      ]
      var payload = commonPayload(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleCalendar: appleCalendar,
        replyText: "Listed \(calendars.count) Apple calendars."
      )
      payload["calendarCount"] = appleCalendar["calendarCount"]
      return adapterOutput(input: input, when: ["always": true, "has_calendars": !calendars.isEmpty], payload: payload)
    case .eventSearch:
      let connection = try appleGatewayRequiredObject(
        envelope.data["events"],
        field: "\(input.addon.name) GraphQL data.events"
      )
      let edges = try appleGatewayRequiredArray(
        connection["edges"],
        field: "\(input.addon.name) GraphQL data.events.edges"
      )
      let events = try edges.enumerated().map { index, edge in
        try appleCalendarEvent(fromEdge: edge, index: index, addonName: input.addon.name)
      }
      let pageInfo = try appleGatewayRequiredObject(
        connection["pageInfo"],
        field: "\(input.addon.name) GraphQL data.events.pageInfo"
      )
      let totalCount = try appleGatewayRequiredNumber(
        connection["totalCount"],
        field: "\(input.addon.name) GraphQL data.events.totalCount"
      )
      let appleCalendar: JSONObject = [
        "events": .array(events.map(JSONValue.object)),
        "pageInfo": .object(pageInfo),
        "totalCount": totalCount
      ]
      return adapterOutput(
        input: input,
        when: ["always": true, "has_events": !events.isEmpty],
        payload: commonPayload(
          input: input,
          resolvedBinary: resolvedBinary,
          envelope: envelope,
          appleCalendar: appleCalendar,
          replyText: "Fetched \(events.count) Apple Calendar events."
        )
      )
    case .eventGet:
      guard let eventValue = envelope.data["event"] else {
        throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.event is missing")
      }
      let hasEvent: Bool
      switch eventValue {
      case .null:
        hasEvent = false
      case .object:
        hasEvent = true
      default:
        throw AdapterExecutionError(
          .invalidOutput,
          "\(input.addon.name) GraphQL data.event must be null or an object"
        )
      }
      let appleCalendar: JSONObject = ["event": eventValue]
      return adapterOutput(
        input: input,
        when: ["always": true, "has_event": hasEvent],
        payload: commonPayload(
          input: input,
          resolvedBinary: resolvedBinary,
          envelope: envelope,
          appleCalendar: appleCalendar,
          replyText: hasEvent ? "Fetched Apple Calendar event." : "Apple Calendar event was not found."
        )
      )
    case .eventCreate, .eventUpdate, .eventDelete, .eventAlarmsSet:
      return try writeOutput(operation, input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    }
  }

  private func renderedInputValues(for input: WorkflowAddonExecutionInput) -> JSONObject {
    renderAddonInputs(input.addon.inputs, variables: addonTemplateVariables(for: input))
  }

  private func addonTemplateVariables(for input: WorkflowAddonExecutionInput) -> JSONObject {
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

  func requiredString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> String {
    guard let value = string(key, config: config, inputValues: inputValues) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    return value
  }

  func appendOptionalString(
    _ key: String,
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) {
    if let value = string(key, config: config, inputValues: inputValues) {
      object[key] = .string(value)
    }
  }

  func string(_ key: String, config: JSONObject, inputValues: JSONObject) -> String? {
    if let value = literalString(inputValues[key]) {
      return value
    }
    return literalString(config[key])
  }

  private func literalString(_ value: JSONValue?) -> String? {
    guard case let .string(value)? = value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func bool(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject,
    defaultValue: Bool? = nil
  ) throws -> Bool? {
    guard let value = inputValues[key] ?? config[key] else {
      return defaultValue
    }
    if let bool = boolValue(value) {
      return bool
    }
    if let string = nonEmptyString(value)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      if string == "true" {
        return true
      }
      if string == "false" {
        return false
      }
    }
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
  }

  func enumString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject,
    allowed: Set<String>,
    defaultValue: String? = nil
  ) throws -> String {
    let raw = string(key, config: config, inputValues: inputValues) ?? defaultValue
    guard let raw else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard allowed.contains(normalized) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) \(key) must be one of \(allowed.sorted().joined(separator: ", "))"
      )
    }
    return normalized
  }

  func recurrenceSpan(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> String {
    try enumString(
      "span",
      input: input,
      config: config,
      inputValues: inputValues,
      allowed: Self.recurrenceSpanValues,
      defaultValue: "THIS_EVENT"
    )
  }

  func appendAvailability(
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws {
    guard string("availability", config: config, inputValues: inputValues) != nil else {
      return
    }
    object["availability"] = .string(try enumString(
      "availability",
      input: input,
      config: config,
      inputValues: inputValues,
      allowed: Self.eventAvailabilityValues
    ))
  }

  func optionalArray(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> [JSONValue]? {
    guard let value = inputValues[key] ?? config[key] else {
      return nil
    }
    if case let .array(array) = value {
      return array
    }
    if let string = nonEmptyString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)),
      case let .array(array) = parsed {
      return array
    }
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be an array")
  }

  func requiredStringArray(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> [String] {
    guard let values = try optionalArray(key, input: input, config: config, inputValues: inputValues) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    return try values.enumerated().map { index, value in
      guard let string = nonEmptyString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !string.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)] must be a non-empty string")
      }
      return string
    }
  }

  func validatedAlarms(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject,
    required: Bool
  ) throws -> [JSONValue]? {
    guard let alarms = try optionalArray(key, input: input, config: config, inputValues: inputValues) else {
      if required {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
      }
      return nil
    }
    for (index, alarm) in alarms.enumerated() {
      guard let object = objectValue(alarm) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)] must be an object")
      }
      if let relativeOffset = object["relativeOffsetSeconds"], relativeOffset.asDouble == nil {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)].relativeOffsetSeconds must be numeric")
      }
      if let absoluteDate = object["absoluteDate"], nonEmptyString(absoluteDate) == nil {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key)[\(index)].absoluteDate must be a string")
      }
      guard object["relativeOffsetSeconds"] != nil || object["absoluteDate"] != nil else {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) \(key)[\(index)] requires relativeOffsetSeconds or absoluteDate"
        )
      }
    }
    return alarms
  }

  func validatedRecurrenceRules(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> [JSONValue]? {
    guard let rules = try optionalArray("recurrenceRules", input: input, config: config, inputValues: inputValues) else {
      return nil
    }
    return try rules.enumerated().map { index, rule in
      guard var object = objectValue(rule) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) recurrenceRules[\(index)] must be an object")
      }
      if let frequency = nonEmptyString(object["frequency"])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        guard Self.recurrenceFrequencyValues.contains(frequency) else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) recurrenceRules[\(index)].frequency is invalid")
        }
        object["frequency"] = .string(frequency)
      }
      return .object(object)
    }
  }

  private func first(input: WorkflowAddonExecutionInput, config: JSONObject, inputValues: JSONObject) throws -> Int {
    let value = inputValues["first"] ?? config["first"]
    let raw: Int?
    if let int = intValue(value) {
      raw = int
    } else if let string = nonEmptyString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
      raw = Int(string)
    } else {
      raw = Self.eventSearchDefaultFirst
    }
    guard let raw, raw > 0 && raw <= Self.eventSearchMaxFirst else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) first must be between 1 and \(Self.eventSearchMaxFirst)")
    }
    return raw
  }

  private static let calendarListDocument = """
  query RielaCalendarList($entityType: CalendarEntityType) {
    calendars(entityType: $entityType) {
      id
      title
      entityType
      sourceTitle
      sourceType
      colorHex
      allowsModifications
      isSubscribed
      isDefault
    }
  }
  """

  private static let eventSearchDocument = """
  query RielaEventSearch($input: EventSearchInput!) {
    events(input: $input) {
      totalCount
      pageInfo {
        hasNextPage
        endCursor
      }
      edges {
        cursor
        node {
  \(eventFields)
        }
      }
    }
  }
  """

  private static let eventGetDocument = """
  query RielaEventGet($eventId: ID!, $occurrenceDate: DateTime) {
    event(eventId: $eventId, occurrenceDate: $occurrenceDate) {
  \(eventFields)
    }
  }
  """

  static let eventFields = """
      id
      calendarId
      title
      notes
      location
      url
      isAllDay
      startDate
      endDate
      timeZone
      status
      availability
      organizer {
        name
        email
        isCurrentUser
        status
      }
      attendees {
        name
        email
        isCurrentUser
        status
      }
      alarms {
        relativeOffsetSeconds
        absoluteDate
      }
      recurrenceRules {
        frequency
        interval
        daysOfWeek
        daysOfMonth
        monthsOfYear
        weeksOfYear
        daysOfYear
        setPositions
        endDate
        occurrenceCount
      }
      isRecurring
      occurrenceDate
      isDetached
      creationDate
      lastModifiedDate
  """
}

struct AppleCalendarGraphQLRequest {
  var document: String
  var variables: JSONValue
}

func appleCalendarEvent(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
  guard case let .object(edge) = value else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.events.edges[\(index)] must be an object"
    )
  }
  guard case var .object(node)? = edge["node"] else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.events.edges[\(index)].node must be an object"
    )
  }
  if let cursor = nonEmptyString(edge["cursor"]) {
    node["cursor"] = .string(cursor)
  }
  return node
}
