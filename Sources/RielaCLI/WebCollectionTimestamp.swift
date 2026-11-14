import Foundation

/// Feed dates must carry a timezone. The normalized wire value keeps the
/// original offset and Python-compatible microseconds for legacy fingerprints.
struct WebCollectionTimestamp: Sendable {
  let date: Date
  let wire: String

  init?(_ source: String) {
    let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard source.utf8.count <= 200 else { return nil }
    let iso = #"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}(?::\d{2})?)(?:[.,](\d{1,9}))?(Z|[+-]\d{2}:?\d{2})$"#
    if let fields = Self.capture(source, iso) {
      let rawOffset = fields[4]
      let offset = rawOffset == "Z" ? "+00:00" : rawOffset.count == 5 ?
        String(rawOffset.prefix(3)) + ":" + String(rawOffset.suffix(2)) : rawOffset
      let fraction = String((fields[3] + "000000").prefix(6))
      let suffix = fraction == "000000" ? "" : "." + fraction
      let time = fields[2].count == 5 ? fields[2] + ":00" : fields[2]
      let normalized = fields[1] + "T" + time + suffix + (offset == "-00:00" ? "+00:00" : offset)
      let formatter = ISO8601DateFormatter()
      if !suffix.isEmpty { formatter.formatOptions.insert(.withFractionalSeconds) }
      guard let date = formatter.date(from: normalized) else { return nil }
      let numericOffset = offset.replacingOccurrences(of: ":", with: "")
      guard let hours = Int(numericOffset.dropFirst().prefix(2)), let minutes = Int(numericOffset.suffix(2)),
        hours <= 23, minutes < 60,
        let zone = TimeZone(secondsFromGMT: (offset.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)) else { return nil }
      let expected = fields[1] + "T" + time
      let wholeSecond = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
      guard String(Self.wire(wholeSecond, timezone: zone).prefix(19)) == expected else { return nil }
      self.date = date; self.wire = normalized; return
    }
    let rfc = #"^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|[A-Za-z]{1,5})(?:\s+\([^)]*\))?$"#
    guard let fields = Self.capture(source, rfc), let day = Int(fields[1]), let year = Int(fields[3]),
      let hour = Int(fields[4]), let minute = Int(fields[5]), let second = Int(fields[6].isEmpty ? "0" : fields[6]),
      let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: fields[2].lowercased()) else { return nil }
    let zones = ["UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5,
      "MST": -7, "MDT": -6, "PST": -8, "PDT": -7]
    let rawZone = fields[7].uppercased()
    guard rawZone != "-0000" else { return nil }
    let offset: Int
    if let hours = zones[rawZone] { offset = hours * 3600 } else {
      guard rawZone.count == 5, let hours = Int(rawZone.dropFirst().prefix(2)),
        let minutes = Int(rawZone.suffix(2)), hours <= 23, minutes < 60 else { return nil }
      offset = (rawZone.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
    guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let resolvedYear = year < 69 ? 2000 + year : year < 100 ? 1900 + year : year
    let components = DateComponents(year: resolvedYear, month: month + 1, day: day, hour: hour, minute: minute, second: second)
    guard let date = calendar.date(from: components),
      calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else { return nil }
    self.date = date; self.wire = Self.wire(date, timezone: zone)
  }

  static func wire(_ date: Date, timezone: TimeZone = .gmt) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timezone
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    let offset = timezone.secondsFromGMT(for: date)
    return formatter.string(from: date) + String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
  }

  private static func capture(_ text: String, _ pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    let source = text as NSString
    return (0..<match.numberOfRanges).map { index in
      match.range(at: index).location == NSNotFound ? "" : source.substring(with: match.range(at: index))
    }
  }
}
