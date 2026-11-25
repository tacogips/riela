import Foundation
import RielaCore
import RielaEvents

extension DefaultEventLiveServer {
  func dispatchCronTick(
    source: CronScheduleSource,
    scheduledAt: Date,
    firedAt: Date,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions,
    dispatcher: CronOverlapDispatcher,
    isLatestDueTick: Bool = true,
    coalescedTickCount: Int = 0
  ) async throws -> Int {
    let timeZone = source.resolvedTimeZone
    var input: JSONObject = [
      "scheduledAt": .string(cronISOTimestamp(scheduledAt)),
      "scheduledLocalTime": .string(cronLocalTimestamp(scheduledAt, timeZone: timeZone)),
      "firedAt": .string(cronISOTimestamp(firedAt)),
      "timezone": .string(source.timezone ?? "UTC")
    ]
    if let previous = source.previousTick(before: scheduledAt) {
      input["previousScheduledAt"] = .string(cronISOTimestamp(previous))
      input["previousScheduledLocalTime"] = .string(cronLocalTimestamp(previous, timeZone: timeZone))
    }
    let envelope = ExternalEventEnvelope(
      sourceId: source.id,
      eventId: "\(source.id)-\(Int(scheduledAt.timeIntervalSince1970))",
      provider: "riela",
      eventType: "cron.tick",
      receivedAt: firedAt,
      dedupeKey: "\(source.id):\(Int(scheduledAt.timeIntervalSince1970))",
      input: input
    )
    let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
      sources: config.sources,
      bindings: config.bindings,
      envelope: envelope
    ))
    if try recordReadOnlyEventIfNeeded(
      envelope: envelope, triggerResult: triggerResult, parsed: parsed, eventRoot: eventRoot
    ) { return 1 }
    guard triggerResult.accepted else {
      return 0
    }
    var submitted = false
    for trigger in triggerResult.triggers {
      guard let workflowName = trigger.workflowName else {
        continue
      }
      let binding = config.bindings.first { $0.id == trigger.bindingId }
      let policy = await dispatcher.effectivePolicy(bindingId: trigger.bindingId)
      if policy.policy != .concurrent && !isLatestDueTick {
        continue
      }
      var fire = CronOverlapFire(
        bindingId: trigger.bindingId,
        sourceId: source.id,
        workflowName: workflowName,
        runtimeVariables: trigger.runtimeVariables,
        envelope: envelope,
        scheduledAt: scheduledAt,
        firedAt: firedAt,
        routineId: binding?.routineId,
        routineStoreRoot: binding?.routineStoreRoot,
        coalescedTickCount: policy.policy == .concurrent ? 0 : coalescedTickCount
      )
      if let binding, let routineId = binding.routineId {
        let gate = routineDispatchGate(
          routineId: routineId,
          storeRoot: binding.routineStoreRoot,
          parsed: parsed,
          workflowName: workflowName
        )
        if let skipReason = gate.skipReason {
          // Persisted like the deferred-start gate skip (design §7.1), but the
          // tick still does not count toward --limit (design §6.3).
          await dispatcher.recordRoutineGateSkip(fire, reason: skipReason)
          continue
        }
        fire.botId = gate.botId
      }
      _ = await dispatcher.submit(fire)
      submitted = true
    }
    return submitted ? 1 : 0
  }

  /// Routine status is checked in SQLite before every cron dispatch, so a
  /// completed or disabled routine stops firing without restarting the serve
  /// loop even though the event config itself is loaded only at startup.
  func routineDispatchGate(
    routineId: String,
    storeRoot: String?,
    parsed: ParsedParityOptions,
    workflowName: String? = nil
  ) -> RoutineDispatchGate {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let store = RoutineStore(rootDirectory: RoutineStore.resolveRootDirectory(
      explicit: storeRoot,
      workingDirectory: workingDirectory,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ))
    do {
      guard let record = try store.load(routineId: routineId) else {
        return RoutineDispatchGate(
          routineId: routineId,
          store: store,
          skipReason: "routine-missing:\(routineId)"
        )
      }
      guard record.status == .active else {
        return RoutineDispatchGate(
          routineId: routineId,
          store: store,
          skipReason: "routine-\(record.status.rawValue):\(routineId)"
        )
      }
      if let botId = record.botId {
        let storeRoot = routineSessionStoreRoot(workflowName: workflowName ?? record.workflowName, parsed: parsed)
        if BotRunLinker.isPaused(botId: botId, sessionStoreRoot: storeRoot) == true {
          return RoutineDispatchGate(routineId: routineId, store: store, skipReason: "bot_paused:\(botId)")
        }
      }
      return RoutineDispatchGate(routineId: routineId, store: store, skipReason: nil, botId: record.botId)
    } catch {
      return RoutineDispatchGate(
        routineId: routineId,
        store: store,
        skipReason: "routine-store-error:\(routineId)"
      )
    }
  }
  private func routineSessionStoreRoot(workflowName: String, parsed: ParsedParityOptions) -> String {
    let resolver = triggerDefaultsResolver ?? CLIWorkflowTriggerDefaultsResolver()
    if let root = try? resolver.sessionStoreRoot(workflowName: workflowName, parsed: parsed) {
      return root
    }
    return CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore, scope: parsed.scope,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
  }
}

