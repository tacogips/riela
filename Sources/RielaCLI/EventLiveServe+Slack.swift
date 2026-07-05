import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents

extension DefaultEventLiveServer {
  func pollSlackSource(
    _ source: SlackGatewaySource,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    var observedMessages = 0
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let token = try source.token(environment: environment)
    let channelIds = source.channelIds(environment: environment)
    for channelId in channelIds {
      let offsetStore = SlackMessageOffsetStore(eventRoot: eventRoot, source: source, channelId: channelId)
      let oldestTimestamp = try offsetStore.loadLastTimestamp()
      let messages: [SlackMessage]
      do {
        messages = try await slackAPI.getMessages(request: SlackGetMessagesRequest(
          token: token,
          channelId: channelId,
          oldestTimestamp: oldestTimestamp,
          limit: parsed.limit ?? source.polling.limit
        ))
      } catch {
        throw EventLiveSourcePollFailure(error)
      }
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: channelId,
        pollingTargetCount: channelIds.count,
        lastUpdateCount: messages.count
      )
      for message in messages.sorted(by: { $0.sortKey < $1.sortKey }) {
        observedMessages += 1
        guard let envelope = source.envelope(from: message, channelId: channelId, eventRoot: eventRoot) else {
          try offsetStore.saveLastTimestamp(message.ts)
          continue
        }
        let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
          sources: config.sources,
          bindings: config.bindings,
          envelope: envelope
        ))
        guard triggerResult.accepted else {
          try offsetStore.saveLastTimestamp(message.ts)
          continue
        }
        for trigger in triggerResult.triggers {
          guard let workflowName = trigger.workflowName else {
            continue
          }
          let result = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
            workflowName: workflowName,
            runtimeVariables: trigger.runtimeVariables,
            parsed: parsed
          ))
          let replies = try await dispatchSlackReplies(result: result, source: source, envelope: envelope, sourceToken: token)
          try SlackConversationHistoryStore(eventRoot: eventRoot, source: source).appendExchange(
            message: message,
            channelId: channelId,
            replies: replies
          )
          if !replies.isEmpty {
            try? writeServeRecord(
              eventRoot: eventRoot,
              status: "ready",
              lastReplyDispatchCount: replies.count,
              lastReplyAs: replies.compactMap(\.replyAs).joined(separator: ",")
            )
          }
        }
        try offsetStore.saveLastTimestamp(message.ts)
      }
    }
    return observedMessages
  }

  private func dispatchSlackReplies(
    result: WorkflowRunResult,
    source: SlackGatewaySource,
    envelope: ExternalEventEnvelope,
    sourceToken: String
  ) async throws -> [SlackConversationReply] {
    guard let channelId = envelope.conversation?["id"]?.stringValue else {
      return []
    }
    let threadTimestamp = envelope.conversation?["threadId"]?.stringValue
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    var replies: [SlackConversationReply] = []
    for execution in result.session.executions {
      guard execution.acceptedOutput?.payload["addon"] == .string("riela/chat-reply-worker"),
        let text = execution.acceptedOutput?.payload["text"]?.stringValue,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continue
      }
      let replyAs = execution.acceptedOutput?.payload["replyAs"]?.stringValue
      let token = source.replyToken(replyAs: replyAs, environment: environment) ?? sourceToken
      try await slackAPI.sendMessage(request: SlackSendMessageRequest(
        token: token,
        channelId: channelId,
        threadTimestamp: threadTimestamp,
        text: text
      ))
      replies.append(SlackConversationReply(replyAs: replyAs, text: text))
    }
    return replies
  }
}

struct SlackGatewaySource: Decodable, Equatable, Sendable {
  var id: String
  var tokenEnv: String?
  var botUserIdEnv: String?
  var channels: [SlackGatewayChannel]
  var polling: SlackGatewayPolling
  var filters: SlackGatewayFilters
  var replyBots: [String: SlackGatewayReplyBot]

  private enum CodingKeys: String, CodingKey {
    case id
    case tokenEnv
    case botUserIdEnv
    case channels
    case polling
    case filters
    case replyBots
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.tokenEnv = try container.decodeIfPresent(String.self, forKey: .tokenEnv)
    self.botUserIdEnv = try container.decodeIfPresent(String.self, forKey: .botUserIdEnv)
    self.channels = try container.decodeIfPresent([SlackGatewayChannel].self, forKey: .channels) ?? []
    self.polling = try container.decodeIfPresent(SlackGatewayPolling.self, forKey: .polling) ?? SlackGatewayPolling()
    self.filters = try container.decodeIfPresent(SlackGatewayFilters.self, forKey: .filters) ?? SlackGatewayFilters()
    self.replyBots = try container.decodeIfPresent([String: SlackGatewayReplyBot].self, forKey: .replyBots) ?? [:]
  }

