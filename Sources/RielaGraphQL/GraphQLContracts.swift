import Foundation
import RielaCore

public struct GraphQLStepExecutionDTO: Codable, Equatable, Sendable {
  public var executionId: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var backend: String?
  public var status: String
  public var failureReason: String?

  public init(
    executionId: String,
    stepId: String,
    nodeId: String,
    attempt: Int,
    backend: String? = nil,
    status: String,
    failureReason: String? = nil
  ) {
    self.executionId = executionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.backend = backend
    self.status = status
    self.failureReason = failureReason
  }
}

public struct GraphQLCommunicationDTO: Codable, Equatable, Sendable {
  public var communicationId: String
  public var fromStepId: String?
  public var toStepId: String?
  public var lifecycleStatus: String
  public var deliveryKind: String
  public var createdOrder: Int

  public init(
    communicationId: String,
    fromStepId: String?,
    toStepId: String?,
    lifecycleStatus: String,
    deliveryKind: String,
    createdOrder: Int
  ) {
    self.communicationId = communicationId
    self.fromStepId = fromStepId
    self.toStepId = toStepId
    self.lifecycleStatus = lifecycleStatus
    self.deliveryKind = deliveryKind
    self.createdOrder = createdOrder
  }
}

public struct GraphQLHookEventDTO: Codable, Equatable, Sendable {
  public var vendor: String
  public var eventName: String
  public var agentSessionId: String
  public var payloadHash: String?

  public init(vendor: String, eventName: String, agentSessionId: String, payloadHash: String? = nil) {
    self.vendor = vendor
    self.eventName = eventName
    self.agentSessionId = agentSessionId
    self.payloadHash = payloadHash
  }
}

public struct GraphQLEventReceiptDTO: Codable, Equatable, Sendable {
  public var sourceId: String
  public var eventId: String
  public var status: String

  public init(sourceId: String, eventId: String, status: String) {
    self.sourceId = sourceId
    self.eventId = eventId
    self.status = status
  }
}

public struct GraphQLReplyDispatchDTO: Codable, Equatable, Sendable {
  public var sourceId: String
  public var provider: String
  public var payload: JSONObject

  public init(sourceId: String, provider: String, payload: JSONObject) {
    self.sourceId = sourceId
    self.provider = provider
    self.payload = payload
  }
}

public struct GraphQLLogEntryDTO: Codable, Equatable, Sendable {
  public var level: String
  public var message: String

  public init(level: String, message: String) {
    self.level = level
    self.message = message
  }
}

public struct GraphQLLLMSessionMessageDTO: Codable, Equatable, Sendable {
  public var role: String
  public var content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct GraphQLLoopEvidenceSummaryDTO: Codable, Equatable, Sendable {
  public var manifestId: String
  public var schemaVersion: Int
  public var workflowId: String
  public var sessionId: String
  public var gateCount: Int
  public var acceptedGateCount: Int
  public var rejectedGateCount: Int
  public var needsWorkGateCount: Int
  public var skippedGateCount: Int
  public var blockingFindingCount: Int
  public var stepCount: Int
  public var artifactCount: Int
  public var changedFileCount: Int
  public var commandCount: Int
  public var verificationCount: Int
  public var implementationPlanCount: Int
  public var residualRiskCount: Int
  public var redactionStatus: String
  public var updatedAt: String

  public init(summary: LoopEvidenceSummary) {
    self.manifestId = summary.manifestId
    self.schemaVersion = summary.schemaVersion
    self.workflowId = summary.workflowId
    self.sessionId = summary.sessionId
    self.gateCount = summary.gateCount
    self.acceptedGateCount = summary.acceptedGateCount
    self.rejectedGateCount = summary.rejectedGateCount
    self.needsWorkGateCount = summary.needsWorkGateCount
    self.skippedGateCount = summary.skippedGateCount
    self.blockingFindingCount = summary.blockingFindingCount
    self.stepCount = summary.stepCount
    self.artifactCount = summary.artifactCount
    self.changedFileCount = summary.changedFileCount
    self.commandCount = summary.commandCount
    self.verificationCount = summary.verificationCount
    self.implementationPlanCount = summary.implementationPlanCount
    self.residualRiskCount = summary.residualRiskCount
    self.redactionStatus = summary.redactionStatus
    self.updatedAt = GraphQLContractProjector.iso8601String(summary.updatedAt)
  }
}

public struct GraphQLLoopFindingSeverityCountsDTO: Codable, Equatable, Sendable {
  public var high: Int
  public var medium: Int
  public var low: Int
  public var informational: Int

