import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents

struct TelegramGatewaySource: Decodable, Equatable, Sendable {
  var id: String
  var tokenEnv: String?
  var botIdEnv: String?
  var chats: [TelegramGatewayChat]
  var polling: TelegramGatewayPolling
  var filters: TelegramGatewayFilters
  var attachments: TelegramGatewayAttachmentPolicy
  var replyBots: [String: TelegramGatewayReplyBot]

  private enum CodingKeys: String, CodingKey {
    case id
    case tokenEnv
    case botIdEnv
    case chats
    case polling
    case filters
    case attachments
    case replyBots
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.tokenEnv = try container.decodeIfPresent(String.self, forKey: .tokenEnv)
    self.botIdEnv = try container.decodeIfPresent(String.self, forKey: .botIdEnv)
    self.chats = try container.decodeIfPresent([TelegramGatewayChat].self, forKey: .chats) ?? []
    self.polling = try container.decodeIfPresent(TelegramGatewayPolling.self, forKey: .polling) ?? TelegramGatewayPolling()
    self.filters = try container.decodeIfPresent(TelegramGatewayFilters.self, forKey: .filters) ?? TelegramGatewayFilters()
    self.attachments = try container.decodeIfPresent(TelegramGatewayAttachmentPolicy.self, forKey: .attachments) ?? TelegramGatewayAttachmentPolicy()
    self.replyBots = try container.decodeIfPresent([String: TelegramGatewayReplyBot].self, forKey: .replyBots) ?? [:]
  }

  func token(environment: [String: String]) throws -> String {
    guard let token = environmentValue(tokenEnv ?? "RIELA_TELEGRAM_BOT_TOKEN", environment: environment) else {
      throw CLIUsageError("telegram-gateway source '\(id)' requires \(tokenEnv ?? "RIELA_TELEGRAM_BOT_TOKEN")")
    }
    return token
  }

  func validateEnvironment(environment: [String: String]) throws {
    _ = try pollingTargets(environment: environment)
    if let botIdEnv, environmentValue(botIdEnv, environment: environment) == nil {
      throw CLIUsageError("telegram-gateway source '\(id)' requires \(botIdEnv)")
    }
  }

  func pollingTargets(environment: [String: String]) throws -> [TelegramPollingTarget] {
    var targets = [TelegramPollingTarget(id: nil, token: try token(environment: environment))]
    for (replyAs, replyBot) in replyBots.sorted(by: { $0.key < $1.key }) {
      guard let tokenEnv = replyBot.tokenEnv else {
        continue
      }
      guard let token = environmentValue(tokenEnv, environment: environment) else {
        throw CLIUsageError("telegram-gateway source '\(id)' reply bot '\(replyAs)' requires \(tokenEnv)")
      }
      if !targets.contains(where: { $0.token == token }) {
        targets.append(TelegramPollingTarget(id: replyAs, token: token))
      }
    }
    return targets
  }

  func replyToken(replyAs: String?, environment: [String: String]) -> String? {
    guard let replyAs,
      let tokenEnv = replyBots[replyAs]?.tokenEnv
    else {
      return nil
    }
    return environmentValue(tokenEnv, environment: environment)
  }

