# example-contract-02-core-sdk progress

Mode: `issue-resolution`. Workflow: `codex-design-and-implement-review-loop`. Issue reference: `comm-000002` (design records issueReference null). Codex-agent references: []. Branch: `fix/example-contract-migration`. Installed CLI: `riela --version` -> `0.2.1` (exit 0).

## Implementation status

- [ ] Full assigned implementation complete. This attempt repaired confirmed sandbox and payload defects but has unresolved host-resolution and remaining scenario/inventory work.
- [x] Attempted validate and inspect for all 55 workflow bundles assigned to this plan. `monja-project-task-orchestrator` is a TypeScript example without `workflow.json`; its generated workflows are covered by its scheduler test.
- [ ] Semantically review every assigned node, prompt, scenario, and expected-results file. `bundle-checks.json` inventories existing paths; static review is partial and must not be counted as complete.
- [ ] Run or precisely classify every assigned scenario; 17 selected scenarios ran in this attempt, with five expected negative cases. Remaining scenarios require a safety review and execution/classification.
- [ ] Resolve or disposition six validate/inspect failures. The installed 0.2.1 host resolver reports `unresolvedAddonExecutable` before bundle authoring diagnostics.
- [ ] Complete current-source TypeScript typecheck. `bun run typecheck` exits 1 because the local `@types/bun` definition is absent; no package fetch was attempted.

## Repairs and exact edit evidence

Snapshots `attempt-1/edits/00` through `10` each hold a preimage, intent JSON with SHA-256, contextual patch, and posthash. Sandbox was changed from `read-only` to `workspace-write` in seven design/implementation author nodes plus `task-repair-loop/nodes/node-repair.json`. The X digest summarizer's conflicting `codexAdditionalArgs` sandbox override was removed and its output schema now requires the documented `when` and nested `payload` fields. The Monja orchestrator generator now declares `workspace-write` for work/verification agents and `read-only` for the planner. No shared index or engine file was edited.

## Per-bundle CLI outcomes

Every row below has exact argv, individual full stdout/stderr log paths, exit codes, and path inventory in `attempt-1/bundle-checks.json`. These initial checks ran before edits; affected bundles have fresh checks in `attempt-1/postedit-checks.json`.

| Bundle | validate exit | inspect exit |
| --- | ---: | ---: |
| `apple-calendar-fetch` | 0 | 0 |
| `apple-clock-alarms-list` | 0 | 0 |
| `apple-gateway-admin` | 0 | 0 |
| `apple-gateway-packaging-plan` | 0 | 0 |
| `apple-mail-list` | 0 | 0 |
| `apple-note-create` | 0 | 0 |
| `apple-note-read` | 0 | 0 |
| `apple-notes-list` | 0 | 0 |
| `apple-notifications` | 0 | 0 |
| `apple-reminders-list` | 0 | 0 |
| `claude-riela-claude-worker` | 0 | 0 |
| `claude-riela-codex-coding` | 0 | 0 |
| `codex-codex-topic-debate` | 0 | 0 |
| `design-and-implement-review-loop` | 0 | 0 |
| `design-and-implement-review-loop-feature-plan` | 0 | 0 |
| `dispatcher-llm-resolver-stub` | 0 | 0 |
| `file-markdown-convert` | 0 | 0 |
| `first-four-arithmetic-pipeline` | 0 | 0 |
| `gemini-ocr-worker` | 1 | 1 |
| `gemini-sdk-worker` | 1 | 1 |
| `kaiba-document-intake` | 0 | 0 |
| `loop-baseline-regression-ops` | 0 | 0 |
| `loop-budget-guard` | 0 | 0 |
| `loop-ci-gate-check` | 0 | 0 |
| `loop-concurrency-lease` | 0 | 0 |
| `loop-engineer-quality-loop` | 0 | 0 |
| `loop-outcome-notifications` | 0 | 0 |
| `loop-stall-guard` | 0 | 0 |
| `memory-consolidation` | 1 | 1 |
| `monja-agent-collaboration` | 0 | 0 |
| `monja-typescript-sdk` | 0 | 0 |
| `node-combinations-showcase` | 0 | 0 |
| `note-agent` | 0 | 0 |
| `note-link-extract` | 0 | 0 |
| `note-rag-retrieval-fusion` | 0 | 0 |
| `open-model-provider-codex` | 0 | 0 |
| `recent-change-quality-loop` | 0 | 0 |
| `required-loop-gate-failure` | 0 | 0 |
| `riela-default-workflow-supervisor` | 0 | 0 |
| `routine-task-runner` | 0 | 0 |
| `same-node-session-echo` | 0 | 0 |
| `scheduled-sleep` | 0 | 0 |
| `seatbelt-sandboxed-worker` | 0 | 0 |
| `subworkflow-chained-simple` | 0 | 0 |
| `task-agent-director` | 0 | 0 |
| `task-repair-loop` | 0 | 0 |
| `worker-only-single-step` | 0 | 0 |
| `workflow-call-live-echo` | 0 | 0 |
| `workflow-call-live-echo-callee` | 0 | 0 |
| `workflow-call-review-target` | 0 | 0 |
| `workflow-call-simple` | 0 | 0 |
| `workflow-knowledge-base` | 1 | 1 |
| `wrike-project-kanban-agent` | 0 | 0 |
| `x-follower-ai-business-digest` | 1 | 1 |
| `x-incremental-posts-kv` | 1 | 1 |