  public init(counts: LoopFindingSeverityCounts) {
    self.high = counts.high
    self.medium = counts.medium
    self.low = counts.low
    self.informational = counts.informational
  }
}

public struct GraphQLLoopBlockingFindingDTO: Codable, Equatable, Sendable {
  public var id: String
  public var severity: String
  public var filePath: String?
  public var line: Int?
  public var message: String
  public var evidenceRefs: [String]

  public init(finding: LoopBlockingFinding) {
    self.id = finding.id
    self.severity = finding.severity
    self.filePath = finding.filePath
    self.line = finding.line
    self.message = finding.message
    self.evidenceRefs = finding.evidenceRefs
  }
}

public struct GraphQLLoopResidualRiskDTO: Codable, Equatable, Sendable {
  public var severity: String
  public var message: String
  public var evidenceRefs: [String]
  public var owner: String?
  public var accepted: Bool

  public init(risk: LoopResidualRisk) {
    self.severity = risk.severity
    self.message = risk.message
    self.evidenceRefs = risk.evidenceRefs
    self.owner = risk.owner
    self.accepted = risk.accepted
  }
}

public struct GraphQLLoopGateResultDTO: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var stepExecutionId: String
  public var decision: String
  public var severityCounts: GraphQLLoopFindingSeverityCountsDTO
  public var blockingFindings: [GraphQLLoopBlockingFindingDTO]
  public var evidenceRefs: [String]
  public var rerunPolicy: String?
  public var residualRisks: [GraphQLLoopResidualRiskDTO]
  public var acceptedAt: String?
  public var diagnostics: [String]

  public init(gate: LoopGateResult) {
    self.gateId = gate.gateId
    self.stepId = gate.stepId
    self.stepExecutionId = gate.stepExecutionId
    self.decision = gate.decision.rawValue
    self.severityCounts = GraphQLLoopFindingSeverityCountsDTO(counts: gate.severityCounts)
    self.blockingFindings = gate.blockingFindings.map(GraphQLLoopBlockingFindingDTO.init)
    self.evidenceRefs = gate.evidenceRefs
    self.rerunPolicy = gate.rerunPolicy
    self.residualRisks = gate.residualRisks.map(GraphQLLoopResidualRiskDTO.init)
    self.acceptedAt = gate.acceptedAt.map(GraphQLContractProjector.iso8601String)
    self.diagnostics = gate.diagnostics
  }
}

public struct GraphQLLoopRecoveryLineageDTO: Codable, Equatable, Sendable {
  public var entryMode: String
  public var sourceSessionId: String?
  public var sourceStepId: String?
  public var sourceStepExecutionId: String?
  public var parentSessionId: String?
  public var childSessionIds: [String]
  public var reason: String?
  public var inputReusePolicy: String
  public var preservedFailureEvidenceRefs: [String]

  public init(lineage: LoopRecoveryLineage) {
    self.entryMode = lineage.entryMode.rawValue
    self.sourceSessionId = lineage.sourceSessionId
    self.sourceStepId = lineage.sourceStepId
    self.sourceStepExecutionId = lineage.sourceStepExecutionId
    self.parentSessionId = lineage.parentSessionId
    self.childSessionIds = lineage.childSessionIds
    self.reason = lineage.reason
    self.inputReusePolicy = lineage.inputReusePolicy
    self.preservedFailureEvidenceRefs = lineage.preservedFailureEvidenceRefs
  }
}

