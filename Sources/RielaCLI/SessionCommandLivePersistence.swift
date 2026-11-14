import RielaCore

struct SessionLivePersistenceConfig: Sendable {
  var workflowName: String
  var requestedScope: WorkflowScope
  var resolution: WorkflowResolutionOptions
  var storeRoot: String
  var bundle: ResolvedWorkflowBundle
  var variables: JSONObject
  var runtimeStore: InMemoryWorkflowRuntimeStore
  var mockScenarioPath: String?
  var workingDirectory: String
}

func makeSessionCommandLivePersistenceHandler(
  configuration: SessionLivePersistenceConfig,
  recorder: WorkflowRunJSONLRecorder? = nil
) async -> WorkflowRunEventHandler {
  let state = WorkflowRunLivePersistenceState()
  await state.configure(storeRoot: configuration.storeRoot)
  return { event in
    if await state.shouldPersist(event: event) {
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
          recorder: recorder
        ),
        state: state
      )
    }
    guard let recorder else {
      return
    }
    await recorder.append(event)
    if event.type == .sessionStarted, event.workflowId == configuration.bundle.workflow.workflowId {
      let context = WorkflowRunContextRecord(
        sessionId: event.sessionId,
        workflowName: configuration.workflowName,
        sessionStore: configuration.storeRoot,
        scope: configuration.requestedScope
      )
      await recorder.append((try? jsonString(context)) ?? #"{"type":"run_context_encode_failed"}"# + "\n")
    }
  }
}
