import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents

protocol EventLiveServing: Sendable {
  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult
}

protocol TelegramGatewayAPI: Sendable {
  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate]
  func getFile(request: TelegramGetFileRequest) async throws -> TelegramFile
  func downloadFile(request: TelegramDownloadFileRequest) async throws -> Data
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

struct EventResolvedAttachmentInputs: Equatable, Sendable {
  var attachments: [JSONObject]
  var imagePaths: [String]
  var attachmentText: String

  static let empty = EventResolvedAttachmentInputs(attachments: [], imagePaths: [], attachmentText: "")
}

struct DefaultEventLiveServer: EventLiveServing {
  var telegramAPI: any TelegramGatewayAPI
  var discordAPI: any DiscordGatewayAPI
  var workflowRunner: any EventWorkflowRunning

  init(
    telegramAPI: any TelegramGatewayAPI = URLSessionTelegramGatewayAPI(),
    discordAPI: any DiscordGatewayAPI = URLSessionDiscordGatewayAPI(),
    workflowRunner: any EventWorkflowRunning = CLIEventWorkflowRunner()
  ) {
    self.telegramAPI = telegramAPI
    self.discordAPI = discordAPI
    self.workflowRunner = workflowRunner
  }

  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult {
    let config = try EventLiveConfig.load(eventRoot: eventRoot)
    let enabledSources = config.enabledSources(target: target)
    let unsupported = enabledSources
      .filter { ![.telegramGateway, .discordGateway].contains($0.kind) }
      .map { "\($0.id):\($0.kind.rawValue)" }
      .joined(separator: ",")
    guard unsupported.isEmpty else {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: unsupported)
    }
    let enabledSourceIds = Set(enabledSources.map(\.id))
    let liveConfig = EventLiveConfig(
      sources: enabledSources,
      bindings: config.bindings.filter { enabledSourceIds.contains($0.sourceId) }
    )

