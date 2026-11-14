import ACP
import Foundation
import RielaCore

public struct BackendWaitSignal: Equatable, Sendable {
  public var presence: PresenceRequirement
  public var eventType: String
  public var observedAt: Date

  public init(presence: PresenceRequirement, eventType: String, observedAt: Date) {
    self.presence = presence
    self.eventType = eventType
    self.observedAt = observedAt
  }
}

public struct BackendWaitSignalRule: Equatable, Sendable {
  public var eventTypes: Set<String>
  public var metadataStatus: String

  public init(eventTypes: Set<String>, metadataStatus: String) {
    self.eventTypes = eventTypes
    self.metadataStatus = metadataStatus
  }
}

public protocol BackendWaitSignalClassifying: Sendable {
  func classify(_ event: WorkflowBackendEventRecord, backend: NodeExecutionBackend) -> BackendWaitSignal?
}

public struct TableBackendWaitSignalClassifier: BackendWaitSignalClassifying {
  private static let toolCallEventTypes: Set<String> = ["tool_call", "tool_call_update"]
  private let table: [NodeExecutionBackend: [BackendWaitSignalRule]]

  public init(table: [NodeExecutionBackend: [BackendWaitSignalRule]]) {
    self.table = table
  }

  public static let `default` = TableBackendWaitSignalClassifier(
    table: Dictionary(uniqueKeysWithValues: NodeExecutionBackend.allCases.map { backend in
      let rules: [BackendWaitSignalRule]
      switch backend {
      case .codexAgent, .claudeCodeAgent, .cursorCliAgent:
        rules = [BackendWaitSignalRule(
          eventTypes: toolCallEventTypes,
          metadataStatus: ACPToolCallStatus.pending.rawValue
        )]
      case .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK:
        rules = []
      }
      return (backend, rules)
    })
  )

  public func classify(
    _ event: WorkflowBackendEventRecord,
    backend: NodeExecutionBackend
  ) -> BackendWaitSignal? {
    guard let status = event.metadata?["status"],
          case let .string(metadataStatus) = status,
          let rule = table[backend]?.first(where: {
            $0.eventTypes.contains(event.eventType) && $0.metadataStatus == metadataStatus
          }) else {
      return nil
    }

    let title: String
    if case let .string(value)? = event.metadata?["title"] {
      title = value
    } else {
      title = event.toolName ?? "unknown"
    }
    let presence = PresenceRequirement(
      traits: [.interactive, .userReachable],
      instructions: "Approve or answer the pending tool call '\(title)' on this host"
    )
    return BackendWaitSignal(presence: presence, eventType: event.eventType, observedAt: event.at)
  }

  /// Inspects only the final event. `events` must be supplied in persisted order.
  public func latestSignal(
    in events: [WorkflowBackendEventRecord],
    backend: NodeExecutionBackend
  ) -> BackendWaitSignal? {
    guard let lastEvent = events.last else { return nil }
    return classify(lastEvent, backend: backend)
  }
}
