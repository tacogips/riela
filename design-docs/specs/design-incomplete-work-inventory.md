# Riela Incomplete Work Inventory

Status: living inventory, verified against code and plans

Created: 2026-07-08

Survey method: full-suite test run on `main` (`b917926`: 1596 tests, 0
failures, 4 env-gated skips), `WorkflowRuntimeCapabilityGap` source review,
`grep TODO|FIXME` over `Sources/` (zero hits), and a status/task audit of
every plan under `impl-plans/active/`.

## Purpose

A single place that records where Riela is knowingly incomplete, with
file-level evidence, so follow-up sessions pick work from here instead of
rediscovering it. Each entry names its authoritative source; update or remove
entries when the source changes.

## 1. Workflow Runtime Capability Gaps (validator-surfaced)

Authoritative source: `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
(`unsupportedFeatures(in:maxConcurrency:supportsCrossWorkflowDispatch:)`).

- **Fanout transitions are not supported by the live runner.**
  `workflow.steps.<id>.transitions.fanout` produces an error-severity gap;
  live runs cannot execute fanout. Mock scenarios are the only way to
  exercise fanout-shaped workflows today.
- **`run.maxConcurrency` is reserved, not implemented.** Declared for future
  fanout execution; setting it is diagnosed as unsupported.
- **Cross-workflow transitions without `resumeStepId` are unsupported.**
  Only the dispatch form (`toWorkflowId` + `resumeStepId`) runs live, and
  only when a callee resolver is wired (CLI wires
  `FileSystemWorkflowCalleeResolver`; library callers must wire their own or
  the run degrades to a warning-level gap).
- **Resume-step transitions without `toWorkflowId` are unsupported.**

Live cross-workflow dispatch itself landed in `c534100` and is not a gap
anymore; the Homebrew cask binary 0.1.17 predates it and silently misroutes
dispatch to the resume step (see section 6).

## 2. Roadmap Phases Not Started

- **Loop engineering application (LA1b and later).**
  `impl-plans/active/loop-engineering-application-gap-closure.md` — status
  "LA1a implemented - LA1b and later roadmap work not started"; 27
  NOT_STARTED tasks covering `LoopStartCommand` / `LoopPromoteCommand`,
  `LoopCostEvidence` + usage accumulation in
  `DeterministicWorkflowRunner+Cost`, budget enforcement
  (`DeterministicWorkflowRunner+Budget`), loop cost columns, evidence
  diff/stats (`LoopEvidenceDiff`, `LoopWorkflowStats`), GraphQL loop
  contract extensions, `gates --check` CI mode, findings export, and an
  `examples/loop-ci-gate-check/` example.
- **Workflow self-evolution versioning.**
  `impl-plans/active/loop-engineering-first-line-tool.md` section
  "8. Workflow Self-Evolution Versioning" is the only remaining NOT_STARTED
  section of that plan (all other sections DONE).
- **RielaApp instance execution timeline.**
  `impl-plans/active/rielaapp-instance-execution-timeline.md` — status
  "Planning", 12 NOT_STARTED tasks; no implementation yet.

## 3. Named Follow-Up Work in Otherwise-Landed Features

- **riela-note libsql driver parity.** `impl-plans/active/riela-note.md`
  ("Partially implemented"): execution through libsql is not implemented;
  real libsql embedded replica/sync behavior and full suite parity against
  that driver remain follow-up work. The main `RielaNote` target stays free
  of the extra dependency until then.
- **Workflow package registry.**
  `impl-plans/active/workflow-package-registry.md`: invalid-package refresh
  diagnostics, full sqlite parity, and a separated publish metadata helper
  remain explicit follow-up work.
- **Package checkout/search.**
  `impl-plans/active/workflow-package-checkout-search.md`: broader table
  rendering polish and additional ambiguity/error-path tests remain explicit
  follow-up work.
- **Distributed registry / container node roadmap.**
  `impl-plans/active/distributed-registry-container-node-roadmap.md`:
  foundation implemented; release publication pending external CI.
- **Swift CLI runtime parity gap closure.**
  `impl-plans/active/swift-cli-runtime-parity-gap-closure.md`: deletion gate
  blocked pending accepted Step 7 / adversarial review metadata; legacy
  runtime removal cannot proceed until that acceptance is recorded.

## 4. Stale Plan Status Headers (bookkeeping, not code gaps)

These plans carry an "In Progress"/"Ready" top-level status while their task
tables read Completed; they need status reconciliation or a move to
`impl-plans/completed/`:

- `impl-plans/active/package-checkout-content-digest-metadata.md`
- `impl-plans/active/workflow-package-publish.md`
- `impl-plans/active/workflow-package-registry-migration.md`
- `impl-plans/active/shared-workflow-serving-library.md`

## 5. Verification Gaps

- **Anthropic live OCR translation path is unverified end-to-end.**
  `Tests/RielaAdaptersTests/OfficialSDKLiveOCRTranslationTests.swift` (gated
  behind `RIELA_LIVE_OCR_TRANSLATION_TESTS=1`): on 2026-07-08 the OpenAI and
  Gemini live tests passed against real APIs; the Anthropic test skipped
  with HTTP 400 "credit balance is too low" — an account/billing condition,
  not a code defect, but the Anthropic image path has no green live run on
  record. Re-run after topping up credits.
- Live suites (OCR translation and any similar `XCTSkip`-gated tests) never
  run in default CI; treat "full suite green" as excluding them.

## 6. Distribution / Packaging Gaps

- **Homebrew cask 0.1.17 binary is behind main.** It predates live
  cross-workflow dispatch (`c534100`) and silently routes dispatch to the
  resume step without running the callee, which breaks packages such as
  `fable-and-improve`. Until a new cask release ships, source builds
  (`swift build -c release`) are required for cross-workflow features.
- **`codex-design-and-implement-review-loop` package has no step budget.**
  The packaged child workflow ships `maxSteps: null`; its step6↔step7 review
  loop has no backstop and can iterate indefinitely when a review finding is
  unsatisfiable (observed 2026-07-08 with shared-worktree churn). Fix
  belongs in the `riela-packages` registry: give the loop a maxSteps default
  or a repeated-finding circuit breaker.

## 7. Repository Housekeeping

- Branch `fix-agent-node-modelfreeze-default` (and its worktree under
  `worktrees/riela-agent-node-modelfreeze-default`) is obsolete: the
  identical fix (`decodeIfPresent ?? false` plus the renamed test) is
  already on main in `Sources/RielaCore/WorkflowModel.swift` /
  `Tests/RielaCoreTests/WorkflowModelTests.swift`. Safe to delete.
- Remote branches `origin/apple-gateway-review-hardening` and
  `origin/integration-merge-all` are merged (PR #35 / PR #36) and can be
  deleted.

## Explicitly Not Gaps

- `Sources/` contains zero TODO/FIXME markers.
- All files added by the 2026-07-08 integration (PR #36) are wired:
  `OfficialSDKImageInputs` feeds the OpenAI, Anthropic, and Gemini adapters
  (`Sources/RielaAdapters/OfficialSDKAdapters.swift`), and
  `RielaNoteLibraryViewModel+Translation` is referenced across `RielaNoteUI`.
- The example parity failure (apple-* examples missing from
  `RielaExampleParityTests.rielaExampleWorkflowNames()`) was repaired in
  PR #36.
