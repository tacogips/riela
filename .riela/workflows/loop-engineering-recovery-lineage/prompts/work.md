Return concise business JSON only. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex processes.

Implement recovery lineage projection:
- Derive `LoopRecoveryLineage` for run, rerun, and resume entry modes.
- Include lineage on `WorkflowRunResult` and pass it into loop evidence projection.
- Add lineage fields to `session rerun` and `session resume` structured output.
- Persist loop evidence with recovery lineage for session rerun/resume without mutating unrelated persisted sessions.
- Add focused tests for core runner lineage and CLI rerun/resume output/persistence.
