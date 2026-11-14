import Foundation
import RielaCore

final class MutableWorkflowRuntimeClock: WorkflowRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func set(_ date: Date) {
    lock.lock()
    self.date = date
    lock.unlock()
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }
}
