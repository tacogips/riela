You are selecting the first implementation slice for Riela loop engineering.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Constraints:
{{workflowInput.constraints}}

Read only:

- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `impl-plans/active/loop-engineering-first-line-tool.md`
- `Package.swift`

Select a bounded first Swift implementation slice that moves the full objective forward without breaking existing workflows. The default expected slice is:

- Add core value models for workflow loop metadata, loop evidence manifest, gate result, and recovery lineage.
- Add optional workflow/step `loop` decoding in `WorkflowModel`.
- Add minimal raw validation allowance for the new loop keys.
- Add focused `RielaCoreTests` proving additive decoding and stable Codable behavior.

Do not modify files outside `tmp/`. Do not run nested Riela or Codex commands. Create `tmp/loop-engineering-mvp-implementation/intake.json` and return the same compact JSON:

```json
{
  "selectedSlice": "",
  "targetFiles": [],
  "testFiles": [],
  "excludedForLater": [],
  "compatibilityRules": [],
  "artifactPath": "tmp/loop-engineering-mvp-implementation/intake.json"
}
```
