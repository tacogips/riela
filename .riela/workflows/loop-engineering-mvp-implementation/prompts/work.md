You are implementing the first Swift MVP slice for Riela loop engineering.

Read:

- `tmp/loop-engineering-mvp-implementation/intake.json`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `impl-plans/active/loop-engineering-first-line-tool.md`

Implement only the first compatible core slice:

- Add core Codable/Equatable/Sendable value types for loop metadata, loop evidence manifest, structured gate result, recovery lineage, policy/evidence declarations, redaction summaries, and related refs.
- Add optional `loop` metadata to authored workflow, normalized workflow, and step refs in `WorkflowModel` while preserving existing JSON compatibility.
- Update workflow validation raw-key allowlists enough that workflows with `loop` metadata validate, without requiring metadata on legacy workflows.
- Add focused unit tests under `Tests/RielaCoreTests` for absent/partial/full loop metadata decoding, manifest Codable round-trip, gate result Codable round-trip, and validation accepting additive `loop` keys.

Keep implementation additive. Do not implement CLI, GraphQL, persistence, package promotion, or runtime policy enforcement in this slice. Do not split files unless needed. If touching any Swift file over 1000 lines, avoid growing it substantially; prefer new files for new types/tests.

Run focused Swift tests if feasible using the explicit Xcode Swift toolchain from the repository instructions. Try SwiftLint if Swift code changed. If a command cannot run, record why.

Do not commit or push. Preserve unrelated dirty worktree changes. Do not start nested Riela or Codex commands.

Create `tmp/loop-engineering-mvp-implementation/work.json` and return the same JSON:

```json
{
  "changedFiles": [],
  "implementationSummary": [],
  "verification": [],
  "deferredWork": [],
  "residualRisks": [],
  "artifactPath": "tmp/loop-engineering-mvp-implementation/work.json"
}
```
