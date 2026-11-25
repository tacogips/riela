import Foundation
import RielaCore
import RielaGraphQL

extension AskCommands {
  func follow(
    _ started: AskConversationPayload, output: WorkflowOutputFormat, selector: String,
    provider: AskGraphQLProvider, ownsLocalTurn: Bool
  ) async throws -> CLICommandResult {
    let id = started.conversation.conversationId
    var cursor = 0
    var content = ""
    var wroteAnswer = false
    do {
      while true {
        let page = try await provider.askActivity(
          conversationId: id, afterSequence: cursor, limit: BotActivityPage.defaultLimit, waitMs: 1_000, remote: selector
        )
        if output == .text {
          for event in page.events where event.executionId == started.conversation.turn?.turnId {
            guard let line = line(for: event, context: started.conversation.context) else { continue }
            wroteAnswer = wroteAnswer || event.kind == .message
            if let writer { writer(line) } else { content += line }
          }
        }
        cursor = page.lastSequence
        if page.turnStatus != AskTurnStatus.running.rawValue, page.state?.currentExecutionId == nil,
           page.events.count < BotActivityPage.defaultLimit { break }
        if page.events.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
      }
    } catch {
      if ownsLocalTurn {
        _ = try? await provider.service.cancel(conversationId: id)
        await provider.service.waitForTurn(conversationId: id)
      }
      throw error
    }
    if ownsLocalTurn { await provider.service.waitForTurn(conversationId: id) }
    let snapshot = try await provider.askConversation(conversationId: id, remote: selector)
    return try render(
      snapshot, output: output, content: wroteAnswer ? content : content + answer(in: snapshot),
      warnings: started.warnings, turnExit: true
    )
  }

  func renderList(_ payload: AskConversationListPayload, output: WorkflowOutputFormat) throws -> CLICommandResult {
    let suffix = remoteHostText(payload.origin)
    let text = payload.conversations.map { "\($0.conversationId)  \($0.title)\(suffix)\n" }.joined()
    return CLICommandResult(exitCode: .success, stdout: output == .json ? try jsonString(payload) : text)
  }

  func render(
    _ payload: AskConversationPayload, output: WorkflowOutputFormat, content: String? = nil,
    warnings: [String]? = nil, turnExit: Bool = false
  ) throws -> CLICommandResult {
    let warnings = warnings ?? payload.warnings
    let turn = payload.conversation.turn
    let issue = turnExit ? turn?.error : nil
    let stderr = (output == .text ? warnings : []) + (issue.map { ["\($0.code): \($0.message)"] } ?? [])
    let text: String
    if output == .json {
      text = try jsonString(AskConversationPayload(
        conversation: payload.conversation, messages: payload.messages, actions: payload.actions,
        limits: payload.limits, warnings: warnings, origin: payload.origin
      ))
    } else {
      text = (content ?? answer(in: payload)) + details(payload)
    }
    let failed = turnExit && (turn?.status == .failed || turn?.status == .cancelled)
    return CLICommandResult(exitCode: failed ? .failure : .success, stdout: text, stderr: stderr.joined(separator: "\n"))
  }

  private func answer(in payload: AskConversationPayload) -> String {
    guard let message = payload.messages.last(where: {
      $0.role == .assistant && $0.turnId == payload.conversation.turn?.turnId
    }) else { return "" }
    return message.text + "\n"
  }

  private func details(_ payload: AskConversationPayload) -> String {
    var lines: [String] = []
    let refs = payload.messages.last(where: {
      $0.role == .assistant && $0.turnId == payload.conversation.turn?.turnId
    })?.citations ?? []
    if !refs.isEmpty {
      lines.append("Records:")
      lines += refs.map { "  \($0.kind.rawValue):\($0.id)" }
    }
    let proposed = payload.actions.filter { $0.status == .proposed }
    if !proposed.isEmpty {
      lines.append("Proposed:")
      lines += proposed.map { action in
        let target = (try? jsonString(action.target))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "  \(action.actionId) \(action.kind.rawValue) \(target)"
      }
    }
    lines.append("conversation \(payload.conversation.conversationId)" + remoteHostText(payload.origin))
    return lines.joined(separator: "\n") + "\n"
  }

  private func line(for event: ActivityEvent, context: AskContext) -> String? {
    switch event.kind {
    case .message:
      guard case let .string(text)? = event.payload["text"], !text.isEmpty else { return nil }
      return text.hasSuffix("\n") ? text : text + "\n"
    case .toolCall:
      guard case let .string(name)? = event.payload["title"],
            event.payload["status"] == .string("inProgress") else { return nil }
      let hint = context.id.map { " \($0)" } ?? ""
      return "· \(name)\(hint)\n"
    default:
      return nil
    }
  }
}
