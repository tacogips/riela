Review the first Swift MVP slice for Riela loop engineering.

Read only `tmp/loop-engineering-mvp-implementation/work.json` and inspect the current diff for these files only:

- `Sources/RielaCore/LoopEngineeringModels.swift`
- `Sources/RielaCore/LoopEvidenceManifest.swift`
- `Sources/RielaCore/LoopGateResult.swift`
- `Sources/RielaCore/LoopRecoveryLineage.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowValidation.swift`
- `Tests/RielaCoreTests/LoopEngineeringModelsTests.swift`
- `Tests/RielaCoreTests/WorkflowLoopMetadataCodableTests.swift`
- `Tests/RielaCoreTests/WorkflowLoopValidationTests.swift`

Accept if the slice is additive, focused on core Codable loop metadata/evidence/gate/recovery models, preserves legacy workflow compatibility, and the recorded focused tests/SwiftLint are credible. Do not modify files, commit, push, or start nested Riela/Codex commands.

Create `tmp/loop-engineering-mvp-implementation/review.json` and return the same JSON:

```json
{
  "needs_revision": false,
  "accepted": true,
  "findings": [],
  "verification": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-mvp-implementation/review.json"
}
```

Set `needs_revision` to true when any high or middle severity finding remains.
