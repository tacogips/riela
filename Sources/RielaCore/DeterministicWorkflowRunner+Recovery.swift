import Foundation

extension DeterministicWorkflowRunner {
  func runRecoveryLineage() -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .run,
      reason: "initial run",
      inputReusePolicy: "fresh-input"
    )
  }

  func resumeRecoveryLineage(sourceSessionId: String) -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .resume,
      sourceSessionId: sourceSessionId,
      parentSessionId: sourceSessionId,
      reason: "resume existing session",
      inputReusePolicy: "existing-session"
    )
  }

  func rerunRecoveryLineage(
    sourceSession: WorkflowSession,
    sourceStepId: String,
    childSessionId: String
  ) -> LoopRecoveryLineage {
    LoopRecoveryLineage(
      entryMode: .rerun,
      sourceSessionId: sourceSession.sessionId,
      sourceStepId: sourceStepId,
      sourceStepExecutionId: sourceSession.executions.last { $0.stepId == sourceStepId }?.executionId,
      parentSessionId: sourceSession.sessionId,
      childSessionIds: [childSessionId],
      reason: "rerun from step \(sourceStepId)",
      inputReusePolicy: "source-session"
    )
  }

  func terminalRootOutput(from session: WorkflowSession) -> JSONObject? {
    session.executions.last(where: { $0.acceptedOutput?.isRootOutput == true })?.acceptedOutput?.payload
  }
}
