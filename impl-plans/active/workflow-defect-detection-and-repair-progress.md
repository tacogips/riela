# Workflow defect detection and verified repair: implementation progress

Mode: `issue-resolution`. Issue: `tacogips/riela` Draft PR #109,
`comm-000002`. Step 6 execution:
`nested-v1-14b59b4ca29e18320877eadad21cfada56111961ce175485874aac2eaa47140d`.
Step 5 accepted the design and plan at checkpoint `6e2caa334fa77404d95377cdfc777384c7cd8db8`;
the dispatch record has no review findings. `codexAgentReferences=[]`.
This progress file records implementation work only. Formal independent review,
shared documentation/index updates, exact-file commit and non-force push are
downstream workflow steps.

## Attempt 1

Evidence root:
`tmp/workflow-defect-repair-20260926-comm000006-a8e1beb/step6-attempt-1/`.
The pre-edit hashes and per-edit intentions are retained there. No Git
stage/commit/push, worktree or sibling-plan edit was performed.

| Task | Current implementation-phase status | Evidence |
| --- | --- | --- |
| T1 | Complete: shared parsed AST, source spans, complete-input syntax errors, typed lookup, eager strict evaluation and legacy wrapper parity. | `Sources/RielaCore/WorkflowConditionAnalysis.swift`, `Sources/RielaCore/WorkflowBranchEvaluation.swift`, focused tests; V1 current-source rerun 6 passed, 0 failed, exit 0. |
| T2 | Pending: Boolean producer guarantee, route rejection before finalization/reservation/publication and entry-path tests. | V2 not run. |
| T3 | Pending: bounded assignment/SCC/guard analysis. | V3 not run. |
| T4 | Pending: persisted completed-cycle comparison and separate D9 activity/responsiveness. | V4 and L-V1–L-V5 not run. |
| T5 | Pending: digest-bound proposals and staged verification. | V5 not run. |
| T6 | Pending: incident fixture, resource registration, A1–A16/L1–L8 integration, docs and combined behavioral gates. | V6–V9 not run. |

## Current-source verification

- V1: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowBranchEvaluationTests|WorkflowConditionAnalysisTests'"`; log `step6-attempt-1/V1-rerun.log`; exit 0; 6 tests, 6 passed, 0 failures. Initial passing run is preserved separately as `V1.log` because the test source was subsequently simplified.
- Changed-file strict SwiftLint: NUL manifest `step6-attempt-1/changed-swift.nul`; `xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"`; log `step6-attempt-1/T1-lint-rerun.log`; exit 0. The prior passing lint run remains `T1-lint.log`.

The tree remains under implementation. T2–T6 and their source-matched required
behavioral gates must finish before Step 6 can claim implementation completeness.
The accepted design digest is
`47f99f9f2761332307afc54eecec1dbc42d9bfa26dd9c7c5308eacdd5c5e0437`.

## Attempt 2: T2 stopped at write ownership boundary

Evidence root:
`tmp/workflow-defect-repair-20260926-comm000006-a8e1beb/step6-attempt-2/`.
The dependency gate
`arch -arm64 /bin/zsh -lc "swift test --filter 'AgentNodeOutputContractValidationTests|WorkflowOutputContractPreflightTests|RuntimeOutputValidationTests'"`
passed 16 tests, 0 failures, exit 0; complete log `T2-dependency.log`.

Partial T2 work in `Sources/RielaCore/WorkflowRouteContract.swift` and
`Sources/RielaCore/RuntimePublication.swift` parses every label, rejects
missing/wrong-type/conflicting controls before candidate-path finalization,
and preserves safe rejected-staging cleanup. Focused unit/publication tests
were added under `Tests/RielaCoreTests/`. This work is **not accepted or
complete**: the V2 command
`arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'"`
exited 1 after 26 tests, 25 passed and 1 failed. Complete log:
`V2-runtime.log`. The failing existing test
`RuntimePublicationTests.testPublicationRecordsExplicitLoopRoutingReconciliationDiagnostic`
received `route.missingControl transitions[1].label ... accepted`.

`Sources/RielaCore/LoopCompletionReviewRouting.swift` currently derives only
`needs_replan` and `needs_work`; the existing route also references
`accepted`. Strict T2 verification requires its effective reconciled controls
to cover that route without inventing a false default. That file is absent
from this plan's approved `writePaths` and dispatch tracked paths. The serial
owner must approve that exact path or assign its maintainer a reviewed repair;
then rerun V2 on the combined source, including the existing reconciliation
test and new route negatives. Do not treat the 25 passing tests as a green V2.

