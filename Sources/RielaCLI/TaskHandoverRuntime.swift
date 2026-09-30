import Foundation
import RielaCore
import RielaWork

struct TaskHandoverRuntime: Sendable {
  var located: TaskCommandRunner.LocatedTask
  var options: TaskStoreOptions
  var hostId = "local"
  var now: @Sendable () -> Date = { Date() }

  func answer(taskId: TaskID, questionId: String, payload: JSONObject, producer: DecisionProducer) throws -> WorkTask {
    try located.store.recordAnswer(
      taskId: taskId, questionId: questionId, payload: payload, producer: producer,
      decisionId: .generate(), now: now()
    )
  }

  func requestTakeover(taskId: TaskID, traits: [HostTrait], producer: DecisionProducer) throws -> WorkTask {
    try located.store.requestTakeover(
      taskId: taskId,
      placement: TakeoverPlacement(hostId: hostId, requiredTraits: traits),
      producer: producer, decisionId: .generate(), now: now()
    )
  }

  func requestHandover(
    taskId: TaskID,
    reason: String,
    immediate: Bool,
    target: String?,
    sinks: [HandoverSinkKind]
  ) throws -> HandoverRequestRecord {
    try located.store.requestHandover(
      taskId: taskId, reason: reason, immediate: immediate, target: target,
      sinks: sinks, now: now()
    )
  }

  func forceOrphan(
    taskId: TaskID,
    producer: DecisionProducer,
    cliSinks: [HandoverSinkKind]
  ) async throws -> HandoverPacket {
    let fenced = try located.store.fenceOrphan(taskId: taskId, now: now(), producer: producer)
    let packet = try await sealOrphan(fenced, cliSinks: cliSinks)
    _ = try located.store.requestTakeover(
      taskId: taskId, placement: TakeoverPlacement(hostId: hostId, requiredTraits: []),
      producer: producer, decisionId: .generate(), now: now()
    )
    return packet
  }

  func reconcileExpired(dryRun: Bool, cliSinks: [HandoverSinkKind]) async throws -> [TaskReconcileEntry] {
    let leases = try located.store.expiredLeases(now: now())
    var entries: [TaskReconcileEntry] = []
    for lease in leases {
      if dryRun {
        entries.append(TaskReconcileEntry(taskId: lease.taskId, attemptId: lease.attemptId, handoverId: nil, action: "would-seal-owner-lost"))
        continue
      }
      let fenced = try located.store.fenceOrphan(
        taskId: lease.taskId, now: now(), producer: .policy(rule: "task-reconcile")
      )
      let packet = try await sealOrphan(fenced, cliSinks: cliSinks)
      entries.append(TaskReconcileEntry(
        taskId: lease.taskId, attemptId: lease.attemptId,
        handoverId: packet.id.rawValue, action: "sealed-owner-lost"
      ))
    }
    return entries
  }

  func adoptAndSeal(
    sessionId: String,
    workingDirectory: String,
    reason: String,
    principal: String,
    existingTaskId: TaskID? = nil,
    cliSinks: [HandoverSinkKind]
  ) async throws -> (WorkTask, HandoverPacket) {
    let sessionRoot = options.sessionStore ?? URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    let executionLock = SessionExecutionLockRegistry(sessionStoreRoot: sessionRoot)
    try executionLock.acquire(sessionId: sessionId)
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).load(sessionId: sessionId)
    guard snapshot.session.status != .running else {
      throw WorkStoreError("running sessions cannot be adopted")
    }
    let reference = WorkflowReference(name: snapshot.session.workflowId)
    let adoption = try TaskAdoption(store: located.store).adopt(
      session: snapshot.session, workflow: reference, workingDirectory: workingDirectory,
      repositoryRoot: workingDirectory, principal: principal, existingTaskId: existingTaskId, now: now()
    )
    guard case let .workflow(workflowReference)? = adoption.task.plan else {
      throw WorkStoreError("adopted task has no workflow reference")
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: workflowReference.name,
      scope: workflowReference.scope.flatMap(WorkflowScope.init(rawValue:)) ?? .auto,
      workflowDefinitionDir: workflowReference.workflowDefinitionDir,
      workingDirectory: workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    let resume = snapshot.session.suspend?.stepId ?? snapshot.session.currentStepId ?? bundle.workflow.entryStepId
    let handoverReason: HandoverReason
    if let suspended = snapshot.session.suspend {
      switch suspended.reasonKind {
      case .userInputRequired:
        guard let question = suspended.question else { throw WorkStoreError("suspended session question is missing") }
        handoverReason = .userInputRequired(question)
      case .userPresenceRequired:
        guard let presence = suspended.presence else { throw WorkStoreError("suspended session presence is missing") }
        handoverReason = .userPresenceRequired(presence)
      case .operatorMove:
        handoverReason = .operatorMove(reason: reason)
      }
    } else {
      handoverReason = .operatorMove(reason: reason)
    }
    let attempt = adoption.attempt
    let packet = try await seal(
      task: adoption.task, attempt: attempt, snapshot: snapshot, bundle: bundle,
      reason: handoverReason, resumeStepId: resume, progressNote: snapshot.session.suspend?.progressNote,
      cliSinks: cliSinks, producer: .human(principal: principal)
    )
    return (adoption.task, packet)
  }

  func handovers(taskId: TaskID) throws -> [HandoverPacket] {
    try located.store.listHandovers(taskId: taskId)
  }

