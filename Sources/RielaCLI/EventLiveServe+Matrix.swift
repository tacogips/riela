import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents

protocol MatrixGatewayAPI: Sendable {
  func sync(request: MatrixSyncRequest) async throws -> MatrixSyncResponse
  func downloadAttachment(request: MatrixDownloadAttachmentRequest) async throws -> Data
  func sendMessage(request: MatrixSendMessageRequest) async throws
}

extension DefaultEventLiveServer {
  func pollMatrixSource(
    _ source: MatrixGatewaySource,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let homeserverURL = try source.homeserverURL(environment: environment)
    let sourceToken = try source.accessToken(environment: environment)
    let sinceStore = try MatrixSinceTokenStore(eventRoot: eventRoot, source: source)
    let response: MatrixSyncResponse
    do {
      response = try await matrixAPI.sync(request: MatrixSyncRequest(
        homeserverURL: homeserverURL,
        accessToken: sourceToken,
        since: try sinceStore.load(),
        timeoutMilliseconds: source.sync.pollTimeoutMs
      ))
    } catch {
      throw EventLiveSourcePollFailure(error)
    }

    let configuredRoomIds = Set(source.rooms.map(\.roomId))
    var observedMessages = 0
    for (roomId, joinedRoom) in response.rooms?.join.sorted(by: { $0.key < $1.key }) ?? [] {
      guard configuredRoomIds.isEmpty || configuredRoomIds.contains(roomId) else {
        continue
      }
      for event in joinedRoom.timeline.events {
        let resolvedAttachments = try await resolveMatrixAttachments(
          source: source,
          event: event,
          roomId: roomId,
          eventRoot: eventRoot,
          homeserverURL: homeserverURL,
          sourceToken: sourceToken
        )
        guard let envelope = source.envelope(
          from: event,
          roomId: roomId,
          eventRoot: eventRoot,
          resolvedAttachments: resolvedAttachments
        ) else {
          continue
        }
        observedMessages += 1
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
          let replies = try await dispatchMatrixReplies(
            result: result,
            source: source,
            envelope: envelope,
            homeserverURL: homeserverURL,
            sourceToken: sourceToken
          )
          try MatrixConversationHistoryStore(eventRoot: eventRoot, source: source).appendExchange(
            event: event,
            roomId: roomId,
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
      }
    }
    try sinceStore.save(response.nextBatch)
    try? writeServeRecord(
      eventRoot: eventRoot,
      status: "ready",
      pollingTarget: source.id,
      pollingTargetCount: source.rooms.count,
      lastUpdateCount: observedMessages
    )
    return observedMessages
  }

  private func resolveMatrixAttachments(
    source: MatrixGatewaySource,
    event: MatrixRoomEvent,
    roomId: String,
    eventRoot: URL,
    homeserverURL: URL,
    sourceToken: String
  ) async throws -> EventResolvedAttachmentInputs {
    guard source.attachments.downloadText,
      let attachment = event.content.textAttachment,
      source.attachments.allowedMimeTypes.contains(attachment.mimeType)
    else {
      return .empty
    }
    if let declaredSize = attachment.size, declaredSize > source.attachments.maxBytes {
      return .empty
    }
    let data = try await matrixAPI.downloadAttachment(request: MatrixDownloadAttachmentRequest(
      homeserverURL: homeserverURL,
      accessToken: sourceToken,
      mxcURL: attachment.mxcURL
    ))
    guard data.count <= source.attachments.maxBytes,
      let text = String(data: data, encoding: .utf8)
    else {
      return .empty
    }
    let localURL = eventRoot
      .appendingPathComponent("attachments", isDirectory: true)
      .appendingPathComponent("matrix", isDirectory: true)
      .appendingPathComponent(safeMatrixStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent(safeMatrixStorageComponent(roomId), isDirectory: true)
      .appendingPathComponent(
        "\(safeMatrixStorageComponent(event.eventId))-\(safeMatrixStorageComponent(attachment.filename))"
      )
    try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: localURL, options: .atomic)
    return EventResolvedAttachmentInputs(
      attachments: [[
        "filename": .string(attachment.filename),
        "contentType": .string(attachment.mimeType),
        "size": .number(Double(data.count)),
        "url": .string(attachment.mxcURL),
        "path": .string(localURL.path)
      ]],
      imagePaths: [],
      attachmentText: text
    )
  }

  private func dispatchMatrixReplies(
    result: WorkflowRunResult,
    source: MatrixGatewaySource,
    envelope: ExternalEventEnvelope,
    homeserverURL: URL,
    sourceToken: String
  ) async throws -> [MatrixConversationReply] {
    guard let roomId = envelope.conversation?["id"]?.stringValue else {
      return []
    }
    let threadEventId = envelope.conversation?["threadId"]?.stringValue
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    var replies: [MatrixConversationReply] = []
    for execution in result.session.executions {
      guard execution.acceptedOutput?.payload["addon"] == .string("riela/chat-reply-worker"),
        let text = execution.acceptedOutput?.payload["text"]?.stringValue,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continue
      }
      let replyAs = execution.acceptedOutput?.payload["replyAs"]?.stringValue
      let token = source.replyToken(replyAs: replyAs, environment: environment) ?? sourceToken
      try await matrixAPI.sendMessage(request: MatrixSendMessageRequest(
        homeserverURL: homeserverURL,
        accessToken: token,
        roomId: roomId,
        transactionId: UUID().uuidString,
        text: text,
        threadEventId: threadEventId
      ))
      replies.append(MatrixConversationReply(replyAs: replyAs, text: text))
    }
    return replies
  }
}

