# whu-08-rollback-service progress

Operator kickoff (2026-11-02, resume #17). The previous dispatches returned without editing files. This dispatch MUST edit code. Work through these steps in order, committing nothing (the workflow commits). After each step, append a short line here.

1. `Sources/RielaCore/WorkflowRollbackProposalStore.swift`: make `transition` compare-and-swap on BOTH `status` and claim transaction id (an optional `expectedClaimTransactionId`). Release and replay paths pass the id. Add a test in `Tests/RielaCoreTests/WorkflowRollbackProposalStoreTests.swift`: an older transaction's retry must not release a newer `applying` claim.
2. Update `releaseRollbackClaim` (Sources/RielaWorkflowRegistry/WorkflowMutableRegistry+Evolution.swift) and `replayPending` (Sources/RielaCLI/WorkflowDefinitionSyncIntentStore.swift) to use that compare-and-swap.
3. Create `Sources/RielaCLI/WorkflowRegressionRollbackService.swift` (proposal creation from a LoopRegressionVerdict, policy manual|approval-required|automatic per design §5, eligibility codes, at most one proposal per regressed version) and `WorkflowRegressionRollbackService+Apply.swift` (store-mode and bundle-mode apply, applying-claim crash recovery).
4. Wire the store-pinned, best-effort post-run hook into `WorkflowRunCommand.swift` / `WorkflowRunCommand+LoopOperations.swift`. One-time runs must never open definition tables.
5. Give `MutableGeneratedWorkflowTaskRegistrar` (ProductionNodeAdapter+WorkflowTaskAddon.swift) the production recorder.
6. Tests: `Tests/RielaCLITests/LoopRegressionRollbackTests.swift` (the cases listed in the plan, using mutable registry/user-scope workflows) and `Tests/RielaCLITests/WorkflowHistoryBoundedStorageTests.swift` (Q7: one-time runs write no definition/audit/proposal rows; repeated unchanged sync is bounded; terminal proposals are pruned with their versions).
7. Gates: swift build, the focused swift test filter, swiftlint, with logs under tmp/workflow-history-unification/whu-08/.

If the work does not fit in one invocation, return implementationIncomplete with the files changed so far. A partial result with changed files is expected and accepted; an empty one is not.

## Partial implementation (2026-11-02)

- Steps 1–2: transition accepts an expected claim transaction ID; registry release and sync-intent replay pass their own IDs. The store test checks that an old retry cannot release a newer claim.
- Steps 3–6 remain outstanding; no rollback service, post-run hook, registrar wiring, or Q7 tests have been implemented in this dispatch. The positional inline JSON and `.json` path forms remain required for Q7.
- Current partial tree: build exit 0; `WorkflowRollbackProposalStoreTests` exit 0 (2 tests); plan filter exit 0 (39 tests, but the two new suites do not yet exist); strict changed-file SwiftLint exit 0. Logs and manifest are in `tmp/workflow-history-unification/whu-08-rollback-service/`. Rerun all gates after implementation is complete.
- WHU-INT-01 is assigned to whu-01, not this plan. The schema generation and cited assertions already reflect generation 13; its remaining acceptance evidence is not established by this dispatch.

## Continuation 1 (2026-11-02)

- Added the store-mode `WorkflowDefinitionService.rollback` seam with proposal identity checks, explicit head CAS, structured diff, and atomic proposal completion. A focused registry test verifies the successful transaction and rejects a mismatched head argument.
- Step 5: generated-task registration now uses the production definition recorder; a focused test verifies its definition row and improvement-node actor.
- Updated two existing recovery tests to claim at `beforePublication` with the actual transaction ID. Their previous literal claim did not represent the transaction recovered after interruption.
- Current source: build exit 0; registry and proposal suites exit 0 (14 tests); plan filter exit 0 (39 tests); strict changed-file lint exit 0. Earlier recovery-suite and lint failures and their corrected reruns are retained in `tmp/workflow-history-unification/whu-08-rollback-service/continuation-*.log`.
- Still required: regression check/list/approve/reject service, bundle apply and crash recovery, service-only post-run hook, Q7 cases and full plan acceptance tests. The plan filter currently does not include the two missing suites, so it is not acceptance evidence. Rerun all gates after completing them.

## Continuation 2 (2026-11-02)

- Added partial `WorkflowRegressionRollbackService`: baseline pair and regression classification, target/parent lookup, eligibility and parent policy, proposal insertion, store approval/rejection, and stale-head supersession. Automatic bundle evaluation and bundle approval fail closed because bundle application is not implemented.
- Added no-baseline coverage and a store approval integration test. Regression-to-proposal policy cases, store race coverage, and rejection transition coverage still require tests.
- Final partial-tree checks: build exit 0, combined focused tests exit 0 (55 tests), plan filter exit 0 (40 tests), strict changed-file lint exit 0. Logs are `tmp/workflow-history-unification/whu-08-rollback-service/continuation2-*`. The plan filter has no Q7 suite and does not prove plan completion.
- Outstanding: bundle-mode restore and claim recovery, post-run hook, complete policy and interleaving tests, Q7 named/inline/path/loop-start zero-row tests, and final acceptance verification. The partial service is not ready for integration review or downstream wiring.

## Continuation 3 (2026-11-02)

- Claim transitions from `applying` now require a nonempty expected transaction ID. The interleaving test also verifies omitted and empty IDs cannot release the newer claim.
- Current partial tree: build exit 0; proposal store suite exit 0 (2 tests); assigned filter exit 0 (40 tests); strict changed-file SwiftLint exit 0. Complete logs and NUL-delimited Swift manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation3-*`. The assigned filter does not include the missing Q7 suite and is not acceptance evidence.
- Completion criteria remain open: bundle apply and recovery, automatic bundle evaluation, post-run hook, Q7 one-time-run tests, full policy and bundle interleaving coverage, and final-source acceptance verification. Formal reviews and finalization remain downstream.

## Continuation 4 (2026-11-02)

- Added the best-effort post-terminal hook for completed store-pinned service runs declaring regression rollback, with loop evidence and a baseline. Errors are persisted as session diagnostics; one-time runs return before opening the store.
- Current partial tree: build exit 0; assigned filter exit 0 (40 tests); strict changed-file SwiftLint exit 0. Logs and Swift manifest: `tmp/workflow-history-unification/whu-08-rollback-service/continuation4-*`.
- The hook still needs direct success and failure tests. Bundle apply and claim recovery, automatic bundle policy, Q7 tests, full policy/interleaving coverage, and final acceptance verification remain incomplete. The passing filter does not include the missing Q7 suite.

## Continuation 5 (2026-11-02)

- Added a service test for manual approval refusal, rejection without head movement, and stale-head supersession without restore.
- Current partial tree: build exit 0; new focused test exit 0 (1 test); assigned filter exit 0 (40 tests); strict changed-file SwiftLint exit 0. Logs and NUL manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation5-*`.
- Bundle apply and crash recovery, automatic bundle policy, direct hook tests, Q7 one-time-run tests, complete policy/interleaving coverage and final acceptance verification remain incomplete. The assigned filter does not exercise the missing Q7 suite.

## Continuation 6 (2026-11-02)

- Added partial bundle approval using a name/scope resolution, canonical source-directory check, rollback attribution, and a publication transaction claim. The mutable-registry happy-path test verifies an applied proposal, parent digest, one rollback audit and no extra registry write. Service recorder resolution now avoids reacquiring the held registry lock.
- The first focused run hung after compilation and was interrupted (exit 130; `continuation6-focused.log`). After correcting the recorder lock, the focused retry passed (1 test); build and strict changed-file lint passed; assigned filter passed (40 tests). Logs and manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation6-*`.
- Bundle claim recovery on check/approve, restore error mapping/cleanup and digest diagnostics are not implemented; automatic bundle evaluation stays disabled. Direct hook tests, Q7 one-time-run tests, policy and interleaving coverage and final acceptance verification remain incomplete. An interrupted bundle apply may leave an applying claim requiring recovery; this partial service is not review-ready.

## Continuation 7 (2026-11-02)

- Added recorder-backed registry or coordinator recovery at check and approve, then CAS release of the originally observed applying claim. Mutable recovery runs before resolving the possibly missing live directory. The new unpublished-claim test and bundle happy-path test pass (2 tests).
- Current partial tree: build exit 0; assigned filter exit 0 (40 tests); strict changed-file lint exit 0. Logs and manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation7-*`.
- Published interruption and concurrent approval coverage, restore error mapping/cleanup, digest diagnostics, automatic bundle policy, direct hook tests, Q7 tests, complete policy tests and final acceptance verification remain incomplete. The assigned filter does not exercise the missing Q7 suite.

## Continuation 8 (2026-11-02)

- Added typed bundle claim/sync/dirty-conflict/history-validation error mappings and pin-derived store recovery after a regressing target is resolved. Invalid snapshot test confirms failure status and unchanged head.
- Current partial tree: build exit 0; focused bundle/recovery tests exit 0 (3 tests); assigned filter exit 0 (40 tests); strict changed-file lint exit 0. Logs and manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation8-*`.
- Remaining: complete pre/post-publication recovery and error cleanup, recovery of a pin-derived store when no regression is found, digest diagnostics, automatic bundle policy, published interruption and concurrent approval tests, direct hook tests, Q7 suite, full policy coverage and final acceptance verification. The filter does not exercise the missing Q7 suite.

## Continuation 9 (2026-11-02)

- Known bundle validation and dirty-conflict failures now invoke recovery before conditionally failing a still-pending proposal. A resolved target pin's store is recovered before a no-regression return.
- Current partial tree: build exit 0; focused bundle/recovery tests exit 0 (3 tests); assigned filter exit 0 (40 tests); strict changed-file lint exit 0. Logs and manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation9-*`.
- Direct tests for pin-root no-regression recovery and post-claim failure cleanup remain needed, as do generic error cleanup, automatic bundle policy, digest diagnostics, published interruption/concurrency, Q7, direct hook and full policy tests. The assigned filter does not exercise the missing Q7 suite; final acceptance verification remains incomplete.

## Continuation 10 (2026-11-02)

- Automatic proposals now apply through their store or bundle path using the parent policy and system actor; a per-version lookup returns existing on repeat. File sync no longer records empty overwrite details when head equals last file version, which had falsely forced manual policy.
- Added an end-to-end automatic bundle regression test covering the parent policy, applied digest and system actor, and repeat idempotence. Initial focused attempts failed due to the empty overwrite record (`continuation10-focused.log`, `continuation10-diagnostic.log`); the corrected retry passed (1 test).
- Current partial tree: build exit 0; registry/proposal suites exit 0 (20 tests); assigned filter exit 0 (40 tests); strict changed-file lint exit 0. Logs and manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation10-*`.
- Remaining: generic restore error cleanup, digest diagnostics, direct tests for pin-root and post-claim recovery, published interruption/concurrency, Q7, direct hook and complete policy coverage. The assigned filter does not exercise the missing Q7 suite; final acceptance verification remains incomplete.

## Continuation 11 (2026-11-02)

- Extended the old-claim interleaving test to reject an attempt to fail a newer claim. A proposed generic recovery catch was removed during self-check: recovery scans all applying claims and could release a concurrent live claim that this invocation did not acquire.
- Initial partial-tree checks passed, but preceded removal of the proposed catch; their logs are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation11-*` and are not final-source evidence.
- Completion remains open: safely scoped generic error cleanup, digest mismatch diagnostics, direct pin-root and post-claim recovery tests, published interruption/concurrency, Q7 zero-row suite, direct hook tests, full policy coverage, and final acceptance verification. Formal review and finalization remain downstream.
- After removal, final-source `WorkflowRollbackProposalStoreTests` passed (2 tests, 0 failures) and strict SwiftLint on the changed test passed; see `continuation11-final-tests.log`, `continuation11-final-lint.log`, and `continuation11-final-changed-swift.nul` in the plan evidence directory.

## Continuation 12 (2026-11-02)

- Claim recovery now replays and releases observed claims while holding the registry or directory publication lock. Generic restore errors recover before propagation; definition-sync failures retain their existing applying state. A live registry publication test verifies recovery waits until the claim is applied.
- Bundle apply records `rollbackDigestMismatch` on an applied proposal through an idempotent, applied-version-guarded store update. Added Q7 coverage for named, positional inline JSON, `.json` path, and loop-start runs with an existing baseline. Added direct hook success/failure and parent manual/approval-required policy tests.
- Final-source build exit 0, assigned filter exit 0 (43 tests), registry/proposal filter exit 0 (22 tests), and strict lint on all changed Swift files exit 0. Logs and NUL manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation12-*`; initial lint found two overlong fixture literals, fixed before the retry.
- Done criteria remain open: direct generic post-claim error cleanup and digest mismatch integration assertions, pin-root no-regression recovery, published interruption and concurrent-approval cases, remaining eligibility and store-mode policy cases, and the other explicitly enumerated plan interleavings are not fully covered. Formal review and finalization remain downstream.

## Continuation 13 (2026-11-02)

- Added tests for store-mode policies and eligibility, pin-root no-regression recovery, post-claim generic errors, digest mismatch, concurrent approvals, published rollback replay, and invalid-definition classification. Added a service catch for typed `WorkflowResolutionError.invalidWorkflow`.
- The final expanded run failed: 41 tests, 3 assertions in `testBundleApprovalFailsInvalidDefinitionAfterClaim`; the proposal remains pending because `Sources/RielaCLI/WorkflowDirectoryTransaction.swift:452` wraps the typed validation error in `CLIUsageError`. The focused diagnostic log confirms the wrapper. That coordinator file is outside whu-08 writePaths; preserving typed validation through the coordinator requires an ownership amendment before this can be repaired safely. No string-based compatibility workaround was added.
- Strict changed-file SwiftLint exit 0. Logs: `continuation13-expanded.log`, `continuation13-invalid-diagnostic.log`, `continuation13-lint.log`; the prior focused run and fixture fix are also retained in the plan evidence directory. The assigned final build and aggregate require rerun after the coordinator repair. Completion criteria remain open.

## Continuation 14 (2026-11-02)

- Preserved `WorkflowResolutionError.invalidWorkflow` through transaction cleanup, so bundle approval can classify the proposal as failed with `invalid_definition`. The previously failing `testBundleApprovalFailsInvalidDefinitionAfterClaim` passed in the expanded filter.
- Current source: build exit 0; assigned filter exit 0 (44 tests, 0 failures); expanded rollback/recovery filter exit 0 (81 tests, 0 failures); strict changed-file SwiftLint exit 0. Complete logs and NUL manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation14-*`.
- Completion remains open: the plan explicitly requires direct coverage for file-origin digest resolution, source-directory mismatch, claim/reject and store-writer interleavings, dirty conflict, and concurrent registry-update/approval timeout. These cases have not been established by the passing filters. Formal review, downstream surfaces and finalization remain downstream.
- WHU-INT-01 belongs to whu-01 and is recorded as resolved by the dispatch operator; its two schema assertions now use the generation constant. No whu-01 paths were amended in this continuation.

## Continuation 15 (2026-11-02)

- Added file-origin target digest resolution, first-use mutable baseline and approval, source-directory mismatch, dirty-conflict, rejection before and during a claim, store-only writer exclusion during a claim, and concurrent registry update/approval coverage. The existing tests cover concurrent approvals and both unpublished and published claim recovery.
- Final-source gates: build exit 0; assigned filter 44 tests, 0 failures; expanded rollback/recovery filter 86 tests, 0 failures; strict changed-file SwiftLint exit 0. Logs and NUL manifest are under `tmp/workflow-history-unification/whu-08-rollback-service/continuation15-final-*`. The initial source-mismatch fixture failed before reaching the intended guard; its corrected test passes in the final expanded run. The initial lint type-length finding was resolved by a same-file test extension.
- Implementation completion criteria: pinned service and Q7 tests implemented and passing; `LoopBaselineCommands.swift` is unchanged. CLI/GraphQL surfaces, formal review, and finalization remain downstream.
