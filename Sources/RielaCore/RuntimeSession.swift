import Foundation

public enum WorkflowSessionStatus: String, Codable, Sendable {
  case created
  case running
  case completed
  case failed
}

public enum WorkflowStepExecutionStatus: String, Codable, Sendable {
  case running
  case completed
  case skipped
  case failed
}

public struct WorkflowSessionFailureKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let maxStepsExceeded = WorkflowSessionFailureKind(rawValue: "maxStepsExceeded")
  public static let cancelled = WorkflowSessionFailureKind(rawValue: "cancelled")
  public static let adapterFailure = WorkflowSessionFailureKind(rawValue: "adapterFailure")
  public static let policyBlocked = WorkflowSessionFailureKind(rawValue: "policyBlocked")
  public static let nodeTimeout = WorkflowSessionFailureKind(rawValue: "nodeTimeout")
  public static let internalFailure = WorkflowSessionFailureKind(rawValue: "internal")
  public static let loopNotConverging = WorkflowSessionFailureKind(rawValue: "loopNotConverging")

  public var compatibilityDiagnostic: String? {
    guard !Self.knownRawValues.contains(rawValue) else {
      return nil
    }
    return "workflow session preserves unknown failure kind '\(rawValue)'"
  }

  private static let knownRawValues: Set<String> = [
    maxStepsExceeded.rawValue,
    cancelled.rawValue,
    adapterFailure.rawValue,
    policyBlocked.rawValue,
    nodeTimeout.rawValue,
    internalFailure.rawValue,
    loopNotConverging.rawValue
  ]
}

public enum WorkflowStepBudgetSource: String, Codable, Equatable, Sendable {
  case commandLine = "command-line"
  case computedDefault = "computed-default"
}

public struct WorkflowStepBudgetDiagnostic: Codable, Equatable, Sendable {
  public var stepBudget: Int
  public var executionCount: Int
  public var maxLoopIterations: Int
  public var budgetSource: WorkflowStepBudgetSource
  public var perStepExecutionCounts: [String: Int]
  public var dominantCycleStepIds: [String]?
  public var dominantCycleRepeatCount: Int?
  public var perStepRevisitCap: Int?
  public var projectedCapExceededStepIds: [String]?
  public var openReviewFindingCount: Int
  public var unscheduledStepId: String?
  public var suggestedMaxSteps: Int?
  public var suggestedRemediation: String?

  public init(
    stepBudget: Int,
    executionCount: Int,
    maxLoopIterations: Int,
    budgetSource: WorkflowStepBudgetSource,
    perStepExecutionCounts: [String: Int] = [:],
    dominantCycleStepIds: [String]? = nil,
    dominantCycleRepeatCount: Int? = nil,
    perStepRevisitCap: Int? = nil,
    projectedCapExceededStepIds: [String]? = nil,
    openReviewFindingCount: Int = 0,
    unscheduledStepId: String? = nil,
    suggestedMaxSteps: Int? = nil,
    suggestedRemediation: String? = nil
  ) {
    self.stepBudget = stepBudget
    self.executionCount = executionCount
    self.maxLoopIterations = maxLoopIterations
    self.budgetSource = budgetSource
    self.perStepExecutionCounts = perStepExecutionCounts
    self.dominantCycleStepIds = dominantCycleStepIds
    self.dominantCycleRepeatCount = dominantCycleRepeatCount
    self.perStepRevisitCap = perStepRevisitCap
    self.projectedCapExceededStepIds = projectedCapExceededStepIds
    self.openReviewFindingCount = openReviewFindingCount
    self.unscheduledStepId = unscheduledStepId
    self.suggestedMaxSteps = suggestedMaxSteps
    self.suggestedRemediation = suggestedRemediation
  }
}

public struct WorkflowAcceptedOutputMetadata: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case payload
    case when
    case isRootOutput
    case acceptedAt
    case routingDiagnostics
  }

  public var payload: JSONObject
  public var when: [String: Bool]
  public var isRootOutput: Bool
  public var acceptedAt: Date
  public var routingDiagnostics: [String]

  public init(
    payload: JSONObject,
    when: [String: Bool],
    isRootOutput: Bool = false,
    acceptedAt: Date,
    routingDiagnostics: [String] = []
  ) {
    self.payload = payload
    self.when = when
    self.isRootOutput = isRootOutput
    self.acceptedAt = acceptedAt
    self.routingDiagnostics = routingDiagnostics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.payload = try container.decode(JSONObject.self, forKey: .payload)
    self.when = try container.decode([String: Bool].self, forKey: .when)
    self.isRootOutput = try container.decodeIfPresent(Bool.self, forKey: .isRootOutput) ?? false
    self.acceptedAt = try container.decode(Date.self, forKey: .acceptedAt)
    self.routingDiagnostics = try container.decodeIfPresent([String].self, forKey: .routingDiagnostics) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(payload, forKey: .payload)
    try container.encode(when, forKey: .when)
    try container.encode(isRootOutput, forKey: .isRootOutput)
    try container.encode(acceptedAt, forKey: .acceptedAt)
    if !routingDiagnostics.isEmpty {
      try container.encode(routingDiagnostics, forKey: .routingDiagnostics)
    }
  }
}

