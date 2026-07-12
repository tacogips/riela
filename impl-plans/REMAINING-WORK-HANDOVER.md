# Remaining Work Handover

**Snapshot date**: 2026-07-12 (Asia/Tokyo)

**Repositories**: `riela` and sibling `../riela-packages`

**Purpose**: transfer every known unfinished task without losing dirty-worktree ownership, review evidence, dependency ordering, or verification obligations

**Status**: handover inventory complete; implementation workflows intentionally stopped at the user's request

## 1. Executive handoff

The `riela` worktree is intentionally dirty and contains several distinct bodies of work. Do not clean, reset, stage, commit, or broadly rewrite it. The sibling `riela-packages` worktree is clean at this snapshot. No Riela workflow, Claude process, or Codex implementation worker remains active.

The next implementer must first finish and independently accept the interrupted Section 8 workflow-versioning hardening. After that clean boundary, run the checked-in project workflow `codex-tool-reap-recovery` with Claude Opus 4.8 to implement Riela-side recovery from unreaped terminal Codex tool children. The correct Claude model identifier is `claude-opus-4-8`; `claude-opus-4.8` is invalid in the installed Claude CLI and is misresolved as retired Opus 4.

The repository has 35 files under `impl-plans/active/`, 262 unchecked implementation-plan checkboxes, and 15 unchecked design checkboxes. All 262 plan checkboxes are assigned below to exactly one of seven checkbox-owning workstreams. The 15 design checkboxes are all in the RielaApp execution-timeline design and are traceability details for its five plan-level acceptance items; they are not counted as a separate workstream.

Several active plans contain no unchecked boxes but are not uniformly complete. They require an explicit status/evidence audit: some should move to `completed/`, while others describe real work using prose or status fields rather than checkboxes. Section 6 assigns every such plan to one primary owner.

## 2. Baseline and preservation rules

### 2.1 Repository state

| Repository | State at snapshot | Rule |
| --- | --- | --- |
| `riela` | 68 dirty paths when this inventory began; includes modified, deleted, and untracked user/worker changes | Preserve all changes. Never use destructive reset/checkout. Inspect overlap before editing. |
| `riela-packages` | Clean (`git status --short` empty) | Change only when an affected Riela contract is duplicated in packaged workflows/skills. Refresh affected digests and run registry validation. |

Scratch artifacts for `riela` must remain under `riela/tmp/`. If `riela-packages` needs changes, its scratch artifacts must remain under `riela-packages/tmp/`. Do not commit either scratch tree.

### 2.2 Work already completed; do not redo

- Agent response streaming is implemented, reviewed, tested, and moved from `impl-plans/active/agent-response-streaming.md` to `impl-plans/completed/agent-response-streaming.md`. Its dirty source/document changes are intentional.
- Codex unified-exec default disablement, WAL-safe read-only SQLite fallback, scope-search resilience, repeated silence warnings, and CLI `backendSilentForMs` projection are implemented. Only the terminal tool-child recovery follow-up remains in that plan.
- Loop first-line tool Section 8 rounds one through seven landed in the dirty tree and passed round-seven evidence: 21 adversarial tests, 74 Section 8 focused tests, 1,714 full Swift tests with four skips and zero failures, strict scoped SwiftLint with zero violations, and `git diff --check`.
- Round-eight Section 8 production changes are partially present. Do not discard them; finish and review them as described in W0.
- `riela-packages` already uses the correct `claude-opus-4-8` model identifier in the packages found by the audit. Do not mass-rewrite those files.

### 2.3 Current dirty-work ownership groups

The dirty paths fall into these primary ownership groups:

1. **Agent streaming completion**: `Sources/RielaAdapters/LocalAgentBackendEventCoalescer.swift`, streaming changes in `LocalAgentProcess.swift`, `ScenarioNodeAdapter.swift`, `RuntimeSession.swift`, `RuntimeStore.swift`, related tests and `design-agent-response-streaming.md`.
2. **Loop first-line/Section 8**: workflow history/versioning/transaction files under `Sources/RielaCLI/Workflow*.swift`, canonical history models under `Sources/RielaCore/`, Section 8 tests, loop design/plan/progress/inventory changes, and CLI extraction files.
3. **Tool-reap workflow definition**: `.riela/workflows/codex-tool-reap-recovery/`. This is authored and validated but its implementation steps were not allowed to complete.
4. **Plan bookkeeping**: `impl-plans/README.md`, deletion of the old active agent-streaming plan, and addition of the completed copy.

