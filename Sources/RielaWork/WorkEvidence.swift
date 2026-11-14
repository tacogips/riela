import Foundation
import RielaCore

/// The one severity scale (design section 8 merges `WorkflowReviewFinding` and
/// `LoopBlockingFinding` onto "the same aliases as today", so the alias table
/// is reused rather than copied).
public typealias FindingSeverity = WorkflowReviewFindingSeverity
public typealias FindingStatus = WorkflowReviewFindingStatus

public enum EvidenceKind: String, Codable, CaseIterable, Sendable {
  case gate
  case finding
  case verification
  case command
  case changedFile
  case artifact
  case cost
  case guardViolation
  case decision
  case delivery
  case contextSnapshot
}

/// What produced a ledger record.
public enum EvidenceProducer: Codable, Equatable, Sendable {
  case stepExecution(String)
  case addon(String)
  case runtime
  case director(sessionId: String)
  case human(principal: String)
  case contextAdapter(String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case stepExecutionId
    case addon
    case sessionId
    case principal
    case adapter
  }

  private enum Kind: String, Codable {
    case stepExecution
    case addon
    case runtime
    case director
    case human
    case contextAdapter
  }

  /// The step execution this record came out of, when there is one. The
  /// projector uses it to build `causedBy` edges.
  public var stepExecutionId: String? {
    if case let .stepExecution(id) = self { return id }
    return nil
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .stepExecution:
      self = .stepExecution(try container.decode(String.self, forKey: .stepExecutionId))
    case .addon:
      self = .addon(try container.decode(String.self, forKey: .addon))
    case .runtime:
      self = .runtime
    case .director:
      self = .director(sessionId: try container.decode(String.self, forKey: .sessionId))
    case .human:
      self = .human(principal: try container.decode(String.self, forKey: .principal))
    case .contextAdapter:
      self = .contextAdapter(try container.decode(String.self, forKey: .adapter))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .stepExecution(id):
      try container.encode(Kind.stepExecution, forKey: .kind)
      try container.encode(id, forKey: .stepExecutionId)
    case let .addon(name):
      try container.encode(Kind.addon, forKey: .kind)
      try container.encode(name, forKey: .addon)
    case .runtime:
      try container.encode(Kind.runtime, forKey: .kind)
    case let .director(sessionId):
      try container.encode(Kind.director, forKey: .kind)
      try container.encode(sessionId, forKey: .sessionId)
    case let .human(principal):
      try container.encode(Kind.human, forKey: .kind)
      try container.encode(principal, forKey: .principal)
    case let .contextAdapter(adapter):
      try container.encode(Kind.contextAdapter, forKey: .kind)
      try container.encode(adapter, forKey: .adapter)
    }
  }
}

/// A small record is inlined; anything large is an artifact path under the
/// runtime store.
public enum PayloadReference: Codable, Equatable, Sendable {
  case inline(JSONObject)
  case artifact(path: String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case inline
    case path
  }

  private enum Kind: String, Codable {
    case inline
    case artifact
  }

  public var inlinePayload: JSONObject? {
    if case let .inline(payload) = self { return payload }
    return nil
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .inline:
      self = .inline(try container.decode(JSONObject.self, forKey: .inline))
    case .artifact:
      self = .artifact(path: try container.decode(String.self, forKey: .path))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .inline(payload):
      try container.encode(Kind.inline, forKey: .kind)
      try container.encode(payload, forKey: .inline)
    case let .artifact(path):
      try container.encode(Kind.artifact, forKey: .kind)
      try container.encode(path, forKey: .path)
    }
  }
}

/// One record in the task ledger. Every record names what produced it and
/// what caused it (design section 8); line-level causality is not attempted.
public struct Evidence: Codable, Equatable, Sendable {
  public var id: EvidenceID
  public var taskId: TaskID
  public var attemptId: AttemptID?
  public var kind: EvidenceKind
  public var producedBy: EvidenceProducer
  public var causedBy: [EvidenceID]
  public var payloadRef: PayloadReference
  public var createdAt: Date

  public init(
    id: EvidenceID,
    taskId: TaskID,
    attemptId: AttemptID? = nil,
    kind: EvidenceKind,
    producedBy: EvidenceProducer,
    causedBy: [EvidenceID] = [],
    payloadRef: PayloadReference,
    createdAt: Date
  ) {
    self.id = id
    self.taskId = taskId
    self.attemptId = attemptId
    self.kind = kind
    self.producedBy = producedBy
    self.causedBy = causedBy
    self.payloadRef = payloadRef
    self.createdAt = createdAt
  }
}

/// `WorkflowReviewFinding` and `LoopBlockingFinding` merged into one record.
/// `id` is the authored id; `fingerprint` is the identity the ledger dedupes
/// on and is always derived from the source fields, never stored alone.
public struct Finding: Codable, Equatable, Sendable {
  public var id: String
  public var fingerprint: LoopFindingFingerprint
  public var severity: FindingSeverity
  public var status: FindingStatus
  public var gateId: String?
  public var sourceStepExecutionId: String
  public var targetStepId: String?
  public var filePath: String?
  public var line: Int?
  public var message: String
  public var feedback: String?

  public init(
    id: String,
    fingerprint: LoopFindingFingerprint,
    severity: FindingSeverity,
    status: FindingStatus = .open,
    gateId: String? = nil,
    sourceStepExecutionId: String,
    targetStepId: String? = nil,
    filePath: String? = nil,
    line: Int? = nil,
    message: String,
    feedback: String? = nil
  ) {
    self.id = id
    self.fingerprint = fingerprint
    self.severity = severity
    self.status = status
    self.gateId = gateId
    self.sourceStepExecutionId = sourceStepExecutionId
    self.targetStepId = targetStepId
    self.filePath = filePath
    self.line = line
    self.message = message
    self.feedback = feedback
  }

  /// A finding that still blocks completion: open, and at a severity the
  /// review retry rules already treat as blocking (high or mid).
  public var blocksCompletion: Bool {
    status == .open && severity.blocksReviewRetry
  }
}
