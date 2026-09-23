import RielaAdapters
import RielaCore

func makeSessionNodeAdapter(
  mockScenarioPath: String?,
  workingDirectory: String,
  codexSupervisorModeEnabled: Bool = false
) throws -> any NodeAdapter {
  try makeScenarioBackedNodeAdapter(
    scenarioPath: mockScenarioPath,
    workingDirectory: workingDirectory,
    codexSupervisorModeEnabled: codexSupervisorModeEnabled
  )
}

func loadExistingWorkflowMessages(
  sessionId: String,
  persistenceStore: SQLiteWorkflowRuntimePersistenceStore
) throws -> [WorkflowMessageRecord] {
  do {
    return try persistenceStore.load(sessionId: sessionId).workflowMessages
  } catch WorkflowRuntimePersistenceStoreError.notFound(_) {
    return []
  }
}