struct RoutineDispatchGate {
  let routineId: String
  let store: RoutineStore
  let skipReason: String?
  var botId: String?
}

protocol EventWorkflowTriggerDefaultsResolving: Sendable {
  func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings?
  func workflowId(workflowName: String, parsed: ParsedParityOptions) throws -> String?
  func sessionStoreRoot(workflowName: String, parsed: ParsedParityOptions) throws -> String?
}
extension EventWorkflowTriggerDefaultsResolving {
  func workflowId(workflowName: String, parsed: ParsedParityOptions) throws -> String? { nil }
  func sessionStoreRoot(workflowName: String, parsed: ParsedParityOptions) throws -> String? { nil }
}
struct CLIWorkflowTriggerDefaultsResolver: EventWorkflowTriggerDefaultsResolving {
  func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings? {
    try resolve(workflowName: workflowName, parsed: parsed).workflow.triggerDefaults
  }
  func workflowId(workflowName: String, parsed: ParsedParityOptions) throws -> String? {
    try resolve(workflowName: workflowName, parsed: parsed).workflow.workflowId
  }
  func sessionStoreRoot(workflowName: String, parsed: ParsedParityOptions) throws -> String? {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let resolution = WorkflowResolutionOptions(workflowName: workflowName, scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir, workingDirectory: workingDirectory)
    let bundle = try resolve(workflowName: workflowName, parsed: parsed)
    let persisted = CLIWorkflowSessionResolution.resolutionForPersistence(resolution: resolution, resolvedSourceScope: bundle.sourceScope)
    return CLIWorkflowSessionStore.resolveRootDirectory(sessionStore: parsed.sessionStore, scope: persisted.scope, workingDirectory: workingDirectory)
  }
  private func resolve(workflowName: String, parsed: ParsedParityOptions) throws -> ResolvedWorkflowBundle {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let options = WorkflowResolutionOptions(
      workflowName: workflowName,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
    let fileResolver = WorkflowRunCommand().resolver
    let resolver = DefinitionStoreWorkflowBundleResolver(
      inner: fileResolver,
      sessionStore: parsed.sessionStore,
      actor: .init(kind: .cli, id: "events-serve"),
      mode: .lookupOnly
    )
    return try resolver.resolve(options)
  }
}

extension EventLiveConfig {
  func cronSources(eventRoot: URL) throws -> [CronScheduleSource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .cron && boundSourceIds.contains(source.id)
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
        let source = try JSONDecoder().decode(CronScheduleSource.self, from: data)
        _ = try CronSchedule.parse(source.schedule)
        return source
      }
  }
}

struct CronScheduleSource: Decodable, Equatable, Sendable {
  var id: String
  var schedule: String
  var timezone: String?

  var resolvedTimeZone: TimeZone {
    timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
  }

  /// Returns each matching second in `(after, until]`, within the bounded scan window.
  func dueTicks(after: Date, until: Date) -> [Date] {
    guard let parsed = try? CronSchedule.parse(schedule) else {
      return []
    }
    let timeZone = resolvedTimeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let lowerBound = max(
      floor(after.timeIntervalSince1970) + 1,
      floor(until.timeIntervalSince1970) - Double(CronSchedule.maximumCatchUpSeconds)
    )
    let upperBound = floor(until.timeIntervalSince1970)
    guard lowerBound <= upperBound else { return [] }
    var ticks: [Date] = []
    var second = lowerBound
    while second <= upperBound {
      let candidate = Date(timeIntervalSince1970: second)
      if parsed.matches(candidate, calendar: calendar) {
        ticks.append(candidate)
      }
      second += 1
    }
    return ticks
  }

  func previousTick(before scheduledAt: Date) -> Date? {
    guard let parsed = try? CronSchedule.parse(schedule) else {
      return nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = resolvedTimeZone
    return parsed.previousOccurrence(before: scheduledAt, calendar: calendar)
  }
}

private func cronISOTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

private func cronLocalTimestamp(_ date: Date, timeZone: TimeZone) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = timeZone
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return formatter.string(from: date)
}
