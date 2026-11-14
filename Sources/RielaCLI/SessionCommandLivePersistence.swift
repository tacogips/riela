import RielaCore

struct SessionLivePersistenceConfig: Sendable {
  var workflowName: String
  var resolution: WorkflowResolutionOptions
  var storeRoot: String
  var bundle: ResolvedWorkflowBundle
  var variables: JSONObject
  var runtimeStore: InMemoryWorkflowRuntimeStore
  var mockScenarioPath: String?
  var workingDirectory: String
}

func makeSessionCommandLivePersistenceHandler(
  configuration: SessionLivePersistenceConfig
) async -> WorkflowRunEventHandler {
  let state = WorkflowRunLivePersistenceState()
  await state.configure(storeRoot: configuration.storeRoot)
  return { event in
    guard await state.shouldPersist(event: event) else {
      return
    }
    let isCalleeSession = event.workflowId != configuration.bundle.workflow.workflowId
    await persistWorkflowRunLiveSessionRecord(
      sessionId: event.sessionId,
      context: WorkflowRunLivePersistenceContext(
        workflowName: isCalleeSession ? event.workflowId : configuration.workflowName,
        resolution: isCalleeSession
          ? WorkflowResolutionOptions(
            workflowName: event.workflowId,
            scope: configuration.resolution.scope,
            workflowDefinitionDir: configuration.resolution.workflowDefinitionDir,
            workingDirectory: configuration.resolution.workingDirectory
          )
          : configuration.resolution,
        bundle: configuration.bundle,
        variables: configuration.variables,
        runtimeStore: configuration.runtimeStore,
        mockScenarioPath: configuration.mockScenarioPath,
        artifactRoot: nil,
        workingDirectory: configuration.workingDirectory,
        recorder: nil
      ),
      state: state
    )
  }
}
