import Foundation
import RielaCore

public enum EventSourceKind: RawRepresentable, Codable, Equatable, Sendable {
  public typealias RawValue = String

  case cron
  case webhook
  case chatSdk
  case discordGateway
  case fileChange
  case telegramGateway
  case matrix
  case s3Repository
  case sequentialList
  case custom(String)

  public init(rawValue: String) {
    switch rawValue {
    case "cron":
      self = .cron
    case "webhook":
      self = .webhook
    case "chat-sdk":
      self = .chatSdk
    case "discord-gateway":
      self = .discordGateway
    case "file-change":
      self = .fileChange
    case "telegram-gateway":
      self = .telegramGateway
    case "matrix":
      self = .matrix
    case "s3-repository":
      self = .s3Repository
    case "sequential-list":
      self = .sequentialList
    default:
      self = .custom(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .cron:
      "cron"
    case .webhook:
      "webhook"
    case .chatSdk:
      "chat-sdk"
    case .discordGateway:
      "discord-gateway"
    case .fileChange:
      "file-change"
    case .telegramGateway:
      "telegram-gateway"
    case .matrix:
      "matrix"
    case .s3Repository:
      "s3-repository"
    case .sequentialList:
      "sequential-list"
    case .custom(let value):
      value
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum EventProvider: RawRepresentable, Codable, Equatable, Sendable {
  public typealias RawValue = String

  case slack
  case teams
  case gchat
  case discord
  case telegram
  case github
  case linear
  case whatsapp
  case messenger
  case web
  case custom(String)

  public init(rawValue: String) {
    switch rawValue {
    case "slack":
      self = .slack
    case "teams":
      self = .teams
    case "gchat":
      self = .gchat
    case "discord":
      self = .discord
    case "telegram":
      self = .telegram
    case "github":
      self = .github
    case "linear":
      self = .linear
    case "whatsapp":
      self = .whatsapp
    case "messenger":
      self = .messenger
    case "web":
      self = .web
    default:
      self = .custom(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .slack:
      "slack"
    case .teams:
      "teams"
    case .gchat:
      "gchat"
    case .discord:
      "discord"
    case .telegram:
      "telegram"
    case .github:
      "github"
    case .linear:
      "linear"
    case .whatsapp:
      "whatsapp"
    case .messenger:
      "messenger"
    case .web:
      "web"
    case .custom(let value):
      value
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension EventProvider {
  public static let supportedChatSDKProviders: [EventProvider] = [
    .slack,
    .teams,
    .gchat,
    .discord,
    .telegram,
    .github,
    .linear,
    .whatsapp,
    .messenger,
    .web
  ]

  public var isSupportedChatSDKProvider: Bool {
    Self.supportedChatSDKProviders.contains(self)
  }
}

public enum EventType: RawRepresentable, Codable, Equatable, Sendable {
  public typealias RawValue = String

  case message
  case chatMessage
  case eventInput
  case custom(String)

  public init(rawValue: String) {
    switch rawValue {
    case "message":
      self = .message
    case "chat.message":
      self = .chatMessage
    case "event-input":
      self = .eventInput
    default:
      self = .custom(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .message:
      "message"
    case .chatMessage:
      "chat.message"
    case .eventInput:
      "event-input"
    case .custom(let value):
      value
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension EventType {
  public static let supportedRielaEventTypes: [EventType] = [
    .message,
    .chatMessage,
    .eventInput
  ]

  public var isSupportedRielaEventType: Bool {
    Self.supportedRielaEventTypes.contains(self)
  }
}

public enum EventReceiverMode: RawRepresentable, Codable, Equatable, Sendable {
  public typealias RawValue = String

  case webhookBridge
  case polling
  case custom(String)

  public init(rawValue: String) {
    switch rawValue {
    case "webhook-bridge":
      self = .webhookBridge
    case "polling":
      self = .polling
    default:
      self = .custom(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .webhookBridge:
      "webhook-bridge"
    case .polling:
      "polling"
    case .custom(let value):
      value
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum EventObjectAccessMode: RawRepresentable, Codable, Equatable, Sendable {
  public typealias RawValue = String

  case metadataOnly
  case custom(String)

  public init(rawValue: String) {
    switch rawValue {
    case "metadata-only":
      self = .metadataOnly
    default:
      self = .custom(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .metadataOnly:
      "metadata-only"
    case .custom(let value):
      value
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct EventArtifactReference: Codable, Equatable, Sendable {
  public var root: String
  public var path: String

  public init(root: String = "artifact", path: String) {
    self.root = root
    self.path = path
  }
}

public struct EventSourceContract: Codable, Equatable, Sendable {
  public var id: String
  public var kind: EventSourceKind
  public var provider: EventProvider?
  public var enabled: Bool
  public var routePath: String?
  public var secretEnv: String?
  public var bucket: String?
  public var eventReceiverMode: EventReceiverMode?
  public var eventReceiverPath: String?
  public var objectAccessMode: EventObjectAccessMode?
  public var rootPrefix: String?
  public var chatWebhookBearerTokenEnv: String?
  fileprivate var hasChatWebhook: Bool
  fileprivate var hasEventReceiver: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case provider
    case enabled
    case routePath
    case secretEnv
    case path
    case signingSecretEnv
    case bucket
    case eventReceiver
    case objectAccess
    case eventReceiverMode
    case eventReceiverPath
    case objectAccessMode
    case rootPrefix
    case webhook
  }

  private enum ChatWebhookCodingKeys: String, CodingKey {
    case path
    case signingSecretEnv
    case bearerTokenEnv
  }

  private enum EventReceiverCodingKeys: String, CodingKey {
    case mode
    case path
    case signingSecretEnv
  }

  private enum ObjectAccessCodingKeys: String, CodingKey {
    case mode
  }

  public init(
    id: String,
    kind: EventSourceKind,
    provider: String? = nil,
    enabled: Bool = true,
    routePath: String? = nil,
    secretEnv: String? = nil,
    bucket: String? = nil,
    eventReceiverMode: String? = nil,
    eventReceiverPath: String? = nil,
    objectAccessMode: String? = nil,
    rootPrefix: String? = nil,
    chatWebhookBearerTokenEnv: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.provider = provider.map(EventProvider.init(rawValue:))
    self.enabled = enabled
    self.routePath = routePath
    self.secretEnv = secretEnv
    self.bucket = bucket
    self.eventReceiverMode = eventReceiverMode.map(EventReceiverMode.init(rawValue:))
    self.eventReceiverPath = eventReceiverPath
    self.objectAccessMode = objectAccessMode.map(EventObjectAccessMode.init(rawValue:))
    self.rootPrefix = rootPrefix
    self.chatWebhookBearerTokenEnv = chatWebhookBearerTokenEnv
    self.hasChatWebhook = kind == .chatSdk && (routePath != nil || secretEnv != nil || chatWebhookBearerTokenEnv != nil)
    self.hasEventReceiver = kind == .s3Repository && (eventReceiverMode != nil || eventReceiverPath != nil || secretEnv != nil)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.kind = try container.decode(EventSourceKind.self, forKey: .kind)
    self.provider = try container.decodeIfPresent(EventProvider.self, forKey: .provider)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    self.routePath = try container.decodeIfPresent(String.self, forKey: .path)
      ?? container.decodeIfPresent(String.self, forKey: .routePath)
    self.secretEnv = try container.decodeIfPresent(String.self, forKey: .signingSecretEnv)
      ?? container.decodeIfPresent(String.self, forKey: .secretEnv)
    self.bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
    if container.contains(.webhook) {
      self.hasChatWebhook = true
      let webhook = try container.nestedContainer(keyedBy: ChatWebhookCodingKeys.self, forKey: .webhook)
      self.routePath = try webhook.decodeIfPresent(String.self, forKey: .path) ?? self.routePath
      self.secretEnv = try webhook.decodeIfPresent(String.self, forKey: .signingSecretEnv) ?? self.secretEnv
      self.chatWebhookBearerTokenEnv = try webhook.decodeIfPresent(String.self, forKey: .bearerTokenEnv)
    } else {
      self.hasChatWebhook = false
      self.chatWebhookBearerTokenEnv = nil
    }
    if container.contains(.eventReceiver) {
      self.hasEventReceiver = true
      let eventReceiver = try container.nestedContainer(keyedBy: EventReceiverCodingKeys.self, forKey: .eventReceiver)
      self.eventReceiverMode = try eventReceiver.decodeIfPresent(EventReceiverMode.self, forKey: .mode)
      self.eventReceiverPath = try eventReceiver.decodeIfPresent(String.self, forKey: .path)
      self.secretEnv = try eventReceiver.decodeIfPresent(String.self, forKey: .signingSecretEnv) ?? self.secretEnv
    } else {
      self.hasEventReceiver = false
      self.eventReceiverMode = try container.decodeIfPresent(EventReceiverMode.self, forKey: .eventReceiverMode)
      self.eventReceiverPath = try container.decodeIfPresent(String.self, forKey: .eventReceiverPath)
    }
    if container.contains(.objectAccess) {
      let objectAccess = try container.nestedContainer(keyedBy: ObjectAccessCodingKeys.self, forKey: .objectAccess)
      self.objectAccessMode = try objectAccess.decodeIfPresent(EventObjectAccessMode.self, forKey: .mode)
    } else {
      self.objectAccessMode = try container.decodeIfPresent(EventObjectAccessMode.self, forKey: .objectAccessMode)
    }
    self.rootPrefix = try container.decodeIfPresent(String.self, forKey: .rootPrefix)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(provider, forKey: .provider)
    if !enabled {
      try container.encode(enabled, forKey: .enabled)
    }
    switch kind {
    case .webhook:
      try container.encodeIfPresent(routePath, forKey: .path)
      try container.encodeIfPresent(secretEnv, forKey: .signingSecretEnv)
    case .s3Repository:
      try container.encodeIfPresent(bucket, forKey: .bucket)
      try container.encodeIfPresent(rootPrefix, forKey: .rootPrefix)
      var eventReceiver = container.nestedContainer(keyedBy: EventReceiverCodingKeys.self, forKey: .eventReceiver)
      try eventReceiver.encode(eventReceiverMode ?? .webhookBridge, forKey: .mode)
      try eventReceiver.encodeIfPresent(eventReceiverPath, forKey: .path)
      try eventReceiver.encodeIfPresent(secretEnv, forKey: .signingSecretEnv)
      var objectAccess = container.nestedContainer(keyedBy: ObjectAccessCodingKeys.self, forKey: .objectAccess)
      try objectAccess.encode(objectAccessMode ?? .metadataOnly, forKey: .mode)
    case .chatSdk:
      if routePath != nil || secretEnv != nil || chatWebhookBearerTokenEnv != nil {
        var webhook = container.nestedContainer(keyedBy: ChatWebhookCodingKeys.self, forKey: .webhook)
        try webhook.encodeIfPresent(routePath, forKey: .path)
        try webhook.encodeIfPresent(secretEnv, forKey: .signingSecretEnv)
        try webhook.encodeIfPresent(chatWebhookBearerTokenEnv, forKey: .bearerTokenEnv)
      }
    default:
      try container.encodeIfPresent(routePath, forKey: .path)
      try container.encodeIfPresent(secretEnv, forKey: .signingSecretEnv)
      try container.encodeIfPresent(bucket, forKey: .bucket)
      try container.encodeIfPresent(rootPrefix, forKey: .rootPrefix)
    }
  }
}

public struct EventBindingMatchRule: Codable, Equatable, Sendable {
  public var eventType: EventType?
  public var conversationId: String?
  public var pathPrefix: String?

  public init(eventType: String? = nil, conversationId: String? = nil, pathPrefix: String? = nil) {
    self.eventType = eventType.map(EventType.init(rawValue:))
    self.conversationId = conversationId
    self.pathPrefix = pathPrefix
  }
}

public enum EventInputMappingMode: String, Codable, CaseIterable, Sendable {
  case eventInput = "event-input"
  case template
}

public struct EventInputMapping: Codable, Equatable, Sendable {
  public var mode: EventInputMappingMode
  public var template: JSONValue?
  public var mirrorToHumanInput: Bool?

  private enum CodingKeys: String, CodingKey {
    case mode
    case template
    case mirrorToHumanInput
  }

  public init(mode: EventInputMappingMode, template: JSONValue? = nil, mirrorToHumanInput: Bool? = nil) {
    self.mode = mode
    self.template = template
    self.mirrorToHumanInput = mirrorToHumanInput
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.mode = try container.decode(EventInputMappingMode.self, forKey: .mode)
    self.template = try container.decodeIfPresent(JSONValue.self, forKey: .template)
    self.mirrorToHumanInput = try container.decodeIfPresent(Bool.self, forKey: .mirrorToHumanInput)
    if mode == .template && template == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .template,
        in: container,
        debugDescription: "template input mappings must include template"
      )
    }
  }
}

public enum EventExecutionMode: String, Codable, CaseIterable, Sendable {
  case direct
  case supervised
  case supervisorDispatch = "supervisor-dispatch"
  case scheduleRegistration = "schedule-registration"
}

public struct EventWorkflowExecutionPolicy: Codable, Equatable, Sendable {
  public var mode: EventExecutionMode?

  public init(mode: EventExecutionMode? = nil) {
    self.mode = mode
  }

  public var allowsMissingWorkflowName: Bool {
    mode == .supervisorDispatch || mode == .scheduleRegistration
  }
}

public enum EventMailboxBridgeInputConsumer: String, Codable, CaseIterable, Sendable {
  case directWorkflow = "direct-workflow"
  case supervisor
}

public struct EventMailboxBridgeInputPolicy: Codable, Equatable, Sendable {
  public var consumer: EventMailboxBridgeInputConsumer

  public init(consumer: EventMailboxBridgeInputConsumer) {
    self.consumer = consumer
  }
}

public enum EventMailboxBridgeReplyMode: String, Codable, CaseIterable, Sendable {
  case none
  case final
}

public enum EventMailboxBridgeStatusMode: String, Codable, CaseIterable, Sendable {
  case none
  case statusOnly = "status-only"
}

public struct EventMailboxBridgeReplyPolicy: Codable, Equatable, Sendable {
  public var mode: EventMailboxBridgeReplyMode

  public init(mode: EventMailboxBridgeReplyMode) {
    self.mode = mode
  }
}

public struct EventMailboxBridgeStatusPolicy: Codable, Equatable, Sendable {
  public var mode: EventMailboxBridgeStatusMode

  public init(mode: EventMailboxBridgeStatusMode) {
    self.mode = mode
  }
}

public struct EventMailboxBridgeOutboundPolicy: Codable, Equatable, Sendable {
  public var reply: EventMailboxBridgeReplyPolicy?
  public var progress: EventMailboxBridgeStatusPolicy?
  public var control: EventMailboxBridgeStatusPolicy?

  public init(
    reply: EventMailboxBridgeReplyPolicy? = nil,
    progress: EventMailboxBridgeStatusPolicy? = nil,
    control: EventMailboxBridgeStatusPolicy? = nil
  ) {
    self.reply = reply
    self.progress = progress
    self.control = control
  }
}

public struct EventMailboxBridgePolicy: Codable, Equatable, Sendable {
  public var input: EventMailboxBridgeInputPolicy?
  public var output: EventMailboxBridgeOutboundPolicy?

  public init(input: EventMailboxBridgeInputPolicy? = nil, output: EventMailboxBridgeOutboundPolicy? = nil) {
    self.input = input
    self.output = output
  }
}

public struct EventBindingContract: Codable, Equatable, Sendable {
  public var id: String
  public var enabled: Bool
  public var sourceId: String
  public var eventType: EventType?
  public var match: EventBindingMatchRule?
  public var workflowName: String?
  public var inputMapping: EventInputMapping
  public var execution: EventWorkflowExecutionPolicy?
  public var outputDestinations: [String]?
  public var mailboxBridge: EventMailboxBridgePolicy?

  private enum CodingKeys: String, CodingKey {
    case id
    case enabled
    case sourceId
    case eventType
    case match
    case workflowName
    case inputMapping
    case execution
    case outputDestinations
    case mailboxBridge
  }

  public init(
    id: String,
    enabled: Bool = true,
    sourceId: String,
    eventType: String? = nil,
    match: EventBindingMatchRule? = nil,
    workflowName: String? = nil,
    inputMapping: EventInputMapping,
    execution: EventWorkflowExecutionPolicy? = nil,
    outputDestinations: [String]? = nil,
    mailboxBridge: EventMailboxBridgePolicy? = nil
  ) {
    self.id = id
    self.enabled = enabled
    self.sourceId = sourceId
    self.eventType = eventType.map(EventType.init(rawValue:))
    self.match = match
    self.workflowName = workflowName
    self.inputMapping = inputMapping
    self.execution = execution
    self.outputDestinations = outputDestinations
    self.mailboxBridge = mailboxBridge
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    self.sourceId = try container.decode(String.self, forKey: .sourceId)
    self.eventType = try container.decodeIfPresent(EventType.self, forKey: .eventType)
    self.match = try container.decodeIfPresent(EventBindingMatchRule.self, forKey: .match)
    self.workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
    self.inputMapping = try container.decode(EventInputMapping.self, forKey: .inputMapping)
    self.execution = try container.decodeIfPresent(EventWorkflowExecutionPolicy.self, forKey: .execution)
    self.outputDestinations = try container.decodeIfPresent([String].self, forKey: .outputDestinations)
    self.mailboxBridge = try container.decodeIfPresent(EventMailboxBridgePolicy.self, forKey: .mailboxBridge)
  }
}

public struct ExternalEventEnvelope: Codable, Equatable, Sendable {
  public var sourceId: String
  public var eventId: String
  public var provider: EventProvider
  public var eventType: EventType
  public var receivedAt: Date
  public var dedupeKey: String?
  public var actor: JSONObject?
  public var conversation: JSONObject?
  public var input: JSONObject
  public var artifacts: [EventArtifactReference]

  public init(
    sourceId: String,
    eventId: String,
    provider: String,
    eventType: String,
    receivedAt: Date,
    dedupeKey: String? = nil,
    actor: JSONObject? = nil,
    conversation: JSONObject? = nil,
    input: JSONObject,
    artifacts: [EventArtifactReference] = []
  ) {
    self.sourceId = sourceId
    self.eventId = eventId
    self.provider = EventProvider(rawValue: provider)
    self.eventType = EventType(rawValue: eventType)
    self.receivedAt = receivedAt
    self.dedupeKey = dedupeKey
    self.actor = actor
    self.conversation = conversation
    self.input = input
    self.artifacts = artifacts
  }

  private enum CodingKeys: String, CodingKey {
    case sourceId
    case eventId
    case provider
    case eventType
    case receivedAt
    case dedupeKey
    case actor
    case conversation
    case input
    case artifacts
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.sourceId = try container.decode(String.self, forKey: .sourceId)
    self.eventId = try container.decode(String.self, forKey: .eventId)
    self.provider = try container.decode(EventProvider.self, forKey: .provider)
    self.eventType = try container.decode(EventType.self, forKey: .eventType)
    let receivedAtString = try container.decode(String.self, forKey: .receivedAt)
    guard let receivedAt = eventISO8601DateFormatter().date(from: receivedAtString) else {
      throw DecodingError.dataCorruptedError(
        forKey: .receivedAt,
        in: container,
        debugDescription: "receivedAt must be an ISO8601 string"
      )
    }
    self.receivedAt = receivedAt
    self.dedupeKey = try container.decodeIfPresent(String.self, forKey: .dedupeKey)
    self.actor = try container.decodeIfPresent(JSONObject.self, forKey: .actor)
    self.conversation = try container.decodeIfPresent(JSONObject.self, forKey: .conversation)
    self.input = try container.decode(JSONObject.self, forKey: .input)
    self.artifacts = try container.decodeIfPresent([EventArtifactReference].self, forKey: .artifacts) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sourceId, forKey: .sourceId)
    try container.encode(eventId, forKey: .eventId)
    try container.encode(provider, forKey: .provider)
    try container.encode(eventType, forKey: .eventType)
    try container.encode(eventISO8601DateFormatter().string(from: receivedAt), forKey: .receivedAt)
    try container.encodeIfPresent(dedupeKey, forKey: .dedupeKey)
    try container.encodeIfPresent(actor, forKey: .actor)
    try container.encodeIfPresent(conversation, forKey: .conversation)
    try container.encode(input, forKey: .input)
    try container.encode(artifacts, forKey: .artifacts)
  }
}

private func eventISO8601DateFormatter() -> ISO8601DateFormatter {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}

public struct EventValidationDiagnostic: Codable, Equatable, Sendable {
  public var code: String
  public var path: String
  public var message: String

  public init(code: String, path: String, message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}

public struct EventReceipt: Codable, Equatable, Sendable {
  public var sourceId: String
  public var eventId: String
  public var dedupeKey: String?
  public var status: String

  public init(sourceId: String, eventId: String, dedupeKey: String? = nil, status: String) {
    self.sourceId = sourceId
    self.eventId = eventId
    self.dedupeKey = dedupeKey
    self.status = status
  }
}

public struct ReplyDispatch: Codable, Equatable, Sendable {
  public var sourceId: String
  public var provider: EventProvider
  public var conversationId: String?
  public var payload: JSONObject

  public init(sourceId: String, provider: String, conversationId: String? = nil, payload: JSONObject) {
    self.sourceId = sourceId
    self.provider = EventProvider(rawValue: provider)
    self.conversationId = conversationId
    self.payload = payload
  }
}

public enum EventContractValidator {
  public static func validate(sources: [EventSourceContract], bindings: [EventBindingContract]) -> [EventValidationDiagnostic] {
    var diagnostics: [EventValidationDiagnostic] = []
    var sourceIds = Set<String>()
    var sourcesById: [String: EventSourceContract] = [:]
    var routePaths = Set<String>()
    for (index, source) in sources.enumerated() {
      if source.id.isEmpty || !sourceIds.insert(source.id).inserted {
        diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].id", message: "event source id must be unique and non-empty"))
      } else {
        sourcesById[source.id] = source
      }
      if source.kind == .webhook, source.routePath?.isEmpty != false {
        diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].path", message: "webhook path must start with / and contain no whitespace, ? or #"))
      }
      if source.kind == .chatSdk {
        if !isSupportedChatSDKProvider(source.provider) {
          diagnostics.append(.init(
            code: "INVALID_EVENT_SOURCE",
            path: "sources[\(index)].provider",
            message: "chat-sdk provider must be one of \(supportedChatSDKProviderNames)"
          ))
        }
        if !source.hasChatWebhook {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].webhook", message: "chat-sdk webhook is required"))
        }
        if !isValidChatSDKRelativePath(source.routePath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].webhook.path", message: "chat-sdk webhook path must be relative and contain no traversal, whitespace, ? or #"))
        }
        if source.secretEnv == nil && source.chatWebhookBearerTokenEnv == nil {
          diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: "sources[\(index)].webhook", message: "chat-sdk webhook must configure signingSecretEnv or bearerTokenEnv"))
        }
      }
      if let routePath = eventHTTPPath(for: source) {
        let routePathLabel = eventHTTPPathLabel(for: source, index: index)
        if !isValidHTTPPath(routePath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: routePathLabel, message: "event route path must start with / and contain no whitespace, ? or #"))
        }
        if !routePaths.insert(routePath).inserted {
          diagnostics.append(.init(code: "EVENT_ROUTE_CONFLICT", path: routePathLabel, message: "event route path conflicts with another source"))
        }
      }
      if let secretEnv = source.secretEnv, !isValidEnvironmentName(secretEnv) {
        diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: eventSecretPathLabel(for: source, index: index), message: "event secret must reference an environment variable name"))
      }
      if let bearerTokenEnv = source.chatWebhookBearerTokenEnv, !isValidEnvironmentName(bearerTokenEnv) {
        diagnostics.append(.init(code: "INVALID_EVENT_SECRET", path: "sources[\(index)].webhook.bearerTokenEnv", message: "bearer token must reference an environment variable name"))
      }
      if source.kind == .s3Repository {
        if source.bucket?.isEmpty != false {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].bucket", message: "bucket is required"))
        }
        if !source.hasEventReceiver {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].eventReceiver", message: "event receiver is required"))
        }
        if let eventReceiverMode = source.eventReceiverMode, eventReceiverMode != .webhookBridge {
          diagnostics.append(.init(
            code: "INVALID_EVENT_SOURCE",
            path: "sources[\(index)].eventReceiver.mode",
            message: "\(eventReceiverMode.rawValue) receiver mode is not supported"
          ))
        }
        if source.objectAccessMode != .metadataOnly {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].objectAccess.mode", message: "object access must explicitly be metadata-only"))
        }
        if let eventReceiverPath = source.eventReceiverPath, !isValidHTTPPath(eventReceiverPath) {
          diagnostics.append(.init(code: "INVALID_EVENT_ROUTE", path: "sources[\(index)].eventReceiver.path", message: "event receiver path must start with / and contain no whitespace, ? or #"))
        }
        if let rootPrefix = source.rootPrefix, rootPrefix.isEmpty || rootPrefix.hasPrefix("/") || rootPrefix.contains("..") {
          diagnostics.append(.init(code: "INVALID_EVENT_SOURCE", path: "sources[\(index)].rootPrefix", message: "root prefix must be a safe object-key prefix"))
        }
      }
    }
    for (index, binding) in bindings.enumerated() {
      if binding.id.isEmpty {
        diagnostics.append(.init(code: "INVALID_EVENT_BINDING", path: "bindings[\(index)].id", message: "event binding id is required"))
      }
      if !sourceIds.contains(binding.sourceId) {
        diagnostics.append(.init(code: "UNKNOWN_EVENT_SOURCE", path: "bindings[\(index)].sourceId", message: "event binding references an unknown source"))
      }
      if binding.execution?.allowsMissingWorkflowName != true && binding.workflowName?.isEmpty != false {
        diagnostics.append(.init(code: "INVALID_EVENT_WORKFLOW", path: "bindings[\(index)].workflowName", message: "workflowName is required unless execution.mode is supervisor-dispatch or schedule-registration"))
      }
      if binding.inputMapping.mode == .template, let template = binding.inputMapping.template {
        validateTemplateValue(template, path: "bindings[\(index)].inputMapping.template", diagnostics: &diagnostics)
      }
      if let outputDestinations = binding.outputDestinations {
        if outputDestinations.isEmpty || outputDestinations.contains(where: { $0.isEmpty }) {
          diagnostics.append(.init(code: "INVALID_EVENT_OUTPUT_DESTINATION", path: "bindings[\(index)].outputDestinations", message: "outputDestinations must be a non-empty string array when set"))
        }
      }
      validateKnownBindingEventTypes(binding, index: index, diagnostics: &diagnostics)
      validateChatSDKBindingCapabilities(binding, source: sourcesById[binding.sourceId], index: index, diagnostics: &diagnostics)
      validateMailboxBridge(binding, index: index, diagnostics: &diagnostics)
    }
    return diagnostics
  }

  public static func validate(envelope: ExternalEventEnvelope, sources: [EventSourceContract]) -> [EventValidationDiagnostic] {
    guard let source = sources.first(where: { $0.id == envelope.sourceId }) else {
      return [.init(code: "UNKNOWN_EVENT_SOURCE", path: "envelope.sourceId", message: "event envelope references an unknown source")]
    }
    guard envelope.eventType.isSupportedRielaEventType else {
      return [.init(
        code: "INVALID_EVENT_ENVELOPE",
        path: "envelope.eventType",
        message: "event type must be one of \(supportedRielaEventTypeNames)"
      )]
    }
    if source.kind == .chatSdk, !supportedChatSDKEventTypes.contains(envelope.eventType) {
      return [.init(
        code: "INVALID_EVENT_ENVELOPE",
        path: "envelope.eventType",
        message: "chat-sdk provider '\(source.provider?.rawValue ?? "")' does not support event type '\(envelope.eventType.rawValue)'"
      )]
    }
    return []
  }

  private static let supportedChatSDKProviderNames = EventProvider.supportedChatSDKProviders
    .map(\.rawValue)
    .joined(separator: ", ")

  private static let supportedRielaEventTypeNames = EventType.supportedRielaEventTypes
    .map(\.rawValue)
    .joined(separator: ", ")

  private static let supportedChatSDKEventTypes: [EventType] = [.chatMessage]

  private static func isSupportedChatSDKProvider(_ provider: EventProvider?) -> Bool {
    guard let provider else {
      return false
    }
    return provider.isSupportedChatSDKProvider
  }

  private static func validateKnownBindingEventTypes(
    _ binding: EventBindingContract,
    index: Int,
    diagnostics: inout [EventValidationDiagnostic]
  ) {
    let eventTypeChecks = [
      (binding.eventType, "bindings[\(index)].eventType"),
      (binding.match?.eventType, "bindings[\(index)].match.eventType")
    ]
    for (eventType, path) in eventTypeChecks {
      guard let eventType, !eventType.isSupportedRielaEventType else {
        continue
      }
      diagnostics.append(.init(
        code: "INVALID_EVENT_BINDING",
        path: path,
        message: "event type must be one of \(supportedRielaEventTypeNames)"
      ))
    }
  }

  private static func validateChatSDKBindingCapabilities(
    _ binding: EventBindingContract,
    source: EventSourceContract?,
    index: Int,
    diagnostics: inout [EventValidationDiagnostic]
  ) {
    guard source?.kind == .chatSdk,
      isSupportedChatSDKProvider(source?.provider)
    else {
      return
    }
    let eventTypeChecks = [
      (binding.eventType, "bindings[\(index)].eventType"),
      (binding.match?.eventType, "bindings[\(index)].match.eventType")
    ]
    for (eventType, path) in eventTypeChecks {
      guard let eventType, !supportedChatSDKEventTypes.contains(eventType) else {
        continue
      }
      diagnostics.append(.init(
        code: "INVALID_EVENT_BINDING",
        path: path,
        message: "chat-sdk provider '\(source?.provider?.rawValue ?? "")' does not support event type '\(eventType.rawValue)'"
      ))
    }
  }

  private static func validateMailboxBridge(_ binding: EventBindingContract, index: Int, diagnostics: inout [EventValidationDiagnostic]) {
    guard let consumer = binding.mailboxBridge?.input?.consumer else {
      return
    }
    let mode = binding.execution?.mode
    let supervisedLike = mode == .supervised || mode == .supervisorDispatch
    switch consumer {
    case .supervisor where !supervisedLike:
      diagnostics.append(.init(
        code: "INVALID_EVENT_MAILBOX_BRIDGE",
        path: "bindings[\(index)].mailboxBridge.input.consumer",
        message: "mailboxBridge.input.consumer supervisor requires execution.mode supervised or supervisor-dispatch"
      ))
    case .directWorkflow where supervisedLike:
      diagnostics.append(.init(
        code: "INVALID_EVENT_MAILBOX_BRIDGE",
        path: "bindings[\(index)].mailboxBridge.input.consumer",
        message: "mailboxBridge.input.consumer direct-workflow cannot be used with execution.mode supervised or supervisor-dispatch"
      ))
    default:
      return
    }
  }

  private static func isValidEnvironmentName(_ value: String) -> Bool {
    value.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
  }

  private static func isValidHTTPPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.range(of: #"\s|\?|#"#, options: .regularExpression) == nil
  }

  private static func isValidChatSDKRelativePath(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else {
      return false
    }
    return !value.hasPrefix("/") && !value.contains("..") && value.range(of: #"\s|\?|#"#, options: .regularExpression) == nil
  }

  private static func eventHTTPPath(for source: EventSourceContract) -> String? {
    switch source.kind {
    case .webhook:
      return source.routePath
    case .s3Repository:
      return source.eventReceiverPath ?? defaultEventSourceHTTPPath(source)
    case .chatSdk:
      return chatSDKHTTPPath(source.routePath)
    default:
      return nil
    }
  }

  private static func eventHTTPPathLabel(for source: EventSourceContract, index: Int) -> String {
    switch source.kind {
    case .s3Repository:
      return "sources[\(index)].eventReceiver.path"
    case .chatSdk:
      return "sources[\(index)].webhook.path"
    default:
      return "sources[\(index)].path"
    }
  }

  private static func eventSecretPathLabel(for source: EventSourceContract, index: Int) -> String {
    switch source.kind {
    case .chatSdk:
      return "sources[\(index)].webhook.signingSecretEnv"
    default:
      return "sources[\(index)].secretEnv"
    }
  }

  private static func defaultEventSourceHTTPPath(_ source: EventSourceContract) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    return "/events/\(source.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? source.id)"
  }

  private static func chatSDKHTTPPath(_ rawPath: String?) -> String? {
    guard let rawPath, !rawPath.isEmpty else {
      return nil
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    let encodedSegments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
    return "/events/\(encodedSegments.joined(separator: "/"))"
  }

  private static func validateTemplateValue(_ value: JSONValue, path: String, diagnostics: inout [EventValidationDiagnostic]) {
    switch value {
    case let .string(string):
      validateTemplateString(string, path: path, diagnostics: &diagnostics)
    case let .array(values):
      for (index, value) in values.enumerated() {
        validateTemplateValue(value, path: "\(path)[\(index)]", diagnostics: &diagnostics)
      }
    case let .object(object):
      for (key, value) in object {
        validateTemplateValue(value, path: "\(path).\(key)", diagnostics: &diagnostics)
      }
    default:
      return
    }
  }

  private static func validateTemplateString(_ value: String, path: String, diagnostics: inout [EventValidationDiagnostic]) {
    let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#
    let regex = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    regex?.enumerateMatches(in: value, range: range) { match, _, _ in
      guard let match, match.numberOfRanges > 1, let refRange = Range(match.range(at: 1), in: value) else {
        return
      }
      let reference = String(value[refRange])
      if !reference.hasPrefix("event.") && !reference.hasPrefix("source.") && !reference.hasPrefix("binding.") {
        diagnostics.append(.init(code: "INVALID_EVENT_TEMPLATE", path: path, message: "unsupported template reference '\(reference)'"))
      }
    }
  }
}
