import Foundation
import RielaCore

public struct WorkflowViewerMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var direction: WorkflowViewerMessageDirection
  public var fromStepId: String?
  public var toStepId: String?
  public var sourceStepExecutionId: String?
  public var transitionCondition: String?
  public var status: WorkflowMessageLifecycleStatus
  public var payloadPreview: String
  public var payloadJSON: String
  public var artifactRefs: [String]
  public var deliveryKind: WorkflowMessageDeliveryKind?
  public var createdOrder: Int?
  public var createdAt: Date?

  public init(
    id: String,
    direction: WorkflowViewerMessageDirection,
    fromStepId: String?,
    toStepId: String?,
    sourceStepExecutionId: String? = nil,
    transitionCondition: String? = nil,
    status: WorkflowMessageLifecycleStatus,
    payloadPreview: String,
    payloadJSON: String? = nil,
    artifactRefs: [String] = [],
    deliveryKind: WorkflowMessageDeliveryKind? = nil,
    createdOrder: Int? = nil,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.direction = direction
    self.fromStepId = fromStepId
    self.toStepId = toStepId
    self.sourceStepExecutionId = sourceStepExecutionId
    self.transitionCondition = transitionCondition
    self.status = status
    self.payloadPreview = payloadPreview
    self.payloadJSON = payloadJSON ?? payloadPreview
    self.artifactRefs = artifactRefs
    self.deliveryKind = deliveryKind
    self.createdOrder = createdOrder
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case direction
    case fromStepId
    case toStepId
    case sourceStepExecutionId
    case transitionCondition
    case status
    case payloadPreview
    case payloadJSON
    case artifactRefs
    case deliveryKind
    case createdOrder
    case createdAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    direction = try container.decode(WorkflowViewerMessageDirection.self, forKey: .direction)
    fromStepId = try container.decodeIfPresent(String.self, forKey: .fromStepId)
    toStepId = try container.decodeIfPresent(String.self, forKey: .toStepId)
    sourceStepExecutionId = try container.decodeIfPresent(String.self, forKey: .sourceStepExecutionId)
    transitionCondition = try container.decodeIfPresent(String.self, forKey: .transitionCondition)
    status = try container.decode(WorkflowMessageLifecycleStatus.self, forKey: .status)
    payloadPreview = try container.decode(String.self, forKey: .payloadPreview)
    payloadJSON = try container.decodeIfPresent(String.self, forKey: .payloadJSON) ?? payloadPreview
    artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs) ?? []
    deliveryKind = try container.decodeIfPresent(WorkflowMessageDeliveryKind.self, forKey: .deliveryKind)
    createdOrder = try container.decodeIfPresent(Int.self, forKey: .createdOrder)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
  }
}

public struct WorkflowViewerNodeMessages: Codable, Equatable, Sendable {
  public var stepId: String
  public var inbox: [WorkflowViewerMessage]
  public var outbox: [WorkflowViewerMessage]

  public init(stepId: String, inbox: [WorkflowViewerMessage] = [], outbox: [WorkflowViewerMessage] = []) {
    self.stepId = stepId
    self.inbox = inbox
    self.outbox = outbox
  }
}

public struct WorkflowViewerTimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var executionId: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var status: WorkflowStepExecutionStatus
  public var backend: NodeExecutionBackend?
  public var startedAt: Date
  public var endedAt: Date?
  public var lastBackendEventAt: Date?
  public var lastBackendEventType: String?
  public var backendEventTotalCount: Int?
  public var backendEvents: [WorkflowViewerBackendEvent]
  public var failureReason: String?

  public init(
    id: String,
    executionId: String? = nil,
    stepId: String,
    nodeId: String,
    attempt: Int,
    status: WorkflowStepExecutionStatus,
    backend: NodeExecutionBackend? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    lastBackendEventAt: Date? = nil,
    lastBackendEventType: String? = nil,
    backendEventTotalCount: Int? = nil,
    backendEvents: [WorkflowViewerBackendEvent] = [],
    failureReason: String? = nil
  ) {
    self.id = id
    self.executionId = executionId ?? id
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.status = status
    self.backend = backend
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.lastBackendEventAt = lastBackendEventAt
    self.lastBackendEventType = lastBackendEventType
    self.backendEventTotalCount = backendEventTotalCount
    self.backendEvents = backendEvents
    self.failureReason = failureReason
  }

  public var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(startedAt) }
  }

  public func ganttLogSummary(maxLength: Int = 72) -> String {
    let rawSummary = failureReason.map { "Failure: \($0)" }
      ?? latestBackendEventSummary()
      ?? lastBackendEventType
      ?? backendEventCountSummary()
      ?? status.rawValue.replacingOccurrences(of: "_", with: " ")
    return Self.truncated(Self.singleLine(rawSummary), maxLength: maxLength)
  }

  private func latestBackendEventSummary() -> String? {
    guard let event = backendEvents.sorted(by: { $0.sequence < $1.sequence }).last else {
      return nil
    }
    if let content = event.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return content
    }
    if let toolName = event.toolName, !toolName.isEmpty {
      return "\(event.eventType) \(toolName)"
    }
    return event.eventType
  }

  private func backendEventCountSummary() -> String? {
    guard let backendEventTotalCount, backendEventTotalCount > 0 else {
      return nil
    }
    return backendEventTotalCount == 1 ? "1 backend event" : "\(backendEventTotalCount) backend events"
  }

  private static func singleLine(_ value: String) -> String {
    value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func truncated(_ value: String, maxLength: Int) -> String {
    guard maxLength > 3, value.count > maxLength else {
      return value
    }
    return "\(value.prefix(maxLength - 3))..."
  }

  enum CodingKeys: String, CodingKey {
    case id
    case executionId
    case stepId
    case nodeId
    case attempt
    case status
    case backend
    case startedAt
    case endedAt
    case lastBackendEventAt
    case lastBackendEventType
    case backendEventTotalCount
    case backendEvents
    case failureReason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    executionId = try container.decodeIfPresent(String.self, forKey: .executionId) ?? id
    stepId = try container.decode(String.self, forKey: .stepId)
    nodeId = try container.decode(String.self, forKey: .nodeId)
    attempt = try container.decode(Int.self, forKey: .attempt)
    status = try container.decode(WorkflowStepExecutionStatus.self, forKey: .status)
    backend = try container.decodeIfPresent(NodeExecutionBackend.self, forKey: .backend)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    lastBackendEventAt = try container.decodeIfPresent(Date.self, forKey: .lastBackendEventAt)
    lastBackendEventType = try container.decodeIfPresent(String.self, forKey: .lastBackendEventType)
    backendEventTotalCount = try container.decodeIfPresent(Int.self, forKey: .backendEventTotalCount)
    backendEvents = try container.decodeIfPresent([WorkflowViewerBackendEvent].self, forKey: .backendEvents) ?? []
    failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
  }
}

public struct WorkflowViewerBackendEvent: Codable, Equatable, Sendable {
  public var sequence: Int
  public var at: Date
  public var eventType: String
  public var channel: AdapterBackendEventChannel?
  public var content: String?
  public var toolName: String?

  public init(
    sequence: Int,
    at: Date,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    content: String? = nil,
    toolName: String? = nil
  ) {
    self.sequence = sequence
    self.at = at
    self.eventType = eventType
    self.channel = channel
    self.content = content
    self.toolName = toolName
  }
}
