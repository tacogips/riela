import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaEvents
import RielaObservability

protocol EventLiveServing: Sendable {
  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult
}

protocol TelegramGatewayAPI: Sendable {
  func getUpdates(request: TelegramGetUpdatesRequest) async throws -> [TelegramUpdate]
  func getFile(request: TelegramGetFileRequest) async throws -> TelegramFile
  func downloadFile(request: TelegramDownloadFileRequest) async throws -> Data
  func sendMessage(request: TelegramSendMessageRequest) async throws
}

protocol SlackGatewayAPI: Sendable {
  func getMessages(request: SlackGetMessagesRequest) async throws -> [SlackMessage]
  func sendMessage(request: SlackSendMessageRequest) async throws
}

protocol EventWorkflowRunning: Sendable {
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult
}

protocol EventWorkflowTriggerDefaultsResolving: Sendable {
  func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings?
}

struct EventWorkflowRunRequest: Sendable {
  var workflowName: String
  var runtimeVariables: JSONObject
  var parsed: ParsedParityOptions
  var onSessionStarted: (@Sendable (String) -> Void)?
}

struct EventResolvedAttachmentInputs: Equatable, Sendable {
  var attachments: [JSONObject]
  var imagePaths: [String]
  var attachmentText: String

  static let empty = EventResolvedAttachmentInputs(attachments: [], imagePaths: [], attachmentText: "")
}

struct EventLiveSourcePollFailure: Error, CustomStringConvertible, Sendable {
  var underlyingDescription: String

  init(_ error: Error) {
    self.underlyingDescription = String(describing: error)
  }

  var description: String {
    underlyingDescription
  }
}

struct DefaultEventLiveServer: EventLiveServing {
  var telegramAPI: any TelegramGatewayAPI
  var discordAPI: any DiscordGatewayAPI
  var slackAPI: any SlackGatewayAPI
  var matrixAPI: any MatrixGatewayAPI
  var webhookyStreamer: any WebhookyRecordStreaming
  var workflowRunner: any EventWorkflowRunning
  var telemetry: any RielaTelemetry
  var runtimeEnvironment: EventRuntimeEnvironment?
  var clock: any EventServeClock
  var triggerDefaultsResolver: (any EventWorkflowTriggerDefaultsResolving)?
  var cancelSettleTimeout: Duration

  private static let serveRecordLock = NSLock()

  init(
    telegramAPI: any TelegramGatewayAPI = URLSessionTelegramGatewayAPI(),
    discordAPI: any DiscordGatewayAPI = URLSessionDiscordGatewayAPI(),
    slackAPI: any SlackGatewayAPI = URLSessionSlackGatewayAPI(),
    matrixAPI: any MatrixGatewayAPI = URLSessionMatrixGatewayAPI(),
    webhookyStreamer: any WebhookyRecordStreaming = SDKWebhookyRecordStreamer(),
    workflowRunner: any EventWorkflowRunning = CLIEventWorkflowRunner(),
    telemetry: (any RielaTelemetry)? = nil,
    clock: any EventServeClock = SystemEventServeClock(),
    triggerDefaultsResolver: (any EventWorkflowTriggerDefaultsResolving)? = nil,
    cancelSettleTimeout: Duration = .seconds(30)
  ) {
    self.telegramAPI = telegramAPI
    self.discordAPI = discordAPI
    self.slackAPI = slackAPI
    self.matrixAPI = matrixAPI
    self.webhookyStreamer = webhookyStreamer
    self.workflowRunner = workflowRunner
    self.telemetry = telemetry ?? RielaTelemetryFactory.make(configuration: .fromEnvironment(
      CLIRuntimeEnvironment.mergedProcessEnvironment(),
      surface: .eventsServe
    ))
    self.clock = clock
    self.triggerDefaultsResolver = triggerDefaultsResolver
    self.cancelSettleTimeout = cancelSettleTimeout
  }

