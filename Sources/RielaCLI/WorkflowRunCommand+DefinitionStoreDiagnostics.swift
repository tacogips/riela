import RielaCore

extension WorkflowRunCommand {
  func persistDefinitionStoreWarningsAfterTerminalPersistence(warnings: [String], sessionId: String, storeRoot: String) {
    guard !warnings.isEmpty else { return }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot))
    if var snapshot = try? store.load(sessionId: sessionId) {
      for warning in warnings where !snapshot.diagnostics.contains(warning) {
        snapshot.diagnostics.append(warning)
      }
      try? store.save(snapshot)
    }
  }
}
