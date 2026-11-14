import Foundation

/// Invocation-scoped optimization, never a source of durable truth. Copies of
/// the persistence store share this bounded cache; unrelated stores do not.
/// Execution values share their immutable payload storage with the live runner.
final class RuntimeExecutionReuse: @unchecked Sendable {
  struct Entry: Sendable {
    let witness: String
    let executions: [WorkflowStepExecution]
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var order: [String] = []

  func load(_ key: String) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entries[key]
  }

  func remember(_ key: String, witness: String, executions: [WorkflowStepExecution]) {
    lock.lock()
    defer { lock.unlock() }
    entries[key] = Entry(witness: witness, executions: executions)
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > 8 {
      entries.removeValue(forKey: order.removeFirst())
    }
  }
}
