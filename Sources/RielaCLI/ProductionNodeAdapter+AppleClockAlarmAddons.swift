import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeAppleClockAlarm(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard let operation = AppleClockAlarmOperation(addonName: input.addon.name) else {
      throw AdapterExecutionError(.providerError, "missing Apple Clock Alarm add-on resolver for '\(input.addon.name)'")
    }
    let engine = AppleClockAlarmEngine(environment: environment)
    return try engine.execute(operation, input: input, context: context)
  }
}

enum AppleClockAlarmOperation: String {
  case list = "riela/apple-clock-alarms-list"
  case create = "riela/apple-clock-alarm-create"
  case toggle = "riela/apple-clock-alarm-toggle"
  case update = "riela/apple-clock-alarm-update"
  case delete = "riela/apple-clock-alarm-delete"

  init?(addonName: String) {
    self.init(rawValue: addonName)
  }

  var mutationFieldName: String? {
    switch self {
    case .list:
      nil
    case .create:
      "createClockAlarm"
    case .toggle:
      "toggleClockAlarm"
    case .update:
      "updateClockAlarm"
    case .delete:
      "deleteClockAlarm"
    }
  }

  var requiredShortcutName: String {
    switch self {
    case .list:
      "apple-gateway-get-alarms"
    case .create:
      "apple-gateway-create-alarm"
    case .toggle:
      "apple-gateway-toggle-alarm"
    case .update:
      "apple-gateway-update-alarm"
    case .delete:
      "apple-gateway-delete-alarm"
    }
  }

  var actionPastTense: String {
    switch self {
    case .list:
      "listed"
    case .create:
      "created"
    case .toggle:
      "toggled"
    case .update:
      "updated"
    case .delete:
      "deleted"
    }
  }

  var requiresMacOS26: Bool {
    self == .update || self == .delete
  }
}

private struct AppleClockAlarmEngine {
  private static let validWeekdays: Set<String> = [
    "MONDAY",
    "TUESDAY",
    "WEDNESDAY",
    "THURSDAY",
    "FRIDAY",
    "SATURDAY",
    "SUNDAY"
  ]

  var environment: [String: String]

