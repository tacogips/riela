import Foundation
import RielaCore
import RielaWork

extension TaskDispatch {
  func runDirectorChild(
    view: AgentDirectorTaskView,
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult {
    do {
      return try await runDirectorChildImpl(
        view: view, located: located, options: options, output: output
      )
    } catch {
      let attempts = try located.store.listAttempts(taskId: view.task.id)
      guard attempts.max(by: { $0.generation < $1.generation })?.id == view.judgedAttempt.id else {
        throw error
      }
      try escalateDirector(store: located.store, view: view, reason: "director child setup failed: \(error)")
      return try render(TaskRunCommandResult(
        taskId: view.task.id.rawValue, statusKind: .waiting, attemptId: nil,
        sessionId: nil, waitReason: .human, placement: nil
      ), output: output)
    }
  }

  private func runDirectorChildImpl(
    view: AgentDirectorTaskView,
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult {
    let store = located.store
    let taskId = view.task.id
    guard let reference = view.task.director.agentWorkflow,
          let scope = reference.scope.map(WorkflowScope.init(rawValue:)) ?? .auto else {
      throw WorkStoreError("director child has no valid configured workflow")
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name, scope: scope,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
    let bundle = try resolver.resolve(resolution)
    guard bundle.workflow.workflowId == reference.name else {
      throw WorkStoreError("director workflow reference and resolved workflow ID differ")
    }
    let diagnostics = DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
    if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
      throw WorkStoreError("director workflow is invalid: \(diagnostic.path): \(diagnostic.message)")
    }
    let entryStepId = bundle.workflow.entryStepId
    let maps = try await reachableWorkflowMaps(
      bundle: bundle, resolution: resolution, resolver: resolver, entryStepId: entryStepId
    )
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: reference.name, entryStepId: entryStepId,
      workflows: maps.workflows, nodePayloads: maps.nodePayloads,
      nodeHostRequirements: maps.nodeHostRequirements
    )
    let topology = try await hostResolver.taskTopology(
      store: store, scope: scope, workingDirectory: options.workingDirectory,
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
      requirements: requirements, local: topology.local,
      workers: topology.workers, assignments: assignments
    )
    let dispatcher = TaskDispatcher(store: store)
    let preview = try dispatcher.preview(
      taskId: taskId, workflowId: reference.name, entryStepId: entryStepId,
      entry: .director, placement: placement
    )
    guard case let .ready(ready) = preview else {
      try escalateDirector(
        store: store, view: view, reason: "director child placement or dependency is unavailable"
      )
      return try render(TaskRunCommandResult(
        taskId: taskId.rawValue, statusKind: .waiting, attemptId: nil,
        sessionId: nil, waitReason: .human, placement: placement
      ), output: output)
    }
    let context = TaskPlacementExecutionContext(
      bundles: maps.bundles, placement: ready.placement,
      defaultWorkspace: topology.defaultWorkspace
    )
    guard placement.choices.allSatisfy({ maps.bundles[$0.provenance.workflowId] != nil }) else {
      throw WorkStoreError("director placement refers to an unresolved workflow")
    }
    for admittedBundle in maps.bundles.values {
      _ = try runner.applyingTaskPlacement(context, to: admittedBundle)
    }
    if placement.choices.contains(where: { $0.hostId != "local" }) {
      guard try configuredDistributedExecutor(
        environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
      ) != nil else {
        try escalateDirector(store: store, view: view, reason: "director remote placement is unavailable")
        return try render(TaskRunCommandResult(
          taskId: taskId.rawValue, statusKind: .waiting, attemptId: nil,
          sessionId: nil, waitReason: .human, placement: placement
        ), output: output)
      }
    }
    let attemptId = AttemptID.generate()
    let selectedHostId = placement.choices.first(where: {
      $0.provenance.workflowId == reference.name && $0.provenance.stepId == entryStepId
    })?.hostId ?? "local"
    guard let selectedHost = ([topology.local] + topology.workers).first(where: {
      $0.hostId == selectedHostId
    }) else {
      throw WorkStoreError("director selected host has no capability snapshot")
    }
    let countBefore = try store.listAttempts(taskId: taskId).count
    let remaining = view.task.guardPolicy.budget?.maxAttempts.map { max(0, $0 - countBefore - 1) } ?? Int.max
    let childView = AgentDirectorTaskView(
      task: view.task, judgedAttempt: view.judgedAttempt, completion: view.completion,
      guardViolations: view.guardViolations, openFindings: view.openFindings,
      evidenceSummary: view.evidenceSummary, remainingAttempts: remaining
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let viewJSON = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(childView))
    var variables = try WorkflowPlanningCapabilityContext(
      host: selectedHost, requirements: requirements
    ).workflowVariables()
    variables["taskView"] = viewJSON
    var placementEvidence = try makePlacementEvidence(
      for: placement, taskId: taskId, attemptId: attemptId, workflowId: reference.name
    )
    var placementPayload = placementEvidence.payloadRef.inlinePayload ?? [:]
    placementPayload["taskView"] = viewJSON
    placementPayload["hostCapabilityContext"] = variables["hostCapabilityContext"]
    if let workspace = topology.defaultWorkspace {
      placementPayload["defaultWorkspace"] = .string(workspace)
    }
    placementEvidence.payloadRef = .inline(placementPayload)
    try beforeReservation?()
    let admitted: AttemptReservationResult
    do {
      admitted = try dispatcher.reserve(
        ready, attemptId: attemptId,
        sessionId: "task-session-\(UUID().uuidString.lowercased())",
        decisionId: .generate(), producer: .policy(rule: "director-child"),
        reason: "bounded director child", judgedAttemptId: view.judgedAttempt.id,
        placementEvidence: placementEvidence
      )
    } catch {
      try escalateDirector(store: store, view: view, reason: "director child admission denied: \(error)")
      return try render(TaskRunCommandResult(
        taskId: taskId.rawValue, statusKind: .waiting, attemptId: nil,
        sessionId: nil, waitReason: .human, placement: placement
      ), output: output)
    }
    guard case let .reserved(reservation) = admitted else {
      try escalateDirector(store: store, view: view, reason: "director child admission must wait")
      return try render(TaskRunCommandResult(
        taskId: taskId.rawValue, statusKind: .waiting, attemptId: nil,
        sessionId: nil, waitReason: .human, placement: placement
      ), output: output)
    }
    guard try store.listAttempts(taskId: taskId).count == countBefore + 1 else {
      throw WorkStoreError("director child admission did not charge exactly one attempt")
    }
    let sessionRoot = URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    let runOptions = WorkflowRunOptions(
      target: reference.name, resolution: resolution, variables: try jsonString(variables),
      nodePatch: nodePatch, mockScenarioPath: mockScenarioPath, output: output,
      sessionStore: sessionRoot, workingDirectory: options.workingDirectory,
      resumeSessionId: reservation.attempt.sessionId
    )
    _ = try await executeReserved(reservation, options: runOptions, store: store, context: context)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root)
      .load(sessionId: reservation.attempt.sessionId)
    guard snapshot.session.status == .completed || snapshot.session.status == .failed else {
      throw WorkStoreError("director child session did not reach a durable terminal state")
    }
    return try await finishDirectorTerminal(
      attemptId: reservation.attempt.id, snapshot: snapshot, view: childView,
      store: store, placement: placement, options: options, output: output
    )
  }

