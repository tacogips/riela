import Foundation
import RielaCore

extension WorkflowRunCommand {
  func runWithAutoImprove(
    initialRequest: DeterministicWorkflowRunRequest,
    runner: DeterministicWorkflowRunner,
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    variables: JSONObject,
    options: WorkflowRunOptions,
    runtimeStore: InMemoryWorkflowRuntimeStore
  ) async throws -> WorkflowRunResult {
    var currentRequest = initialRequest
    var current: WorkflowRunResult?
    var incidents: [JSONValue] = []
    var remediations: [JSONValue] = []
    var supervisedAttempts = 0
    var pendingRemediationIndex: Int?

    while supervisedAttempts < options.autoImprovePolicy.maxSupervisedAttempts {
      supervisedAttempts += 1
      let outcome: SupervisedAttemptOutcome
      do {
        outcome = try await runSupervisedAttempt(
          currentRequest,
          runner: runner,
          workflowId: workflow.workflowId,
          runtimeStore: runtimeStore,
          policy: options.autoImprovePolicy
        )
      } catch {
        guard let failedSession = await runtimeStore.latestSession(workflowId: workflow.workflowId) else {
          throw error
        }
        outcome = .completed(failedRunResult(workflow: workflow, session: failedSession))
      }

      switch outcome {
      case let .completed(result):
        fillPendingRemediationTarget(pendingRemediationIndex, targetSessionId: result.session.sessionId, remediations: &remediations)
        pendingRemediationIndex = nil
        current = result
        guard result.status == .failed,
              supervisedAttempts < options.autoImprovePolicy.maxSupervisedAttempts else {
          return result.withSupervision(supervisionRecord(
            status: result.status == .completed ? "succeeded" : "failed",
            policy: options.autoImprovePolicy,
            targetSessionId: result.session.sessionId,
            attempts: supervisedAttempts,
            incidents: incidents,
            remediations: remediations
          ))
        }

        let failedExecution = result.session.executions.last { $0.status == .failed }
        let targetStepId = failedExecution?.stepId ?? workflow.entryStepId
        let incidentId = "incident-\(supervisedAttempts)"
        incidents.append(.object([
          "incidentId": .string(incidentId),
          "category": .string("failure"),
          "sessionId": .string(result.session.sessionId),
          "stepId": .string(targetStepId),
          "executionId": .string(failedExecution?.executionId ?? ""),
          "message": .string(failedExecution?.failureReason ?? "workflow failed")
        ]))

        appendRerunRemediation(
          incidentId: incidentId,
          sourceSessionId: result.session.sessionId,
          targetStepId: targetStepId,
          supervisedAttempts: supervisedAttempts,
          remediations: &remediations
        )
        pendingRemediationIndex = remediations.indices.last
        currentRequest = rerunRequest(
          base: initialRequest,
          workflow: workflow,
          nodePayloads: nodePayloads,
          variables: variables,
          options: options,
          sourceSessionId: result.session.sessionId,
          targetStepId: targetStepId
        )

      case let .stalled(stalledSession):
        fillPendingRemediationTarget(pendingRemediationIndex, targetSessionId: stalledSession.sessionId, remediations: &remediations)
        pendingRemediationIndex = nil
        let failedSession = await markStalledSessionFailed(stalledSession, runtimeStore: runtimeStore, policy: options.autoImprovePolicy)
        let runningExecution = workflowAutoImproveStallTarget(in: stalledSession)
        let targetStepId = runningExecution?.stepId ?? stalledSession.currentStepId ?? workflow.entryStepId
        let incidentId = "incident-\(supervisedAttempts)"
        incidents.append(.object([
          "incidentId": .string(incidentId),
          "category": .string("stall"),
          "sessionId": .string(stalledSession.sessionId),
          "stepId": .string(targetStepId),
          "executionId": .string(runningExecution?.executionId ?? ""),
          "message": .string("workflow made no session progress within \(options.autoImprovePolicy.stallTimeoutMs)ms")
        ]))

        let failedResult = failedRunResult(workflow: workflow, session: failedSession)
        current = failedResult
        guard supervisedAttempts < options.autoImprovePolicy.maxSupervisedAttempts else {
          return failedResult.withSupervision(supervisionRecord(
            status: "failed",
            policy: options.autoImprovePolicy,
            targetSessionId: failedSession.sessionId,
            attempts: supervisedAttempts,
            incidents: incidents,
            remediations: remediations
          ))
        }

        appendRerunRemediation(
          incidentId: incidentId,
          sourceSessionId: failedSession.sessionId,
          targetStepId: targetStepId,
          supervisedAttempts: supervisedAttempts,
          remediations: &remediations
        )
        pendingRemediationIndex = remediations.indices.last
        currentRequest = rerunRequest(
          base: initialRequest,
          workflow: workflow,
          nodePayloads: nodePayloads,
          variables: variables,
          options: options,
          sourceSessionId: failedSession.sessionId,
          targetStepId: targetStepId
        )
      }
    }

    let fallbackSession = await runtimeStore.latestSession(workflowId: workflow.workflowId) ?? WorkflowSession(
      workflowId: workflow.workflowId,
      sessionId: "\(workflow.workflowId)-unstarted-supervision",
      status: .failed,
      entryStepId: workflow.entryStepId,
      createdAt: Date(),
      updatedAt: Date()
    )
    let fallback = current ?? failedRunResult(workflow: workflow, session: fallbackSession)
    return fallback.withSupervision(supervisionRecord(
      status: "failed",
      policy: options.autoImprovePolicy,
      targetSessionId: fallback.session.sessionId,
      attempts: supervisedAttempts,
      incidents: incidents,
      remediations: remediations
    ))
  }
}

