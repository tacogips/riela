import Foundation

public struct WorkflowStepBackendEventInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
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

  public init(
    sessionId: String,
    executionId: String,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    contentDelta: String? = nil,
    contentSnapshot: String? = nil,
    isDelta: Bool = false,
    toolName: String? = nil,
    usage: JSONObject? = nil,
    metadata: JSONObject? = nil,
    sequence: Int? = nil,
    at: Date? = nil
  ) {
    self.sessionId = sessionId
    self.executionId = executionId
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
  }
}