extension EventLiveConfig {
  func matrixSources(eventRoot: URL) throws -> [MatrixGatewaySource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .matrix && boundSourceIds.contains(source.id)
    }.map(\.id))
    guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        let data = try Data(contentsOf: url)
        let contract = try JSONDecoder().decode(EventSourceContract.self, from: data)
        guard sourceIds.contains(contract.id) else {
          return nil
        }
        return try JSONDecoder().decode(MatrixGatewaySource.self, from: data)
      }
  }
}

struct MatrixGatewaySource: Decodable, Equatable, Sendable {
  var id: String
  var homeserverUrlEnv: String?
  var accessTokenEnv: String?
  var userId: String
  var rooms: [MatrixGatewayRoom]
  var sync: MatrixGatewaySync
  var history: MatrixGatewayHistory
  var attachments: MatrixGatewayAttachmentPolicy
  var replyBots: [String: MatrixGatewayReplyBot]

  private enum CodingKeys: String, CodingKey {
    case id
    case homeserverUrlEnv
    case accessTokenEnv
    case userId
    case rooms
    case sync
    case history
    case attachments
    case replyBots
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.homeserverUrlEnv = try container.decodeIfPresent(String.self, forKey: .homeserverUrlEnv)
    self.accessTokenEnv = try container.decodeIfPresent(String.self, forKey: .accessTokenEnv)
    self.userId = try container.decode(String.self, forKey: .userId)
    self.rooms = try container.decodeIfPresent([MatrixGatewayRoom].self, forKey: .rooms) ?? []
    self.sync = try container.decodeIfPresent(MatrixGatewaySync.self, forKey: .sync) ?? MatrixGatewaySync()
    self.history = try container.decodeIfPresent(MatrixGatewayHistory.self, forKey: .history) ?? MatrixGatewayHistory()
    self.attachments = try container.decodeIfPresent(MatrixGatewayAttachmentPolicy.self, forKey: .attachments)
      ?? MatrixGatewayAttachmentPolicy()
    self.replyBots = try container.decodeIfPresent([String: MatrixGatewayReplyBot].self, forKey: .replyBots) ?? [:]
  }

