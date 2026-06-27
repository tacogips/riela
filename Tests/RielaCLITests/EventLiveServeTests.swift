import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeTests: XCTestCase {
  func testTelegramGatewayServePollsRunsWorkflowAndSendsReply() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 42,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "200",
          text: "Yui, hello"
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "承知しました。短く返します。", replyAs: "yui")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["telegram-flow"])
    XCTAssertEqual(workflowRequests.first?.runtimeVariables["humanInput"], .object([
      "request": .string("Yui, hello"),
      "conversationId": .string("100")
    ]))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages, [
      TelegramSendMessageRequest(
        token: "yui-token",
        chatId: "100",
        threadId: nil,
        text: "承知しました。短く返します。"
      )
    ])
    let offsetText = try String(contentsOf: eventRoot.appendingPathComponent("telegram/telegram-live-offset.json"), encoding: .utf8)
    XCTAssertTrue(offsetText.contains(#""offset" : 43"#))
  }

  func testTelegramGatewayServeIgnoresConfiguredBotSelfMessages() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 43,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "999",
          text: "self"
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "ignored", replyAs: "yui")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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

  func testTelegramGatewayServeIgnoresBotMessagesByDefault() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 44,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "555",
          text: "@mikatrend0529bot bot echo",
          isBot: true
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "ignored", replyAs: "mika")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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

  func testTelegramGatewayServeAllowsBotMessagesWhenConfigured() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot, ignoreBots: false)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 45,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "555",
          text: "@mikatrend0529bot bot question",
          isBot: true
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "bot question accepted", replyAs: "mika")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
    XCTAssertEqual(workflowRequests.count, 1)
    XCTAssertEqual(sentMessages, [
      TelegramSendMessageRequest(token: "mika-token", chatId: "100", threadId: nil, text: "bot question accepted")
    ])
  }

  func testTelegramGatewayServePollsReplyBotTokensForMentionedMessages() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot, timeoutSeconds: 10)
    let api = FakeTelegramGatewayAPI(updatesByToken: [
      "source-token": [],
      "mika-token": [
        TelegramUpdate(
          updateId: 88,
          message: try TelegramMessage.fixture(
            chatId: "100",
            fromId: "200",
            text: "@mikatrend0529bot 最近調子どう?"
          )
        )
      ]
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "元気だよ。最近の流れも見てるよ。", replyAs: "mika")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "source-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
    let getUpdateTokens = await api.getUpdateTokens
    XCTAssertEqual(getUpdateTokens.prefix(2), ["source-token", "mika-token"])
    let getUpdateRequests = await api.getUpdateRequests
    XCTAssertEqual(getUpdateRequests.prefix(2).map(\.timeoutSeconds), [10, 2])
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["telegram-flow"])
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages, [
      TelegramSendMessageRequest(
        token: "mika-token",
        chatId: "100",
        threadId: nil,
        text: "元気だよ。最近の流れも見てるよ。"
      )
    ])
    let offsetText = try String(
      contentsOf: eventRoot.appendingPathComponent("telegram/telegram-live-offset-mika.json"),
      encoding: .utf8
    )
    XCTAssertTrue(offsetText.contains(#""offset" : 89"#))
    let serveRecordData = try Data(contentsOf: eventRoot.appendingPathComponent("serve-record.json"))
    guard case let .object(serveRecord) = try JSONDecoder().decode(JSONValue.self, from: serveRecordData) else {
      return XCTFail("Expected serve record to be a JSON object.")
    }
    XCTAssertEqual(serveRecord["lastPollingTarget"], .string("mika"))
    XCTAssertEqual(serveRecord["pollingTargetCount"], .number(2))
    XCTAssertEqual(serveRecord["lastUpdateCount"], .number(1))
    XCTAssertEqual(serveRecord["lastReplyDispatchCount"], .number(1))
    XCTAssertEqual(serveRecord["lastReplyAs"], .string("mika"))
  }

  func testTelegramGatewayServeTargetFiltersUnrelatedBindingsBeforeDryRun() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    try writeUnrelatedWebhookEventConfig(eventRoot: eventRoot)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 89,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "200",
          text: "@mikatrend0529bot targeted live check"
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replyText: "targeted ok", replyAs: "mika")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: "telegram-live",
        parsed: try ParsedParityOptions([
          "--workflow-definition-dir", eventRoot.deletingLastPathComponent().path,
          "--limit", "1"
        ]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.map(\.workflowName), ["telegram-flow"])
    let serveRecordData = try Data(contentsOf: eventRoot.appendingPathComponent("serve-record.json"))
    guard case let .object(serveRecord) = try JSONDecoder().decode(JSONValue.self, from: serveRecordData) else {
      return XCTFail("Expected serve record to be a JSON object.")
    }
    XCTAssertNil(serveRecord["lastDiagnosticCodes"])
    XCTAssertEqual(serveRecord["lastWorkflowName"], .string("telegram-flow"))
  }

  func testTelegramGatewayServeDeduplicatesSameMessageAcrossPollingTargets() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot, timeoutSeconds: 10)
    let api = FakeTelegramGatewayAPI(updatesByToken: [
      "source-token": [
        TelegramUpdate(
          updateId: 90,
          message: try TelegramMessage.fixture(
            chatId: "100",
            fromId: "200",
            messageId: "10",
            text: "@rinacursor0529bot なんの機能?"
          )
        )
      ],
      "mika-token": [
        TelegramUpdate(
          updateId: 91,
          message: try TelegramMessage.fixture(
            chatId: "100",
            fromId: "200",
            messageId: "11",
            text: "@rinacursor0529bot なんの機能?"
          )
        )
      ]
    ])
    let workflowRunner = FakeEventWorkflowRunner(
      replyText: "この三者チャットの言及ルーティングと会話の継続性を担う機能です。",
      replyAs: "rina"
    )
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "source-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
    let sentMessages = await api.sentMessages
    XCTAssertEqual(workflowRequests.count, 1)
    XCTAssertEqual(sentMessages.count, 1)
    let history = try XCTUnwrap(historyInput(from: workflowRequests[0]))
    XCTAssertEqual(history, [])
    let historyData = try Data(contentsOf: eventRoot.appendingPathComponent(
      "telegram-history/telegram-live/100-main.json"
    ))
    let historyValues = try JSONDecoder().decode([JSONValue].self, from: historyData)
    XCTAssertEqual(historyValues.count, 2)
  }

  func testTelegramGatewayServeRequiresConfiguredEnvironmentBeforeReady() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      workflowRunner: FakeEventWorkflowRunner(replyText: "unused", replyAs: "yui")
    )

    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue([:]) {
        try await server.serve(
          eventRoot: eventRoot,
          target: nil,
          parsed: try ParsedParityOptions(["--limit", "1"]),
          output: .json
        )
      }
      XCTFail("Expected missing Telegram environment to fail before reporting ready.")
    } catch {
      XCTAssertTrue(String(describing: error).contains("TEST_TELEGRAM_TOKEN"))
    }
    let serveRecordData = try Data(contentsOf: eventRoot.appendingPathComponent("serve-record.json"))
    guard case let .object(serveRecord) = try JSONDecoder().decode(JSONValue.self, from: serveRecordData) else {
      return XCTFail("Expected serve record to be a JSON object.")
    }
    XCTAssertEqual(serveRecord["status"], .string("failed"))
    XCTAssertTrue(serveRecord["detail"]?.stringValue?.contains("TEST_TELEGRAM_TOKEN") == true)
  }

  func testTelegramGatewayServeIncludesPersistedConversationHistory() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot)
    let api = FakeTelegramGatewayAPI(updates: [
      TelegramUpdate(
        updateId: 50,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "200",
          messageId: "50",
          text: "@rinacursor0529bot 最近調子どう?"
        )
      ),
      TelegramUpdate(
        updateId: 51,
        message: try TelegramMessage.fixture(
          chatId: "100",
          fromId: "200",
          messageId: "51",
          text: "@rinacursor0529bot なんの機能?"
        )
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(
      replies: [
        "順調だよ。今は新しい機能の検証を進めているところ。",
        "さっき話した新しい機能の検証のことだよ。"
      ],
      replyAs: "rina"
    )
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
      "@rinacursor0529bot 最近調子どう?",
      "順調だよ。今は新しい機能の検証を進めているところ。"
    ])
    XCTAssertEqual(history.map { $0["role"]?.stringValue }, ["user", "assistant"])
    XCTAssertEqual(history.last?["replyAs"]?.stringValue, "rina")
  }

  func testTelegramGatewayServeResolvesPhotoCaptionIntoImagePath() async throws {
    let eventRoot = try temporaryDirectory()
    try writeTelegramEventConfig(eventRoot: eventRoot, resolveAttachmentFilePaths: true)
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    let api = FakeTelegramGatewayAPI(
      updates: [
        TelegramUpdate(
          updateId: 52,
          message: try TelegramMessage.photoFixture(
            chatId: "100",
            fromId: "200",
            caption: "@mikatrend0529bot What kind of image is this?",
            fileId: "photo-file"
          )
        )
      ],
      filesById: [
        "photo-file": TelegramFile(fileId: "photo-file", fileUniqueId: "unique-photo", fileSize: imageData.count, filePath: "photos/yui.png")
      ],
      downloadedFilesByPath: [
        "photos/yui.png": imageData
      ]
    )
    let workflowRunner = FakeEventWorkflowRunner(replyText: "Yuiのアイコン画像です。", replyAs: "mika")
    let server = DefaultEventLiveServer(telegramAPI: api, workflowRunner: workflowRunner)

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_TELEGRAM_TOKEN": "source-token",
      "TEST_TELEGRAM_BOT_ID": "999",
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token",
      "TEST_TELEGRAM_MIKA_TOKEN": "mika-token"
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
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.count, 1)
    let input = try XCTUnwrap(eventInput(from: workflowRequests[0]))
    XCTAssertEqual(input["text"], .string("@mikatrend0529bot What kind of image is this?"))
    let imagePath = try XCTUnwrap(jsonArray(input["imagePaths"])?.first?.stringValue)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), imageData)
    let attachments = try XCTUnwrap(jsonArray(input["attachments"]))
    XCTAssertEqual(attachments.count, 1)
    let attachment = try XCTUnwrap(jsonObject(attachments[0]))
    XCTAssertEqual(attachment["path"]?.stringValue, imagePath)
    XCTAssertEqual(attachment["fileId"], .string("photo-file"))
  }

  func testDiscordGatewayServePollsRunsWorkflowAndSendsPersonaReplies() async throws {
    let eventRoot = try temporaryDirectory()
    try writeDiscordEventConfig(eventRoot: eventRoot)
    let api = FakeDiscordGatewayAPI(messages: [
      try DiscordMessage.fixture(
        id: "1510000000000000001",
        channelId: "200",
        guildId: "100",
        content: "Yui、MikaとRinaにも自然に聞いて"
      )
    ])
    let workflowRunner = FakeEventWorkflowRunner(replies: [
      ("YuiからMikaに渡します。@Mika、どう見えますか？", "yui"),
      ("Mikaだよ。自然だと思う。@Rina、技術面どう？", "mika"),
      ("問題ない。routing と reply identity は分離。", "rina")
    ])
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_DISCORD_TOKEN": "source-token",
      "TEST_DISCORD_APP_ID": "999",
      "TEST_DISCORD_YUI_TOKEN": "yui-token",
      "TEST_DISCORD_MIKA_TOKEN": "mika-token",
      "TEST_DISCORD_RINA_TOKEN": "rina-token",
      "RIELA_DISCORD_CHANNEL_ID": "999"
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
    XCTAssertEqual(workflowRequests.first?.runtimeVariables["humanInput"], .object([
      "request": .string("Yui、MikaとRinaにも自然に聞いて"),
      "conversationId": .string("200")
    ]))
    let sentMessages = await api.sentMessages
    XCTAssertEqual(sentMessages, [
      DiscordSendMessageRequest(token: "yui-token", channelId: "200", text: "YuiからMikaに渡します。@Mika、どう見えますか？"),
      DiscordSendMessageRequest(token: "mika-token", channelId: "200", text: "Mikaだよ。自然だと思う。@Rina、技術面どう？"),
      DiscordSendMessageRequest(token: "rina-token", channelId: "200", text: "問題ない。routing と reply identity は分離。")
    ])
    let offsetText = try String(contentsOf: eventRoot.appendingPathComponent("discord/discord-live-200-offset.json"), encoding: .utf8)
    XCTAssertTrue(offsetText.contains(#""lastMessageId" : "1510000000000000001""#))
  }

  func testDiscordGatewayServeResolvesImageAttachmentIntoImagePath() async throws {
    let eventRoot = try temporaryDirectory()
    try writeDiscordEventConfig(eventRoot: eventRoot, resolveAttachmentFilePaths: true)
    let imageData = Data([0xFF, 0xD8, 0xFF])
    let api = FakeDiscordGatewayAPI(
      messages: [
        try DiscordMessage.fixture(
          id: "1510000000000000100",
          channelId: "200",
          guildId: "100",
          content: "@mikatrend0529bot What kind of image is this?",
          attachmentsJSON: """
          [{
            "id": "att-1",
            "filename": "yui.jpg",
            "content_type": "image/jpeg",
            "size": \(imageData.count),
            "url": "https://cdn.example/yui.jpg",
            "width": 512,
            "height": 512
          }]
          """
        )
      ],
      attachmentDataByURL: [
        "https://cdn.example/yui.jpg": imageData
      ]
    )
    let workflowRunner = FakeEventWorkflowRunner(replyText: "Yuiのアイコン画像です。", replyAs: "mika")
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_DISCORD_TOKEN": "source-token",
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
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.count, 1)
    let input = try XCTUnwrap(eventInput(from: workflowRequests[0]))
    let imagePath = try XCTUnwrap(jsonArray(input["imagePaths"])?.first?.stringValue)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), imageData)
    let attachments = try XCTUnwrap(jsonArray(input["attachments"]))
    XCTAssertEqual(attachments.count, 1)
    let attachment = try XCTUnwrap(jsonObject(attachments[0]))
    XCTAssertEqual(attachment["path"]?.stringValue, imagePath)
    XCTAssertEqual(attachment["filename"], .string("yui.jpg"))
  }

  func testDiscordGatewayServeUsesRequestedLimitOnInitialPoll() async throws {
    let eventRoot = try temporaryDirectory()
    try writeDiscordEventConfig(eventRoot: eventRoot)
    let api = FakeDiscordGatewayAPI(messages: [
      try DiscordMessage.fixture(id: "1510000000000000001", channelId: "200", guildId: "100", content: "first"),
      try DiscordMessage.fixture(id: "1510000000000000002", channelId: "200", guildId: "100", content: "second")
    ])
    let workflowRunner = FakeEventWorkflowRunner(replies: ["reply one", "reply two"], replyAs: "yui")
    let server = DefaultEventLiveServer(
      telegramAPI: FakeTelegramGatewayAPI(updates: []),
      discordAPI: api,
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_DISCORD_TOKEN": "source-token",
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
          "--limit", "2"
        ]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=2"))
    let getMessageRequests = await api.getMessageRequests
    XCTAssertEqual(getMessageRequests.first?.limit, 2)
    let workflowRequests = await workflowRunner.requests
    XCTAssertEqual(workflowRequests.count, 2)
  }

  func testTelegramAPIStatusResponseReportsTelegramFailureDescription() throws {
    let data = Data(#"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#.utf8)
    let response = try JSONDecoder().decode(TelegramAPIStatusResponse.self, from: data)

    XCTAssertThrowsError(try response.validate(operation: "sendMessage")) { error in
      XCTAssertTrue(String(describing: error).contains("Bad Request: chat not found"))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeTelegramEventConfig(
    eventRoot: URL,
    timeoutSeconds: Int = 0,
    ignoreBots: Bool? = nil,
    resolveAttachmentFilePaths: Bool = false
  ) throws {
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
        "timeoutSeconds": \(timeoutSeconds),
        "limit": 1,
        "offsetPath": "telegram/telegram-live-offset.json"
      },
      "attachments": {
        "includePhotos": true,
        "resolveFilePaths": \(resolveAttachmentFilePaths)
      },
      \(ignoreBots.map { #""filters": {"ignoreBots": \#($0), "ignoreSelf": true},"# } ?? "")
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

  private func writeUnrelatedWebhookEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try """
    {
      "id": "unrelated-webhook",
      "kind": "webhook",
      "path": "/unrelated"
    }
    """.write(to: sources.appendingPathComponent("unrelated-webhook.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "unrelated-webhook-to-workflow",
      "sourceId": "unrelated-webhook",
      "workflowName": "unrelated-flow",
      "match": {"eventType": "repo.push"},
      "inputMapping": {
        "mode": "template",
        "template": {"request": "{{event.input.text}}"}
      }
    }
    """.write(to: bindings.appendingPathComponent("unrelated-webhook-to-workflow.json"), atomically: true, encoding: .utf8)
  }

  private func writeDiscordEventConfig(eventRoot: URL, resolveAttachmentFilePaths: Bool = false) throws {
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
      "channels": [{"id": "200", "includeThreads": true, "personas": ["yui", "mika", "rina"]}],
      "polling": {
        "limit": 1,
        "offsetPath": "discord/discord-live-200-offset.json"
      },
      "attachments": {
        "includeImages": true,
        "resolveFilePaths": \(resolveAttachmentFilePaths),
        "maxBytes": 1024
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