public struct WorkflowAdapterOutputMetadata: Codable, Equatable, Sendable {
  public var provider: String
  public var model: String
  public var completionPassed: Bool
  public var when: [String: Bool]

  public init(provider: String, model: String, completionPassed: Bool, when: [String: Bool]) {
    self.provider = provider
    self.model = model
    self.completionPassed = completionPassed
    self.when = when
  }
}

public struct WorkflowStepExecution: Codable, Equatable, Sendable {
  public var executionId: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var backend: NodeExecutionBackend?
  public var status: WorkflowStepExecutionStatus
  public var acceptedOutput: WorkflowAcceptedOutputMetadata?
  public var adapterOutput: WorkflowAdapterOutputMetadata?
  public var failureReason: String?
  public var lastBackendEventAt: Date?
  public var lastBackendEventType: String?
  public var backendEventCount: Int?
  public var recentBackendEvents: [WorkflowBackendEventRecord]?
  public var streamedResponseText: String?
  public var usage: AdapterUsage?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    executionId: String,
    stepId: String,
    nodeId: String,
    attempt: Int,
    backend: NodeExecutionBackend? = nil,
    status: WorkflowStepExecutionStatus = .running,
    acceptedOutput: WorkflowAcceptedOutputMetadata? = nil,
    adapterOutput: WorkflowAdapterOutputMetadata? = nil,
    failureReason: String? = nil,
    lastBackendEventAt: Date? = nil,
    lastBackendEventType: String? = nil,
    backendEventCount: Int? = nil,
    recentBackendEvents: [WorkflowBackendEventRecord]? = nil,
    streamedResponseText: String? = nil,
    usage: AdapterUsage? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.executionId = executionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.backend = backend
    self.status = status
    self.acceptedOutput = acceptedOutput
    self.adapterOutput = adapterOutput
    self.failureReason = failureReason
    self.lastBackendEventAt = lastBackendEventAt
    self.lastBackendEventType = lastBackendEventType
    self.backendEventCount = backendEventCount
    self.recentBackendEvents = recentBackendEvents
    self.streamedResponseText = streamedResponseText
    self.usage = usage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WorkflowBackendEventRecord: Codable, Equatable, Sendable {
  public var sequence: Int
  public var at: Date
  public var eventType: String
  public var channel: AdapterBackendEventChannel?
  public var content: String?
  public var toolName: String?
  public var usage: JSONObject?

  public init(
    sequence: Int,
    at: Date,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    content: String? = nil,
    toolName: String? = nil,
    usage: JSONObject? = nil
  ) {
    self.sequence = sequence
    self.at = at
    self.eventType = eventType
    self.channel = channel
    self.content = content
    self.toolName = toolName
    self.usage = usage
  }
}

public struct WorkflowSession: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case workflowId
    case sessionId
    case status
    case entryStepId
    case currentStepId
    case createdAt
    case updatedAt
    case executions
    case fanoutGroups
    case reviewFindings
    case failureReason
    case failureKind
    case failedAt
    case stepBudgetDiagnostic
    case instanceIdentity
    case instanceKind
    case instanceBaseIdentity
    case instanceConfiguration
  }

  public var workflowId: String
  public var sessionId: String
  public var status: WorkflowSessionStatus
  public var entryStepId: String
  public var currentStepId: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var executions: [WorkflowStepExecution]
  public var fanoutGroups: [WorkflowFanoutGroupRecord]?
  public var reviewFindings: [WorkflowReviewFinding]
  public var failureReason: String?
  public var failureKind: WorkflowSessionFailureKind?
  public var failedAt: Date?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var instanceBaseIdentity: String?
  public var instanceConfiguration: JSONObject?

  public var workflowExecutionId: String {
    get { sessionId }
    set { sessionId = newValue }
  }

  public init(
    workflowId: String,
    sessionId: String,
    status: WorkflowSessionStatus = .created,
    entryStepId: String,
    currentStepId: String? = nil,
    createdAt: Date,
    updatedAt: Date,
    executions: [WorkflowStepExecution] = [],
    fanoutGroups: [WorkflowFanoutGroupRecord]? = nil,
    reviewFindings: [WorkflowReviewFinding] = [],
    failureReason: String? = nil,
    failureKind: WorkflowSessionFailureKind? = nil,
    failedAt: Date? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    instanceBaseIdentity: String? = nil,
    instanceConfiguration: JSONObject? = nil
  ) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.status = status
    self.entryStepId = entryStepId
    self.currentStepId = currentStepId
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.executions = executions
    self.fanoutGroups = fanoutGroups
    self.reviewFindings = reviewFindings
    self.failureReason = failureReason
    self.failureKind = failureKind
    self.failedAt = failedAt
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.instanceBaseIdentity = instanceBaseIdentity
    self.instanceConfiguration = instanceConfiguration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.workflowId = try container.decode(String.self, forKey: .workflowId)
    self.sessionId = try container.decode(String.self, forKey: .sessionId)
    self.status = try container.decode(WorkflowSessionStatus.self, forKey: .status)
    self.entryStepId = try container.decode(String.self, forKey: .entryStepId)
    self.currentStepId = try container.decodeIfPresent(String.self, forKey: .currentStepId)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    self.executions = try container.decodeIfPresent([WorkflowStepExecution].self, forKey: .executions) ?? []
    self.fanoutGroups = try container.decodeIfPresent([WorkflowFanoutGroupRecord].self, forKey: .fanoutGroups)
    self.reviewFindings = try container.decodeIfPresent([WorkflowReviewFinding].self, forKey: .reviewFindings) ?? []
    self.failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    self.failureKind = try container.decodeIfPresent(WorkflowSessionFailureKind.self, forKey: .failureKind)
    self.failedAt = try container.decodeIfPresent(Date.self, forKey: .failedAt)
    self.stepBudgetDiagnostic = try container.decodeIfPresent(WorkflowStepBudgetDiagnostic.self, forKey: .stepBudgetDiagnostic)
    self.instanceIdentity = try container.decodeIfPresent(String.self, forKey: .instanceIdentity)
    self.instanceKind = try container.decodeIfPresent(String.self, forKey: .instanceKind)
    self.instanceBaseIdentity = try container.decodeIfPresent(String.self, forKey: .instanceBaseIdentity)
    self.instanceConfiguration = try container.decodeIfPresent(JSONObject.self, forKey: .instanceConfiguration)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workflowId, forKey: .workflowId)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(status, forKey: .status)
    try container.encode(entryStepId, forKey: .entryStepId)
    try container.encodeIfPresent(currentStepId, forKey: .currentStepId)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(executions, forKey: .executions)
    try container.encodeIfPresent(fanoutGroups, forKey: .fanoutGroups)
    try container.encode(reviewFindings, forKey: .reviewFindings)
    try container.encodeIfPresent(failureReason, forKey: .failureReason)
    try container.encodeIfPresent(failureKind, forKey: .failureKind)
    try container.encodeIfPresent(failedAt, forKey: .failedAt)
    try container.encodeIfPresent(stepBudgetDiagnostic, forKey: .stepBudgetDiagnostic)
    try container.encodeIfPresent(instanceIdentity, forKey: .instanceIdentity)
    try container.encodeIfPresent(instanceKind, forKey: .instanceKind)
    try container.encodeIfPresent(instanceBaseIdentity, forKey: .instanceBaseIdentity)
    try container.encodeIfPresent(instanceConfiguration, forKey: .instanceConfiguration)
  }
}

