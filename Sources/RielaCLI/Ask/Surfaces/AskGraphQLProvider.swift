import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

enum AskRequestIdentity {
  @TaskLocal static var decidedBy: String?
}

struct AskGraphQLProvider: AskGraphQLProviding {
  let service: AskService
  let registry: RemoteRegistry
  var transport: RemoteHTTP.Transport = RemoteHTTP.production
  var origin: @Sendable () -> BotOrigin = { .local(serverId: nil, serverName: nil, at: Date()) }
  var isStillAuthorized: @Sendable () async -> Bool = { true }

  func remoteProvider(_ selector: String?) throws -> RemoteAskProvider? {
    switch try RemoteRouting.resolve(remote: selector, registry: registry) {
    case .local: return nil
    case let .remote(record, token):
      return RemoteAskProvider(
        client: RemoteGraphQLClient(record: record, token: token, transport: transport), registry: registry
      )
    case .all:
      throw BotStoreError(code: "remote_selector_invalid", message: "Select one remote for Ask Riela")
    }
  }

  func askConversations(remote: String?) async throws -> AskConversationListPayload {
    if let remote = try remoteProvider(remote) { return try await remote.list() }
    return try .init(conversations: service.conversations(), origin: origin())
  }

  func askConversation(conversationId: String, remote: String?) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(remote) { return try await remote.conversation(conversationId) }
    return try payload(service.conversation(id: conversationId))
  }

  func askActivity(conversationId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?) async throws -> AskActivityPage {
    if let remote = try remoteProvider(remote) {
      let page = try await remote.activity(conversationId, afterSequence: afterSequence, limit: limit, waitMs: waitMs)
      guard await activityIsAuthorized() else {
        throw AskError(code: "UNAUTHENTICATED", message: "The activity grant is no longer valid")
      }
      return page
    }
    do {
      let read = try await service.activity(
        conversationId: conversationId, afterSequence: afterSequence, limit: limit, waitMs: waitMs,
        isStillAuthorized: { await activityIsAuthorized() }
      )
      let page = read.page
      return AskActivityPage(
        events: page.events, state: page.state, lastSequence: page.lastSequence, firstRetainedSequence: page.firstRetainedSequence,
        truncated: page.truncated, activitySource: page.activitySource,
        turnStatus: read.turnStatus?.rawValue ?? "unknown", origin: origin()
      )
    } catch let error as AskError where error.code == "activity_wait_revoked" {
      throw AskError(code: "UNAUTHENTICATED", message: error.message)
    }
  }

  func startAsk(input: StartAskInput) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("startAsk", input: input) }
    return try await payload(service.send(.init(
      message: input.message, context: input.context, selection: input.selection, draftDefinition: input.draftDefinition
    )))
  }

  func sendAskMessage(input: SendAskMessageInput) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("sendAskMessage", input: input) }
    return try await payload(service.send(.init(
      conversationId: input.conversationId, message: input.message, context: input.context, draftDefinition: input.draftDefinition
    )))
  }

  func cancelAsk(input: AskConversationInput) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("cancelAsk", input: input) }
    return try await payload(service.cancel(conversationId: input.conversationId))
  }

  func confirmAskAction(input: AskActionInput) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("confirmAskAction", input: input) }
    return try await payload(service.confirm(
      conversationId: input.conversationId, actionId: input.actionId, decidedBy: AskRequestIdentity.decidedBy ?? "local"
    ))
  }

  func dismissAskAction(input: AskActionInput) async throws -> AskConversationPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("dismissAskAction", input: input) }
    return try payload(service.dismiss(
      conversationId: input.conversationId, actionId: input.actionId, decidedBy: AskRequestIdentity.decidedBy ?? "local"
    ))
  }

  func removeAskConversation(input: AskConversationInput) async throws -> AskConversationListPayload {
    if let remote = try remoteProvider(input.remote) { return try await remote.mutate("removeAskConversation", input: input) }
    try service.remove(conversationId: input.conversationId)
    return try .init(conversations: service.conversations(), origin: origin())
  }

  func payload(_ snapshot: AskConversationSnapshot) -> AskConversationPayload {
    .init(
      conversation: snapshot.conversation, messages: snapshot.messages, actions: snapshot.actions,
      limits: snapshot.limits, warnings: snapshot.warnings, origin: origin()
    )
  }

  private func activityIsAuthorized() async -> Bool {
    guard BotsRequestGrant.current?.isStillValid() ?? true else { return false }
    return await isStillAuthorized()
  }
}