  func validateEnvironment(environment: [String: String]) throws {
    _ = try homeserverURL(environment: environment)
    _ = try accessToken(environment: environment)
    guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIUsageError("matrix source '\(id)' requires userId")
    }
    guard !rooms.isEmpty else {
      throw CLIUsageError("matrix source '\(id)' requires at least one room")
    }
    for (replyAs, replyBot) in replyBots.sorted(by: { $0.key < $1.key }) {
      guard let environmentName = replyBot.accessTokenEnv else {
        continue
      }
      guard matrixEnvironmentValue(environmentName, environment: environment) != nil else {
        throw CLIUsageError("matrix source '\(id)' reply bot '\(replyAs)' requires \(environmentName)")
      }
    }
  }

  func homeserverURL(environment: [String: String]) throws -> URL {
    let environmentName = homeserverUrlEnv ?? "RIELA_MATRIX_HOMESERVER_URL"
    guard let rawValue = matrixEnvironmentValue(environmentName, environment: environment),
      let url = URL(string: rawValue),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      url.host != nil
    else {
      throw CLIUsageError("matrix source '\(id)' requires a valid \(environmentName)")
    }
    return url
  }

  func accessToken(environment: [String: String]) throws -> String {
    let environmentName = accessTokenEnv ?? "RIELA_MATRIX_ACCESS_TOKEN"
    guard let token = matrixEnvironmentValue(environmentName, environment: environment) else {
      throw CLIUsageError("matrix source '\(id)' requires \(environmentName)")
    }
    return token
  }

  func replyToken(replyAs: String?, environment: [String: String]) -> String? {
    guard let replyAs,
      let environmentName = replyBots[replyAs]?.accessTokenEnv
    else {
      return nil
    }
    return matrixEnvironmentValue(environmentName, environment: environment)
  }

  func envelope(
    from event: MatrixRoomEvent,
    roomId: String,
    eventRoot: URL,
    resolvedAttachments: EventResolvedAttachmentInputs = .empty
  ) -> ExternalEventEnvelope? {
    guard event.type == "m.room.message",
      event.sender != userId || history.includeOwnMessages,
      let body = event.content.body?.trimmingCharacters(in: .whitespacesAndNewlines),
      !body.isEmpty || !resolvedAttachments.attachments.isEmpty
    else {
      return nil
    }
    let threadEventId = event.content.relatesTo?.relType == "m.thread"
      ? event.content.relatesTo?.eventId
      : nil
    var conversation: JSONObject = ["id": .string(roomId)]
    if let threadEventId {
      conversation["threadId"] = .string(threadEventId)
    }
    return ExternalEventEnvelope(
      sourceId: id,
      eventId: event.eventId,
      provider: "matrix",
      eventType: "chat.message",
      receivedAt: event.receivedAt,
      actor: [
        "id": .string(event.sender),
        "displayName": .string(event.sender),
        "isBot": .bool(event.sender == userId)
      ],
      conversation: conversation,
      input: [
        "text": .string(body),
        "provider": .string("matrix"),
        "history": .array(MatrixConversationHistoryStore(eventRoot: eventRoot, source: self)
          .loadHistory(roomId: roomId, threadEventId: threadEventId)
          .map(JSONValue.object)),
        "historySource": .string("chat-memory"),
        "attachments": .array(resolvedAttachments.attachments.map(JSONValue.object)),
        "imagePaths": .array(resolvedAttachments.imagePaths.map(JSONValue.string)),
        "attachmentText": .string(resolvedAttachments.attachmentText),
        "eventDataRoot": .string(eventRoot.path)
      ]
    )
  }
}

struct MatrixGatewayRoom: Decodable, Equatable, Sendable {
  var roomId: String
  var alias: String?
}

struct MatrixGatewaySync: Decodable, Equatable, Sendable {
  var pollTimeoutMs: Int
  var sinceTokenPath: String?

  init(pollTimeoutMs: Int = 30_000, sinceTokenPath: String? = nil) {
    self.pollTimeoutMs = max(0, min(pollTimeoutMs, 60_000))
    self.sinceTokenPath = sinceTokenPath
  }

  private enum CodingKeys: String, CodingKey {
    case pollTimeoutMs
    case sinceTokenPath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      pollTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .pollTimeoutMs) ?? 30_000,
      sinceTokenPath: try container.decodeIfPresent(String.self, forKey: .sinceTokenPath)
    )
  }
}

struct MatrixGatewayHistory: Decodable, Equatable, Sendable {
  var maxMessages: Int
  var maxBytes: Int
  var maxAgeMs: Int64
  var scope: String
  var includeOwnMessages: Bool

  init(
    maxMessages: Int = 80,
    maxBytes: Int = 131_072,
    maxAgeMs: Int64 = 2_592_000_000,
    scope: String = "thread-or-room",
    includeOwnMessages: Bool = false
  ) {
    self.maxMessages = max(1, min(maxMessages, 500))
    self.maxBytes = max(1_024, min(maxBytes, 5_242_880))
    self.maxAgeMs = max(0, maxAgeMs)
    self.scope = scope
    self.includeOwnMessages = includeOwnMessages
  }

  private enum CodingKeys: String, CodingKey {
    case maxMessages
    case maxBytes
    case maxAgeMs
    case scope
    case includeOwnMessages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxMessages: try container.decodeIfPresent(Int.self, forKey: .maxMessages) ?? 80,
      maxBytes: try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 131_072,
      maxAgeMs: try container.decodeIfPresent(Int64.self, forKey: .maxAgeMs) ?? 2_592_000_000,
      scope: try container.decodeIfPresent(String.self, forKey: .scope) ?? "thread-or-room",
      includeOwnMessages: try container.decodeIfPresent(Bool.self, forKey: .includeOwnMessages) ?? false
    )
  }
}

