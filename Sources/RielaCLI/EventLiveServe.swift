import Foundation
import RielaCore
import RielaEvents

protocol EventLiveServing: Sendable {
  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult
}

protocol TelegramGatewayAPI: Sendable {
  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate]
  func sendMessage(request: TelegramSendMessageRequest) async throws
}

protocol EventWorkflowRunning: Sendable {
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult
}

struct EventWorkflowRunRequest: Sendable {
  var workflowName: String
  var runtimeVariables: JSONObject
  var parsed: ParsedParityOptions
}

struct DefaultEventLiveServer: EventLiveServing {
  var telegramAPI: any TelegramGatewayAPI
  var workflowRunner: any EventWorkflowRunning

  init(
    telegramAPI: any TelegramGatewayAPI = URLSessionTelegramGatewayAPI(),
    workflowRunner: any EventWorkflowRunning = CLIEventWorkflowRunner()
  ) {
    self.telegramAPI = telegramAPI
    self.workflowRunner = workflowRunner
  }

  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult {
    let config = try EventLiveConfig.load(eventRoot: eventRoot)
    let enabledSources = config.sources.filter(\.enabled)
    let unsupported = enabledSources
      .filter { $0.kind != .telegramGateway }
      .map { "\($0.id):\($0.kind.rawValue)" }
      .joined(separator: ",")
    guard unsupported.isEmpty else {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: unsupported)
    }

