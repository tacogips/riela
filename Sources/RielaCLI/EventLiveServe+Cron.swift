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
    parsed: ParsedParityOptions
  ) async throws -> Int {
    let timeZone = source.resolvedTimeZone
    let envelope = ExternalEventEnvelope(
      sourceId: source.id,
      eventId: "\(source.id)-\(Int(scheduledAt.timeIntervalSince1970))",
      provider: "riela",
      eventType: "cron.tick",
      receivedAt: firedAt,
      dedupeKey: "\(source.id):\(Int(scheduledAt.timeIntervalSince1970))",
      input: [
        "scheduledAt": .string(cronISOTimestamp(scheduledAt)),
        "scheduledLocalTime": .string(cronLocalTimestamp(scheduledAt, timeZone: timeZone)),
        "firedAt": .string(cronISOTimestamp(firedAt)),
        "timezone": .string(source.timezone ?? "UTC")
      ]
    )
    let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
      sources: config.sources,
      bindings: config.bindings,
      envelope: envelope
    ))
    guard triggerResult.accepted else {
      return 0
    }
    var dispatchedRun = false
    for trigger in triggerResult.triggers {
      guard let workflowName = trigger.workflowName else {
        continue
      }
      let binding = config.bindings.first { $0.id == trigger.bindingId }
      var routineGate: RoutineDispatchGate?
      if let binding, let routineId = binding.routineId {
        let gate = routineDispatchGate(
          routineId: routineId,
          storeRoot: binding.routineStoreRoot,
          parsed: parsed
        )
        if let skipReason = gate.skipReason {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            pollingTarget: source.id,
            lastIgnoredReason: skipReason
          )
          continue
        }
        routineGate = gate
      }
      _ = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
        workflowName: workflowName,
        runtimeVariables: trigger.runtimeVariables,
        parsed: parsed
      ))
      dispatchedRun = true
      if let routineGate {
        _ = try? routineGate.store.recordRunCompletion(routineId: routineGate.routineId, at: firedAt)
      }
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: source.id,
        lastWorkflowName: workflowName
      )
    }
    return dispatchedRun ? 1 : 0
  }

  /// Routine status is checked in SQLite before every cron dispatch, so a
  /// completed or disabled routine stops firing without restarting the serve
  /// loop even though the event config itself is loaded only at startup.
  private func routineDispatchGate(
    routineId: String,
    storeRoot: String?,
    parsed: ParsedParityOptions
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
      return RoutineDispatchGate(routineId: routineId, store: store, skipReason: nil)
    } catch {
      return RoutineDispatchGate(
        routineId: routineId,
        store: store,
        skipReason: "routine-store-error:\(routineId)"
      )
    }
  }
}

struct RoutineDispatchGate {
  let routineId: String
  let store: RoutineStore
  let skipReason: String?
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

  /// Returns the most recent schedule match in `(after, until]`, coalescing
  /// ticks that were missed while a previous dispatch was still running into
  /// one fire. The scan window is bounded so a long host sleep cannot replay
  /// an unbounded backlog.
  func dueTick(after: Date, until: Date) -> Date? {
    guard let parsed = try? CronSchedule.parse(schedule) else {
      return nil
    }
    let timeZone = resolvedTimeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let lowerBound = max(
      floor(after.timeIntervalSince1970) + 1,
      floor(until.timeIntervalSince1970) - Double(CronSchedule.maximumCatchUpSeconds)
    )
    let upperBound = floor(until.timeIntervalSince1970)
    guard lowerBound <= upperBound else {
      return nil
    }
    var second = upperBound
    while second >= lowerBound {
      let candidate = Date(timeIntervalSince1970: second)
      if parsed.matches(candidate, calendar: calendar) {
        return candidate
      }
      second -= 1
    }
    return nil
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