public struct GraphQLWorkflowSessionDTO: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var workflowExecutionId: String
  public var status: String
  public var currentStepId: String?
  public var lastCompletedStepId: String?
  public var failureReason: String?
  public var failureKind: String?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var instanceBaseIdentity: String?
  public var instanceConfiguration: JSONObject?
  public var stepExecutions: [GraphQLStepExecutionDTO]
  public var communications: [GraphQLCommunicationDTO]
  public var hookEvents: [GraphQLHookEventDTO]
  public var eventReceipts: [GraphQLEventReceiptDTO]
  public var replyDispatches: [GraphQLReplyDispatchDTO]
  public var logs: [GraphQLLogEntryDTO]
  public var llmSessionMessages: [GraphQLLLMSessionMessageDTO]
  public var loopEvidence: GraphQLLoopEvidenceSummaryDTO?
  public var loopGates: [GraphQLLoopGateResultDTO]
  public var loopRecovery: GraphQLLoopRecoveryLineageDTO?

  public init(
    workflowId: String,
    sessionId: String,
    workflowExecutionId: String? = nil,
    status: String,
    currentStepId: String? = nil,
    lastCompletedStepId: String? = nil,
    failureReason: String? = nil,
    failureKind: String? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    instanceBaseIdentity: String? = nil,
    instanceConfiguration: JSONObject? = nil,
    stepExecutions: [GraphQLStepExecutionDTO] = [],
    communications: [GraphQLCommunicationDTO] = [],
    hookEvents: [GraphQLHookEventDTO] = [],
    eventReceipts: [GraphQLEventReceiptDTO] = [],
    replyDispatches: [GraphQLReplyDispatchDTO] = [],
    logs: [GraphQLLogEntryDTO] = [],
    llmSessionMessages: [GraphQLLLMSessionMessageDTO] = [],
    loopEvidence: GraphQLLoopEvidenceSummaryDTO? = nil,
    loopGates: [GraphQLLoopGateResultDTO] = [],
    loopRecovery: GraphQLLoopRecoveryLineageDTO? = nil
  ) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.workflowExecutionId = workflowExecutionId ?? sessionId
    self.status = status
    self.currentStepId = currentStepId
    self.lastCompletedStepId = lastCompletedStepId
    self.failureReason = failureReason
    self.failureKind = failureKind
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.instanceBaseIdentity = instanceBaseIdentity
    self.instanceConfiguration = instanceConfiguration
    self.stepExecutions = stepExecutions
    self.communications = communications
    self.hookEvents = hookEvents
    self.eventReceipts = eventReceipts
    self.replyDispatches = replyDispatches
    self.logs = logs
    self.llmSessionMessages = llmSessionMessages
    self.loopEvidence = loopEvidence
    self.loopGates = loopGates
    self.loopRecovery = loopRecovery
  }
}

public struct GraphQLWorkflowSessionSummaryDTO: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var status: String
  public var failureKind: String?
  public var currentStepId: String?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var executionCount: Int
  public var updatedAt: Date
  public var sessionStore: String?

  public init(
    sessionId: String,
    workflowName: String,
    status: String,
    failureKind: String? = nil,
    currentStepId: String? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    executionCount: Int,
    updatedAt: Date,
    sessionStore: String? = nil
  ) {
    self.sessionId = sessionId
    self.workflowName = workflowName
    self.status = status
    self.failureKind = failureKind
    self.currentStepId = currentStepId
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.executionCount = executionCount
    self.updatedAt = updatedAt
    self.sessionStore = sessionStore
  }
}

public struct GraphQLInspectSessionRequest: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String

  public var workflowExecutionId: String {
    get { sessionId }
    set { sessionId = newValue }
  }

  public init(workflowId: String, sessionId: String) {
    self.workflowId = workflowId
    self.sessionId = sessionId
  }
}

public struct GraphQLWorkflowSessionsRequest: Codable, Equatable, Sendable {
  public var workflowName: String?
  public var status: String?
  public var limit: Int?

  public init(workflowName: String? = nil, status: String? = nil, limit: Int? = nil) {
    self.workflowName = workflowName
    self.status = status
    self.limit = limit
  }
}

public typealias GraphQLLoopEvidenceRequest = GraphQLInspectSessionRequest

public enum GraphQLLoopEvidenceQueryStatus: String, Codable, Equatable, Sendable {
  case found
  case notFound = "not-found"
  case noEvidence = "no-loop-evidence"
  case workflowMismatch = "workflow-mismatch"
  case invalidRequest = "invalid-request"
  case error
}

public struct GraphQLContinueSessionRequest: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var input: JSONObject

  public var workflowExecutionId: String {
    get { sessionId }
    set { sessionId = newValue }
  }

  public init(workflowId: String, sessionId: String, input: JSONObject = [:]) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.input = input
  }
}

public struct GraphQLManagerSessionLookupRequest: Codable, Equatable, Sendable {
  public var managerSessionId: String?

  public init(managerSessionId: String? = nil) {
    self.managerSessionId = managerSessionId
  }
}

public struct GraphQLSendManagerMessageRequest: Codable, Equatable, Sendable {
  public var workflowId: String
  public var workflowExecutionId: String
  public var message: String?
  public var actions: JSONValue?
  public var attachments: JSONValue?
  public var idempotencyKey: String?
  public var managerSessionId: String?
  public var managerNodeExecId: String?

  public init(
    workflowId: String,
    workflowExecutionId: String,
    message: String? = nil,
    actions: JSONValue? = nil,
    attachments: JSONValue? = nil,
    idempotencyKey: String? = nil,
    managerSessionId: String? = nil,
    managerNodeExecId: String? = nil
  ) {
    self.workflowId = workflowId
    self.workflowExecutionId = workflowExecutionId
    self.message = message
    self.actions = actions
    self.attachments = attachments
    self.idempotencyKey = idempotencyKey
    self.managerSessionId = managerSessionId
    self.managerNodeExecId = managerNodeExecId
  }
}

