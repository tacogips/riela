# P1 lifecycle implementation progress

Issue: `comm-000002: Complete the Work Runtime P1 dependency DAG`
Plan: `p1-lifecycle` / `impl-plans/active/work-runtime-p1-guard-director.md`
Step: `step6-implement` / `nested-v1-836d58fe1e8d3f93103396379c05e7965797e859051d4dec35d352e7865cdaf2`

## 2026-09-23 implementation

- Confirmed authoritative predecessor admission: `p1-reservation` appears in runtime `acceptedPlanIds`.
- Preserved the retained typed guard, deterministic director, completion evaluator, causal/versioned decision applier, replay-outcome persistence, and cancellation-acknowledgement paths.
- Routed coordinator-created rerun/recover decisions through a stable `PendingAttemptReservation` in the same `WorkStore.applyDecision` transaction. The public applier validates task, decision, predecessor attempt, and entry identity before persisting the request.
- Added store coverage that a malformed request rolls back the decision and a matching request persists with its decision.

## Verification

- `swift build --scratch-path tmp/work-runtime-p1/build/p1-lifecycle`: exit 1; blocked before compilation because the sandbox denies the default Clang module cache. Complete final log: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-836d58fe1e8d/retry-3/build.log`.
- Exact focused ARM64 test filter: exit 1; blocked before discovery by the same denied default Clang module cache. Complete final log: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-836d58fe1e8d/retry-3/focused-tests.log`.
- Accommodated focused test command with workspace module caches: exit 1; blocked before test discovery because dependency fetch for `agent-gateway` cannot resolve `github.com`. Complete log: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-836d58fe1e8d/focused-tests-accommodated.log`.
- Targeted `swiftc -parse`, strict touched-file SwiftLint, repository SwiftLint (baseline warnings only), and `git diff --check` each exited 0. Complete final logs: `retry-3/swift-parse.log`, `retry-3/touched-swiftlint.log`, `retry-3/repository-swiftlint.log`, and `retry-3/diff-check.log` under the same evidence directory.

No high or mid author-self-check finding is unresolved in the changed hunks. Stable behavioral verification remains blocked by the unavailable dependency fetch and must be rerun after dependency availability is restored.

## comm-000031 revision

- Store acceptance now validates causal evidence ownership and reconstructs completion from persisted attempt/finding state.
- Live cancel, reject, stop, rerun, and recover retain the attempt fence until a canonical cancelled snapshot acknowledges the decision; acknowledgement maps terminal/replacement task state only afterward.
- Added missing/foreign causal evidence coverage and budget coverage with a matching pending reservation.
- Final syntax parse, strict touched lint, and diff check passed; accommodated focused test remains blocked by unavailable `agent-gateway` DNS. Logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-836d58fe1e8d/revision-31/`.

## Step 6 rerun `nested-v1-f6ba2002209e43a22a82777d485d34ee489d401b78942dfc2e3f19e0d41325f3`

- Confirmed authoritative dependency admission: runtime `acceptedPlanIds` includes `p1-reservation`.
- Corrected store-local completion-ledger decoding, preserved durable original replay applications, and retained requested rerun/recover entry while terminal cancellation acknowledgement is pending.
- Guard token accounting now deduplicates replayed step-execution records; attempt capacity remains the reservation admission fence, so the final admitted attempt can complete. Director guard and gate candidates are stable-sorted and gate recovery requires remaining capacity.
- Fallback build passed after the mandatory isolated-scratch build was blocked by the sandbox's default Clang module cache. The current-tree focused fallback passed 40 selected tests with zero failures. Logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-f6ba2002209e/attempt-1/build-fallback-2.log` and `focused-tests-final.log`.
- Strict touched SwiftLint and `git diff --check` passed: `touched-swiftlint.log`, `diff-check.log`. Final source hashes: `final-source.sha256`.
- Implementation remains pending independent integrity/adversarial review; this log does not mark P1-2/P1-3 or shared indexes complete.