  func resumeLinkedDirectorIfPresent(
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult? {
    let store = located.store
    guard let latest = try store.listAttempts(taskId: located.task.id).max(by: {
      $0.generation < $1.generation
    }),
          latest.entry == .director, latest.judgedAttemptId != nil else {
      return nil
    }
    guard located.task.state == .running || located.task.state == .verifying
      || located.task.state == .waiting || located.task.state == .succeeded
      || located.task.state == .failed || located.task.state == .cancelled else {
      return nil
    }
    if located.task.state.isTerminal || located.task.state == .waiting {
      let failed = located.task.state == .failed || located.task.state == .cancelled
      return try render(TaskRunCommandResult(
        taskId: located.task.id.rawValue,
        statusKind: failed ? .failed : located.task.state == .succeeded ? .completed : .waiting,
        attemptId: latest.id.rawValue, sessionId: latest.sessionId,
        waitReason: located.task.state == .waiting ? .human : nil, placement: nil
      ), output: output, exitCode: failed ? .failure : .success)
    }
    let context = try store.listEvidence(taskId: located.task.id).first(where: {
      $0.attemptId == latest.id && $0.payloadRef.inlinePayload?["taskView"] != nil
    })
    guard let payload = context?.payloadRef.inlinePayload,
          let viewJSON = payload["taskView"] else {
      throw WorkStoreError("linked director child has no durable judged TaskView")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let view = try decoder.decode(AgentDirectorTaskView.self, from: JSONEncoder().encode(viewJSON))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root)
      .load(sessionId: latest.sessionId)
    if snapshot.session.status == .created, latest.state == .prepared,
       latest.launch?.phase == .reserved {
      return try await resumeReservedDirector(
        attempt: latest, view: view, payload: payload,
        located: located, options: options, output: output
      )
    }
    if snapshot.session.status != .completed && snapshot.session.status != .failed {
      return try await waitForUncertainDirectorChild(
        attempt: latest, view: view, located: located, options: options, output: output
      )
    }
    return try await finishDirectorTerminal(
      attemptId: latest.id, snapshot: snapshot, view: view,
      store: store, placement: nil, options: options, output: output
    )
  }

  private func waitForUncertainDirectorChild(
    attempt: Attempt,
    view: AgentDirectorTaskView,
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult {
    let sessionRoot = URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    let lock = SessionExecutionLockRegistry(sessionStoreRoot: sessionRoot)
    try lock.acquire(sessionId: attempt.sessionId)
    defer { withExtendedLifetime(lock) {} }
    guard let current = try located.store.loadAttempt(id: attempt.id),
          current.entry == .director, current.judgedAttemptId == view.judgedAttempt.id,
          current.sessionId == attempt.sessionId,
          let task = try located.store.loadTask(id: attempt.taskId), task.state == .running,
          try located.store.listAttempts(taskId: task.id).last?.id == attempt.id else {
      throw WorkStoreError("director child changed while recovering uncertain execution")
    }
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root)
      .load(sessionId: current.sessionId)
    if snapshot.session.status == .completed || snapshot.session.status == .failed {
      return try await resumeLinkedDirectorIfPresent(
        located: located, options: options, output: output
      ) ?? CLICommandResult(exitCode: .failure, stderr: "director child disappeared during recovery")
    }
    let decision = Decision(
      id: .generate(), taskId: task.id, attemptId: view.judgedAttempt.id,
      producer: .policy(rule: "director-uncertain-launch"), kind: .wait(.human),
      reason: "director child execution is nonterminal after its process stopped; human reconciliation required",
      createdAt: Date()
    )
    _ = try located.store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: view.completion,
      decisionEvidenceId: .generate()
    )
    return try render(TaskRunCommandResult(
      taskId: task.id.rawValue, statusKind: .waiting,
      attemptId: current.id.rawValue, sessionId: current.sessionId,
      waitReason: .human, placement: nil
    ), output: output)
  }