public struct GraphQLReplayCommunicationRequest: Codable, Equatable, Sendable {
  public var workflowId: String
  public var workflowExecutionId: String
  public var communicationId: String
  public var reason: String?
  public var idempotencyKey: String?
  public var managerSessionId: String?

  public init(
    workflowId: String,
    workflowExecutionId: String,
    communicationId: String,
    reason: String? = nil,
    idempotencyKey: String? = nil,
    managerSessionId: String? = nil
  ) {
    self.workflowId = workflowId
    self.workflowExecutionId = workflowExecutionId
    self.communicationId = communicationId
    self.reason = reason
    self.idempotencyKey = idempotencyKey
    self.managerSessionId = managerSessionId
  }
}

public typealias GraphQLRetryCommunicationDeliveryRequest = GraphQLReplayCommunicationRequest

public struct GraphQLManagerIntentSummaryDTO: Codable, Equatable, Sendable {
  public var kind: String
  public var targetId: String?
  public var reason: String?

  public init(kind: String, targetId: String? = nil, reason: String? = nil) {
    self.kind = kind
    self.targetId = targetId
    self.reason = reason
  }
}

public struct GraphQLManagerSessionViewDTO: Codable, Equatable, Sendable {
  public var session: JSONValue
  public var messages: JSONValue

  public init(session: JSONValue, messages: JSONValue) {
    self.session = session
    self.messages = messages
  }
}

public struct GraphQLSendManagerMessagePayload: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var managerMessageId: String
  public var parsedIntent: [GraphQLManagerIntentSummaryDTO]
  public var createdCommunicationIds: [String]
  public var queuedNodeIds: [String]
  public var rejectionReason: String?
  public var workflowId: String
  public var workflowExecutionId: String
  public var managerSessionId: String

  public init(
    accepted: Bool,
    managerMessageId: String,
    parsedIntent: [GraphQLManagerIntentSummaryDTO],
    createdCommunicationIds: [String],
    queuedNodeIds: [String],
    rejectionReason: String? = nil,
    workflowId: String,
    workflowExecutionId: String,
    managerSessionId: String
  ) {
    self.accepted = accepted
    self.managerMessageId = managerMessageId
    self.parsedIntent = parsedIntent
    self.createdCommunicationIds = createdCommunicationIds
    self.queuedNodeIds = queuedNodeIds
    self.rejectionReason = rejectionReason
    self.workflowId = workflowId
    self.workflowExecutionId = workflowExecutionId
    self.managerSessionId = managerSessionId
  }
}

public struct GraphQLReplayCommunicationPayload: Codable, Equatable, Sendable {
  public var sourceCommunicationId: String
  public var workflowExecutionId: String
  public var replayedCommunicationId: String
  public var status: String

  public init(
    sourceCommunicationId: String,
    workflowExecutionId: String,
    replayedCommunicationId: String,
    status: String
  ) {
    self.sourceCommunicationId = sourceCommunicationId
    self.workflowExecutionId = workflowExecutionId
    self.replayedCommunicationId = replayedCommunicationId
    self.status = status
  }
}

public struct GraphQLRetryCommunicationDeliveryPayload: Codable, Equatable, Sendable {
  public var communicationId: String
  public var activeDeliveryAttemptId: String
  public var status: String

  public init(communicationId: String, activeDeliveryAttemptId: String, status: String) {
    self.communicationId = communicationId
    self.activeDeliveryAttemptId = activeDeliveryAttemptId
    self.status = status
  }
}

public struct GraphQLControlPlaneResult: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var status: String
  public var diagnostics: [String]

  public init(accepted: Bool, status: String, diagnostics: [String] = []) {
    self.accepted = accepted
    self.status = status
    self.diagnostics = diagnostics
  }
}

public struct GraphQLInspectSessionResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var session: GraphQLWorkflowSessionDTO?

  public init(result: GraphQLControlPlaneResult, session: GraphQLWorkflowSessionDTO? = nil) {
    self.result = result
    self.session = session
  }
}

public struct GraphQLLoopEvidenceResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var evidence: GraphQLLoopEvidenceSummaryDTO?
  public var gates: [GraphQLLoopGateResultDTO]
  public var recovery: GraphQLLoopRecoveryLineageDTO?

  public init(
    result: GraphQLControlPlaneResult,
    evidence: GraphQLLoopEvidenceSummaryDTO? = nil,
    gates: [GraphQLLoopGateResultDTO] = [],
    recovery: GraphQLLoopRecoveryLineageDTO? = nil
  ) {
    self.result = result
    self.evidence = evidence
    self.gates = gates
    self.recovery = recovery
  }
}

public struct GraphQLWorkflowSessionsResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var sessions: [GraphQLWorkflowSessionSummaryDTO]

  public init(
    result: GraphQLControlPlaneResult,
    sessions: [GraphQLWorkflowSessionSummaryDTO] = []
  ) {
    self.result = result
    self.sessions = sessions
  }
}

public struct GraphQLWorkflowInstanceDTO: Codable, Equatable, Sendable {
  public var identity: String
  public var workflowId: String
  public var sourceIdentity: String?
  public var displayName: String?
  public var configuration: JSONObject

  public init(instance: WorkflowInstanceDefinition) {
    self.identity = instance.identity
    self.workflowId = instance.workflowId
    self.sourceIdentity = instance.sourceIdentity
    self.displayName = instance.displayName
    self.configuration = EffectiveWorkflowInstance(
      identity: instance.identity,
      kind: .named,
      configuration: instance.configuration
    ).configurationJSONObject
  }
}

public struct GraphQLWorkflowInstanceInput: Codable, Equatable, Sendable {
  public var identity: String
  public var workflowId: String
  public var sourceIdentity: String?
  public var displayName: String?
  public var configuration: WorkflowInstanceConfiguration

  public init(
    identity: String,
    workflowId: String,
    sourceIdentity: String? = nil,
    displayName: String? = nil,
    configuration: WorkflowInstanceConfiguration = WorkflowInstanceConfiguration()
  ) {
    self.identity = identity
    self.workflowId = workflowId
    self.sourceIdentity = sourceIdentity
    self.displayName = displayName
    self.configuration = configuration
  }

  public var definition: WorkflowInstanceDefinition {
    WorkflowInstanceDefinition(
      identity: identity,
      workflowId: workflowId,
      sourceIdentity: sourceIdentity,
      displayName: displayName,
      configuration: configuration
    )
  }
}

public struct GraphQLWorkflowInstanceQueryResult<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: Value?

  public init(result: GraphQLControlPlaneResult, value: Value? = nil) {
    self.result = result
    self.value = value
  }
}

public struct GraphQLWorkflowInstanceMutationResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var instance: GraphQLWorkflowInstanceDTO?

  public init(result: GraphQLControlPlaneResult, instance: GraphQLWorkflowInstanceDTO? = nil) {
    self.result = result
    self.instance = instance
  }
}

public protocol GraphQLControlPlaneServicing: Sendable {
  func inspectSession(_ request: GraphQLInspectSessionRequest) async -> GraphQLInspectSessionResult
  func workflowSessions(_ request: GraphQLWorkflowSessionsRequest) async -> GraphQLWorkflowSessionsResult
  func loopEvidence(_ request: GraphQLLoopEvidenceRequest) async -> GraphQLLoopEvidenceResult
  func continueSession(_ request: GraphQLContinueSessionRequest) async -> GraphQLControlPlaneResult
  func managerSession(_ request: GraphQLManagerSessionLookupRequest) async -> GraphQLManagerSessionViewDTO?
  func sendManagerMessage(_ request: GraphQLSendManagerMessageRequest) async -> GraphQLSendManagerMessagePayload
  func replayCommunication(_ request: GraphQLReplayCommunicationRequest) async -> GraphQLReplayCommunicationPayload
  func retryCommunicationDelivery(_ request: GraphQLRetryCommunicationDeliveryRequest) async -> GraphQLRetryCommunicationDeliveryPayload
}

public extension GraphQLControlPlaneServicing {
  func workflowSessions(_ request: GraphQLWorkflowSessionsRequest) async -> GraphQLWorkflowSessionsResult {
    GraphQLWorkflowSessionsResult(
      result: GraphQLControlPlaneResult(
        accepted: false,
        status: GraphQLLoopEvidenceQueryStatus.error.rawValue,
        diagnostics: ["workflow session discovery is not available from this service"]
      )
    )
  }

  func loopEvidence(_ request: GraphQLLoopEvidenceRequest) async -> GraphQLLoopEvidenceResult {
    let inspected = await inspectSession(request)
    guard inspected.result.accepted, let session = inspected.session else {
      return GraphQLLoopEvidenceResult(result: inspected.result)
    }
    guard let evidence = session.loopEvidence else {
      return GraphQLLoopEvidenceResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.noEvidence.rawValue,
          diagnostics: ["loop evidence not found for session \(request.sessionId)"]
        )
      )
    }
    return GraphQLLoopEvidenceResult(
      result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
      evidence: evidence,
      gates: session.loopGates,
      recovery: session.loopRecovery
    )
  }
}

