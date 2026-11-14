Implement only workflow-run persistence connection for loop evidence.

Targets:

- Project `LoopEvidenceManifest` during live and final `workflow run` persistence when the resolved workflow has `loop` metadata.
- Preserve legacy runs with `loopEvidence: nil`.
- Add focused CLI tests that run a loop workflow and assert persisted SQLite/file snapshots contain loop evidence and gates.

Do not implement loop CLI commands, GraphQL, package promotion, or policy enforcement in this slice. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex commands.

Write `tmp/loop-engineering-run-persistence/work.json` and return the same JSON:

```json
{
  "changedFiles": [],
  "implementationSummary": [],
  "verification": [],
  "deferredWork": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-run-persistence/work.json"
}
```
