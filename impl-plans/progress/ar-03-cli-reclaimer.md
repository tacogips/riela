# ar-03-cli-reclaimer implementation progress

Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL or number).
Workflow mode: `issue-resolution`. Implementation agent: Codex `/root` (Step 6).
Branch: `feat/automatic-retention`.

## Changes

- Added `RetentionSQLiteReclaimer` in `Sources/RielaCLI/RetentionSQLiteReclaimer.swift`. It reports DB plus WAL sizes, opens without enabling WAL, uses incremental vacuum and PASSIVE checkpoints, gates NONE-to-INCREMENTAL conversion on free space and the automatic 64 MiB limit, and returns warning results for busy, disk-full, and other SQLite errors without throwing.
- Added eight behavioral tests in `Tests/RielaCLITests/RetentionReclamationTests.swift`, including automatic physical shrink of an incremental database without full `VACUUM`, conversion, free-space deferrals, missing databases, busy writers, and preservation of rollback-journal mode. Test roots are realpath-resolved beneath repository `tmp/`.
- Verified source SHA-256: `b9adf4d985e93c2cd99588f15fd247097bc9c5f9f64728426957705537509ea2`.
- Verified test SHA-256: `43ce858c7b97ee966b9295d9ac0dc05a526f96df693e33e4e65dd1cea7a9011d`.

## Verification

| Command | exitStatus | testsRun | failureCount | Outcome | Evidence |
|---|---:|---:|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter RetentionReclamationTests > tmp/automatic-retention/ar-03-cli-reclaimer/test.log 2>&1'` | 1 | 8 | 5 | First run exposed a fixture ordering error: WAL was enabled before setting `auto_vacuum`, so the incremental fixture was actually NONE-mode. Observer assertions also matched the `auto_vacuum` pragma text. Corrected in the test file; this attempt is retained as prior evidence, not a passing gate. | `tmp/automatic-retention/ar-03-cli-reclaimer/test.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RetentionReclamationTests > tmp/automatic-retention/ar-03-cli-reclaimer/test-rerun-001.log 2>&1'` | 0 | 8 | 0 | All eight tests passed, including physical file shrink on an incremental DB without full `VACUUM`. | `tmp/automatic-retention/ar-03-cli-reclaimer/test-rerun-001.log` |
| `arch -arm64 /bin/zsh -lc 'set -o pipefail; if [ -s tmp/automatic-retention/ar-03-cli-reclaimer/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-03-cli-reclaimer/changed-swift-files.nul > tmp/automatic-retention/ar-03-cli-reclaimer/swiftlint-rerun-001.log 2>&1; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | Strict SwiftLint passed for the exact changed-file manifest. | `tmp/automatic-retention/ar-03-cli-reclaimer/swiftlint-rerun-001.log` |
| `count=$(grep -Ec 'wal_checkpoint\\(TRUNCATE\\)|wal_checkpoint\\(RESTART\\)' Sources/RielaCLI/RetentionSQLiteReclaimer.swift || true); test "$count" -eq 0; test "$(grep -Fc 'func reclaim(databasePath: String, mode: RetentionReclamationMode) -> RetentionReclamationResult' Sources/RielaCLI/RetentionSQLiteReclaimer.swift)" -eq 1; printf 'forbidden_checkpoint_count=%s\\nrequired_signature_count=1\\n' "$count"` | 0 | 0 | 0 | Reported zero forbidden checkpoints and exactly one required function signature. | terminal output |

The first build took 692 seconds because this worktree had no compiled SwiftPM products. Concurrent fanout commands briefly held the shared `.build` lock before the successful rerun; the complete rerun log includes that wait and the completed build/test output.

## Completion criteria

- [x] Reclaimer implements design §5.3 and never throws.
- [x] Automatic incremental vacuum physically shrinks an incremental-mode DB without a full `VACUUM`.
- [x] NONE-mode conversion respects the automatic size cap and injected free-space gate.
- [x] PASSIVE checkpoint is used; TRUNCATE and RESTART are absent.
- [x] Eight focused behavioral tests pass with zero failures.
- [x] Strict changed-file SwiftLint passes.
- [x] Verification evidence is complete under `tmp/automatic-retention/ar-03-cli-reclaimer/`.

Formal integrity/adversarial review and serial branch finalization are owned by downstream workflow steps.
