import ArgumentParser
import Foundation
import RielaAdapters
import RielaCore

/// Reads the recovery lineage persisted on the source session's evidence
/// manifest so rerun/resume entries can thread `rootSessionId`/`attemptNumber`
/// (and the runner can enforce `budget.maxSessionAttempts`) without walking
/// session chains. Absent snapshots or manifests degrade to nil (attempt one).
func persistedRecoveryLineage(
  sessionId: String,
  storeRoot: String
) -> LoopRecoveryLineage? {
  let store = SQLiteWorkflowRuntimePersistenceStore(
    rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)
  )
  return (try? store.load(sessionId: sessionId))?.loopEvidence?.recovery
}

func projectLoopEvidence(
  session: WorkflowSession,
  workflowMessages: [WorkflowMessageRecord],
  bundle: ResolvedWorkflowBundle,
  recovery: LoopRecoveryLineage?
) -> LoopEvidenceManifest? {
  try? DefaultLoopEvidenceProjector().project(
    LoopEvidenceProjectionInput(
      workflow: bundle.workflow,
      session: session,
      workflowMessages: workflowMessages,
      workflowSource: loopWorkflowSource(from: bundle),
      recovery: recovery
    )
  )
}

private func loopWorkflowSource(from bundle: ResolvedWorkflowBundle) -> LoopWorkflowSource {
  LoopWorkflowSource(
    scope: bundle.sourceScope.rawValue,
    kind: bundle.packageManifest == nil ? "workflow-directory" : "package",
    workflowDirectory: bundle.workflowDirectory,
    packageName: bundle.packageManifest?.name,
    packageVersion: bundle.packageManifest?.version,
    packageDirectory: bundle.packageDirectory,
    mutable: bundle.provenance == .mutable
  )
}