## Step 6 corrective rerun `nested-v1-f6ba2002209e43a22a82777d485d34ee489d401b78942dfc2e3f19e0d41325f3`

- Addressed author-review findings within P1-2/P1-3: `warn` durably records an immutable guard batch without forcing a decision; terminal attempts apply stop/rerun/recover directly rather than waiting for impossible cancellation acknowledgement; replay now rejects a changed decision-evidence identity.

## Step 6 corrective check `nested-v1-78fe3c76514a75903fa793b38971c3e7ad648bf8d7f5b14f5c258bd26112e726`

- Confirmed authoritative dependency admission: runtime `acceptedPlanIds` contains `p1-reservation`.
- Fixed live-action decision validation so a decision cannot use an attempt owned by another task before the cancellation shortcut; the regression proves neither task, the foreign attempt, nor the decision ledger changes on rejection.
- Made same-gate convergence selection use an explicit violation-kind rank before gate and evidence identity; the regression proves stable selection with reversed caller order and inverted evidence IDs.
- Before this corrective edit, the current shared tree passed the plan-focused suites (55 tests) and reservation/cancellation suite (23 tests): `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-78fe3c76514a/plan-focused-tests.log` and `cancellation-tests.log`.
- The corrective focused compilation is blocked by concurrent capability work in `Sources/RielaCLI/DoctorCommand.swift:282`: `DoctorCommandResult` has no `generatedAt`; complete log `corrective-tests.log`. It is outside this plan's write paths, so corrective behavioral rerun awaits a stable shared tree.
- Strict touched-file SwiftLint and `git diff --check` passed before the corrective edit: `touched-swiftlint.log`, `diff-check.log`; repeat them with corrective tests at the serial verification join. Source snapshots and exact hunk intent are retained in `pre-edit/` and `post-edit/`.
- The final cache-isolated focused suite passed **58 selected tests with 0 failures**, including the new cross-task live-attempt, late decision-evidence rollback, and convergence-rank regressions. The reservation/cancellation suite passed **23 selected tests with 0 failures**. Final strict touched-file SwiftLint and `git diff --check` both exited 0. Complete command evidence: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-78fe3c76514a/verification-evidence.json`.
- Author self-check: no unresolved high or mid finding remains in the assigned P1-2/P1-3 hunks. Independent integrity/adversarial review remains required; this entry does not accept P1-2/P1-3 or update shared indexes.
- Fallback build passed after the required isolated-scratch build was blocked by the sandbox default Clang module cache. The fallback focused suite passed 41 selected tests with zero failures.
- Strict touched SwiftLint and `git diff --check` passed; repository SwiftLint exited 0 with unrelated baseline warnings. Complete logs and source hashes are in `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/attempt-1/`.
- Independent integrity and adversarial review remain required; this progress log does not accept P1-2/P1-3 or update shared indexes.

## Step 6 implementation `nested-v1-089bfaa190cd5f108e65d61436b63fc47f28c7b039bdfe626534cf1a52efcd85`

- Confirmed runtime-owned predecessor admission: `p1-reservation` is in `acceptedPlanIds`.
- Reconciled three bounded P1-2/P1-3 defects: guard replay retains the first persisted observation despite a later invocation timestamp; `onViolation: .fail` always emits a stop rather than an inactivity rerun; accept rejects a non-latest task attempt so an old success cannot mask a newer failure.
- Added targeted dispatcher/store regressions for timestamp-stable guard replay, fail-policy inactivity, and old-attempt acceptance. No schema, CLI, capability, or reservation files were edited.
- Required isolated scratch build exited 1 before compilation because its default Clang module cache is denied by the sandbox. The current-tree cache-isolated fallback build exited 0, and the focused suite exited 0 with 43 selected tests and zero failures. Strict touched-file SwiftLint, repository SwiftLint (unrelated baseline warnings only), and `git diff --check` each exited 0. Complete logs, edit intent, and final hashes: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-implement-089bfaa/`.
- Author self-check found no unresolved high or mid issue in this plan's hunks. Independent integrity/adversarial review remains required; this entry does not accept P1-2/P1-3 or update shared indexes.

