# ISW-175: verify the cherry-picked #175 fixes

**Status**: Ready
**planId**: ISW-175-verify
**Issue**: https://github.com/tacogips/riela/issues/175
**Design Reference**: none (verification only; see design-docs/specs/design-rerun-input-carryover-and-finalization-evidence.md mapping note in the Step 2 output)
**dependsOn**: none (wave 1)
**Created**: 2026-10-24

## Intent and context

Two commits are already on `feat/issue-sweep-20261024`, and this plan proves
they work:

- `64a4927f` normalizes a flattened when-without-payload agent envelope in
  `Sources/RielaCore/AdapterContracts.swift`. Its test is in
  `Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift`.
- `b2543045` classifies exhausted output validation
  (`WorkflowPublicationError.validationRejected`) as `adapterFailure` in
  `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`. Its test
  is in `Tests/RielaCoreTests/WorkflowStepFailurePolicyTests.swift`.

`docs/output-contracts.md` already documents both. No source change is
expected.

## Non-goals

- Do not edit any file under `Sources/`, `Tests/` or `docs/`.
- Do not re-implement or amend the commits.
- Do not run the full `swift test`.

## Write ownership

- `impl-plans/progress/issue-sweep-20261024-175-verify.md`: the only file
  this plan writes.

## Tasks

1. Run `git show --stat 64a4927f b2543045` and confirm both commits are
   ancestors of `HEAD` (`git merge-base --is-ancestor <sha> HEAD`, exit 0).
2. Run the verification commands below. Logs go under
   `tmp/issue-sweep-20261024/ISW-175-verify/`.
3. Write the progress log. For every command, record the command,
   `exitStatus` (integer), `testsRun` (integer, from XCTest
   "Executed N tests"), `failureCount` (integer) and the log path.

## Verification commands

Run each from the repository root:

```
arch -arm64 /bin/zsh -lc 'swift test --filter AdapterUtilitiesTests > tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStepFailurePolicyTests > tmp/issue-sweep-20261024/ISW-175-verify/failure-policy.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/failure-policy.log'
```

Each run must show `exitStatus=0` and `failureCount=0`. Each must also run
the tests the commits added:

- `AdapterUtilitiesTests`: the flattened when-without-payload cases from
  `64a4927f`;
- `WorkflowStepFailurePolicyTests`: the validationRejected → adapterFailure
  assertion from `b2543045`.

## Failure handling

If a test fails, do not fix it in this plan. Record the failing test names
and the log path, and mark the plan blocked with a dependency object:
`{"blockedOn": "Sources/RielaCore/AdapterContracts.swift or DeterministicWorkflowRunner+Cancellation.swift", "reason": "..."}`.
Another worker's in-progress edit may cause a build failure in a file outside
this plan. In that case retry once after a short wait and record the drift.

## Completion criteria

- [ ] Both commits are confirmed ancestors of HEAD.
- [ ] Both focused filters exit 0 with failureCount 0, and the integer
      fields are recorded.
- [ ] The progress log is written. `git status --short` shows no changes
      outside the progress log and `tmp/`.

## Progress log expectations

`impl-plans/progress/issue-sweep-20261024-175-verify.md` contains one
session entry: date, commands, integer evidence fields, log paths and the
verdict.