  func token(environment: [String: String]) throws -> String {
    guard let token = slackEnvironmentValue(tokenEnv ?? "RIELA_SLACK_BOT_TOKEN", environment: environment) else {
      throw CLIUsageError("slack-gateway source '\(id)' requires \(tokenEnv ?? "RIELA_SLACK_BOT_TOKEN")")
    }
    return token
  }

  func validateEnvironment(environment: [String: String]) throws {
    _ = try token(environment: environment)
    if let botUserIdEnv, slackEnvironmentValue(botUserIdEnv, environment: environment) == nil {
      throw CLIUsageError("slack-gateway source '\(id)' requires \(botUserIdEnv)")
    }
    for (replyAs, replyBot) in replyBots.sorted(by: { $0.key < $1.key }) {
      guard let tokenEnv = replyBot.tokenEnv else {
        continue
      }
      guard slackEnvironmentValue(tokenEnv, environment: environment) != nil else {
        throw CLIUsageError("slack-gateway source '\(id)' reply bot '\(replyAs)' requires \(tokenEnv)")
      }
    }
    if channelIds(environment: environment).isEmpty {
      throw CLIUsageError("slack-gateway source '\(id)' requires at least one channel id")
    }
  }

  func channelIds(environment: [String: String]) -> [String] {
    let configured = channels.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !configured.isEmpty {
      return configured
    }
    let fallback = environment["RIELA_SLACK_CHANNEL_ID"]
      .map { [$0.trimmingCharacters(in: .whitespacesAndNewlines)] }?
      .filter { !$0.isEmpty } ?? []
    return Array(Set(fallback)).sorted()
  }

  func replyToken(replyAs: String?, environment: [String: String]) -> String? {
    guard let replyAs,
      let tokenEnv = replyBots[replyAs]?.tokenEnv
    else {
      return nil
    }
    return slackEnvironmentValue(tokenEnv, environment: environment)
  }

  func envelope(from message: SlackMessage, channelId: String, eventRoot: URL) -> ExternalEventEnvelope? {
    guard isAllowed(message: message, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()),
      !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.files.isEmpty
    else {
      return nil
    }
    let threadTimestamp = message.threadTimestamp ?? message.ts
    return ExternalEventEnvelope(
      sourceId: id,
      eventId: "\(channelId):\(message.ts)",
      provider: "slack",
      eventType: "chat.message",
      receivedAt: message.timestampDate ?? Date(),
      actor: compactSlackObject([
        "id": message.user.map(JSONValue.string),
        "displayName": message.username.map(JSONValue.string),
        "botId": message.botId.map(JSONValue.string),
        "isBot": .bool(message.isBotMessage)
      ]),
      conversation: compactSlackObject([
        "id": .string(channelId),
        "threadId": .string(threadTimestamp),
        "messageTs": .string(message.ts)
      ]),
      input: [
        "text": .string(message.text),
        "provider": .string("slack"),
        "history": .array(
          SlackConversationHistoryStore(eventRoot: eventRoot, source: self)
            .loadHistory(message: message, channelId: channelId)
            .map(JSONValue.object)
        ),
        "historySource": .string("chat-memory"),
        "attachments": .array(message.files.map { .object($0.normalizedDescriptor) }),
        "imagePaths": .array([]),
        "attachmentText": .string(""),
        "eventDataRoot": .string(eventRoot.path)
      ]
    )
  }

  private func isAllowed(message: SlackMessage, environment: [String: String]) -> Bool {
    if filters.ignoreBots, message.isBotMessage {
      return false
    }
    if filters.ignoreSelf,
      let botUserIdEnv,
      let botUserId = slackEnvironmentValue(botUserIdEnv, environment: environment),
      message.user == botUserId {
      return false
    }
    return true
  }
}

struct SlackGatewayChannel: Decodable, Equatable, Sendable {
  var id: String

  private enum CodingKeys: String, CodingKey {
    case id
  }
}

struct SlackGatewayPolling: Decodable, Equatable, Sendable {
  var limit: Int
  var offsetPath: String?

  init(limit: Int = 15, offsetPath: String? = nil) {
    self.limit = limit
    self.offsetPath = offsetPath
  }
}

struct SlackGatewayFilters: Decodable, Equatable, Sendable {
  var ignoreBots: Bool
  var ignoreSelf: Bool

  init(ignoreBots: Bool = true, ignoreSelf: Bool = true) {
    self.ignoreBots = ignoreBots
    self.ignoreSelf = ignoreSelf
  }
}

struct SlackGatewayReplyBot: Decodable, Equatable, Sendable {
  var tokenEnv: String?
}

struct SlackGetMessagesRequest: Equatable, Sendable {
  var token: String
  var channelId: String
  var oldestTimestamp: String?
  var limit: Int
}