## Lifecycle blocker coverage repair — 2026-09-23

- Added focused behavioral coverage that a simultaneous guard batch persists all
  observed violations before the selected policy action, that causal evidence
  from a different attempt of the same task is rejected, and that an agent
  decision replays its recorded result while a changed agent producer conflicts.
- The cancellation path now explicitly proves that acknowledgement without the
  durable matching cancelled runtime snapshot rejects and retains the running
  task fence. Existing warning/inactivity fixtures now supply a heartbeat-capable
  backend and assert the current typed budget summary.
- Foreground cache-isolated ARM64 build exited 0; complete evidence is
  `tmp/lifecycle-independent-review/build.log`.
- The independent cache-isolated ARM64 lifecycle filter exited 0 with **47
  selected tests, 0 failures**; complete evidence is
  `tmp/lifecycle-independent-review/focused-tests.log`.
- Strict touched-file SwiftLint exited 0 with zero violations and `git diff
  --check` exited 0; complete evidence is
  `tmp/lifecycle-independent-review/touched-swiftlint.log` and
  `tmp/lifecycle-independent-review/diff-check.log`. The combined build
  compiled `WorkflowBackendPolicyTests`, so the reported policy-test
  compatibility issue is not present in this tree.

This entry records verification only; it does not accept P1-2/P1-3 or alter
shared indexes.

## Step 6 implementation `nested-v1-46bfaf8a40323c986e7f0f12f01346348f5ccf54e94aba91ff06753219772dea`

