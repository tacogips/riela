import Foundation
import RielaCore

public protocol AskGraphQLProviding: Sendable {
  func askConversations(remote: String?) async throws -> AskConversationListPayload
  func askConversation(conversationId: String, remote: String?) async throws -> AskConversationPayload
  func askActivity(conversationId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?) async throws -> AskActivityPage
  func startAsk(input: StartAskInput) async throws -> AskConversationPayload
  func sendAskMessage(input: SendAskMessageInput) async throws -> AskConversationPayload
  func cancelAsk(input: AskConversationInput) async throws -> AskConversationPayload
  func confirmAskAction(input: AskActionInput) async throws -> AskConversationPayload
  func dismissAskAction(input: AskActionInput) async throws -> AskConversationPayload
  func removeAskConversation(input: AskConversationInput) async throws -> AskConversationListPayload
}

public struct AskGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public static let queryFields: Set<String> = ["askConversations", "askConversation", "askActivity"]
  public static let mutationFields: Set<String> = [
    "startAsk", "sendAskMessage", "cancelAsk", "confirmAskAction", "dismissAskAction", "removeAskConversation"
  ]

  public let provider: any AskGraphQLProviding
  public let next: (any GraphQLDocumentExecuting)?

  public init(provider: any AskGraphQLProviding, next: (any GraphQLDocumentExecuting)? = nil) {
    self.provider = provider
    self.next = next
  }

  public static func supports(_ field: String) -> Bool {
    queryFields.contains(field) || mutationFields.contains(field)
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var completed: JSONObject = [:]
    do {
      let roots = try roots(for: request)
      let owned = roots.filter { Self.supports($0.fieldName) }
      guard !owned.isEmpty else { return await next?.execute(request) ?? .notHandled }
      try validateUniqueGraphQLRootResponseKeys(roots)
      if let rejection = await preflight(request, rootFields: roots) { return rejection }
      for root in roots {
        if Self.supports(root.fieldName) {
          completed[root.responseKey] = try await execute(root)
        } else {
          var forwarded = request
          forwarded.parsedRootFields = [root]
          let response = await next?.execute(forwarded) ?? .notHandled
          if let errors = response.body["errors"] {
            return GraphQLDocumentExecutionResponse(
              handled: true, body: ["data": completed.isEmpty ? .null : .object(completed), "errors": errors]
            )
          }
          guard case let .object(data)? = response.body["data"], response.handled else {
            throw BotStoreError(code: "INVALID_ASK", message: "Unsupported GraphQL root field")
          }
          completed.merge(data) { _, latest in latest }
        }
      }
      return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(completed)])
    } catch let error as AskError {
      return failure(BotStoreError(code: error.code, message: error.message), completed: completed)
    } catch let error as BotStoreError {
      return failure(error, completed: completed)
    } catch {
      return failure(BotStoreError(code: "ask_io_failure", message: "Ask operation failed"), completed: completed)
    }
  }

  private func roots(for request: GraphQLDocumentRequest) throws -> [ParsedGraphQLRootField] {
    if let roots = request.parsedRootFields { return roots }
    do {
      let operations = try parseGraphQLOperations(
        in: request.query, operationName: request.operationName, variables: request.variables, parseArguments: true
      )
      return try selectGraphQLOperation(operations, operationName: request.operationName)?.rootFields ?? []
    } catch {
      throw BotStoreError(code: "INVALID_ASK", message: "Invalid GraphQL document")
    }
  }

  private func execute(_ root: ParsedGraphQLRootField) async throws -> JSONValue {
    let value: JSONValue
    switch try decode(root) {
    case let .list(remote):
      value = try await BotSurfaceJSON.value(provider.askConversations(remote: remote))
    case let .conversation(id, remote):
      value = try await BotSurfaceJSON.value(provider.askConversation(conversationId: id, remote: remote))
    case let .activity(id, after, limit, wait, remote):
      value = try await BotSurfaceJSON.value(provider.askActivity(
        conversationId: id, afterSequence: after, limit: limit, waitMs: wait, remote: remote
      ))
    case let .start(input): value = try await BotSurfaceJSON.value(provider.startAsk(input: input))
    case let .send(input): value = try await BotSurfaceJSON.value(provider.sendAskMessage(input: input))
    case let .cancel(input): value = try await BotSurfaceJSON.value(provider.cancelAsk(input: input))
    case let .confirm(input): value = try await BotSurfaceJSON.value(provider.confirmAskAction(input: input))
    case let .dismiss(input): value = try await BotSurfaceJSON.value(provider.dismissAskAction(input: input))
    case let .remove(input): value = try await BotSurfaceJSON.value(provider.removeAskConversation(input: input))
    }
    return projectGraphQLValue(value, selections: root.selections)
  }

  private enum Operation {
    case list(String?)
    case conversation(String, String?)
    case activity(String, Int, Int, Int, String?)
    case start(StartAskInput)
    case send(SendAskMessageInput)
    case cancel(AskConversationInput)
    case confirm(AskActionInput)
    case dismiss(AskActionInput)
    case remove(AskConversationInput)
  }

  private func decode(_ root: ParsedGraphQLRootField) throws -> Operation {
    let invalid = BotStoreError(code: "INVALID_ASK", message: "Invalid arguments for '\(root.fieldName)'")
    func input<T: Decodable>(_ type: T.Type, at key: String = "input") throws -> T {
      guard let value = root.arguments[key],
            let decoded = try? JSONDecoder().decode(type, from: JSONEncoder().encode(value)) else { throw invalid }
      return decoded
    }
    func optional<T: Decodable>(_ type: T.Type, at key: String) throws -> T? {
      guard let value = root.arguments[key], value != .null else { return nil }
      return try input(type, at: key)
    }

    switch root.fieldName {
    case "askConversations": return .list(try optional(String.self, at: "remote"))
    case "askConversation":
      return .conversation(try input(String.self, at: "conversationId"), try optional(String.self, at: "remote"))
    case "askActivity":
      let limit = try optional(Int.self, at: "limit") ?? BotActivityPage.defaultLimit
      let wait = try optional(Int.self, at: "waitMs") ?? 0
      return .activity(
        try input(String.self, at: "conversationId"), max(0, try optional(Int.self, at: "afterSequence") ?? 0),
        min(BotActivityPage.maximumLimit, max(1, limit)),
        min(BotActivityPage.maximumWaitMs, max(0, wait)), try optional(String.self, at: "remote")
      )
    case "startAsk": return .start(try input(StartAskInput.self))
    case "sendAskMessage": return .send(try input(SendAskMessageInput.self))
    case "cancelAsk": return .cancel(try input(AskConversationInput.self))
    case "confirmAskAction": return .confirm(try input(AskActionInput.self))
    case "dismissAskAction": return .dismiss(try input(AskActionInput.self))
    case "removeAskConversation": return .remove(try input(AskConversationInput.self))
    default: throw invalid
    }
  }

  private func failure(_ error: BotStoreError, completed: JSONObject = [:]) -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(handled: true, body: [
      "data": completed.isEmpty ? .null : .object(completed),
      "errors": .array([.object(["message": .string(error.message), "extensions": .object(["code": .string(error.code)])])])
    ])
  }
}

extension AskGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let owned = rootFields.filter { Self.supports($0.fieldName) }
    let forwarded = rootFields.filter { !Self.supports($0.fieldName) }
    if !owned.isEmpty, !request.isLocallyTrusted {
      return failure(BotStoreError(code: "ASK_UNAVAILABLE", message: "Ask GraphQL requires a locally trusted host"))
    }
    for root in owned {
      let expected: GraphQLDocumentOperationType = Self.queryFields.contains(root.fieldName) ? .query : .mutation
      guard root.operationType == expected, (try? decode(root)) != nil else {
        return failure(BotStoreError(code: "INVALID_ASK", message: "Invalid Ask field '\(root.fieldName)'"))
      }
    }
    guard !forwarded.isEmpty else { return nil }
    guard let next = next as? any GraphQLDocumentDomainPreflighting else {
      return failure(BotStoreError(code: "INVALID_ASK", message: "GraphQL fallback does not support preflight"))
    }
    return await next.preflight(request, rootFields: forwarded)
  }
}