  func execute(
    _ operation: AppleClockAlarmOperation,
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
    let request = try graphQLRequest(operation: operation, input: input, config: config, variables: variables)
    var arguments = ["graphql", "--query", request.document]
    if let requestVariables = request.variables {
      arguments += ["--variables", try requestVariables.compactJSONString()]
    }
    let processOutput = try runGraphQLRequest(
      resolvedBinary: resolvedBinary,
      arguments: arguments,
      deadline: context.deadline
    )
    if processOutput.terminationStatus != 0 {
      if let envelope = graphQLErrorEnvelope(from: processOutput, addonName: input.addon.name) {
        throw classifiedGraphQLError(operation: operation, input: input, errors: envelope.errors)
      }
      let detail = appleGatewayCompactText(processOutput.stderr.isEmpty ? processOutput.stdout : processOutput.stderr)
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway failed with exit code \(processOutput.terminationStatus): \(detail)"
      )
    }
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw classifiedGraphQLError(operation: operation, input: input, errors: envelope.errors)
    }

    switch operation {
    case .list:
      return try listOutput(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    case .create, .toggle, .update, .delete:
      return try mutationOutput(operation: operation, input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    }
  }

  private func runGraphQLRequest(
    resolvedBinary: AppleGatewayResolvedBinary,
    arguments: [String],
    deadline: Date?
  ) throws -> AppleGatewayProcessOutput {
    let runner = AppleGatewayProcessRunner(runtimeEnvironment: environment)
    return try runner.run(
      executablePath: resolvedBinary.path,
      arguments: arguments,
      deadline: deadline,
      allowNonzeroExit: true
    )
  }

  private func graphQLRequest(
    operation: AppleClockAlarmOperation,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> AppleClockAlarmGraphQLRequest {
    switch operation {
    case .list:
      return AppleClockAlarmGraphQLRequest(document: Self.listDocument, variables: nil)
    case .create:
      let time = try validatedTime(requiredString("time", input: input, config: config, variables: variables), input: input)
      var operationInput: JSONObject = ["time": .string(time)]
      appendOptionalString("label", to: &operationInput, config: config, variables: variables)
      try appendRepeatDaysIfPresent(to: &operationInput, input: input, config: config, variables: variables)
      return mutationRequest(document: Self.createDocument, input: operationInput)
    case .toggle:
      var operationInput: JSONObject = [
        "label": .string(try requiredString("label", input: input, config: config, variables: variables))
      ]
      if let enabled = try optionalBool("enabled", input: input, config: config, variables: variables) {
        operationInput["enabled"] = .bool(enabled)
      }
      return mutationRequest(document: Self.toggleDocument, input: operationInput)
    case .update:
      var operationInput: JSONObject = [
        "label": .string(try requiredString("label", input: input, config: config, variables: variables))
      ]
      if let time = optionalString("time", config: config, variables: variables) {
        operationInput["time"] = .string(try validatedTime(time, input: input))
      }
      appendOptionalString("newLabel", to: &operationInput, config: config, variables: variables)
      try appendRepeatDaysIfPresent(to: &operationInput, input: input, config: config, variables: variables)
      return mutationRequest(document: Self.updateDocument, input: operationInput)
    case .delete:
      let operationInput: JSONObject = [
        "label": .string(try requiredString("label", input: input, config: config, variables: variables))
      ]
      return mutationRequest(document: Self.deleteDocument, input: operationInput)
    }
  }

  private func mutationRequest(document: String, input: JSONObject) -> AppleClockAlarmGraphQLRequest {
    AppleClockAlarmGraphQLRequest(
      document: document,
      variables: .object(["input": .object(input)])
    )
  }

  private func listOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    let alarms = try appleGatewayRequiredArray(
      envelope.data["clockAlarms"],
      field: "\(input.addon.name) GraphQL data.clockAlarms"
    )
    let validatedAlarms = try alarms.enumerated().map { index, alarm in
      try validatedClockAlarm(alarm, field: "\(input.addon.name) GraphQL data.clockAlarms[\(index)]")
    }
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["clockAlarms"] = .array(validatedAlarms)
    payload["alarmCount"] = .number(Double(validatedAlarms.count))
    payload["replyText"] = .string("Listed \(validatedAlarms.count) Apple Clock alarms.")
    return output(input: input, when: ["always": true, "has_alarms": !validatedAlarms.isEmpty], payload: payload)
  }

  private func mutationOutput(
    operation: AppleClockAlarmOperation,
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    guard let fieldName = operation.mutationFieldName else {
      throw AdapterExecutionError(.providerError, "missing mutation field for \(input.addon.name)")
    }
    let result = try envelope.mutationField(fieldName, addonName: input.addon.name)
    guard let success = boolValue(result["success"]) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.\(fieldName).success must be a boolean")
    }
    if !success {
      let warning = nonEmptyString(result["warning"]) ?? "Clock alarm operation did not succeed"
      throw AdapterExecutionError(.providerError, "\(input.addon.name) failed: \(appleGatewayCompactText(warning))")
    }
    let alarm = try validatedOptionalClockAlarm(
      result["alarm"],
      field: "\(input.addon.name) GraphQL data.\(fieldName).alarm"
    )
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["clockAlarm"] = alarm
    payload["result"] = .object(result)
    payload["replyText"] = .string("Apple Clock alarm \(operation.actionPastTense).")
    return output(input: input, when: ["always": true, "succeeded": true], payload: payload)
  }

  private func validatedOptionalClockAlarm(_ value: JSONValue?, field: String) throws -> JSONValue {
    guard let value else {
      throw AdapterExecutionError(.invalidOutput, "\(field) must be null or a ClockAlarm object")
    }
    if case .null = value {
      return .null
    }
    return try validatedClockAlarm(value, field: field)
  }

  private func validatedClockAlarm(_ value: JSONValue, field: String) throws -> JSONValue {
    guard case let .object(alarm) = value else {
      throw AdapterExecutionError(.invalidOutput, "\(field) must be a ClockAlarm object")
    }
    try requireClockAlarmString(alarm["id"], field: "\(field).id")
    try requireClockAlarmString(alarm["label"], field: "\(field).label")
    try requireClockAlarmString(alarm["time"], field: "\(field).time")
    guard boolValue(alarm["isEnabled"]) != nil else {
      throw AdapterExecutionError(.invalidOutput, "\(field).isEnabled must be a boolean")
    }
    let repeatDays = try appleGatewayRequiredArray(alarm["repeatDays"], field: "\(field).repeatDays")
    for (index, repeatDay) in repeatDays.enumerated() {
      try requireClockAlarmString(repeatDay, field: "\(field).repeatDays[\(index)]")
    }
    return value
  }

  private func requireClockAlarmString(_ value: JSONValue?, field: String) throws {
    guard nonEmptyString(value) != nil else {
      throw AdapterExecutionError(.invalidOutput, "\(field) must be a non-empty string")
    }
  }

  private func graphQLErrorEnvelope(
    from output: AppleGatewayProcessOutput,
    addonName: String
  ) -> AppleGatewayGraphQLEnvelope? {
    for candidate in [output.stdout, output.stderr] where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let envelope = try? AppleGatewayGraphQLEnvelope(stdout: candidate, addonName: addonName),
        !envelope.errors.isEmpty
      else {
        continue
      }
      return envelope
    }
    return nil
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
        "hostOSVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
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

  private func classifiedGraphQLError(
    operation: AppleClockAlarmOperation,
    input: WorkflowAddonExecutionInput,
    errors: [String]
  ) -> AdapterExecutionError {
    let detail = appleGatewayCompactText(errors.joined(separator: "; "))
    let normalized = detail.lowercased()
    let missingBridgeTokens = [
      "shortcut_bridge_missing",
      "shortcut_not_found",
      "shortcuts_clock_bridge",
      "shortcutsclockbridge",
      "missing shortcut",
      "shortcut not found",
      "could not find shortcut"
    ]
    if missingBridgeTokens.contains(where: { normalized.contains($0) }) {
      return AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) requires Shortcuts Clock bridge shortcut '\(operation.requiredShortcutName)' from apple-gateway packaging/shortcuts and permission shortcutsClockBridge: \(detail)"
      )
    }
    let osVersionTokens = [
      "unsupported_os_version",
      "unsupported os version",
      "requires macos 26",
      "macos 26+",
      "macos 26 or newer"
    ]
    if operation.requiresMacOS26, osVersionTokens.contains(where: { normalized.contains($0) }) {
      return AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) requires macOS 26+: \(detail)"
      )
    }
    return AdapterExecutionError(
      .providerError,
      "\(input.addon.name) GraphQL errors: \(detail)"
    )
  }

  private func requiredString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> String {
    guard let value = optionalString(key, config: config, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    return value
  }

  private func appendOptionalString(_ key: String, to object: inout JSONObject, config: JSONObject, variables: JSONObject) {
    if let value = optionalString(key, config: config, variables: variables) {
      object[key] = .string(value)
    }
  }

  private func optionalString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    guard let value = nonEmptyString(variables[key])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    return value.isEmpty ? nil : value
  }

  private func optionalBool(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> Bool? {
    if let value = boolValue(config[key]) {
      return value
    }
    if config[key] != nil {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
    }
    if let value = boolValue(variables[key]) {
      return value
    }
    if variables[key] != nil {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
    }
    return nil
  }

  private func appendRepeatDaysIfPresent(
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws {
    guard let repeatDays = try optionalRepeatDays(input: input, config: config, variables: variables) else {
      return
    }
    object["repeatDays"] = .array(repeatDays.map { .string($0) })
  }

  private func optionalRepeatDays(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> [String]? {
    if let value = config["repeatDays"] {
      return try repeatDays(from: value, input: input)
    }
    if let value = variables["repeatDays"] {
      return try repeatDays(from: value, input: input)
    }
    return nil
  }

  private func repeatDays(from value: JSONValue, input: WorkflowAddonExecutionInput) throws -> [String]? {
    let tokens: [String]
    if case let .array(values) = value {
      tokens = try values.map { value in
        guard let day = nonEmptyString(value) else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) repeatDays must be an array of weekday strings")
        }
        return day
      }
    } else if let raw = nonEmptyString(value) {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      tokens = trimmed.split(separator: ",").map(String.init)
    } else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) repeatDays must be a string array or comma-separated string")
    }
    return try tokens.map { token in
      let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard Self.validWeekdays.contains(normalized) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) repeatDays contains invalid weekday '\(token)'")
      }
      return normalized
    }
  }

  private func validatedTime(_ value: String, input: WorkflowAddonExecutionInput) throws -> String {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts[0].count == 2,
      parts[1].count == 2,
      Self.isASCIIDigits(parts[0]),
      Self.isASCIIDigits(parts[1]),
      let hour = Int(parts[0]),
      let minute = Int(parts[1]),
      (0...23).contains(hour),
      (0...59).contains(minute)
    else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) time must be HH:mm 24-hour format")
    }
    return value
  }

  private static func isASCIIDigits(_ value: Substring) -> Bool {
    value.utf8.allSatisfy { byte in
      (48...57).contains(byte)
    }
  }

  private static let alarmFields = """
      id
      label
      time
      isEnabled
      repeatDays
  """

  private static let listDocument = """
  query RielaAppleClockAlarmsList {
    clockAlarms {
  \(alarmFields)
    }
  }
  """

  private static let createDocument = """
  mutation RielaAppleClockAlarmCreate($input: CreateClockAlarmInput!) {
    createClockAlarm(input: $input) {
      success
      warning
      alarm {
  \(alarmFields)
      }
    }
  }
  """

  private static let toggleDocument = """
  mutation RielaAppleClockAlarmToggle($input: ToggleClockAlarmInput!) {
    toggleClockAlarm(input: $input) {
      success
      warning
      alarm {
  \(alarmFields)
      }
    }
  }
  """

  private static let updateDocument = """
  mutation RielaAppleClockAlarmUpdate($input: UpdateClockAlarmInput!) {
    updateClockAlarm(input: $input) {
      success
      warning
      alarm {
  \(alarmFields)
      }
    }
  }
  """

  private static let deleteDocument = """
  mutation RielaAppleClockAlarmDelete($input: DeleteClockAlarmInput!) {
    deleteClockAlarm(input: $input) {
      success
      warning
      alarm {
  \(alarmFields)
      }
    }
  }
  """
}

private struct AppleClockAlarmGraphQLRequest {
  var document: String
  var variables: JSONValue?
}
