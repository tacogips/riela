import Foundation
import RielaCore
import RielaGraphQL

struct AskActionService: Sendable {
  let store: BotStore
  let proposals: AskActionProposer
  let mutations: any AskMutationSurface
  var environment: [String: String] = [:]
  var now: @Sendable () -> Date = { Date() }

  func confirm(conversationId: String, actionId: String, decidedBy: String) async throws -> AskAction {
    let at = now()
    let action = try store.decideAskAction(
      conversationId: conversationId, actionId: actionId, decision: .confirm, decidedBy: decidedBy, now: at
    )
    let target: AskActionTarget
    do {
      target = try await proposals.revalidate(action, at: now())
    } catch {
      return try store.completeAskAction(actionId: actionId, result: failure(AskActionProposer.invalidTarget), now: now())
    }

    var result: AskActionResult
    do {
      result = try await execute(target)
      result.message = result.message.map { AskRedaction.text($0, environment: environment) }
      result.summary = result.summary.map { AskRedaction.text($0, environment: environment) }
    } catch {
      result = failure(error)
    }
    return try store.completeAskAction(actionId: actionId, result: result, now: now())
  }

  func dismiss(conversationId: String, actionId: String, decidedBy: String) throws -> AskAction {
    try store.decideAskAction(
      conversationId: conversationId, actionId: actionId, decision: .dismiss, decidedBy: decidedBy, now: now()
    )
  }

  private func execute(_ target: AskActionTarget) async throws -> AskActionResult {
    switch target {
    case let .sessionStop(sessionId, workflowId):
      return try await mutations.stopSession(sessionId: sessionId, workflowId: workflowId)
    case let .sessionRerun(sessionId, workflowId, stepId):
      return try await mutations.rerunSession(sessionId: sessionId, workflowId: workflowId, stepId: stepId)
    case let .requestAnswer(requestId, optionId):
      return try await mutations.answerBotRequest(requestId: requestId, optionId: optionId, decline: optionId == nil)
    case let .botPause(botId, paused):
      return try await mutations.setBotPaused(botId: botId, paused: paused)
    }
  }

  private func failure(_ error: Error) -> AskActionResult {
    let detail: (code: String, message: String)
    switch error {
    case let error as AskError:
      detail = (error.code, error.message)
    case let error as GraphQLSessionControlError:
      detail = (error.code, error.message)
    case let error as BotStoreError:
      detail = (error.code, error.message)
    default:
      detail = ("action_mutation_failed", String(describing: error))
    }
    return .init(ok: false, code: detail.code, message: AskRedaction.text(detail.message, environment: environment))
  }
}
