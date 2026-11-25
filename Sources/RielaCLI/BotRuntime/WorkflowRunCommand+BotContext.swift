import RielaCore
import RielaObservability

extension WorkflowRunCommand {
  func prepareBotContext(_ botId: String?, linker: BotRunLinker) throws -> BotRunContext? {
    guard let botId else { return nil }
    do {
      return try linker.prepare(botId: botId)
    } catch BotRunLinkError.notFound where botLinkSource.source == "routine" {
      RielaStandardStreams.writeError("riela bot link: bot_not_found: \(botId); starting routine without a bot\n")
      return nil
    } catch let error as BotRunLinkError {
      throw CLIUsageError(error.message)
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
