import Foundation

public enum HostTrait: String, Codable, CaseIterable, Sendable, Comparable {
  case userReachable
  case interactive
  case tccApproved
  case hardwareKey
  case gui
  public static func < (lhs: HostTrait, rhs: HostTrait) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HandoverOption: Codable, Equatable, Sendable {
  public var id: String
  public var label: String
  public var description: String?
  public init(id: String, label: String, description: String? = nil) {
    self.id = id; self.label = label; self.description = description
  }
}
public struct HandoverQuestion: Codable, Equatable, Sendable {
  public var id: String
  public var text: String
  public var options: [HandoverOption]
  public var answerSchema: JSONObject?
  public var defaultAnswer: JSONObject?
  public var impact: String?
  public init(id: String, text: String, options: [HandoverOption] = [], answerSchema: JSONObject? = nil,
              defaultAnswer: JSONObject? = nil, impact: String? = nil) {
    self.id = id; self.text = text; self.options = options; self.answerSchema = answerSchema
    self.defaultAnswer = defaultAnswer; self.impact = impact
  }
}
public struct PresenceRequirement: Codable, Equatable, Sendable {
  public var traits: [HostTrait]
  public var instructions: String
  public init(traits: [HostTrait], instructions: String) {
    self.traits = Array(Set(traits)).sorted(); self.instructions = instructions
  }
  private enum CodingKeys: String, CodingKey { case traits, instructions }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(traits: try c.decode([HostTrait].self, forKey: .traits), instructions: try c.decode(String.self, forKey: .instructions))
  }
}
public enum SuspendReasonKind: String, Codable, Sendable { case userInputRequired, userPresenceRequired, operatorMove }
public enum SuspendProducer: Codable, Equatable, Sendable {
  case stepExecution(String)
  case runtime
  case human(principal: String)
  private enum CodingKeys: String, CodingKey { case kind, stepExecutionId, principal }
  private enum Kind: String, Codable { case stepExecution, runtime, human }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .stepExecution: self = .stepExecution(try c.decode(String.self, forKey: .stepExecutionId))
    case .runtime: self = .runtime
    case .human: self = .human(principal: try c.decode(String.self, forKey: .principal))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .stepExecution(id): try c.encode(Kind.stepExecution, forKey: .kind); try c.encode(id, forKey: .stepExecutionId)
    case .runtime: try c.encode(Kind.runtime, forKey: .kind)
    case let .human(principal): try c.encode(Kind.human, forKey: .kind); try c.encode(principal, forKey: .principal)
    }
  }
}
public struct SuspendRecord: Codable, Equatable, Sendable {
  public var reasonKind: SuspendReasonKind
  public var stepId: String
  public var stepExecutionId: String?
  public var question: HandoverQuestion?
  public var presence: PresenceRequirement?
  public var progressNote: String?
  public var suspendedAt: Date
  public var producer: SuspendProducer
  public init(reasonKind: SuspendReasonKind, stepId: String, stepExecutionId: String? = nil,
              question: HandoverQuestion? = nil, presence: PresenceRequirement? = nil,
              progressNote: String? = nil, suspendedAt: Date, producer: SuspendProducer) {
    self.reasonKind = reasonKind; self.stepId = stepId; self.stepExecutionId = stepExecutionId
    self.question = question; self.presence = presence; self.progressNote = progressNote
    self.suspendedAt = suspendedAt; self.producer = producer
  }
}
public struct HandoverEnvelope: Codable, Equatable, Sendable {
  public var reason: SuspendReasonKind
  public var question: HandoverQuestion?
  public var presence: PresenceRequirement?
  public var progressNote: String?
  public var resumeStepId: String?
  public static let reservedKey = "handover"
  public init(reason: SuspendReasonKind, question: HandoverQuestion? = nil, presence: PresenceRequirement? = nil,
              progressNote: String? = nil, resumeStepId: String? = nil) {
    self.reason = reason; self.question = question; self.presence = presence
    self.progressNote = progressNote; self.resumeStepId = resumeStepId
  }
  public static func parse(_ value: JSONValue, source: String) throws -> HandoverEnvelope {
    func invalid(_ detail: String) -> AdapterExecutionError { AdapterExecutionError(.invalidOutput, "\(source).handover\(detail)") }
    guard case let .object(object) = value else { throw invalid(" must be an object") }
    let allowed: Set<String> = ["reason", "question", "presence", "progressNote", "resumeStepId"]
    guard object.keys.allSatisfy(allowed.contains) else { throw invalid(" contains an unsupported key") }
    guard let raw = object["reason"]?.stringValue, let reason = SuspendReasonKind(rawValue: raw), reason != .operatorMove else {
      throw invalid(".reason must be userInputRequired or userPresenceRequired")
    }
    let question: HandoverQuestion?
    let presence: PresenceRequirement?
    do {
      question = try object["question"].map { try decodeHandoverObject(HandoverQuestion.self, $0) }
      presence = try object["presence"].map { try decodeHandoverObject(PresenceRequirement.self, $0) }
    } catch {
      throw invalid(" contains an invalid question or presence payload")
    }
    if reason == .userInputRequired,
       question?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        || question?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      throw invalid(".question with non-empty id and text is required")
    }
    if reason == .userPresenceRequired, presence?.traits.isEmpty != false { throw invalid(".presence with at least one trait is required") }
    if let note = object["progressNote"] {
      guard let text = note.stringValue else { throw invalid(".progressNote must be a string") }
      guard text.utf8.count <= 8_192 else { throw invalid(".progressNote exceeds 8192 UTF-8 bytes") }
    }
    if let resume = object["resumeStepId"] {
      guard let text = resume.stringValue else { throw invalid(".resumeStepId must be a string") }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid(".resumeStepId must be non-empty") }
    }
    return HandoverEnvelope(reason: reason, question: question, presence: presence,
                            progressNote: object["progressNote"]?.stringValue, resumeStepId: object["resumeStepId"]?.stringValue)
  }
}
private func decodeHandoverObject<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
  try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
}
private extension JSONValue {
  var stringValue: String? { if case let .string(value) = self { return value }; return nil }
}
public enum HandoverSinkKind: String, Codable, Sendable { case store, kaiba, gitRef, file, command }
public struct HandoverSinkConfig: Codable, Equatable, Sendable {
  public var kind: HandoverSinkKind
  public var kaibaInstanceId: String?
  public var notebookId: String?
  public var remote: String?
  public var path: String?
  public var command: [String]?
  public init(kind: HandoverSinkKind, kaibaInstanceId: String? = nil, notebookId: String? = nil,
              remote: String? = nil, path: String? = nil, command: [String]? = nil) {
    self.kind = kind; self.kaibaInstanceId = kaibaInstanceId; self.notebookId = notebookId
    self.remote = remote; self.path = path; self.command = command
  }
}
public struct HandoverSinkRef: Codable, Equatable, Sendable {
  public var kind: HandoverSinkKind
  public var locator: String
  public var digest: String
  public var writtenAt: Date
  public var serialized: String { "\(kind.rawValue):\(locator)#sha256:\(digest)" }
  public init(kind: HandoverSinkKind, locator: String, digest: String, writtenAt: Date) {
    self.kind = kind; self.locator = locator; self.digest = digest; self.writtenAt = writtenAt
  }
  public static func parse(_ value: String) throws -> ParsedHandoverSinkRef {
    guard let colon = value.firstIndex(of: ":"), let marker = value.range(of: "#sha256:", options: .backwards) else { throw SinkRefError.invalid }
    let kindString = String(value[..<colon]); let locatorStart = value.index(after: colon)
    let digest = String(value[marker.upperBound...])
    guard marker.lowerBound >= locatorStart, let kind = HandoverSinkKind(rawValue: kindString), digest.count == 64,
          digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SinkRefError.invalid }
    return ParsedHandoverSinkRef(kind: kind, locator: String(value[locatorStart..<marker.lowerBound]), digest: digest)
  }
  public enum SinkRefError: Error { case invalid }
}
public struct ParsedHandoverSinkRef: Codable, Equatable, Sendable {
  public var kind: HandoverSinkKind
  public var locator: String
  public var digest: String
  public init(kind: HandoverSinkKind, locator: String, digest: String) {
    self.kind = kind; self.locator = locator; self.digest = digest
  }
}
public struct HandoverHistoryBundle: Codable, Equatable, Sendable {
  public var executions: [WorkflowStepExecution]; public var messages: [WorkflowMessageRecord]
  public var compatibilityDigests: [String: String]; public var truncated: Bool
  public init(executions: [WorkflowStepExecution], messages: [WorkflowMessageRecord], compatibilityDigests: [String: String], truncated: Bool) {
    self.executions = executions; self.messages = messages; self.compatibilityDigests = compatibilityDigests; self.truncated = truncated
  }
}
public struct WorkflowHandoverDeclaration: Codable, Equatable, Sendable {
  public var sinks: [HandoverSinkConfig]; public init(sinks: [HandoverSinkConfig]) { self.sinks = sinks }
}
public struct WorkflowDeliverableProjection: Codable, Equatable, Sendable {
  public var store: String; public var instanceField: String?; public var idFields: [String]
  public init(store: String, instanceField: String? = nil, idFields: [String]) { self.store = store; self.instanceField = instanceField; self.idFields = idFields }
}
