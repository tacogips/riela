import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class GraphQLSelectionBuilderTests: XCTestCase {
  func testNestedSelectionsAndJSONLeavesFollowTheDescriptors() {
    let detail = GraphQLSelectionBuilder.selection(forType: "BotDetailPayload!")
    XCTAssertTrue(detail.contains("board { needsYou { itemKind itemId"))
    XCTAssertTrue(detail.contains("planned { itemKind itemId"))
    XCTAssertTrue(detail.contains("action { workflowName input }"))
    XCTAssertTrue(detail.contains("origin { remote serverId"))
    XCTAssertFalse(detail.contains("{ }"))
    XCTAssertEqual(GraphQLSelectionBuilder.selection(forType: "JSON!"), "")
  }

  func testGeneratedDocumentsExecuteForEveryBotsRoot() async throws {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let roots = BotsGraphQLDocumentExecutor.queryFields.map { "Query.\($0)" }
      + BotsGraphQLDocumentExecutor.mutationFields.map { "Mutation.\($0)" }
    let variables = fixtures()
    XCTAssertTrue(Set(variables.keys).isSubset(of: Set(roots)))
    for root in roots.sorted() {
      let values = variables[root] ?? [:]
      let document = try GraphQLSelectionBuilder.document(for: root, arguments: Set(values.keys))
      let response = await executor.execute(.init(query: document.query, variables: values, isLocallyTrusted: true))
      XCTAssertTrue(response.handled, root)
      XCTAssertNil(response.body["errors"], "\(root): \(response.body)")
      guard case let .object(data)? = response.body["data"] else {
        XCTFail("\(root) produced no data")
        continue
      }
      XCTAssertNotNil(data[document.field.name], root)
    }
  }

  private func fixtures() -> [String: JSONObject] {
    let bot: JSONValue = .string("alpha")
    let provider: JSONValue = .string("work/codex")
    let change: JSONValue = .string("change")
    return [
      "Query.bot": ["botId": bot],
      "Query.botActivity": ["sessionId": .string("session")],
      "Query.botMemory": ["botId": bot],
      "Query.botSuggestions": ["botId": bot],
      "Query.botJobHistory": ["botId": bot],
      "Query.botMemoryHistory": ["botId": bot],
      "Query.botMemoryDiff": ["botId": bot, "changeId": change],
      "Query.modelCatalog": ["providerInstanceId": provider],
      "Query.provider": ["instanceId": provider],
      "Mutation.createBot": input(["name": .string("Alpha")]),
      "Mutation.updateBot": input(["botId": bot, "name": .string("New")]),
      "Mutation.setBotPaused": input(["botId": bot, "paused": .bool(true)]),
      "Mutation.removeBot": input(["botId": bot]),
      "Mutation.setBotListState": input(["botId": bot, "pinned": .bool(true)]),
      "Mutation.answerBotRequest": input(["requestId": .string("request"), "optionId": .string("allow-1")]),
      "Mutation.refreshProviders": input([:]),
      "Mutation.saveProviderInstance": input(["instanceId": provider]),
      "Mutation.removeProviderInstance": input(["instanceId": provider]),
      "Mutation.updateBotMemory": input(["botId": bot, "markdown": .string("- note")]),
      "Mutation.undoBotMemoryChange": input(["botId": bot, "changeId": change]),
      "Mutation.captureBotFeedback": input(["botId": bot, "sessionId": .string("session"), "fromFindings": .bool(true)]),
      "Mutation.decideBotSuggestion": input(["suggestionId": .string("suggestion"), "decision": .string("accept")]),
      "Mutation.runBotJob": input(["botId": bot, "job": .string("look-around")]),
      "Mutation.mintPairingCode": input(["address": .string("https://riela.example")]),
      "Mutation.revokePairingGrant": input(["grantId": .string("grant")]),
      "Mutation.addRemote": input(["name": .string("srv"), "code": .string("fixture-code")]),
      "Mutation.removeRemote": input(["name": .string("srv")]),
      "Mutation.useRemote": input(["name": .string("srv")])
    ]
  }

  private func input(_ arguments: JSONObject) -> JSONObject { ["input": .object(arguments)] }
}

extension RecordingBotsProvider {
  func botJobHistory(botId: String, job: BotJobKind?, limit: Int, remote: String?) async throws -> BotJobHistoryPayload {
    .init(runs: [], origin: fixtureOrigin)
  }

  func botMemoryHistory(botId: String, limit: Int, remote: String?) async throws -> BotMemoryHistoryPayload {
    .init(changes: [], origin: fixtureOrigin)
  }

  func botMemoryDiff(botId: String, changeId: String, remote: String?) async throws -> BotMemoryDiffPayload {
    .init(diffs: [], origin: fixtureOrigin)
  }

  private var fixtureOrigin: BotOrigin {
    .local(serverId: nil, serverName: nil, at: Date(timeIntervalSince1970: 0))
  }
}
