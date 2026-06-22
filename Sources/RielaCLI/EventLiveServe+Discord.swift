import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents

protocol DiscordGatewayAPI: Sendable {
  func getMessages(request: DiscordGetMessagesRequest) async throws -> [DiscordMessage]
  func sendMessage(request: DiscordSendMessageRequest) async throws
}

extension DefaultEventLiveServer {
  func pollDiscordSource(
    _ source: DiscordGatewaySource,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    var observedMessages = 0
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let token = try source.token(environment: environment)
    let channelIds = source.channelIds(environment: environment)
    for channelId in channelIds {
      let offsetStore = DiscordMessageOffsetStore(eventRoot: eventRoot, source: source, channelId: channelId)
      let afterMessageId = try offsetStore.loadLastMessageId()
      let messages = try await discordAPI.getMessages(request: DiscordGetMessagesRequest(
        token: token,
        channelId: channelId,
        afterMessageId: afterMessageId,
        limit: parsed.limit ?? source.polling.limit
      ))
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: channelId,
        pollingTargetCount: channelIds.count,
        lastUpdateCount: messages.count
      )
      for message in messages.sorted(by: { $0.sortKey < $1.sortKey }) {
        observedMessages += 1
        try offsetStore.saveLastMessageId(message.id)
        guard let envelope = source.envelope(from: message, eventRoot: eventRoot) else {
          continue
        }
        let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
          sources: config.sources,
          bindings: config.bindings,
          envelope: envelope
        ))
        guard triggerResult.accepted else {
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
          let replies = try await dispatchDiscordReplies(result: result, source: source, envelope: envelope, sourceToken: token)
          try DiscordConversationHistoryStore(eventRoot: eventRoot, source: source).appendExchange(message: message, replies: replies)
          if !replies.isEmpty {
            try? writeServeRecord(
              eventRoot: eventRoot,
              status: "ready",
              lastReplyDispatchCount: replies.count,
              lastReplyAs: replies.compactMap(\.replyAs).joined(separator: ",")
            )
          }
        }
      }
    }
    return observedMessages
  }

  private func dispatchDiscordReplies(
    result: WorkflowRunResult,
    source: DiscordGatewaySource,
    envelope: ExternalEventEnvelope,
    sourceToken: String
  ) async throws -> [DiscordConversationReply] {
    let channelId = envelope.conversation?["threadId"]?.stringValue ?? envelope.conversation?["id"]?.stringValue
    guard let channelId else {
      return []
    }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    var replies: [DiscordConversationReply] = []
    for execution in result.session.executions {
      guard execution.acceptedOutput?.payload["addon"] == .string("riela/chat-reply-worker"),
        let text = execution.acceptedOutput?.payload["text"]?.stringValue,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continue
      }
      let replyAs = execution.acceptedOutput?.payload["replyAs"]?.stringValue
      let token = source.replyToken(replyAs: replyAs, environment: environment) ?? sourceToken
      try await discordAPI.sendMessage(request: DiscordSendMessageRequest(token: token, channelId: channelId, text: text))
      replies.append(DiscordConversationReply(replyAs: replyAs, text: text))
    }
    return replies
  }
}

extension EventLiveConfig {
  func discordSources(eventRoot: URL) throws -> [DiscordGatewaySource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .discordGateway && boundSourceIds.contains(source.id)
    }.map(\.id))
    return try decodeDiscordSourceDirectory(sourceDirectory, sourceIds: sourceIds)
  }

  private func decodeDiscordSourceDirectory(_ directory: URL, sourceIds: Set<String>) throws -> [DiscordGatewaySource] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        let data = try Data(contentsOf: url)
        let contract = try JSONDecoder().decode(EventSourceContract.self, from: data)
        guard sourceIds.contains(contract.id) else {
          return nil
        }
        return try JSONDecoder().decode(DiscordGatewaySource.self, from: data)
      }
  }
}

struct DiscordGatewaySource: Decodable, Equatable, Sendable {
  var id: String
  var tokenEnv: String?
  var applicationIdEnv: String?
  var guildIds: [String]
  var channels: [DiscordGatewayChannel]
  var polling: DiscordGatewayPolling
  var filters: DiscordGatewayFilters
  var attachments: DiscordGatewayAttachmentPolicy
  var replyBots: [String: DiscordGatewayReplyBot]