struct MatrixGatewayAttachmentPolicy: Decodable, Equatable, Sendable {
  var downloadText: Bool
  var maxBytes: Int
  var allowedMimeTypes: Set<String>

  init(
    downloadText: Bool = false,
    maxBytes: Int = 65_536,
    allowedMimeTypes: Set<String> = ["text/plain", "text/markdown", "application/json"]
  ) {
    self.downloadText = downloadText
    self.maxBytes = max(1, min(maxBytes, 1_048_576))
    self.allowedMimeTypes = allowedMimeTypes
  }

  private enum CodingKeys: String, CodingKey {
    case downloadText
    case maxBytes
    case allowedMimeTypes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      downloadText: try container.decodeIfPresent(Bool.self, forKey: .downloadText) ?? false,
      maxBytes: try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 65_536,
      allowedMimeTypes: Set(try container.decodeIfPresent([String].self, forKey: .allowedMimeTypes)
        ?? ["text/plain", "text/markdown", "application/json"])
    )
  }
}

struct MatrixGatewayReplyBot: Decodable, Equatable, Sendable {
  var accessTokenEnv: String?
}

struct MatrixSyncRequest: Equatable, Sendable {
  var homeserverURL: URL
  var accessToken: String
  var since: String?
  var timeoutMilliseconds: Int
}

struct MatrixSendMessageRequest: Equatable, Sendable {
  var homeserverURL: URL
  var accessToken: String
  var roomId: String
  var transactionId: String
  var text: String
  var threadEventId: String?
}

struct MatrixDownloadAttachmentRequest: Equatable, Sendable {
  var homeserverURL: URL
  var accessToken: String
  var mxcURL: String
}

struct MatrixSyncResponse: Decodable, Equatable, Sendable {
  var nextBatch: String
  var rooms: MatrixSyncRooms?

  private enum CodingKeys: String, CodingKey {
    case nextBatch = "next_batch"
    case rooms
  }
}

struct MatrixSyncRooms: Decodable, Equatable, Sendable {
  var join: [String: MatrixJoinedRoom]
}

struct MatrixJoinedRoom: Decodable, Equatable, Sendable {
  var timeline: MatrixRoomTimeline
}

struct MatrixRoomTimeline: Decodable, Equatable, Sendable {
  var events: [MatrixRoomEvent]
}

struct MatrixRoomEvent: Decodable, Equatable, Sendable {
  var type: String
  var eventId: String
  var sender: String
  var originServerTimestamp: Int64?
  var content: MatrixMessageContent

  private enum CodingKeys: String, CodingKey {
    case type
    case eventId = "event_id"
    case sender
    case originServerTimestamp = "origin_server_ts"
    case content
  }

  var receivedAt: Date {
    originServerTimestamp.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date()
  }
}

struct MatrixMessageContent: Decodable, Equatable, Sendable {
  var body: String?
  var messageType: String?
  var filename: String?
  var url: String?
  var info: MatrixAttachmentInfo?
  var relatesTo: MatrixEventRelation?

  private enum CodingKeys: String, CodingKey {
    case body
    case messageType = "msgtype"
    case filename
    case url
    case info
    case relatesTo = "m.relates_to"
  }

  init(
    body: String?,
    messageType: String?,
    filename: String? = nil,
    url: String? = nil,
    info: MatrixAttachmentInfo? = nil,
    relatesTo: MatrixEventRelation?
  ) {
    self.body = body
    self.messageType = messageType
    self.filename = filename
    self.url = url
    self.info = info
    self.relatesTo = relatesTo
  }

  var textAttachment: MatrixTextAttachment? {
    guard messageType == "m.file",
      let mxcURL = url,
      mxcURL.hasPrefix("mxc://"),
      let mimeType = info?.mimeType?.lowercased()
    else {
      return nil
    }
    return MatrixTextAttachment(
      filename: filename?.nilIfEmpty ?? body?.nilIfEmpty ?? "attachment.txt",
      mimeType: mimeType,
      size: info?.size,
      mxcURL: mxcURL
    )
  }
}

struct MatrixAttachmentInfo: Decodable, Equatable, Sendable {
  var mimeType: String?
  var size: Int?

  private enum CodingKeys: String, CodingKey {
    case mimeType = "mimetype"
    case size
  }
}