struct SlackSendMessageRequest: Equatable, Sendable {
  var token: String
  var channelId: String
  var threadTimestamp: String?
  var text: String
}

struct SlackMessage: Decodable, Equatable, Sendable {
  var type: String?
  var subtype: String?
  var user: String?
  var username: String?
  var botId: String?
  var text: String
  var ts: String
  var threadTimestamp: String?
  var files: [SlackFile]

  var isBotMessage: Bool {
    subtype == "bot_message" || botId != nil
  }

  var sortKey: Double {
    Double(ts) ?? 0
  }

  var timestampDate: Date? {
    guard let seconds = Double(ts) else {
      return nil
    }
    return Date(timeIntervalSince1970: seconds)
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case subtype
    case user
    case username
    case botId = "bot_id"
    case text
    case ts
    case threadTimestamp = "thread_ts"
    case files
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.type = try container.decodeIfPresent(String.self, forKey: .type)
    self.subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
    self.user = try container.decodeIfPresent(String.self, forKey: .user)
    self.username = try container.decodeIfPresent(String.self, forKey: .username)
    self.botId = try container.decodeIfPresent(String.self, forKey: .botId)
    self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    self.ts = try container.decode(String.self, forKey: .ts)
    self.threadTimestamp = try container.decodeIfPresent(String.self, forKey: .threadTimestamp)
    self.files = try container.decodeIfPresent([SlackFile].self, forKey: .files) ?? []
  }
}

struct SlackFile: Decodable, Equatable, Sendable {
  var id: String
  var name: String?
  var mimetype: String?
  var filetype: String?
  var urlPrivate: String?
  var size: Int?

  var normalizedDescriptor: JSONObject {
    compactSlackObject([
      "id": .string(id),
      "name": name.map(JSONValue.string),
      "mimetype": mimetype.map(JSONValue.string),
      "filetype": filetype.map(JSONValue.string),
      "urlPrivate": urlPrivate.map(JSONValue.string),
      "size": size.map { .number(Double($0)) }
    ])
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case mimetype
    case filetype
    case urlPrivate = "url_private"
    case size
  }
}

