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
  public var isRetryable: Bool?
  public var retryAfter: Duration?

  public init(
    _ code: AdapterExecutionErrorCode,
    _ message: String,
    isRetryable: Bool? = nil,
    retryAfter: Duration? = nil
  ) {
    self.code = code
    self.message = message
    self.isRetryable = isRetryable
    self.retryAfter = retryAfter
  }
}

public struct AdapterUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?
  public var cacheReadInputTokens: Int?
  public var cacheCreationInputTokens: Int?
  public var providerRaw: JSONObject

  public init(
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    totalTokens: Int? = nil,
    cacheReadInputTokens: Int? = nil,
    cacheCreationInputTokens: Int? = nil,
    providerRaw: JSONObject = [:]
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.cacheReadInputTokens = cacheReadInputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.providerRaw = providerRaw
  }

  public var eventPayload: JSONObject {
    var payload: JSONObject = [:]
    if let inputTokens {
      payload["input_tokens"] = .integer(Int64(inputTokens))
    }
    if let outputTokens {
      payload["output_tokens"] = .integer(Int64(outputTokens))
    }
    if let totalTokens {
      payload["total_tokens"] = .integer(Int64(totalTokens))
    }
    if let cacheReadInputTokens {
      payload["cache_read_input_tokens"] = .integer(Int64(cacheReadInputTokens))
    }
    if let cacheCreationInputTokens {
      payload["cache_creation_input_tokens"] = .integer(Int64(cacheCreationInputTokens))
    }
    if !providerRaw.isEmpty {
      payload["provider_raw"] = .object(providerRaw)
    }
    return payload
  }
}

public struct AdapterExecutionInput: Codable, Equatable, Sendable {
  public var node: AgentNodePayload
  public var promptText: String
  public var freshPromptText: String?
  public var resumedPromptText: String?
  public var systemPromptText: String?
  public var sessionPolicy: WorkflowStepSessionPolicy?
  public var executionIdentity: AdapterExecutionIdentity?
  public var arguments: JSONObject
  public var mergedVariables: JSONObject
  public var agentEnvironment: [String: String]
  public var executionIndex: Int
  public var output: AdapterOutputAttemptContext?

  public init(
    node: AgentNodePayload,
    promptText: String,
    freshPromptText: String? = nil,
    resumedPromptText: String? = nil,
    systemPromptText: String? = nil,
    sessionPolicy: WorkflowStepSessionPolicy? = nil,
    executionIdentity: AdapterExecutionIdentity? = nil,
    arguments: JSONObject = [:],
    mergedVariables: JSONObject = [:],
    agentEnvironment: [String: String] = [:],
    executionIndex: Int = 1,
    output: AdapterOutputAttemptContext? = nil
  ) {
    self.node = node
    self.promptText = promptText
    self.freshPromptText = freshPromptText
    self.resumedPromptText = resumedPromptText
    self.systemPromptText = systemPromptText
    self.sessionPolicy = sessionPolicy
    self.executionIdentity = executionIdentity
    self.arguments = arguments
    self.mergedVariables = mergedVariables
    self.agentEnvironment = agentEnvironment
    self.executionIndex = executionIndex
    self.output = output
  }

  public var resolvedFreshPromptText: String {
    freshPromptText ?? promptText
  }

  public var resolvedResumedPromptText: String {
    resumedPromptText ?? promptText
  }
}

public struct AdapterExecutionIdentity: Codable, Equatable, Hashable, Sendable {
  public var workflowRunId: String
  public var workflowSessionId: String
  public var stepId: String

  public init(workflowRunId: String, workflowSessionId: String, stepId: String) {
    self.workflowRunId = workflowRunId
    self.workflowSessionId = workflowSessionId
    self.stepId = stepId
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
  public var metadata: JSONObject?
  public var sequence: Int?
  public var at: Date?
  public var backendSessionId: String?

  public init(
    provider: String,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    contentDelta: String? = nil,
    contentSnapshot: String? = nil,
    isDelta: Bool = false,
    toolName: String? = nil,
    usage: JSONObject? = nil,
    metadata: JSONObject? = nil,
    sequence: Int? = nil,
    at: Date? = nil,
    backendSessionId: String? = nil
  ) {
    self.provider = provider
    self.eventType = eventType
    self.channel = channel
    self.contentDelta = contentDelta
    self.contentSnapshot = contentSnapshot
    self.isDelta = isDelta
    self.toolName = toolName
    self.usage = usage
    self.metadata = metadata
    self.sequence = sequence
    self.at = at
    self.backendSessionId = backendSessionId
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
  public var usage: AdapterUsage?

  public init(
    provider: String,
    model: String,
    promptText: String,
    completionPassed: Bool,
    when: [String: Bool] = ["always": true],
    payload: JSONObject,
    usage: AdapterUsage? = nil
  ) {
    self.provider = provider
    self.model = model
    self.promptText = promptText
    self.completionPassed = completionPassed
    self.when = when
    self.payload = payload
    self.usage = usage
  }
}

public protocol NodeAdapter: Sendable {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput
  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async
}

public struct WorkflowRunLifecycleContext: Equatable, Sendable {
  public var workflowRunId: String

  public init(workflowRunId: String) {
    self.workflowRunId = workflowRunId
  }
}

public extension NodeAdapter {
  func workflowRunDidEnd(_: WorkflowRunLifecycleContext) async {}
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