  func envelope(
    from update: TelegramUpdate,
    eventRoot: URL,
    resolvedAttachments: EventResolvedAttachmentInputs = .empty
  ) -> ExternalEventEnvelope? {
    guard let message = update.message,
      isAllowed(message: message, environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    else {
      return nil
    }
    let text = message.displayText
    guard !text.isEmpty || !resolvedAttachments.attachments.isEmpty else {
      return nil
    }
    let chatId = message.chat.id
    return ExternalEventEnvelope(
      sourceId: id,
      eventId: String(update.updateId),
      provider: "telegram",
      eventType: "chat.message",
      receivedAt: Date(timeIntervalSince1970: TimeInterval(message.date ?? 0)),
      actor: compactObject([
        "id": message.from?.id.map { .string($0) },
        "displayName": message.from?.displayName.map { .string($0) },
        "username": message.from?.username.map { .string($0) },
        "isBot": message.from?.isBot.map { .bool($0) }
      ]),
      conversation: compactObject([
        "id": .string(chatId),
        "threadId": message.messageThreadId.map { .string($0) },
        "title": message.chat.title.map { .string($0) },
        "type": message.chat.type.map { .string($0) }
      ]),
      input: [
        "text": .string(text),
        "provider": .string("telegram"),
        "history": .array(
          TelegramConversationHistoryStore(eventRoot: eventRoot, source: self)
            .loadHistory(message: message)
            .map(JSONValue.object)
        ),
        "historySource": .string("chat-memory"),
        "attachments": .array(resolvedAttachments.attachments.map { .object($0) }),
        "imagePaths": .array(resolvedAttachments.imagePaths.map { .string($0) }),
        "attachmentText": .string(resolvedAttachments.attachmentText),
        "eventDataRoot": .string(eventRoot.path)
      ]
    )
  }

  private func isAllowed(message: TelegramMessage, environment: [String: String]) -> Bool {
    if filters.ignoreBots, message.from?.isBot == true {
      return false
    }
    if filters.ignoreSelf,
      let botIdEnv,
      let botId = environmentValue(botIdEnv, environment: environment),
      message.from?.id == botId {
      return false
    }
    let allowedChatIds = Set(chats.map(\.id) + chatIdOverrides(environment: environment))
    return allowedChatIds.isEmpty || allowedChatIds.contains(message.chat.id)
  }

  private func chatIdOverrides(environment: [String: String]) -> [String] {
    environment["RIELA_TELEGRAM_CHAT_ID"]
      .map { [$0.trimmingCharacters(in: .whitespacesAndNewlines)] }?
      .filter { !$0.isEmpty } ?? []
  }

  private func environmentValue(_ name: String, environment: [String: String]) -> String? {
    guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }
}

struct TelegramGatewayChat: Decodable, Equatable, Sendable {
  var id: String

  private enum CodingKeys: String, CodingKey {
    case id
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeTelegramStringID(forKey: .id)
  }
}

struct TelegramGatewayPolling: Decodable, Equatable, Sendable {
  var timeoutSeconds: Int
  var limit: Int
  var offsetPath: String?

  init(timeoutSeconds: Int = 30, limit: Int = 100, offsetPath: String? = nil) {
    self.timeoutSeconds = timeoutSeconds
    self.limit = limit
    self.offsetPath = offsetPath
  }
}

struct TelegramGatewayFilters: Decodable, Equatable, Sendable {
  var ignoreBots: Bool
  var ignoreSelf: Bool

  init(ignoreBots: Bool = true, ignoreSelf: Bool = true) {
    self.ignoreBots = ignoreBots
    self.ignoreSelf = ignoreSelf
  }
}

struct TelegramGatewayAttachmentPolicy: Decodable, Equatable, Sendable {
  var includePhotos: Bool
  var resolveFilePaths: Bool

  init(includePhotos: Bool = true, resolveFilePaths: Bool = false) {
    self.includePhotos = includePhotos
    self.resolveFilePaths = resolveFilePaths
  }
}

struct TelegramGatewayReplyBot: Decodable, Equatable, Sendable {
  var tokenEnv: String?
}

struct TelegramPollingTarget: Equatable, Sendable {
  var id: String?
  var token: String

  var recordId: String {
    id ?? "source"
  }
}

struct TelegramGetUpdatesRequest: Equatable, Sendable {
  var token: String
  var offset: Int?
  var timeoutSeconds: Int
  var limit: Int
}

struct TelegramSendMessageRequest: Equatable, Sendable {
  var token: String
  var chatId: String
  var threadId: String?
  var text: String
}

struct TelegramGetFileRequest: Equatable, Sendable {
  var token: String
  var fileId: String
}

struct TelegramDownloadFileRequest: Equatable, Sendable {
  var token: String
  var filePath: String
}

struct TelegramUpdate: Decodable, Equatable, Sendable {
  var updateId: Int
  var message: TelegramMessage?

  private enum CodingKeys: String, CodingKey {
    case updateId = "update_id"
    case message
  }
}

struct TelegramMessage: Decodable, Equatable, Sendable {
  var messageId: String
  var messageThreadId: String?
  var date: Int?
  var text: String?
  var caption: String?
  var photo: [TelegramPhotoSize]
  var from: TelegramSender?
  var chat: TelegramChat

