import Foundation
import RielaCore

func nextBotRoutineTick(_ routine: RoutineRecord, after date: Date) -> Date? {
  guard let cron = try? CronSchedule.parse(routine.schedule) else { return nil }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = routine.timezone.flatMap(TimeZone.init(identifier:)) ?? .gmt
  guard let horizon = calendar.date(byAdding: .year, value: 9, to: date) else { return nil }
  var candidate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970) + 1)
  while candidate <= horizon {
    if cron.matches(candidate, calendar: calendar) { return candidate }
    let components = calendar.dateComponents([.month, .day, .weekday, .hour, .minute, .second], from: candidate)
    guard let month = components.month, let day = components.day, let weekday = components.weekday,
      let hour = components.hour, let minute = components.minute, let second = components.second else { return nil }
    let skip: Calendar.Component
    if !cron.months.contains(month) {
      skip = .month
    } else if !botCronDayMatches(cron, day: day, weekday: weekday - 1) {
      skip = .day
    } else if !cron.hours.contains(hour) {
      skip = .hour
    } else if !cron.minutes.contains(minute) {
      skip = .minute
    } else {
      let next = cron.seconds.filter { $0 > second }.min() ?? 60
      candidate = candidate.addingTimeInterval(Double(next - second))
      continue
    }
    guard let interval = calendar.dateInterval(of: skip, for: candidate), interval.end > candidate else { return nil }
    candidate = interval.end
  }
  return nil
}

private func botCronDayMatches(_ cron: CronSchedule, day: Int, weekday: Int) -> Bool {
  let dayMatches = cron.daysOfMonth.contains(day)
  let weekdayMatches = cron.daysOfWeek.contains(weekday)
  switch (cron.dayOfMonthRestricted, cron.dayOfWeekRestricted) {
  case (true, true): return dayMatches || weekdayMatches
  case (true, false): return dayMatches
  case (false, true): return weekdayMatches
  case (false, false): return true
  }
}