Selected-file strict SwiftLint for all eight changed Swift files exited 0;
manifest `changed-swift.nul`, complete log `strict-lint.log`. T2 producer
schema guarantee proof, full publication entry-path coverage and two-attempt
exhaustion remain unfinished. T3–T6 and their gates remain pending. No other
source path was edited to bypass the failed assertion.

## Attempt 3: authorized T2 reconciliation continuation

Evidence root: `tmp/workflow-defect-implementation/T2-continuation/`.
The Attempt 2 ownership sentence above is historical and false. The committed
dispatch `plans[0].writePaths` and all four persisted child `inputSnapshot`
writePaths arrays include both `Sources/RielaCore/LoopCompletionReviewRouting.swift`
and `Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift` (115 paths per array).
There is no T2 ownership blocker. The Step 5 accepted design and plan remain
aligned; `dependsOn=[]` and no review finding was supplied.

The bounded reconciliation amendment now derives `accepted` from the existing
needs-replan/needs-work decision precedence and checks the full three-control
map. Exact-map assertions were updated in the publication, loop guard, loop
policy and adapter tests. Added publication cases cover missing or contradictory
accepted, all three decisions, goal-false precedence, idempotence and non-review
pass-through. A synthetic loop-guard output now explicitly supplies
`needs_replan=false` for a route that reads that control under negation; strict
all-referenced-control rejection remains enabled. Per-edit intentions and pre/post
hashes are saved in this attempt's evidence root.

Current-source gates, with complete logs and terminal status lines:

- V2: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'"`; `V2-final.log`; exit 0, 27 tests passed, zero failures.
- V2b: `arch -arm64 /bin/zsh -lc "swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'"`; `V2b-final.log`; exit 0, 38 tests passed, zero failures.
- Exact changed-Swift lint: `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/T2-continuation/all-changed-swift.nul`; `all-changed-lint.log`; exit 0. `verified-swift.sha256` records the tested Swift bytes.
- `git diff --check` passed before the final progress update; rerun it for this final log.

The first local V2 wrapper used zsh's read-only `status` variable after tests had
passed; its log lacks a reliable terminal status and is superseded by the
attempt-specific V2 reruns. The first V2b rerun failed 1/38 on the missing
synthetic `needs_replan` value; its `V2b.log` is preserved. An initial strict
lint found a test-only large tuple; its failed log is preserved and the current
changed-file lint is green. The older Attempt 2 V2 failure remains failed.

T2 remains incomplete: producer schema/guarantee analysis and validation wiring,
all publication-entry paths, and two-total-attempt exhaustion still require
implementation and source-matched behavioral evidence. T3–T6, V3–V9, activity
L-V1–L-V5 and formal review remain pending. No shared index, commit or push was
performed in Step 6.

## Attempt 4: producer proof and bounded correction evidence

Evidence root: `tmp/workflow-defect-implementation/T2-continuation-2/`.
This is the second productive continuation of the same Step 6 plan. The earlier
T1 and T2 reconciliation changes and all failed/passing historical logs remain
preserved. Per-edit intentions `intent-001.txt` through `intent-010.txt`, the
pre-edit hashes and `verified-swift.sha256` record this attempt's source identity.

`WorkflowRouteContract.swift` now has a bounded 4,096-visit proof for a
required top-level Boolean payload control. It recognizes Boolean type, const,
all-Boolean enum, whole-object const/enum, every `anyOf`/`oneOf` alternative,
and a demonstrably consistent split `allOf` required/property case. Optional,
nullable, untyped, mixed or unsupported alternatives report
`analysis_incomplete` at a schema pointer. `WorkflowValidation.swift` uses the
shared parsed condition to report malformed labels and incomplete proof for
every referenced identifier, including short-circuited paths. Unverified
add-on provenance is incomplete rather than attributed to an upstream agent.
Runtime all-control rejection is unchanged.

`WorkflowRouteContractTests.swift` and
`AgentNodeOutputContractValidationTests.swift` cover proof and diagnostic cases.
`RuntimePublicationTests.swift` now checks that a missing fanout route control
rejects before dispatch or accepted-output persistence.
`RuntimeOutputValidationTests.swift` verifies a missing runtime route control
exhausts exactly two total agent validation attempts. These tests complement the
existing ordinary publication and successful correction cases.

Current-source foreground gates:

- V2: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'"`; `V2-final.log`; exit 0, 31 passed, zero failures.
- V2b: `arch -arm64 /bin/zsh -lc "swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'"`; `V2b-final.log`; exit 0, 38 passed, zero failures.
- Producer/preflight: `arch -arm64 /bin/zsh -lc "swift test --filter 'AgentNodeOutputContractValidationTests|WorkflowOutputContractPreflightTests|RuntimeOutputValidationTests'"`; `T2-dependency-final.log`; exit 0, 18 passed, zero failures.
- Exact changed-file strict lint: `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/T2-continuation-2/changed-swift.nul`; `strict-lint-final-attempt-2.log`; exit 0.