Some files, especially `LocalAgentProcess.swift`, are cross-cutting. Before W1 edits them, establish the accepted W0/streaming baseline and diff only the intended ownership slice.

## 3. Immediate recovery point

### W0 — Finish interrupted Section 8 round-eight hardening

**Primary sources**:

- `impl-plans/active/loop-engineering-first-line-tool.md`
- `impl-plans/active/loop-engineering-first-line-tool-progress.md`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `design-docs/specs/design-incomplete-work-inventory.md`

**State**:

- Independent review after round seven returned zero high and four medium findings:
  1. committed recovery must recreate/exact-verify both operation and transaction audits before cleanup;
  2. marker cleanup must retain descriptor-pinned parents through unlink/fsync;
  3. snapshot/proposal/change-set/runtime-gate construction must be descriptor-relative end to end;
  4. legacy split-record reconciliation must use the real transition graph and evidence-evolution rules.
- Round-eight implementation added, among other files, `WorkflowHistoryPrivateDirectory.swift`, `WorkflowPinnedRecordCleanup.swift`, and `WorkflowRound8AdversarialTests.swift`.
- Latest recorded round-eight run executed 19 tests: four legacy-reconciliation tests passed and 15 tests failed through one common cleanup path. After an earlier type-check fix, the current common error is `CLIUsageError("unable to remove private workflow history artifact")` at `Sources/RielaCLI/WorkflowHistoryPrivateDirectory.swift:163` during adversarial child/leaf/ancestor swaps.
- The round-eight Riela session was canceled to avoid concurrent edits. Its snapshot is under `tmp/complete-all-design-impl/section8-fix8-artifacts/section8-review-fix-round8-session-1/`; logs include `tmp/fix-round8/round8-2.log` and `round8-3.log` when present.

**Next actions**:

1. Diagnose cleanup semantics for an intentionally replaced private artifact. Cleanup must remain descriptor-relative and must not hide the primary adversarial rejection, escape the pinned root, or delete an attacker-controlled replacement.
2. Make all 19 `WorkflowRound8AdversarialTests` pass.
3. Re-run all Section 8 focused suites and strict SwiftLint for every changed Section 8 file.
4. Run full `swift test`, file-size checks, and `git diff --check` on the exact final tree.
5. Run a new independent read-only adversarial review. Accept only when high and medium findings are zero.
6. Reconcile the Section 8 plan/progress/inventory status from evidence. Do not mark the broader loop plan complete merely because Section 8 passes.

**Stop condition**: W0 is not complete until round-eight tests are green and a fresh independent review reports zero high/medium findings.

## 4. Checkbox-owning workstreams

The following seven workstreams own all 262 unchecked implementation-plan boxes. Counts are snapshot counts, not effort estimates.

### W1 — Codex terminal tool-child correlation and recovery — 12 unchecked

**Plan**: `impl-plans/active/codex-unified-exec-stall-followup.md`

**Design**: `design-docs/specs/design-codex-unified-exec-stall-followup.md`

**Required executor**: Riela workflow using Claude Opus 4.8

Deliverables:

- Persist per-attempt tool-call/process correlation with direct-agent PID/PGID, descendant PID, and process-start identity.
- Track `command_execution` started/completed state independently from generic backend heartbeats.
- Classify only unresolved, ownership-safe terminal/zombie descendants whose live host misses completion past a grace period.
- Request host-side completion first, then ownership-revalidate and perform bounded process-group TERM/grace/KILL; reap only Riela's direct child through the single completion owner.
- Continue the same attempt only with an acknowledged terminal result and intact stream; otherwise use mutation-safe, budgeted auto-improve retry/rerun.
- Persist idempotent CAS incident/remediation state; cancellation wins all races; diagnostics and inspection are redacted.
- Add off/observe/recover policy plus grace/continuation controls across CLI, library, GraphQL, serialization, help, and local/remote execution.
- Add deterministic macOS/Linux unit and integration coverage for the real post-summary/unreaped-child shape.

