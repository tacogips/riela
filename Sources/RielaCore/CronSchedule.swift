import Foundation

/// Six-field cron expression: second minute hour day-of-month month day-of-week.
/// Supports `*`, `*/n`, single values, ranges `a-b`, stepped ranges `a-b/n`,
/// and comma lists. Day-of-week accepts 0-7 where both 0 and 7 mean Sunday.
public struct CronSchedule: Equatable, Sendable {
  public static let maximumCatchUpSeconds = 3_600

  public var seconds: Set<Int>
  public var minutes: Set<Int>
  public var hours: Set<Int>
  public var daysOfMonth: Set<Int>
  public var months: Set<Int>
  public var daysOfWeek: Set<Int>
  public var dayOfMonthRestricted: Bool
  public var dayOfWeekRestricted: Bool

  public static func parse(_ expression: String) throws -> CronSchedule {
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

  /// Expands an interval shorthand ("45s", "30m", "2h", or a bare minute count
  /// like "30") into a six-field cron expression. Only intervals that divide
  /// their unit evenly are supported, so ticks land on stable boundaries.
  public static func expression(every shorthand: String) throws -> String {
    let trimmed = shorthand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else {
      throw CronScheduleParseError("every-interval is empty")
    }
    let unit: Character
    let digits: String
    if let last = trimmed.last, "smh".contains(last) {
      unit = last
      digits = String(trimmed.dropLast())
    } else {
      unit = "m"
      digits = trimmed
    }
    guard let value = Int(digits), value > 0 else {
      throw CronScheduleParseError("every-interval must be a positive integer with an optional s/m/h unit: '\(shorthand)'")
    }
    switch unit {
    case "s":
      guard value <= 59, 60 % value == 0 else {
        throw CronScheduleParseError("every-interval seconds must divide 60 evenly: '\(shorthand)'")
      }
      return value == 1 ? "* * * * * *" : "*/\(value) * * * * *"
    case "m":
      guard value <= 59, 60 % value == 0 else {
        throw CronScheduleParseError("every-interval minutes must divide 60 evenly: '\(shorthand)'")
      }
      return value == 1 ? "0 * * * * *" : "0 */\(value) * * * *"
    default:
      guard value <= 23, 24 % value == 0 else {
        throw CronScheduleParseError("every-interval hours must divide 24 evenly: '\(shorthand)'")
      }
      return value == 1 ? "0 0 * * * *" : "0 0 */\(value) * * *"
    }
  }

  public func matches(_ date: Date, calendar: Calendar) -> Bool {
    let components = calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], from: date)
    guard let second = components.second,
          let minute = components.minute,
          let hour = components.hour,
          let day = components.day,
          let month = components.month,
          let weekday = components.weekday else {
      return false
    }
    guard secondMatches(second), minuteMatches(minute), hourMatches(hour), monthMatches(month) else {
      return false
    }
    return dayMatches(day: day, cronWeekday: weekday - 1)
  }

  /// Returns the latest matching whole second strictly before `date`, or nil when none is found
  /// at or after the calendar-relative nine-year search horizon.
  public func previousOccurrence(before date: Date, calendar: Calendar) -> Date? {
    guard let horizon = calendar.date(byAdding: .year, value: -9, to: date) else {
      return nil
    }
    var candidate = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970) - 1)

    while candidate >= horizon {
      let components = calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], from: candidate)
      guard let second = components.second,
            let minute = components.minute,
            let hour = components.hour,
            let day = components.day,
            let month = components.month,
            let weekday = components.weekday else {
        return nil
      }

      if !monthMatches(month) {
        guard let start = calendar.dateInterval(of: .month, for: candidate)?.start else {
          return nil
        }
        candidate = start.addingTimeInterval(-1)
      } else if !dayMatches(day: day, cronWeekday: weekday - 1) {
        guard let start = calendar.dateInterval(of: .day, for: candidate)?.start else {
          return nil
        }
        candidate = start.addingTimeInterval(-1)
      } else if !hourMatches(hour) {
        guard let start = calendar.dateInterval(of: .hour, for: candidate)?.start else {
          return nil
        }
        candidate = start.addingTimeInterval(-1)
      } else if !minuteMatches(minute) {
        guard let start = calendar.dateInterval(of: .minute, for: candidate)?.start else {
          return nil
        }
        candidate = start.addingTimeInterval(-1)
      } else if !secondMatches(second) {
        candidate = candidate.addingTimeInterval(-1)
      } else {
        return candidate
      }
    }
    return nil
  }

  private func secondMatches(_ value: Int) -> Bool {
    seconds.contains(value)
  }

  private func minuteMatches(_ value: Int) -> Bool {
    minutes.contains(value)
  }

  private func hourMatches(_ value: Int) -> Bool {
    hours.contains(value)
  }

  private func monthMatches(_ value: Int) -> Bool {
    months.contains(value)
  }

  private func dayMatches(day: Int, cronWeekday: Int) -> Bool {
    let dayOfMonthMatches = daysOfMonth.contains(day)
    let dayOfWeekMatches = daysOfWeek.contains(cronWeekday)
    return switch (dayOfMonthRestricted, dayOfWeekRestricted) {
    case (true, true):
      dayOfMonthMatches || dayOfWeekMatches
    case (true, false):
      dayOfMonthMatches
    case (false, true):
      dayOfWeekMatches
    case (false, false):
      true
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

public struct CronScheduleParseError: Error, CustomStringConvertible, Sendable {
  public var description: String

  public init(_ description: String) {
    self.description = description
  }
}
