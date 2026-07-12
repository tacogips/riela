import Foundation
import RielaCore

/// Typed record emitted when a `loop.concurrency` guard refuses or skips a
/// start (design S11).
public struct LoopConcurrencyBusyRecord: Codable, Equatable, Sendable {
  public var type: String
  public var workflowId: String
  public var holderSessionId: String
  public var holderHeartbeatAt: Date
  public var onBusy: String

  public init(
    type: String,
    workflowId: String,
    holderSessionId: String,
    holderHeartbeatAt: Date,
    onBusy: String
  ) {
    self.type = type
    self.workflowId = workflowId
    self.holderSessionId = holderSessionId
    self.holderHeartbeatAt = holderHeartbeatAt
    self.onBusy = onBusy
  }
}

enum LoopConcurrencyPreflightOutcome {
  /// No guard declared, or the lease was acquired. `leaseHolder` is the
  /// pending placeholder token to release if the run never persists a
  /// snapshot; `diagnostics` carries the stale-takeover note when one
  /// happened.
  case proceed(leaseHolder: String?, diagnostics: [String])
  /// `onBusy == "fail"`: refuse with a non-zero exit; no session is created.
  case busyFail(CLICommandResult)
  /// `onBusy == "skip"`: exit 0 with a skip record; no session is created.
  case busySkip(CLICommandResult)
}

/// Advisory same-loop concurrency guard, invoked by every execution entry
/// that starts (or re-enters) a session for a workflow declaring
/// `loop.concurrency` — `workflow run` (which `loop start` and event-serve
/// delegate to) plus session resume/rerun. Limitations are inherent to an
/// advisory lease: two different data roots see different lease tables, and
/// a paused-but-alive process can lose its lease to staleness takeover.
func loopConcurrencyPreflight(
  workflow: WorkflowDefinition,
  sessionStoreRoot: String,
  output: WorkflowOutputFormat
) throws -> LoopConcurrencyPreflightOutcome {
  guard let concurrency = workflow.loop?.concurrency else {
    return .proceed(leaseHolder: nil, diagnostics: [])
  }
  let store = SQLiteWorkflowRuntimePersistenceStore(
    rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
  )
  let holder = "pending:\(UUID().uuidString)"
  switch try store.acquireLoopConcurrencyLease(workflowId: workflow.workflowId, holder: holder) {
  case let .acquired(takenOverFrom):
    let diagnostics = takenOverFrom.map {
      ["loop concurrency: took over stale lease previously held by session '\($0)'"]
    } ?? []
    return .proceed(leaseHolder: holder, diagnostics: diagnostics)
  case let .busy(holderSessionId, heartbeatAt):
    let record = LoopConcurrencyBusyRecord(
      type: concurrency.onBusy == "skip" ? "loop_concurrency_skipped" : "loop_concurrency_busy",
      workflowId: workflow.workflowId,
      holderSessionId: holderSessionId,
      holderHeartbeatAt: heartbeatAt,
      onBusy: concurrency.onBusy
    )
    let rendered: String
    switch output {
    case .json, .jsonl:
      rendered = ((try? jsonString(record)) ?? "{}").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    case .text, .table:
      rendered = """
      loop concurrency \(concurrency.onBusy == "skip" ? "skipped" : "busy"): workflow '\(workflow.workflowId)' \
      is held by session '\(holderSessionId)' (last heartbeat \(heartbeatAt))

      """
    }
    if concurrency.onBusy == "skip" {
      return .busySkip(CLICommandResult(exitCode: .success, stdout: rendered))
    }
    return .busyFail(CLICommandResult(exitCode: .failure, stdout: rendered, stderr: ""))
  }
}

/// Releases a still-pending lease after a run that never persisted a
/// snapshot (e.g. validation failure before the first save). Once the save
/// path binds the lease to the real session id this is a no-op, and terminal
/// saves release bound leases themselves.
func releasePendingLoopConcurrencyLease(
  workflow: WorkflowDefinition,
  sessionStoreRoot: String,
  leaseHolder: String?
) {
  guard let leaseHolder, workflow.loop?.concurrency != nil else {
    return
  }
  let store = SQLiteWorkflowRuntimePersistenceStore(
    rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
  )
  try? store.releaseLoopConcurrencyLease(workflowId: workflow.workflowId, holder: leaseHolder)
}