Prepared workflow:

```text
.riela/workflows/codex-tool-reap-recovery/
```

It has plan, implement, independent review/fix, and verify steps, all fixed to `claude-code-agent` / `claude-opus-4-8`. It was structurally validated. Several planning runs were intentionally canceled as scope changed; no W1 source implementation was accepted from those runs.

Run only after W0 establishes a stable overlapping worktree:

```bash
.build/debug/riela workflow validate codex-tool-reap-recovery \
  --workflow-definition-dir .riela/workflows --output json

.build/debug/riela workflow run codex-tool-reap-recovery \
  --workflow-definition-dir .riela/workflows \
  --session-store tmp/codex-tool-reap-recovery/final-sessions \
  --artifact-root tmp/codex-tool-reap-recovery/final-artifacts \
  --auto-improve --max-supervised-attempts 2 \
  --workflow-mutation-mode execution-copy \
  --stall-timeout-ms 600000 --monitor-interval-ms 5000 \
  --default-timeout-ms 7200000 --max-steps 8 --output jsonl
```

`riela-packages` impact is conditional: update duplicated workflow-run/auto-improve/troubleshooting guidance only after the final policy surface is known; refresh affected `riela-package.json` digests and run `task check` there.

### W2 — Loop engineering application gap closure — 62 unchecked

**Plan**: `impl-plans/active/loop-engineering-application-gap-closure.md`

**State**: LA1a implemented; LA1b and later phases not started.

Primary deliverables:

- `loop start` policy-panel/delegation behavior and `loop promote` readiness.
- Cost value types, usage accumulation, duration/evidence projection, and legacy decoding.
- Budget metadata/validation/enforcement, failure kind, lineage, cancellation, and progress evidence.
- Deterministic evidence diff and workflow statistics.
- CLI diff/stats, GraphQL projections, `gates --check` exit-code contract, SARIF export, and CI example.

Order: LA1b → cost model/accumulator → budget → diff/stats → CLI/GraphQL → CI/SARIF. W3 consumes the diff/stat types; publish stable typed contracts before W3 integration.

### W3 — Loop convergence and operations — 30 unchecked

**Plan**: `impl-plans/active/loop-engineering-convergence-and-operations.md`

**State**: LB1 implemented; LB2–LB6 remain.

Primary deliverables:

- SQLite loop baselines and set/show/clear APIs.
- Regression verdict classification and CLI baseline/regress/diff sugar.
- Authored concurrency policy, lease table, acquire/heartbeat/release semantics, and shared run/event preflight.
- Busy fail/skip behavior, stale takeover diagnostics, and advisory limitations.
- Terminal-outcome notification metadata, dispatch, env indirection, retries, diagnostics, and package warnings.

Dependencies: tolerant failure decoding from W2 budget work; `LoopEvidenceDiffer` and stats from W2. Avoid implementing duplicate diff/stat types in W3.

### W4 — Apple local-gateway add-on completion/hardening — 79 unchecked

| Plan | Count | Primary remaining scope |
| --- | ---: | --- |
| `apple-mail-addons.md` | 48 | list/message add-ons, GraphQL rendering/parsing, secure materialization/download, FDA/error mapping, deterministic tests, example/docs/verification |
| `apple-notes-crud-addons.md` | 27 | intermediate-symlink/root hardening, soft missing note semantics, process-group descendant cleanup, verification |
| `apple-clock-alarm-addons.md` | 4 | real envelope/time-format QA for Clock and Shortcuts bridge behavior |

Share one hardened process-group/timeout primitive where appropriate, but do not conflate it with W1's Codex tool-call classifier. W4 owns Apple gateway semantics; W1 owns agent tool lifecycle/supervision.

### W5 — Package registry, checkout, publish, and migration — 72 unchecked

