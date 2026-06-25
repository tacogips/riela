Plan the runtime evidence projection slice only.

Read:

- `impl-plans/active/loop-engineering-first-line-tool.md`
- `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Sources/RielaCore/RuntimeSession.swift`

Write `tmp/loop-engineering-runtime-evidence/intake.json` and return the same JSON:

```json
{
  "selectedSlice": "runtime evidence projector and optional snapshot persistence",
  "implementationFiles": [],
  "testFiles": [],
  "excluded": [],
  "artifactPath": "tmp/loop-engineering-runtime-evidence/intake.json"
}
```