public enum WorkflowMessageRoutingScope: String, Codable, Sendable {
  case workflow
  case root
}

public enum WorkflowMessageDeliveryKind: String, Codable, Sendable {
  case direct
  case fanout
  case rootOutput = "root-output"
}

public enum WorkflowMessageLifecycleStatus: String, Codable, Sendable {
  case created
  case delivered
  case consumed
  case failed
  case superseded
}

public struct WorkflowMessageRecord: Codable, Equatable, Sendable {
  public var communicationId: String
  public var workflowExecutionId: String
  public var fromStepId: String?
  public var toStepId: String?
  public var routingScope: WorkflowMessageRoutingScope
  public var deliveryKind: WorkflowMessageDeliveryKind
  public var sourceStepExecutionId: String
  public var transitionCondition: String?
  public var payload: JSONObject
  public var artifactRefs: [String]
  public var lifecycleStatus: WorkflowMessageLifecycleStatus
  public var createdOrder: Int
  public var createdAt: Date

  public init(
    communicationId: String,
    workflowExecutionId: String,
    fromStepId: String?,
    toStepId: String?,
    routingScope: WorkflowMessageRoutingScope = .workflow,
    deliveryKind: WorkflowMessageDeliveryKind = .direct,
    sourceStepExecutionId: String,
    transitionCondition: String? = nil,
    payload: JSONObject,
    artifactRefs: [String] = [],
    lifecycleStatus: WorkflowMessageLifecycleStatus = .created,
    createdOrder: Int,
    createdAt: Date
  ) {
    self.communicationId = communicationId
    self.workflowExecutionId = workflowExecutionId
    self.fromStepId = fromStepId
    self.toStepId = toStepId
    self.routingScope = routingScope
    self.deliveryKind = deliveryKind
    self.sourceStepExecutionId = sourceStepExecutionId
    self.transitionCondition = transitionCondition
    self.payload = payload
    self.artifactRefs = artifactRefs
    self.lifecycleStatus = lifecycleStatus
    self.createdOrder = createdOrder
    self.createdAt = createdAt
  }
}