  private enum CodingKeys: String, CodingKey {
    case id
    case tokenEnv
    case applicationIdEnv
    case guildIds
    case channels
    case polling
    case filters
    case attachments
    case replyBots
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.tokenEnv = try container.decodeIfPresent(String.self, forKey: .tokenEnv)
    self.applicationIdEnv = try container.decodeIfPresent(String.self, forKey: .applicationIdEnv)
    self.guildIds = try container.decodeIfPresent([String].self, forKey: .guildIds) ?? []
    self.channels = try container.decodeIfPresent([DiscordGatewayChannel].self, forKey: .channels) ?? []
    self.polling = try container.decodeIfPresent(DiscordGatewayPolling.self, forKey: .polling) ?? DiscordGatewayPolling()
    self.filters = try container.decodeIfPresent(DiscordGatewayFilters.self, forKey: .filters) ?? DiscordGatewayFilters()
    self.attachments = try container.decodeIfPresent(DiscordGatewayAttachmentPolicy.self, forKey: .attachments) ?? DiscordGatewayAttachmentPolicy()
    self.replyBots = try container.decodeIfPresent([String: DiscordGatewayReplyBot].self, forKey: .replyBots) ?? [:]
  }

  func token(environment: [String: String]) throws -> String {
    guard let token = discordEnvironmentValue(tokenEnv ?? "RIELA_DISCORD_BOT_TOKEN", environment: environment) else {
      throw CLIUsageError("discord-gateway source '\(id)' requires \(tokenEnv ?? "RIELA_DISCORD_BOT_TOKEN")")
    }
    return token
  }

  func validateEnvironment(environment: [String: String]) throws {
    _ = try token(environment: environment)
    if let applicationIdEnv, discordEnvironmentValue(applicationIdEnv, environment: environment) == nil {
      throw CLIUsageError("discord-gateway source '\(id)' requires \(applicationIdEnv)")
    }
    for (replyAs, replyBot) in replyBots.sorted(by: { $0.key < $1.key }) {
      guard let tokenEnv = replyBot.tokenEnv else {
        continue
      }
      guard discordEnvironmentValue(tokenEnv, environment: environment) != nil else {
        throw CLIUsageError("discord-gateway source '\(id)' reply bot '\(replyAs)' requires \(tokenEnv)")
      }
    }
    if channelIds(environment: environment).isEmpty {
      throw CLIUsageError("discord-gateway source '\(id)' requires at least one channel id")
    }
  }

  func channelIds(environment: [String: String]) -> [String] {
    let overrides = ["RIELA_DISCORD_CHANNEL_ID", "RIEL_DISCORD_CHANNEL_ID"].compactMap {
      environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    if !overrides.isEmpty {
      return Array(Set(overrides)).sorted()
    }
    return channels.map(\.id)
  }

  func replyToken(replyAs: String?, environment: [String: String]) -> String? {
    guard let replyAs,
      let tokenEnv = replyBots[replyAs]?.tokenEnv
    else {
      return nil
    }
    return discordEnvironmentValue(tokenEnv, environment: environment)
  }

  func envelope(from message: DiscordMessage, eventRoot: URL) -> ExternalEventEnvelope? {
    guard isAllowed(message: message),
      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty
    else {
      return nil
    }
    return ExternalEventEnvelope(
      sourceId: id,
      eventId: message.id,
      provider: "discord",
      eventType: "chat.message",
      receivedAt: message.timestampDate ?? Date(),
      actor: message.author.map { author in
        compactDiscordObject([
          "id": .string(author.id),
          "displayName": .string(author.displayName),
          "username": .string(author.username),
          "isBot": .bool(author.bot ?? false)
        ])
      },
      conversation: compactDiscordObject([
        "id": .string(message.channelId),
        "guildId": message.guildId.map(JSONValue.string)
      ]),
      input: [
        "text": .string(message.content),
        "provider": .string("discord"),
        "history": .array(DiscordConversationHistoryStore(eventRoot: eventRoot, source: self).loadHistory(message: message).map(JSONValue.object)),
        "historySource": .string("chat-memory"),
        "attachments": .array(message.attachments.map { .object($0.normalizedDescriptor) }),
        "imagePaths": .array([]),
        "attachmentText": .string(""),
        "eventDataRoot": .string(eventRoot.path)
      ]
    )
  }

  private func isAllowed(message: DiscordMessage) -> Bool {
    if filters.ignoreBots, message.author?.bot == true {
      return false
    }
    return true
  }
}

struct DiscordGatewayChannel: Decodable, Equatable, Sendable {
  var id: String
  var includeThreads: Bool
  var personas: [String]

