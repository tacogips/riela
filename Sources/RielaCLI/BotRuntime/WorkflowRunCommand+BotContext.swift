import RielaCore
import RielaObservability

extension WorkflowRunCommand {
  func prepareBotContext(
    _ options: WorkflowRunOptions, linker: BotRunLinker, workingDirectory: String, environment: [String: String]
  ) throws -> BotRunContext? {
    if let botId = options.botId {
      do {
        return try linker.prepare(botId: botId, workingDirectory: workingDirectory, environment: environment)
      } catch BotRunLinkError.notFound where botLinkSource.source == "routine" {
        RielaStandardStreams.writeError("riela bot link: bot_not_found: \(botId); starting routine without a bot\n")
      } catch let error as BotRunLinkError {
        throw CLIUsageError(error.message)
      }
    }
    return options.resumeSessionId.flatMap {
      BotActivityRuntime.botContext(
        forExistingSession: $0, sessionStoreRoot: linker.sessionStoreRoot, workingDirectory: workingDirectory, environment: environment
      )
    }
  }

  func makeRunRequest(
    options: WorkflowRunOptions,
    preparedRun: PreparedResolvedWorkflowRun,
    taskContext: TaskPlacementExecutionContext?,
    eventHandler: @escaping WorkflowRunEventHandler,
    sessionAdmission: @escaping @Sendable (String) throws -> Void,
    botContext: BotRunContext?
  ) -> DeterministicWorkflowRunRequest {
    let effectiveInstance = preparedRun.execution.instance
    var request = DeterministicWorkflowRunRequest(
      workflow: preparedRun.bundle.workflow,
      nodePayloads: preparedRun.bundle.nodePayloads,
      variables: effectiveInstance.configuration.defaultVariables,
      maxSteps: options.maxSteps,
      maxConcurrency: options.maxConcurrency,
      maxLoopIterations: options.maxLoopIterations,
      disableDefaultLoopGuard: options.disableDefaultLoopGuard,
      defaultTimeoutMs: options.defaultTimeoutMs,
      timeoutMs: options.timeoutMs,
      resumeSessionId: options.resumeSessionId,
      agentSilenceWarningMs: options.agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: options.agentSilenceMonitorIntervalMs,
      effectiveInstance: effectiveInstance,
      eventHandler: eventHandler,
      sessionExecutionAdmission: sessionAdmission,
      boundaryHandover: taskContext?.boundaryHandover, cancellationCause: taskContext?.cancellationCause,
      cancellationReason: operatorCancellationReason,
      definitionSource: preparedRun.definitionSource
    )
    request.botContext = botContext
    return request
  }
}
