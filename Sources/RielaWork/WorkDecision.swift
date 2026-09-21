import Foundation

/// Who produced a decision (design section 4). Directors never execute; the
/// runtime applies what they decide.
public enum DecisionProducer: Codable, Equatable, Sendable {
  case policy(rule: String)
  case agent(sessionId: String)
  case human(principal: String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case rule
    case sessionId
    case principal
  }

  private enum Kind: String, Codable {
    case policy
    case agent
    case human
  }

  /// The `work_decisions.producer_kind` filter column.
  public var kindName: String {
    switch self {
    case .policy: return Kind.policy.rawValue
    case .agent: return Kind.agent.rawValue
    case .human: return Kind.human.rawValue
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .policy:
      self = .policy(rule: try container.decode(String.self, forKey: .rule))
    case .agent:
      self = .agent(sessionId: try container.decode(String.self, forKey: .sessionId))
    case .human:
      self = .human(principal: try container.decode(String.self, forKey: .principal))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .policy(rule):
      try container.encode(Kind.policy, forKey: .kind)
      try container.encode(rule, forKey: .rule)
    case let .agent(sessionId):
      try container.encode(Kind.agent, forKey: .kind)
      try container.encode(sessionId, forKey: .sessionId)
    case let .human(principal):
      try container.encode(Kind.human, forKey: .kind)
      try container.encode(principal, forKey: .principal)
    }
  }
}

public enum WaitReason: Codable, Equatable, Sendable {
  case capacity
  case dependency
  case clarification(question: String)
  case until(Date)

  private enum CodingKeys: String, CodingKey {
    case kind
    case question
    case date
  }

  private enum Kind: String, Codable {
    case capacity
    case dependency
    case clarification
    case until
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .capacity:
      self = .capacity
    case .dependency:
      self = .dependency
    case .clarification:
      self = .clarification(question: try container.decode(String.self, forKey: .question))
    case .until:
      self = .until(try container.decode(Date.self, forKey: .date))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .capacity:
      try container.encode(Kind.capacity, forKey: .kind)
    case .dependency:
      try container.encode(Kind.dependency, forKey: .kind)
    case let .clarification(question):
      try container.encode(Kind.clarification, forKey: .kind)
      try container.encode(question, forKey: .question)
    case let .until(date):
      try container.encode(Kind.until, forKey: .kind)
      try container.encode(date, forKey: .date)
    }
  }
}

/// A workflow change a director proposed. The proposal is routed through the
/// existing `workflow self-improve` review gate in P2; P0 only records it.
public struct ProposalRef: Codable, Equatable, Sendable {
  public var id: String
  public var summary: String?

  public init(id: String, summary: String? = nil) {
    self.id = id
    self.summary = summary
  }
}

/// A `stop` decision always points at the guard-violation evidence that
/// caused it.
public struct GuardViolationRef: Codable, Equatable, Sendable {
  public var evidenceId: EvidenceID
  public var summary: String

  public init(evidenceId: EvidenceID, summary: String) {
    self.evidenceId = evidenceId
    self.summary = summary
  }
}

public enum DecisionKind: Codable, Equatable, Sendable {
  case start
  case resume
  case rerun(fromStepId: String?)
  case recover(fromGateId: String)
  case replan(instruction: String)
  case wait(WaitReason)
  case proposeWorkflowChange(ProposalRef)
  case accept
  case reject(reason: String)
  case cancel
  case stop(GuardViolationRef)

  private enum CodingKeys: String, CodingKey {
    case kind
    case fromStepId
    case fromGateId
    case instruction
    case wait
    case proposal
    case reason
    case violation
  }

  private enum Kind: String, Codable {
    case start
    case resume
    case rerun
    case recover
    case replan
    case wait
    case proposeWorkflowChange
    case accept
    case reject
    case cancel
    case stop
  }

  /// The `work_decisions.kind` filter column.
  public var kindName: String {
    switch self {
    case .start: return Kind.start.rawValue
    case .resume: return Kind.resume.rawValue
    case .rerun: return Kind.rerun.rawValue
    case .recover: return Kind.recover.rawValue
    case .replan: return Kind.replan.rawValue
    case .wait: return Kind.wait.rawValue
    case .proposeWorkflowChange: return Kind.proposeWorkflowChange.rawValue
    case .accept: return Kind.accept.rawValue
    case .reject: return Kind.reject.rawValue
    case .cancel: return Kind.cancel.rawValue
    case .stop: return Kind.stop.rawValue
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .start:
      self = .start
    case .resume:
      self = .resume
    case .rerun:
      self = .rerun(fromStepId: try container.decodeIfPresent(String.self, forKey: .fromStepId))
    case .recover:
      self = .recover(fromGateId: try container.decode(String.self, forKey: .fromGateId))
    case .replan:
      self = .replan(instruction: try container.decode(String.self, forKey: .instruction))
    case .wait:
      self = .wait(try container.decode(WaitReason.self, forKey: .wait))
    case .proposeWorkflowChange:
      self = .proposeWorkflowChange(try container.decode(ProposalRef.self, forKey: .proposal))
    case .accept:
      self = .accept
    case .reject:
      self = .reject(reason: try container.decode(String.self, forKey: .reason))
    case .cancel:
      self = .cancel
    case .stop:
      self = .stop(try container.decode(GuardViolationRef.self, forKey: .violation))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .start:
      try container.encode(Kind.start, forKey: .kind)
    case .resume:
      try container.encode(Kind.resume, forKey: .kind)
    case let .rerun(fromStepId):
      try container.encode(Kind.rerun, forKey: .kind)
      try container.encodeIfPresent(fromStepId, forKey: .fromStepId)
    case let .recover(fromGateId):
      try container.encode(Kind.recover, forKey: .kind)
      try container.encode(fromGateId, forKey: .fromGateId)
    case let .replan(instruction):
      try container.encode(Kind.replan, forKey: .kind)
      try container.encode(instruction, forKey: .instruction)
    case let .wait(reason):
      try container.encode(Kind.wait, forKey: .kind)
      try container.encode(reason, forKey: .wait)
    case let .proposeWorkflowChange(proposal):
      try container.encode(Kind.proposeWorkflowChange, forKey: .kind)
      try container.encode(proposal, forKey: .proposal)
    case .accept:
      try container.encode(Kind.accept, forKey: .kind)
    case let .reject(reason):
      try container.encode(Kind.reject, forKey: .kind)
      try container.encode(reason, forKey: .reason)
    case .cancel:
      try container.encode(Kind.cancel, forKey: .kind)
    case let .stop(violation):
      try container.encode(Kind.stop, forKey: .kind)
      try container.encode(violation, forKey: .violation)
    }
  }
}

/// Every "what happens next" is one of these (design decision 6).
public struct Decision: Codable, Equatable, Sendable {
  public var id: DecisionID
  public var taskId: TaskID
  public var attemptId: AttemptID?
  public var producer: DecisionProducer
  public var kind: DecisionKind
  public var reason: String
  public var causedBy: [EvidenceID]
  public var createdAt: Date

  public init(
    id: DecisionID,
    taskId: TaskID,
    attemptId: AttemptID? = nil,
    producer: DecisionProducer,
    kind: DecisionKind,
    reason: String,
    causedBy: [EvidenceID] = [],
    createdAt: Date
  ) {
    self.id = id
    self.taskId = taskId
    self.attemptId = attemptId
    self.producer = producer
    self.kind = kind
    self.reason = reason
    self.causedBy = causedBy
    self.createdAt = createdAt
  }
}
