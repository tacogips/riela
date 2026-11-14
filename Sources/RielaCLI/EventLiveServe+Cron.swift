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
    for trigger in triggerResult.triggers {
      guard let workflowName = trigger.workflowName else {
        continue
      }
      _ = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
        workflowName: workflowName,
        runtimeVariables: trigger.runtimeVariables,
        parsed: parsed
      ))
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: source.id,
        lastWorkflowName: workflowName
      )
    }
    return 1
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

/// Six-field cron expression: second minute hour day-of-month month day-of-week.
/// Supports `*`, `*/n`, single values, ranges `a-b`, stepped ranges `a-b/n`,
/// and comma lists. Day-of-week accepts 0-7 where both 0 and 7 mean Sunday.
struct CronSchedule: Equatable, Sendable {
  static let maximumCatchUpSeconds = 3_600

  var seconds: Set<Int>
  var minutes: Set<Int>
  var hours: Set<Int>
  var daysOfMonth: Set<Int>
  var months: Set<Int>
  var daysOfWeek: Set<Int>
  var dayOfMonthRestricted: Bool
  var dayOfWeekRestricted: Bool

  static func parse(_ expression: String) throws -> CronSchedule {
    let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard fields.count == 6 else {
      throw CronScheduleParseError("cron schedule must have six fields (sec min hour dom month dow): '\(expression)'")
    }
    let daysOfWeekRaw = try parseField(fields[5], name: "day-of-week", minimum: 0, maximum: 7)
    return CronSchedule(
      seconds: try parseField(fields[0], name: "second", minimum: 0, maximum: 59),
      minutes: try parseField(fields[1], name: "minute", minimum: 0, maximum: 59),
      hours: try parseField(fields[2], name: "hour", minimum: 0, maximum: 23),
      daysOfMonth: try parseField(fields[3], name: "day-of-month", minimum: 1, maximum: 31),
      months: try parseField(fields[4], name: "month", minimum: 1, maximum: 12),
      daysOfWeek: Set(daysOfWeekRaw.map { $0 == 7 ? 0 : $0 }),
      dayOfMonthRestricted: fields[3] != "*",
      dayOfWeekRestricted: fields[5] != "*"
    )
  }

  func matches(_ date: Date, calendar: Calendar) -> Bool {
    let components = calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], from: date)
    guard let second = components.second,
          let minute = components.minute,
          let hour = components.hour,
          let day = components.day,
          let month = components.month,
          let weekday = components.weekday else {
      return false
    }
    guard seconds.contains(second), minutes.contains(minute), hours.contains(hour), months.contains(month) else {
      return false
    }
    let cronWeekday = weekday - 1
    let dayOfMonthMatches = daysOfMonth.contains(day)
    let dayOfWeekMatches = daysOfWeek.contains(cronWeekday)
    switch (dayOfMonthRestricted, dayOfWeekRestricted) {
    case (true, true):
      return dayOfMonthMatches || dayOfWeekMatches
    case (true, false):
      return dayOfMonthMatches
    case (false, true):
      return dayOfWeekMatches
    case (false, false):
      return true
    }
  }

  private static func parseField(_ field: String, name: String, minimum: Int, maximum: Int) throws -> Set<Int> {
    var values: Set<Int> = []
    for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
      let stepSplit = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard stepSplit.count <= 2 else {
        throw CronScheduleParseError("cron \(name) field has too many '/' separators: '\(part)'")
      }
      let rangeText = stepSplit[0]
      let step: Int
      if stepSplit.count == 2 {
        guard let parsedStep = Int(stepSplit[1]), parsedStep > 0 else {
          throw CronScheduleParseError("cron \(name) field step must be a positive integer: '\(part)'")
        }
        step = parsedStep
      } else {
        step = 1
      }
      let lower: Int
      let upper: Int
      if rangeText == "*" {
        lower = minimum
        upper = maximum
      } else if rangeText.contains("-") {
        let bounds = rangeText.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low <= high else {
          throw CronScheduleParseError("cron \(name) field range is invalid: '\(part)'")
        }
        lower = low
        upper = high
      } else {
        guard let value = Int(rangeText) else {
          throw CronScheduleParseError("cron \(name) field value is not a number: '\(part)'")
        }
        lower = value
        upper = stepSplit.count == 2 ? maximum : value
      }
      guard lower >= minimum, upper <= maximum else {
        throw CronScheduleParseError("cron \(name) field value out of range \(minimum)-\(maximum): '\(part)'")
      }
      var value = lower
      while value <= upper {
        values.insert(value)
        value += step
      }
    }
    guard !values.isEmpty else {
      throw CronScheduleParseError("cron \(name) field resolved to no values: '\(field)'")
    }
    return values
  }
}

struct CronScheduleParseError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
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
