import Foundation
import RielaCore
import RielaWork

struct TaskRunCommandResult: Codable, Sendable {
  var taskId: String
  var status: String
  var attemptId: String?
  var sessionId: String?
  var waitReason: WaitReason?
  var placement: BackendCapabilityPlacementResult?
}

/// Bridges Work's atomic admission to the existing CLI workflow runner.
struct TaskDispatch: Sendable {
  var resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()
  var hostResolver: any HostCapabilityResolving = HostCapabilityResolver()
  var runner: WorkflowRunCommand = WorkflowRunCommand()
  var mockScenarioPath: String?
  var beforeReservation: (@Sendable () throws -> Void)?
  var nodePatch: String?

  func run(
    taskId: String,
    options: TaskStoreOptions,
    dryRun: Bool,
    output: WorkflowOutputFormat
  ) async -> CLICommandResult {
    do {
      let id = TaskID(taskId)
      guard let located = try TaskCommandRunner().locateTask(id, in: options) else {
        throw WorkStoreError("task '\(taskId)' was not found")
      }
      guard let plan = located.task.plan else {
        throw WorkStoreError("task '\(taskId)' has no executable plan")
      }
      guard case let .workflow(reference) = plan else {
        throw WorkStoreError("temporary task workflows are not yet executable")
      }
      guard let scope = reference.scope.map(WorkflowScope.init(rawValue:)) ?? .auto else {
        throw WorkStoreError("task '\(taskId)' has an invalid workflow scope")
      }
      let resolution = WorkflowResolutionOptions(
        workflowName: reference.name,
        scope: scope,
        workflowDefinitionDir: reference.workflowDefinitionDir,
        workingDirectory: options.workingDirectory
      )
      let bundle = try resolver.resolve(resolution)
      guard bundle.workflow.workflowId == reference.name else {
        throw WorkStoreError("task workflow reference and resolved workflow ID differ")
      }
      let diagnostics = DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
      if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
        throw WorkStoreError("task workflow is invalid: \(diagnostic.path): \(diagnostic.message)")
      }
      let dispatcher = TaskDispatcher(store: located.store)
      let pending = try dispatcher.pendingReservation(taskId: id)
      let entry = pending?.entry ?? .start
      let entryStepId = try selectedEntryStep(entry, task: located.task, workflow: bundle.workflow)
      var maps = try await reachableWorkflowMaps(
        bundle: bundle,
        resolution: resolution,
        resolver: resolver,
        entryStepId: entryStepId
      )
      maps.bundles[bundle.workflow.workflowId]?.workflow.entryStepId = entryStepId
      let requirements = try WorkflowRequirementResolver().resolve(
        workflowId: bundle.workflow.workflowId,
        entryStepId: entryStepId,
        workflows: maps.workflows,
        nodePayloads: maps.nodePayloads,
        nodeHostRequirements: maps.nodeHostRequirements
      )
      let topology = try await hostResolver.taskTopology(
        store: located.store,
        scope: resolution.scope,
        workingDirectory: options.workingDirectory,
        localAddonExecutables: maps.localAddonExecutables
      )
      var assignments: [WorkflowRequirementProvenance: DistributedWorkerTarget] = [:]
      for requirement in requirements {
        for provenance in requirement.provenance {
          if let target = maps.workflows[provenance.workflowId]?
            .steps.first(where: { $0.id == provenance.stepId })?.placement?.target {
            assignments[provenance] = target
          }
        }
      }
      let placement = BackendCapabilityPlacementResolver().resolve(
        requirements: requirements,
        local: topology.local,
        workers: topology.workers,
        assignments: assignments
      )
      let preview = try dispatcher.preview(
        taskId: id,
        workflowId: reference.name,
        entryStepId: entryStepId,
        entry: entry,
        placement: placement
      )
      switch preview {
      case let .wait(reason):
        return try render(TaskRunCommandResult(
          taskId: taskId, status: "waiting", attemptId: nil,
          sessionId: nil, waitReason: reason, placement: placement
        ), output: output)
      case let .ready(ready):
        let taskContext = TaskPlacementExecutionContext(
          bundles: maps.bundles,
          placement: ready.placement,
          defaultWorkspace: topology.defaultWorkspace
        )
        guard ready.placement.choices.allSatisfy({ maps.bundles[$0.provenance.workflowId] != nil }) else {
          throw WorkStoreError("task placement refers to an unresolved workflow")
        }
        for admittedBundle in maps.bundles.values {
          _ = try runner.applyingTaskPlacement(taskContext, to: admittedBundle)
        }
        if dryRun {
          return try render(TaskRunCommandResult(
            taskId: taskId, status: "ready", attemptId: nil,
            sessionId: nil, waitReason: nil, placement: ready.placement
          ), output: output)
        }
        if ready.placement.choices.contains(where: { $0.hostId != "local" }) {
          guard try configuredDistributedExecutor(
            environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
          ) != nil else {
            throw WorkStoreError("remote task placement requires a configured distributed controller")
          }
        }
        let attemptId = AttemptID.generate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let placementRecord = try JSONDecoder().decode(
          JSONValue.self, from: encoder.encode(ready.placement)
        )
        let placementEvidence = Evidence(
          id: EvidenceID("evidence-placement-\(attemptId.rawValue)"),
          taskId: id,
          attemptId: attemptId,
          kind: .contextSnapshot,
          producedBy: .runtime,
          payloadRef: .inline([
            "placement": placementRecord,
            "workflowId": .string(bundle.workflow.workflowId)
          ]),
          createdAt: Date()
        )
        try beforeReservation?()
        let reserved = try dispatcher.reserve(
          ready,
          attemptId: attemptId,
          sessionId: "task-session-\(UUID().uuidString.lowercased())",
          decisionId: pending?.decisionId ?? .generate(),
          producer: .policy(rule: "task-run"),
          reason: "task run",
          placementEvidence: placementEvidence,
          pendingRequestId: pending?.id
        )
        guard case let .reserved(reservation) = reserved else {
          guard case let .wait(reason) = reserved else {
            throw WorkStoreError("task reservation returned no attempt or wait reason")
          }
          return try render(TaskRunCommandResult(
            taskId: taskId, status: "waiting", attemptId: nil,
            sessionId: nil, waitReason: reason, placement: placement
          ), output: output)
        }
        let sessionRoot = URL(fileURLWithPath: located.root).deletingLastPathComponent().path
        let runOptions = WorkflowRunOptions(
          target: reference.name,
          resolution: resolution,
          nodePatch: nodePatch,
          mockScenarioPath: mockScenarioPath,
          output: output,
          sessionStore: sessionRoot,
          workingDirectory: options.workingDirectory,
          resumeSessionId: reservation.attempt.sessionId
        )
        let workflowResult = await runner.runTaskReservation(
          runOptions, reservation: reservation, store: located.store, context: taskContext
        )
        let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root)
          .load(sessionId: reservation.attempt.sessionId)
        guard snapshot.session.status == .completed || snapshot.session.status == .failed else {
          throw WorkStoreError("reserved task session did not reach a durable terminal state")
        }
        try reconcileTerminal(snapshot: snapshot, reservation: reservation, store: located.store, taskId: id)
        if workflowResult.exitCode != .success { return workflowResult }
        return try render(TaskRunCommandResult(
          taskId: taskId, status: snapshot.session.status.rawValue,
          attemptId: attemptId.rawValue,
          sessionId: reservation.attempt.sessionId,
          waitReason: nil,
          placement: placement
        ), output: output)
      }
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func reconcileTerminal(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    reservation: AttemptReservation,
    store: WorkStore,
    taskId: TaskID
  ) throws {
    let id = taskId
    let attemptId = reservation.attempt.id
    let projection = WorkEvidenceProjector().project(
      snapshot: snapshot,
      task: reservation.task,
      attempt: reservation.attempt
    )
    let terminalEvidence = Evidence(
      id: EvidenceID("evidence-terminal-\(attemptId.rawValue)"),
      taskId: id,
      attemptId: attemptId,
      kind: .contextSnapshot,
      producedBy: .runtime,
      payloadRef: .inline(["sessionStatus": .string(snapshot.session.status.rawValue)]),
      createdAt: snapshot.session.updatedAt
    )
    try store.saveEvidence(projection.evidence + [terminalEvidence])
    try store.saveFindings(projection.findings, taskId: id)
    _ = try store.reconcileAttempt(
      attemptId: attemptId,
      outcome: WorkEvidenceProjector.outcome(from: snapshot)
    )
    let currentTask = try store.loadTask(id: id)
    let currentAttempt = try store.loadAttempt(id: attemptId)
    guard let currentTask, let currentAttempt else {
      throw WorkStoreError("reconciled task attempt is missing")
    }
    let attempts = try store.listAttempts(taskId: id)
    let completion = try store.currentCompletionVerdict(taskId: id, attemptId: attemptId)
    let gateEvidence = projection.evidence.reduce(into: [String: EvidenceID]()) { result, evidence in
      guard evidence.kind == .gate,
            case let .string(gateId)? = evidence.payloadRef.inlinePayload?["gateId"] else { return }
      result[gateId] = evidence.id
    }
    let gateResults = attempts.flatMap { $0.outcome?.gateResults ?? [] }
    let sessionStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
    var cumulativeWallClockMs = 0
    for attempt in attempts {
      let session = try attempt.id == attemptId
        ? snapshot.session : sessionStore.loadStrictReadOnly(sessionId: attempt.sessionId).session
      guard session.sessionId == attempt.sessionId,
            session.status == .completed || session.status == .failed else {
        throw WorkStoreError("task attempt has no durable terminal session for guard evaluation")
      }
      let durationMs = max(0, Int(session.updatedAt.timeIntervalSince(session.createdAt) * 1_000))
      let (sum, overflow) = cumulativeWallClockMs.addingReportingOverflow(durationMs)
      cumulativeWallClockMs = overflow ? Int.max : sum
    }
    let snapshotInput = TaskGuardSnapshotAdapter.make(
      attempts: attempts,
      session: snapshot.session,
      wallClockMs: cumulativeWallClockMs,
      signals: RunnerGuardSignals(gateResults: gateResults)
    )
    let violations = WorkGuard.evaluate(policy: currentTask.guardPolicy, snapshot: snapshotInput)
    let guardApplication = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: currentTask,
      latestAttempt: currentAttempt,
      snapshot: snapshotInput,
      completion: completion,
      failedStepId: nil,
      attemptFailureEvidenceId: snapshot.session.status == .failed ? terminalEvidence.id : nil,
      gateEvidenceIds: gateEvidence,
      completionEvidenceIds: completion.isSatisfied ? [terminalEvidence.id] : [],
      violationEvidenceIds: violations.indices.map {
        EvidenceID("evidence-guard-\(attemptId.rawValue)-\($0)")
      },
      decisionId: DecisionID("decision-terminal-\(attemptId.rawValue)"),
      decisionEvidenceId: EvidenceID("evidence-decision-terminal-\(attemptId.rawValue)")
    )
    if guardApplication.application == nil, completion.isSatisfied {
      let decision = Decision(
        id: DecisionID("decision-warning-completion-\(attemptId.rawValue)"),
        taskId: id,
        attemptId: attemptId,
        producer: .policy(rule: "completion-after-warning"),
        kind: .accept,
        reason: "completion contract is satisfied",
        causedBy: [terminalEvidence.id],
        createdAt: Date()
      )
      _ = try store.applyDecision(
        decision,
        expectedTaskVersion: currentTask.version,
        completion: completion,
        decisionEvidenceId: EvidenceID("evidence-decision-warning-completion-\(attemptId.rawValue)")
      )
    }
  }

  private func selectedEntryStep(
    _ entry: AttemptEntry,
    task: WorkTask,
    workflow: WorkflowDefinition
  ) throws -> String {
    let stepId: String
    switch entry {
    case .start, .resume:
      stepId = workflow.entryStepId
    case let .rerunFromStep(selected):
      stepId = selected ?? workflow.entryStepId
    case let .recoverFromGate(gateId):
      guard let gate = task.completion.gates.first(where: { $0.id == gateId }) else {
        throw WorkStoreError("task recovery gate '\(gateId)' does not exist")
      }
      stepId = gate.stepId
    case .director:
      throw WorkStoreError("director child requires bounded director dispatch")
    }
    guard workflow.steps.contains(where: { $0.id == stepId }) else {
      throw WorkStoreError("task entry step '\(stepId)' does not exist")
    }
    return stepId
  }

  private func render(_ result: TaskRunCommandResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      var lines = ["taskId: \(result.taskId)", "status: \(result.status)"]
      if let attemptId = result.attemptId { lines.append("attemptId: \(attemptId)") }
      if let sessionId = result.sessionId { lines.append("sessionId: \(sessionId)") }
      if let reason = result.waitReason { lines.append("waitReason: \(reason)") }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }
}
