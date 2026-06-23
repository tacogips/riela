import Foundation
import RielaCore
@testable import RielaCLI

func historyInput(from request: EventWorkflowRunRequest) -> [JSONObject]? {
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

func eventInput(from request: EventWorkflowRunRequest) -> JSONObject? {
  guard
    case let .object(event)? = request.runtimeVariables["event"],
    case let .object(input)? = event["input"]
  else {
    return nil
  }
  return input
}

actor FakeTelegramGatewayAPI: TelegramGatewayAPI {
  private var queuedUpdates: [TelegramUpdate]
  private var queuedUpdatesByToken: [String: [TelegramUpdate]]
  private var filesById: [String: TelegramFile]
  private var downloadedFilesByPath: [String: Data]
  private(set) var getUpdateTokens: [String] = []
  private(set) var getUpdateRequests: [TelegramGetUpdatesRequest] = []
  private(set) var getFileRequests: [TelegramGetFileRequest] = []
  private(set) var downloadFileRequests: [TelegramDownloadFileRequest] = []
  private(set) var sentMessages: [TelegramSendMessageRequest] = []

  init(
    updates: [TelegramUpdate],
    filesById: [String: TelegramFile] = [:],
    downloadedFilesByPath: [String: Data] = [:]
  ) {
    self.queuedUpdates = updates
    self.queuedUpdatesByToken = [:]
    self.filesById = filesById
    self.downloadedFilesByPath = downloadedFilesByPath
  }

  init(
    updatesByToken: [String: [TelegramUpdate]],
    filesById: [String: TelegramFile] = [:],
    downloadedFilesByPath: [String: Data] = [:]
  ) {
    self.queuedUpdates = []
    self.queuedUpdatesByToken = updatesByToken
    self.filesById = filesById
    self.downloadedFilesByPath = downloadedFilesByPath
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

  func getFile(request: TelegramGetFileRequest) async throws -> TelegramFile {
    getFileRequests.append(request)
    guard let file = filesById[request.fileId] else {
      throw CLIUsageError("missing fake Telegram file for \(request.fileId)")
    }
    return file
  }

  func downloadFile(request: TelegramDownloadFileRequest) async throws -> Data {
    downloadFileRequests.append(request)
    guard let data = downloadedFilesByPath[request.filePath] else {
      throw CLIUsageError("missing fake Telegram file data for \(request.filePath)")
    }
    return data
  }

  func sendMessage(request: TelegramSendMessageRequest) async throws {
    sentMessages.append(request)
  }
}

actor FakeDiscordGatewayAPI: DiscordGatewayAPI {
  private var queuedMessages: [DiscordMessage]
  private var attachmentDataByURL: [String: Data]
  private(set) var getMessageRequests: [DiscordGetMessagesRequest] = []
  private(set) var downloadAttachmentRequests: [DiscordDownloadAttachmentRequest] = []
  private(set) var sentMessages: [DiscordSendMessageRequest] = []

  init(messages: [DiscordMessage], attachmentDataByURL: [String: Data] = [:]) {
    self.queuedMessages = messages
    self.attachmentDataByURL = attachmentDataByURL
  }

  func getMessages(request: DiscordGetMessagesRequest) async throws -> [DiscordMessage] {
    getMessageRequests.append(request)
    let messages = queuedMessages
    queuedMessages = []
    return messages
  }

  func downloadAttachment(request: DiscordDownloadAttachmentRequest) async throws -> Data {
    downloadAttachmentRequests.append(request)
    guard let data = attachmentDataByURL[request.url] else {
      throw CLIUsageError("missing fake Discord attachment data for \(request.url)")
    }
    return data
  }

  func sendMessage(request: DiscordSendMessageRequest) async throws {
    sentMessages.append(request)
  }
}

actor FakeEventWorkflowRunner: EventWorkflowRunning {
  private(set) var requests: [EventWorkflowRunRequest] = []
  private let repliesByRequest: [[(text: String, replyAs: String)]]

  init(replyText: String, replyAs: String) {
    self.repliesByRequest = [[(replyText, replyAs)]]
  }

  init(replies: [String], replyAs: String) {
    self.repliesByRequest = replies.map { [($0, replyAs)] }
  }

  init(replies: [(text: String, replyAs: String)]) {
    self.repliesByRequest = [replies]
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    requests.append(request)
    let replies = repliesByRequest[min(requests.count - 1, repliesByRequest.count - 1)]
    let now = Date(timeIntervalSince1970: 0)
    let executions = replies.enumerated().map { index, reply in
      WorkflowStepExecution(
        executionId: "exec-\(index + 1)",
        stepId: "send-\(reply.replyAs)-reply",
        nodeId: "send-\(reply.replyAs)-reply",
        attempt: 1,
        status: .completed,
        acceptedOutput: WorkflowAcceptedOutputMetadata(
          payload: [
            "addon": .string("riela/chat-reply-worker"),
            "text": .string(reply.text),
            "replyAs": .string(reply.replyAs)
          ],
          when: [:],
          acceptedAt: now
        ),
        createdAt: now,
        updatedAt: now
      )
    }
    let session = WorkflowSession(
      workflowId: request.workflowName,
      sessionId: "session-1",
      status: .completed,
      entryStepId: executions.first?.stepId ?? "send-yui-reply",
      createdAt: now,
      updatedAt: now,
      executions: executions
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

extension TelegramMessage {
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

  static func photoFixture(
    chatId: String,
    fromId: String,
    messageId: String = "1",
    caption: String,
    fileId: String,
    isBot: Bool = false
  ) throws -> TelegramMessage {
    try JSONDecoder().decode(TelegramMessage.self, from: Data("""
    {
      "message_id": "\(messageId)",
      "date": 0,
      "caption": "\(caption)",
      "photo": [{
        "file_id": "\(fileId)",
        "file_unique_id": "unique-\(fileId)",
        "width": 512,
        "height": 512,
        "file_size": 4
      }],
      "from": {"id": "\(fromId)", "is_bot": \(isBot), "first_name": "Tester"},
      "chat": {"id": "\(chatId)", "type": "group", "title": "Test Chat"}
    }
    """.utf8))
  }
}

extension DiscordMessage {
  static func fixture(
    id: String,
    channelId: String,
    guildId: String,
    content: String,
    isBot: Bool = false,
    attachmentsJSON: String = "[]"
  ) throws -> DiscordMessage {
    try JSONDecoder().decode(DiscordMessage.self, from: Data("""
    {
      "id": "\(id)",
      "channel_id": "\(channelId)",
      "guild_id": "\(guildId)",
      "content": "\(content)",
      "timestamp": "2026-06-21T23:40:00.000000+00:00",
      "author": {"id": "300", "username": "tester", "global_name": "Tester", "bot": \(isBot)},
      "attachments": \(attachmentsJSON)
    }
    """.utf8))
  }
}

func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array) = value else {
    return nil
  }
  return array
}

func jsonObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}
