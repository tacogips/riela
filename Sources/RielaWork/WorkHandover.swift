import Foundation
import RielaCore

public struct HandoverID: WorkIdentifier {
  public static let prefix = "handover"
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}
public enum HandoverReason: Codable, Equatable, Sendable {
  case userInputRequired(HandoverQuestion)
  case userPresenceRequired(PresenceRequirement)
  case ownerLost(OwnerLossEvidence)
  case inactivity(stepId: String, idleMs: Int)
  case operatorMove(reason: String)
  private enum CodingKeys: String, CodingKey { case kind, question, presence, evidence, stepId, idleMs, reason }
  private enum Kind: String, Codable { case userInputRequired, userPresenceRequired, ownerLost, inactivity, operatorMove }
  public var kindName: String {
    switch self {
    case .userInputRequired: Kind.userInputRequired.rawValue
    case .userPresenceRequired: Kind.userPresenceRequired.rawValue
    case .ownerLost: Kind.ownerLost.rawValue
    case .inactivity: Kind.inactivity.rawValue
    case .operatorMove: Kind.operatorMove.rawValue
    }
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .userInputRequired: self = .userInputRequired(try c.decode(HandoverQuestion.self, forKey: .question))
    case .userPresenceRequired: self = .userPresenceRequired(try c.decode(PresenceRequirement.self, forKey: .presence))
    case .ownerLost: self = .ownerLost(try c.decode(OwnerLossEvidence.self, forKey: .evidence))
    case .inactivity: self = .inactivity(stepId: try c.decode(String.self, forKey: .stepId), idleMs: try c.decode(Int.self, forKey: .idleMs))
    case .operatorMove: self = .operatorMove(reason: try c.decode(String.self, forKey: .reason))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .userInputRequired(value): try c.encode(Kind.userInputRequired, forKey: .kind); try c.encode(value, forKey: .question)
    case let .userPresenceRequired(value): try c.encode(Kind.userPresenceRequired, forKey: .kind); try c.encode(value, forKey: .presence)
    case let .ownerLost(value): try c.encode(Kind.ownerLost, forKey: .kind); try c.encode(value, forKey: .evidence)
    case let .inactivity(stepId, idleMs): try c.encode(Kind.inactivity, forKey: .kind); try c.encode(stepId, forKey: .stepId); try c.encode(idleMs, forKey: .idleMs)
    case let .operatorMove(reason): try c.encode(Kind.operatorMove, forKey: .kind); try c.encode(reason, forKey: .reason)
    }
  }
}
public struct OwnerLossEvidence: Codable, Equatable, Sendable {
  public var attemptId: AttemptID; public var lastHeartbeatAt: Date?; public var expiredAt: Date; public var fence: Int; public var forcedBy: DecisionProducer
  public init(attemptId: AttemptID, lastHeartbeatAt: Date? = nil, expiredAt: Date, fence: Int, forcedBy: DecisionProducer) {
    self.attemptId = attemptId; self.lastHeartbeatAt = lastHeartbeatAt; self.expiredAt = expiredAt; self.fence = fence; self.forcedBy = forcedBy
  }
}
public struct HandoverWorkflowRef: Codable, Equatable, Sendable {
  public var workflowId: String; public var scope: String?; public var workflowDefinitionDir: String?; public var entryStepId: String; public var resumeStepId: String
  public init(workflowId: String, scope: String? = nil, workflowDefinitionDir: String? = nil, entryStepId: String, resumeStepId: String) {
    self.workflowId = workflowId; self.scope = scope; self.workflowDefinitionDir = workflowDefinitionDir; self.entryStepId = entryStepId; self.resumeStepId = resumeStepId
  }
}
public struct BudgetSnapshot: Codable, Equatable, Sendable {
  public var attemptsUsed: Int; public var maxAttempts: Int?; public var tokensUsed: Int; public var maxTotalTokens: Int?
  public var wallClockMsUsed: Int; public var maxWallClockMs: Int?
  public init(attemptsUsed: Int, maxAttempts: Int? = nil, tokensUsed: Int, maxTotalTokens: Int? = nil, wallClockMsUsed: Int, maxWallClockMs: Int? = nil) {
    self.attemptsUsed = attemptsUsed; self.maxAttempts = maxAttempts; self.tokensUsed = tokensUsed; self.maxTotalTokens = maxTotalTokens
    self.wallClockMsUsed = wallClockMsUsed; self.maxWallClockMs = maxWallClockMs
  }
}
public struct HandoverStepSummary: Codable, Equatable, Sendable {
  public var stepId: String; public var stepExecutionId: String; public var status: WorkflowStepExecutionStatus
  public var acceptedOutput: JSONObject?; public var responseExcerpt: String?; public var backend: String?
  public init(stepId: String, stepExecutionId: String, status: WorkflowStepExecutionStatus, acceptedOutput: JSONObject? = nil, responseExcerpt: String? = nil, backend: String? = nil) {
    self.stepId = stepId; self.stepExecutionId = stepExecutionId; self.status = status; self.acceptedOutput = acceptedOutput; self.responseExcerpt = responseExcerpt; self.backend = backend
  }
}
public struct HandoverProgress: Codable, Equatable, Sendable {
  public var acceptedSteps: [HandoverStepSummary]; public var remainingSteps: [String]; public var latestGateResults: [LoopGateResult]
  public var openFindings: [Finding]; public var evidenceSummary: [String: Int]; public var remainingBudget: BudgetSnapshot
  public init(acceptedSteps: [HandoverStepSummary], remainingSteps: [String], latestGateResults: [LoopGateResult], openFindings: [Finding], evidenceSummary: [String: Int], remainingBudget: BudgetSnapshot) {
    self.acceptedSteps = acceptedSteps; self.remainingSteps = remainingSteps; self.latestGateResults = latestGateResults
    self.openFindings = openFindings; self.evidenceSummary = evidenceSummary; self.remainingBudget = remainingBudget
  }
}
public enum PublicationState: Codable, Equatable, Sendable {
  case published
  case checkpointFailed(reason: String)
  case unpublished(lastKnown: String?)
  private enum CodingKeys: String, CodingKey { case kind, reason, lastKnown }
  private enum Kind: String, Codable { case published, checkpointFailed, unpublished }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .published: self = .published
    case .checkpointFailed: self = .checkpointFailed(reason: try c.decode(String.self, forKey: .reason))
    case .unpublished: self = .unpublished(lastKnown: try c.decodeIfPresent(String.self, forKey: .lastKnown))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .published: try c.encode(Kind.published, forKey: .kind)
    case let .checkpointFailed(reason): try c.encode(Kind.checkpointFailed, forKey: .kind); try c.encode(reason, forKey: .reason)
    case let .unpublished(lastKnown): try c.encode(Kind.unpublished, forKey: .kind); try c.encodeIfPresent(lastKnown, forKey: .lastKnown)
    }
  }
}
public struct RepositoryDeliverable: Codable, Equatable, Sendable {
  public var root: String; public var remote: String; public var branch: String; public var baseRevision: String; public var headCommit: String?
  public var state: PublicationState; public var dirtyPaths: [String]
  public init(root: String, remote: String, branch: String, baseRevision: String, headCommit: String? = nil, state: PublicationState, dirtyPaths: [String] = []) {
    self.root = root; self.remote = remote; self.branch = branch; self.baseRevision = baseRevision; self.headCommit = headCommit; self.state = state; self.dirtyPaths = dirtyPaths
  }
}
public struct DocumentDeliverable: Codable, Equatable, Sendable {
  public var store: String; public var instance: String?; public var ids: [String]; public var producedByStepIds: [String]
  public init(store: String, instance: String? = nil, ids: [String], producedByStepIds: [String]) {
    self.store = store; self.instance = instance; self.ids = ids; self.producedByStepIds = producedByStepIds
  }
}
public struct ArtifactFileRef: Codable, Equatable, Sendable { public var path: String; public var sha256: String; public var bytes: Int
  public init(path: String, sha256: String, bytes: Int) { self.path = path; self.sha256 = sha256; self.bytes = bytes }
}
public struct ArtifactBundleRef: Codable, Equatable, Sendable { public var files: [ArtifactFileRef]; public var location: HandoverSinkRef
  public init(files: [ArtifactFileRef], location: HandoverSinkRef) { self.files = files; self.location = location }
}
public struct LocalOnlyDeliverable: Codable, Equatable, Sendable { public var kind: String; public var path: String; public var bytes: Int?
  public init(kind: String, path: String, bytes: Int? = nil) { self.kind = kind; self.path = path; self.bytes = bytes }
}
public enum DeliverableRef: Codable, Equatable, Sendable {
  case repository(RepositoryDeliverable), document(DocumentDeliverable), artifactBundle(ArtifactBundleRef), localOnly(LocalOnlyDeliverable)
  private enum CodingKeys: String, CodingKey { case kind, repository, document, artifactBundle, localOnly }
  private enum Kind: String, Codable { case repository, document, artifactBundle, localOnly }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .repository: self = .repository(try c.decode(RepositoryDeliverable.self, forKey: .repository))
    case .document: self = .document(try c.decode(DocumentDeliverable.self, forKey: .document))
    case .artifactBundle: self = .artifactBundle(try c.decode(ArtifactBundleRef.self, forKey: .artifactBundle))
    case .localOnly: self = .localOnly(try c.decode(LocalOnlyDeliverable.self, forKey: .localOnly))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .repository(v): try c.encode(Kind.repository, forKey: .kind); try c.encode(v, forKey: .repository)
    case let .document(v): try c.encode(Kind.document, forKey: .kind); try c.encode(v, forKey: .document)
    case let .artifactBundle(v): try c.encode(Kind.artifactBundle, forKey: .kind); try c.encode(v, forKey: .artifactBundle)
    case let .localOnly(v): try c.encode(Kind.localOnly, forKey: .kind); try c.encode(v, forKey: .localOnly)
    }
  }
}
public struct HandoverContinuationContract: Codable, Equatable, Sendable {
  public var resumeStepId: String; public var completion: CompletionContract; public var verification: [VerificationRequirement]; public var guardPolicy: GuardPolicy
  public init(resumeStepId: String, completion: CompletionContract, verification: [VerificationRequirement], guardPolicy: GuardPolicy) {
    self.resumeStepId = resumeStepId; self.completion = completion; self.verification = verification; self.guardPolicy = guardPolicy
  }
}
public struct HandoverAnswer: Codable, Equatable, Sendable {
  public var questionId: String; public var payload: JSONObject; public var answeredBy: DecisionProducer; public var answeredAt: Date
  public init(questionId: String, payload: JSONObject, answeredBy: DecisionProducer, answeredAt: Date) {
    self.questionId = questionId; self.payload = payload; self.answeredBy = answeredBy; self.answeredAt = answeredAt
  }
}
public struct HandoverPacket: Codable, Equatable, Sendable {
  public var id: HandoverID; public var version: Int; public var taskId: TaskID; public var intentId: IntentID
  public var fromAttemptId: AttemptID; public var fromSessionId: String; public var generation: Int; public var reason: HandoverReason
  public var workflow: HandoverWorkflowRef; public var progress: HandoverProgress; public var history: HandoverHistoryBundle
  public var variables: JSONObject; public var deliverables: [DeliverableRef]; public var contract: HandoverContinuationContract
  public var brief: String; public var sinks: [HandoverSinkRef]; public var producedBy: EvidenceProducer; public var producedOn: String
  public var createdAt: Date; public var digest: String
  public init(id: HandoverID, version: Int = 1, taskId: TaskID, intentId: IntentID, fromAttemptId: AttemptID, fromSessionId: String,
              generation: Int, reason: HandoverReason, workflow: HandoverWorkflowRef, progress: HandoverProgress,
              history: HandoverHistoryBundle, variables: JSONObject = [:], deliverables: [DeliverableRef] = [],
              contract: HandoverContinuationContract, brief: String, sinks: [HandoverSinkRef] = [],
              producedBy: EvidenceProducer, producedOn: String, createdAt: Date, digest: String = "") {
    self.id = id; self.version = version; self.taskId = taskId; self.intentId = intentId; self.fromAttemptId = fromAttemptId
    self.fromSessionId = fromSessionId; self.generation = generation; self.reason = reason; self.workflow = workflow
    self.progress = progress; self.history = history; self.variables = variables; self.deliverables = deliverables
    self.contract = contract; self.brief = brief; self.sinks = sinks; self.producedBy = producedBy; self.producedOn = producedOn
    self.createdAt = createdAt; self.digest = digest
  }
  public func canonicalDigest() throws -> String {
    var copy = self; copy.sinks = []; copy.digest = ""
    return JSONCanonical.sha256Hex(try JSONCanonical.encode(copy))
  }
  public func sealed() throws -> HandoverPacket { var copy = self; copy.digest = try canonicalDigest(); return copy }
}
public struct TakeoverPlacement: Codable, Equatable, Sendable {
  public var hostId: String; public var requiredTraits: [HostTrait]; public var backend: NodeExecutionBackend?; public var model: String?
  public init(hostId: String, requiredTraits: [HostTrait] = [], backend: NodeExecutionBackend? = nil, model: String? = nil) {
    self.hostId = hostId; self.requiredTraits = Array(Set(requiredTraits)).sorted(); self.backend = backend; self.model = model
  }
}
public struct TakeoverLineage: Codable, Equatable, Sendable {
  public var fromAttemptId: AttemptID; public var handoverId: HandoverID; public var hops: Int
  public init(fromAttemptId: AttemptID, handoverId: HandoverID, hops: Int) { self.fromAttemptId = fromAttemptId; self.handoverId = handoverId; self.hops = hops }
}
public struct AttemptLease: Codable, Equatable, Sendable {
  public var attemptId: AttemptID; public var taskId: TaskID; public var sessionId: String; public var tokenDigest: String
  public var fence: Int; public var heartbeatAt: Date; public var expiresAt: Date; public var hostId: String
  public init(attemptId: AttemptID, taskId: TaskID, sessionId: String, tokenDigest: String, fence: Int, heartbeatAt: Date, expiresAt: Date, hostId: String) {
    self.attemptId = attemptId; self.taskId = taskId; self.sessionId = sessionId; self.tokenDigest = tokenDigest
    self.fence = fence; self.heartbeatAt = heartbeatAt; self.expiresAt = expiresAt; self.hostId = hostId
  }
}
public struct LeasePolicy: Codable, Equatable, Sendable {
  public var ttlMs: Int; public var heartbeatMs: Int
  public init(ttlMs: Int = 300_000, heartbeatMs: Int = 15_000) { self.ttlMs = ttlMs; self.heartbeatMs = heartbeatMs }
}
public enum CheckpointPolicy: Codable, Equatable, Sendable {
  case none, stepBoundary, everyMs(Int)
  private enum CodingKeys: String, CodingKey { case kind, intervalMs }
  private enum Kind: String, Codable { case none, stepBoundary, everyMs }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .none: self = .none
    case .stepBoundary: self = .stepBoundary
    case .everyMs: self = .everyMs(try c.decode(Int.self, forKey: .intervalMs))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none: try c.encode(Kind.none, forKey: .kind)
    case .stepBoundary: try c.encode(Kind.stepBoundary, forKey: .kind)
    case let .everyMs(ms):
      try c.encode(Kind.everyMs, forKey: .kind)
      try c.encode(ms, forKey: .intervalMs)
    }
  }
}
public struct PublicationPolicy: Codable, Equatable, Sendable {
  public var remote: String; public var branchTemplate: String; public var branchAllowlist: String; public var allowCreateBranch: Bool
  public init(remote: String = "origin", branchTemplate: String = "riela/task/{taskId}/g{generation}", branchAllowlist: String = "riela/task/*", allowCreateBranch: Bool = true) {
    self.remote = remote; self.branchTemplate = branchTemplate; self.branchAllowlist = branchAllowlist; self.allowCreateBranch = allowCreateBranch
  }
}
public struct HandoverPolicy: Codable, Equatable, Sendable {
  public var onWaitSignal: Bool; public var checkpoint: CheckpointPolicy; public var sinks: [HandoverSinkConfig]; public var publish: PublicationPolicy
  public init(onWaitSignal: Bool = true, checkpoint: CheckpointPolicy = .stepBoundary, sinks: [HandoverSinkConfig] = [], publish: PublicationPolicy = PublicationPolicy()) {
    self.onWaitSignal = onWaitSignal; self.checkpoint = checkpoint; self.sinks = sinks; self.publish = publish
  }
}
public enum HandoverBounds {
  public static let acceptedOutput = 32_768, responseExcerpt = 4_096, history = 2_097_152, variables = 262_144
  public static let brief = 65_536, packet = 4_194_304, progressNote = 8_192, artifactFiles = 16, artifactBytes = 524_288
}
public struct TaskHandoverSummary: Codable, Equatable, Sendable {
  public var taskId: TaskID; public var handoverId: HandoverID; public var reasonKind: String; public var requiredTraits: [HostTrait]
  public var needsAnswer: Bool; public var questionText: String?; public var createdAt: Date
  public init(taskId: TaskID, handoverId: HandoverID, reasonKind: String, requiredTraits: [HostTrait], needsAnswer: Bool, questionText: String? = nil, createdAt: Date) {
    self.taskId = taskId; self.handoverId = handoverId; self.reasonKind = reasonKind; self.requiredTraits = requiredTraits
    self.needsAnswer = needsAnswer; self.questionText = questionText; self.createdAt = createdAt
  }
}
public struct HandoverRequestRecord: Codable, Equatable, Sendable {
  public var requestId: String; public var taskId: TaskID; public var attemptId: AttemptID; public var reason: String
  public var immediate: Bool; public var target: String?; public var sinks: [HandoverSinkKind]; public var requestedAt: Date; public var consumedAt: Date?
  public init(requestId: String, taskId: TaskID, attemptId: AttemptID, reason: String, immediate: Bool, target: String? = nil,
              sinks: [HandoverSinkKind] = [], requestedAt: Date, consumedAt: Date? = nil) {
    self.requestId = requestId; self.taskId = taskId; self.attemptId = attemptId; self.reason = reason; self.immediate = immediate
    self.target = target; self.sinks = sinks; self.requestedAt = requestedAt; self.consumedAt = consumedAt
  }
}
