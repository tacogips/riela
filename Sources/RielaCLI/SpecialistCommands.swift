import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RielaCore
import RielaWorkflowRegistry

struct SpecialistCommandResult: Codable, Equatable, Sendable {
  var accepted: Bool
  var task: SpecialistTask?
  var dispatch: SpecialistDispatch?
  var message: String
}

struct SpecialistCatalogCard: Codable, Equatable, Sendable {
  var workflowId: String
  var workflowName: String
  var shortSummary: String
  var originId: String
  var revision: String
  var active: Bool
}

struct SpecialistCatalogPage: Codable, Sendable {
  let cards: [WorkflowCompactCatalogCard]
  let nextCursor: String?
}

/// Persists a local operator request before any workflow run. Provider identities
/// enter only through authenticated adapters, never command-line flags.
public struct SpecialistCommandRunner: Sendable {
  private let classifierAdapter: any NodeAdapter
  private let httpTransport: any SpecialistHTTPTransport
  private let wrikeGateway: (any SpecialistWrikeGateway)?

  public init() {
    classifierAdapter = makeProductionNodeAdapter()
    httpTransport = URLSessionSpecialistHTTPTransport()
    wrikeGateway = nil
  }

  init(
    classifierAdapter: any NodeAdapter,
    httpTransport: any SpecialistHTTPTransport = URLSessionSpecialistHTTPTransport(),
    wrikeGateway: (any SpecialistWrikeGateway)? = nil
  ) {
    self.classifierAdapter = classifierAdapter
    self.httpTransport = httpTransport
    self.wrikeGateway = wrikeGateway
  }

  public func run(_ command: SpecialistCommand) async -> CLICommandResult {
    do {
      let parsed = try SpecialistCLIArguments(command.options)
      let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
      let store = SpecialistSupervisorStore(rootDirectory: parsed.stateRoot)
      switch command.kind {
      case .catalog:
        return try renderCatalog(parsed: parsed, output: command.options.output)
      case .catalogRefresh:
        return try render(WorkflowCompactCatalog().refresh(workingDirectory: parsed.workingDirectory), output: command.options.output)
      case .serve:
        return await serve(command: command, parsed: parsed, store: store, principal: principal)
      case .submit:
        let result = try await submit(command: command, parsed: parsed, store: store, principal: principal)
        return try render(result, output: command.options.output)
      case .status:
        guard let taskId = command.options.target else { throw CLIUsageError("specialist status requires a task id") }
        let task = try store.task(taskId: taskId, principal: principal)
        let result = SpecialistCommandResult(
          accepted: task != nil,
          task: task,
          dispatch: task?.dispatchId.flatMap { try? store.dispatch(dispatchId: $0) },
          message: task == nil ? "not_found" : "ok"
        )
        return try render(result, output: command.options.output)
      case .cancel:
        guard let taskId = command.options.target else { throw CLIUsageError("specialist cancel requires a task id") }
        guard let task = try store.task(taskId: taskId, principal: principal) else {
          return try render(SpecialistCommandResult(accepted: false, task: nil, dispatch: nil, message: "not_found"), output: command.options.output)
        }
        let cancelled = try store.transition(taskId: taskId, to: .cancelRequested, expectedVersion: task.version)
        let dispatch = cancelled.dispatchId.flatMap { try? store.dispatch(dispatchId: $0) }
        // The nonce-bound owner monitor pulls this durable request and cancels
        // its own execution. A persisted PID is never a signalling authority.
        return try render(SpecialistCommandResult(accepted: true, task: cancelled, dispatch: dispatch, message: "cancel_requested"), output: command.options.output)
      case .execute:
        guard let dispatchId = command.options.target else { throw CLIUsageError("specialist execute requires a dispatch id") }
        return await execute(dispatchId: dispatchId, parsed: parsed, store: store, principal: principal, output: command.options.output)
      case .reconcile:
        if let eventId = parsed.reconcileEventId {
          guard let generation = parsed.reconcileExpectedGeneration,
                let receipt = parsed.reconcileRemoteReceiptId else {
            throw CLIUsageError("delivery reconciliation requires --event-id, --expected-generation, and --remote-receipt-id")
          }
          let settled = try store.reconcileDelivery(
            eventId: eventId, expectedGeneration: generation, remoteReceiptId: receipt
          )
          return try render(settled, output: command.options.output)
        }
        if let taskId = parsed.reconcileTaskId {
          guard let requestId = parsed.reconcileRequestId,
                let version = parsed.reconcileExpectedVersion,
                let outcome = parsed.reconcileOutcome,
                let evidence = parsed.reconcileEvidence else {
            throw CLIUsageError("dispatch reconciliation requires --task-id, --request-id, --expected-version, --outcome, and --evidence")
          }
          let task = try store.reconcileDispatch(
            taskId: taskId, requestId: requestId, expectedVersion: version,
            outcome: outcome, evidence: evidence
          )
          return try render(SpecialistCommandResult(
            accepted: true, task: task,
            dispatch: task.dispatchId.flatMap { try? store.dispatch(dispatchId: $0) },
            message: "reconciled_\(outcome.rawValue)"
          ), output: command.options.output)
        }
        let repaired = try await reconciliationPass(parsed: parsed, store: store)
        struct ReconciliationResult: Codable {
          let dispatches: [SpecialistDispatch]
          let repairedDeliveries: [SpecialistDeliveryReceipt]
        }
        return try render(ReconciliationResult(dispatches: try store.recoverableDispatches(), repairedDeliveries: repaired), output: command.options.output)
      case .smoke:
        return try await SpecialistSmokeCommand().run(options: command.options)
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "specialist command failed: \(error)")
    }
  }