| Plan | Count | Primary remaining scope |
| --- | ---: | --- |
| `package-checkout-content-digest-metadata.md` | 1 | final later review with no high/mid findings |
| `workflow-package-checkout-search.md` | 19 | opt-in pre-install static/container checks, findings/redaction, reject/warn policy, sandboxed command construction, rollback/overwrite safety |
| `workflow-package-publish.md` | 22 | option/error tests, hardened git adapter, clone/remote checks, source resolution, metadata/backend hints, permission/PR/dirty-worktree coverage |
| `workflow-package-registry-migration.md` | 26 | source/package equality, registry metadata/docs, checkout/validate/usage/mock smoke, status and verification |
| `workflow-package-registry.md` | 4 | invalid-package refresh diagnostics and publish cache-refresh contracts |

Recommended sequence:

1. Reconcile these plans against the current Swift implementation; several progress notes still name old TypeScript/Biome commands.
2. Finish registry diagnostics/contracts.
3. Finish checkout safety and digest review.
4. Finish publish transport and failure tests.
5. Perform migration/docs/smoke verification against clean `riela-packages`.

`riela-packages` is clean now. Old migration notes claiming a dirty registry are historical and must not be treated as current blockers. Any payload edit requires the release skill's digest refresh and registry `task check`.

### W6 — RielaApp instance execution timeline — 5 plan checks + 15 design checks

**Plan**: `impl-plans/active/rielaapp-instance-execution-timeline.md`

**Design**: `design-docs/specs/design-rielaapp-instance-execution-timeline.md`

**State**: not started.

Implement viewer data enrichment, timeline layout, AppKit timeline pane, detail popover, viewer integration, and instance entry point. Verify completed, live, loop-heavy, legacy-no-message-log, and never-run sessions. Timeline data must come through `WorkflowViewerLoader`, not direct App SQLite reads. Use the `rielaapp-ui-verification` workflow/skill for visual verification.

The 15 design checkboxes are subordinate traceability items for this workstream; do not count them as 15 additional independent tasks.

### W7 — Shared workflow serving completion — 2 unchecked

**Plan**: `impl-plans/active/shared-workflow-serving-library.md`

Confirm `riela serve` delegates lifecycle behavior to the shared library, run the prescribed verification commands, reconcile the contradictory `Ready`/`COMPLETED` status, and move the plan only after evidence passes.

## 5. Non-checkbox workstreams and blockers

### W8 — Riela Note remaining product scope

**Plan**: `impl-plans/active/riela-note.md` (`Partially implemented`).

Remaining prose-defined work includes real libsql embedded-replica/sync execution and parity, remote listener/socket/HTTP registration paths, and deferred vector/multi-source RAG/web-search behavior. Split these into explicit checklists or follow-up plans before implementation so completion is measurable. Do not infer that five checked boxes mean the whole plan is complete.

### W9 — Swift runtime deletion gate and instance/package guidance

- `swift-cli-runtime-parity-gap-closure.md`: accepted implementation is largely present, but deletion readiness remains blocked on current accepted review/adversarial metadata and final evidence updates. Do not delete legacy TypeScript until the readiness JSON and review gate are truthfully accepted.
- `workflow-instance-unification.md`: implementation is marked completed, but prose records packaged-skill guidance and full/live/remote verification follow-ups. Route packaged guidance to `riela-packages`; archive only after deciding whether those follow-ups belong here or in a new plan.

### W10 — Runtime capability roadmap without an owning active checklist

From `design-incomplete-work-inventory.md` and `WorkflowRuntimeCapabilityGap`:

- live fanout transitions;
- `run.maxConcurrency`;
- invalid cross-workflow/resume combinations and library callee-resolver requirements.

Create or select an authoritative implementation plan before coding. Do not hide these under W2/W3 concurrency, which concerns loop-run leases rather than workflow fanout execution.

### W11 — Hermes adoption decision

`hermes-inspired-capabilities.md` is planning-only and awaits adoption-set confirmation. This is a genuine user/product decision, not an engineering blocker to unrelated work. Update its stale statement that workflow self-evolution is not started: Section 8 is substantially implemented but awaiting W0 acceptance.

### W12 — Distribution, live verification, and external operations

