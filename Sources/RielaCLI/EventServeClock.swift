import Foundation

protocol EventServeClock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

struct SystemEventServeClock: EventServeClock {
  func now() -> Date {
    Date()
  }

  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
