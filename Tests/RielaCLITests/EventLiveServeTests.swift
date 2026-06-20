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
      "TEST_TELEGRAM_YUI_TOKEN": "yui-token"
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
      "TEST_TELEGRAM_BOT_ID": "999"
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

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-tests-\(UUID().uuidString)", isDirectory: true)
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
        "yui": {"tokenEnv": "TEST_TELEGRAM_YUI_TOKEN"}
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

private actor FakeTelegramGatewayAPI: TelegramGatewayAPI {
  private var queuedUpdates: [TelegramUpdate]
  private(set) var sentMessages: [TelegramSendMessageRequest] = []

  init(updates: [TelegramUpdate]) {
    self.queuedUpdates = updates
  }

  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate] {
    let updates = queuedUpdates
    queuedUpdates = []
    return updates
  }

  func sendMessage(request: TelegramSendMessageRequest) async throws {
    sentMessages.append(request)
  }
}

private actor FakeEventWorkflowRunner: EventWorkflowRunning {
  private(set) var requests: [EventWorkflowRunRequest] = []
  private let replyText: String
  private let replyAs: String

  init(replyText: String, replyAs: String) {
    self.replyText = replyText
    self.replyAs = replyAs
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    requests.append(request)
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
  static func fixture(chatId: String, fromId: String, text: String) throws -> TelegramMessage {
    try JSONDecoder().decode(TelegramMessage.self, from: Data("""
    {
      "message_id": 1,
      "date": 0,
      "text": "\(text)",
      "from": {"id": "\(fromId)", "is_bot": false, "first_name": "Tester"},
      "chat": {"id": "\(chatId)", "type": "group", "title": "Test Chat"}
    }
    """.utf8))
  }
}