public enum GraphQLContractProjector {
  public static let schemaContract = """
  scalar JSON
  scalar JSONObject
  \(graphQLNoteSchemaContract)
  type ControlPlaneResult { accepted: Boolean!, status: String!, diagnostics: [String!]! }
  type ManagerIntentSummary { kind: String!, targetId: String, reason: String }
  type ManagerSessionView { session: JSON!, messages: JSON! }
  type SendManagerMessagePayload {
    accepted: Boolean!
    managerMessageId: String!
    parsedIntent: [ManagerIntentSummary!]!
    createdCommunicationIds: [String!]!
    queuedNodeIds: [String!]!
    rejectionReason: String
    workflowId: String!
    workflowExecutionId: String!
    managerSessionId: String!
  }
  type ReplayCommunicationPayload { sourceCommunicationId: String!, workflowExecutionId: String!, replayedCommunicationId: String!, status: String! }
  type RetryCommunicationDeliveryPayload { communicationId: String!, activeDeliveryAttemptId: String!, status: String! }
  type LoopEvidenceSummary {
    manifestId: String!
    schemaVersion: Int!
    workflowId: String!
    sessionId: String!
    gateCount: Int!
    acceptedGateCount: Int!
    rejectedGateCount: Int!
    needsWorkGateCount: Int!
    skippedGateCount: Int!
    blockingFindingCount: Int!
    stepCount: Int!
    artifactCount: Int!
    changedFileCount: Int!
    commandCount: Int!
    verificationCount: Int!
    implementationPlanCount: Int!
    residualRiskCount: Int!
    redactionStatus: String!
    updatedAt: String!
  }
  type LoopFindingSeverityCounts { high: Int!, medium: Int!, low: Int!, informational: Int! }
  type LoopBlockingFinding {
    id: String!
    severity: String!
    filePath: String
    line: Int
    message: String!
    evidenceRefs: [String!]!
  }
  type LoopResidualRisk {
    severity: String!
    message: String!
    evidenceRefs: [String!]!
    owner: String
    accepted: Boolean!
  }
  type LoopGateResult {
    gateId: String!
    stepId: String!
    stepExecutionId: String!
    decision: String!
    severityCounts: LoopFindingSeverityCounts!
    blockingFindings: [LoopBlockingFinding!]!
    evidenceRefs: [String!]!
    rerunPolicy: String
    residualRisks: [LoopResidualRisk!]!
    acceptedAt: String
    diagnostics: [String!]!
  }
  type LoopRecoveryLineage {
    entryMode: String!
    sourceSessionId: String
    sourceStepId: String
    sourceStepExecutionId: String
    parentSessionId: String
    childSessionIds: [String!]!
    reason: String
    inputReusePolicy: String!
    preservedFailureEvidenceRefs: [String!]!
  }
  type WorkflowSession {
    workflowId: String!
    sessionId: String!
    workflowExecutionId: String!
    status: String!
    currentStepId: String
    lastCompletedStepId: String
    failureReason: String
    failureKind: String
    stepBudgetDiagnostic: StepBudgetDiagnostic
    instanceIdentity: String
    instanceKind: String
    instanceBaseIdentity: String
    instanceConfiguration: JSONObject
    stepExecutions: [StepExecution!]!
    communications: [Communication!]!
    hookEvents: [HookEvent!]!
    eventReceipts: [EventReceipt!]!
    replyDispatches: [ReplyDispatch!]!
    logs: [LogEntry!]!
    llmSessionMessages: [LLMSessionMessage!]!
    loopEvidence: LoopEvidenceSummary
    loopGates: [LoopGateResult!]!
    loopRecovery: LoopRecoveryLineage
  }
  type StepBudgetDiagnostic {
    stepBudget: Int!
    executionCount: Int!
    maxLoopIterations: Int!
    budgetSource: String!
    perStepExecutionCounts: JSON!
    dominantCycleStepIds: [String!]
    dominantCycleRepeatCount: Int
    perStepRevisitCap: Int
    projectedCapExceededStepIds: [String!]
    openReviewFindingCount: Int!
    unscheduledStepId: String
    suggestedMaxSteps: Int
    suggestedRemediation: String
  }
  type WorkflowSessionSummary {
    sessionId: String!
    workflowName: String!
    status: String!
    failureKind: String
    currentStepId: String
    instanceIdentity: String
    instanceKind: String
    executionCount: Int!
    updatedAt: String!
    sessionStore: String
  }
  type WorkflowInstance {
    identity: String!
    workflowId: String!
    sourceIdentity: String
    displayName: String
    configuration: JSONObject!
  }
  type WorkflowInstanceQueryPayload {
    result: ControlPlaneResult!
    value: WorkflowInstance
  }
  type WorkflowInstancesQueryPayload {
    result: ControlPlaneResult!
    value: [WorkflowInstance!]
  }
  type WorkflowInstanceMutationPayload {
    result: ControlPlaneResult!
    instance: WorkflowInstance
  }
  type StepExecution { executionId: String!, stepId: String!, nodeId: String!, attempt: Int!, backend: String, status: String!, failureReason: String }
  type Communication { communicationId: String!, fromStepId: String, toStepId: String, lifecycleStatus: String!, deliveryKind: String!, createdOrder: Int! }
  type HookEvent { vendor: String!, eventName: String!, agentSessionId: String!, payloadHash: String }
  type EventReceipt { sourceId: String!, eventId: String!, status: String! }
  type ReplyDispatch { sourceId: String!, provider: String!, payload: JSONObject! }
  type LogEntry { level: String!, message: String! }
  type LLMSessionMessage { role: String!, content: String! }
  input ContinueSessionInput { workflowId: String!, sessionId: String!, input: JSONObject! }
  input SendManagerMessageInput { workflowId: String!, workflowExecutionId: String!, message: String, actions: JSON, attachments: JSON, idempotencyKey: String, managerSessionId: String, managerNodeExecId: String }
  input ReplayCommunicationInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }
  input RetryCommunicationDeliveryInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }
  input WorkflowInstanceInput { identity: String!, workflowId: String!, sourceIdentity: String, displayName: String, configuration: JSONObject }
  type Query {
    note(noteId: String!): NoteQueryPayload!
    notebook(notebookId: String!): NotebookQueryPayload!
    notebooks(limit: Int, offset: Int, tagFilter: [String!], sort: NoteListSort, createdAfter: String, createdBefore: String): NotebooksQueryPayload!
    notes(limit: Int, offset: Int, notebookId: String, tagFilter: [String!]): NotesQueryPayload!
    # Direct full-text hits are ranked first; sort orders filter-only and linked-neighbor groups.
    searchNotes(query: String!, tagFilter: [String!], classFilter: [String!], sort: NoteListSort, createdAfter: String, createdBefore: String, includeLinked: Boolean, limit: Int, offset: Int): NoteSearchQueryPayload!
    proposeNoteLinks(noteId: String!, limit: Int): NoteLinkProposalQueryPayload!
    tags: NoteTagsQueryPayload!
    tagClasses: NoteTagClassesQueryPayload!
    noteFile(fileId: String!): NoteFileQueryPayload!
    autoActions: NoteAutoActionsQueryPayload!
    workflowInstances(workflowId: String): WorkflowInstancesQueryPayload!
    workflowInstance(identity: String!, workflowId: String): WorkflowInstanceQueryPayload!
    workflowSession(workflowId: String!, sessionId: String!): WorkflowSession
    workflowSessions(workflowName: String, status: String, limit: Int): [WorkflowSessionSummary!]!
    loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceSummary
    managerSession(managerSessionId: String): ManagerSessionView
  }
  type Mutation {
    createNote(input: CreateNoteInput!): NoteMutationPayload!
    createNotebook(input: CreateNotebookInput!): NoteMutationPayload!
    defineNoteTagClass(input: DefineNoteTagClassInput!): NoteMutationPayload!
    defineNoteTag(input: DefineNoteTagInput!): NoteMutationPayload!
    scaffoldNoteIngestionWorkflow(input: ScaffoldNoteIngestionWorkflowInput!): NoteMutationPayload!
    updateNote(input: UpdateNoteInput!): NoteMutationPayload!
    deleteNote(noteId: String!): ControlPlaneResult!
    deleteNotebook(notebookId: String!): ControlPlaneResult!
    applyNotebookTags(input: ApplyNotebookTagsInput!): NoteMutationPayload!
    removeNotebookTag(notebookId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    setNoteReadOnly(noteId: String!, readOnly: Boolean!): NoteMutationPayload!
    applyNoteTags(input: ApplyNoteTagsInput!): NoteMutationPayload!
    removeNoteTag(noteId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    addNoteComment(input: AddNoteCommentInput!): NoteMutationPayload!
    linkNotes(input: LinkNotesInput!): NoteMutationPayload!
    attachNoteFile(input: AttachNoteFileInput!): NoteMutationPayload!
    configureNoteAutoAction(input: ConfigureNoteAutoActionInput!): NoteMutationPayload!
    deleteNoteAutoAction(actionId: String!): ControlPlaneResult!
    saveNoteConversation(input: SaveNoteConversationInput!): NoteMutationPayload!
    migrateNoteFileStorage(input: MigrateNoteFileStorageInput!): NoteFileMigrationPayload!
    migrateAllNoteFiles(input: MigrateAllNoteFilesInput!): NoteFileMigrationPayload!
    createWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    updateWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    deleteWorkflowInstance(identity: String!, workflowId: String): WorkflowInstanceMutationPayload!
    continueSession(input: ContinueSessionInput!): ControlPlaneResult!
    sendManagerMessage(input: SendManagerMessageInput!): SendManagerMessagePayload!
    replayCommunication(input: ReplayCommunicationInput!): ReplayCommunicationPayload!
    retryCommunicationDelivery(input: RetryCommunicationDeliveryInput!): RetryCommunicationDeliveryPayload!
  }
  """

