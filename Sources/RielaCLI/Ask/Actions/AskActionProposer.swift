import Foundation
import RielaCore

enum AskActionTarget: Sendable {
  case sessionStop(sessionId: String, workflowId: String)
  case sessionRerun(sessionId: String, workflowId: String, stepId: String)
  case requestAnswer(requestId: String, optionId: String?)
  case botPause(botId: String, paused: Bool)

  var record: JSONObject {
    switch self {
    case let .sessionStop(sessionId, workflowId):
      return ["sessionId": .string(sessionId), "workflowId": .string(workflowId)]
    case let .sessionRerun(sessionId, workflowId, stepId):
      return ["sessionId": .string(sessionId), "workflowId": .string(workflowId), "stepId": .string(stepId)]
    case let .requestAnswer(requestId, optionId):
      var record: JSONObject = ["requestId": .string(requestId)]
      if let optionId {
        record["optionId"] = .string(optionId)
      } else {
        record["decline"] = .bool(true)
      }
      return record
    case let .botPause(botId, paused):
      return ["botId": .string(botId), "paused": .bool(paused)]
    }
  }
}

struct AskActionProposer: Sendable {
  let surface: any AskReadSurface
  let store: BotStore
  var environment: [String: String] = [:]
  var limits: AskLimits = .standard
  var now: @Sendable () -> Date = { Date() }
  var additionalRedactionValues: [String: String] = [:]

  func propose(
    conversationId: String, turnId: String, kind: String, target: JSONObject, reason: String?
  ) async throws -> AskAction {
    guard let kind = AskActionKind(rawValue: kind) else {
      throw AskError(code: "action_kind_unknown", message: "Unknown proposed action kind")
    }
    let at = now()
    let validated = try await validate(kind: kind, target: target, at: at)
    let action = AskAction(
      conversationId: conversationId, turnId: turnId, kind: kind,
      target: validated.record, reason: cleanReason(reason ?? ""),
      createdAt: RoutineStore.timestamp(at),
      expiresAt: RoutineStore.timestamp(at.addingTimeInterval(TimeInterval(limits.actionLifetimeSeconds)))
    )
    return try store.insertAskAction(action, limits: limits)
  }

  func revalidate(_ action: AskAction, at: Date) async throws -> AskActionTarget {
    var proposed = action.target
    proposed.removeValue(forKey: "workflowId")
    let validated = try await validate(kind: action.kind, target: proposed, at: at)
    // Execute only if the stored fields still describe the same target.
    guard validated.record == action.target else { throw Self.invalidTarget }
    return validated
  }

  private func validate(kind: AskActionKind, target: JSONObject, at: Date) async throws -> AskActionTarget {
    let keys = Set(target.keys)
    switch kind {
    case .stopSession:
      guard keys == ["sessionId"], case let .string(sessionId)? = target["sessionId"] else {
        throw Self.invalidTarget
      }
      let session = try await session(id: sessionId)
      guard !session.status.isTerminal else { throw Self.invalidTarget }
      return .sessionStop(sessionId: session.sessionId, workflowId: session.workflowId)
    case .rerunSession:
      guard keys == ["sessionId", "stepId"],
            case let .string(sessionId)? = target["sessionId"],
            case let .string(stepId)? = target["stepId"], !stepId.isEmpty else {
        throw Self.invalidTarget
      }
      let session = try await session(id: sessionId)
      guard try await surface.actionStepExists(sessionId: session.sessionId, stepId: stepId) else {
        throw Self.invalidTarget
      }
      return .sessionRerun(sessionId: session.sessionId, workflowId: session.workflowId, stepId: stepId)
    case .answerBotRequest:
      return try await requestAnswer(target, keys: keys, at: at)
    case .setBotPaused:
      guard keys == ["botId", "paused"],
            case let .string(botId)? = target["botId"], !botId.isEmpty,
            case let .bool(paused)? = target["paused"],
            try await surface.actionBotExists(id: botId) else {
        throw Self.invalidTarget
      }
      return .botPause(botId: botId, paused: paused)
    }
  }

  private func session(id: String) async throws -> WorkflowSession {
    guard !id.isEmpty else { throw Self.invalidTarget }
    do {
      return try await surface.actionSession(id: id)
    } catch let error as AskError where error.code == "not_found" {
      throw Self.invalidTarget
    }
  }

  private func requestAnswer(_ target: JSONObject, keys: Set<String>, at: Date) async throws -> AskActionTarget {
    guard case let .string(requestId)? = target["requestId"], !requestId.isEmpty,
          let request = try await surface.actionPermissionRequest(id: requestId),
          request.status == .pending, at < request.expiresAt else {
      throw Self.invalidTarget
    }
    if keys == ["requestId", "decline"], target["decline"] == .bool(true) {
      return .requestAnswer(requestId: request.requestId, optionId: nil)
    }
    guard keys == ["requestId", "optionId"],
          case let .string(optionId)? = target["optionId"],
          request.options.contains(where: { $0.optionId == optionId }) else {
      throw Self.invalidTarget
    }
    return .requestAnswer(requestId: request.requestId, optionId: optionId)
  }

  private func cleanReason(_ reason: String) -> String {
    let scalars = reason.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let clean = AskRedaction.text(
      String(String.UnicodeScalarView(scalars)), environment: environment, additionalValues: additionalRedactionValues
    )
    return String(clean.prefix(200))
  }

  static var invalidTarget: AskError {
    AskError(code: "action_target_invalid", message: "The action target is invalid or no longer available")
  }
}
