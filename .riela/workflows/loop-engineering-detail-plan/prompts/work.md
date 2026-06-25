You are the authoring worker for the detailed Riela loop-engineering design and implementation plan.

Read `tmp/loop-engineering-detail-plan/intake.json` and `design-docs/specs/design-loop-engineering-first-line-tool.md`. Inspect relevant source/docs enough to ground implementation details, but keep exploration bounded to likely targets under `Sources/RielaCore`, `Sources/RielaCLI`, `Sources/RielaGraphQL`, `Tests/RielaCoreTests`, `Tests/RielaCLITests`, and `Tests/RielaGraphQLTests`.

Write these files:

- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `impl-plans/active/loop-engineering-first-line-tool.md`

The detailed design must be implementation-ready and must cover:

- compatibility and migration strategy
- loop metadata and workflow usage contract shape
- `LoopEvidenceManifest` MVP data model
- structured gate result model
- recovery lineage and rerun/resume semantics
- mutation/process policy enforcement posture
- CLI, GraphQL, runtime persistence, and package-promotion surfaces
- security/redaction defaults
- phased rollout and explicit non-goals

The implementation plan must use the repository's `impl-plans/templates/plan-template.md` style and must include:

- status, design references, scope included/excluded
- concrete Swift module/file targets
- DTO/model/interface sketches where useful
- test plan by module
- dependency ordering
- completion criteria
- progress log
- migration/backward-compatibility notes

Do not commit or push. Preserve unrelated dirty worktree changes. Do not start nested agent or workflow processes. Do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`.

Create `tmp/loop-engineering-detail-plan/work.json` with your full JSON output. Return the same JSON object:

```json
{
  "writtenFiles": [],
  "designDecisions": [],
  "implementationSlices": [],
  "compatibilityPlan": [],
  "verification": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-detail-plan/work.json"
}
```
