import Foundation

extension DeterministicWorkflowRunner {
  func isWorkflowRunCancellation(_ error: Error) -> Bool {
    error is CancellationError
  }

  func finalizeInterruptedSessionFailed(
    sessionId: String,
    request: DeterministicWorkflowRunRequest,
    error: Error,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?,
    effectiveStepBudget: Int?
  ) async {
    guard let failedSession = try? await store.markSessionFailed(
      WorkflowSessionFailureInput(
        sessionId: sessionId,
        reason: workflowRunFailureReason(error),
        failureKind: workflowRunFailureKind(error),
        stepBudgetDiagnostic: stepBudgetDiagnostic,
        effectiveStepBudget: effectiveStepBudget
      )
    ) else {
      return
    }

    let result = WorkflowRunResult(
      workflowId: request.workflow.workflowId,
      session: failedSession,
      rootOutput: terminalRootOutput(from: failedSession),
      exitCode: 1,
      transitions: 0
    )
    await emitSessionCompletedEvent(result: result, handler: request.eventHandler)
  }

  func workflowRunFailureKind(_ error: Error) -> WorkflowSessionFailureKind {
    if isWorkflowRunCancellation(error) {
      return .cancelled
    }
    if case DeterministicWorkflowRunnerError.maxStepsExceeded = error {
      return .maxStepsExceeded
    }
    if case DeterministicWorkflowRunnerError.loopBudgetExceeded = error {
      return .budgetExceeded
    }
    if error is DeterministicWorkflowRunner.LoopConvergenceError {
      return .loopNotConverging
    }
    if let adapterError = error as? AdapterExecutionError {
      switch adapterError.code {
      case .policyBlocked:
        return .policyBlocked
      case .timeout:
        return .nodeTimeout
      case .providerError, .invalidInput, .invalidOutput:
        return .adapterFailure
      }
    }
    return .internalFailure
  }

  func workflowRunFailureReason(_ error: Error) -> String {
    if isWorkflowRunCancellation(error) {
      return "workflow run cancelled"
    }
    if let adapterError = error as? AdapterExecutionError {
      return "\(adapterError.code.rawValue): \(adapterError.message)"
    }
    if let convergenceError = error as? DeterministicWorkflowRunner.LoopConvergenceError {
      return convergenceError.description
    }
    if case let DeterministicWorkflowRunnerError.loopBudgetExceeded(diagnostic) = error {
      return diagnostic
    }
    return String(describing: error)
  }

  func stepBudgetDiagnostic(
    session: WorkflowSession,
    stepBudget: Int,
    executionCount: Int,
    maxLoopIterations: Int,
    budgetSource: WorkflowStepBudgetSource,
    executionCounts: [String: Int],
    unscheduledStepId: String?
  ) -> WorkflowStepBudgetDiagnostic {
    let dominantCycle = dominantCycleStepIds(
      executedStepIds: session.executions.map(\.stepId),
      unscheduledStepId: unscheduledStepId
    )
    let cycleLength = max(1, dominantCycle?.stepIds.count ?? executionCounts.count)
    let suggestedMaxSteps = max(stepBudget + cycleLength, executionCount + cycleLength)
    let perStepRevisitCap = maxLoopIterations + 1
    let projectedCounts = projectedExecutionCounts(
      executionCounts,
      unscheduledStepId: unscheduledStepId
    )
    let capExceededStepIds = projectedCounts
      .filter { $0.value > perStepRevisitCap }
      .map(\.key)
      .sorted()
    return WorkflowStepBudgetDiagnostic(
      stepBudget: stepBudget,
      executionCount: executionCount,
      maxLoopIterations: maxLoopIterations,
      budgetSource: budgetSource,
      perStepExecutionCounts: executionCounts,
      dominantCycleStepIds: dominantCycle?.stepIds,
      dominantCycleRepeatCount: dominantCycle?.repeatCount,
      perStepRevisitCap: perStepRevisitCap,
      projectedCapExceededStepIds: capExceededStepIds,
      openReviewFindingCount: session.reviewFindings.count,
      unscheduledStepId: unscheduledStepId,
      suggestedMaxSteps: suggestedMaxSteps,
      suggestedRemediation: "session resume \(session.sessionId) --max-steps \(suggestedMaxSteps)"
    )
  }

  private func projectedExecutionCounts(
    _ executionCounts: [String: Int],
    unscheduledStepId: String?
  ) -> [String: Int] {
    guard let unscheduledStepId else {
      return executionCounts
    }
    var projectedCounts = executionCounts
    projectedCounts[unscheduledStepId, default: 0] += 1
    return projectedCounts
  }

  private func dominantCycleStepIds(
    executedStepIds: [String],
    unscheduledStepId: String?
  ) -> WorkflowDominantCycle? {
    var sequence = executedStepIds
    if let unscheduledStepId {
      sequence.append(unscheduledStepId)
    }
    guard sequence.count >= 2 else {
      return nil
    }

    var best: WorkflowDominantCycle?
    for startIndex in sequence.indices {
      let remainingCount = sequence.count - startIndex
      guard remainingCount >= 2 else {
        continue
      }
      for cycleLength in 1...(remainingCount / 2) {
        let candidate = Array(sequence[startIndex..<(startIndex + cycleLength)])
        var repeatCount = 1
        while repeats(
          candidate,
          in: sequence,
          startIndex: startIndex,
          cycleLength: cycleLength,
          repeatCount: repeatCount + 1
        ) {
          repeatCount += 1
        }
        guard repeatCount >= 2 else {
          continue
        }
        let coverage = cycleLength * repeatCount
        if shouldPreferDominantCycle(
          coverage: coverage,
          cycleLength: cycleLength,
          currentBest: best
        ) {
          best = WorkflowDominantCycle(stepIds: candidate, repeatCount: repeatCount, coverage: coverage)
        }
      }
    }
    return best
  }

  private func shouldPreferDominantCycle(
    coverage: Int,
    cycleLength: Int,
    currentBest: WorkflowDominantCycle?
  ) -> Bool {
    guard let currentBest else {
      return true
    }
    return coverage > currentBest.coverage || (coverage == currentBest.coverage && cycleLength < currentBest.stepIds.count)
  }

  private func repeats(
    _ candidate: [String],
    in sequence: [String],
    startIndex: Int,
    cycleLength: Int,
    repeatCount: Int
  ) -> Bool {
    let candidateStart = startIndex + ((repeatCount - 1) * cycleLength)
    let candidateEnd = candidateStart + cycleLength
    guard candidateEnd <= sequence.count else {
      return false
    }
    return Array(sequence[candidateStart..<candidateEnd]) == candidate
  }
}

private struct WorkflowDominantCycle {
  var stepIds: [String]
  var repeatCount: Int
  var coverage: Int
}