  func serve(eventRoot: URL, target: String?, parsed: ParsedParityOptions, output: WorkflowOutputFormat) async throws -> ScopedParityCommandResult {
    if parsed.runtimeEnvironmentChannel && parsed.runtimeEnvironmentFile != nil {
      throw CLIUsageError("environment_channel_cannot_load_sources")
    }
    let required = workflowRunner is CLIEventWorkflowRunner
      ? try await eventRequiredEnvironment(eventRoot: eventRoot, target: target, parsed: parsed) : []
    let prepared = try await CLIRuntimeEnvironmentPreparation.prepare(path: parsed.runtimeEnvironmentFile,
      required: parsed.runtimeEnvironmentChannel ? [] : required, base: CLIRuntimeEnvironment.mergedProcessEnvironment(),
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    let runtime = EventRuntimeEnvironment(base: prepared, requiresBootstrap: parsed.runtimeEnvironmentChannel)
    let channel = parsed.runtimeEnvironmentChannel ? RuntimeEnvironmentChannel(state: runtime) : nil
    defer { channel?.stop() }
    try await runtime.awaitInitial()
    var server = self
    server.runtimeEnvironment = runtime
    let captured = try await runtime.capture()
    if required.contains(where: { captured[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }) {
      throw CLIUsageError("environment_required_missing")
    }
    return try await CLIRuntimeEnvironment.$captured.withValue(captured) {
      try await server.servePrepared(eventRoot: eventRoot, target: target, parsed: parsed)
    }
  }

  private func servePrepared(eventRoot: URL, target: String?, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    let startedAt = try serveStartedAt(parsed: parsed)
    let config = try EventLiveConfig.load(eventRoot: eventRoot)
    let enabledSources = config.enabledSources(target: target)
    await recordServeStart(sourceCount: enabledSources.count)
    let unsupported = unsupportedLiveSourceSummary(enabledSources)
    if !unsupported.isEmpty {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: unsupported)
    }
    let liveConfig = filteredLiveConfig(config, sources: enabledSources)

    let telegramSources = try liveConfig.telegramSources(eventRoot: eventRoot)
    let discordSources = try liveConfig.discordSources(eventRoot: eventRoot)
    let slackSources = try liveConfig.slackSources(eventRoot: eventRoot)
    let matrixSources = try liveConfig.matrixSources(eventRoot: eventRoot)
    let cronSources = try liveConfig.cronSources(eventRoot: eventRoot)
    let (overlapPolicies, overlapPolicyRecords) = try resolveCronOverlapPolicies(
      bindings: liveConfig.bindings, cronSources: cronSources, parsed: parsed, eventRoot: eventRoot
    )
    let webhookySources = try liveConfig.webhookySources(eventRoot: eventRoot)
    let fileChangeSources: [FileChangeWatchSource]
    do {
      fileChangeSources = try liveConfig.fileChangeSources(eventRoot: eventRoot)
    } catch {
      try? writeServeRecord(eventRoot: eventRoot, status: "failed", detail: String(describing: error))
      throw error
    }
    guard !telegramSources.isEmpty || !discordSources.isEmpty || !slackSources.isEmpty || !matrixSources.isEmpty
      || !cronSources.isEmpty || !webhookySources.isEmpty || !fileChangeSources.isEmpty else {
      return liveUnavailable(eventRoot: eventRoot, actionTarget: target, unsupportedSources: enabledSources.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ","))
    }

    try validateLiveSourceEnvironments(
      telegram: telegramSources, discord: discordSources, slack: slackSources,
      matrix: matrixSources, webhooky: webhookySources, eventRoot: eventRoot
    )
    try writeServeRecord(eventRoot: eventRoot, status: "ready", overlapPolicies: overlapPolicyRecords)
    var processedEvents = 0
    let maximumEvents = parsed.limit
    let serveStartedAt = clock.now()
    var cronLastCheckedAt: [String: Date] = Dictionary(
      uniqueKeysWithValues: cronSources.map { ($0.id, serveStartedAt) }
    )
    // Startup snapshots so files that already exist never dispatch events;
    // only changes observed after listener start are announced.
    let fileChangeStates = try makeFileChangeStates(fileChangeSources, eventRoot: eventRoot)
    let webhookyBuffer = WebhookyRecordBuffer()
    let webhookyTasks = startWebhookyStreams(
      sources: webhookySources,
      buffer: webhookyBuffer,
      eventRoot: eventRoot
    )
    defer {
      webhookyTasks.forEach { $0.cancel() }
    }
    let webhookySourcesById = Dictionary(uniqueKeysWithValues: webhookySources.map { ($0.id, $0) })
    let dispatcher = CronOverlapDispatcher(
      server: self, eventRoot: eventRoot, parsed: parsed, policies: overlapPolicies,
      clock: clock, cancelSettleTimeout: cancelSettleTimeout
    )
    do {
      repeat {
      for (sourceId, record) in await webhookyBuffer.drain() {
        guard let source = webhookySourcesById[sourceId] else {
          continue
        }
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "webhooky"
        ) {
          try await dispatchWebhookyRecord(
            source: source,
            record: record,
            config: liveConfig,
            eventRoot: eventRoot,
            parsed: parsed
          )
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in cronSources {
        let now = clock.now()
        let lastCheckedAt = cronLastCheckedAt[source.id] ?? now
        cronLastCheckedAt[source.id] = now
        let ticks = source.dueTicks(after: lastCheckedAt, until: now)
        guard !ticks.isEmpty else {
          continue
        }
        for (index, scheduledAt) in ticks.enumerated() {
          processedEvents += try await pollSourceSafely(
            eventRoot: eventRoot,
            sourceId: source.id,
            sourceKind: "cron"
          ) {
            try await dispatchCronTick(
              source: source, scheduledAt: scheduledAt, firedAt: now,
              config: liveConfig, eventRoot: eventRoot, parsed: parsed,
              dispatcher: dispatcher, isLatestDueTick: index == ticks.count - 1,
              coalescedTickCount: ticks.count - 1
            )
          }
          if let maximumEvents, processedEvents >= maximumEvents {
            try await drainHonoringCancellation(dispatcher)
            await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
            return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
          }
        }
      }
      for source in fileChangeSources {
        guard let state = fileChangeStates[source.id] else {
          continue
        }
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "file-change"
        ) {
          try await pollFileChangeSource(
            source: source,
            state: state,
            config: liveConfig,
            eventRoot: eventRoot,
            parsed: parsed
          )
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in telegramSources {
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "telegram"
        ) {
          try await pollTelegramSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in discordSources {
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "discord"
        ) {
          try await pollDiscordSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in slackSources {
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "slack"
        ) {
          try await pollSlackSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      for source in matrixSources {
        processedEvents += try await pollSourceSafely(
          eventRoot: eventRoot,
          sourceId: source.id,
          sourceKind: "matrix"
        ) {
          try await pollMatrixSource(source, config: liveConfig, eventRoot: eventRoot, parsed: parsed)
        }
        if let maximumEvents, processedEvents >= maximumEvents {
          try await drainHonoringCancellation(dispatcher)
          await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
          return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
        }
      }
      let noGatewaySourcesRemain = telegramSources.isEmpty && discordSources.isEmpty
        && slackSources.isEmpty && matrixSources.isEmpty
      if maximumEvents == nil || noGatewaySourcesRemain {
        try await clock.sleep(for: webhookySources.isEmpty ? .seconds(1) : .milliseconds(200))
      }
      } while maximumEvents == nil || processedEvents < (maximumEvents ?? 0)

      try await drainHonoringCancellation(dispatcher)
    } catch {
      await Task { await dispatcher.shutdownCancelling() }.value
      throw error
    }

    await recordEventsServeCompletion(startedAt: startedAt, processedEvents: processedEvents)
    return liveReady(eventRoot: eventRoot, actionTarget: target, processedEvents: processedEvents)
  }

}

func drainHonoringCancellation(_ dispatcher: CronOverlapDispatcher) async throws {
  await withTaskCancellationHandler {
    await dispatcher.drain()
  } onCancel: {
    Task { await dispatcher.abandonDrain() }
  }
  try Task.checkCancellation()
}

extension DefaultEventLiveServer {
  private func serveStartedAt(parsed: ParsedParityOptions) throws -> Date {
    _ = try EventReadOnlyPolicy.isEnabled(parsed: parsed, environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    return clock.now()
  }

  private func filteredLiveConfig(_ config: EventLiveConfig, sources: [EventSourceContract]) -> EventLiveConfig {
    let sourceIds = Set(sources.map(\.id))
    return EventLiveConfig(sources: sources, bindings: config.bindings.filter { sourceIds.contains($0.sourceId) })
  }

  private func recordServeStart(sourceCount: Int) async {
    await telemetry.recordLog(RielaTelemetryLog(
      name: "riela.events.serve.start",
      attributes: ["runtime.surface": "events-serve", "event.source.count": String(sourceCount)]
    ))
  }

  private func unsupportedLiveSourceSummary(_ sources: [EventSourceContract]) -> String {
    sources.filter { !$0.kind.supportsLiveEventServe }
      .map { "\($0.id):\($0.kind.rawValue)" }
      .joined(separator: ",")
  }

  private func resolveCronOverlapPolicies(
    bindings: [EventBindingContract],
    cronSources: [CronScheduleSource],
    parsed: ParsedParityOptions,
    eventRoot: URL
  ) throws -> ([String: EffectiveEventOverlapPolicy], JSONObject) {
    var policies: [String: EffectiveEventOverlapPolicy] = [:]
    var records: JSONObject = [:]
    let resolver = triggerDefaultsResolver
      ?? (workflowRunner is CLIEventWorkflowRunner ? CLIWorkflowTriggerDefaultsResolver() : nil)
    for binding in bindings where binding.enabled && cronSources.contains(where: { $0.id == binding.sourceId }) {
      guard let workflowName = binding.workflowName else { continue }
      var workflowDefaults: EventOverlapSettings?
      var unresolved = false
      if binding.overlapSettings?.overlapPolicy == nil, let resolver {
        do {
          workflowDefaults = try resolver.triggerDefaults(workflowName: workflowName, parsed: parsed)
        } catch {
          unresolved = true
        }
      }
      let effective: EffectiveEventOverlapPolicy
      do {
        effective = try resolveEventOverlapPolicy(binding: binding.overlapSettings, workflow: workflowDefaults)
      } catch {
        let message = String(describing: error)
        try? writeServeRecord(eventRoot: eventRoot, status: "failed", detail: message)
        throw CLIUsageError(message)
      }
      policies[binding.id] = effective
      var entry: JSONObject = ["policy": .string(effective.policy.rawValue), "source": .string(effective.source.rawValue)]
      if let cap = effective.maxQueuedRuns { entry["maxQueuedRuns"] = .number(Double(cap)) }
      if let cap = effective.maxConcurrentRuns { entry["maxConcurrentRuns"] = .number(Double(cap)) }
      if unresolved { entry["diagnostic"] = .string("overlap_policy_workflow_unresolved") }
      records[binding.id] = .object(entry)
    }
    return (policies, records)
  }

  private func validateLiveSourceEnvironments(
    telegram: [TelegramGatewaySource], discord: [DiscordGatewaySource], slack: [SlackGatewaySource],
    matrix: [MatrixGatewaySource], webhooky: [WebhookyStreamSource], eventRoot: URL
  ) throws {
    do {
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      try telegram.forEach { try $0.validateEnvironment(environment: environment) }
      try discord.forEach { try $0.validateEnvironment(environment: environment) }
      try slack.forEach { try $0.validateEnvironment(environment: environment) }
      try matrix.forEach { try $0.validateEnvironment(environment: environment) }
      try webhooky.forEach { try $0.validateEnvironment(environment: environment) }
    } catch {
      try? writeServeRecord(eventRoot: eventRoot, status: "failed", detail: String(describing: error))
      throw error
    }
  }

  private func makeFileChangeStates(
    _ sources: [FileChangeWatchSource], eventRoot: URL
  ) throws -> [String: FileChangeWatchState] {
    do {
      return Dictionary(uniqueKeysWithValues: try sources.map { ($0.id, try FileChangeWatchState(source: $0)) })
    } catch {
      try? writeServeRecord(eventRoot: eventRoot, status: "failed", detail: String(describing: error))
      throw error
    }
  }

  private func recordEventsServeCompletion(startedAt: Date, processedEvents: Int) async {
    let attributes = [
      "runtime.surface": "events-serve",
      "event.count": String(processedEvents),
      "status": "completed"
    ]
    await telemetry.recordSpan(RielaTelemetrySpan(
      name: "riela.events.serve",
      status: .ok,
      startedAt: startedAt,
      attributes: attributes
    ))
    await telemetry.recordMetric(RielaTelemetryMetric(
      name: "riela.events.processed.count",
      value: Double(processedEvents),
      attributes: attributes
    ))
    await telemetry.flush(timeout: .seconds(2))
  }

  private func pollSourceSafely(
    eventRoot: URL,
    sourceId: String,
    sourceKind: String,
    poll: () async throws -> Int
  ) async throws -> Int {
    do {
      return try await poll()
    } catch let error as EventLiveSourcePollFailure {
      let message = error.description
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        detail: message,
        lastIgnoredReason: "\(sourceKind)-poll-failed",
        lastEnvelopeSourceId: sourceId,
        lastDiagnosticCodes: "event_source_poll_failed"
      )
      await telemetry.recordLog(RielaTelemetryLog(
        name: "riela.events.source.poll.failed",
        attributes: [
          "runtime.surface": "events-serve",
          "event.source.id": sourceId,
          "event.source.kind": sourceKind,
          "error": message
        ]
      ))
      return 0
    }
  }

  /// A failed workflow run for one event must not kill the listener: the
  /// failure is recorded on the serve record (and telemetry) and the source
  /// keeps polling, mirroring how file-change dispatch already behaves.
  func recordWorkflowDispatchFailure(
    eventRoot: URL,
    sourceKind: String,
    sourceId: String,
    workflowName: String,
    error: any Error
  ) async {
    let message = String(describing: error)
    try? writeServeRecord(
      eventRoot: eventRoot,
      status: "ready",
      detail: message,
      pollingTarget: sourceId,
      lastIgnoredReason: "\(sourceKind)-workflow-failed",
      lastWorkflowName: workflowName,
      lastEnvelopeSourceId: sourceId
    )
    await telemetry.recordLog(RielaTelemetryLog(
      name: "riela.events.workflow.dispatch.failed",
      attributes: [
        "runtime.surface": "events-serve",
        "event.source.id": sourceId,
        "event.source.kind": sourceKind,
        "workflow.name": workflowName,
        "error": message
      ]
    ))
  }

  /// Runs the workflow for one telegram update. A failed run is recorded on
  /// the serve record and the message is marked seen so the listener keeps
  /// polling instead of exiting; `nil` tells the caller to skip the update.
  private func runTelegramWorkflowOrRecordFailure(
    workflowName: String,
    runtimeVariables: JSONObject,
    parsed: ParsedParityOptions,
    eventRoot: URL,
    source: TelegramGatewaySource,
    update: TelegramUpdate,
    dedupeStore: TelegramMessageDedupeStore
  ) async throws -> WorkflowRunResult? {
    do {
      return try await runEventWorkflow(EventWorkflowRunRequest(
        workflowName: workflowName,
        runtimeVariables: runtimeVariables,
        parsed: parsed
      ))
    } catch {
      await recordWorkflowDispatchFailure(
        eventRoot: eventRoot,
        sourceKind: "telegram",
        sourceId: source.id,
        workflowName: workflowName,
        error: error
      )
      if let message = update.message {
        try dedupeStore.markSeen(message: message)
      }
      return nil
    }
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
      let updates: [TelegramUpdate]
      do {
        updates = try await telegramAPI.getUpdates(request: TelegramGetUpdatesRequest(
          token: target.token,
          offset: offset,
          timeoutSeconds: pollingTimeoutSeconds(for: target, source: source),
          limit: parsed.limit ?? source.polling.limit
        ))
      } catch {
        throw EventLiveSourcePollFailure(error)
      }
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: target.recordId,
        pollingTargetCount: targets.count,
        lastUpdateCount: updates.count
      )
      for update in updates {
        observedUpdates += 1
        if try !EventReadOnlyPolicy.isEnabled(parsed: parsed, environment: environment) {
          try offsetStore.saveOffset(update.updateId + 1)
        }
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
          try offsetStore.saveOffset(update.updateId + 1)
          continue
        }
        if let message = update.message, try dedupeStore.hasSeen(message: message) {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            lastIgnoredReason: "telegram-duplicate-message"
          )
          try offsetStore.saveOffset(update.updateId + 1)
          continue
        }
        let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
          sources: config.sources,
          bindings: config.bindings,
          envelope: envelope
        ))
        if try recordReadOnlyEventIfNeeded(
          envelope: envelope, triggerResult: triggerResult, parsed: parsed, eventRoot: eventRoot
        ) { try offsetStore.saveOffset(update.updateId + 1); continue }
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
          guard let result = try await runTelegramWorkflowOrRecordFailure(
            workflowName: workflowName,
            runtimeVariables: trigger.runtimeVariables,
            parsed: parsed,
            eventRoot: eventRoot,
            source: source,
            update: update,
            dedupeStore: dedupeStore
          ) else {
            continue
          }
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
    lastBindingIds: String? = nil,
    overlapPolicies: JSONObject? = nil
  ) throws {
    Self.serveRecordLock.lock()
    defer { Self.serveRecordLock.unlock() }
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
    if let overlapPolicies {
      record["overlapPolicies"] = .object(overlapPolicies)
    }
    try jsonString(record).write(
      to: recordURL,
      atomically: true,
      encoding: .utf8
    )
  }
}

struct CLIWorkflowTriggerDefaultsResolver: EventWorkflowTriggerDefaultsResolving {
  func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings? {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let options = WorkflowResolutionOptions(
      workflowName: workflowName,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
    return try WorkflowRunCommand().resolver.resolve(options).workflow.triggerDefaults
  }
}

struct CLIEventWorkflowRunner: EventWorkflowRunning {
  var command: WorkflowRunCommand

