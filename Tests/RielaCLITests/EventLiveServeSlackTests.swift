import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeSlackTests: XCTestCase {
  func testSlackGatewayServePollsRunsWorkflowAndSendsThreadReply() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let api = FakeSlackGatewayAPI(messages: [
      try SlackMessage.fixture(ts: "1780000000.000100", text: "Riela, can you answer from Slack?")
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "Slackから受け取ったよ。短く返します。", replyAs: "riela")
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: FakeDiscordGatewayAPI(messages: []),
      slackAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_SLACK_TOKEN": "source-token",
      "TEST_SLACK_BOT_USER_ID": "U999",
      "TEST_SLACK_RIELA_TOKEN": "riela-token",
      "TEST_SLACK_YUI_TOKEN": "yui-token",
      "TEST_SLACK_MIKA_TOKEN": "mika-token",
      "TEST_SLACK_RINA_TOKEN": "rina-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions([
          "--workflow-definition-dir", eventRoot.deletingLastPathComponent().path,
          "--limit", "1"
        ]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["slack-flow"])
    XCTAssertEqual(workflowRequests.first?.runtimeVariables["humanInput"], .object([
      "request": .string("Riela, can you answer from Slack?"),
      "conversationId": .string("C200"),
      "threadId": .string("1780000000.000100")
    ]))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages, [
      SlackSendMessageRequest(
        token: "riela-token",
        channelId: "C200",
        threadTimestamp: "1780000000.000100",
        text: "Slackから受け取ったよ。短く返します。"
      )
    ])
    let offsetText = try String(
      contentsOf: eventRoot.appendingPathComponent("slack/slack-live-C200-offset.json"),
      encoding: .utf8
    )
    XCTAssertTrue(offsetText.contains(#""lastTimestamp" : "1780000000.000100""#))
  }

  func testSlackGatewayServeIgnoresConfiguredBotSelfMessages() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let api = FakeSlackGatewayAPI(messages: [
      try SlackMessage.fixture(ts: "1780000000.000200", user: "U999", text: "self")
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "ignored", replyAs: "riela")
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: FakeDiscordGatewayAPI(messages: []),
      slackAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_SLACK_TOKEN": "source-token",
      "TEST_SLACK_BOT_USER_ID": "U999",
      "TEST_SLACK_RIELA_TOKEN": "riela-token",
      "TEST_SLACK_YUI_TOKEN": "yui-token",
      "TEST_SLACK_MIKA_TOKEN": "mika-token",
      "TEST_SLACK_RINA_TOKEN": "rina-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    let workflowRequests = await workflowRunner.requests
    let sentMessages = await api.sentMessages
    XCTAssertEqual(workflowRequests.count, 0)
    XCTAssertEqual(sentMessages, [])
  }

  func testSlackGatewayServeIncludesPersistedConversationHistory() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let api = FakeSlackGatewayAPI(messages: [
      try SlackMessage.fixture(ts: "1780000000.000300", text: "First Slack message"),
      try SlackMessage.fixture(
        ts: "1780000000.000400",
        text: "What did I just ask?",
        threadTimestamp: "1780000000.000300"
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(
      replies: [
        "最初のSlackメッセージを受け取りました。",
        "さっきは最初のSlackメッセージについて聞いていました。"
      ],
      replyAs: "riela"
    )
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: FakeDiscordGatewayAPI(messages: []),
      slackAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_SLACK_TOKEN": "source-token",
      "TEST_SLACK_BOT_USER_ID": "U999",
      "TEST_SLACK_RIELA_TOKEN": "riela-token",
      "TEST_SLACK_YUI_TOKEN": "yui-token",
      "TEST_SLACK_MIKA_TOKEN": "mika-token",
      "TEST_SLACK_RINA_TOKEN": "rina-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions([
          "--workflow-definition-dir", eventRoot.deletingLastPathComponent().path,
          "--limit", "2"
        ]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.count, 2)
    let history = try XCTUnwrap(historyInput(from: workflowRequests[1]))
    XCTAssertEqual(history.map { $0["text"]?.stringValue }, [
      "First Slack message",
      "最初のSlackメッセージを受け取りました。"
    ])
    XCTAssertEqual(history.map { $0["role"]?.stringValue }, ["user", "assistant"])
    XCTAssertEqual(history.last?["replyAs"]?.stringValue, "riela")
  }

  func testSlackGatewayServeDispatchesThreePersonaRepliesInThread() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let api = FakeSlackGatewayAPI(messages: [
      try SlackMessage.fixture(
        ts: "1780000000.000500",
        text: "Yui, ask Mika and Rina for Slack thread opinions."
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replies: [
      ("Yuiです。まず整理します。@Mika、見せ方はどう？", "yui"),
      ("Mikaだよ。Slackでも読みやすいと思う。@Rina、技術面は？", "mika"),
      ("Rinaです。replyAs と thread_ts を固定できれば制御可能。", "rina")
    ])
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: FakeDiscordGatewayAPI(messages: []),
      slackAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_SLACK_TOKEN": "source-token",
      "TEST_SLACK_BOT_USER_ID": "U999",
      "TEST_SLACK_RIELA_TOKEN": "riela-token",
      "TEST_SLACK_YUI_TOKEN": "yui-token",
      "TEST_SLACK_MIKA_TOKEN": "mika-token",
      "TEST_SLACK_RINA_TOKEN": "rina-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions([
          "--workflow-definition-dir", eventRoot.deletingLastPathComponent().path,
          "--limit", "1"
        ]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages.map(\.token), ["yui-token", "mika-token", "rina-token"])
    XCTAssertEqual(sentMessages.map(\.channelId), ["C200", "C200", "C200"])
    XCTAssertEqual(sentMessages.map(\.threadTimestamp), [
      "1780000000.000500",
      "1780000000.000500",
      "1780000000.000500"
    ])
    let history = try JSONDecoder().decode(
      [JSONValue].self,
      from: Data(contentsOf: eventRoot.appendingPathComponent(
        "slack-history/slack-live/C200-1780000000.000500.json"
      ))
    )
    let historyObjects = history.compactMap(jsonObject)
    XCTAssertEqual(historyObjects.map { $0["role"]?.stringValue }, [
      "user",
      "assistant",
      "assistant",
      "assistant"
    ])
    XCTAssertEqual(historyObjects.compactMap { $0["replyAs"]?.stringValue }, ["yui", "mika", "rina"])
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-slack-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeSlackEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "slack-live",
      "kind": "slack-gateway",
      "provider": "slack",
      "tokenEnv": "TEST_SLACK_TOKEN",
      "botUserIdEnv": "TEST_SLACK_BOT_USER_ID",
      "channels": [{"id": "C200"}],
      "polling": {
        "limit": 1
      },
      "replyBots": {
        "riela": {"tokenEnv": "TEST_SLACK_RIELA_TOKEN"},
        "yui": {"tokenEnv": "TEST_SLACK_YUI_TOKEN"},
        "mika": {"tokenEnv": "TEST_SLACK_MIKA_TOKEN"},
        "rina": {"tokenEnv": "TEST_SLACK_RINA_TOKEN"}
      }
    }
    """.write(to: sources.appendingPathComponent("slack-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "slack-to-workflow",
      "sourceId": "slack-live",
      "workflowName": "slack-flow",
      "match": {"eventType": "chat.message"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "{{event.input.text}}",
          "conversationId": "{{event.conversation.id}}",
          "threadId": "{{event.conversation.threadId}}"
        },
        "mirrorToHumanInput": true
      },
      "outputDestinations": ["slack-replies"]
    }
    """.write(to: bindings.appendingPathComponent("slack-to-workflow.json"), atomically: true, encoding: .utf8)
  }
}
