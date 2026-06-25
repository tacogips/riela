You are revising the detailed Riela loop-engineering design and implementation plan.

Read:

- `tmp/loop-engineering-detail-plan/intake.json`
- `tmp/loop-engineering-detail-plan/work.json`
- `tmp/loop-engineering-detail-plan/review.json`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `impl-plans/active/loop-engineering-first-line-tool.md`

Revise the design and implementation plan to address every high or middle severity review finding. Preserve accepted content that is still correct.

Do not commit or push. Preserve unrelated dirty worktree changes. Do not start nested agent or workflow processes. Do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`.

Update `tmp/loop-engineering-detail-plan/work.json` with your full JSON output. Return the same JSON object:

```json
{
  "writtenFiles": [],
  "addressedFindings": [],
  "designDecisions": [],
  "implementationSlices": [],
  "compatibilityPlan": [],
  "verification": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-detail-plan/work.json"
}
```
