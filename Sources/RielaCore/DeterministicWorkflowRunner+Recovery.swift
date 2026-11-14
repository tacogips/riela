import Foundation

extension DeterministicWorkflowRunner {
  /// Resolved run/resume/rerun session entry: either the session and lineage
  /// the step loop proceeds with, or a terminal result to return immediately
  /// (resuming an already-terminal session).
  enum SessionEntry {
    case terminal(WorkflowRunResult)
    case proceed(SessionEntryContext)
  }

  struct SessionEntryContext {
    var session: WorkflowSession
    var currentStepId: String?
    var recoveryLineage: LoopRecoveryLineage
    /// Variables the entry mode injects on top of the request (review-finding
    /// replay context on rerun).
    var variableOverrides: JSONObject = [:]
  }

  func resolveSessionEntry(_ request: DeterministicWorkflowRunRequest) async throws -> SessionEntry {
    if let resumeSessionId = request.resumeSessionId {
      return try await resolveResumeEntry(request, resumeSessionId: resumeSessionId)
    }
    if let rerunFromSessionId = request.rerunFromSessionId {
      return try await resolveRerunEntry(request, rerunFromSessionId: rerunFromSessionId)
    }
    let entryStepId = request.workflow.entryStepId
    try await validateCrossWorkflowDispatchTargets(in: request.workflow)
    let session = try await store.createSession(
      WorkflowSessionCreateInput(
        workflowId: request.workflow.workflowId,
        entryStepId: entryStepId,
        effectiveInstance: request.effectiveInstance
      )
    )
    return .proceed(SessionEntryContext(
      session: session,
      currentStepId: entryStepId,
      recoveryLineage: runRecoveryLineage()
    ))
  }

  private func resolveResumeEntry(
    _ request: DeterministicWorkflowRunRequest,
    resumeSessionId: String
  ) async throws -> SessionEntry {
    guard let existing = try await store.loadSession(id: resumeSessionId) else {
      throw DeterministicWorkflowRunnerError.resumeValidation("resume session not found: \(resumeSessionId)")
    }
    guard existing.workflowId == request.workflow.workflowId else {
      throw DeterministicWorkflowRunnerError.resumeValidation("session workflow does not match command workflow")
    }
    let resumeLineage = resumeRecoveryLineage(
      sourceSessionId: resumeSessionId,
      sourceLineage: request.sourceRecoveryLineage
    )
    let canResumeBudgetFailure = existing.status == .failed && existing.failureKind == .maxStepsExceeded
    if existing.status == .completed || (existing.status == .failed && !canResumeBudgetFailure) {
      let terminalResult = WorkflowRunResult(
        workflowId: request.workflow.workflowId,
        session: existing,
        rootOutput: terminalRootOutput(from: existing),
        exitCode: existing.status == .completed ? 0 : 1,
        transitions: 0,
        recovery: resumeLineage
      )
      await emitSessionCompletedEvent(result: terminalResult, handler: request.eventHandler)
      return .terminal(terminalResult)
    }
    try await validateCrossWorkflowDispatchTargets(in: request.workflow)
    let currentStepId = existing.currentStepId ?? existing.entryStepId
    let variableOverrides = try await recoveredLoopGuardPayload(
      sessionId: existing.sessionId,
      stepId: currentStepId
    )
    return .proceed(SessionEntryContext(
      session: existing,
      currentStepId: currentStepId,
      recoveryLineage: resumeLineage,
      variableOverrides: variableOverrides
    ))
  }

  private func resolveRerunEntry(
    _ request: DeterministicWorkflowRunRequest,
    rerunFromSessionId: String
  ) async throws -> SessionEntry {
    guard let sourceSession = try await store.loadSession(id: rerunFromSessionId) else {
      throw DeterministicWorkflowRunnerError.rerunValidation("source session not found: \(rerunFromSessionId)")
    }
    guard sourceSession.workflowId == request.workflow.workflowId else {
      throw DeterministicWorkflowRunnerError.rerunValidation("source session workflow does not match command workflow")
    }
    let entryStepId: String
    do {
      entryStepId = try WorkflowSessionEntryValidation.validateRerunTarget(
        workflow: request.workflow,
        sourceSession: sourceSession,
        rerunStepId: request.rerunFromStepId
      )
    } catch let error as WorkflowSessionEntryValidationError {
      throw DeterministicWorkflowRunnerError.rerunValidation(errorMessage(error))
    }
    try await validateCrossWorkflowDispatchTargets(in: request.workflow)
    let session = try await store.createSession(
      WorkflowSessionCreateInput(
        workflowId: request.workflow.workflowId,
        entryStepId: entryStepId,
        effectiveInstance: request.effectiveInstance
      )
    )
    return .proceed(SessionEntryContext(
      session: session,
      currentStepId: entryStepId,
      recoveryLineage: rerunRecoveryLineage(
        sourceSession: sourceSession,
        sourceStepId: entryStepId,
        childSessionId: session.sessionId,
        sourceLineage: request.sourceRecoveryLineage
      ),
      variableOverrides: WorkflowReviewFindingReplayContext.variables(
        from: sourceSession.reviewFindings,
        targetStepId: entryStepId
      )
    ))
  }

  func runRecoveryLineage() -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .run,
      reason: "initial run",
      inputReusePolicy: "fresh-input",
      attemptNumber: 1
    )
  }

  func resumeRecoveryLineage(
    sourceSessionId: String,
    sourceLineage: LoopRecoveryLineage? = nil
  ) -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .resume,
      sourceSessionId: sourceSessionId,
      parentSessionId: sourceSessionId,
      reason: "resume existing session",
      inputReusePolicy: "existing-session",
      rootSessionId: sourceLineage?.rootSessionId ?? sourceSessionId,
      attemptNumber: sourceLineage?.attemptNumber ?? 1
    )
  }

  func rerunRecoveryLineage(
    sourceSession: WorkflowSession,
    sourceStepId: String,
    childSessionId: String,
    sourceLineage: LoopRecoveryLineage? = nil
  ) -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .rerun,
      sourceSessionId: sourceSession.sessionId,
      sourceStepId: sourceStepId,
      sourceStepExecutionId: sourceSession.executions.last { $0.stepId == sourceStepId }?.executionId,
      parentSessionId: sourceSession.sessionId,
      childSessionIds: [childSessionId],
      reason: "rerun from step \(sourceStepId)",
      inputReusePolicy: "source-session",
      rootSessionId: sourceLineage?.rootSessionId ?? sourceSession.sessionId,
      attemptNumber: (sourceLineage?.attemptNumber ?? 1) + 1
    )
  }

  func terminalRootOutput(from session: WorkflowSession) -> JSONObject? {
    session.executions.last(where: { $0.acceptedOutput?.isRootOutput == true })?.acceptedOutput?.payload
  }
}
