import Foundation

func rielaNoteRelativeTimestampText(_ timestamp: String, now: Date = Date()) -> String {
  guard let date = rielaNoteDate(from: timestamp) else {
    return timestamp
  }
  let seconds = Int(now.timeIntervalSince(date).rounded())
  let isFuture = seconds < 0
  let absoluteSeconds = abs(seconds)
  guard absoluteSeconds >= 60 else {
    return "just now"
  }
  let units: [RielaNoteRelativeTimeUnit] = [
    RielaNoteRelativeTimeUnit(seconds: 31_536_000, singular: "year", plural: "years"),
    RielaNoteRelativeTimeUnit(seconds: 2_592_000, singular: "month", plural: "months"),
    RielaNoteRelativeTimeUnit(seconds: 604_800, singular: "week", plural: "weeks"),
    RielaNoteRelativeTimeUnit(seconds: 86_400, singular: "day", plural: "days"),
    RielaNoteRelativeTimeUnit(seconds: 3_600, singular: "hour", plural: "hours"),
    RielaNoteRelativeTimeUnit(seconds: 60, singular: "minute", plural: "minutes")
  ]
  let unit = units.first { absoluteSeconds >= $0.seconds } ?? units[units.count - 1]
  let value = max(1, absoluteSeconds / unit.seconds)
  let label = value == 1 ? unit.singular : unit.plural
  if isFuture {
    return "in \(value) \(label)"
  }
  return "\(value) \(label) ago"
}

private struct RielaNoteRelativeTimeUnit {
  var seconds: Int
  var singular: String
  var plural: String
}

private func rielaNoteDate(from timestamp: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: timestamp) {
    return date
  }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: timestamp)
}
