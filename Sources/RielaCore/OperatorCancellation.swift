import Foundation

public final class OperatorCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var storedReason: String?

  public init() {}

  public func request(reason: String, actor: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard storedReason == nil else { return false }
    storedReason = "operator_cancelled by \(actor): \(reason)"
    return true
  }

  public var isRequested: Bool { failureReason != nil }

  public var failureReason: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedReason
  }
}