  public static func project(
    session: WorkflowSession,
    communications: [WorkflowMessageRecord] = [],
    hookEvents: [GraphQLHookEventDTO] = [],
    eventReceipts: [GraphQLEventReceiptDTO] = [],
    replyDispatches: [GraphQLReplyDispatchDTO] = [],
    logs: [GraphQLLogEntryDTO] = [],
    llmSessionMessages: [GraphQLLLMSessionMessageDTO] = [],
    loopEvidence: LoopEvidenceManifest? = nil
  ) -> GraphQLWorkflowSessionDTO {
    .init(
      workflowId: session.workflowId,
      sessionId: session.sessionId,
      workflowExecutionId: session.workflowExecutionId,
      status: session.status.rawValue,
      currentStepId: session.currentStepId,
      lastCompletedStepId: session.executions.last { $0.status == .completed || $0.status == .skipped }?.stepId,
      failureReason: session.failureReason,
      failureKind: session.failureKind?.rawValue,
      stepBudgetDiagnostic: session.stepBudgetDiagnostic,
      instanceIdentity: session.instanceIdentity,
      instanceKind: session.instanceKind,
      instanceBaseIdentity: session.instanceBaseIdentity,
      instanceConfiguration: session.instanceConfiguration,
      stepExecutions: session.executions.map {
        .init(
          executionId: $0.executionId,
          stepId: $0.stepId,
          nodeId: $0.nodeId,
          attempt: $0.attempt,
          backend: $0.backend?.rawValue,
          status: $0.status.rawValue,
          failureReason: $0.failureReason
        )
      },
      communications: communications.map {
        .init(
          communicationId: $0.communicationId,
          fromStepId: $0.fromStepId,
          toStepId: $0.toStepId,
          lifecycleStatus: $0.lifecycleStatus.rawValue,
          deliveryKind: $0.deliveryKind.rawValue,
          createdOrder: $0.createdOrder
        )
      },
      hookEvents: hookEvents,
      eventReceipts: eventReceipts,
      replyDispatches: replyDispatches,
      logs: logs,
      llmSessionMessages: llmSessionMessages,
      loopEvidence: loopEvidence.map { GraphQLLoopEvidenceSummaryDTO(summary: LoopEvidenceSummary(manifest: $0)) },
      loopGates: loopEvidence?.gates.map(GraphQLLoopGateResultDTO.init) ?? [],
      loopRecovery: loopEvidence?.recovery.map(GraphQLLoopRecoveryLineageDTO.init)
    )
  }