  private enum CodingKeys: String, CodingKey {
    case id
    case includeThreads
    case personas
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeDiscordStringID(forKey: .id)
    self.includeThreads = try container.decodeIfPresent(Bool.self, forKey: .includeThreads) ?? false
    self.personas = try container.decodeIfPresent([String].self, forKey: .personas) ?? []
  }
}

struct DiscordGatewayPolling: Decodable, Equatable, Sendable {
  var limit: Int
  var offsetPath: String?

  init(limit: Int = 10, offsetPath: String? = nil) {
    self.limit = limit
    self.offsetPath = offsetPath
  }
}

struct DiscordGatewayFilters: Decodable, Equatable, Sendable {
  var ignoreBots: Bool
  var ignoreSelf: Bool
  var requireMention: Bool

  init(ignoreBots: Bool = true, ignoreSelf: Bool = true, requireMention: Bool = false) {
    self.ignoreBots = ignoreBots
    self.ignoreSelf = ignoreSelf
    self.requireMention = requireMention
  }
}

struct DiscordGatewayAttachmentPolicy: Decodable, Equatable, Sendable {
  var includeImages: Bool
  var resolveFilePaths: Bool
  var maxBytes: Int?

  init(includeImages: Bool = true, resolveFilePaths: Bool = false, maxBytes: Int? = nil) {
    self.includeImages = includeImages
    self.resolveFilePaths = resolveFilePaths
    self.maxBytes = maxBytes
  }
}

struct DiscordGatewayReplyBot: Decodable, Equatable, Sendable {
  var tokenEnv: String?
}

struct DiscordGetMessagesRequest: Equatable, Sendable {
  var token: String
  var channelId: String
  var afterMessageId: String?
  var limit: Int
}

struct DiscordSendMessageRequest: Equatable, Sendable {
  var token: String
  var channelId: String
  var text: String
}

struct DiscordMessage: Decodable, Equatable, Sendable {
  var id: String
  var channelId: String
  var guildId: String?
  var content: String
  var timestamp: String?
  var author: DiscordUser?
  var attachments: [DiscordAttachment]

  var sortKey: UInt64 {
    UInt64(id) ?? 0
  }

  var timestampDate: Date? {
    guard let timestamp else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case channelId = "channel_id"
    case guildId = "guild_id"
    case content
    case timestamp
    case author
    case attachments
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeDiscordStringID(forKey: .id)
    self.channelId = try container.decodeDiscordStringID(forKey: .channelId)
    self.guildId = try container.decodeDiscordStringIDIfPresent(forKey: .guildId)
    self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
    self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    self.author = try container.decodeIfPresent(DiscordUser.self, forKey: .author)
    self.attachments = try container.decodeIfPresent([DiscordAttachment].self, forKey: .attachments) ?? []
  }
}

struct DiscordUser: Decodable, Equatable, Sendable {
  var id: String
  var username: String
  var globalName: String?
  var bot: Bool?

  var displayName: String {
    globalName ?? username
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case username
    case globalName = "global_name"
    case bot
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeDiscordStringID(forKey: .id)
    self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? id
    self.globalName = try container.decodeIfPresent(String.self, forKey: .globalName)
    self.bot = try container.decodeIfPresent(Bool.self, forKey: .bot)
  }
}

struct DiscordAttachment: Decodable, Equatable, Sendable {
  var id: String
  var filename: String
  var contentType: String?
  var size: Int?
  var url: String?
  var width: Int?
  var height: Int?

