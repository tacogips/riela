import Foundation

public enum AdapterExecutionErrorCode: String, Codable, Sendable {
  case providerError = "provider_error"
  case invalidInput = "invalid_input"
  case policyBlocked = "policy_blocked"
  case timeout
  case invalidOutput = "invalid_output"
}

public struct AdapterExecutionError: Error, Equatable, Sendable {
  public var code: AdapterExecutionErrorCode
  public var message: String

  public init(_ code: AdapterExecutionErrorCode, _ message: String) {
    self.code = code
    self.message = message
  }
}

public struct AdapterExecutionInput: Codable, Equatable, Sendable {
  public var node: AgentNodePayload
  public var promptText: String
  public var systemPromptText: String?
  public var sessionPolicy: WorkflowStepSessionPolicy?
  public var arguments: JSONObject
  public var mergedVariables: JSONObject
  public var agentEnvironment: [String: String]
  public var executionIndex: Int
  public var output: AdapterOutputAttemptContext?

  public init(
    node: AgentNodePayload,
    promptText: String,
    systemPromptText: String? = nil,
    sessionPolicy: WorkflowStepSessionPolicy? = nil,
    arguments: JSONObject = [:],
    mergedVariables: JSONObject = [:],
    agentEnvironment: [String: String] = [:],
    executionIndex: Int = 1,
    output: AdapterOutputAttemptContext? = nil
  ) {
    self.node = node
    self.promptText = promptText
    self.systemPromptText = systemPromptText
    self.sessionPolicy = sessionPolicy
    self.arguments = arguments
    self.mergedVariables = mergedVariables
    self.agentEnvironment = agentEnvironment
    self.executionIndex = executionIndex
    self.output = output
  }
}

public enum AdapterBackendEventChannel: String, Codable, Equatable, Sendable {
  case lifecycle
  case assistant
  case thinking
  case tool
  case usage
}

public struct AdapterBackendEvent: Equatable, Sendable {
  public var provider: String
  public var eventType: String
  public var channel: AdapterBackendEventChannel?
  public var contentDelta: String?
  public var contentSnapshot: String?
  public var isDelta: Bool
  public var toolName: String?
  public var usage: JSONObject?
  public var sequence: Int?
  public var at: Date?

  public init(
    provider: String,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    contentDelta: String? = nil,
    contentSnapshot: String? = nil,
    isDelta: Bool = false,
    toolName: String? = nil,
    usage: JSONObject? = nil,
    sequence: Int? = nil,
    at: Date? = nil
  ) {
    self.provider = provider
    self.eventType = eventType
    self.channel = channel
    self.contentDelta = contentDelta
    self.contentSnapshot = contentSnapshot
    self.isDelta = isDelta
    self.toolName = toolName
    self.usage = usage
    self.sequence = sequence
    self.at = at
  }
}

public typealias AdapterBackendEventHandler = @Sendable (AdapterBackendEvent) async -> Void

public struct AdapterExecutionContext: Sendable {
  public var deadline: Date?
  public var backendEventHandler: AdapterBackendEventHandler?

  public init(deadline: Date? = nil, backendEventHandler: AdapterBackendEventHandler? = nil) {
    self.deadline = deadline
    self.backendEventHandler = backendEventHandler
  }
}

public struct AdapterOutputAttemptContext: Codable, Equatable, Sendable {
  public var maxValidationAttempts: Int
  public var attempt: Int

  public init(maxValidationAttempts: Int, attempt: Int) {
    self.maxValidationAttempts = maxValidationAttempts
    self.attempt = attempt
  }
}

public struct AdapterExecutionOutput: Codable, Equatable, Sendable {
  public var provider: String
  public var model: String
  public var promptText: String
  public var completionPassed: Bool
  public var when: [String: Bool]
  public var payload: JSONObject

  public init(
    provider: String,
    model: String,
    promptText: String,
    completionPassed: Bool,
    when: [String: Bool] = ["always": true],
    payload: JSONObject
  ) {
    self.provider = provider
    self.model = model
    self.promptText = promptText
    self.completionPassed = completionPassed
    self.when = when
    self.payload = payload
  }
}

public protocol NodeAdapter: Sendable {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput
}

public func normalizeTextBusinessPayload(_ text: String) -> JSONObject {
  ["text": .string(text)]
}

public struct OutputContractEnvelopeNormalization: Equatable, Sendable {
  public var completionPassed: Bool
  public var when: [String: Bool]
  public var payload: JSONObject
  public var usedEnvelope: Bool
  public var routingDiagnostics: [String]

  public init(
    completionPassed: Bool,
    when: [String: Bool],
    payload: JSONObject,
    usedEnvelope: Bool,
    routingDiagnostics: [String] = []
  ) {
    self.completionPassed = completionPassed
    self.when = when
    self.payload = payload
    self.usedEnvelope = usedEnvelope
    self.routingDiagnostics = routingDiagnostics
  }
}

public struct OutputContractRoutingReconciliation: Equatable, Sendable {
  public var when: [String: Bool]
  public var diagnostics: [String]

  public init(when: [String: Bool], diagnostics: [String] = []) {
    self.when = when
    self.diagnostics = diagnostics
  }
}

public typealias OutputContractRoutingReconciler =
  @Sendable (_ when: [String: Bool], _ payload: JSONObject) -> OutputContractRoutingReconciliation

public func normalizeOutputContractEnvelope(
  _ value: JSONObject,
  source: String,
  defaults: (completionPassed: Bool, when: [String: Bool]) = (true, ["always": true]),
  routingReconciler: OutputContractRoutingReconciler? = nil
) throws -> OutputContractEnvelopeNormalization {
  guard let whenValue = value["when"] else {
    let reconciled = routingReconciler?(defaults.when, value)
      ?? OutputContractRoutingReconciliation(when: defaults.when)
    return OutputContractEnvelopeNormalization(
      completionPassed: defaults.completionPassed,
      when: reconciled.when,
      payload: value,
      usedEnvelope: false,
      routingDiagnostics: reconciled.diagnostics
    )
  }

  guard let when = booleanMap(from: whenValue) else {
    throw AdapterExecutionError(.invalidOutput, "\(source).when must be an object<boolean> when provided")
  }

  guard let payloadValue = value["payload"], case let .object(payload) = payloadValue else {
    throw AdapterExecutionError(.invalidOutput, "\(source).payload must be an object when when is provided")
  }

  let completionPassed: Bool
  if let completionPassedValue = value["completionPassed"] {
    guard case let .bool(value) = completionPassedValue else {
      throw AdapterExecutionError(.invalidOutput, "\(source).completionPassed must be a boolean when provided")
    }
    completionPassed = value
  } else {
    completionPassed = defaults.completionPassed
  }

  let reconciled = routingReconciler?(when, payload)
    ?? OutputContractRoutingReconciliation(when: when)
  return OutputContractEnvelopeNormalization(
    completionPassed: completionPassed,
    when: reconciled.when,
    payload: payload,
    usedEnvelope: true,
    routingDiagnostics: reconciled.diagnostics
  )
}

private func booleanMap(from value: JSONValue) -> [String: Bool]? {
  guard case let .object(object) = value else {
    return nil
  }
  var map: [String: Bool] = [:]
  for (key, entry) in object {
    guard case let .bool(boolValue) = entry else {
      return nil
    }
    map[key] = boolValue
  }
  return map
}
