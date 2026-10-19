# ar-05-cli-executor progress

Workflow mode: `issue-resolution`  
Issue reference: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number)  
Codex-agent reference: `/root (Codex) Step 6 implementation`  
Plan: `impl-plans/active/automatic-retention-05-cli-executor.md`  
Branch/worktree: `feat/automatic-retention`, `tmp/automatic-retention-worktree`

## Implementation status

- `TerminalRetentionPaths` now accepts optional artifact and memory roots, validates distinctness/nesting only for present roots, rejects artifact snapshot access without an artifact root, and returns no memory DBs without a memory root.
- Runtime message bytes are counted separately from result payload bytes. Optional artifact and memory scans are skipped when those roots are absent.
- `TerminalRetentionSecondary` uses `RetentionSQLiteReclaimer`, passes the selected manual/automatic mode, returns reclamation records, and contains no full `VACUUM` or truncating checkpoint path. Session prune reports reclamation results.
- Message tombstone DDL and message recreation guards were added. Results pruning can preserve messages; independent message pruning writes per-session tombstones and uses result-tombstoned orphan sets.
- `TerminalRetentionExecutor.runPolicy` implements results, messages-only, merged family/orphan message cap selection, per-family lock admission, transaction rechecks against `eligible`, results/message tombstones, dry-run read-only reporting, optional roots, pending-root mismatch protection, category reports, orphan lock finalization, and reclamation reporting.
- Pending cleanup roots are checked per family and mismatches remain protected while other eligible families proceed.
- `TerminalRetentionPolicyTests` adds 16 behavioral tests. Every fixture backdates `updated_at` in both `workflow_runtime_snapshots` and `cli_workflow_sessions` relative to the fake clock; orphan message fixtures backdate `created_at` as well.

## Acceptance criteria

| Criterion | Status | Evidence |
|---|---|---|
| Results policy pruning uses locks, transaction recheck, tombstones, optional roots, and pending-root mismatch protection. | Met | `TerminalRetentionExecutor.swift`; tests `testResultsFollowResultsDeletesMessagesAndReportsTheirBytes`, `testPendingRootsMismatchProtectsOneFamilyAndContinuesPruning`, `testExecutionLockedFamilyRemainsProtectedUnderCap`. |
| Messages-only pruning merges `plan.eligible` family candidates with orphan sets and rechecks family membership against `currentPlan.eligible`. | Met | `TerminalRetentionExecutor.swift`; tests `testMessageCapIncludesOrphanAndFamilyBytesAndRechecksEligibleFamily`, `testOrphanMessagesArePrunedIndependently`, `testMessagesOnlyTombstoneLeavesSnapshotAndRejectsRecreation`. |
| Session prune uses manual reclamation and reports results; no full VACUUM/truncating checkpoint remains in executor or secondary cleanup. | Met | `TerminalRetentionSecondary.swift`, `TerminalRetentionExecutor.swift`; `testSessionPruneJSONIncludesReclamationResults`; static grep below. |
| Focused suite count is at least the previous 11 tests plus 14; dependency suites and strict selected-file SwiftLint pass. | Met | Final focused suite: 27/0; dependency suites: 35/0; strict selected-file lint: exit 0, empty log. |

## Verification

| Command | exitStatus | testsRun | failureCount | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionTests|TerminalRetentionPolicyTests" > tmp/automatic-retention/ar-05-cli-executor/test-final.log 2>&1'` | 0 | 27 | 0 | `tmp/automatic-retention/ar-05-cli-executor/test-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SessionExecutionLockTests|RetentionReclamationTests|TerminalRetentionPlanTests" > tmp/automatic-retention/ar-05-cli-executor/deps-final.log 2>&1'` | 0 | 35 | 0 | `tmp/automatic-retention/ar-05-cli-executor/deps-final.log` |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-05-cli-executor/changed-swift-files.nul > tmp/automatic-retention/ar-05-cli-executor/swiftlint-final.log 2>&1` | 0 | 0 | 0 | `tmp/automatic-retention/ar-05-cli-executor/swiftlint-final.log` (empty) |
| `grep -nE 'VACUUM|wal_checkpoint\(TRUNCATE\)' Sources/RielaCLI/TerminalRetentionSecondary.swift Sources/RielaCLI/TerminalRetentionExecutor.swift` | 1 (expected no matches) | 0 | 0 | No output |
| `grep -n 'func runPolicy(' Sources/RielaCLI/TerminalRetentionExecutor.swift && grep -n 'allowMessagesRetired: true' Sources/RielaCLI/TerminalRetentionExecutor.swift && if grep -nE 'VACUUM|wal_checkpoint\(TRUNCATE\)' Sources/RielaCLI/TerminalRetentionSecondary.swift Sources/RielaCLI/TerminalRetentionExecutor.swift; then exit 1; else printf '%s\n' 'no VACUUM or truncating checkpoint references'; fi && git diff --check` | 0 | 0 | 0 | `runPolicy` and `allowMessagesRetired: true` match; forbidden patterns absent; diff check clean |

## Superseded attempts

- `compile-test.log`: exit 1 before test execution; the compiler reported a type-check complexity issue in the new heterogeneous candidate sort. Split it into typed intermediate arrays.
- `compile-test-002.log`: exit 1 during test compilation after making roots optional; existing fixtures needed to unwrap their explicitly supplied roots. Updated those call sites.
- `policy-test-001.log`: 25 tests, 2 failures. The orphan setup pass also ran its independent messages policy, and pending-root mismatches were not being attached to planner metadata. The tests and metadata protection were corrected.
- `policy-test-002.log`: 25 tests, 2 failures. The diagnostic assertions confirmed the setup pass was pruning the orphan message in the same invocation; the setup now keeps messages forever so the subsequent pass tests orphan pruning.
- `policy-test-003.log`: exit 1 before test execution due to a helper type mismatch while updating protected-family reporting; corrected to pass explicit root/reason pairs.
- `swiftlint-initial.log`: exit 1 with four formatting findings; all were fixed. The final selected-file strict lint is clean.

## Handoff

No implementation blocker remains. Formal test-integrity, adversarial, and combined-tree integration reviews, then serial commit finalization, belong to downstream workflow steps.

## Operator amendment (2026-10-19, after session 452 blocked on ar-07)

The ar-07 implementer reported a seam it could not fix inside its write scope:
`runPolicy` reclaimed the runtime database with `.automatic` and `finalize`
reclaimed it again, and the service's injected `freeSpace` probe never reached
the reclaimer. The operator fixed it in this plan's files:

- `TerminalRetentionExecutor` has a stored `reclaimer: RetentionSQLiteReclaimer`
  used for every SQLite file it reclaims (runtime, memory, artifact message DBs).
- `runPolicy` no longer reclaims the runtime database. `finalize` reclaims it
  exactly once, after orphan-lock cleanup.
- `runPolicy(... reclamationMode:)` (default `.automatic`) is passed to secondary
  cleanup so manual `riela gc` uses `.manual` for memory/artifact databases.
- `TerminalRetentionSecondary.clean(... reclaimer:)` takes the executor's reclaimer.

Verification: `swift test --filter "RielaRetentionServiceTests|TerminalRetentionPolicyTests|TerminalRetentionTests|RetentionReclamationTests|..."`
exitStatus 0, testsRun 164, failureCount 0 (log: tmp/automatic-retention/manual-fix/focused.log).