- Confirmed runtime-owned predecessor admission: `p1-reservation` is in `acceptedPlanIds`.
- Corrected the P1-3a warning-policy bypass: `.warn` now persists nonbudget observations without an action, but budget evidence continues to the deterministic budget stop. Added the token-budget equality-boundary regression.
- Required isolated-scratch build and focused test commands each exited 1 before compilation because the sandbox denies `/Users/taco/.cache/clang/ModuleCache`. The cache-isolated fallback build exited 0. The fallback focused test rebuild is blocked by an unrelated concurrent capability test compile error: `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift:167` omits required `AgentProviderConfiguration.baseUrl`.
- Strict touched-file SwiftLint, repository SwiftLint, and `git diff --check` exited 0. Complete logs, per-edit intent, and hashes: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-lifecycle/step6-implement-46bfaf8a/`.
- No unresolved lifecycle high/mid source finding remains after the warning-budget correction. Behavioral verification of the new regression awaits resolution of the unrelated shared-tree compile failure; independent integrity/adversarial review remains required.

## Step 6 verification rerun `nested-v1-127d4f3792ba6106c7d1b9dd0eba7b72a4e90a95f7b756bc7a25a13bc540a1fa`

- Confirmed runtime-owned predecessor admission: `p1-reservation` remains in `acceptedPlanIds`.
- Exact isolated-scratch build and focused filter each exited 1 before compilation/discovery because the sandbox denies the default Clang module cache. Cache-isolated fallback build exited 0; its focused lifecycle filter exited 0 with 47 selected tests and zero failures. Strict touched-file lint, repository lint (unrelated baseline warnings only), and `git diff --check` exited 0. Complete logs, current source hashes, and structured evidence: `tmp/work-runtime-p1/p1-lifecycle/step6-127d4f/`.
- Self-check identified two serial-reconciliation requirements outside this plan's permitted write map: immutable guard-batch persistence needs a compare-and-insert transactional primitive rather than `WorkStore.saveEvidence`'s conflict-upsert in `Sources/RielaWork/WorkStore.swift`; and failure/gate recovery needs persisted causal evidence identifiers before the policy director can emit rerun/recover decisions. No speculative cross-plan edit was made. P1-2/P1-3 remain unaccepted pending those repairs and independent review.

## Serial lifecycle ledger repair — 2026-09-23

- Performed the required serial repair in `WorkStore.swift`, outside the original
  lifecycle worker write map: immutable guard observations now use a dedicated
  `BEGIN IMMEDIATE` compare-and-insert batch. Equivalent replay returns the
  first canonical observation; a conflicting identifier rolls back the entire
  batch so concurrent writers cannot overwrite or partially persist it.
- Automatic policy rerun/recover now requires persisted causal evidence scoped
  to the same task and attempt. The director carries matching failure/gate
  evidence identifiers and fails closed to human wait when they are absent;
  the store independently enforces the contract.
- Accept completion reconstruction now propagates missing or corrupt runtime
  snapshot errors except for an explicit snapshot `notFound`, which supplies no
  acceptance evidence and remains valid when the completion contract does not
  require it. Corrupt, invalid, schema, and read errors still propagate; a
  failed reconstruction leaves task, attempt, decisions, and decision evidence
  unchanged in the enclosing transaction.
- The cache-isolated ARM64 lifecycle, reservation, cancellation, and store suite
  passed **95 selected tests with 0 failures**. Strict SwiftLint on all seven
  serial-repair Swift files and `git diff --check` also passed. Evidence:
  `tmp/work-runtime-p1/p1-lifecycle/serial-repair/combined-tests.log`,
  `swiftlint.log`, and `diff-check.log`.

No material lifecycle finding remains from this serial repair. This progress
entry records implementation evidence only and does not update shared indexes.

## Step 6 implementation `nested-v1-e397661a8401634706a4a1641bb295d8b468043c06c59e2fc7f4b8cbf9b4c16e`

- Confirmed runtime-owned predecessor admission: `p1-reservation` is in
  `acceptedPlanIds`. Re-read the accepted guard/director plan and retained
  lifecycle implementation before repair.
- Addressed two high self-review findings in the assigned P1-2/P1-3 seam:
  required gate acceptance now fails closed when any required gate has no valid
  current acceptance payload; stable decision replay compares immutable intent
  fields and returns the original durable application when only `createdAt`
  differs. The original persisted decision timestamp remains unchanged.
- Added regressions for a missing required gate payload and a replay with a
  different retry timestamp. Intent records and pre/post hashes are under
  `tmp/work-runtime-p1/p1-lifecycle/intents/step6-e397661a-001/` and
  `step6-e397661a-002/`; structured command evidence is
  `tmp/work-runtime-p1/p1-lifecycle/step6-e397661a/verification-evidence.json`.
- Required isolated-scratch build and test commands exited 1 before compilation
  or discovery because the sandbox denies the default Clang module cache.
  Cache-isolated fallback build exited 0 and the focused lifecycle suites
  exited 0 with **55 selected tests and 0 failures**. Strict touched-file lint,
  repository lint (unrelated baseline warnings only), and `git diff --check`
  exited 0.

This entry does not accept P1-2/P1-3 or update shared indexes; independent
test-integrity/adversarial and combined-tree review remain required.

## Step 6 verification refresh `nested-v1-4a36c1b4e15ada7042bdb0ba28cf3eea68237194acf1746bbc6815b493d55cec`

- Confirmed runtime-owned dependency admission: `p1-reservation` is present in
  `acceptedPlanIds` for `p1-lifecycle`.
- Re-read the accepted P1-2/P1-3 plan, retained lifecycle source/test hunks,
  and shared-path changes. No further source repair was warranted. Independent
  bounded read-only review found no unresolved high or mid finding in
  `TaskGuardCoordinator`, `DeterministicDirector`, `DecisionApplier`,
  `WorkStore+Decisions`, or their assigned suites.
- The mandated isolated-scratch build exited 1 before compilation because the
  sandbox denies the default Clang module cache. The cache-isolated retry also
  exited 1 because `agent-gateway` dependency fetch cannot resolve
  `github.com`. Complete logs: `tmp/work-runtime-p1/p1-lifecycle/attempt-1/01-build.log`
  and `02-build-fallback.log`.
- With the existing resolved `.build` checkouts and plan-local writable module
  caches, the foreground focused lifecycle filter exited 0 with **58 selected
  tests and 0 failures**. Complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-1/04-focused-tests-fallback.log`.
