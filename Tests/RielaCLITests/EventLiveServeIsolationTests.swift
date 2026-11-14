import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeIsolationTests: XCTestCase {
  func testOneLiveSourceFailureDoesNotStopOtherSources() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    try writeDiscordEventConfig(eventRoot: eventRoot)
    let discordAPI = FakeDiscordGatewayAPI(messages: [
      try DiscordMessage.fixture(
        id: "1510000000000000020",
        channelId: "200",
        guildId: "100",
        content: "Discord should still run"
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "discord ok", replyAs: "yui")
    let server = DefaultEventLiveServer(
      telegramAPI: FailingTelegramGatewayAPI(message: "telegram 429"),
      discordAPI: discordAPI,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token",
      "TEST_DISCORD_TOKEN": "discord-source-token",
      "TEST_DISCORD_APP_ID": "999",
      "TEST_DISCORD_YUI_TOKEN": "yui-token",
      "TEST_DISCORD_MIKA_TOKEN": "mika-token",
      "TEST_DISCORD_RINA_TOKEN": "rina-token"
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
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["discord-flow"])
    let sentMessages = await discordAPI.sentMessages
    XCTAssertEqual(sentMessages, [
      DiscordSendMessageRequest(token: "yui-token", channelId: "200", text: "discord ok")
    ])
    let serveRecordData = try Data(contentsOf: eventRoot.appendingPathComponent("serve-record.json"))
    guard case let .object(serveRecord) = try JSONDecoder().decode(JSONValue.self, from: serveRecordData) else {
      return XCTFail("Expected serve record to be a JSON object.")
    }
    XCTAssertEqual(serveRecord["lastIgnoredReason"], .string("telegram-poll-failed"))
    XCTAssertEqual(serveRecord["lastDiagnosticCodes"], .string("event_source_poll_failed"))
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-isolation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeTelegramEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "telegram-live",
      "kind": "telegram-gateway",
      "provider": "telegram",
      "tokenEnv": "TEST_TELEGRAM_TOKEN",
      "botIdEnv": "TEST_TELEGRAM_BOT_ID",
      "chats": [{"id": "100"}],
      "polling": {
        "timeoutSeconds": 0,
        "limit": 1,
        "offsetPath": "telegram/telegram-live-offset.json"
      },
      "replyBots": {
        "yui": {"tokenEnv": "TEST_TELEGRAM_YUI_TOKEN"},
        "mika": {"tokenEnv": "TEST_TELEGRAM_MIKA_TOKEN"}
      }
    }
    """.write(to: sources.appendingPathComponent("telegram-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "telegram-to-workflow",
      "sourceId": "telegram-live",
      "workflowName": "telegram-flow",
      "match": {"eventType": "chat.message"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "{{event.input.text}}",
          "conversationId": "{{event.conversation.id}}"
        },
        "mirrorToHumanInput": true
      },
      "outputDestinations": ["telegram-replies"]
    }
    """.write(to: bindings.appendingPathComponent("telegram-to-workflow.json"), atomically: true, encoding: .utf8)
  }

  private func writeDiscordEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "discord-live",
      "kind": "discord-gateway",
      "provider": "discord",
      "tokenEnv": "TEST_DISCORD_TOKEN",
      "applicationIdEnv": "TEST_DISCORD_APP_ID",
      "guildIds": ["100"],
      "channels": [{"id": "200", "personas": ["yui", "mika", "rina"]}],
      "polling": {
        "limit": 1,
        "offsetPath": "discord/discord-live-200-offset.json"
      },
      "replyBots": {
        "yui": {"tokenEnv": "TEST_DISCORD_YUI_TOKEN"},
        "mika": {"tokenEnv": "TEST_DISCORD_MIKA_TOKEN"},
        "rina": {"tokenEnv": "TEST_DISCORD_RINA_TOKEN"}
      }
    }
    """.write(to: sources.appendingPathComponent("discord-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "discord-to-workflow",
      "sourceId": "discord-live",
      "workflowName": "discord-flow",
      "match": {"eventType": "chat.message"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "{{event.input.text}}",
          "conversationId": "{{event.conversation.id}}"
        },
        "mirrorToHumanInput": true
      },
      "outputDestinations": ["discord-replies"]
    }
    """.write(to: bindings.appendingPathComponent("discord-to-workflow.json"), atomically: true, encoding: .utf8)
  }
}
