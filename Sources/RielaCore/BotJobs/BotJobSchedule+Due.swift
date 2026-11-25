import Foundation

public enum BotJobKind: String, Codable, CaseIterable, Sendable {
  case upkeep
  case lookAround = "look-around"
}

public struct BotJobDueInput: Sendable {
  public var schedule: BotJobSchedule
  public var now: Date
  public var calendar: Calendar
  public var paused: Bool
  public var busy: Bool
  public var lastActivityAt: Date?
  public var lastSuccessAt: Date?
  public var ledgerPeriodKeys: Set<String>

  public init(
    schedule: BotJobSchedule, now: Date, calendar: Calendar, paused: Bool, busy: Bool,
    lastActivityAt: Date?, lastSuccessAt: Date?, ledgerPeriodKeys: Set<String>
  ) {
    self.schedule = schedule
    self.now = now
    self.calendar = calendar
    self.paused = paused
    self.busy = busy
    self.lastActivityAt = lastActivityAt
    self.lastSuccessAt = lastSuccessAt
    self.ledgerPeriodKeys = ledgerPeriodKeys
  }
}

public enum BotJobDecision: Equatable, Sendable {
  case notDue(reason: String)
  case skip(periodKey: String, reason: String)
  case run(periodKey: String, skippedPeriodKeys: [String])
}

public enum BotJobDue {
  public static func periodKey(for date: Date, schedule: BotJobSchedule, calendar: Calendar) -> String? {
    switch schedule {
    case .off:
      return nil
    case .nightly:
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
      return String(format: "%04d-%02d-%02d", year, month, day)
    case .weekly:
      let parts = periodCalendar(schedule: schedule, calendar: calendar)
        .dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
      guard let year = parts.yearForWeekOfYear, let week = parts.weekOfYear else { return nil }
      return String(format: "%04d-W%02d", year, week)
    }
  }

  public static func decide(_ input: BotJobDueInput) -> BotJobDecision {
    guard input.schedule != .off else { return .notDue(reason: "off") }
    guard !input.paused else { return .notDue(reason: "paused") }
    guard !input.busy else { return .notDue(reason: "busy") }

    let calendar = periodCalendar(schedule: input.schedule, calendar: input.calendar)
    let unit: Calendar.Component = input.schedule == .weekly ? .weekOfYear : .day
    guard let current = calendar.dateInterval(of: unit, for: input.now),
      let candidate = calendar.dateInterval(of: unit, for: current.start.addingTimeInterval(-1)),
      let key = periodKey(for: candidate.start, schedule: input.schedule, calendar: calendar)
    else { return .notDue(reason: "invalid_period") }

    guard !input.ledgerPeriodKeys.contains(key) else { return .notDue(reason: "done") }
    guard let lastActivity = input.lastActivityAt,
      input.lastSuccessAt.map({ lastActivity > $0 }) ?? true
    else { return .skip(periodKey: key, reason: "no_activity") }

    return .run(
      periodKey: key,
      skippedPeriodKeys: catchUpKeys(before: candidate.start, input: input, calendar: calendar, unit: unit)
    )
  }

  private static func catchUpKeys(
    before candidate: Date, input: BotJobDueInput, calendar: Calendar, unit: Calendar.Component
  ) -> [String] {
    guard let success = input.lastSuccessAt,
      let successPeriod = calendar.dateInterval(of: unit, for: success)
    else { return [] }

    // Compare period boundaries so the successful period is never backfilled.
    var cursor = candidate
    var keys: [String] = []
    while keys.count < 30,
      let period = calendar.dateInterval(of: unit, for: cursor.addingTimeInterval(-1)),
      period.start >= successPeriod.end,
      let key = periodKey(for: period.start, schedule: input.schedule, calendar: calendar) {
      if !input.ledgerPeriodKeys.contains(key) { keys.append(key) }
      cursor = period.start
    }
    return keys.reversed()
  }

  private static func periodCalendar(schedule: BotJobSchedule, calendar: Calendar) -> Calendar {
    guard schedule == .weekly else { return calendar }
    var isoCalendar = Calendar(identifier: .iso8601)
    isoCalendar.timeZone = calendar.timeZone
    return isoCalendar
  }
}
