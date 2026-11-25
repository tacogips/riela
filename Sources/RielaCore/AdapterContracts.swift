import Foundation

public enum AdapterExecutionErrorCode: String, Codable, Sendable {
  case providerError = "provider_error"
  case invalidInput = "invalid_input"
  case policyBlocked = "policy_blocked"
  case timeout
  case invalidOutput = "invalid_output"
  case templateResolutionFailed = "template_resolution_failed"
}

public enum AdapterEffectOutcome: String, Codable, Sendable, Equatable {
  case notDispatched, rejected, unknown
}

public struct AdapterExecutionError: Error, Equatable, Sendable {
  public var code: AdapterExecutionErrorCode
  public var message: String
  public var isRetryable: Bool?
  public var retryAfter: Duration?
  public var failureKind: WorkflowSessionFailureKind?
  public var effectOutcome: AdapterEffectOutcome?

  public init(
    _ code: AdapterExecutionErrorCode,
    _ message: String,
    isRetryable: Bool? = nil,
    retryAfter: Duration? = nil,
    failureKind: WorkflowSessionFailureKind? = nil,
    effectOutcome: AdapterEffectOutcome? = nil
  ) {
    self.code = code
    self.message = message
    self.isRetryable = isRetryable
    self.retryAfter = retryAfter
    self.failureKind = failureKind
    self.effectOutcome = effectOutcome
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

public struct AdapterMCPServer: Codable, Equatable, Sendable {
  public var name: String
  public var command: String
  public var arguments: [String]
  public var environment: [String: String]

  public init(name: String, command: String, arguments: [String], environment: [String: String]) {
    self.name = name
    self.command = command
    self.arguments = arguments
    self.environment = environment
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
  public var mcpServers: [AdapterMCPServer]

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
    output: AdapterOutputAttemptContext? = nil,
    mcpServers: [AdapterMCPServer] = []
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
    self.mcpServers = mcpServers
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    node = try container.decode(AgentNodePayload.self, forKey: .node)
    promptText = try container.decode(String.self, forKey: .promptText)
    freshPromptText = try container.decodeIfPresent(String.self, forKey: .freshPromptText)
    resumedPromptText = try container.decodeIfPresent(String.self, forKey: .resumedPromptText)
    systemPromptText = try container.decodeIfPresent(String.self, forKey: .systemPromptText)
    sessionPolicy = try container.decodeIfPresent(WorkflowStepSessionPolicy.self, forKey: .sessionPolicy)
    executionIdentity = try container.decodeIfPresent(AdapterExecutionIdentity.self, forKey: .executionIdentity)
    arguments = try container.decode(JSONObject.self, forKey: .arguments)
    mergedVariables = try container.decode(JSONObject.self, forKey: .mergedVariables)
    agentEnvironment = try container.decode([String: String].self, forKey: .agentEnvironment)
    executionIndex = try container.decode(Int.self, forKey: .executionIndex)
    output = try container.decodeIfPresent(AdapterOutputAttemptContext.self, forKey: .output)
    mcpServers = try container.decodeIfPresent([AdapterMCPServer].self, forKey: .mcpServers) ?? []
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

public enum AdapterActivityUpdate: Codable, Equatable, Sendable {
  case message(messageId: String?, text: String, replace: Bool)
  case thought(text: String)
  case toolCall(AdapterActivityToolCall)
  case plan(planId: String, entries: [AdapterActivityPlanEntry])
  case planRemoved(planId: String)
  case mode(modeId: String)
  case commands(names: [String])
  case configOptions(options: [JSONObject])
  case sessionInfo(title: String?)
  case usage(JSONObject)
  case notice(severity: String, title: String, description: String?)
  case subagent(subSessionId: String, title: String?, state: String?)
  case stop(stopReason: String, limited: Bool, limitedResetAt: Date?)
  case reportedModel(String)
  case other(updateKind: String)
}

public struct AdapterActivityLocation: Codable, Equatable, Sendable {
  public var path: String
  public var line: Int?

  public init(path: String, line: Int? = nil) {
    self.path = path
    self.line = line
  }
}

/// Optional fields are nil when the backend update did not carry them.
public struct AdapterActivityToolCall: Codable, Equatable, Sendable {
  public var toolCallId: String
  public var title: String?
  public var toolKind: String?
  public var status: String?
  public var locations: [AdapterActivityLocation]?

  public init(
    toolCallId: String, title: String? = nil, toolKind: String? = nil,
    status: String? = nil, locations: [AdapterActivityLocation]? = nil
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.toolKind = toolKind
    self.status = status
    self.locations = locations
  }
}

public struct AdapterActivityPlanEntry: Codable, Equatable, Sendable {
  public var content: String
  public var status: String
  public var priority: String

  public init(content: String, status: String, priority: String) {
    self.content = content
    self.status = status
    self.priority = priority
  }
}

public struct AdapterPermissionOption: Codable, Equatable, Sendable {
  public var optionId: String
  public var name: String
  public var kind: String

  public init(optionId: String, name: String, kind: String) {
    self.optionId = optionId
    self.name = name
    self.kind = kind
  }
}

public struct AdapterPermissionRequest: Codable, Equatable, Sendable {
  public var toolCallId: String?
  public var title: String?
  public var options: [AdapterPermissionOption]

  public init(toolCallId: String? = nil, title: String? = nil, options: [AdapterPermissionOption]) {
    self.toolCallId = toolCallId
    self.title = title
    self.options = options
  }
}

public enum AdapterPermissionOutcome: Codable, Equatable, Sendable {
  case selected(optionId: String)
  case cancelled
}

public typealias AdapterPermissionRequestHandler = @Sendable (AdapterPermissionRequest) async -> AdapterPermissionOutcome

public enum AdapterBackendEventChannel: String, Codable, Equatable, Sendable {
  case lifecycle
  case assistant
  case thinking
  case tool
  case usage
}

public struct AdapterBackendEvent: Codable, Equatable, Sendable {
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
  public var activity: AdapterActivityUpdate?

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
    backendSessionId: String? = nil,
    activity: AdapterActivityUpdate? = nil
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
    self.activity = activity
  }
}

public typealias AdapterBackendEventHandler = @Sendable (AdapterBackendEvent) async -> Void

public struct AdapterExecutionContext: Sendable {
  public var deadline: Date?
  public var backendEventHandler: AdapterBackendEventHandler?

  public var permissionRequestHandler: AdapterPermissionRequestHandler?

  public init(
    deadline: Date? = nil,
    backendEventHandler: AdapterBackendEventHandler? = nil,
    permissionRequestHandler: AdapterPermissionRequestHandler? = nil
  ) {
    self.deadline = deadline
    self.backendEventHandler = backendEventHandler
    self.permissionRequestHandler = permissionRequestHandler
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
  public var runtimeFinalizationToken: WorkflowAddonFinalizationToken?
  /// Normalization notes the adapter produced before handing over the payload
  /// (for example a flattened `when` envelope). The runtime merges them into
  /// the accepted output's routing diagnostics. Like the finalization token,
  /// they are runtime-local and never encoded, so no worker or guest can
  /// smuggle free text through them.
  public var routingDiagnostics: [String]

  public init(
    provider: String,
    model: String,
    promptText: String,
    completionPassed: Bool,
    when: [String: Bool] = ["always": true],
    payload: JSONObject,
    usage: AdapterUsage? = nil,
    runtimeFinalizationToken: WorkflowAddonFinalizationToken? = nil,
    routingDiagnostics: [String] = []
  ) {
    self.provider = provider
    self.model = model
    self.promptText = promptText
    self.completionPassed = completionPassed
    self.when = when
    self.payload = payload
    self.usage = usage
    self.runtimeFinalizationToken = runtimeFinalizationToken
    self.routingDiagnostics = routingDiagnostics
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case model
    case promptText
    case completionPassed
    case when
    case payload
    case usage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(String.self, forKey: .provider)
    model = try container.decode(String.self, forKey: .model)
    promptText = try container.decode(String.self, forKey: .promptText)
    completionPassed = try container.decode(Bool.self, forKey: .completionPassed)
    when = try container.decodeIfPresent([String: Bool].self, forKey: .when) ?? ["always": true]
    payload = try container.decode(JSONObject.self, forKey: .payload)
    usage = try container.decodeIfPresent(AdapterUsage.self, forKey: .usage)
    runtimeFinalizationToken = nil
    routingDiagnostics = []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(model, forKey: .model)
    try container.encode(promptText, forKey: .promptText)
    try container.encode(completionPassed, forKey: .completionPassed)
    try container.encode(when, forKey: .when)
    try container.encode(payload, forKey: .payload)
    try container.encodeIfPresent(usage, forKey: .usage)
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

  let payload: JSONObject
  var envelopeDiagnostics: [String] = []
  if let payloadValue = value["payload"] {
    guard case let .object(object) = payloadValue else {
      throw AdapterExecutionError(.invalidOutput, "\(source).payload must be an object when when is provided")
    }
    payload = object
  } else {
    // Flattened routing envelope: a valid boolean `when` map with the business
    // fields beside it instead of under `payload`. The intent is unambiguous,
    // so treat the remaining top-level fields as the payload rather than
    // rejecting the whole output; the output schema still validates them.
    var flattened = value
    flattened.removeValue(forKey: "when")
    flattened.removeValue(forKey: "completionPassed")
    payload = flattened
    envelopeDiagnostics.append(
      "\(source) returned `when` without `payload`; normalized the sibling top-level fields as the payload"
    )
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
    routingDiagnostics: envelopeDiagnostics + reconciled.diagnostics
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