  var displayText: String {
    (text ?? caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var largestPhoto: TelegramPhotoSize? {
    photo.max { lhs, rhs in
      lhs.sortSize < rhs.sortSize
    }
  }

  private enum CodingKeys: String, CodingKey {
    case messageId = "message_id"
    case messageThreadId = "message_thread_id"
    case date
    case text
    case caption
    case photo
    case from
    case chat
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.messageId = try container.decodeTelegramStringID(forKey: .messageId)
    self.messageThreadId = try container.decodeTelegramStringIDIfPresent(forKey: .messageThreadId)
    self.date = try container.decodeIfPresent(Int.self, forKey: .date)
    self.text = try container.decodeIfPresent(String.self, forKey: .text)
    self.caption = try container.decodeIfPresent(String.self, forKey: .caption)
    self.photo = try container.decodeIfPresent([TelegramPhotoSize].self, forKey: .photo) ?? []
    self.from = try container.decodeIfPresent(TelegramSender.self, forKey: .from)
    self.chat = try container.decode(TelegramChat.self, forKey: .chat)
  }
}

struct TelegramPhotoSize: Decodable, Equatable, Sendable {
  var fileId: String
  var fileUniqueId: String?
  var width: Int?
  var height: Int?
  var fileSize: Int?

  var normalizedDescriptor: JSONObject {
    compactObject([
      "kind": .string("photo"),
      "fileId": .string(fileId),
      "fileUniqueId": fileUniqueId.map(JSONValue.string),
      "width": width.map { .number(Double($0)) },
      "height": height.map { .number(Double($0)) },
      "fileSize": fileSize.map { .number(Double($0)) }
    ])
  }

  private enum CodingKeys: String, CodingKey {
    case fileId = "file_id"
    case fileUniqueId = "file_unique_id"
    case width
    case height
    case fileSize = "file_size"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.fileId = try container.decode(String.self, forKey: .fileId)
    self.fileUniqueId = try container.decodeIfPresent(String.self, forKey: .fileUniqueId)
    self.width = try container.decodeIfPresent(Int.self, forKey: .width)
    self.height = try container.decodeIfPresent(Int.self, forKey: .height)
    self.fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
  }

  var sortSize: Int {
    fileSize ?? ((width ?? 0) * (height ?? 0))
  }
}

struct TelegramChat: Decodable, Equatable, Sendable {
  var id: String
  var title: String?
  var type: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case type
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeTelegramStringID(forKey: .id)
    self.title = try container.decodeIfPresent(String.self, forKey: .title)
    self.type = try container.decodeIfPresent(String.self, forKey: .type)
  }
}

struct TelegramSender: Decodable, Equatable, Sendable {
  var id: String?
  var isBot: Bool?
  var firstName: String?
  var username: String?

  var displayName: String? {
    firstName ?? username
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case isBot = "is_bot"
    case firstName = "first_name"
    case username
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeTelegramStringIDIfPresent(forKey: .id)
    self.isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot)
    self.firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
    self.username = try container.decodeIfPresent(String.self, forKey: .username)
  }
}

struct URLSessionTelegramGatewayAPI: TelegramGatewayAPI {
  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate] {
    var components = URLComponents(string: "https://api.telegram.org/bot\(request.token)/getUpdates")
    var queryItems = [
      URLQueryItem(name: "timeout", value: String(request.timeoutSeconds)),
      URLQueryItem(name: "limit", value: String(request.limit))
    ]
    if let offset = request.offset {
      queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw CLIUsageError("failed to build Telegram getUpdates URL")
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    let decoded = try JSONDecoder().decode(TelegramGetUpdatesResponse.self, from: data)
    try decoded.validate(operation: "getUpdates")
    return decoded.result ?? []
  }

  func getFile(request: TelegramGetFileRequest) async throws -> TelegramFile {
    var components = URLComponents(string: "https://api.telegram.org/bot\(request.token)/getFile")
    components?.queryItems = [URLQueryItem(name: "file_id", value: request.fileId)]
    guard let url = components?.url else {
      throw CLIUsageError("failed to build Telegram getFile URL")
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    let decoded = try JSONDecoder().decode(TelegramGetFileResponse.self, from: data)
    try decoded.validate(operation: "getFile")
    guard let result = decoded.result else {
      throw CLIUsageError("Telegram getFile did not return a file")
    }
    return result
  }

  func downloadFile(request: TelegramDownloadFileRequest) async throws -> Data {
    guard let url = URL(string: "https://api.telegram.org/file/bot\(request.token)/\(request.filePath)") else {
      throw CLIUsageError("failed to build Telegram file URL")
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("Telegram file download failed with HTTP \(http.statusCode)")
    }
    return data
  }

  func sendMessage(request: TelegramSendMessageRequest) async throws {
    guard let url = URL(string: "https://api.telegram.org/bot\(request.token)/sendMessage") else {
      throw CLIUsageError("failed to build Telegram sendMessage URL")
    }
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "chat_id", value: request.chatId),
      URLQueryItem(name: "text", value: request.text)
    ]
    if let threadId = request.threadId {
      components.queryItems?.append(URLQueryItem(name: "message_thread_id", value: threadId))
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("Telegram sendMessage failed with HTTP \(http.statusCode)")
    }
    let decoded = try JSONDecoder().decode(TelegramAPIStatusResponse.self, from: data)
    try decoded.validate(operation: "sendMessage")
  }
}

