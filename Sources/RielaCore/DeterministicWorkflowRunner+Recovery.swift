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
        effectiveInstance: request.effectiveInstance,
        parentSessionId: request.parentSessionId,
        rootSessionId: request.rootSessionId,
        effectiveStepBudget: request.effectiveStepBudget
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
    let failedExecution = existing.executions.last
    let retryableFailureKind = existing.failureKind == .adapterFailure || existing.failureKind == .policyBlocked
      || existing.failureKind == .nodeTimeout
    let canRetryFailedStep = existing.status == .failed && retryableFailureKind
      && failedExecution?.status == .failed && failedExecution?.stepId == existing.currentStepId
      && failedExecution?.acceptedOutput == nil && failedExecution?.pendingRoutePublication == nil
    if request.retryFailedStep && !canRetryFailedStep {
      throw DeterministicWorkflowRunnerError.resumeValidation(
        "--retry-failed-step requires an adapter-failed, policy-blocked or timed-out current step with no accepted output"
      )
    }
    if existing.status == .completed || (existing.status == .failed && !canResumeBudgetFailure && !request.retryFailedStep) {
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
    let currentStepId = existing.suspend?.stepId ?? existing.currentStepId ?? existing.entryStepId
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
    let importInput: WorkflowHistoryImportInput?
    if request.preserveHistory {
      let history = try await preservedHistory(request, source: sourceSession, target: entryStepId)
      try Self.validateRerunFinalizationEvidence(
        workflow: request.workflow,
        source: sourceSession,
        targetStepId: entryStepId,
        available: history.executions
      )
      importInput = history
    } else {
      importInput = try await plainRerunImport(request, source: sourceSession, target: entryStepId)
    }
    // Lineage is decided here, once: a preserved-history rerun is a child of
    // its source; a plain rerun keeps the caller's lineage whether or not it
    // carries evidence. Recovery lineage records the source either way, and
    // the import never rewrites session lineage for session sources.
    let parentSessionId = request.preserveHistory ? sourceSession.sessionId : request.parentSessionId
    let rootSessionId = request.preserveHistory
      ? (sourceSession.rootSessionId ?? sourceSession.sessionId) : request.rootSessionId
    try await validateCrossWorkflowDispatchTargets(in: request.workflow)
    var session = try await store.createSession(
      WorkflowSessionCreateInput(
        workflowId: request.workflow.workflowId,
        entryStepId: entryStepId,
        effectiveInstance: request.effectiveInstance,
        parentSessionId: parentSessionId,
        rootSessionId: rootSessionId,
        effectiveStepBudget: request.effectiveStepBudget
      )
    )
    if var importInput {
      importInput.sessionId = session.sessionId
      session = try await store.importAcceptedHistory(importInput)
    }
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

  /// Plain-rerun preflight: the carried inbox (D2) plus bound finalization
  /// evidence (D3). Nil when nothing would be imported. A source that is
  /// still `created` or `running` is rejected only when something would be
  /// imported, because the store import needs a settled source; a rerun that
  /// carries nothing (for example of an orphaned `running` session) starts
  /// with fresh input.
  private func plainRerunImport(
    _ request: DeterministicWorkflowRunRequest,
    source: WorkflowSession,
    target: String
  ) async throws -> WorkflowHistoryImportInput? {
    let carried = try await rerunCarriedInbox(source: source, workflow: request.workflow, targetStepId: target)
    let boundEvidence = try Self.rerunFinalizationEvidenceExecutions(
      workflow: request.workflow,
      source: source,
      targetStepId: target,
      available: source.executions
    )
    let executionIds = Set((carried?.executions ?? []).map(\.executionId) + boundEvidence.map(\.executionId))
    let executions = source.executions.filter { executionIds.contains($0.executionId) }
    let messages = carried?.messages ?? []
    guard !executions.isEmpty || !messages.isEmpty else {
      return nil
    }
    guard source.status == .failed || source.status == .suspended || source.status == .completed else {
      throw DeterministicWorkflowRunnerError.rerunValidation(
        "rerun source session must be failed, suspended or completed to carry its accepted evidence " +
          "(source \(source.sessionId) is \(source.status.rawValue)); use session resume \(source.sessionId) " +
          "for a live session, or rerun the entry step for fresh input")
    }
    return WorkflowHistoryImportInput(
      sessionId: "",
      sourceSessionId: source.sessionId,
      executions: executions,
      messages: messages
    )
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
