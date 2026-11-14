import Foundation

public enum WorkflowServeAdmissionWire {
  public static let controlTypes = ["admission-close", "admission-confirm", "admission-open"]
  public static let acknowledgementType = "admission-ack"
  public static let defaultLeaseSeconds = 120
  public static let maxFrameBytes = 1_048_576
}

public struct WorkflowServeAdmissionFrame: Codable, Equatable, Sendable {
  public var type: String
  public var requestId: String
  public var leaseSeconds: Int?

  public init(type: String, requestId: String, leaseSeconds: Int? = nil) {
    self.type = type
    self.requestId = requestId
    self.leaseSeconds = leaseSeconds
  }

  public func encodedLine() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var data = try encoder.encode(self)
    data.append(0x0a)
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes else {
      throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Admission frame exceeds limit"))
    }
    return data
  }

  public static func decodeControlLine(_ data: Data) -> Self? {
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes,
      let frame = try? JSONDecoder().decode(Self.self, from: data),
      WorkflowServeAdmissionWire.controlTypes.contains(frame.type) else { return nil }
    return frame
  }
}

public enum WorkflowServeAdmissionState: String, Codable, Sendable {
  case open, closed, expired
}

public struct WorkflowServeAdmissionAcknowledgement: Codable, Equatable, Sendable {
  public var type: String
  public var requestId: String
  public var state: WorkflowServeAdmissionState
  public var running: Int
  public var queued: Int

  public init(type: String = WorkflowServeAdmissionWire.acknowledgementType, requestId: String,
              state: WorkflowServeAdmissionState, running: Int, queued: Int) {
    self.type = type
    self.requestId = requestId
    self.state = state
    self.running = running
    self.queued = queued
  }

  public static func decodeLine(_ data: Data) -> Self? {
    guard data.count <= WorkflowServeAdmissionWire.maxFrameBytes,
      let ack = try? JSONDecoder().decode(Self.self, from: data),
      ack.type == WorkflowServeAdmissionWire.acknowledgementType else { return nil }
    return ack
  }
}

public enum WorkflowServeAdmissionError: Error, Equatable, Sendable {
  case unsupported, noAcknowledgement, childExited
}