private enum SupervisedAttemptOutcome: Sendable {
  case completed(WorkflowRunResult)
  case stalled(WorkflowSession)
}

func workflowAutoImproveCanDetectStall(in execution: WorkflowStepExecution) -> Bool {
  guard execution.status == .running else {
    return false
  }
  guard let backend = execution.backend else {
    return true
  }
  return workflowAutoImproveBackendSupportsHeartbeat(backend) && execution.lastBackendEventAt != nil
}

func workflowAutoImproveStallTarget(in session: WorkflowSession) -> WorkflowStepExecution? {
  session.executions.last(where: workflowAutoImproveCanDetectStall)
}

func workflowAutoImproveLatestStallActivityDate(in session: WorkflowSession) -> Date? {
  session.executions
    .filter(workflowAutoImproveCanDetectStall)
    .compactMap(workflowAutoImproveStallActivityDate)
    .max()
}

func workflowAutoImproveStallActivityDate(_ execution: WorkflowStepExecution) -> Date? {
  if workflowAutoImproveBackendSupportsHeartbeat(execution.backend) {
    return execution.lastBackendEventAt
  }
  return execution.updatedAt
}

func workflowAutoImproveBackendSupportsHeartbeat(_ backend: NodeExecutionBackend?) -> Bool {
  switch backend {
  case .codexAgent, .claudeCodeAgent, .cursorCliAgent:
    return true
  case .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK, nil:
    return false
  }
}

private extension WorkflowRunCommand {
  func runSupervisedAttempt(
    _ request: DeterministicWorkflowRunRequest,
    runner: DeterministicWorkflowRunner,
    workflowId: String,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    policy: WorkflowAutoImprovePolicy
  ) async throws -> SupervisedAttemptOutcome {
    guard policy.stallDetectionEnabled else {
      return .completed(try await runner.run(request))
    }
    return try await withThrowingTaskGroup(of: SupervisedAttemptOutcome.self) { group in
      group.addTask {
        .completed(try await runner.run(request))
      }
      group.addTask {
        .stalled(try await monitorWorkflowStall(workflowId: workflowId, runtimeStore: runtimeStore, policy: policy))
      }
      guard let outcome = try await group.next() else {
        throw CancellationError()
      }
      group.cancelAll()
      return outcome
    }
  }

  func monitorWorkflowStall(
    workflowId: String,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    policy: WorkflowAutoImprovePolicy
  ) async throws -> WorkflowSession {
    var lastActivityDate: Date?
    var lastObservedAt = Date()
    while !Task.isCancelled {
      try await Task.sleep(nanoseconds: millisecondsToNanoseconds(policy.monitorIntervalMs))
      guard let session = await runtimeStore.latestSession(workflowId: workflowId),
            session.status == .running,
            let activityDate = workflowAutoImproveLatestStallActivityDate(in: session) else {
        lastActivityDate = nil
        lastObservedAt = Date()
        continue
      }

      if lastActivityDate != activityDate {
        lastActivityDate = activityDate
        lastObservedAt = Date()
        continue
      }
      if Date().timeIntervalSince(lastObservedAt) * 1_000 >= Double(policy.stallTimeoutMs) {
        return session
      }
    }
    throw CancellationError()
  }

