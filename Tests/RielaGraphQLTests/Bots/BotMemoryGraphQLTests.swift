import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class BotMemoryGraphQLTests: XCTestCase {
  func testReadsAndMutationsDecodeTypedInputsAndProjectAuditPayloads() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let operations: [(String, JSONValue)] = [
      (#"{ result: botMemory(botId: "alpha", remote: "host") { botId markdown instructionCount noteCount changes { changeId } } }"#,
        .object([
          "botId": .string("alpha"), "markdown": .string("## Instructions"), "instructionCount": .integer(1), "noteCount": .integer(0),
          "changes": .array([.object(["changeId": .string("change")])])
        ])),
      (#"mutation { result: updateBotMemory(input: {botId: "alpha", markdown: "- new", reason: "edit"}) { change { actor } } }"#,
        .object(["change": .object(["actor": .string("api")])])),
      (#"mutation { result: undoBotMemoryChange(input: {botId: "alpha", changeId: "change"}) { change { changeId } } }"#,
        .object(["change": .object(["changeId": .string("change")])])),
      (#"mutation { result: captureBotFeedback(input: {botId: "alpha", sessionId: "s1", fromFindings: true}) { change { entries { op } } } }"#,
        .object(["change": .object(["entries": .array([.object(["op": .string("add")])])])]))
    ]
    for (query, value) in operations {
      let response = await executor.execute(.init(query: query, environment: [:], isLocallyTrusted: true))
      XCTAssertEqual(response.body["data"], .object(["result": value]), "\(response.body)")
    }
    let calls = await provider.calls
    XCTAssertEqual(calls, ["memory:alpha:host", "edit:alpha:- new:edit", "undo:alpha:change", "feedback:alpha:s1:true"])
  }
}

extension RecordingBotsProvider {
  func botMemory(botId: String, remote: String?) async throws -> BotMemoryPayload {
    recordCatalogCall("memory:\(botId):\(remote ?? "")")
    return BotMemoryPayload(
      botId: botId, markdown: "## Instructions", summary: .init(instructionCount: 1),
      changes: [try memoryChange().change], origin: memoryOrigin
    )
  }

  func updateBotMemory(input: UpdateBotMemoryInput) async throws -> BotMemoryChangePayload {
    recordCatalogCall("edit:\(input.botId):\(input.markdown):\(input.reason ?? "")")
    return try memoryChange()
  }

  func undoBotMemoryChange(input: UndoBotMemoryChangeInput) async throws -> BotMemoryChangePayload {
    recordCatalogCall("undo:\(input.botId):\(input.changeId ?? "")")
    return try memoryChange()
  }

  func captureBotFeedback(input: CaptureBotFeedbackInput) async throws -> BotMemoryChangePayload {
    recordCatalogCall("feedback:\(input.botId):\(input.sessionId ?? ""):\(input.fromFindings == true)")
    return try memoryChange()
  }

  private var memoryOrigin: BotOrigin { .local(serverId: nil, serverName: nil, at: Date(timeIntervalSince1970: 0)) }

  private func memoryChange() throws -> BotMemoryChangePayload {
    let encoded = """
      {"changeId":"change","botId":"alpha","actor":"api","reason":"edit","evidenceRefs":[],
       "createdAt":"2026-11-25T00:00:00Z","entries":[{"recordId":1,"op":"add","toVersion":1}],
       "redacted":false,"downgraded":false,"ignoredInstructionChanges":0}
      """
    return BotMemoryChangePayload(change: try JSONDecoder().decode(BotMemoryChangeSet.self, from: Data(encoded.utf8)), origin: memoryOrigin)
  }
}