  private func resumeReservedDirector(
    attempt: Attempt,
    view: AgentDirectorTaskView,
    payload: JSONObject,
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult {
    guard let reference = located.task.director.agentWorkflow,
          let scope = reference.scope.map(WorkflowScope.init(rawValue:)) ?? .auto,
          let placementJSON = payload["placement"],
          let hostJSON = payload["hostCapabilityContext"],
          let viewJSON = payload["taskView"] else {
      throw WorkStoreError("reserved director child has incomplete durable placement inputs")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let placement = try decoder.decode(
      BackendCapabilityPlacementResult.self, from: JSONEncoder().encode(placementJSON)
    )
    let hostContext = try decoder.decode(
      WorkflowPlanningCapabilityContext.self, from: JSONEncoder().encode(hostJSON)
    )
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name, scope: scope,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
    let bundle = try resolver.resolve(resolution)
    guard bundle.workflow.workflowId == reference.name,
          let selected = placement.choices.first(where: {
            $0.provenance.workflowId == reference.name
              && $0.provenance.stepId == bundle.workflow.entryStepId
          }), selected.hostId == hostContext.host.hostId else {
      throw WorkStoreError("reserved director child placement no longer matches its workflow and host")
    }
    let maps = try await reachableWorkflowMaps(
      bundle: bundle, resolution: resolution, resolver: resolver,
      entryStepId: bundle.workflow.entryStepId
    )
    let workspace: String?
    if case let .string(value)? = payload["defaultWorkspace"] {
      workspace = value
    } else {
      workspace = nil
    }
    let context = TaskPlacementExecutionContext(
      bundles: maps.bundles, placement: placement, defaultWorkspace: workspace
    )
    guard placement.choices.allSatisfy({ maps.bundles[$0.provenance.workflowId] != nil }) else {
      throw WorkStoreError("reserved director child placement refers to an unresolved workflow")
    }
    for admittedBundle in maps.bundles.values {
      _ = try runner.applyingTaskPlacement(context, to: admittedBundle)
    }
    let decisions = try located.store.listDecisions(taskId: located.task.id).filter {
      $0.attemptId == attempt.id && $0.producer == .policy(rule: "director-child")
    }
    guard decisions.count == 1, let decision = decisions.first else {
      throw WorkStoreError("reserved director child has no exact admission decision")
    }
    let reservation = AttemptReservation(
      task: located.task, attempt: attempt, decision: decision,
      launchToken: "", reclaimPreLaunch: true
    )
    let sessionRoot = URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    let runOptions = WorkflowRunOptions(
      target: reference.name, resolution: resolution,
      variables: try jsonString(["taskView": viewJSON, "hostCapabilityContext": hostJSON]),
      nodePatch: nodePatch, mockScenarioPath: mockScenarioPath, output: output,
      sessionStore: sessionRoot, workingDirectory: options.workingDirectory,
      resumeSessionId: attempt.sessionId
    )
    _ = try await executeReserved(
      reservation, options: runOptions, store: located.store, context: context
    )
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root)
      .load(sessionId: attempt.sessionId)
    guard snapshot.session.status == .completed || snapshot.session.status == .failed else {
      throw WorkStoreError("reclaimed director child did not reach a durable terminal state")
    }
    return try await finishDirectorTerminal(
      attemptId: attempt.id, snapshot: snapshot, view: view,
      store: located.store, placement: placement, options: options, output: output
    )
  }

  private func finishDirectorTerminal(
    attemptId: AttemptID,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    view: AgentDirectorTaskView,
    store: WorkStore,
    placement: BackendCapabilityPlacementResult?,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) async throws -> CLICommandResult {
    var outcome = WorkEvidenceProjector.outcome(from: snapshot)
    if snapshot.loopEvidence == nil {
      outcome.costs = LoopCostAccumulator.evidence(from: snapshot.session.executions)
    }
    if let cancellation = try store.attemptCancellation(
      taskId: view.task.id, attemptId: attemptId, sessionId: snapshot.session.sessionId
    ) {
      if !cancellation.acknowledged {
        let evidence = try store.listEvidence(taskId: view.task.id).first {
          $0.id == EvidenceID("evidence-placement-\(attemptId.rawValue)")
        }
        guard let placementJSON = evidence?.payloadRef.inlinePayload?["placement"] else {
          throw WorkStoreError("director cancellation has no durable selected placement")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let selected = try decoder.decode(
          BackendCapabilityPlacementResult.self, from: JSONEncoder().encode(placementJSON)
        )
        try await TaskRunCancellation.proveSelectedHostStop(
          choices: selected.choices.filter { $0.hostId != "local" },
          sessionId: snapshot.session.sessionId, store: store
        )
        _ = try store.acknowledgeAttemptCancellation(attemptId: attemptId, outcome: outcome)
      }
      guard let child = try store.loadAttempt(id: attemptId),
            child.state == .reconciled, child.outcome == outcome,
            let task = try store.loadTask(id: view.task.id) else {
        throw WorkStoreError("director cancellation acknowledgment disagrees with its terminal session")
      }
      return try render(TaskRunCommandResult(
        taskId: task.id.rawValue, statusKind: .failed,
        attemptId: child.id.rawValue, sessionId: child.sessionId,
        waitReason: nil, placement: placement,
        error: "director child was cancelled by a task decision"
      ), output: output, exitCode: .failure)
    }
    let child: Attempt
    if let existing = try store.loadAttempt(id: attemptId), existing.state == .reconciled {
      guard existing.outcome == outcome else {
        throw WorkStoreError("replayed director outcome differs from its terminal session")
      }
      child = existing
    } else {
      child = try store.reconcileAttempt(attemptId: attemptId, outcome: outcome)
    }
    return try finishDirectorChild(
      child: child, snapshot: snapshot, view: view,
      store: store, placement: placement, options: options, output: output
    )
  }

  private func finishDirectorChild(
    child: Attempt,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    view: AgentDirectorTaskView,
    store: WorkStore,
    placement: BackendCapabilityPlacementResult?,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat
  ) throws -> CLICommandResult {
    let taskId = view.task.id
    let currentTask = try store.loadTask(id: taskId)
    guard let currentTask else { throw WorkStoreError("director task disappeared after child") }
    guard currentTask.state == .verifying,
          currentTask.version == view.task.version + 2 else {
      throw WorkStoreError("director child decision is stale after newer task work or human action")
    }
    let validation = AgentDirector.validate(
      output: snapshot.rootOutput ?? [:], directorAttempt: child, view: view,
      allowedKinds: ["accept", "reject", "cancel", "rerun", "recover", "wait"],
      causedBy: view.evidenceSummary.map(\.id), decisionId: .generate()
    )
    switch validation {
    case let .needsHuman(reason):
      try escalateDirector(store: store, view: view, reason: reason)
    case let .decision(decision):
      let requestedEntry: AttemptEntry?
      switch decision.kind {
      case let .rerun(stepId): requestedEntry = .rerunFromStep(stepId)
      case let .recover(gateId): requestedEntry = .recoverFromGate(gateId)
      default: requestedEntry = nil
      }
      let pending = requestedEntry.map {
        PendingAttemptReservation(
          id: "pending-\(decision.id.rawValue)", taskId: taskId,
          decisionId: decision.id, predecessorAttemptId: view.judgedAttempt.id, entry: $0
        )
      }
      do {
        if let requestedEntry {
          try validateDirectorTarget(requestedEntry, task: view.task, options: options)
          try validateDirectorWallClockBudget(task: currentTask, store: store)
        }
        _ = try store.applyDecision(
          decision, expectedTaskVersion: currentTask.version,
          completion: view.completion,
          decisionEvidenceId: EvidenceID("evidence-decision-\(decision.id.rawValue)"),
          pendingReservation: pending
        )
      } catch {
        try escalateDirector(store: store, view: view, reason: "director decision rejected: \(error)")
      }
    }
    let finalTask = try store.loadTask(id: taskId)
    let finalState = finalTask?.state
    let failed = finalState == .failed || finalState == .cancelled
    return try render(TaskRunCommandResult(
      taskId: taskId.rawValue,
      statusKind: failed ? .failed : finalState == .succeeded ? .completed : .waiting,
      attemptId: child.id.rawValue, sessionId: child.sessionId,
      waitReason: finalState == .waiting ? .human : nil, placement: placement
    ), output: output, exitCode: failed ? .failure : .success)
  }

  private func validateDirectorTarget(
    _ entry: AttemptEntry, task: WorkTask, options: TaskStoreOptions
  ) throws {
    guard case let .workflow(reference)? = task.plan,
          let scope = reference.scope.map(WorkflowScope.init(rawValue:)) ?? .auto else {
      throw WorkStoreError("director target has no resolvable work workflow")
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name, scope: scope,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
    let workflow = try resolver.resolve(resolution).workflow
    guard workflow.workflowId == reference.name else {
      throw WorkStoreError("director target resolved a different work workflow")
    }
    let stepId: String
    switch entry {
    case let .rerunFromStep(selected):
      stepId = selected ?? workflow.entryStepId
    case let .recoverFromGate(gateId):
      guard let gate = task.completion.gates.first(where: { $0.id == gateId }) else {
        throw WorkStoreError("director recovery gate '\(gateId)' does not exist")
      }
      stepId = gate.stepId
    default:
      throw WorkStoreError("director target is not a rerun or recovery entry")
    }
    guard workflow.steps.contains(where: { $0.id == stepId }) else {
      throw WorkStoreError("director target step '\(stepId)' does not exist")
    }
  }

  private func validateDirectorWallClockBudget(task: WorkTask, store: WorkStore) throws {
    guard let limit = task.guardPolicy.budget?.maxWallClockMs else { return }
    let sessions = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
    var used = 0
    for attempt in try store.listAttempts(taskId: task.id) where attempt.state == .reconciled {
      let session = try sessions.loadStrictReadOnly(sessionId: attempt.sessionId).session
      guard session.sessionId == attempt.sessionId,
            session.status == .completed || session.status == .failed else {
        throw WorkStoreError("director budget has no durable terminal session for an attempt")
      }
      let duration = max(0, Int(session.updatedAt.timeIntervalSince(session.createdAt) * 1_000))
      let (sum, overflow) = used.addingReportingOverflow(duration)
      used = overflow ? Int.max : sum
    }
    guard used < limit else {
      throw WorkStoreError("director recommendation exhausted task wallClock budget")
    }
  }

  private func escalateDirector(
    store: WorkStore, view: AgentDirectorTaskView, reason: String
  ) throws {
    guard let task = try store.loadTask(id: view.task.id) else {
      throw WorkStoreError("director task is missing during escalation")
    }
    guard task.state == .verifying,
          let latest = try store.listAttempts(taskId: task.id).max(by: {
            $0.generation < $1.generation
          }),
          latest.id == view.judgedAttempt.id || (
            latest.entry == .director && latest.judgedAttemptId == view.judgedAttempt.id
              && latest.state == .reconciled
          ) else {
      throw WorkStoreError("director escalation cannot overwrite newer task state")
    }
    let decision = Decision(
      id: .generate(), taskId: task.id, attemptId: view.judgedAttempt.id,
      producer: .policy(rule: "director-escalation"), kind: .wait(.human),
      reason: reason, createdAt: Date()
    )
    _ = try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: view.completion,
      decisionEvidenceId: .generate()
    )
  }
}
