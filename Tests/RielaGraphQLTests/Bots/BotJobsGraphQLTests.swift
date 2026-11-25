import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class BotJobsGraphQLTests: XCTestCase {
  func testRootsDecodeInputsAndProjectTypedPayloads() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let operations: [(String, JSONValue)] = [
      (#"{ result: bot(botId: "alpha") { jobs { job schedule lastRun { status } } suggestions { status } } }"#,
        .object([
          "jobs": .array([.object([
            "job": .string("upkeep"), "schedule": .string("nightly"),
            "lastRun": .object(["status": .string("succeeded")])
          ])]),
          "suggestions": .array([.object(["status": .string("accepted")])])
        ])),
      (#"{ result: botSuggestions(botId: "alpha", status: "open", remote: "host") { suggestions { title action { workflowName } } } }"#,
        .object(["suggestions": .array([.object(["title": .string("Inspect"), "action": .object(["workflowName": .string("inspect")])])])])),
      (#"mutation { result: decideBotSuggestion(input: {suggestionId: "sug", decision: "accept", run: true}) { suggestion { status } } }"#,
        .object(["suggestion": .object(["status": .string("started")])])),
      (#"""
      mutation {
        result: decideBotSuggestion(input: {suggestionId: "sug", decision: "dismiss", reason: "later", remote: "host"}) {
          suggestion { status }
        }
      }
      """#, .object(["suggestion": .object(["status": .string("dismissed")])])),
      (#"mutation { result: runBotJob(input: {botId: "alpha", job: "look-around", force: true, remote: "host"}) { job status sessionId } }"#,
        .object(["job": .string("look-around"), "status": .string("succeeded"), "sessionId": .string("session-job")]))
    ]
    for (query, value) in operations {
      let output = await executor.execute(.init(query: query, environment: [:], isLocallyTrusted: true))
      XCTAssertEqual(output.body["data"], .object(["result": value]), "\(output.body)")
    }
    let calls = await provider.calls
    XCTAssertEqual(calls, [
      "detail:alpha:", "suggestions:alpha:open:host", "decide:sug:accept:true::",
      "decide:sug:dismiss:false:later:host", "job:alpha:look-around:true:host"
    ])
  }

  func testUnknownSuggestionDecisionIsRejectedBeforeCallingProvider() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let query = #"mutation { decideBotSuggestion(input: {suggestionId: "sug", decision: "start"}) { suggestion { status } } }"#
    let result = await executor.execute(.init(query: query, environment: [:], isLocallyTrusted: true))
    XCTAssertTrue(String(describing: result.body["errors"]).contains("INVALID_BOT"), "\(result.body)")
    let calls = await provider.calls
    XCTAssertEqual(calls, [])
  }
}

extension RecordingBotsProvider {
  func botSuggestions(botId: String, status: BotSuggestion.Status?, remote: String?) async throws -> BotSuggestionListPayload {
    recordCatalogCall("suggestions:\(botId):\(status?.rawValue ?? ""):\(remote ?? "")")
    return BotSuggestionListPayload(botId: botId, suggestions: [try jobSuggestion(.open)], origin: jobTestOrigin)
  }

  func decideBotSuggestion(input: DecideBotSuggestionInput) async throws -> BotSuggestionPayload {
    recordCatalogCall(
      "decide:\(input.suggestionId):\(input.decision.rawValue):\(input.run == true):\(input.reason ?? ""):\(input.remote ?? "")"
    )
    let status: BotSuggestion.Status = input.decision == .dismiss ? .dismissed : .started
    return BotSuggestionPayload(suggestion: try jobSuggestion(status), origin: jobTestOrigin)
  }

  func runBotJob(input: RunBotJobInput) async throws -> BotJobPayload {
    recordCatalogCall("job:\(input.botId):\(input.job.rawValue):\(input.force == true):\(input.remote ?? "")")
    return BotJobPayload(botId: input.botId, job: input.job, status: .succeeded, sessionId: "session-job", origin: jobTestOrigin)
  }

  func jobSuggestion(_ status: BotSuggestion.Status) throws -> BotSuggestion {
    let encoded = """
      {"suggestionId":"sug","botId":"alpha","title":"Inspect","createdAt":"2026-11-25T00:00:00Z",
       "status":"\(status.rawValue)","action":{"workflowName":"inspect","input":{}}}
      """
    return try JSONDecoder().decode(BotSuggestion.self, from: Data(encoded.utf8))
  }

  func jobTestRun() throws -> BotJobRun {
    let encoded = """
      {"botId":"alpha","job":"upkeep","periodKey":"2026-11-24","status":"succeeded",
       "startedAt":"2026-11-25T00:00:00Z","finishedAt":"2026-11-25T00:01:00Z"}
      """
    return try JSONDecoder().decode(BotJobRun.self, from: Data(encoded.utf8))
  }

  private var jobTestOrigin: BotOrigin {
    .local(serverId: nil, serverName: nil, at: Date(timeIntervalSince1970: 0))
  }
}