  var normalizedDescriptor: JSONObject {
    compactDiscordObject([
      "id": .string(id),
      "filename": .string(filename),
      "contentType": contentType.map(JSONValue.string),
      "size": size.map { .number(Double($0)) },
      "url": url.map(JSONValue.string),
      "width": width.map { .number(Double($0)) },
      "height": height.map { .number(Double($0)) }
    ])
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case filename
    case contentType = "content_type"
    case size
    case url
    case width
    case height
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeDiscordStringID(forKey: .id)
    self.filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? id
    self.contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
    self.size = try container.decodeIfPresent(Int.self, forKey: .size)
    self.url = try container.decodeIfPresent(String.self, forKey: .url)
    self.width = try container.decodeIfPresent(Int.self, forKey: .width)
    self.height = try container.decodeIfPresent(Int.self, forKey: .height)
  }
}

struct URLSessionDiscordGatewayAPI: DiscordGatewayAPI {
  func getMessages(request: DiscordGetMessagesRequest) async throws -> [DiscordMessage] {
    var components = URLComponents(string: "https://discord.com/api/v10/channels/\(request.channelId)/messages")
    var queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(request.limit, 100))))]
    if let afterMessageId = request.afterMessageId {
      queryItems.append(URLQueryItem(name: "after", value: afterMessageId))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw CLIUsageError("failed to build Discord messages URL")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.setValue("Bot \(request.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    try validateDiscordHTTPResponse(response, data: data, operation: "get channel messages")
    return try JSONDecoder().decode([DiscordMessage].self, from: data)
  }

  func sendMessage(request: DiscordSendMessageRequest) async throws {
    guard let url = URL(string: "https://discord.com/api/v10/channels/\(request.channelId)/messages") else {
      throw CLIUsageError("failed to build Discord sendMessage URL")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bot \(request.token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(DiscordCreateMessageBody(content: request.text))
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    try validateDiscordHTTPResponse(response, data: data, operation: "create message")
  }

  private func validateDiscordHTTPResponse(_ response: URLResponse, data: Data, operation: String) throws {
    guard let http = response as? HTTPURLResponse else {
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw CLIUsageError("Discord \(operation) failed with HTTP \(http.statusCode): \(body)")
    }
  }
}

private struct DiscordCreateMessageBody: Encodable {
  var content: String
}

struct DiscordConversationReply: Equatable, Sendable {
  var replyAs: String?
  var text: String
}

private struct DiscordMessageOffsetStore {
  var eventRoot: URL
  var source: DiscordGatewaySource
  var channelId: String

  func loadLastMessageId() throws -> String? {
    let url = offsetURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try JSONDecoder().decode(DiscordOffsetRecord.self, from: Data(contentsOf: url)).lastMessageId
  }

  func saveLastMessageId(_ messageId: String) throws {
    let url = offsetURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(DiscordOffsetRecord(lastMessageId: messageId)).write(to: url, options: .atomic)
  }

  private func offsetURL() -> URL {
    let relative = source.polling.offsetPath ?? "discord/\(source.id)-\(safeDiscordStorageComponent(channelId))-offset.json"
    return eventRoot.appendingPathComponent(relative)
  }
}

private struct DiscordOffsetRecord: Codable {
  var lastMessageId: String
}

private struct DiscordConversationHistoryStore {
  private static let maxEntries = 80

  var eventRoot: URL
  var source: DiscordGatewaySource

  func loadHistory(message: DiscordMessage) -> [JSONObject] {
    let url = historyURL(message: message)
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

  func appendExchange(message: DiscordMessage, replies: [DiscordConversationReply]) throws {
    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !replies.isEmpty else {
      return
    }
    let url = historyURL(message: message)
    var history = loadHistory(message: message)
    history.append(compactDiscordObject([
      "role": .string("user"),
      "text": .string(message.content),
      "messageId": .string(message.id),
      "senderId": message.author.map { .string($0.id) }
    ]))
    for reply in replies {
      history.append(compactDiscordObject([
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

  private func historyURL(message: DiscordMessage) -> URL {
    eventRoot
      .appendingPathComponent("discord-history", isDirectory: true)
      .appendingPathComponent(safeDiscordStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent("\(safeDiscordStorageComponent(message.channelId)).json")
  }
}

private func discordEnvironmentValue(_ name: String, environment: [String: String]) -> String? {
  let candidates = name.hasPrefix("RIELA_")
    ? [name, "RIEL_" + name.dropFirst("RIELA_".count)]
    : [name]
  return candidates.lazy.compactMap { candidate in
    environment[String(candidate)]?.trimmingCharacters(in: .whitespacesAndNewlines)
  }.first { !$0.isEmpty }
}

private func safeDiscordStorageComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = value.unicodeScalars.map { scalar in
    allowed.contains(scalar) ? Character(scalar) : "_"
  }
  let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
  return sanitized.isEmpty ? "unknown" : sanitized
}

private func compactDiscordObject(_ fields: [String: JSONValue?]) -> JSONObject {
  fields.reduce(into: JSONObject()) { result, pair in
    if let value = pair.value {
      result[pair.key] = value
    }
  }
}

private extension KeyedDecodingContainer {
  func decodeDiscordStringID(forKey key: Key) throws -> String {
    if let string = try? decode(String.self, forKey: key) {
      return string
    }
    if let int = try? decode(Int64.self, forKey: key) {
      return String(int)
    }
    throw DecodingError.typeMismatch(
      String.self,
      DecodingError.Context(codingPath: codingPath + [key], debugDescription: "expected string or integer id")
    )
  }

  func decodeDiscordStringIDIfPresent(forKey key: Key) throws -> String? {
    guard contains(key) else {
      return nil
    }
    return try decodeDiscordStringID(forKey: key)
  }
}
