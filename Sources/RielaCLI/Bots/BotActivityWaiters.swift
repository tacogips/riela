import Foundation

final class BotActivityWaiters: @unchecked Sendable {
  static let shared = BotActivityWaiters()

  private let lock = NSLock()
  private var waiting = 0

  func acquire() -> Bool {
    lock.withLock {
      guard waiting < 32 else { return false }
      waiting += 1
      return true
    }
  }

  func release() {
    lock.withLock { waiting -= 1 }
  }
}
