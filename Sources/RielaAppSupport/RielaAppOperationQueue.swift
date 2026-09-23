import Foundation

/// Serializes whole asynchronous transitions, including their suspension points.
@MainActor
public final class RielaAppOperationQueue {
  private var tail: Task<Void, Never>?

  public init() {}

  public func run<Result: Sendable>(_ operation: @escaping @MainActor () async -> Result) async -> Result {
    let previous = tail
    let task = Task { @MainActor in
      await previous?.value
      return await operation()
    }
    tail = Task { @MainActor in _ = await task.value }
    return await task.value
  }
}
