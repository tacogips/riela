import Foundation
import RielaCore

extension AppleCalendarAddonEngine {
  func writeGraphQLRequest(
    _ operation: BuiltinCalendarAddon,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject
  ) throws -> AppleCalendarGraphQLRequest {
    switch operation {
    case .eventCreate:
      var eventInput = try eventInputBase(input: input, config: config, inputValues: inputValues, requireCreateFields: true)
      eventInput["isAllDay"] = .bool(try bool(
        "isAllDay",
        input: input,
        config: config,
        inputValues: inputValues,
        defaultValue: false
      ) ?? false)
      return AppleCalendarGraphQLRequest(
        document: Self.eventCreateDocument,
        variables: .object(["input": .object(eventInput)])
      )
    case .eventUpdate:
      let eventId = try requiredString("eventId", input: input, config: config, inputValues: inputValues)
      var eventInput: JSONObject = [
        "eventId": .string(eventId),
        "span": .string(try recurrenceSpan(input: input, config: config, inputValues: inputValues))
      ]
      appendOptionalString("occurrenceDate", to: &eventInput, input: input, config: config, inputValues: inputValues)
      eventInput.merge(
        try eventInputBase(input: input, config: config, inputValues: inputValues, requireCreateFields: false)
      ) { _, new in new }
      if let isAllDay = try bool("isAllDay", input: input, config: config, inputValues: inputValues) {
        eventInput["isAllDay"] = .bool(isAllDay)
      }
      return AppleCalendarGraphQLRequest(
        document: Self.eventUpdateDocument,
        variables: .object(["input": .object(eventInput)])
      )
    case .eventDelete:
      let eventId = try requiredString("eventId", input: input, config: config, inputValues: inputValues)
      var requestVariables: JSONObject = [
        "eventId": .string(eventId),
        "span": .string(try recurrenceSpan(input: input, config: config, inputValues: inputValues))
      ]
      appendOptionalString("occurrenceDate", to: &requestVariables, input: input, config: config, inputValues: inputValues)
      return AppleCalendarGraphQLRequest(document: Self.eventDeleteDocument, variables: .object(requestVariables))
    case .eventAlarmsSet:
      let eventId = try requiredString("eventId", input: input, config: config, inputValues: inputValues)
      let alarms = try validatedAlarms("alarms", input: input, config: config, inputValues: inputValues, required: true) ?? []
      var requestVariables: JSONObject = [
        "eventId": .string(eventId),
        "alarms": .array(alarms),
        "span": .string(try recurrenceSpan(input: input, config: config, inputValues: inputValues))
      ]
      appendOptionalString("occurrenceDate", to: &requestVariables, input: input, config: config, inputValues: inputValues)
      return AppleCalendarGraphQLRequest(document: Self.eventAlarmsSetDocument, variables: .object(requestVariables))
    case .calendarList, .eventSearch, .eventGet:
      throw AdapterExecutionError(.providerError, "missing Calendar write resolver for '\(input.addon.name)'")
    }
  }