  init(command: WorkflowRunCommand = WorkflowRunCommand()) {
    self.command = command
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    guard try !EventReadOnlyPolicy.isEnabled(
      parsed: request.parsed, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ) else { throw EventReadOnlyDispatchBlocked() }
    let workingDirectory = request.parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    var observedCommand = command
    observedCommand.sessionStartedObserver = request.onSessionStarted
    let result = await observedCommand.run(WorkflowRunOptions(
      target: request.workflowName,
      resolution: WorkflowResolutionOptions(
        workflowName: request.workflowName,
        scope: request.parsed.scope,
        workflowDefinitionDir: request.parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory
      ),
      variables: try jsonString(request.runtimeVariables),
      nodePatch: request.parsed.nodePatch,
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
    // Advisory loop-concurrency skip (design S11): no session was created;
    // surface the typed skip record on the event receipt instead of a
    // decode failure.
    if result.stdout.contains("\"type\":\"loop_concurrency_skipped\"") {
      throw CLIUsageError(
        "loop concurrency skipped: " + result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      )
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

  func slackSources(eventRoot: URL) throws -> [SlackGatewaySource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .slackGateway && boundSourceIds.contains(source.id)
    }.map(\.id))
    return try Self.decodeSourceDirectory(sourceDirectory, sourceIds: sourceIds, as: SlackGatewaySource.self)
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
