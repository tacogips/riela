import Foundation

/// Invocation-scoped optimization, never a source of durable truth. Copies of
/// the persistence store share this bounded cache; unrelated stores do not.
/// Execution values share their immutable payload storage with the live runner.
final class RuntimeExecutionReuse: @unchecked Sendable {
  static let shared = RuntimeExecutionReuse()

  struct Entry: Sendable {
    let witness: String
    let executions: [WorkflowStepExecution]
    let rootOutputJSON: String?
    let diagnosticsJSON: String
    let loopEvidenceJSON: String?
    let loopSummaryJSON: String?
    let createdAt: String
    let updatedAt: String
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var order: [String] = []

  func load(_ key: String) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entries[key]
  }

  func remember(
    _ key: String,
    witness: String,
    executions: [WorkflowStepExecution],
    rootOutputJSON: String?,
    diagnosticsJSON: String,
    loopEvidenceJSON: String?,
    loopSummaryJSON: String?,
    createdAt: String,
    updatedAt: String
  ) {
    lock.lock()
    defer { lock.unlock() }
    entries[key] = Entry(
      witness: witness,
      executions: executions,
      rootOutputJSON: rootOutputJSON,
      diagnosticsJSON: diagnosticsJSON,
      loopEvidenceJSON: loopEvidenceJSON,
      loopSummaryJSON: loopSummaryJSON,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > 8 {
      entries.removeValue(forKey: order.removeFirst())
    }
  }
}
