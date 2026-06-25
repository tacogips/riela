Implement only the runtime evidence projector and optional snapshot persistence slice.

Targets:

- Add `Sources/RielaCore/LoopEvidenceProjector.swift`.
- Add optional `loopEvidence` to `WorkflowRuntimePersistenceSnapshot`.
- Round-trip `loopEvidence` through file and SQLite runtime persistence.
- Add focused tests under `Tests/RielaCoreTests` for projector behavior and persistence compatibility.

Do not implement CLI, GraphQL, package promotion, or policy enforcement in this slice. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex commands.

Write `tmp/loop-engineering-runtime-evidence/work.json` and return the same JSON:

```json
{
  "changedFiles": [],
  "implementationSummary": [],
  "verification": [],
  "deferredWork": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-runtime-evidence/work.json"
}
```