struct MatrixTextAttachment: Equatable, Sendable {
  var filename: String
  var mimeType: String
  var size: Int?
  var mxcURL: String
}

struct MatrixEventRelation: Decodable, Equatable, Sendable {
  var relType: String?
  var eventId: String?

  private enum CodingKeys: String, CodingKey {
    case relType = "rel_type"
    case eventId = "event_id"
  }
}

struct MatrixConversationReply: Equatable, Sendable {
  var replyAs: String?
  var text: String
}

struct URLSessionMatrixGatewayAPI: MatrixGatewayAPI {
  func sync(request: MatrixSyncRequest) async throws -> MatrixSyncResponse {
    var components = URLComponents(
      url: request.homeserverURL
        .appendingPathComponent("_matrix")
        .appendingPathComponent("client")
        .appendingPathComponent("v3")
        .appendingPathComponent("sync"),
      resolvingAgainstBaseURL: false
    )
    var queryItems = [URLQueryItem(name: "timeout", value: String(request.timeoutMilliseconds))]
    if let since = request.since, !since.isEmpty {
      queryItems.append(URLQueryItem(name: "since", value: since))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
      throw CLIUsageError("matrix sync URL is invalid")
    }
    return try await execute(
      url: url,
      method: "GET",
      accessToken: request.accessToken,
      body: nil,
      decode: MatrixSyncResponse.self
    )
  }

  func downloadAttachment(request: MatrixDownloadAttachmentRequest) async throws -> Data {
    guard let components = URLComponents(string: request.mxcURL),
      components.scheme == "mxc",
      let serverName = components.host,
      !serverName.isEmpty,
      !components.path.isEmpty
    else {
      throw CLIUsageError("matrix attachment URL is invalid")
    }
    let mediaId = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !mediaId.isEmpty else {
      throw CLIUsageError("matrix attachment media id is missing")
    }
    let url = request.homeserverURL
      .appendingPathComponent("_matrix")
      .appendingPathComponent("client")
      .appendingPathComponent("v1")
      .appendingPathComponent("media")
      .appendingPathComponent("download")
      .appendingPathComponent(serverName)
      .appendingPathComponent(mediaId)
    var urlRequest = URLRequest(url: url)
    urlRequest.setValue("Bearer \(request.accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      throw CLIUsageError("matrix attachment download failed")
    }
    return data
  }

  func sendMessage(request: MatrixSendMessageRequest) async throws {
    let url = request.homeserverURL
      .appendingPathComponent("_matrix")
      .appendingPathComponent("client")
      .appendingPathComponent("v3")
      .appendingPathComponent("rooms")
      .appendingPathComponent(request.roomId)
      .appendingPathComponent("send")
      .appendingPathComponent("m.room.message")
      .appendingPathComponent(request.transactionId)
    var body: JSONObject = [
      "msgtype": .string("m.text"),
      "body": .string(request.text)
    ]
    if let threadEventId = request.threadEventId {
      body["m.relates_to"] = .object([
        "rel_type": .string("m.thread"),
        "event_id": .string(threadEventId),
        "is_falling_back": .bool(true),
        "m.in_reply_to": .object(["event_id": .string(threadEventId)])
      ])
    }
    _ = try await execute(
      url: url,
      method: "PUT",
      accessToken: request.accessToken,
      body: body,
      decode: MatrixSendResponse.self
    )
  }

  private func execute<Response: Decodable>(
    url: URL,
    method: String,
    accessToken: String,
    body: JSONObject?,
    decode type: Response.Type
  ) async throws -> Response {
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = method
    urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let body {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    }
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      let detail = String(data: data, encoding: .utf8) ?? "unknown Matrix response"
      throw CLIUsageError("matrix HTTP request failed: \(detail)")
    }
    return try JSONDecoder().decode(type, from: data)
  }
}

private struct MatrixSendResponse: Decodable {
  var eventId: String

  private enum CodingKeys: String, CodingKey {
    case eventId = "event_id"
  }
}

private struct MatrixSinceTokenRecord: Codable {
  var since: String
}

private struct MatrixSinceTokenStore {
  var url: URL

  init(eventRoot: URL, source: MatrixGatewaySource) throws {
    let configuredPath = source.sync.sinceTokenPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let relativePath = configuredPath?.nilIfEmpty ?? "matrix/\(source.id)-sync.json"
    self.url = try safeMatrixEventRootRelativeURL(eventRoot: eventRoot, relativePath: relativePath)
  }

