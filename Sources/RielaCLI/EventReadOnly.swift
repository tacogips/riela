import Crypto
import Foundation
import RielaCore
import RielaEvents

/// Read-only remains an ingestion mode, distinct from the one-shot dry run.
/// The legacy spelling shipped in the event skill is accepted fail-closed too.
enum EventReadOnlyPolicy {
  static func isEnabled(parsed: ParsedParityOptions, environment: [String: String]) throws -> Bool {
    var enabled = parsed.readOnly
    for key in ["RIELA_EVENTS_READ_ONLY", "RIEL_EVENTS_READ_ONLY"] {
      guard let raw = environment[key] else { continue }
      switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on": enabled = true
      case "", "0", "false", "no", "off": break
      default: throw CLIUsageError("\(key) requires a boolean value; refusing event dispatch")
      }
    }
    return enabled
  }
}

struct EventReadOnlyDispatchBlocked: Error {}

struct EventOperatorCancelled: Error, CustomStringConvertible {
  let sessionId: String?
  var description: String { "operator_cancelled" }
}

private final class EventTaskHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<WorkflowRunResult, Error>?
  private var cancelled = false
  private var storedSessionId: String?

  func store(_ task: Task<WorkflowRunResult, Error>) {
    lock.lock(); defer { lock.unlock() }
    self.task = task
    if cancelled { task.cancel() }
  }

  func cancel() {
    lock.lock(); defer { lock.unlock() }
    cancelled = true
    task?.cancel()
  }

  func recordSession(_ id: String) {
    lock.lock(); defer { lock.unlock() }
    storedSessionId = id
  }

  var sessionId: String? {
    lock.lock(); defer { lock.unlock() }
    return storedSessionId
  }
}

extension DefaultEventLiveServer {
  /// Every live workflow entry passes this boundary, including injected runners.
  func runEventWorkflow(_ request: EventWorkflowRunRequest, queuedAdmission: Bool = false) async throws -> WorkflowRunResult {
    if queuedAdmission {
      try await admissionGate?.admitQueued()
    } else {
      try await admissionGate?.admit()
    }
    if let registry = sessionCancelRegistry {
      registry.beginRun()
      let cancellation = OperatorCancellation()
      let box = EventTaskHandleBox()
      var registeredRequest = request
      registeredRequest.operatorCancellation = cancellation
      registeredRequest.onSessionStarted = { sessionId in
        box.recordSession(sessionId)
        registry.register(sessionId: sessionId, cancellation: cancellation, cancel: { box.cancel() })
        request.onSessionStarted?(sessionId)
      }
      let childRequest = registeredRequest
      let child = Task {
        let captured = try await currentEnvironment()
        return try await CLIRuntimeEnvironment.$overrides.withValue(nil) {
          try await CLIRuntimeEnvironment.$captured.withValue(captured) {
            guard try !EventReadOnlyPolicy.isEnabled(parsed: childRequest.parsed, environment: captured) else {
              throw EventReadOnlyDispatchBlocked()
            }
            return try await workflowRunner.runWorkflow(childRequest)
          }
        }
      }
      box.store(child)
      do {
        let result = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        if let id = box.sessionId { registry.unregister(sessionId: id) }
        registry.endRun()
        await admissionGate?.release()
        return result
      } catch {
        if let id = box.sessionId { registry.unregister(sessionId: id) }
        registry.endRun()
        await admissionGate?.release()
        if cancellation.isRequested { throw EventOperatorCancelled(sessionId: box.sessionId) }
        throw error
      }
    }
    do {
      let captured = try await currentEnvironment()
      let result = try await CLIRuntimeEnvironment.$overrides.withValue(nil) {
        try await CLIRuntimeEnvironment.$captured.withValue(captured) {
          guard try !EventReadOnlyPolicy.isEnabled(parsed: request.parsed, environment: captured) else {
            throw EventReadOnlyDispatchBlocked()
          }
          return try await workflowRunner.runWorkflow(request)
        }
      }
      await admissionGate?.release()
      return result
    } catch {
      await admissionGate?.release()
      throw error
    }
  }

  /// Persist evidence before advancing matched provider polling cursors. File
  /// watchers retain their existing in-memory scan/startup snapshot semantics.
  /// A read-only delivery never marks workflow execution, reply, or dedupe success.
  func recordReadOnlyEventIfNeeded(
    envelope: ExternalEventEnvelope,
    triggerResult: EventDryRunResult,
    parsed: ParsedParityOptions,
    eventRoot: URL,
    observedAt: Date = Date()
  ) throws -> Bool {
    guard try EventReadOnlyPolicy.isEnabled(
      parsed: parsed, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ) else { return false }
    let idBytes = Data((envelope.sourceId + "\u{0}" + envelope.eventId).utf8)
    let digest = SHA256.hash(data: idBytes).map { String(format: "%02x", $0) }.joined()
    let receiptId = "event-readonly-" + digest
    // The shared receipt store applies the safe-id/containment check and the
    // private permissions used by every other receipt writer.
    let store = EventReceiptStore(eventRoot: eventRoot)
    if let existing = try store.load(receiptId) {
      guard existing.receiptId == receiptId, existing.sourceId == envelope.sourceId, existing.eventId == envelope.eventId,
        existing.reason == "read-only", existing.workflowExecutionId == nil else {
        throw CLIUsageError("Read-only receipt identity mismatch; refusing to advance ingestion")
      }
    } else {
      try store.save(PersistedEventReceipt(
        receiptId: receiptId, sourceId: envelope.sourceId, eventId: envelope.eventId,
        status: triggerResult.accepted ? "skipped" : (triggerResult.diagnostics.isEmpty ? "ignored" : "failed"),
        duplicate: false, workflowExecutionId: nil, workflowName: triggerResult.triggers.first?.workflowName,
        replayedFromReceiptId: nil, reason: "read-only", updatedAt: observedAt, envelope: envelope,
        readOnlyTriggers: triggerResult.triggers, readOnlyDiagnostics: triggerResult.diagnostics
      ))
    }
    try writeServeRecord(
      eventRoot: eventRoot, status: "ready", pollingTarget: envelope.sourceId,
      lastIgnoredReason: "read-only", lastTriggerCount: triggerResult.triggers.count,
      lastEnvelopeSourceId: envelope.sourceId, lastEnvelopeEventType: envelope.eventType.rawValue
    )
    return true
  }
}

struct PersistedEventReceipt: Codable, Equatable, Sendable {
  var receiptId: String
  var sourceId: String
  var eventId: String
  var status: String
  var duplicate: Bool
  var workflowExecutionId: String?
  var workflowName: String?
  var replayedFromReceiptId: String?
  var reason: String?
  var updatedAt: Date
  var envelope: ExternalEventEnvelope
  var readOnlyTriggers: [EventDryRunTriggerSummary]?
  var readOnlyDiagnostics: [EventValidationDiagnostic]?
  var bindingId: String?
  var overlapPolicy: String?
  var overlapPolicySource: String?
  var cancelledSessionIds: [String]?
  var coalescedTickCount: Int?
  /// The `events serve` dispatcher instance (`<pid>-<random>`) that wrote a
  /// cron overlap receipt; absent on CLI-written and older receipts, which
  /// still decode. Used to reconcile receipts a dead serve abandoned.
  var serveInstanceId: String?
}