    let telegramSources = try config.telegramSources(eventRoot: eventRoot)
    guard !telegramSources.isEmpty else {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: enabledSources.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ","))
    }

    try writeServeRecord(eventRoot: eventRoot, status: "ready")
    var processedEvents = 0
    let maximumEvents = parsed.limit
    repeat {
      for source in telegramSources {
        processedEvents += try await pollTelegramSource(source, config: config, eventRoot: eventRoot, parsed: parsed)
        if let maximumEvents, processedEvents >= maximumEvents {
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      if maximumEvents == nil {
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    } while maximumEvents == nil || processedEvents < (maximumEvents ?? 0)

    return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
  }

  private func pollTelegramSource(
    _ source: TelegramGatewaySource,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    let token = try source.token(environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    let offsetStore = TelegramOffsetStore(eventRoot: eventRoot, source: source)
    let offset = try offsetStore.loadOffset()
    let updates = try await telegramAPI.getUpdates(request: TelegramGetUpdatesRequest(
      token: token,
      offset: offset,
      timeoutSeconds: source.polling.timeoutSeconds,
      limit: parsed.limit ?? source.polling.limit
    ))
    var observedUpdates = 0
    let historyStore = TelegramConversationHistoryStore(eventRoot: eventRoot, source: source)
    for update in updates {
      observedUpdates += 1
      try offsetStore.saveOffset(update.updateId + 1)
      let history = try update.message.map { try historyStore.loadHistory(for: $0) } ?? []
      guard let envelope = source.envelope(from: update, eventRoot: eventRoot, history: history) else {
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
        let replies = try await dispatchTelegramReplies(
          result: result,
          source: source,
          envelope: envelope,
          sourceToken: token
        )
        if let message = update.message {
          try historyStore.append(message: message, replies: replies)
        }
      }
    }
    return observedUpdates
  }

  private func dispatchTelegramReplies(
    result: WorkflowRunResult,
    source: TelegramGatewaySource,
    envelope: ExternalEventEnvelope,
    sourceToken: String
  ) async throws -> [TelegramConversationReply] {
    let chatId = envelope.conversation?["id"]?.stringValue
    guard let chatId else {
      return []
    }
    let threadId = envelope.conversation?["threadId"]?.stringValue
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    var replies: [TelegramConversationReply] = []
    for execution in result.session.executions {
      guard execution.acceptedOutput?.payload["addon"] == .string("riela/chat-reply-worker"),
        let text = execution.acceptedOutput?.payload["text"]?.stringValue,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continue
      }
      let replyAs = execution.acceptedOutput?.payload["replyAs"]?.stringValue
      let token = source.replyToken(replyAs: replyAs, environment: environment) ?? sourceToken
      try await telegramAPI.sendMessage(request: TelegramSendMessageRequest(
        token: token,
        chatId: chatId,
        threadId: threadId,
        text: text
      ))
      replies.append(TelegramConversationReply(replyAs: replyAs, text: text))
    }
    return replies
  }

  private func liveUnavailable(eventRoot: URL, actionTarget: String?, unsupportedSources: String) -> ScopedParityCommandResult {
    ScopedParityCommandResult(
      scope: "events",
      command: "serve",
      target: actionTarget,
      status: "failed",
      records: [
        "eventRoot=\(eventRoot.path)",
        "mode=telegram-gateway-live",
        "status=unavailable",
        "unsupportedLiveSources=\(unsupportedSources)"
      ]
    )
  }

  private func liveReady(eventRoot: URL, actionTarget: String?, processedEvents: Int) -> ScopedParityCommandResult {
    ScopedParityCommandResult(
      scope: "events",
      command: "serve",
      target: actionTarget,
      status: "ok",
      records: [
        "eventRoot=\(eventRoot.path)",
        "mode=telegram-gateway-live",
        "status=ready",
        "processedEvents=\(processedEvents)"
      ]
    )
  }

  private func writeServeRecord(eventRoot: URL, status: String) throws {
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    try jsonString([
      "eventRoot": .string(eventRoot.path),
      "status": .string(status),
      "mode": .string("telegram-gateway-live")
    ] as JSONObject).write(
      to: eventRoot.appendingPathComponent("serve-record.json"),
      atomically: true,
      encoding: .utf8
    )
  }
}

struct CLIEventWorkflowRunner: EventWorkflowRunning {
  var command: WorkflowRunCommand

  init(command: WorkflowRunCommand = WorkflowRunCommand()) {
    self.command = command
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    let workingDirectory = request.parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let result = await command.run(WorkflowRunOptions(
      target: request.workflowName,
      resolution: WorkflowResolutionOptions(
        workflowName: request.workflowName,
        scope: request.parsed.scope,
        workflowDefinitionDir: request.parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory
      ),
      variables: try jsonString(request.runtimeVariables),
      mockScenarioPath: request.parsed.mockScenarioPath,
      output: .json,
      timeoutMs: request.parsed.timeoutMs,
      artifactRoot: request.parsed.artifactRoot,
      sessionStore: request.parsed.sessionStore,
      workingDirectory: workingDirectory
    ))
    guard result.exitCode == .success else {
      throw CLIUsageError(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
  }
}

struct EventLiveConfig: Sendable {
  var sources: [EventSourceContract]
  var bindings: [EventBindingContract]

  static func load(eventRoot: URL) throws -> EventLiveConfig {
    let configURL = eventRoot.appendingPathComponent("events.json")
    if FileManager.default.fileExists(atPath: configURL.path) {
      let decoded = try JSONDecoder().decode(EventLiveConfigFile.self, from: Data(contentsOf: configURL))
      return EventLiveConfig(sources: decoded.sources, bindings: decoded.bindings)
    }
    return EventLiveConfig(
      sources: try decodeDirectory(eventRoot.appendingPathComponent("sources", isDirectory: true), as: EventSourceContract.self),
      bindings: try decodeDirectory(eventRoot.appendingPathComponent("bindings", isDirectory: true), as: EventBindingContract.self)
    )
  }

  func telegramSources(eventRoot: URL) throws -> [TelegramGatewaySource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    return try Self.decodeDirectory(sourceDirectory, as: TelegramGatewaySource.self)
      .filter { source in
        boundSourceIds.contains(source.id)
          && sources.contains { $0.id == source.id && $0.enabled && $0.kind == .telegramGateway }
      }
  }

  private static func decodeDirectory<T: Decodable>(_ directory: URL, as type: T.Type) throws -> [T] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try JSONDecoder().decode(type, from: Data(contentsOf: $0)) }
  }
}

private struct EventLiveConfigFile: Codable {
  var sources: [EventSourceContract]
  var bindings: [EventBindingContract]
}

struct TelegramGatewaySource: Decodable, Equatable, Sendable {
  var id: String
  var tokenEnv: String?
  var botIdEnv: String?
  var chats: [TelegramGatewayChat]
  var polling: TelegramGatewayPolling
  var filters: TelegramGatewayFilters
  var replyBots: [String: TelegramGatewayReplyBot]

  private enum CodingKeys: String, CodingKey {
    case id
    case tokenEnv
    case botIdEnv
    case chats
    case polling
    case filters
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
    self.replyBots = try container.decodeIfPresent([String: TelegramGatewayReplyBot].self, forKey: .replyBots) ?? [:]
  }

  func token(environment: [String: String]) throws -> String {
    guard let token = environmentValue(tokenEnv ?? "RIELA_TELEGRAM_BOT_TOKEN", environment: environment) else {
      throw CLIUsageError("telegram-gateway source '\(id)' requires \(tokenEnv ?? "RIELA_TELEGRAM_BOT_TOKEN")")
    }
    return token
  }

  func replyToken(replyAs: String?, environment: [String: String]) -> String? {
    guard let replyAs,
      let tokenEnv = replyBots[replyAs]?.tokenEnv
    else {
      return nil
    }
    return environmentValue(tokenEnv, environment: environment)
  }

  func envelope(from update: TelegramUpdate, eventRoot: URL, history: [JSONValue] = []) -> ExternalEventEnvelope? {
    guard let message = update.message,
      let text = message.text,
      isAllowed(message: message, environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    else {
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
        "history": .array(history),
        "historySource": .string("live"),
        "attachments": .array([]),
        "imagePaths": .array([]),
        "attachmentText": .string(""),
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
    ["RIELA_TELEGRAM_CHAT_ID", "RIEL_TELEGRAM_CHAT_ID"].compactMap {
      environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }

  private func environmentValue(_ name: String, environment: [String: String]) -> String? {
    let candidates = name.hasPrefix("RIELA_")
      ? [name, "RIEL_" + name.dropFirst("RIELA_".count)]
      : [name]
    return candidates.lazy.compactMap { candidate in
      environment[String(candidate)]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.first { !$0.isEmpty }
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

struct TelegramGatewayReplyBot: Decodable, Equatable, Sendable {
  var tokenEnv: String?
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
  var from: TelegramSender?
  var chat: TelegramChat

  private enum CodingKeys: String, CodingKey {
    case messageId = "message_id"
    case messageThreadId = "message_thread_id"
    case date
    case text
    case from
    case chat
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.messageId = try container.decodeTelegramStringID(forKey: .messageId)
    self.messageThreadId = try container.decodeTelegramStringIDIfPresent(forKey: .messageThreadId)
    self.date = try container.decodeIfPresent(Int.self, forKey: .date)
    self.text = try container.decodeIfPresent(String.self, forKey: .text)
    self.from = try container.decodeIfPresent(TelegramSender.self, forKey: .from)
    self.chat = try container.decode(TelegramChat.self, forKey: .chat)
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
    return try JSONDecoder().decode(TelegramGetUpdatesResponse.self, from: data).result
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
    let (_, response) = try await URLSession.shared.data(for: urlRequest)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("Telegram sendMessage failed with HTTP \(http.statusCode)")
    }
  }
}

struct TelegramConversationReply: Equatable, Sendable {
  var replyAs: String?
  var text: String
}

private struct TelegramConversationHistoryStore {
  private static let maxEntries = 24

  var eventRoot: URL
  var source: TelegramGatewaySource

  func loadHistory(for message: TelegramMessage) throws -> [JSONValue] {
    let url = historyURL(for: message)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    let entries = try JSONDecoder().decode([TelegramConversationHistoryEntry].self, from: Data(contentsOf: url))
    return entries.suffix(Self.maxEntries).map(\.jsonValue)
  }

  func append(message: TelegramMessage, replies: [TelegramConversationReply]) throws {
    guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    let url = historyURL(for: message)
    let existing: [TelegramConversationHistoryEntry]
    if FileManager.default.fileExists(atPath: url.path) {
      existing = (try? JSONDecoder().decode([TelegramConversationHistoryEntry].self, from: Data(contentsOf: url))) ?? []
    } else {
      existing = []
    }
    let userEntry = TelegramConversationHistoryEntry(
      role: "user",
      actorId: message.from?.id,
      actorName: message.from?.displayName,
      replyAs: nil,
      text: text,
      timestamp: message.date
    )
    let replyEntries = replies.map { reply in
      TelegramConversationHistoryEntry(
        role: "assistant",
        actorId: nil,
        actorName: reply.replyAs,
        replyAs: reply.replyAs,
        text: reply.text,
        timestamp: Int(Date().timeIntervalSince1970)
      )
    }
    let entries = Array((existing + [userEntry] + replyEntries).suffix(Self.maxEntries))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(entries).write(to: url, options: .atomic)
  }

  private func historyURL(for message: TelegramMessage) -> URL {
    let thread = message.messageThreadId ?? "main"
    let filename = "\(safeHistoryComponent(message.chat.id))-\(safeHistoryComponent(thread)).json"
    return eventRoot
      .appendingPathComponent("telegram-history", isDirectory: true)
      .appendingPathComponent(safeHistoryComponent(source.id), isDirectory: true)
      .appendingPathComponent(filename)
  }

  private func safeHistoryComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = value.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return sanitized.isEmpty ? "unknown" : sanitized
  }
}

private struct TelegramConversationHistoryEntry: Codable, Equatable {
  var role: String
  var actorId: String?
  var actorName: String?
  var replyAs: String?
  var text: String
  var timestamp: Int?

  var jsonValue: JSONValue {
    .object(compactObject([
      "role": .string(role),
      "actorId": actorId.map { .string($0) },
      "actorName": actorName.map { .string($0) },
      "replyAs": replyAs.map { .string($0) },
      "text": .string(text),
      "timestamp": timestamp.map { .number(Double($0)) }
    ]))
  }
}

private struct TelegramGetUpdatesResponse: Decodable {
  var ok: Bool
  var result: [TelegramUpdate]
}

private struct TelegramOffsetStore {
  var eventRoot: URL
  var source: TelegramGatewaySource

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
    let relative = source.polling.offsetPath ?? "telegram/\(source.id)-offset.json"
    return eventRoot.appendingPathComponent(relative)
  }
}

private struct TelegramOffsetRecord: Codable {
  var offset: Int
}

private extension KeyedDecodingContainer {
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

private func compactObject(_ fields: [String: JSONValue?]) -> JSONObject {
  fields.reduce(into: JSONObject()) { result, pair in
    if let value = pair.value {
      result[pair.key] = value
    }
  }
}