struct TelegramFile: Decodable, Equatable, Sendable {
  var fileId: String
  var fileUniqueId: String?
  var fileSize: Int?
  var filePath: String?

  private enum CodingKeys: String, CodingKey {
    case fileId = "file_id"
    case fileUniqueId = "file_unique_id"
    case fileSize = "file_size"
    case filePath = "file_path"
  }
}

struct TelegramConversationReply: Equatable, Sendable {
  var replyAs: String?
  var text: String
}

struct TelegramAPIStatusResponse: Decodable, Equatable {
  var ok: Bool
  var errorCode: Int?
  var description: String?

  private enum CodingKeys: String, CodingKey {
    case ok
    case errorCode = "error_code"
    case description
  }

  func validate(operation: String) throws {
    guard ok else {
      let detail = description ?? errorCode.map { "error code \($0)" } ?? "unknown Telegram API error"
      throw CLIUsageError("Telegram \(operation) failed: \(detail)")
    }
  }
}

private struct TelegramGetUpdatesResponse: Decodable {
  var status: TelegramAPIStatusResponse
  var result: [TelegramUpdate]?

  var ok: Bool {
    status.ok
  }

  private enum CodingKeys: String, CodingKey {
    case result
  }

  init(from decoder: Decoder) throws {
    self.status = try TelegramAPIStatusResponse(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.result = try container.decodeIfPresent([TelegramUpdate].self, forKey: .result)
  }

  func validate(operation: String) throws {
    try status.validate(operation: operation)
  }
}

private struct TelegramGetFileResponse: Decodable {
  var status: TelegramAPIStatusResponse
  var result: TelegramFile?

  private enum CodingKeys: String, CodingKey {
    case result
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.result = try container.decodeIfPresent(TelegramFile.self, forKey: .result)
    self.status = try TelegramAPIStatusResponse(from: decoder)
  }

  func validate(operation: String) throws {
    try status.validate(operation: operation)
  }
}

struct TelegramOffsetStore {
  var eventRoot: URL
  var source: TelegramGatewaySource
  var targetId: String?

  func loadOffset() throws -> Int? {
    let url = offsetURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let record = try JSONDecoder().decode(TelegramOffsetRecord.self, from: Data(contentsOf: url))
    return record.offset
  }

  func saveOffset(_ offset: Int) throws {
    let url = offsetURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(TelegramOffsetRecord(offset: offset)).write(to: url, options: .atomic)
  }

  private func offsetURL() -> URL {
    let relative = offsetPathWithTarget(
      source.polling.offsetPath ?? "telegram/\(source.id)-offset.json",
      targetId: targetId
    )
    return eventRoot.appendingPathComponent(relative)
  }

