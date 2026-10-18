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

extension DefaultEventLiveServer {
  /// Every live workflow entry passes this boundary, including injected runners.
  func runEventWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    guard try !EventReadOnlyPolicy.isEnabled(
      parsed: request.parsed, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ) else { throw EventReadOnlyDispatchBlocked() }
    return try await workflowRunner.runWorkflow(request)
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
    let root = eventRoot.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = root.appendingPathComponent(receiptId + ".json")
    if FileManager.default.fileExists(atPath: url.path) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let existing = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
      guard existing.receiptId == receiptId, existing.sourceId == envelope.sourceId, existing.eventId == envelope.eventId,
        existing.reason == "read-only", existing.workflowExecutionId == nil else {
        throw CLIUsageError("Read-only receipt identity mismatch; refusing to advance ingestion")
      }
    } else {
      let receipt = PersistedEventReceipt(
        receiptId: receiptId, sourceId: envelope.sourceId, eventId: envelope.eventId,
        status: triggerResult.accepted ? "skipped" : (triggerResult.diagnostics.isEmpty ? "ignored" : "failed"),
        duplicate: false, workflowExecutionId: nil, workflowName: triggerResult.triggers.first?.workflowName,
        replayedFromReceiptId: nil, reason: "read-only", updatedAt: observedAt, envelope: envelope,
        readOnlyTriggers: triggerResult.triggers, readOnlyDiagnostics: triggerResult.diagnostics
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(receipt).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
}