- `distributed-registry-container-node-roadmap.md`: foundation is implemented; release publication awaits external CI.
- Ship a Homebrew cask newer than 0.1.17 so distributed binaries include live cross-workflow dispatch. Until then, source builds are required for that behavior.
- Re-run the gated Anthropic live OCR translation test after account credits are available; default full tests do not cover it.
- Decide whether to delete obsolete local worktree/branch `fix-agent-node-modelfreeze-default` and merged remote branches `apple-gateway-review-hardening` and `integration-merge-all`. Branch deletion is an external/destructive operation and requires explicit authorization.
- In `riela-packages`, bound the `codex-design-and-implement-review-loop` review cycle with a step budget or repeated-finding circuit breaker. The current workflow has `maxLoopIterations: 3` but no explicit global `maxSteps`; verify current runtime semantics before choosing the fix.

### W13 — Active-plan status and archive reconciliation

This workstream owns bookkeeping only, not feature implementation. For each plan below, compare source/tests/current prose before moving it:

- likely completed but still active: `apple-calendar-addons`, `apple-notes-list-addon`, `apple-reminders-addons`, `installed-package-workflow-resolution`, `macos-workflow-viewer`, `node-input-filters`, `official-sdk-adapter-improvements`, `official-sdk-adapter-review-improvements`, `package-manager-ux-gap-closure`, `riela-note-ui-refinements`, `riela-seatbelt-sandbox`, `rielaapp-ux-onboarding-improvements`, `three-axis-issue-resolution-review`, `workflow-progress-observability`;
- status contradiction requiring evidence audit: `apple-gateway-admin-addons` (header says ready for implementation while all 51 boxes are checked), `workflow-instance-unification`, and `loop-engineering-first-line-tool` after W0;
- keep active for real external/prose work: distributed registry, Hermes, Riela Note, Swift parity, and all W1–W7 plans.

Update `impl-plans/README.md` from actual plan files. It currently contains stale descriptions, including plans described as planning or follow-up-pending despite their own completed status.

## 6. Complete active-plan traceability matrix

Every active plan has exactly one primary owner below. Cross-cutting dependencies are references, not duplicate ownership.

| Active plan | Primary workstream | Snapshot disposition |
| --- | --- | --- |
| `apple-calendar-addons` | W13 | completion/archive audit |
| `apple-clock-alarm-addons` | W4 | four QA checks remain |
| `apple-gateway-admin-addons` | W13 | status/evidence contradiction audit |
| `apple-mail-addons` | W4 | 48 checks remain despite internal DONE text |
| `apple-notes-crud-addons` | W4 | 27 hardening/verification checks remain |
| `apple-notes-list-addon` | W13 | completion/archive audit |
| `apple-reminders-addons` | W13 | completion/archive audit; retain explicit out-of-scope QA separately |
| `codex-unified-exec-stall-followup` | W1 | 12 checks remain |
| `distributed-registry-container-node-roadmap` | W12 | external CI/release remains |
| `hermes-inspired-capabilities` | W11 | adoption decision required |
| `installed-package-workflow-resolution` | W13 | completion/archive audit |
| `loop-engineering-application-gap-closure` | W2 | 62 checks remain |
| `loop-engineering-convergence-and-operations` | W3 | 30 checks remain |
| `loop-engineering-first-line-tool-progress` | W0 | preserve as W0 evidence log |
| `loop-engineering-first-line-tool` | W0 | round-eight acceptance outstanding |
| `macos-workflow-viewer` | W13 | completion/archive audit |
| `node-input-filters` | W13 | completion/archive audit |
| `official-sdk-adapter-improvements` | W13 | archive; live OCR gap belongs W12 |
| `official-sdk-adapter-review-improvements` | W13 | completion/archive audit |
| `package-checkout-content-digest-metadata` | W5 | one independent-review check remains |
| `package-manager-ux-gap-closure` | W13 | completion/archive audit |
| `riela-note-ui-refinements` | W13 | reconcile stale README/progress text, then archive |
| `riela-note` | W8 | prose-defined product work remains |
| `riela-seatbelt-sandbox` | W13 | completion/archive audit |
| `rielaapp-instance-execution-timeline` | W6 | not started; five plan checks remain |
| `rielaapp-ux-onboarding-improvements` | W13 | completion/archive audit |
| `shared-workflow-serving-library` | W7 | two checks remain |
| `swift-cli-runtime-parity-gap-closure` | W9 | deletion-gate evidence pending |
| `three-axis-issue-resolution-review` | W13 | completion/archive audit |
| `workflow-instance-unification` | W9 | package guidance/live verification disposition |
| `workflow-package-checkout-search` | W5 | 19 checks remain |
| `workflow-package-publish` | W5 | 22 checks remain |
| `workflow-package-registry-migration` | W5 | 26 checks remain |
| `workflow-package-registry` | W5 | four checks remain |
| `workflow-progress-observability` | W13 | archive; packaged guidance, if any, belongs W9/W12 |

