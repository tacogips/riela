# Issue 118: bounded fanout directory change evidence — implementation progress

Mode: `issue-resolution`. Issue: <https://github.com/tacogips/riela/issues/118>.
Plan: `impl-plans/completed/fanout-directory-change-tracking.md`.
Git branch: `fix/fanout-directory-change-tracking`; checkpoint HEAD:
`e947b5800206178388d1b05387bd35f330b18219`.
Step 6 status: implementation and author verification complete. Serial
reconciliation, test-integrity, adversarial and integration reviews are accepted;
final commit and non-force push remain downstream.

Serial reconciliation repaired the `comm-000021` integration finding. Independent
integration review accepted the revised tree before Git finalization.

## Assigned work and completion criteria

- T1 complete: immutable captures retain sorted unique declared roots; bounded,
  deterministic directory expansion records directories, hidden descendants and
  missing roots. Symlink, `.git`, traversal, special, unreadable and evidence
  recursion selections fail. Files retain bytes, hash and mode. File descriptors
  use `O_NOFOLLOW`; file and directory identity and membership are rechecked.
- T2 complete: reduce re-expands each record's declared roots and compares the
  sorted union of recorded/current paths. Added, removed, kind, directory
  membership and content/mode reasons retain branch, step and artifact attribution.
  Joined output contains no source bytes.
- T3 complete: 15 focused tests pass, covering exact files, nested/hidden/empty
  directories, overlaps, missing-root and kind transitions, membership, mode,
  unsafe and unreadable entries, deterministic mutation, capture/reduce limits
  and two dependency waves. The nested directory fixture asserts stored bytes
  for `tree/nested/deep` and its path-attributed reduce drift. The scale
  reproduction has 60 declared directories, 407 regular files, 467 unique
  entries and zero overlaps; a fresh wave-two actor reports an added file, removed
  file and parent membership drift. The original package manifest was not supplied.
- T4 complete: final-source focused tests, runner tests, selected-file SwiftLint,
  source build and diff check pass. Author self-review found and fixed bounded
  read and private artifact publication issues. No high/mid findings remain.

## Source identity and edit evidence

- `Sources/RielaCore/WorkflowFanoutChangeEvidence.swift`:
  SHA-256 `b1003ac9ce99098fbb0e9efb9a85192f9f7cf7ba514f39073104886567185ca7`.
- `Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift`:
  SHA-256 `f72bc60c3e00a4c11644f920911f31af6f8fe16253fd7ce842d6f042f7a8b2c3`.
- Before/after preimages, hashes and exact intentions for every edit are retained
  under `tmp/issue-118/fanout-directory-change-tracking/attempt-1/edit-1/`
  through `edit-16/`, then `attempt-2/edit-1/` through `edit-3/`.
  No concurrent writer drift was observed.
- Final source hash manifest:
  `tmp/issue-118/attempt-2/verification/source-sha256.txt`.

## Test-integrity revision

Communication `comm-000012` from `step6-test-integrity-check` did not accept
the first attempt. Its sole mid finding was missing proof that recursion captures
and compares a file inside a nested directory. The focused test now captures
`tree/nested/deep`, asserts its stored original bytes and nested child list,
confirms stable no-drift reduce, then changes its bytes and asserts an observation
with branch `a`, path `tree/nested/deep`, and reason `content-or-mode-drift`.
No production source change was needed. The finding is addressed for renewed
test-integrity review; this worker does not claim review acceptance.

## Final verification

All commands ran from the repository root in the foreground. Complete logs,
terminal exit files and command/cwd/source receipts live under
`tmp/issue-118/attempt-2/verification/`.

| Command | Exit | Result | Complete log |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowFanoutMapReduceTests` | 0 | 15 passed, 0 failed | `focused-test.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerFanoutTests` | 0 | 11 passed, 0 failed | `runner-fanout-test.log` |
| `changed_swift_manifest=tmp/issue-118/attempt-2/verification/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf '%s\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | both selected Swift files pass | `swiftlint.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | build complete | `swift-build.log` |
| `git diff --check` | 0 | no whitespace errors | `diff-check.log` |

The selected Swift manifest is
`tmp/issue-118/attempt-2/verification/changed-swift.nul`.
Attempt-1 passing logs and receipts remain under
`tmp/issue-118/attempt-1/verification/` as prior-source evidence.
The earlier `terminal-focused-test.log` run exited 1 before tests because
Foundation rejects `.atomic` together with `.withoutOverwriting`. That edit was
replaced by exclusive `0600` artifact creation. Earlier compile and assertion
failures are
retained in `focused-test.log`, `focused-test-rerun.log`, and
`focused-test-rerun-2.log`; subsequent runs resolved them.

## Design conformance and handoff

Integration review `comm-000021` found that replacing an ancestor with a symlink
after exact-file observation could preserve the final file's inode and bypass the
old ancestry check. Serial reconciliation added final ancestry checks for files
and directories and a deterministic exact-file and empty-directory regression.
The regression verifies rejection and no published artifact. The first repair
test run failed 1 of 16 tests because direct directory replacement returned a
retryable mutation before the ancestry policy check; its complete log and exit
receipt remain in `tmp/issue-118/reconcile-attempt-2/`. The final repair checks
live in `tmp/issue-118/reconcile-attempt-3/` with complete logs, terminal exit
receipts, changed-Swift manifest and source hashes:

| Command | Exit | Result | Complete log |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowFanoutMapReduceTests` | 0 | 16 passed, 0 failed | `tmp/issue-118/reconcile-attempt-3/focused-test.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerFanoutTests` | 0 | 11 passed, 0 failed | `tmp/issue-118/reconcile-attempt-3/runner-fanout-test.log` |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/issue-118/reconcile-attempt-3/changed-swift.nul` | 0 | both changed Swift files pass | `tmp/issue-118/reconcile-attempt-3/swiftlint.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | build complete | `tmp/issue-118/reconcile-attempt-3/swift-build.log` |
| `git diff --check` | 0 | no whitespace errors | `tmp/issue-118/reconcile-attempt-3/diff-check.log` |

Final Swift SHA-256 values: source
`b14b749b4f28f4cff798c4b6e7893a0d922874122e02075d5f4b515844c720c5`,
test `bcf2d274d65dcb8d139cee034bedeaf0b7118d7b96ef992de430383a20e1c49a`.

Step 7 adversarial and combined integration reviews accepted the reconciled tree
with no high or mid findings. Browser E2E was skipped because no browser-facing
file changed. The plan is archived before final commit; commit and non-force push
remain downstream workflow steps.

The implementation stays within the accepted directory snapshot design and the
three assigned write paths. No scheduler, schema, workflow, package or sibling
worktree changes were made. Node-boundary snapshots can miss transient writes
inside a single agent invocation, as the design states. Exact-file staging,
commit and non-force push remain for later workflow steps.
