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

  func testTelegramGatewayServeIgnoresAnyBotMessagesToPreventReplyLoops() async throws {
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

  private func writeTelegramEventConfig(eventRoot: URL, timeoutSeconds: Int = 0) throws {
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
}

private func historyInput(from request: EventWorkflowRunRequest) -> [JSONObject]? {
  guard
    case let .object(event)? = request.runtimeVariables["event"],
    case let .object(input)? = event["input"],
    case let .array(history)? = input["history"]
  else {
    return nil
  }
  return history.compactMap { value in
    guard case let .object(object) = value else {
      return nil
    }
    return object
  }
}

private actor FakeTelegramGatewayAPI: TelegramGatewayAPI {
  private var queuedUpdates: [TelegramUpdate]
  private var queuedUpdatesByToken: [String: [TelegramUpdate]]
  private(set) var getUpdateTokens: [String] = []
  private(set) var getUpdateRequests: [TelegramGetUpdatesRequest] = []
  private(set) var sentMessages: [TelegramSendMessageRequest] = []

  init(updates: [TelegramUpdate]) {
    self.queuedUpdates = updates
    self.queuedUpdatesByToken = [:]
  }

  init(updatesByToken: [String: [TelegramUpdate]]) {
    self.queuedUpdates = []
    self.queuedUpdatesByToken = updatesByToken
  }

  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate] {
    getUpdateRequests.append(request)
    getUpdateTokens.append(request.token)
    let updates: [TelegramUpdate]
    if queuedUpdatesByToken.keys.contains(request.token) {
      updates = queuedUpdatesByToken[request.token] ?? []
      queuedUpdatesByToken[request.token] = []
    } else {
      updates = queuedUpdates
      queuedUpdates = []
    }
    return updates
  }

  func sendMessage(request: TelegramSendMessageRequest) async throws {
    sentMessages.append(request)
  }
}

private actor FakeEventWorkflowRunner: EventWorkflowRunning {
  private(set) var requests: [EventWorkflowRunRequest] = []
  private let replyTexts: [String]
  private let replyAs: String

  init(replyText: String, replyAs: String) {
    self.replyTexts = [replyText]
    self.replyAs = replyAs
  }

  init(replies: [String], replyAs: String) {
    self.replyTexts = replies
    self.replyAs = replyAs
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    requests.append(request)
    let replyText = replyTexts[min(requests.count - 1, replyTexts.count - 1)]
    let now = Date(timeIntervalSince1970: 0)
    let output = WorkflowAcceptedOutputMetadata(
      payload: [
        "addon": .string("riela/chat-reply-worker"),
        "text": .string(replyText),
        "replyAs": .string(replyAs)
      ],
      when: [:],
      acceptedAt: now
    )
    let execution = WorkflowStepExecution(
      executionId: "exec-1",
      stepId: "send-yui-reply",
      nodeId: "send-yui-reply",
      attempt: 1,
      status: .completed,
      acceptedOutput: output,
      createdAt: now,
      updatedAt: now
    )
    let session = WorkflowSession(
      workflowId: request.workflowName,
      sessionId: "session-1",
      status: .completed,
      entryStepId: "send-yui-reply",
      createdAt: now,
      updatedAt: now,
      executions: [execution]
    )
    return WorkflowRunResult(
      workflowId: request.workflowName,
      session: session,
      rootOutput: nil,
      exitCode: 0,
      transitions: 0
    )
  }
}

private extension TelegramMessage {
  static func fixture(
    chatId: String,
    fromId: String,
    messageId: String = "1",
    text: String,
    isBot: Bool = false
  ) throws -> TelegramMessage {
    try JSONDecoder().decode(TelegramMessage.self, from: Data("""
    {
      "message_id": "\(messageId)",
      "date": 0,
      "text": "\(text)",
      "from": {"id": "\(fromId)", "is_bot": \(isBot), "first_name": "Tester"},
      "chat": {"id": "\(chatId)", "type": "group", "title": "Test Chat"}
    }
    """.utf8))
  }
}