  private func offsetPathWithTarget(_ relative: String, targetId: String?) -> String {
    guard let targetId else {
      return relative
    }
    let suffix = "-\(safeTelegramStorageComponent(targetId))"
    let slashIndex = relative.lastIndex(of: "/")
    let searchStart = slashIndex.map { relative.index(after: $0) } ?? relative.startIndex
    if let dotIndex = relative[searchStart...].lastIndex(of: ".") {
      return "\(relative[..<dotIndex])\(suffix)\(relative[dotIndex...])"
    }
    return relative + suffix
  }
}

private struct TelegramOffsetRecord: Codable {
  var offset: Int
}

struct TelegramMessageDedupeStore {
  private static let maxKeys = 512

  var eventRoot: URL
  var source: TelegramGatewaySource

  func hasSeen(message: TelegramMessage) throws -> Bool {
    try loadKeys().contains(key(for: message))
  }

  func markSeen(message: TelegramMessage) throws {
    let url = storeURL()
    var keys = try loadKeys()
    keys.append(key(for: message))
    var uniqueKeys: [String] = []
    var seenKeys = Set<String>()
    for key in keys.suffix(Self.maxKeys) where seenKeys.insert(key).inserted {
      uniqueKeys.append(key)
    }
    keys = uniqueKeys
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(TelegramMessageDedupeRecord(keys: keys)).write(to: url, options: .atomic)
  }

  private func loadKeys() throws -> [String] {
    let url = storeURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    return try JSONDecoder().decode(TelegramMessageDedupeRecord.self, from: Data(contentsOf: url)).keys
  }

  private func storeURL() -> URL {
    eventRoot
      .appendingPathComponent("telegram", isDirectory: true)
      .appendingPathComponent("\(safeTelegramStorageComponent(source.id))-seen-messages.json")
  }

  private func key(for message: TelegramMessage) -> String {
    if let contentKey = contentKey(for: message) {
      return contentKey
    }
    return [
      message.chat.id,
      message.messageThreadId ?? "main",
      message.messageId
    ].map(safeTelegramStorageComponent).joined(separator: ":")
  }

  private func contentKey(for message: TelegramMessage) -> String? {
    let text = message.displayText
    guard !text.isEmpty,
      let senderId = message.from?.id,
      let date = message.date
    else {
      return nil
    }
    return [
      message.chat.id,
      message.messageThreadId ?? "main",
      senderId,
      String(date),
      text
    ].map(safeTelegramStorageComponent).joined(separator: ":")
  }
}

private struct TelegramMessageDedupeRecord: Codable {
  var keys: [String]
}

struct TelegramConversationHistoryStore {
  private static let maxEntries = 80

  var eventRoot: URL
  var source: TelegramGatewaySource

  func loadHistory(message: TelegramMessage) -> [JSONObject] {
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

  func appendExchange(message: TelegramMessage, replies: [TelegramConversationReply]) throws {
    let text = message.displayText
    guard !text.isEmpty else {
      return
    }
    let url = historyURL(message: message)
    var history = loadHistory(message: message)
    history.append(compactObject([
      "role": .string("user"),
      "text": .string(text),
      "messageId": .string(message.messageId),
      "senderId": message.from?.id.map(JSONValue.string)
    ]))
    for reply in replies {
      history.append(compactObject([
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

  private func historyURL(message: TelegramMessage) -> URL {
    eventRoot
      .appendingPathComponent("telegram-history", isDirectory: true)
      .appendingPathComponent(safeTelegramStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent("\(safeTelegramStorageComponent(message.chat.id))-\(safeTelegramStorageComponent(message.messageThreadId ?? "main")).json")
  }
}

func safeTelegramStorageComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = value.unicodeScalars.map { scalar in
    allowed.contains(scalar) ? Character(scalar) : "_"
  }
  let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
  return sanitized.isEmpty ? "unknown" : sanitized
}

extension KeyedDecodingContainer {
  func decodeTelegramStringID(forKey key: Key) throws -> String {
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

  func decodeTelegramStringIDIfPresent(forKey key: Key) throws -> String? {
    guard contains(key) else {
      return nil
    }
    return try decodeTelegramStringID(forKey: key)
  }
}

func compactObject(_ fields: [String: JSONValue?]) -> JSONObject {
  fields.reduce(into: JSONObject()) { result, pair in
    if let value = pair.value {
      result[pair.key] = value
    }
  }
}