Non-plan inventory sources are uniquely assigned as follows: runtime capability gaps → W10; Homebrew/live API/external CI/branch cleanup/package loop budget → W12; the 15 design-timeline checks → W6; `riela-packages` policy synchronization for W1 → W1.

## 7. Dependency-ordered execution

```text
W0 Section 8 recovery and acceptance
 ├─> W1 Codex tool-child recovery (overlapping process/runtime files)
 ├─> W13 archive/status reconciliation for loop-first-line
 └─> stable dirty-tree boundary

W2 loop application typed contracts
 └─> W3 loop baselines/concurrency/notifications

W5 registry foundation
 ├─> checkout/search safety
 ├─> publish transport
 └─> migration + riela-packages smoke/digests

W4 Apple hardening          independent after shared process-file ownership check
W6 RielaApp timeline        independent; requires UI verification
W7 shared serving          independent small closure
W8 Riela Note              independent after explicit sub-plan creation
W9 deletion/instance docs  review-gate dependent
W10 runtime fanout plan    independent design/planning
W11 Hermes                 user decision
W12 release/operations     external authorization or service state
W13 bookkeeping            run incrementally only after each owner's evidence closes
```

Safe parallelization requires disjoint files and separate Riela session/artifact roots. Do not run W0 and W1 concurrently. Do not run multiple W5 slices against the same registry checkout. W2 and W3 may overlap only after W2 publishes the shared diff/failure contracts and path ownership is explicit.

## 8. Riela session handoff

| Purpose | Session/evidence | Terminal state |
| --- | --- | --- |
| Section 8 round seven implementation | `section8-review-fix-round7-session-1` under `tmp/complete-all-design-impl/section8-fix7-artifacts/` | completed; green evidence recorded |
| Independent review after round seven | `section8-final-review-session-1` under `section8-review-artifacts-round7/` | completed; needs revision, four medium findings |
| Section 8 round eight | `section8-review-fix-round8-session-1` under `section8-fix8-artifacts/` | canceled/failed after partial implementation and failing focused tests |
| Tool-reap workflow with invalid dotted model id | first isolated `codex-tool-reap-recovery` sessions | failed; Claude reported retired Opus 4 |
| Tool-reap Opus 4.8 planning attempts | stores under `tmp/codex-tool-reap-recovery/` | intentionally canceled for scope updates, then stopped to focus on this handover |

The failed dotted-model attempts are configuration evidence, not implementation failures. A direct probe recorded actual usage of `claude-opus-4-8` under `tmp/codex-tool-reap-recovery/opus-alias-probe.json`.

## 9. Verification contract for future handoffs

For every implementation workstream:

1. Run the narrow deterministic tests that prove each requirement.
2. Run strict SwiftLint for every changed Swift file; split responsibility-based files above 1,000 lines.
3. Run the appropriate full repository suite on the exact final tree. Record gated/live skips separately.
4. Run `git diff --check` in each changed repository.
5. Use an independent adversarial review for security/process/filesystem/package boundaries; accept only zero high/medium findings.
6. Update design, plan, progress, and this handover from evidence, not intent.
7. Move a plan from `active/` only when its real implementation, verification, and follow-up disposition are complete.
8. For `riela-packages`, refresh every affected package digest and run `task check`.

## 10. MECE self-review

### 10.1 Method

The inventory used four independent source classes:

1. all 35 `impl-plans/active/*.md` files, their top-level/progress status text, and every Markdown checkbox;
2. all unchecked design checkboxes and `design-incomplete-work-inventory.md`;
3. current `git status --short`, stopped Riela process/session evidence, and focused test logs;
4. sibling `riela-packages` status, model references, duplicated Riela guidance, and package workflow budget evidence.

