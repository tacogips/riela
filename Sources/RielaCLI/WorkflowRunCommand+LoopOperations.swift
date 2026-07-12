import Foundation
import RielaCore

/// A concurrency lease acquired at preflight that has not yet bound to a
/// session (design S11).
struct WorkflowRunPendingLease {
  var workflow: WorkflowDefinition
  var storeRoot: String
  var holder: String
}

/// Loop-operations support for `workflow run`: the S11 concurrency preflight
/// and the S12 terminal-outcome notification dispatch.
extension WorkflowRunCommand {
  enum RunConcurrencyPreflight {
    case proceed(WorkflowRunPendingLease?, takeoverDiagnostic: String?)
    case finish(CLICommandResult)
  }

  /// Advisory loop concurrency guard: refuse or skip before any session is
  /// created. The acquired pending lease binds to the real session on the
  /// first snapshot save and releases at terminal save.
  func runConcurrencyPreflight(
    bundle: ResolvedWorkflowBundle,
    storeRoot: String,
    options: WorkflowRunOptions
  ) throws -> RunConcurrencyPreflight {
    switch try loopConcurrencyPreflight(
      workflow: bundle.workflow,
      sessionStoreRoot: storeRoot,
      output: options.output
    ) {
    case let .busyFail(result):
      return .finish(result)
    case let .busySkip(result):
      return .finish(result)
    case let .proceed(leaseHolder, diagnostics):
      let pending = leaseHolder.map {
        WorkflowRunPendingLease(workflow: bundle.workflow, storeRoot: storeRoot, holder: $0)
      }
      return .proceed(pending, takeoverDiagnostic: diagnostics.first)
    }
  }

  /// Releases a lease that never bound to a session (the run failed before
  /// its first snapshot save). Bound leases release at terminal persistence.
  func releasePendingLease(_ lease: WorkflowRunPendingLease?) {
    guard let lease else {
      return
    }
    releasePendingLoopConcurrencyLease(
      workflow: lease.workflow,
      sessionStoreRoot: lease.storeRoot,
      leaseHolder: lease.holder
    )
  }

  /// Best-effort terminal-outcome notification dispatch (design S12): runs
  /// only after terminal persistence succeeded, records every attempt as a
  /// session diagnostic, and never alters the session outcome or exit code.
  func dispatchLoopNotificationsAfterTerminalPersistence(
    finalResult: WorkflowRunResult,
    loopEvidence: LoopEvidenceManifest?,
    bundle: ResolvedWorkflowBundle,
    options: WorkflowRunOptions,
    storeRoot: String
  ) async {
    let diagnostics = await LoopNotificationDispatcher().dispatchIfDeclared(
      workflow: bundle.workflow,
      session: finalResult.session,
      manifest: loopEvidence,
      workflowDirectory: bundle.workflowDirectory,
      workingDirectory: options.workingDirectory
    )
    guard !diagnostics.isEmpty else {
      return
    }
    let store = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)
    )
    if var snapshot = try? store.load(sessionId: finalResult.session.sessionId) {
      snapshot.diagnostics += diagnostics
      try? store.save(snapshot)
    }
  }
}
