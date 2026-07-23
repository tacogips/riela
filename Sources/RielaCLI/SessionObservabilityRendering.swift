import Foundation
import RielaCore

extension SessionInspectionCommand {
  func render(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    command: String,
    output: WorkflowOutputFormat,
    observabilityView: SessionObservabilityView? = nil
  ) throws -> CLICommandResult {
    let health = command == "health" ? (snapshot.session.status == .failed ? "failed" : "ok") : nil
    let loopEvidence = snapshot.loopEvidence.map(LoopEvidenceSummary.init)
    let runningExecutions = snapshot.session.executions.filter { $0.status == .running }
    let activeExecution = runningExecutions.last
    let lastCompletedStepId = snapshot.session.executions.last { $0.status == .completed || $0.status == .skipped }?.stepId
    let result = SessionInspectionCommandResult(
      sessionId: snapshot.session.sessionId,
      parentSessionId: snapshot.session.parentSessionId,
      rootSessionId: snapshot.session.rootSessionId,
      workflowName: snapshot.session.workflowId,
      status: snapshot.session.status,
      currentStepId: snapshot.session.currentStepId,
      currentStage: Self.stageDescription(for: snapshot.session.currentStepId),
      lastCompletedStepId: lastCompletedStepId,
      failureReason: snapshot.session.failureReason,
      failureKind: snapshot.session.failureKind,
      stepBudgetDiagnostic: snapshot.session.stepBudgetDiagnostic,
      instanceIdentity: snapshot.session.instanceIdentity,
      instanceKind: snapshot.session.instanceKind,
      instanceBaseIdentity: snapshot.session.instanceBaseIdentity,
      instanceConfiguration: snapshot.session.instanceConfiguration,
      activeStepId: activeExecution?.stepId,
      activeStage: Self.stageDescription(for: activeExecution?.stepId),
      activeExecutionId: activeExecution?.executionId,
      activeBackend: activeExecution?.backend,
      activeExecutionUpdatedAt: activeExecution?.updatedAt,
      activeBackendEventAt: activeExecution?.lastBackendEventAt,
      activeBackendEventType: activeExecution?.lastBackendEventType,
      backendSilentForMs: activeExecution.flatMap(backendSilentForMs),
      activeSilentForMs: activeExecution.flatMap(activeSilentForMs),
      executionCount: snapshot.session.executions.count,
      executions: executionRows(for: command, allExecutions: snapshot.session.executions, runningExecutions: runningExecutions),
      reviewFindingCount: snapshot.session.reviewFindings.count,
      reviewFindings: snapshot.session.reviewFindings,
      health: health,
      loopEvidenceRecorded: snapshot.loopEvidence != nil,
      loopEvidence: loopEvidence,
      progress: observabilityView?.root.digest,
      rollup: command == "progress" ? observabilityView?.root : nil,
      backendActivity: observabilityView?.backendActivity
    )
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = [
        "sessionId: \(result.sessionId)",
        "parentSessionId: \(result.parentSessionId ?? "-")",
        "rootSessionId: \(result.rootSessionId)",
        "workflow: \(result.workflowName)",
        "status: \(result.status.rawValue)",
        "currentStepId: \(result.currentStepId ?? "-")",
        "currentStage: \(result.currentStage ?? "-")",
        "lastCompletedStepId: \(result.lastCompletedStepId ?? "-")",
        "failureKind: \(result.failureKind?.rawValue ?? "-")",
        "failureReason: \(result.failureReason ?? "-")",
        "instanceIdentity: \(result.instanceIdentity ?? "-")",
        "instanceKind: \(result.instanceKind ?? "-")",
        "instanceBaseIdentity: \(result.instanceBaseIdentity ?? "-")",
        "activeStepId: \(result.activeStepId ?? "-")",
        "activeStage: \(result.activeStage ?? "-")",
        "activeExecutionId: \(result.activeExecutionId ?? "-")",
        "activeBackend: \(result.activeBackend?.rawValue ?? "-")",
        "activeExecutionUpdatedAt: \(result.activeExecutionUpdatedAt.map(renderISO8601) ?? "-")",
        "activeBackendEventAt: \(result.activeBackendEventAt.map(renderISO8601) ?? "-")",
        "activeBackendEventType: \(result.activeBackendEventType ?? "-")",
        "backendSilentForMs: \(result.backendSilentForMs.map(String.init) ?? "-")",
        "activeSilentForMs: \(result.activeSilentForMs.map(String.init) ?? "-")",
        "executionCount: \(result.executionCount)",
        "reviewFindingCount: \(result.reviewFindingCount)",
        "loopEvidenceRecorded: \(result.loopEvidenceRecorded ? "true" : "false")"
      ]
      if let health {
        lines.append("health: \(health)")
      }
      if let activity = result.backendActivity {
        lines.append("backendActivity: \(activity.verdict.rawValue)")
        lines.append("backendActivityAgeMs: \(activity.ageMs.map(String.init) ?? "-")")
        lines.append("backendActivityThresholdsMs: active=\(activity.activeThresholdMs) stalled=\(activity.stalledThresholdMs)")
        lines.append(contentsOf: activity.evidence.map { evidence in
          let path = evidence.path.map(homeAbbreviatedPath) ?? "-"
          return "backendActivityEvidence: \(evidence.kind.rawValue) ageMs=\(evidence.ageMs.map(String.init) ?? "-") path=\(path) detail=\(evidence.detail)"
        })
      }
      if command == "progress", let rollup = result.rollup {
        if let truncated = observabilityView?.rollupTruncated {
          lines.append("rollupTruncated: \(truncated ? "true" : "false")")
        }
        if let limit = observabilityView?.rollupSnapshotLimit {
          lines.append("rollupSnapshotLimit: \(limit)")
        }
        lines.append(contentsOf: progressTreeLines(rollup))
      }
      if let loopEvidence {
        lines.append(
          "loopEvidence: gates=\(loopEvidence.gateCount) accepted=\(loopEvidence.acceptedGateCount) rejected=\(loopEvidence.rejectedGateCount) blockingFindings=\(loopEvidence.blockingFindingCount)"
        )
      }
      if let diagnostic = result.stepBudgetDiagnostic {
        lines.append("stepBudget: \(diagnostic.stepBudget)")
        if let cycleStepIds = diagnostic.dominantCycleStepIds, let repeatCount = diagnostic.dominantCycleRepeatCount {
          lines.append("dominantCycle: \(cycleStepIds.joined(separator: " -> ")) (x\(repeatCount))")
        }
        if let perStepRevisitCap = diagnostic.perStepRevisitCap {
          lines.append("perStepRevisitCap: \(perStepRevisitCap)")
        }
        if let exceededStepIds = diagnostic.projectedCapExceededStepIds, !exceededStepIds.isEmpty {
          lines.append("projectedCapExceededStepIds: \(exceededStepIds.joined(separator: ","))")
        }
        lines.append("unscheduledStepId: \(diagnostic.unscheduledStepId ?? "-")")
        lines.append("suggestedRemediation: \(diagnostic.suggestedRemediation ?? "-")")
      }
      if command == "logs" {
        lines.append(contentsOf: snapshot.session.executions.compactMap { execution in
          execution.failureReason.map { "\(execution.executionId)\t\(execution.stepId)\t\($0)" }
        })
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }

  static func stageDescription(for stepId: String?) -> String? {
    guard let stepId else {
      return nil
    }
    let normalized = stepId.lowercased()
    if normalized.contains("ocr") {
      return "OCR in progress"
    }
    if normalized.contains("translate") || normalized.contains("translation") {
      return "Translation in progress"
    }
    if normalized.contains("ingest") || normalized.contains("note-create") || normalized.contains("create-note") {
      return "Note creation in progress"
    }
    return nil
  }

  func executionRows(
    for command: String,
    allExecutions: [WorkflowStepExecution],
    runningExecutions: [WorkflowStepExecution]
  ) -> [WorkflowStepExecution] {
    switch command {
    case "status", "export", "step-runs":
      return allExecutions
    case "progress":
      return runningExecutions
    default:
      return []
    }
  }

  func activeSilentForMs(_ execution: WorkflowStepExecution) -> Int? {
    guard execution.status == .running else {
      return nil
    }
    let lastSignalAt = execution.lastBackendEventAt ?? execution.updatedAt
    return max(0, Int(Date().timeIntervalSince(lastSignalAt) * 1_000))
  }

  func backendSilentForMs(_ execution: WorkflowStepExecution) -> Int? {
    guard execution.status == .running, let lastSignalAt = execution.lastBackendEventAt else {
      return nil
    }
    return max(0, Int(Date().timeIntervalSince(lastSignalAt) * 1_000))
  }
}

private func renderISO8601(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
