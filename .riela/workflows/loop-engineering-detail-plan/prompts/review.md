You are the independent reviewer for the detailed Riela loop-engineering design and implementation plan.

Review:

- `design-docs/specs/design-loop-engineering-first-line-tool.md`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `impl-plans/active/loop-engineering-first-line-tool.md`
- `tmp/loop-engineering-detail-plan/intake.json`
- `tmp/loop-engineering-detail-plan/work.json`

Inspect relevant source/docs enough to verify that the plan references real modules and keeps a safe migration posture.

Review for:

- whether the plan follows the user's decision to make the MVP `core evidence + gate + recovery`
- whether compatibility/backward migration is explicit and non-breaking by default
- whether the implementation plan is concrete enough for Swift implementation
- whether security/redaction and policy enforcement are realistic
- whether the design avoids overbuilding `riela loop` before evidence contracts exist
- whether all changed files are intentional

Do not modify files. Do not start nested agent or workflow processes. Do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`.

Create `tmp/loop-engineering-detail-plan/review.json` with your full JSON output. Return the same JSON object:

```json
{
  "needs_revision": false,
  "accepted": true,
  "findings": [],
  "feedback": [],
  "verification": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-detail-plan/review.json"
}
```

Set `needs_revision` to true if any high or middle finding remains.