Failures: `gemini-ocr-worker`, `gemini-sdk-worker`, `memory-consolidation`, `workflow-knowledge-base`, `x-follower-ai-business-digest`, `x-incremental-posts-kv`. All six report `workflow.requirements` `unresolvedAddonExecutable`; see their full `*-validate.log` and `*-inspect.log` files. This is not reported as a pass.

Minimal upstream reproduction: `riela workflow validate minimal-x-digest --workflow-definition-dir tmp/example-contract-migration/example-contract-02-core-sdk/attempt-1/upstream-repro --output json` exits 1 with `unresolvedAddonExecutable(workflowId: "minimal-x-digest", nodeId: "read-state")`; source and full log are under `attempt-1/upstream-repro/`. `riela/x-digest` is handled in runtime dispatch but absent from installed host resolution. Engine repair and upstream issue submission are outside this plan's write paths; serial owner must route this reproduction upstream before claiming all bundles valid.

## Mock and source-test evidence

`attempt-1/safe-mock-results.json` records 17 exact foreground commands, unique variables/session/artifact paths, full logs, exit codes, status, and node execution counts. Successful statuses: 12; intentional failed statuses: 5. `task-repair-loop` also has a direct successful run under `attempt-1/mock-task-repair/`.

`bun test` from `examples/monja-agent-collaboration` passed 86/86 with zero failures (`attempt-1/monja-agent-tests-scoped.log`, exit 0). The repository-root selector traversed stale `tmp/` copies and was interrupted (exit 130); a subsequent root explicit glob likewise traversed stale copies, 332 pass / 12 fail, exit 1. Those failures refer to missing old snapshot `.build/debug/riela`, not the current example; the scoped current-source suite is the relevant gate. `RIELA_BIN=/opt/homebrew/bin/riela bun test scheduler.test.ts` from `examples/monja-project-task-orchestrator` passed 23/23 after the generator fix (`attempt-1/monja-scheduler-tests-fixed.log`, exit 0). Earlier pre-fix scheduler runs failed 21/23, preserved in separate logs. `bun run typecheck` exits 1 due to missing `@types/bun` (`attempt-1/monja-typecheck.log`).

Do not run `examples/monja-typescript-sdk/scripts/verify.sh`: it backgrounds a mock server and the sibling `../monja/packages/client-typescript` source is absent. Do not run `loop-concurrency-lease/run-demo.sh`: it backgrounds Riela. The current X digest scenario has no step mocks and would reach X gateway, KV, and Telegram. Apple/Gemini/Wrike live integrations require their host, provider, or credentials. `loop-outcome-notifications` needs a plan-local output path and webhook environment cleared before mock execution. These are explicit unverified classifications, not passes.

## Remaining assigned work and downstream boundary

Finish semantic per-file review, scenario safety classification and deterministic execution or precise prerequisite records, repair inaccurate `EXPECTED_RESULTS.md` claims for host-blocked examples, resolve host-resolver ownership with an upstream report, and rerun all relevant gates on the stable tree. Formal independent reviews, shared documentation/index reconciliation, exact-file staging, commit, and non-force push belong to later workflow steps.

## Final author self-check

`riela --version` exited 0 and printed `0.2.1` (`attempt-1/riela-version.log`). `git diff --check` exited 0 (`attempt-1/git-diff-check.log`). SHA-256 verification of all 12 plan-local edit snapshots found no drift. The current tree includes disjoint plan 01 writes; these checks are on a moving shared tree, and the serial join owns stable combined verification. No formal review decision, commit, or push is claimed.