  func load() throws -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try JSONDecoder().decode(MatrixSinceTokenRecord.self, from: Data(contentsOf: url)).since
  }

  func save(_ since: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(MatrixSinceTokenRecord(since: since)).write(to: url, options: .atomic)
  }
}

private struct MatrixConversationHistoryStore {
  var eventRoot: URL
  var source: MatrixGatewaySource

  func loadHistory(roomId: String, threadEventId: String?) -> [JSONObject] {
    let url = historyURL(roomId: roomId, threadEventId: threadEventId)
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let values = try? JSONDecoder().decode([JSONValue].self, from: data)
    else {
      return []
    }
    let cutoff = Date().addingTimeInterval(-Double(source.history.maxAgeMs) / 1_000)
    return values.compactMap { value in
      guard case let .object(object) = value else {
        return nil
      }
      guard source.history.maxAgeMs == 0 || matrixHistoryDate(object) >= cutoff else {
        return nil
      }
      return object
    }
  }

  func appendExchange(
    event: MatrixRoomEvent,
    roomId: String,
    replies: [MatrixConversationReply]
  ) throws {
    let threadEventId = event.content.relatesTo?.relType == "m.thread"
      ? event.content.relatesTo?.eventId
      : nil
    let url = historyURL(roomId: roomId, threadEventId: threadEventId)
    var history = loadHistory(roomId: roomId, threadEventId: threadEventId)
    let recordedAt = event.receivedAt
    history.append(compactMatrixObject([
      "role": .string("user"),
      "text": event.content.body.map(JSONValue.string),
      "messageId": .string(event.eventId),
      "senderId": .string(event.sender),
      "recordedAt": .string(matrixHistoryTimestamp(recordedAt))
    ]))
    for reply in replies {
      history.append(compactMatrixObject([
        "role": .string("assistant"),
        "text": .string(reply.text),
        "replyAs": reply.replyAs.map(JSONValue.string),
        "recordedAt": .string(matrixHistoryTimestamp(recordedAt))
      ]))
    }
    history = Array(history.suffix(source.history.maxMessages))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(history.map(JSONValue.object))
    while data.count > source.history.maxBytes, history.count > 1 {
      history.removeFirst()
      data = try encoder.encode(history.map(JSONValue.object))
    }
    guard data.count <= source.history.maxBytes else {
      return
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private func historyURL(roomId: String, threadEventId: String?) -> URL {
    let scopeId = source.history.scope == "thread-or-room" ? (threadEventId ?? roomId) : roomId
    return eventRoot
      .appendingPathComponent("matrix-history", isDirectory: true)
      .appendingPathComponent(safeMatrixStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent("\(safeMatrixStorageComponent(scopeId)).json")
  }
}

private func matrixHistoryDateFormatter() -> ISO8601DateFormatter {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}

private func matrixHistoryTimestamp(_ date: Date) -> String {
  matrixHistoryDateFormatter().string(from: date)
}

private func matrixHistoryDate(_ object: JSONObject) -> Date {
  guard let rawValue = object["recordedAt"]?.stringValue,
    let date = matrixHistoryDateFormatter().date(from: rawValue)
  else {
    return .distantPast
  }
  return date
}

private func compactMatrixObject(_ fields: [String: JSONValue?]) -> JSONObject {
  fields.reduce(into: JSONObject()) { result, pair in
    if let value = pair.value {
      result[pair.key] = value
    }
  }
}

private func safeMatrixStorageComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = value.unicodeScalars.map { scalar in
    allowed.contains(scalar) ? Character(scalar) : "_"
  }
  let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
  return sanitized.isEmpty ? "unknown" : sanitized
}

private func safeMatrixEventRootRelativeURL(eventRoot: URL, relativePath: String) throws -> URL {
  guard let normalizedPath = normalizedMatrixEventRootRelativePath(relativePath) else {
    throw CLIUsageError("matrix sinceTokenPath must be event-root-relative: \(relativePath)")
  }
  let root = eventRoot.standardizedFileURL
  let url = root.appendingPathComponent(normalizedPath).standardizedFileURL
  guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
    throw CLIUsageError("matrix sinceTokenPath escapes event root: \(relativePath)")
  }
  return url
}

private func normalizedMatrixEventRootRelativePath(_ rawPath: String) -> String? {
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

private func matrixEnvironmentValue(_ name: String, environment: [String: String]) -> String? {
  environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