  func sealSuspended(
    taskId: TaskID,
    attempt: Attempt,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    cliSinks: [HandoverSinkKind] = []
  ) async throws -> HandoverPacket {
    guard let record = snapshot.session.suspend else {
      throw WorkStoreError("suspended task session has no SuspendRecord")
    }
    let reason: HandoverReason
    switch record.reasonKind {
    case .userInputRequired:
      guard let question = record.question else { throw WorkStoreError("suspended session question is missing") }
      reason = .userInputRequired(question)
    case .userPresenceRequired:
      guard let presence = record.presence else { throw WorkStoreError("suspended session presence is missing") }
      reason = .userPresenceRequired(presence)
    case .operatorMove:
      reason = .operatorMove(reason: record.progressNote ?? "operator handover")
    }
    guard let task = try located.store.loadTask(id: taskId) else {
      throw WorkStoreError("task '\(taskId.rawValue)' disappeared before handover sealing")
    }
    return try await seal(
      task: task, attempt: attempt, snapshot: snapshot, bundle: bundle,
      reason: reason, resumeStepId: record.stepId, progressNote: record.progressNote,
      cliSinks: cliSinks, producer: .runtime, variables: variables, ownerAlive: true
    )
  }

  func sealTriggered(
    taskId: TaskID,
    attempt: Attempt,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    bundle: ResolvedWorkflowBundle,
    variables: JSONObject,
    reason: HandoverReason
  ) async throws -> HandoverPacket {
    guard let task = try located.store.loadTask(id: taskId) else {
      throw WorkStoreError("task '\(taskId.rawValue)' disappeared before handover sealing")
    }
    return try await seal(
      task: task, attempt: attempt, snapshot: snapshot, bundle: bundle,
      reason: reason, resumeStepId: snapshot.session.currentStepId ?? bundle.workflow.entryStepId,
      progressNote: nil, cliSinks: [], producer: .runtime, variables: variables,
      ownerAlive: reason.kindName != "ownerLost"
    )
  }

  private func sealOrphan(_ fenced: OrphanFenceResult, cliSinks: [HandoverSinkKind]) async throws -> HandoverPacket {
    let attempt = fenced.predecessor
    let sessionRoot = options.sessionStore ?? URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).load(sessionId: attempt.sessionId)
    guard case let .workflow(reference)? = fenced.task.plan else {
      throw WorkStoreError("orphaned task has no workflow plan")
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name,
      scope: reference.scope.flatMap(WorkflowScope.init(rawValue:)) ?? .auto,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
    let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
    let resumeStep = snapshot.session.currentStepId ?? bundle.workflow.entryStepId
    let reason = HandoverReason.ownerLost(fenced.evidence)
    let packet = try await seal(
      task: fenced.task, attempt: attempt, snapshot: snapshot, bundle: bundle,
      reason: reason, resumeStepId: resumeStep, progressNote: nil, cliSinks: cliSinks,
      producer: .runtime, ownerAlive: false, expectedTaskVersion: fenced.task.version
    )
    return packet
  }

  private func seal(
    task: WorkTask,
    attempt: Attempt,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    bundle: ResolvedWorkflowBundle,
    reason: HandoverReason,
    resumeStepId: String,
    progressNote: String?,
    cliSinks: [HandoverSinkKind],
    producer: EvidenceProducer,
    variables: JSONObject = [:],
    ownerAlive: Bool = false,
    expectedTaskVersion: Int? = nil
  ) async throws -> HandoverPacket {
    let reference: WorkflowReference
    guard case let .workflow(value)? = task.plan else { throw WorkStoreError("task has no workflow reference") }
    reference = value
    let workflowRef = HandoverWorkflowRef(
      workflowId: reference.name, scope: reference.scope,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      entryStepId: bundle.workflow.entryStepId, resumeStepId: resumeStepId
    )
    let sinkContext = HandoverSinkContext(
      hostId: hostId, storeRoot: located.root,
      repositoryRoot: options.workingDirectory, store: located.store,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    )
    let configs = HandoverSinkFactory.mergedConfigs(task: task, workflow: bundle.workflow, cliKinds: cliSinks)
    let sinks = try HandoverSinkFactory.make(configs, context: sinkContext)
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let input = HandoverPacketBuilderInput(
      handoverId: HandoverID.generate(), task: task, attempt: attempt, reason: reason,
      resumeStepId: resumeStepId, snapshot: snapshot, workflow: bundle.workflow,
      workflowRef: workflowRef, deliverables: DeliverableCollector(
        workflow: bundle.workflow, nodePayloads: bundle.nodePayloads
      ).collect(snapshot: snapshot), variables: variables, progressNote: progressNote,
      hostId: hostId, producer: producer,
      redaction: TaskHandoverSupport.redactionRules(
        workflow: bundle.workflow, nodePayloads: bundle.nodePayloads, environment: environment
      ), now: now()
    )
    let currentTask = try located.store.loadTask(id: task.id) ?? task
    return try await HandoverCoordinator(
      store: located.store, builder: HandoverPacketBuilder(store: located.store)
    ).seal(HandoverSealRequest(
      builderInput: input,
      publisher: task.context == nil ? nil : TaskDeliverablePublisher(
        store: located.store,
        reservationFence: (try? located.store.loadLease(attemptId: attempt.id)?.fence) ?? -1,
        workflow: bundle.workflow,
        nodePayloads: bundle.nodePayloads
      ),
      ownerAlive: ownerAlive, sinks: sinks,
      decisionId: .generate(), decisionProducer: .policy(rule: "task-handover"),
      predecessorOutcome: WorkEvidenceProjector.outcome(from: snapshot),
      expectedTaskVersion: expectedTaskVersion ?? currentTask.version
    ))
  }
}

struct TaskReconcileEntry: Codable, Equatable, Sendable {
  var taskId: TaskID
  var attemptId: AttemptID
  var handoverId: String?
  var action: String
}
