import RielaCore
import RielaGraphQL

protocol AskMutationSurface: Sendable {
  func stopSession(sessionId: String, workflowId: String) async throws -> AskActionResult
  func rerunSession(sessionId: String, workflowId: String, stepId: String) async throws -> AskActionResult
  func answerBotRequest(requestId: String, optionId: String?, decline: Bool) async throws -> AskActionResult
  func setBotPaused(botId: String, paused: Bool) async throws -> AskActionResult
}

struct ProviderAskMutationSurface: AskMutationSurface {
  let sessions: any GraphQLSessionControlProviding
  let bots: any BotsGraphQLProviding

  func stopSession(sessionId: String, workflowId: String) async throws -> AskActionResult {
    let payload = try await sessions.stopSession(.init(workflowId: workflowId, sessionId: sessionId))
    return sessionResult(payload, summary: "Session stopped")
  }

  func rerunSession(sessionId: String, workflowId: String, stepId: String) async throws -> AskActionResult {
    let payload = try await sessions.rerunSession(.init(workflowId: workflowId, sessionId: sessionId, stepId: stepId))
    return sessionResult(payload, summary: "Session rerun")
  }

  func answerBotRequest(requestId: String, optionId: String?, decline: Bool) async throws -> AskActionResult {
    let payload = try await bots.answerBotRequest(input: .init(
      requestId: requestId, optionId: optionId, decline: decline, remote: "local"
    ))
    return .init(ok: true, summary: decline ? "Permission declined" : "Permission answered", ids: [payload.requestId])
  }

  func setBotPaused(botId: String, paused: Bool) async throws -> AskActionResult {
    let payload = try await bots.setBotPaused(input: .init(botId: botId, paused: paused, remote: "local"))
    return .init(ok: true, summary: payload.bot.paused ? "Bot paused" : "Bot resumed", ids: [payload.bot.botId])
  }

  private func sessionResult(_ payload: GraphQLSessionMutationPayload, summary: String) -> AskActionResult {
    let ids = payload.sessionId.map { [$0] } ?? []
    guard payload.result.accepted else {
      return .init(
        ok: false, ids: ids, code: payload.result.status,
        message: payload.result.diagnostics.first ?? "Session control failed"
      )
    }
    return .init(ok: true, summary: summary, ids: ids)
  }
}