  func millisecondsToNanoseconds(_ milliseconds: Int) -> UInt64 {
    UInt64(milliseconds) * 1_000_000
  }

  func markStalledSessionFailed(
    _ session: WorkflowSession,
    runtimeStore: InMemoryWorkflowRuntimeStore,
    policy: WorkflowAutoImprovePolicy
  ) async -> WorkflowSession {
    guard let runningExecution = workflowAutoImproveStallTarget(in: session) else {
      return session
    }
    _ = try? await runtimeStore.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId,
      executionId: runningExecution.executionId,
      status: .failed,
      failureReason: "workflow made no session progress within \(policy.stallTimeoutMs)ms"
    ))
    return (try? await runtimeStore.loadSession(id: session.sessionId)) ?? session
  }

  func failedRunResult(workflow: WorkflowDefinition, session: WorkflowSession) -> WorkflowRunResult {
    WorkflowRunResult(
      workflowId: workflow.workflowId,
      session: session,
      rootOutput: nil,
      exitCode: 1,
      transitions: 0
    )
  }

  func appendRerunRemediation(
    incidentId: String,
    sourceSessionId: String,
    targetStepId: String,
    supervisedAttempts: Int,
    remediations: inout [JSONValue]
  ) {
    remediations.append(.object([
      "remediationId": .string("remediation-\(supervisedAttempts)"),
      "incidentId": .string(incidentId),
      "action": .string("rerun-workflow"),
      "managerControl": .string("session rerun"),
      "sourceSessionId": .string(sourceSessionId),
      "targetSessionId": .string(""),
      "targetStepId": .string(targetStepId)
    ]))
  }

  func fillPendingRemediationTarget(
    _ index: Int?,
    targetSessionId: String,
    remediations: inout [JSONValue]
  ) {
    guard let index,
          remediations.indices.contains(index),
          case var .object(remediation) = remediations[index] else {
      return
    }
    remediation["targetSessionId"] = .string(targetSessionId)
    remediations[index] = .object(remediation)
  }

  func rerunRequest(
    base: DeterministicWorkflowRunRequest,
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    variables: JSONObject,
    options: WorkflowRunOptions,
    sourceSessionId: String,
    targetStepId: String
  ) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads,
      variables: variables,
      maxSteps: options.maxSteps,
      maxConcurrency: options.maxConcurrency,
      maxLoopIterations: options.maxLoopIterations,
      defaultTimeoutMs: options.defaultTimeoutMs,
      timeoutMs: options.timeoutMs,
      addonAttachments: base.addonAttachments,
      addonAttachmentDescriptors: base.addonAttachmentDescriptors,
      rerunFromSessionId: sourceSessionId,
      rerunFromStepId: targetStepId,
      memoryRootDirectory: base.memoryRootDirectory,
      eventHandler: base.eventHandler
    )
  }

  func supervisionRecord(
    status: String,
    policy: WorkflowAutoImprovePolicy,
    targetSessionId: String,
    attempts: Int,
    incidents: [JSONValue],
    remediations: [JSONValue]
  ) -> JSONObject {
    [
      "supervisionRunId": .string("supervision-\(targetSessionId)"),
      "targetSessionId": .string(targetSessionId),
      "mode": .string("auto-improve"),
      "status": .string(status),
      "attempts": .number(Double(attempts)),
      "policy": .object([
        "maxSupervisedAttempts": .number(Double(policy.maxSupervisedAttempts)),
        "maxWorkflowPatches": .number(Double(policy.maxWorkflowPatches)),
        "monitorIntervalMs": .number(Double(policy.monitorIntervalMs)),
        "stallTimeoutMs": .number(Double(policy.stallTimeoutMs)),
        "stallDetectionEnabled": .bool(policy.stallDetectionEnabled),
        "workflowMutationMode": .string(policy.workflowMutationMode.rawValue),
        "nestedSuperviser": .bool(policy.nestedSuperviser)
      ]),
      "incidents": .array(incidents),
      "remediations": .array(remediations),
      "managerControl": .object([
        "transport": .string("local-runtime"),
        "targetedRerun": .bool(!remediations.isEmpty),
        "command": .string("session rerun")
      ])
    ]
  }
}

private extension WorkflowRunResult {
  func withSupervision(_ supervision: JSONObject) -> WorkflowRunResult {
    var result = self
    result.supervision = supervision
    return result
  }
}
