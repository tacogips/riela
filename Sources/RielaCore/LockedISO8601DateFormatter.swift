import Foundation

final class LockedISO8601DateFormatter: @unchecked Sendable {
  private let formatter: ISO8601DateFormatter
  private let fallbackFormatter: ISO8601DateFormatter?
  private let lock = NSLock()

  init(
    formatOptions: ISO8601DateFormatter.Options = [.withInternetDateTime, .withFractionalSeconds],
    fallbackFormatOptions: ISO8601DateFormatter.Options? = nil
  ) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = formatOptions
    self.formatter = formatter
    if let fallbackFormatOptions {
      let fallbackFormatter = ISO8601DateFormatter()
      fallbackFormatter.formatOptions = fallbackFormatOptions
      self.fallbackFormatter = fallbackFormatter
    } else {
      self.fallbackFormatter = nil
    }
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer {
      lock.unlock()
    }
    return formatter.string(from: date)
  }

  func date(from text: String) -> Date? {
    lock.lock()
    defer {
      lock.unlock()
    }
    return formatter.date(from: text) ?? fallbackFormatter?.date(from: text)
  }
}
