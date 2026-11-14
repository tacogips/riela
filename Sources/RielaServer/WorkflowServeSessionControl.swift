import Foundation

public enum WorkflowServeSessionControlWire {
  public static let controlTypes = ["session-cancel", "session-list"]
  public static let acknowledgementTypes = ["session-cancel-ack", "session-list-ack"]
  public static let maxReasonBytes = 512
}

public struct WorkflowServeSessionControlFrame: Codable, Equatable, Sendable {
  public var type: String
  public var requestId: String
  public var sessionId: String?
  public var reason: String?
  public var actor: String?

  public init(type: String, requestId: String, sessionId: String? = nil, reason: String? = nil, actor: String? = nil) {
    self.type = type
    self.requestId = requestId
    self.sessionId = sessionId
    self.reason = reason
    self.actor = actor
  }

  public func encodedLine() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var data = try encoder.encode(self)
    data.append(0x0a)
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes else {
      throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Session control frame exceeds limit"))
    }
    return data
  }

  public static func decodeControlLine(_ data: Data) -> Self? {
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes,
      let frame = try? JSONDecoder().decode(Self.self, from: data),
      WorkflowServeSessionControlWire.controlTypes.contains(frame.type) else { return nil }
    if frame.type == "session-cancel" {
      guard let sessionId = frame.sessionId, !sessionId.isEmpty,
        let reason = frame.reason, (1...WorkflowServeSessionControlWire.maxReasonBytes).contains(reason.utf8.count),
        !reason.contains("\0"), let actor = frame.actor, !actor.isEmpty else { return nil }
    }
    return frame
  }
}

public enum WorkflowServeSessionCancelOutcome: String, Codable, Sendable {
  case cancelRequested, alreadyRequested, notFound
}

// The public wire contract pins this name.
// swiftlint:disable:next type_name
public struct WorkflowServeSessionControlAcknowledgement: Codable, Equatable, Sendable {
  public var type: String
  public var requestId: String
  public var sessionId: String?
  public var outcome: WorkflowServeSessionCancelOutcome?
  public var sessionIds: [String]?
  public var pendingRunCount: Int?

  public init(type: String, requestId: String, sessionId: String? = nil, outcome: WorkflowServeSessionCancelOutcome? = nil,
              sessionIds: [String]? = nil, pendingRunCount: Int? = nil) {
    self.type = type
    self.requestId = requestId
    self.sessionId = sessionId
    self.outcome = outcome
    self.sessionIds = sessionIds
    self.pendingRunCount = pendingRunCount
  }

  public static func decodeLine(_ data: Data) -> Self? {
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes,
      let ack = try? JSONDecoder().decode(Self.self, from: data),
      WorkflowServeSessionControlWire.acknowledgementTypes.contains(ack.type) else { return nil }
    return ack
  }

  public static func cancelAck(requestId: String, sessionId: String, outcome: WorkflowServeSessionCancelOutcome) -> Self {
    Self(type: "session-cancel-ack", requestId: requestId, sessionId: sessionId, outcome: outcome)
  }

  public static func listAck(requestId: String, sessionIds: [String], pendingRunCount: Int) -> Self {
    Self(type: "session-list-ack", requestId: requestId, sessionIds: sessionIds, pendingRunCount: pendingRunCount)
  }
}

public enum WorkflowServeSessionControlError: Error, Equatable, Sendable {
  case unsupported, noAcknowledgement, childExited
}