The audit counted 262 unchecked active-plan items. Workstream counts reconcile exactly:

```text
W1  12
W2  62
W3  30
W4  79
W5  72
W6   5
W7   2
-------
   262
```

### 10.2 Orphan scan

- Every active plan appears once in the traceability matrix.
- Every unchecked plan checkbox belongs to W1–W7.
- All 15 unchecked design boxes belong to W6 and are explicitly treated as subordinate traceability rather than duplicate tasks.
- Source `TODO`/`FIXME` scan found zero markers in `Sources/`.
- The two `TODO` strings found in `riela-packages` are prompt instructions saying not to create TODO artifacts; they are not unfinished tasks.
- Prose/status-only gaps from the living inventory are assigned to W8–W12.

**Result**: zero known orphan remaining tasks.

### 10.3 Overlap scan

- Apple process cleanup is owned by W4; Codex tool lifecycle recovery is owned by W1. They may share primitives but not primary task ownership.
- Workflow fanout/maxConcurrency is W10; loop concurrency leases are W3.
- Loop diff/stat types are W2; W3 consumes them rather than reimplementing them.
- Package implementation/migration is W5; generic release/live/external operations are W12; bookkeeping moves are W13.
- The timeline's design and plan checkboxes are one W6 scope.

**Result**: zero duplicate primary ownership assignments.

### 10.4 Consistency scan

Corrections made while preparing this handover:

- Treated `apple-mail-addons.md` as unfinished because it has 48 unchecked items even though its progress text says DONE.
- Treated `apple-gateway-admin-addons.md` as a status contradiction rather than assuming either the header or checked table is authoritative.
- Kept Section 8 open despite zero unchecked boxes because the latest round-eight tests fail and independent acceptance is absent.
- Reclassified old `workflow-package-registry-migration` dirty-registry blocker as historical because `riela-packages` is currently clean.
- Recorded the installed Claude CLI's exact Opus 4.8 identifier as `claude-opus-4-8`.
- Did not treat generic full-suite green claims as covering live/gated tests.

### 10.5 Dependency-cycle scan

No cycle exists in the primary dependency graph. W2 feeds W3; W0 precedes W1; W5's internal sequence ends in migration; W13 consumes completion evidence but does not feed implementation. W11 and W12 are decision/external leaves. Cross-cutting review and documentation updates are exit gates, not back-edges.

### 10.6 Residual uncertainties

- Zero-checkbox active plans can encode additional prose-only follow-ups beyond the ones found by status-keyword and inventory scans. W13 must read each plan completely before moving it.
- The exact intended adoption set for Hermes requires user input.
- External CI, API credits, release credentials, and branch deletion authorization are outside repository control.
- Round-eight Section 8 cleanup semantics require implementation-level diagnosis; this document records the observed failure without prescribing an unsafe deletion rule.
- W1's same-attempt continuation may be impossible with the current upstream Codex host protocol. The design requires fail-closed retry/refusal when terminal acknowledgement cannot be proven.

**MECE conclusion**: the handover is collectively exhaustive for the audited plan/design/status/git/session/package sources and mutually exclusive at primary workstream ownership. Cross-cutting dependencies are explicitly referenced, not double-counted.

## 11. Program-wide definition of done

The remaining-work program is complete only when:

- W0–W10 implementation/review obligations are either completed or explicitly superseded by an accepted design decision;
- W11 has a recorded adoption decision;
- W12 external verification/release items have completed evidence or an explicitly accepted external deferral with owner and retry condition;
- all affected `riela-packages` payloads are synchronized, digest-refreshed, and validated;
- every active plan has truthful status and is either still active for a named remaining task or moved to `completed/`;
- the active-plan unchecked count is zero unless an item is explicitly accepted as deferred with owner and trigger;
- full deterministic tests, scoped lint, repository diff checks, required UI verification, and independent high/medium-zero reviews are recorded;
- no Riela workflow, agent child, monitor, socket, or test fixture is left running or orphaned;
- this handover's orphan and duplicate-primary scans remain at zero on a fresh inventory.