struct URLSessionSlackGatewayAPI: SlackGatewayAPI {
  func getMessages(request: SlackGetMessagesRequest) async throws -> [SlackMessage] {
    var components = URLComponents(string: "https://slack.com/api/conversations.history")
    var queryItems = [
      URLQueryItem(name: "channel", value: request.channelId),
      URLQueryItem(name: "limit", value: String(max(1, min(request.limit, 200))))
    ]
    if let oldestTimestamp = request.oldestTimestamp {
      queryItems.append(URLQueryItem(name: "oldest", value: oldestTimestamp))
      queryItems.append(URLQueryItem(name: "inclusive", value: "false"))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw CLIUsageError("failed to build Slack conversations.history URL")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.setValue("Bearer \(request.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    try validateSlackHTTPResponse(response, data: data, operation: "conversations.history")
    let decoded = try JSONDecoder().decode(SlackConversationsHistoryResponse.self, from: data)
    try decoded.validate(operation: "conversations.history")
    return decoded.messages ?? []
  }

  func sendMessage(request: SlackSendMessageRequest) async throws {
    guard let url = URL(string: "https://slack.com/api/chat.postMessage") else {
      throw CLIUsageError("failed to build Slack chat.postMessage URL")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(request.token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(SlackPostMessageBody(
      channel: request.channelId,
      threadTs: request.threadTimestamp,
      text: request.text
    ))
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    try validateSlackHTTPResponse(response, data: data, operation: "chat.postMessage")
    let decoded = try JSONDecoder().decode(SlackAPIStatusResponse.self, from: data)
    try decoded.validate(operation: "chat.postMessage")
  }

  private func validateSlackHTTPResponse(_ response: URLResponse, data: Data, operation: String) throws {
    guard let http = response as? HTTPURLResponse else {
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw CLIUsageError("Slack \(operation) failed with HTTP \(http.statusCode): \(body)")
    }
  }
}

private struct SlackConversationsHistoryResponse: Decodable {
  var status: SlackAPIStatusResponse
  var messages: [SlackMessage]?

  private enum CodingKeys: String, CodingKey {
    case messages
  }

  init(from decoder: Decoder) throws {
    self.status = try SlackAPIStatusResponse(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.messages = try container.decodeIfPresent([SlackMessage].self, forKey: .messages)
  }

  func validate(operation: String) throws {
    try status.validate(operation: operation)
  }
}

struct SlackAPIStatusResponse: Decodable, Equatable {
  var ok: Bool
  var error: String?

  func validate(operation: String) throws {
    guard ok else {
      throw CLIUsageError("Slack \(operation) failed: \(error ?? "unknown Slack API error")")
    }
  }
}

private struct SlackPostMessageBody: Encodable {
  var channel: String
  var threadTs: String?
  var text: String

  private enum CodingKeys: String, CodingKey {
    case channel
    case threadTs = "thread_ts"
    case text
  }
}

struct SlackConversationReply: Equatable, Sendable {
  var replyAs: String?
  var text: String
}

private struct SlackMessageOffsetStore {
  var eventRoot: URL
  var source: SlackGatewaySource
  var channelId: String

  func loadLastTimestamp() throws -> String? {
    let url = try offsetURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try JSONDecoder().decode(SlackOffsetRecord.self, from: Data(contentsOf: url)).lastTimestamp
  }

  func saveLastTimestamp(_ timestamp: String) throws {
    let url = try offsetURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(SlackOffsetRecord(lastTimestamp: timestamp)).write(to: url, options: .atomic)
  }

  private func offsetURL() throws -> URL {
    let relative = source.polling.offsetPath ?? "slack/\(source.id)-\(safeSlackStorageComponent(channelId))-offset.json"
    return try safeSlackEventRootRelativeURL(eventRoot: eventRoot, relativePath: relative)
  }
}

private struct SlackOffsetRecord: Codable {
  var lastTimestamp: String
}

private struct SlackConversationHistoryStore {
  private static let maxEntries = 80

  var eventRoot: URL
  var source: SlackGatewaySource

  func loadHistory(message: SlackMessage, channelId: String) -> [JSONObject] {
    let url = historyURL(message: message, channelId: channelId)
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let values = try? JSONDecoder().decode([JSONValue].self, from: data)
    else {
      return []
    }
    return values.compactMap { value in
      guard case let .object(object) = value else {
        return nil
      }
      return object
    }
  }

  func appendExchange(message: SlackMessage, channelId: String, replies: [SlackConversationReply]) throws {
    guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !replies.isEmpty else {
      return
    }
    let url = historyURL(message: message, channelId: channelId)
    var history = loadHistory(message: message, channelId: channelId)
    history.append(compactSlackObject([
      "role": .string("user"),
      "text": .string(message.text),
      "messageId": .string(message.ts),
      "senderId": message.user.map(JSONValue.string)
    ]))
    for reply in replies {
      history.append(compactSlackObject([
        "role": .string("assistant"),
        "text": .string(reply.text),
        "replyAs": reply.replyAs.map(JSONValue.string)
      ]))
    }
    history = Array(history.suffix(Self.maxEntries))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(history.map(JSONValue.object)).write(to: url, options: .atomic)
  }

  private func historyURL(message: SlackMessage, channelId: String) -> URL {
    eventRoot
      .appendingPathComponent("slack-history", isDirectory: true)
      .appendingPathComponent(safeSlackStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent("\(safeSlackStorageComponent(channelId))-\(safeSlackStorageComponent(message.threadTimestamp ?? message.ts)).json")
  }
}

private func slackEnvironmentValue(_ name: String, environment: [String: String]) -> String? {
  guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
    !value.isEmpty
  else {
    return nil
  }
  return value
}

private func safeSlackStorageComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = value.unicodeScalars.map { scalar in
    allowed.contains(scalar) ? Character(scalar) : "_"
  }
  let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
  return sanitized.isEmpty ? "unknown" : sanitized
}

private func safeSlackEventRootRelativeURL(eventRoot: URL, relativePath: String) throws -> URL {
  guard let normalizedPath = normalizedSlackEventRootRelativePath(relativePath) else {
    throw CLIUsageError("slack-gateway offsetPath must be event-root-relative: \(relativePath)")
  }
  let root = eventRoot.standardizedFileURL
  let url = root.appendingPathComponent(normalizedPath).standardizedFileURL
  guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
    throw CLIUsageError("slack-gateway offsetPath escapes event root: \(relativePath)")
  }
  return url
}

private func normalizedSlackEventRootRelativePath(_ rawPath: String) -> String? {
  guard !rawPath.isEmpty,
    !rawPath.hasPrefix("/"),
    rawPath.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil
  else {
    return nil
  }
  let segments = rawPath.replacingOccurrences(of: "\\", with: "/")
    .split(separator: "/", omittingEmptySubsequences: false)
  guard !segments.contains(where: { $0 == ".." }) else {
    return nil
  }
  let normalized = segments
    .filter { !$0.isEmpty && $0 != "." }
    .map(String.init)
    .joined(separator: "/")
  return normalized.isEmpty ? nil : normalized
}

private func compactSlackObject(_ fields: [String: JSONValue?]) -> JSONObject {
  fields.reduce(into: JSONObject()) { result, pair in
    if let value = pair.value {
      result[pair.key] = value
    }
  }
}
