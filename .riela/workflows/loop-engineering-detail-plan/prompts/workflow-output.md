You are publishing the accepted detailed design and implementation-plan handoff.

Read only:

- `tmp/loop-engineering-detail-plan/work.json`
- `tmp/loop-engineering-detail-plan/review.json`

Do not inspect large files. Do not run git commands. Do not modify files. Do not start nested agent or workflow processes. Do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`.

Return one concise JSON object. Keep each array to at most 5 items:

```json
{
  "accepted": true,
  "workflowId": "loop-engineering-detail-plan",
  "designPath": "design-docs/specs/design-loop-engineering-first-line-tool-detail.md",
  "implementationPlanPath": "impl-plans/active/loop-engineering-first-line-tool.md",
  "summary": "",
  "topDecisions": [],
  "implementationSlices": [],
  "changedFiles": [],
  "verification": [],
  "residualRisks": []
}
```