  public static func project(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    hookEvents: [GraphQLHookEventDTO] = [],
    eventReceipts: [GraphQLEventReceiptDTO] = [],
    replyDispatches: [GraphQLReplyDispatchDTO] = [],
    logs: [GraphQLLogEntryDTO] = [],
    llmSessionMessages: [GraphQLLLMSessionMessageDTO] = []
  ) -> GraphQLWorkflowSessionDTO {
    project(
      session: snapshot.session,
      communications: snapshot.workflowMessages,
      hookEvents: hookEvents,
      eventReceipts: eventReceipts,
      replyDispatches: replyDispatches,
      logs: logs,
      llmSessionMessages: llmSessionMessages,
      loopEvidence: snapshot.loopEvidence
    )
  }

  public static func projectSessionSummary(
    session: WorkflowSession,
    workflowName: String,
    sessionStore: String? = nil
  ) -> GraphQLWorkflowSessionSummaryDTO {
    GraphQLWorkflowSessionSummaryDTO(
      sessionId: session.sessionId,
      workflowName: workflowName,
      status: session.status.rawValue,
      failureKind: session.failureKind?.rawValue,
      currentStepId: session.currentStepId,
      instanceIdentity: session.instanceIdentity,
      instanceKind: session.instanceKind,
      executionCount: session.executions.count,
      updatedAt: session.updatedAt,
      sessionStore: sessionStore
    )
  }

  public static func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
