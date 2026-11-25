import Foundation
import RielaCore
import RielaGraphQL

struct RemoteAskProvider: Sendable {
  let client: RemoteGraphQLClient
  let registry: RemoteRegistry
  var now: @Sendable () -> Date = Date.init

  func list() async throws -> AskConversationListPayload {
    try await execute("Query.askConversations")
  }

  func conversation(_ id: String) async throws -> AskConversationPayload {
    try await execute("Query.askConversation", arguments: ["conversationId": .string(id)])
  }

  func activity(_ id: String, afterSequence: Int, limit: Int, waitMs: Int) async throws -> AskActivityPage {
    try await execute("Query.askActivity", arguments: [
      "conversationId": .string(id), "afterSequence": .number(Double(afterSequence)),
      "limit": .number(Double(limit)), "waitMs": .number(Double(waitMs))
    ])
  }

  func mutate<Input: Encodable, Output: Decodable>(_ name: String, input: Input) async throws -> Output {
    try await execute("Mutation.\(name)", arguments: ["input": try RemoteBotsProvider.inputValue(input)])
  }

  private func execute<Output: Decodable>(_ root: String, arguments: JSONObject = [:]) async throws -> Output {
    let document = try GraphQLSelectionBuilder.document(for: root, arguments: Set(arguments.keys))
    let data = try await client.execute(query: document.query, variables: arguments)
    let record = client.record
    let observedAt = now()
    let invalid = BotStoreError(code: "remote_invalid_response", message: "The remote returned an invalid Ask payload")
    guard let value = data[document.field.name] else { throw invalid }
    let verified = RemoteOriginProjection(record: record, observedAt: observedAt).rewrite(value, type: document.field.type)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let payload = try? decoder.decode(Output.self, from: JSONEncoder().encode(verified)) else { throw invalid }
    try? registry.touchLastSeen(name: record.name, at: observedAt, grantId: record.grantId)
    return payload
  }
}