  func submit(
    command: SpecialistCommand,
    parsed: SpecialistCLIArguments,
    store: SpecialistSupervisorStore,
    principal: SpecialistPrincipal,
    inboundRequest: SpecialistRequest? = nil
  ) async throws -> SpecialistCommandResult {
    guard let submittedRequestId = command.options.target else { throw CLIUsageError("specialist submit requires a request id") }
    let incoming = inboundRequest ?? SpecialistRequest(
      requestId: submittedRequestId, sourceEventId: parsed.sourceEventId ?? submittedRequestId,
      principal: principal, route: parsed.route, body: parsed.body
    )
    let request = try store.accept(incoming)
    let requestId = request.requestId
    try validateMockComposition(parsed: parsed)
    if request.route == .status {
      _ = try store.enqueueStatusReply(request)
      return SpecialistCommandResult(accepted: true, task: nil, dispatch: nil, message: "status_reply_queued")
    }
    if request.route == .cancel {
      guard let taskId = explicitControlTaskID(in: request.body, command: "/cancel"),
            let task = try store.task(taskId: taskId, principal: request.principal) else {
        _ = try store.enqueueControlReply(request, message: "No visible task was cancelled. Use /cancel <taskId>.")
        return SpecialistCommandResult(accepted: false, task: nil, dispatch: nil, message: "cancel_not_found")
      }
      let cancelled = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: task.version)
      _ = try store.enqueueControlReply(request, message: "Cancellation requested for \(cancelled.taskId).")
      return SpecialistCommandResult(accepted: true, task: cancelled,
                                     dispatch: cancelled.dispatchId.flatMap { try? store.dispatch(dispatchId: $0) },
                                     message: "cancel_requested")
    }
    if request.route == .clarification {
      guard let continuation = try store.beginClarificationContinuation(request) else {
        _ = try store.enqueueControlReply(request, message: "No clarification is pending for this requester.")
        return SpecialistCommandResult(accepted: false, task: nil, dispatch: nil, message: "clarification_not_found")
      }
      _ = try store.enqueueControlReply(request, message: "Clarification recorded for \(continuation.task.taskId); routing is continuing.")
      // A service-owned continuation lane consumes this persisted request.
      // Do not recurse here: a crash after the durable write must resume the
      // same routing pass on restart, rather than depending on this turn.
      return SpecialistCommandResult(
        accepted: true, task: continuation.task, dispatch: nil,
        message: "clarification_routing_queued"
      )
    }
    guard request.route == .work else { throw CLIUsageError("unsupported specialist request route") }
    if let existing = try store.taskForRoutingRequest(requestId: requestId, principal: request.principal),
       let dispatchId = existing.dispatchId, let dispatch = try store.dispatch(dispatchId: dispatchId) {
      return SpecialistCommandResult(accepted: true, task: existing, dispatch: dispatch, message: "already_accepted")
    }
    let routing = try configuredRouting(parsed: parsed)
    if parsed.mockScenarioPath == nil,
       routing.specialists.contains(where: { $0.allowedOriginIds.isEmpty }) {
      throw CLIUsageError("each production specialist requires nonempty allowedOriginIds")
    }
    let round = try store.beginClassificationRound(SpecialistClassificationRound(
      requestId: request.requestId,
      configurationRevision: routing.revision,
      // The identity is sealed only after the authorized owner chooses one
      // active card. No caller-selected workflow influences ownership.
      catalogRevision: "pending-authorized-selection",
      deadline: Date().addingTimeInterval(routing.deadlineSeconds)
    ))
    let sealed: SpecialistClassificationRound
    if round.sealed {
      sealed = round
    } else {
      let decisions = try await routing.provider.classify(
        request: request, specialists: routing.specialists, deadline: round.deadline
      )
      sealed = try store.sealClassificationRound(requestId: request.requestId, decisions: decisions)
    }
    let settlement = SpecialistRequestRouter.settle(
      route: request.route,
      decisions: sealed.decisions,
      eligibleSpecialistIDs: Set(routing.specialists.map(\.id)),
      priority: routing.specialists.map(\.id)
    )
    _ = try store.recordRouting(requestId: request.requestId, settlement: settlement, decisions: sealed.decisions)
    if settlement.outcome == .status {
      // A classified status question uses the same authenticated persisted
      // resolver as `/status`; it never asks the caller to repeat itself.
      _ = try store.enqueueStatusReply(request)
      return SpecialistCommandResult(
        accepted: true,
        task: nil,
        dispatch: nil,
        message: "status_reply_queued"
      )
    }
    if settlement.outcome == .routingClarification {
      _ = try store.enqueueControlReply(request, message: "Please clarify whether this is new work or a status request.")
      return SpecialistCommandResult(accepted: true, task: nil, dispatch: nil, message: "routing_clarification_queued")
    }
    guard settlement.outcome == .newWork else {
      let response = settlement.outcome == .needsClarification
        ? "More detail is required before assigning this task."
        : "No authorized specialist can currently own this task; it remains queued."
      _ = try store.enqueueControlReply(request, message: response)
      let pendingTask = try store.taskForRoutingRequest(requestId: requestId, principal: request.principal)
        ?? store.createTaskIfWorkRequest(request, taskId: "task-\(requestId)")
      let projected: SpecialistTask?
      if let pendingTask {
        projected = try store.transition(
          taskId: pendingTask.taskId,
          to: settlement.outcome == .needsClarification ? .needsClarification : .unclaimed,
          expectedVersion: pendingTask.version
        )
      } else {
        projected = nil
      }
      return SpecialistCommandResult(accepted: false, task: projected, dispatch: nil, message: settlement.outcome.rawValue)
    }
    guard let task = try store.taskForRoutingRequest(requestId: requestId, principal: request.principal)
      ?? store.createTaskIfWorkRequest(request, taskId: "task-\(requestId)") else {
      throw CLIUsageError("work request did not create a task")
    }
    // Capacity is evaluated in configured priority order, not merely after
    // choosing the lexical/first claimant. A full claimant cannot starve a
    // later authorized claimant with available durable capacity.
    var claimed: SpecialistTask?
    var owner: SpecialistConfiguredSpecialist?
    for candidate in routing.specialists where settlement.claimants.contains(candidate.id) {
      do {
        claimed = try store.claim(
          taskId: task.taskId, ownerId: candidate.id, capacity: candidate.capacity,
          expectedVersion: task.version
        )
        owner = candidate
        break
      } catch SpecialistSupervisorStoreError.capacityUnavailable {
        continue
      }
    }
    guard let claimed, let owner else {
      _ = try store.enqueueControlReply(request, message: "Authorized claimants are at capacity; task \(task.taskId) will retry.")
      let waiting = try store.transition(taskId: task.taskId, to: .capacityWait, expectedVersion: task.version)
      return SpecialistCommandResult(accepted: false, task: waiting, dispatch: nil, message: "capacity_wait")
    }
    guard !owner.allowedOriginIds.isEmpty else {
      throw CLIUsageError("selected specialist has no trusted origin policy")
    }
    let compact: WorkflowCompactCatalogCard
    if let workflowId = parsed.workflowId {
      compact = try selectedCard(workflowId: workflowId, parsed: parsed)
    } else if let selector = routing.provider as? any SpecialistWorkflowSelecting {
      let proposed = try await selector.selectWorkflow(
        request: request, specialist: owner, deadline: Date().addingTimeInterval(routing.deadlineSeconds)
      )
      compact = try selectedCard(workflowId: proposed.workflowId, parsed: parsed, originId: proposed.originId)
      guard compact.revision == proposed.revision else { throw CLIUsageError("selected workflow changed during planning") }
    } else {
      throw CLIUsageError("this classifier requires an explicit --workflow; automatic selection requires classifier.node")
    }
    let workflowId = compact.workflowId
    guard owner.allowedOriginIds.contains(compact.originId) &&
              (owner.allowedWorkflowIds.isEmpty || owner.allowedWorkflowIds.contains(compact.workflowId)) else {
      throw CLIUsageError("selected workflow is outside the specialist authorization policy")
    }
    guard compact.active else { throw CLIUsageError("selected workflow is inactive") }
    let entry = try WorkflowRegistryService().fetch(
      target: WorkflowRegistryTarget(workflowId: workflowId, scope: .auto, originId: compact.originId),
      workingDirectory: parsed.workingDirectory
    )
    guard entry.valid, entry.activationState == .active else { throw CLIUsageError("selected workflow is invalid or inactive") }
    try validateInputJSON(parsed.variables)
    let workflowData = try Data(contentsOf: URL(fileURLWithPath: entry.workflowDirectory).appendingPathComponent("workflow.json"))
    guard let workflow = validateAuthoredWorkflowData(workflowData).workflow else {
      throw CLIUsageError("selected workflow definition is invalid")
    }
    // Capture the exact selected closure before recording a runnable dispatch.
    // The runner never executes the mutable registry directory after this
    // point; it verifies the capture against the sealed card digest instead.
    let dispatchId = "dispatch-\(requestId)"
    try captureWorkflowSnapshot(
      sourceDirectory: URL(fileURLWithPath: entry.workflowDirectory, isDirectory: true),
      dispatchId: dispatchId,
      expectedRevision: compact.revision,
      stateRoot: parsed.stateRoot
    )
    let invocationVariables: String?
    if parsed.variables == nil, let preparer = routing.provider as? any SpecialistInputPreparing {
      let callable = try SpecialistCallableInputValidation.callableNode(
        directory: workflowSnapshotDirectory(stateRoot: parsed.stateRoot, dispatchId: dispatchId),
        workingDirectory: parsed.workingDirectory
      )
      do {
        let prepared = try await preparer.prepareInput(
          request: request, specialist: owner, workflow: compact, callableNode: callable,
          deadline: Date().addingTimeInterval(routing.deadlineSeconds)
        )
        invocationVariables = String(data: try JSONEncoder().encode(prepared), encoding: .utf8)
      } catch SpecialistInputPreparationError.needsClarification(let question) {
        let boundedQuestion = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !boundedQuestion.isEmpty else { throw CLIUsageError("input preparation requested an empty clarification") }
        let waiting = try store.transition(
          taskId: claimed.taskId, to: .needsClarification, expectedVersion: claimed.version
        )
        _ = try store.enqueueControlReply(request, message: boundedQuestion)
        return SpecialistCommandResult(
          accepted: true, task: waiting, dispatch: nil, message: "needs_clarification"
        )
      }
    } else {
      invocationVariables = parsed.variables
    }
    try SpecialistCallableInputValidation.validateSnapshot(
      directory: workflowSnapshotDirectory(stateRoot: parsed.stateRoot, dispatchId: dispatchId),
      variablesJSON: invocationVariables, workingDirectory: parsed.workingDirectory
    )
    let reserved = try store.reserveDispatch(
      taskId: claimed.taskId,
      dispatchId: dispatchId,
      childSessionId: "child-\(requestId)",
      expectedVersion: claimed.version,
      workflowId: entry.workflowId,
      workflowOriginId: compact.originId,
      workflowRevision: compact.revision,
      entryStepId: workflow.managerStepId ?? workflow.entryStepId,
      inputJSON: invocationVariables
    )
    return SpecialistCommandResult(accepted: true, task: reserved, dispatch: try store.dispatch(dispatchId: dispatchId), message: "queued")
  }

  func execute(
    dispatchId: String,
    parsed: SpecialistCLIArguments,
    store: SpecialistSupervisorStore,
    principal: SpecialistPrincipal,
    output: WorkflowOutputFormat
  ) async -> CLICommandResult {
    do {
      // Registry/snapshot/input checks are intentionally completed before the
      // durable running transition. A failed preflight cannot strand accepted
      // capacity in a running dispatch with no monitor.
      guard let dispatch = try store.dispatch(dispatchId: dispatchId) else {
        throw CLIUsageError("dispatch does not exist")
      }
      guard let workflowId = dispatch.workflowId else { throw CLIUsageError("dispatch has no selected workflow") }
      guard let pinned = dispatch.workflowRevision, let originId = dispatch.workflowOriginId else {
        throw CLIUsageError("dispatch lacks immutable registry pin")
      }
      let current = try selectedCard(workflowId: workflowId, parsed: parsed, originId: originId)
      guard current.revision == pinned, current.active else {
        throw CLIUsageError("selected workflow changed after reservation; reconciliation is required")
      }
      let snapshotDirectory = workflowSnapshotDirectory(stateRoot: parsed.stateRoot, dispatchId: dispatchId)
      guard FileManager.default.fileExists(atPath: snapshotDirectory.path) else {
        throw CLIUsageError("reserved workflow snapshot is missing; reconciliation is required")
      }
      guard try WorkflowCompactCatalog().closureRevision(workflowDirectory: snapshotDirectory) == pinned else {
        throw CLIUsageError("reserved workflow snapshot changed; reconciliation is required")
      }
      let snapshotData = try Data(contentsOf: snapshotDirectory.appendingPathComponent("workflow.json"))
      guard validateAuthoredWorkflowData(snapshotData).workflow != nil else {
        throw CLIUsageError("reserved workflow snapshot is invalid")
      }
      // The monitor always resumes a durable child identity. Reserve its
      // canonical created checkpoint before spawning so a persistence failure
      // fails before any subprocess can start, and a restarted monitor never
      // invents a replacement child session.
      try ensureReservedChildRuntimeSnapshot(dispatch: dispatch, stateRoot: parsed.stateRoot)
      let launched = try store.beginDispatch(dispatchId: dispatchId)
      if canLaunchDurableChildMonitor() {
        return try await executeWithDurableChildMonitor(
          dispatch: launched, parsed: parsed, store: store, principal: principal,
          output: output, snapshotDirectory: snapshotDirectory
        )
      }
      let workflowDirectoryName = snapshotDirectory.lastPathComponent
      let run = await WorkflowRunCommand().run(WorkflowRunOptions(
        target: workflowDirectoryName,
        resolution: WorkflowResolutionOptions(
          workflowName: workflowDirectoryName,
          scope: .direct,
          workflowDefinitionDir: snapshotDirectory.path,
          workingDirectory: parsed.workingDirectory
        ),
        variables: launched.inputJSON,
        mockScenarioPath: parsed.mockScenarioPath,
        output: .json,
        // The runner resumes the canonical child snapshot reserved by the
      // supervisor transaction; it must use the same runtime-store root.
        sessionStore: parsed.stateRoot,
        workingDirectory: parsed.workingDirectory,
        explicitWorkingDirectory: true,
        resumeSessionId: launched.childSessionId
      ))
      let terminal = try store.completeDispatch(
        dispatchId: dispatchId,
        succeeded: run.exitCode == .success,
        resultJSON: String(run.stdout.prefix(32_768))
      )
      let completedTask = try store.task(taskId: launched.taskId, principal: principal)
      let result = SpecialistCommandResult(
        accepted: run.exitCode == .success,
        task: completedTask,
        dispatch: terminal,
        message: run.exitCode == .success ? "completed" : "failed"
      )
      return try render(result, output: output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "specialist execute failed: \(error)")
    }
  }

  /// Production service processes launch an independent `riela workflow run`
  /// monitor. That process remains the parent of workflow command subprocesses
  /// after a service SIGKILL, so it can reap them and persist the canonical
  /// SQLite terminal snapshot. A replacement service reconciles that receipt
  /// and never starts a replacement child session.
  private func executeWithDurableChildMonitor(
    dispatch: SpecialistDispatch,
    parsed: SpecialistCLIArguments,
    store: SpecialistSupervisorStore,
    principal: SpecialistPrincipal,
    output: WorkflowOutputFormat,
    snapshotDirectory: URL
  ) async throws -> CLICommandResult {
    let receipt = childReceiptURL(stateRoot: parsed.stateRoot, dispatchId: dispatch.dispatchId)
    try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: receipt.path, contents: nil)
    let receiptHandle = try FileHandle(forWritingTo: receipt)
    defer { try? receiptHandle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let control = SpecialistMonitorControl(
      stateRoot: parsed.stateRoot, dispatchId: dispatch.dispatchId, childSessionId: dispatch.childSessionId
    )
    try control.preparePrivateStore()
    // Persist the nonce before the kernel is asked to spawn. The child must
    // bind it before entering the normal runner, so a late process can be
    // revoked during no-effect recovery.
    _ = try store.authorizeChildMonitorLaunch(dispatchId: dispatch.dispatchId, controlToken: control.nonce)
    try await waitAtSpecialistLaunchTestBoundary("after-begin-dispatch")
    process.environment = try control.launchEnvironment()
    var arguments = [
      "workflow", "run", snapshotDirectory.lastPathComponent,
      "--workflow-definition-dir", snapshotDirectory.path,
      "--working-dir", parsed.workingDirectory,
      "--session-store", parsed.stateRoot,
      "--resume-session-id", dispatch.childSessionId,
      "--output", "json"
    ]
    if let input = dispatch.inputJSON { arguments += ["--variables", input] }
    if let scenario = parsed.mockScenarioPath { arguments += ["--mock-scenario", scenario] }
    process.arguments = arguments
    process.standardOutput = receiptHandle
    process.standardError = receiptHandle
    try process.run()
    try await waitAtSpecialistLaunchTestBoundary("after-process-run-before-monitor-binding")
    _ = try store.recordChildMonitor(
      dispatchId: dispatch.dispatchId, processId: process.processIdentifier, receiptPath: receipt.path, controlToken: control.nonce
    )
    // This wait occupies only the execution lane. Intake, status, delivery,
    // and lease-renewal lanes continue while the monitor owns the child. The
    // independent monitor observes durable cancellation even after service exit.
    while process.isRunning {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    // Monitor exit alone is insufficient: SIGKILL can leave node descendants
    // alive. Require the workflow runner's canonical terminal checkpoint even
    // for cancellation; without it, retain cancel_requested for recovery.
    guard try reconcileRunningChild(dispatch, parsed: parsed, store: store) else {
      _ = try store.requireDispatchRecovery(dispatchId: dispatch.dispatchId)
      throw CLIUsageError("workflow monitor exited without a canonical terminal receipt")
    }
    let terminal = try store.dispatch(dispatchId: dispatch.dispatchId)
    let task = try store.task(taskId: dispatch.taskId, principal: principal)
    return try render(SpecialistCommandResult(
      accepted: task?.state == .succeeded,
      task: task, dispatch: terminal,
      message: task?.state == .cancelled ? "cancelled" : (task?.state == .succeeded ? "completed" : "failed")
    ), output: output)
  }

  /// Debug-only synchronization used by the kernel-backed launch-window
  /// regression. It is compiled out of release products and has no effect
  /// unless both explicitly named test variables are present.
  private func waitAtSpecialistLaunchTestBoundary(_ boundary: String) async throws {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    guard environment["RIELA_SPECIALIST_TEST_LAUNCH_BOUNDARY"] == boundary,
          let acknowledgementPath = environment["RIELA_SPECIALIST_TEST_LAUNCH_BOUNDARY_ACK"],
          !acknowledgementPath.isEmpty else { return }
    let acknowledgement = URL(fileURLWithPath: acknowledgementPath)
    try Data((boundary + "\n").utf8).write(to: acknowledgement, options: .atomic)
    while FileManager.default.fileExists(atPath: acknowledgement.path) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #endif
  }

  /// Returns true when the canonical child record was terminal and its task
  /// projection was committed.  Missing runtime state remains uncertain: it
  /// is intentionally attached for explicit operator reconciliation instead
  /// of being silently relaunched.
  func reconcileRunningChild(
    _ dispatch: SpecialistDispatch,
    parsed: SpecialistCLIArguments,
    store: SpecialistSupervisorStore
  ) throws -> Bool {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: parsed.stateRoot)
    )
    let snapshot: WorkflowRuntimePersistenceSnapshot
    do {
      snapshot = try runtime.load(sessionId: dispatch.childSessionId)
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error { return false }
      throw error
    }
    _ = try store.projectProgress(
      taskId: dispatch.taskId,
      childStepId: snapshot.session.currentStepId,
      childObservedAt: snapshot.session.updatedAt,
      trackerObservedAt: nil,
      uncertain: snapshot.session.status == .created || snapshot.session.status == .running
    )
    switch snapshot.session.status {
    case .created, .running:
      return false
    case .completed, .failed:
      let resultJSON = String(
        data: try JSONEncoder().encode(snapshot), encoding: .utf8
      ) ?? #"{\"runtimeSnapshot\":\"encode_failed\"}"#
      _ = try store.completeDispatch(
        dispatchId: dispatch.dispatchId,
        succeeded: snapshot.session.status == .completed,
        resultJSON: resultJSON
      )
      _ = try store.recordChildReceiptObserved(dispatchId: dispatch.dispatchId)
      return true
    }
  }

  /// Only a created canonical session with no persisted execution proves that
  /// recovery can revoke a launch nonce and retry. A running/failed session,
  /// a node-start phase, or a missing record is explicitly uncertain.
  func hasCanonicalNoEffectStartEvidence(
    _ dispatch: SpecialistDispatch, parsed: SpecialistCLIArguments
  ) throws -> Bool {
    guard dispatch.launchPhase != .nodeStarted else { return false }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: parsed.stateRoot)
    )
    do {
      let snapshot = try runtime.load(sessionId: dispatch.childSessionId)
      return snapshot.session.status == .created && snapshot.session.executions.isEmpty
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error { return false }
      throw error
    }
  }

  private func canLaunchDurableChildMonitor() -> Bool {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    // The process was already started by the kernel. Avoid a second
    // filesystem permission probe here: sandboxed/product test launches can
    // legitimately deny metadata probing even though this is the real riela
    // executable and can spawn its workflow monitor.
    return executable.lastPathComponent == "riela"
  }

  private func childReceiptURL(stateRoot: String, dispatchId: String) -> URL {
    URL(fileURLWithPath: stateRoot, isDirectory: true)
      .appendingPathComponent("child-receipts", isDirectory: true)
      .appendingPathComponent("\(dispatchId).jsonl")
  }

  func childMonitorIsAlive(_ dispatch: SpecialistDispatch) -> Bool {
    guard dispatch.childControlTokenHash != nil, let heartbeat = dispatch.childMonitorHeartbeatAt else { return false }
    let age = Date().timeIntervalSince(heartbeat)
    return age >= 0 && age < 30
  }

  func reconciliationPass(parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore) async throws -> [SpecialistDeliveryReceipt] {
    guard let worker = try deliveryWorker(parsed: parsed, store: store) else { return [] }
    return await worker.reconcileUncertain()
  }

  private func renderCatalog(parsed: SpecialistCLIArguments, output: WorkflowOutputFormat) throws -> CLICommandResult {
    let catalog = WorkflowCompactCatalog()
    let cards = try catalog.list(
      workingDirectory: parsed.workingDirectory, query: parsed.catalogQuery,
      limit: parsed.catalogLimit, cursor: parsed.catalogCursor
    )
    let nextCursor = cards.count == parsed.catalogLimit ? cards.last.map(catalog.paginationCursor(for:)) : nil
    return try render(SpecialistCatalogPage(cards: cards, nextCursor: nextCursor), output: output)
  }

  private func selectedCard(
    workflowId: String, parsed: SpecialistCLIArguments, originId: String? = nil
  ) throws -> WorkflowCompactCatalogCard {
    let requiredOrigin = originId ?? parsed.originId
    return try WorkflowCompactCatalog().select(
      workflowId: workflowId, originId: requiredOrigin, workingDirectory: parsed.workingDirectory
    )
  }

  private func validateInputJSON(_ input: String?) throws {
    guard let input, !input.isEmpty else { return }
    guard let data = input.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
      throw CLIUsageError("--variables must be a JSON object")
    }
  }

  private func workflowSnapshotDirectory(stateRoot: String, dispatchId: String) -> URL {
    URL(fileURLWithPath: stateRoot, isDirectory: true)
      .appendingPathComponent("workflow-snapshots", isDirectory: true)
      .appendingPathComponent(dispatchId, isDirectory: true)
  }

  private func ensureReservedChildRuntimeSnapshot(
    dispatch: SpecialistDispatch, stateRoot: String
  ) throws {
    guard let workflowId = dispatch.workflowId, let entryStepId = dispatch.entryStepId else {
      throw CLIUsageError("dispatch lacks immutable workflow identity")
    }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: stateRoot)
    )
    do {
      let existing = try runtime.load(sessionId: dispatch.childSessionId)
      guard existing.session.workflowId == workflowId,
            existing.session.entryStepId == entryStepId else {
        throw CLIUsageError("reserved child runtime identity conflicts with dispatch")
      }
      return
    } catch let error as WorkflowRuntimePersistenceStoreError {
      guard case .notFound = error else { throw error }
    }
    let now = Date()
    let session = WorkflowSession(
      workflowId: workflowId,
      sessionId: dispatch.childSessionId,
      status: .created,
      entryStepId: entryStepId,
      currentStepId: entryStepId,
      createdAt: now,
      updatedAt: now,
      rootSessionId: dispatch.childSessionId
    )
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func captureWorkflowSnapshot(
    sourceDirectory: URL,
    dispatchId: String,
    expectedRevision: String,
    stateRoot: String
  ) throws {
    let destination = workflowSnapshotDirectory(stateRoot: stateRoot, dispatchId: dispatchId)
    let catalog = WorkflowCompactCatalog()
    if FileManager.default.fileExists(atPath: destination.path) {
      guard try catalog.closureRevision(workflowDirectory: destination) == expectedRevision else {
        throw CLIUsageError("existing workflow snapshot conflicts with selected revision")
      }
      return
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".capture-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: sourceDirectory, to: staging)
      guard try catalog.closureRevision(workflowDirectory: staging) == expectedRevision else {
        throw CLIUsageError("selected workflow changed while capturing its snapshot")
      }
      // This is defense in depth against accidental mutation; the sealed
      // closure digest remains the authority because local operators can alter
      // permissions on their own state directory.
      try makeReadOnly(staging)
      // Same-parent rename publishes only a fully checked immutable capture.
      // A failed or concurrent capture never removes the published destination.
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      try? discardUnpublishedSnapshot(staging)
      throw error
    }
  }

  private func discardUnpublishedSnapshot(_ staging: URL) throws {
    guard FileManager.default.fileExists(atPath: staging.path) else { return }
    if try staging.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      try FileManager.default.removeItem(at: staging)
      return
    }
    // Only the unique staging tree created above is eligible for cleanup.
    // Do not follow symlinks, including links in rejected partial captures.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
    if let files = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      for case let file as URL in files {
        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
          try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
      }
    }
    try FileManager.default.removeItem(at: staging)
  }

  private func makeReadOnly(_ directory: URL) throws {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let previousMode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
      let requiresExecution = values.isDirectory == true || previousMode & 0o111 != 0
      try FileManager.default.setAttributes([.posixPermissions: requiresExecution ? 0o500 : 0o400], ofItemAtPath: url.path)
    }
  }

  private func boundedSummary(_ source: String?, workflowId: String) -> String {
    let normalized = (source ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String((normalized.isEmpty ? "Workflow \(workflowId)" : normalized).prefix(240))
  }

  func render<T: Encodable>(_ result: T, output: WorkflowOutputFormat) throws -> CLICommandResult {
    if output.isStructured { return CLICommandResult(exitCode: .success, stdout: try jsonString(result)) }
    return CLICommandResult(exitCode: .success, stdout: "ok\n")
  }

  private func render(_ result: SpecialistCommandResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    let exitCode: CLIExitCode = result.accepted ? .success : .failure
    if output.isStructured { return CLICommandResult(exitCode: exitCode, stdout: try jsonString(result)) }
    return CLICommandResult(exitCode: exitCode, stdout: result.message + "\n")
  }

  private func configuredRouting(parsed: SpecialistCLIArguments) throws -> SpecialistConfiguredRouting {
    guard let configPath = parsed.specialistConfigPath else {
      throw CLIUsageError("work submission requires --specialist-config; --owner is not an authorization boundary")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let configuration = try JSONDecoder().decode(SpecialistConfiguredRoutingFile.self, from: data)
    guard !configuration.specialists.isEmpty,
          Set(configuration.specialists.map(\.id)).count == configuration.specialists.count,
          configuration.specialists.allSatisfy({ $0.capacity > 0 }) else {
      throw CLIUsageError("specialist configuration has no uniquely authorized specialists")
    }
    let provider: any SpecialistDecisionProvider
    if let fixture = configuration.classifier.fixtureDecisions {
      guard parsed.mockScenarioPath != nil else {
        throw CLIUsageError("fixture classifier requires --mock-scenario and cannot be used for production ownership")
      }
      provider = SpecialistFixtureClassifier(decisions: fixture)
    } else if let node = configuration.classifier.node {
      let cards = try WorkflowCompactCatalog().allCards(workingDirectory: parsed.workingDirectory).filter(\.active)
      provider = SpecialistRielaClassifier(node: node, cards: cards, adapter: classifierAdapter)
    } else {
      guard let endpoint = URL(string: configuration.classifier.endpoint ?? ""),
            endpoint.scheme?.lowercased() == "https",
            let secretEnvironment = configuration.classifier.secretEnvironment,
            let identity = configuration.classifier.providerIdentity, !identity.isEmpty else {
        throw CLIUsageError("specialist classifier requires authenticated HTTPS provider configuration")
      }
      let token: String
      do {
        token = try EnvironmentSpecialistSecretProvider().secret(named: secretEnvironment)
      } catch {
        throw CLIUsageError("specialist classifier secret is unavailable from approved secret provider")
      }
      provider = SpecialistAuthenticatedClassifier(
        endpoint: endpoint, bearerToken: token, providerIdentity: identity, transport: URLSessionSpecialistHTTPTransport()
      )
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return SpecialistConfiguredRouting(
      specialists: configuration.specialists, provider: provider, revision: "sha256:\(digest)",
      deadlineSeconds: max(1, min(configuration.classifier.deadlineSeconds ?? 30, 300))
    )
  }

  func deliveryWorker(parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore) throws -> SpecialistOutboxDeliveryWorker? {
    guard let config = try transportConfiguration(parsed: parsed) else { return nil }
    let matrix: SpecialistMatrixDeliveryAdapter?
    if let value = config.matrix {
      matrix = SpecialistMatrixDeliveryAdapter(
        homeserver: try validatedMatrixHomeserver(value.homeserver),
        accessToken: try resolvedMatrixAccessToken(value, parsed: parsed), transport: httpTransport
      )
    } else { matrix = nil }
    let wrike: SpecialistWrikeDeliveryAdapter?
    if let value = config.wrike {
      let gateway = wrikeGateway ?? SpecialistWrikeGatewayAdapter(configuration: .init(
        folderId: value.folderId, statusByLifecycle: value.statusByLifecycle
      ))
      wrike = SpecialistWrikeDeliveryAdapter(gateway: gateway)
    } else { wrike = nil }
    guard matrix != nil || wrike != nil else { return nil }
    return SpecialistOutboxDeliveryWorker(store: store, matrix: matrix, matrixRoomID: config.matrix?.roomId, wrike: wrike,
                                         matrixAccountID: config.matrix?.accountId)
  }

  func matrixIntake(parsed: SpecialistCLIArguments) throws -> SpecialistMatrixIntakeAdapter? {
    guard let config = try transportConfiguration(parsed: parsed), let matrix = config.matrix else { return nil }
    guard let accountId = matrix.accountId, !accountId.isEmpty,
          let localUserId = matrix.localUserId, !localUserId.isEmpty,
          !matrix.roomId.isEmpty else {
      throw CLIUsageError("Matrix transport requires accountId, localUserId, and roomId")
    }
    return SpecialistMatrixIntakeAdapter(
      homeserver: try validatedMatrixHomeserver(matrix.homeserver),
      accessToken: try resolvedMatrixAccessToken(matrix, parsed: parsed), accountId: accountId,
      localUserId: localUserId, transport: httpTransport, allowedRoomIDs: [matrix.roomId]
    )
  }

  private func transportConfiguration(parsed: SpecialistCLIArguments) throws -> SpecialistTransportConfiguration? {
    guard let path = parsed.transportConfigPath else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw CLIUsageError("specialist transport configuration cannot be read")
    }
    do {
      return try JSONDecoder().decode(SpecialistTransportConfiguration.self, from: data)
    } catch {
      throw CLIUsageError("specialist transport configuration is malformed")
    }
  }

  private func validatedMatrixHomeserver(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
      throw CLIUsageError("Matrix homeserver must be an HTTPS URL")
    }
    return url
  }

  private func resolvedMatrixAccessToken(
    _ matrix: SpecialistTransportConfiguration.Matrix, parsed: SpecialistCLIArguments
  ) throws -> String {
    if let environmentName = matrix.accessTokenEnvironment {
      guard parsed.mockScenarioPath == nil else {
        throw CLIUsageError("mock scenario cannot compose with live Matrix credentials")
      }
      do {
        return try EnvironmentSpecialistSecretProvider().secret(named: environmentName)
      } catch {
        throw CLIUsageError("Matrix access token is unavailable from approved secret provider")
      }
    }
    if parsed.mockScenarioPath != nil, let fixture = matrix.fixtureAccessToken, !fixture.isEmpty {
      return try FixtureSpecialistSecretProvider(value: fixture).secret(named: "FIXTURE_MATRIX_TOKEN")
    }
    throw CLIUsageError("Matrix transport requires accessTokenEnvironment")
  }

  func matrixRoute(for body: String) -> SpecialistRequestRoute {
    let command = body.split(whereSeparator: \.isWhitespace).first?.lowercased()
    switch command {
    case "/status": return .status
    case "/cancel": return .cancel
    default: return .work
    }
  }

  /// Fixture execution is a closed world. It can use only fixture classifier
  /// decisions and fixture Matrix tokens, never an environment credential or
  /// a production transport configuration that could contact a live service.
  private func validateMockComposition(parsed: SpecialistCLIArguments) throws {
    guard parsed.mockScenarioPath != nil, let path = parsed.transportConfigPath else { return }
    let config = try transportConfiguration(parsed: parsed)
    if config?.matrix?.accessTokenEnvironment != nil {
      throw CLIUsageError("mock scenario cannot select a live Matrix credential")
    }
    if config?.wrike != nil, wrikeGateway == nil {
      throw CLIUsageError("mock scenario cannot select the production Wrike transport")
    }
    _ = path // Retain an explicit path binding in diagnostics/source review.
  }

  private func explicitControlTaskID(in body: String, command: String) -> String? {
    let parts = body.split(whereSeparator: \.isWhitespace)
    guard parts.count == 2, parts[0].lowercased() == command else { return nil }
    let candidate = String(parts[1])
    return candidate.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil ? nil : candidate
  }
}