T2 remains incomplete against its original acceptance: the stable typed
`WorkflowDefectDiagnostic` model, raw validation integration, guaranteed
when-only provenance, and ordinary/inline/fanout/callee/recovery publication
matrix need further work and tests. T3–T6 and their V3–V9/L-V1–L-V5 gates are
unimplemented. The focused passing suites are current behavioral evidence for
the changed hunks, not an independent review decision or full plan acceptance.

## Attempt 5: terminal Step 6 handoff after bounded continuations

Evidence root: `tmp/workflow-defect-implementation/T2-terminal/`. The workflow
progress gate returned `implementation_continue=true` after the two productive
continuations above. This attempt fixes the material self-check omission in T2
and records an accurate terminal implementation handoff; it does not claim plan
completion or reset the preserved tree.

`WorkflowValidation.swift` now reports `analysis_incomplete` for each referenced
route control when an agent node has no output schema, alongside the existing
missing-schema error. `WorkflowRawValidation.swift` now uses the same
`ParsedWorkflowCondition` syntax check for authored transition labels and
reports a span-addressed error before typed materialization. Focused tests in
`AgentNodeOutputContractValidationTests.swift` and
`WorkflowRouteContractTests.swift` cover these paths. The read-only self-check
found no separate material publication-order regression in the common candidate
path. Per-edit intent and source hashes are retained in this attempt's root.

Final-source foreground evidence:

- V2: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'"`; `V2.log`; exit 0, 32 passed, zero failures.
- V2b: `arch -arm64 /bin/zsh -lc "swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'"`; `V2b.log`; exit 0, 38 passed, zero failures.
- Raw/agent validation: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowModelTests|AgentNodeOutputContractValidationTests'"`; `raw-model.log`; exit 0, 35 passed, zero failures.
- Focused new paths: `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|AgentNodeOutputContractValidationTests'"`; `T2-validation-attempt-3.log`; exit 0, 14 passed, zero failures.
- Exact changed-Swift strict lint: `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/T2-terminal/all-changed-swift.nul`; `all-changed-lint.log`; exit 0.

Two compilation failures from this attempt remain in `T2-validation.log` and
`T2-validation-attempt-2.log`; the shadowed diagnostic helper and malformed
test string literal were corrected before the passing rerun. The historical
Attempt 2 V2 failure remains immutable. No source or test was removed to obtain
the green focused suites.

Implementation remains incomplete. T2 still requires the typed
`WorkflowDefectDiagnostic` and source-bound digest, explicit when-only/add-on
guarantee provenance, full raw/typed diagnostic integration, and all ordinary,
inline, fanout-join, callee-resume and recovered pending-publication rejection
paths with zero downstream effects. T3 graph/cycle analysis, T4 durable semantic
progress and D9 activity, T5 reviewed repair, and T6 incident fixture/docs are
not implemented. V3–V9 and L-V1–L-V5 cannot be represented as passing gates.
The two productive continuation allowance is exhausted. A new authorized
implementation run can resume from this dirty tree and these evidence roots;
formal review, shared docs/index, exact-file commit and non-force push remain
downstream only after implementation passes.

## 2026-09-26 operator pause: T2 review repair in progress

The later native user-scope workflow split the accepted plan into serial
T2-remaining, T3, T4, T5 and T6 tasks. Its T2 child session is
`nested-v1-21f8a00ec3e23977bd9d59ad5c68924ffd82088dddb9cac773651c202e24a03b`
under `tmp/workflow-defect-t2-provenance-scope/sessions`. The operator stopped
the live CLI process at the user's request to isolate the P1 release work.
This is a recoverable WIP checkpoint, **not** an accepted implementation or
workflow completion.

Before adversarial review, the T2 test-integrity gate accepted corrected
source-matched evidence: V2 45/45, V2b 48/48 (including the actual loop-policy
suite 10/10), V2c 19/19, V2d 35/35, V2e 40/40, CLI 2/2, changed-file strict
SwiftLint and `git diff --check`. The first V2b filter had omitted the
loop-policy suite; its 38/38 result is historical, not the accepted evidence.

The Sol adversarial review then rejected T2 on a material provenance gap:
static route proof accepts an add-on package digest while runtime registration
selection matches name/version without binding that digest. The workflow routed
back to Step 6 to add an exact digest match and a same-name/version,
different-digest regression. That repair was interrupted and may be partially
edited. Recheck the source diff and rerun focused tests, strict lint and review
before claiming T2 accepted. T3–T6 have not started; no release should contain
this branch's T2 changes until the remaining work and gates finish.
