import Foundation

extension SQLiteWorkflowRuntimePersistenceStore {
  func traceSnapshotAssembly(_ phase: String, count: Int, changed: Int = 0) {
    guard ProcessInfo.processInfo.environment["RIELA_BULK_RESOURCE_DIAGNOSTICS"] == "1" else { return }
    // Numeric test diagnostics only; never emit inputs, outputs, IDs or env.
    FileHandle.standardError.write(Data("canonical-resource phase=\(phase) executions=\(count) changed=\(changed)\n".utf8))
  }
}
