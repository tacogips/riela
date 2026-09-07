import Crypto
import Foundation
import RielaCore

extension SpecialistCommandRunner {
  /// The normal service is a long-lived, fenced supervisor. `--once` is kept
  /// solely for deterministic diagnostics and tests; it is not the production
  /// lifecycle contract.
  func serve(
    command: SpecialistCommand, parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore, principal: SpecialistPrincipal
  ) async -> CLICommandResult {
    do {
      let lease = try store.acquireServiceLease(workerId: "worker-\(UUID().uuidString.lowercased())")
      defer { try? store.releaseServiceLease(lease) }
      if parsed.serveOnce { return try await servePass(command: command, parsed: parsed, store: store, principal: principal) }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { while !Task.isCancelled { _ = try await self.intakePass(command: command, parsed: parsed, store: store); try await Task.sleep(nanoseconds: 250_000_000) } }
        group.addTask { while !Task.isCancelled { _ = try await self.continuationRoutingPass(command: command, parsed: parsed, store: store); try await Task.sleep(nanoseconds: 100_000_000) } }
        group.addTask { while !Task.isCancelled { _ = try await self.executionPass(parsed: parsed, store: store, principal: principal); try await Task.sleep(nanoseconds: 100_000_000) } }
        group.addTask { while !Task.isCancelled { _ = try await self.deliveryPass(parsed: parsed, store: store); try await Task.sleep(nanoseconds: 250_000_000) } }
        group.addTask {
          var currentLease = lease
          while !Task.isCancelled { try await Task.sleep(nanoseconds: 250_000_000); currentLease = try store.renewServiceLease(currentLease) }
        }
        try await group.waitForAll()
      }
      return CLICommandResult(exitCode: .success)
    } catch is CancellationError {
      return CLICommandResult(exitCode: .success)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "specialist serve failed: \(error)")
    }
  }

  fileprivate func servePass(
    command: SpecialistCommand, parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore, principal: SpecialistPrincipal
  ) async throws -> CLICommandResult {
    let continuations = try await continuationRoutingPass(command: command, parsed: parsed, store: store)
    let acceptedInbound = try await intakePass(command: command, parsed: parsed, store: store)
    let executed = try await executionPass(parsed: parsed, store: store, principal: principal)
    let deliveries = try await deliveryPass(parsed: parsed, store: store)
    struct ServiceResult: Codable { let mode: String; let continuations: [String]; let acceptedInbound: [String]; let executed: [String]; let deliveries: [SpecialistDeliveryReceipt] }
    return try render(ServiceResult(mode: "durable_supervised_lanes", continuations: continuations, acceptedInbound: acceptedInbound, executed: executed.sorted(), deliveries: deliveries), output: command.options.output)
  }

  /// Consumes only persisted continuations. A crash after `beginClarificationContinuation`
  /// and before this lane runs therefore recovers on a new service process.
  fileprivate func continuationRoutingPass(
    command: SpecialistCommand, parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore
  ) async throws -> [String] {
    var routed: [String] = []
    for waiting in try store.pendingCapacityWaitRequests() {
      _ = try store.reopenCapacityWait(taskId: waiting.task.taskId, expectedVersion: waiting.task.version)
      let result = try await submit(
        command: SpecialistCommand(kind: .submit, options: .init(scope: "specialist", command: "submit", target: waiting.request.requestId, arguments: command.options.arguments, output: .json)),
        parsed: parsed, store: store, principal: waiting.request.principal, inboundRequest: waiting.request
      )
      // Still-full capacity is a normal durable retry result, never a reason
      // to abort Matrix cursor advancement or terminate the service.
      guard result.accepted || result.message == "capacity_wait" else {
        throw CLIUsageError("capacity retry was not accepted: \(result.message)")
      }
      routed.append(waiting.request.requestId)
    }
    for continuation in try store.pendingClarificationContinuations() {
      let result = try await submit(
        command: SpecialistCommand(kind: .submit, options: .init(scope: "specialist", command: "submit", target: continuation.request.requestId, arguments: command.options.arguments, output: .json)),
        parsed: parsed, store: store, principal: continuation.request.principal, inboundRequest: continuation.request
      )
      guard result.accepted || result.message == SpecialistRoutingOutcome.unclaimed.rawValue || result.message == SpecialistRoutingOutcome.needsClarification.rawValue || result.message == "capacity_wait" else {
        throw CLIUsageError("clarification continuation was not accepted: \(result.message)")
      }
      routed.append(continuation.request.requestId)
    }
    return routed.sorted()
  }

  fileprivate func intakePass(command: SpecialistCommand, parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore) async throws -> [String] {
    guard let intake = try matrixIntake(parsed: parsed) else { return [] }
    let page = try await intake.poll(since: try store.providerCursor(provider: "matrix"))
    var accepted: [String] = []
    for event in page.events {
      let hash = SHA256.hash(data: Data(event.sourceEventId.utf8)).map { String(format: "%02x", $0) }.joined()
      let request = SpecialistRequest(requestId: "matrix-\(String(hash.prefix(48)))", sourceEventId: event.sourceEventId, principal: event.principal, route: matrixRoute(for: event.body), body: event.body)
      let submitCommand = SpecialistCommand(kind: .submit, options: .init(
        scope: "specialist", command: "submit", target: request.requestId,
        arguments: command.options.arguments, output: .json
      ))
      let result = try await submit(
        command: submitCommand, parsed: parsed, store: store,
        principal: event.principal, inboundRequest: request
      )
      guard result.accepted || result.message == SpecialistRoutingOutcome.unclaimed.rawValue || result.message == SpecialistRoutingOutcome.needsClarification.rawValue || result.message == "capacity_wait" else {
        throw CLIUsageError("Matrix request was not accepted: \(result.message)")
      }
      accepted.append(event.sourceEventId)
    }
    if let cursor = page.nextBatch { try store.saveProviderCursor(provider: "matrix", cursor: cursor) }
    return accepted
  }

  fileprivate func executionPass(parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore, principal: SpecialistPrincipal) async throws -> [String] {
    var completed: [String] = []
    for record in try store.recoverableDispatches() {
      switch record.state {
      case .prepared:
        if try store.task(taskId: record.taskId, principal: principal)?.state == .cancelRequested {
          _ = try store.cancelPreparedDispatch(dispatchId: record.dispatchId)
          completed.append(record.dispatchId)
          continue
        }
        let result = await execute(dispatchId: record.dispatchId, parsed: parsed, store: store, principal: principal, output: .json)
        guard result.exitCode == .success else {
          if let dispatch = try store.dispatch(dispatchId: record.dispatchId),
             dispatch.state == .terminal,
             try store.task(taskId: dispatch.taskId, principal: principal)?.state == .cancelled {
            completed.append(record.dispatchId)
            continue
          }
          if try store.dispatch(dispatchId: record.dispatchId)?.state == .running {
            _ = try store.requireDispatchRecovery(dispatchId: record.dispatchId)
          }
          throw CLIUsageError("specialist execution failed for \(record.dispatchId): \(result.stderr)")
        }
        completed.append(record.dispatchId)
      case .running:
        if try reconcileRunningChild(record, parsed: parsed, store: store) {
          completed.append(record.dispatchId)
        } else if record.childProcessId != nil, childMonitorIsAlive(record) {
          _ = try store.attachRunningDispatch(dispatchId: record.dispatchId)
        } else if record.childProcessId != nil {
          _ = try store.requireDispatchRecovery(dispatchId: record.dispatchId)
        } else {
          // A service can die after beginDispatch, or after the kernel has
          // spawned the monitor but before recordChildMonitor commits. There
          // is no durable monitor identity to attach in either case. Fence
          // the dispatch and permit a later reopen only from the canonical
          // created/no-execution runtime receipt.
          _ = try store.requireDispatchRecovery(dispatchId: record.dispatchId)
        }
      case .recoveryRequired:
        if try hasCanonicalNoEffectStartEvidence(record, parsed: parsed) { _ = try store.reopenUnstartedDispatch(dispatchId: record.dispatchId) }
      case .terminal, .delivered: break
      }
    }
    return completed
  }

  fileprivate func deliveryPass(parsed: SpecialistCLIArguments, store: SpecialistSupervisorStore) async throws -> [SpecialistDeliveryReceipt] {
    // A crashed sender never gains another write attempt merely because its
    // process disappeared. Fence expired generations before selecting pending
    // work, then reconcile uncertainty through stable destination identity.
    _ = try store.fenceExpiredDeliveries()
    guard let worker = try deliveryWorker(parsed: parsed, store: store) else { return [] }
    return await worker.deliverPending() + worker.reconcileUncertain()
  }
}
