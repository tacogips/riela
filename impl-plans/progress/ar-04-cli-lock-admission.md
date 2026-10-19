# ar-04-cli-lock-admission progress

Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL or number).
Codex agent: `/root`, Step 6 implementation.
Workflow mode: `issue-resolution`; branch: `feat/automatic-retention`.
Plan: `impl-plans/active/automatic-retention-04-cli-lock-admission.md`.
Design: `design-docs/specs/design-automatic-retention.md`.

## Implemented

- Hardened execution-lock acquisition with post-flock inode validation and up to eight retries, with a no-op test injection seam.
- Added messages-retired admission and the `allowMessagesRetired` option while preserving results-retirement precedence.
- Added bounded orphan execution-lock selection/removal with regular-file filtering, nonblocking exclusive lock, under-lock existence recheck, and inode recheck.
- Added messages-retired source rejection for rerun and resume. Resume needs the direct source check because a completed-session no-op does not invoke runner admission.
- Added focused lock, orphan cleanup, admission and CLI regression tests. New test fixtures use canonical repository-local `tmp/` roots.

## Verification

Final source checks:

| Command | Exit | Tests run | Failures | Complete log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SessionExecutionLockTests|SessionMessageRetentionAdmissionTests" > tmp/automatic-retention/ar-04-cli-lock-admission/test-rerun-002.log 2>&1'` | 0 | 14 | 0 | `tmp/automatic-retention/ar-04-cli-lock-admission/test-rerun-002.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionTests|WorkflowCommandScenarioTests" > tmp/automatic-retention/ar-04-cli-lock-admission/regression.log 2>&1'` | 0 | 11 | 0 | `tmp/automatic-retention/ar-04-cli-lock-admission/regression.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCommandTests.testSessionResumeUsesMockScenarioForCommandNodes" > tmp/automatic-retention/ar-04-cli-lock-admission/workflow-scenario-regression.log 2>&1'` | 0 | 1 | 0 | `tmp/automatic-retention/ar-04-cli-lock-admission/workflow-scenario-regression.log` |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-04-cli-lock-admission/changed-swift-files.nul` (Xcode toolchain environment set) | 0 | — | — | `tmp/automatic-retention/ar-04-cli-lock-admission/swiftlint-final.log` |

Earlier test attempts are retained as failure evidence: `test.log` exited 1 with 14 tests / 1 failure (test JSON date decoding setup); `test-rerun.log` exited 1 with 14 tests / 2 failures (resume bypassed admission for an already-completed session). The decoder was aligned to ISO-8601 and direct resume source rejection added; final source-matched rerun passed.

The exact changed Swift file list is NUL-delimited in `tmp/automatic-retention/ar-04-cli-lock-admission/changed-swift-files.nul`. Per-edit intent records and pre-edit snapshots are also in that evidence directory.

## Review handoff

Formal test-integrity and adversarial review, later shared documentation/index updates, exact-file staging, and local commit remain downstream workflow steps.