- The matching current-tree cache-isolated fallback build also exited 0;
  complete log: `tmp/work-runtime-p1/p1-lifecycle/attempt-1/10-build-current-fallback.log`.
- `git diff --check` exited 0; complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-1/03-diff-check.log`. Fresh
  pre-verification hashes and the immutable evidence-refresh intent are in
  `tmp/work-runtime-p1/p1-lifecycle/intents/001/`.
- The strict lint command over the current 11 changed lifecycle Swift files
  exited 0 with no diagnostics; complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-1/06-touched-swiftlint.log` and
  manifest: `tmp/work-runtime-p1/p1-lifecycle/changed-swift-files.nul`.
  Repository SwiftLint also exited 0; its warnings are confined to unrelated
  `RielaCore`, `RielaCLI`, `RielaGraphQL`, server, app-support, and CLI test
  files. Complete log: `tmp/work-runtime-p1/p1-lifecycle/attempt-1/07-repository-swiftlint.log`.

No unresolved P1-2/P1-3 high/mid author-self-check finding remains. This entry
does not accept the plan or update shared indexes; integrity/adversarial and
combined-tree review remain downstream gates.

## Step 6 test-integrity repair `comm-000083`

- Addressed every mid finding in the test-integrity review without production
  changes. Added explicit gate-visits equality, duplicate same-execution
  cumulative-cost, and coordinator guard-persistence-conflict regressions in
  `WorkGuardTests.swift` and `WorkGuardDispatcherTests.swift`.
- Added a compact table-driven `DecisionApplierStoreTests` regression covering
  live `.stop`, `.reject`, `.rerun`, and `.recover`: each retains task/attempt
  fences and leases before a matching cancelled snapshot is acknowledged;
  rerun/recover pending reservations remain durable and only then advance to
  scheduled state.
- The cache-isolated current-tree focused lifecycle filter exited 0 with
  **61 selected tests and 0 failures**. Complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-2/04-focused-tests-final.log`.
  Strict lint over the changed test files and `git diff --check` exited 0;
  complete logs: `05-touched-swiftlint-final.log` and `03-diff-check.log`.
  Pre/post intent and source hashes are retained under
  `tmp/work-runtime-p1/p1-lifecycle/attempt-2/`.

All `comm-000083` high/mid test-integrity findings are addressed. This entry
does not accept P1-2/P1-3 or update shared indexes; downstream adversarial and
combined-tree review remain required.

## Step 6 adversarial repair `comm-000087`

- Addressed the high-severity false-success path. Completion reconstruction now
  records a non-completed attempt as unmet, and the deterministic director
  returns safe human wait rather than accepting any latest attempt whose
  outcome status is not completed after recovery is unavailable.
- Added focused completion, director, and store-backed regressions for failed
  empty contracts, failed attempts with otherwise accepted gate/verification/
  acceptance inputs, and a caller-supplied satisfied accept against a failed
  latest attempt. The store leaves task state and decisions unchanged.
- The current-tree cache-isolated lifecycle filter exited 0 with **64 selected
  tests and 0 failures**. Complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-3/02-focused-tests-final.log`.
  Strict touched SwiftLint and `git diff --check` exited 0; complete logs:
  `03-touched-swiftlint.log` and `04-diff-check.log` in the same directory.

All `comm-000087` high/mid adversarial findings are addressed. This entry does
not accept P1-2/P1-3 or update shared indexes; downstream combined-tree review
remains required.

## Step 6 adversarial fencing repair `comm-000091`

- Added transactional latest-attempt binding for `.cancel`, `.stop`, `.reject`,
  `.rerun`, and `.recover`, matching existing accept validation. When a task
  has any attempt, omitted or stale same-task attempt identities reject before
  causality, application, lease, cancellation, pending-reservation, decision,
  or evidence mutation.
