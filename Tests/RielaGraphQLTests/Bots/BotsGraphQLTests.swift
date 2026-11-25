import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class BotsGraphQLTests: XCTestCase {
  func testEachRootDecodesInputAndProjectsItsPayload() async throws {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let operations = [
      ("{ result: bots(filter: {groupBy: \"workspace\"}) { groups } }", JSONValue.object(["groups": .array([])])),
      ("{ result: bot(botId: \"alpha\", remote: \"local\") { bot { botId } memory } }",
        .object(["bot": .object(["botId": .string("alpha")]), "memory": .null])),
      ("mutation { result: createBot(input: {name: \"Alpha\"}) { bot { name } } }", .object(["bot": .object(["name": .string("Alpha")])])),
      ("mutation { result: updateBot(input: {botId: \"alpha\", name: \"New\"}) { bot { name } } }", .object(["bot": .object(["name": .string("New")])])),
      ("mutation { result: setBotPaused(input: {botId: \"alpha\", paused: true}) { bot { paused } } }", .object(["bot": .object(["paused": .bool(true)])])),
      ("mutation { result: removeBot(input: {botId: \"alpha\"}) { bot { botId } } }", .object(["bot": .object(["botId": .string("alpha")])])),
      ("mutation { result: setBotListState(input: {botId: \"alpha\", manualOrder: 3}) { bot { botId } } }",
        .object(["bot": .object(["botId": .string("alpha")])]))
    ]
    for (query, value) in operations {
      let result = await executor.execute(request(query))
      XCTAssertEqual(result.body["data"], .object(["result": value]), "\(result.body)")
    }
    let calls = await provider.calls
    XCTAssertEqual(calls, ["list:workspace", "detail:alpha:local", "create:Alpha", "update:alpha:New", "pause:alpha:true", "remove:alpha", "state:alpha:3"])
  }

  func testTrustAndMutationOperationValidationPrecedeProviderCalls() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let denied = await executor.execute(request("{ bots { groups } }", trusted: false))
    XCTAssertTrue(String(describing: denied.body["errors"]).contains("BOTS_UNAVAILABLE"), "\(denied.body)")
    let invalid = await executor.execute(request("{ createBot(input: {name: \"Alpha\"}) { bot { botId } } }"))
    XCTAssertTrue(String(describing: invalid.body["errors"]).contains("INVALID_BOT"), "\(invalid.body)")
    let calls = await provider.calls
    XCTAssertEqual(calls, [])
  }

  func testUnknownFieldFallsThroughAndStoreErrorCodeIsPreserved() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider, next: OtherBotTestExecutor())
    let response = await executor.execute(request("{ example }"))
    XCTAssertEqual(response.body["data"], .object(["example": .bool(true)]))
    let missing = await executor.execute(request("{ bot(botId: \"missing\") { bot { botId } } }"))
    XCTAssertTrue(String(describing: missing.body["errors"]).contains("bot_not_found"), "\(missing.body)")
  }

  private func request(_ query: String, trusted: Bool = true) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(query: query, environment: [:], isLocallyTrusted: trusted)
  }
}

private struct OtherBotTestExecutor: GraphQLDocumentExecuting {
  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(["example": .bool(true)])])
  }
}

actor RecordingBotsProvider: BotsGraphQLProviding {
  private(set) var calls: [String] = []

  func recordCatalogCall(_ call: String) { calls.append(call) }
  private let activityError: BotStoreError?

  init(activityError: BotStoreError? = nil) {
    self.activityError = activityError
  }

  private func record(id: String = "alpha", name: String = "Alpha", paused: Bool = false) -> GraphQLBot {
    GraphQLBot(botId: id, name: name, paused: paused, createdAt: "now", updatedAt: "now")
  }

  func bots(filter: BotFilter?) async throws -> BotListPayload {
    calls.append("list:\(filter?.groupBy?.rawValue ?? "")")
    return BotListPayload(bots: [], groups: [])
  }

  func bot(botId: String, remote: String?) async throws -> BotDetailPayload {
    calls.append("detail:\(botId):\(remote ?? "")")
    guard botId != "missing" else { throw BotStoreError(code: "bot_not_found", message: "Missing bot") }
    let bot = record(id: botId)
    let instant = Date(timeIntervalSince1970: 0)
    let origin = BotOrigin.local(serverId: nil, serverName: nil, at: instant)
    let input = BotBoardInput(bot: bot, now: instant, origin: origin, redact: { $0 })
    return BotDetailPayload(bot: bot, board: GraphQLBotBoard(BotBoardProjector.board(input)), routines: [], origin: origin)
  }

  func botActivity(sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?) async throws -> BotActivityPage {
    calls.append("activity:\(sessionId):\(afterSequence):\(limit):\(waitMs):\(remote ?? "")")
    if let activityError { throw activityError }
    let instant = Date(timeIntervalSince1970: 0)
    let event = ActivityEvent(
      sessionId: sessionId, seq: 7, executionId: "execution", at: instant,
      kind: .message, payload: ["text": .string("hello")]
    )
    var state = ActivityState()
    state.source = "acp"
    state.usage = ["used": .integer(3)]
    state.configOptions = [["id": .string("model")]]
    return BotActivityPage(
      events: [event], state: state, lastSequence: 7, firstRetainedSequence: 7, truncated: true,
      activitySource: "acp", sessionStatus: "running", origin: .local(serverId: nil, serverName: nil, at: instant)
    )
  }

  func createBot(input: CreateBotInput) async throws -> BotMutationPayload {
    calls.append("create:\(input.name ?? "")")
    return BotMutationPayload(bot: record(name: input.name ?? ""))
  }

  func updateBot(input: UpdateBotInput) async throws -> BotMutationPayload {
    calls.append("update:\(input.botId ?? ""):\(input.name ?? "")")
    return BotMutationPayload(bot: record(name: input.name ?? ""))
  }

  func setBotPaused(input: SetBotPausedInput) async throws -> BotMutationPayload {
    calls.append("pause:\(input.botId):\(input.paused)")
    return BotMutationPayload(bot: record(paused: input.paused))
  }

  func removeBot(input: RemoveBotInput) async throws -> BotMutationPayload {
    calls.append("remove:\(input.botId)")
    return BotMutationPayload(bot: record(id: input.botId))
  }

  func setBotListState(input: SetBotListStateInput) async throws -> BotMutationPayload {
    calls.append("state:\(input.botId):\(input.manualOrder ?? -1)")
    return BotMutationPayload(bot: record(id: input.botId))
  }

  func answerBotRequest(input: AnswerBotRequestInput) async throws -> BotRequestPayload {
    calls.append("answer:\(input.requestId):\(input.optionId ?? ""):\(input.decline == true):\(input.remote ?? "")")
    return BotRequestPayload(requestId: input.requestId, status: .answered, outcomeOptionId: input.optionId, resolvedBy: .user)
  }
}