  func writeOutput(
    _ operation: BuiltinCalendarAddon,
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    switch operation {
    case .eventCreate:
      let event = try envelope.mutationField("createEvent", addonName: input.addon.name)
      return eventMutationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        event: event,
        when: ["always": true, "created": true],
        replyText: "Created Apple Calendar event."
      )
    case .eventUpdate:
      let event = try envelope.mutationField("updateEvent", addonName: input.addon.name)
      return eventMutationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        event: event,
        when: ["always": true, "updated": true],
        replyText: "Updated Apple Calendar event."
      )
    case .eventDelete:
      let deleteResult = try envelope.mutationField("deleteEvent", addonName: input.addon.name)
      guard let deleted = boolValue(deleteResult["success"]) else {
        throw AdapterExecutionError(
          .invalidOutput,
          "\(input.addon.name) GraphQL data.deleteEvent.success must be a boolean"
        )
      }
      guard deleted else {
        throw AdapterExecutionError(
          .providerError,
          "\(input.addon.name) GraphQL data.deleteEvent.success was false"
        )
      }
      let appleCalendar: JSONObject = ["deleteResult": .object(deleteResult)]
      var payload = commonPayload(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleCalendar: appleCalendar,
        replyText: "Deleted Apple Calendar event."
      )
      payload["deleted"] = .bool(deleted)
      return adapterOutput(input: input, when: ["always": true, "deleted": deleted], payload: payload)
    case .eventAlarmsSet:
      let event = try envelope.mutationField("setEventAlarms", addonName: input.addon.name)
      return eventMutationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        event: event,
        when: ["always": true, "alarms_set": true],
        replyText: "Set Apple Calendar event alarms."
      )
    case .calendarList, .eventSearch, .eventGet:
      throw AdapterExecutionError(.providerError, "missing Calendar write output for '\(input.addon.name)'")
    }
  }

  private func eventMutationOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope,
    event: JSONObject,
    when: [String: Bool],
    replyText: String
  ) -> AdapterExecutionOutput {
    var outputWhen = when
    outputWhen["has_event"] = true
    return adapterOutput(
      input: input,
      when: outputWhen,
      payload: commonPayload(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleCalendar: ["event": .object(event)],
        replyText: replyText
      )
    )
  }

  private func eventInputBase(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    inputValues: JSONObject,
    requireCreateFields: Bool
  ) throws -> JSONObject {
    var eventInput: JSONObject = [:]
    if requireCreateFields {
      eventInput["title"] = .string(try requiredString("title", input: input, config: config, inputValues: inputValues))
      eventInput["startDate"] = .string(try requiredString("startDate", input: input, config: config, inputValues: inputValues))
      eventInput["endDate"] = .string(try requiredString("endDate", input: input, config: config, inputValues: inputValues))
    } else {
      appendOptionalString("title", to: &eventInput, input: input, config: config, inputValues: inputValues)
      appendOptionalString("startDate", to: &eventInput, input: input, config: config, inputValues: inputValues)
      appendOptionalString("endDate", to: &eventInput, input: input, config: config, inputValues: inputValues)
    }
    appendOptionalString("calendarId", to: &eventInput, input: input, config: config, inputValues: inputValues)
    appendOptionalString("notes", to: &eventInput, input: input, config: config, inputValues: inputValues)
    appendOptionalString("location", to: &eventInput, input: input, config: config, inputValues: inputValues)
    appendOptionalString("url", to: &eventInput, input: input, config: config, inputValues: inputValues)
    appendOptionalString("timeZone", to: &eventInput, input: input, config: config, inputValues: inputValues)
    try appendAvailability(to: &eventInput, input: input, config: config, inputValues: inputValues)
    if let alarms = try validatedAlarms("alarms", input: input, config: config, inputValues: inputValues, required: false) {
      eventInput["alarms"] = .array(alarms)
    }
    if let recurrenceRules = try validatedRecurrenceRules(input: input, config: config, inputValues: inputValues) {
      eventInput["recurrenceRules"] = .array(recurrenceRules)
    }
    return eventInput
  }

  private static let eventCreateDocument = """
  mutation RielaEventCreate($input: CreateEventInput!) {
    createEvent(input: $input) {
  \(eventFields)
    }
  }
  """

  private static let eventUpdateDocument = """
  mutation RielaEventUpdate($input: UpdateEventInput!) {
    updateEvent(input: $input) {
  \(eventFields)
    }
  }
  """

  private static let eventDeleteDocument = """
  mutation RielaEventDelete($eventId: ID!, $span: RecurrenceSpan!, $occurrenceDate: DateTime) {
    deleteEvent(eventId: $eventId, span: $span, occurrenceDate: $occurrenceDate) {
      success
    }
  }
  """

  private static let eventAlarmsSetDocument = """
  mutation RielaEventAlarmsSet(
    $eventId: ID!,
    $alarms: [AlarmInput!]!,
    $span: RecurrenceSpan!,
    $occurrenceDate: DateTime
  ) {
    setEventAlarms(eventId: $eventId, alarms: $alarms, span: $span, occurrenceDate: $occurrenceDate) {
  \(eventFields)
    }
  }
  """
}