- Added table-driven store coverage for all five actions against both omitted
  and stale attempt identities while a newer authorized attempt is running;
  the regression compares task/attempt records and all relevant durable row
  counts before and after rejection.
- The cache-isolated current-tree lifecycle filter exited 0 with **65 selected
  tests and 0 failures**. Complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-4/02-focused-tests-final.log`.
  Strict touched SwiftLint and `git diff --check` exited 0; complete logs:
  `03-touched-swiftlint.log` and `04-diff-check.log` in the same directory.

All `comm-000091` high/mid adversarial findings are addressed. This entry does
not accept P1-2/P1-3 or update shared indexes; downstream combined-tree review
remains required.

## Step 6 adversarial budget-admission repair `comm-000095`

- Replaced max-attempt-only admission checks with one transaction-local shared
  budget fence used by both `applyDecision` and `reserveAttempt`. It enforces
  the reservation-owned attempt limit, replay-deduplicated persisted token
  totals, persisted workflow-change proposals, and immutable exhausted
  wall-clock/proposal guard evidence before any new start/resume/rerun/recover
  request can commit or consume a reservation.
- Added direct-caller tables over human, policy, and agent producers for all
  four execution-requesting decisions and direct start/resume reservations;
  each dimension rejects before task, attempt, lease, request, decision,
  application, or evidence mutation. An explicit last-admitted-attempt test
  keeps completion acceptance outside the admission fence.
- The cache-isolated current-tree focused lifecycle filter exited 0 with
  **68 selected tests and 0 failures**. Complete log:
  `tmp/work-runtime-p1/p1-lifecycle/attempt-5/22-focused-tests-final.log`.

All `comm-000095` high/mid adversarial findings are addressed. This entry does
not accept P1-2/P1-3 or update shared indexes; downstream combined-tree review
remains required.

## Step 6 P1-2 official SDK heartbeat repair

- Fixed the configured-backend edge case in `Sources/RielaWork/WorkGuard.swift`:
  `official/*-sdk` backends are now exempt from inactivity violations even when
  explicitly listed in `heartbeatBackends`, preserving the accepted SDK
  exemption. `WorkGuardTests` now exercises exact `official/openai-sdk`
  configuration.
- Cache-isolated focused lifecycle verification passed **69 tests with 0
  failures**; `git diff --check` and strict changed-file SwiftLint passed.
  The requested scratch-path build remains blocked before compilation because
  its module cache is outside the writable sandbox; the prescribed current-tree
  cache-isolated fallback build passed. Complete immutable logs and structured
  evidence: `tmp/work-runtime-p1/p1-lifecycle/step6/verification-evidence.json`.

No unresolved P1-2/P1-3 high/mid author-self-check finding remains. This entry
does not accept P1-2/P1-3 or update shared indexes; downstream combined-tree
review remains required.

## Step 6 adversarial repair `comm-000108`

- Repaired cumulative token accounting in both `TaskGuardSnapshotAdapter` and
  reservation admission: costs now deduplicate by `(attemptId, stepExecutionId)`.
  Repeated cumulative records within an attempt retain the latest value, while
  distinct attempts with reused session-local IDs both count toward the task
  budget.
- Added focused adapter and admission regressions. The cache-isolated lifecycle
  filter passed **70 tests with 0 failures**; final `git diff --check` and
  strict changed-file SwiftLint passed. The requested scratch build remains
  sandbox-blocked before compilation; the current-tree fallback test compiled
  and passed. Evidence: `tmp/work-runtime-p1/p1-lifecycle/step6-repair-comm-000108/verification-evidence.json`.

All `comm-000108` high/mid findings are addressed. This entry does not accept
P1-2/P1-3 or update shared indexes; downstream combined-tree review remains
required.

## Step 6 test-integrity repair `comm-000111`

- Added the independent reservation-admission replay regression requested by
  test integrity: same-attempt cumulative costs `13` then `42` with one
  execution ID remain at `42`, so a reservation below the 50-token limit
  succeeds. The existing cross-attempt `60 + 60` rejection remains intact.
- Cache-isolated focused lifecycle verification passed **71 tests with 0
  failures**; `git diff --check` and strict changed-file SwiftLint passed.
  Evidence: `tmp/work-runtime-p1/p1-lifecycle/step6-repair-comm-000111/verification-evidence.json`.

All `comm-000111` high/mid findings are addressed. This entry does not accept
P1-2/P1-3 or update shared indexes; downstream combined-tree review remains
required.

## Step 6 adversarial repair `comm-000115`

- Latest-attempt authorization now orders attempts by transactionally assigned
  `generation DESC`, then `attempt_id`, rather than caller-supplied creation
  time. The existing protected-action table now reserves generation 2 with an
  earlier timestamp and lexically smaller ID; stale generation-1 cancel, stop,
  reject, rerun, and recover decisions all reject before mutation.
- Cache-isolated focused lifecycle verification passed **71 tests with 0
  failures**; `git diff --check` and strict changed-file SwiftLint passed.
  Evidence: `tmp/work-runtime-p1/p1-lifecycle/step6-repair-comm-000115/verification-evidence.json`.

All `comm-000115` high/mid findings are addressed. This entry does not accept
P1-2/P1-3 or update shared indexes; downstream combined-tree review remains
required.

## Step 6 adversarial repair `comm-000119`

- The transaction-authoritative applier now requires persisted causal evidence
  for every `accept`, `cancel`, `stop`, `reject`, `rerun`, and `recover`, no
  matter whether the producer is human, policy, or agent. Existing causal
  scope validation continues to reject foreign task/attempt evidence; a stop
  must additionally cite its `GuardViolationRef.evidenceId` and that evidence
  must be a persisted guard violation.
- Added `DecisionApplierCausalityStoreTests` as a narrow responsibility split
  from the existing store suite. Its matrix proves empty and foreign causes
  roll back cancel, stop, reject, rerun, and recover for human, policy, and
  agent producers, and verifies a non-guard stop cause rolls back without durable
  mutation. Existing success-path tests now persist valid causal evidence.
- Cache-isolated focused lifecycle verification exited 0 with **73 selected
  tests and 0 failures**. `git diff --check`, strict changed-file SwiftLint,
  and repository SwiftLint exited 0. The prescribed scratch-path build exited
  1 before compilation because the user Clang module cache is unwritable;
  the cache-isolated focused test compiled the current tree. Complete logs and
  structured evidence: `tmp/work-runtime-p1/p1-lifecycle/step6-repair-comm-000119/verification-evidence.json`.

All `comm-000119` high/mid findings are addressed. This entry does not accept
P1-2/P1-3 or update shared indexes; p1-dispatch integration, combined-tree
review, and p1-finalize remain downstream.

## Step 6 adversarial repair `comm-000123`

- Completion-satisfied policy acceptance now carries explicit persisted
  latest-attempt completion evidence through `DeterministicDirectorInput` and
  `TaskGuardCoordinator`. A satisfied completion without evidence safely waits
  for a human; the durable applier remains authoritative for missing, foreign,
  or stale evidence.
- Added a store-backed coordinator completion regression proving a completed
  attempt with persisted verification evidence transitions to `succeeded` and
  reconciles its attempt. Missing, foreign-task, and stale-attempt completion
  evidence each reject without creating a decision or advancing the task.
- Cache-isolated focused lifecycle verification exited 0 with **75 selected
  tests and 0 failures**. `git diff --check`, strict changed-file SwiftLint,
  and repository SwiftLint exited 0. The prescribed scratch-path build exited
  1 before compilation because the user Clang module cache is unwritable;
  the cache-isolated focused test compiled the current tree. Evidence:
  `tmp/work-runtime-p1/p1-lifecycle/step6-repair-comm-000123/verification-evidence.json`.

All `comm-000123` high/mid findings are addressed. This entry does not accept
P1-2/P1-3 or update shared indexes; p1-dispatch integration, combined-tree
review, and p1-finalize remain downstream.