    let telegramSources = try liveConfig.telegramSources(eventRoot: eventRoot)
    let discordSources = try liveConfig.discordSources(eventRoot: eventRoot)
    guard !telegramSources.isEmpty || !discordSources.isEmpty else {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: enabledSources.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ","))
    }

    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    do {
      try telegramSources.forEach { try $0.validateEnvironment(environment: environment) }
      try discordSources.forEach { try $0.validateEnvironment(environment: environment) }
    } catch {
      try? writeServeRecord(eventRoot: eventRoot, status: "failed", detail: String(describing: error))
      throw error
    }
    try writeServeRecord(eventRoot: eventRoot, status: "ready")
    var processedEvents = 0
    let maximumEvents = parsed.limit
    repeat {
      for source in telegramSources {
        processedEvents += try await pollTelegramSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
        if let maximumEvents, processedEvents >= maximumEvents {
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in discordSources {
        processedEvents += try await pollDiscordSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
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
    var observedUpdates = 0
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let targets = try source.pollingTargets(environment: environment)
    let dedupeStore = TelegramMessageDedupeStore(eventRoot: eventRoot, source: source)
    for target in targets {
      let offsetStore = TelegramOffsetStore(eventRoot: eventRoot, source: source, targetId: target.id)
      let offset = try offsetStore.loadOffset()
      let updates = try await telegramAPI.getUpdates(request: TelegramGetUpdatesRequest(
        token: target.token,
        offset: offset,
        timeoutSeconds: pollingTimeoutSeconds(for: target, source: source),
        limit: parsed.limit ?? source.polling.limit
      ))
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: target.recordId,
        pollingTargetCount: targets.count,
        lastUpdateCount: updates.count
      )
      for update in updates {
        observedUpdates += 1
        try offsetStore.saveOffset(update.updateId + 1)
        let resolvedAttachments: EventResolvedAttachmentInputs
        if let message = update.message {
          resolvedAttachments = try await resolveTelegramAttachments(
            source: source,
            message: message,
            eventRoot: eventRoot,
            token: target.token
          )
        } else {
          resolvedAttachments = .empty
        }
        guard let envelope = source.envelope(
          from: update,
          eventRoot: eventRoot,
          resolvedAttachments: resolvedAttachments
        ) else {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            lastIgnoredReason: "telegram-envelope-filtered-or-empty"
          )
          continue
        }
        if let message = update.message, try dedupeStore.hasSeen(message: message) {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            lastIgnoredReason: "telegram-duplicate-message"
          )
          continue
        }
        let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
          sources: config.sources,
          bindings: config.bindings,
          envelope: envelope
        ))
        guard triggerResult.accepted else {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            lastIgnoredReason: "telegram-trigger-not-accepted",
            lastTriggerCount: triggerResult.triggers.count,
            lastEnvelopeSourceId: envelope.sourceId,
            lastEnvelopeEventType: envelope.eventType.rawValue,
            lastEnvelopeConversationId: envelope.conversation?["id"]?.stringValue,
            lastDiagnosticCodes: triggerResult.diagnostics.map(\.code).joined(separator: ","),
            lastBindingIds: config.bindings.map(\.id).joined(separator: ",")
          )
          continue
        }
        for trigger in triggerResult.triggers {
          guard let workflowName = trigger.workflowName else {
            try? writeServeRecord(
              eventRoot: eventRoot,
              status: "ready",
              lastIgnoredReason: "telegram-trigger-missing-workflow",
              lastTriggerCount: triggerResult.triggers.count
            )
            continue
          }
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            lastIgnoredReason: "",
            lastTriggerCount: triggerResult.triggers.count,
            lastWorkflowName: workflowName
          )
          let result = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
            workflowName: workflowName,
            runtimeVariables: trigger.runtimeVariables,
            parsed: parsed
          ))
          let replies = try await dispatchTelegramReplies(
            result: result,
            source: source,
            envelope: envelope,
            sourceToken: target.token
          )
          if let message = update.message {
            try TelegramConversationHistoryStore(eventRoot: eventRoot, source: source)
              .appendExchange(message: message, replies: replies)
          }
          if !replies.isEmpty {
            try? writeServeRecord(
              eventRoot: eventRoot,
              status: "ready",
              lastReplyDispatchCount: replies.count,
              lastReplyAs: replies.compactMap(\.replyAs).joined(separator: ",")
            )
          }
          if let message = update.message {
            try dedupeStore.markSeen(message: message)
          }
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

  private func pollingTimeoutSeconds(for target: TelegramPollingTarget, source: TelegramGatewaySource) -> Int {
    guard target.id != nil else {
      return source.polling.timeoutSeconds
    }
    return min(source.polling.timeoutSeconds, 2)
  }

  private func resolveTelegramAttachments(
    source: TelegramGatewaySource,
    message: TelegramMessage,
    eventRoot: URL,
    token: String
  ) async throws -> EventResolvedAttachmentInputs {
    guard source.attachments.includePhotos, let photo = message.largestPhoto else {
      return .empty
    }
    var descriptor = photo.normalizedDescriptor
    var imagePaths: [String] = []
    if source.attachments.resolveFilePaths {
      let file = try await telegramAPI.getFile(request: TelegramGetFileRequest(token: token, fileId: photo.fileId))
      if let filePath = file.filePath {
        let data = try await telegramAPI.downloadFile(request: TelegramDownloadFileRequest(token: token, filePath: filePath))
        let localURL = telegramAttachmentURL(
          eventRoot: eventRoot,
          source: source,
          message: message,
          photo: photo,
          remoteFilePath: filePath
        )
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        descriptor["path"] = .string(localURL.path)
        descriptor["remoteFilePath"] = .string(filePath)
        imagePaths.append(localURL.path)
      }
    }
    return EventResolvedAttachmentInputs(
      attachments: [descriptor],
      imagePaths: imagePaths,
      attachmentText: message.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
  }

  private func telegramAttachmentURL(
    eventRoot: URL,
    source: TelegramGatewaySource,
    message: TelegramMessage,
    photo: TelegramPhotoSize,
    remoteFilePath: String
  ) -> URL {
    let remoteExtension = URL(fileURLWithPath: remoteFilePath).pathExtension
    let fileExtension = remoteExtension.isEmpty ? "jpg" : safeTelegramStorageComponent(remoteExtension)
    return eventRoot
      .appendingPathComponent("attachments", isDirectory: true)
      .appendingPathComponent("telegram", isDirectory: true)
      .appendingPathComponent(safeTelegramStorageComponent(source.id), isDirectory: true)
      .appendingPathComponent(safeTelegramStorageComponent(message.chat.id), isDirectory: true)
      .appendingPathComponent(
        "\(safeTelegramStorageComponent(message.messageId))-\(safeTelegramStorageComponent(photo.fileId)).\(fileExtension)"
      )
  }

  func liveUnavailable(eventRoot: URL, actionTarget: String?, unsupportedSources: String) -> ScopedParityCommandResult {
    ScopedParityCommandResult(
      scope: "events",
      command: "serve",
      target: actionTarget,
      status: "failed",
      records: [
        "eventRoot=\(eventRoot.path)",
        "mode=event-live",
        "status=unavailable",
        "unsupportedLiveSources=\(unsupportedSources)"
      ]
    )
  }

  func liveReady(eventRoot: URL, actionTarget: String?, processedEvents: Int) -> ScopedParityCommandResult {
    ScopedParityCommandResult(
      scope: "events",
      command: "serve",
      target: actionTarget,
      status: "ok",
      records: [
        "eventRoot=\(eventRoot.path)",
        "mode=event-live",
        "status=ready",
        "processedEvents=\(processedEvents)"
      ]
    )
  }

  func writeServeRecord(
    eventRoot: URL,
    status: String,
    detail: String? = nil,
    pollingTarget: String? = nil,
    pollingTargetCount: Int? = nil,
    lastUpdateCount: Int? = nil,
    lastReplyDispatchCount: Int? = nil,
    lastReplyAs: String? = nil,
    lastIgnoredReason: String? = nil,
    lastTriggerCount: Int? = nil,
    lastWorkflowName: String? = nil,
    lastEnvelopeSourceId: String? = nil,
    lastEnvelopeEventType: String? = nil,
    lastEnvelopeConversationId: String? = nil,
    lastDiagnosticCodes: String? = nil,
    lastBindingIds: String? = nil
  ) throws {
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    let recordURL = eventRoot.appendingPathComponent("serve-record.json")
    var record: JSONObject = {
      guard let data = try? Data(contentsOf: recordURL),
        case let .object(existing) = try? JSONDecoder().decode(JSONValue.self, from: data)
      else {
        return [:]
      }
      return existing
    }()
    record["eventRoot"] = .string(eventRoot.path)
    record["status"] = .string(status)
    record["mode"] = .string("event-live")
    record["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
    if let detail {
      record["detail"] = .string(detail)
    } else if status != "failed" {
      record.removeValue(forKey: "detail")
    }
    if let pollingTarget {
      record["lastPollingTarget"] = .string(pollingTarget)
    }
    if let pollingTargetCount {
      record["pollingTargetCount"] = .number(Double(pollingTargetCount))
    }
    if let lastUpdateCount {
      record["lastUpdateCount"] = .number(Double(lastUpdateCount))
    }
    if let lastReplyDispatchCount {
      record["lastReplyDispatchCount"] = .number(Double(lastReplyDispatchCount))
    }
    if let lastReplyAs, !lastReplyAs.isEmpty {
      record["lastReplyAs"] = .string(lastReplyAs)
    }
    if let lastIgnoredReason {
      if lastIgnoredReason.isEmpty {
        record.removeValue(forKey: "lastIgnoredReason")
      } else {
        record["lastIgnoredReason"] = .string(lastIgnoredReason)
      }
    }
    if let lastTriggerCount {
      record["lastTriggerCount"] = .number(Double(lastTriggerCount))
    }
    if let lastWorkflowName, !lastWorkflowName.isEmpty {
      record["lastWorkflowName"] = .string(lastWorkflowName)
    }
    if let lastEnvelopeSourceId {
      record["lastEnvelopeSourceId"] = .string(lastEnvelopeSourceId)
    }
    if let lastEnvelopeEventType {
      record["lastEnvelopeEventType"] = .string(lastEnvelopeEventType)
    }
    if let lastEnvelopeConversationId {
      record["lastEnvelopeConversationId"] = .string(lastEnvelopeConversationId)
    }
    if let lastDiagnosticCodes {
      record["lastDiagnosticCodes"] = .string(lastDiagnosticCodes)
    }
    if let lastBindingIds {
      record["lastBindingIds"] = .string(lastBindingIds)
    }
    try jsonString(record).write(
      to: recordURL,
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
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .telegramGateway && boundSourceIds.contains(source.id)
    }.map(\.id))
    return try Self.decodeSourceDirectory(sourceDirectory, sourceIds: sourceIds, as: TelegramGatewaySource.self)
  }

  func enabledSources(target: String?) -> [EventSourceContract] {
    let enabled = sources.filter(\.enabled)
    guard let target, !target.isEmpty else {
      return enabled
    }
    return enabled.filter { $0.id == target }
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

  private static func decodeSourceDirectory<T: Decodable>(_ directory: URL, sourceIds: Set<String>, as type: T.Type) throws -> [T] {
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
        return try JSONDecoder().decode(type, from: data)
      }
  }
}

private struct EventLiveConfigFile: Codable {
  var sources: [EventSourceContract]
  var bindings: [EventBindingContract]
}
