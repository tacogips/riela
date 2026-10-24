# ISW-175 verification progress

## Session — 2026-10-24

Workflow mode: `issue-resolution`.
Issue reference: `tacogips/riela#175` (verify commits `64a4927f`, `b2543045`).
Codex-agent references: none assigned or used.
Review decision: accepted plan review `comm-000014`; no implementation/review findings were supplied for this verification plan.

### Findings

- Both commits are ancestors of `HEAD` (`1addb368f835fbcd2aa544644fc1c7cc48ef8e85`). `git show --stat --oneline --no-renames 64a4927f b2543045` confirmed the expected source/test changes.
- `AdapterUtilitiesTests` did not reach test execution. Initial compile failed on concurrently incomplete `WorkflowFailureDiagnostics`/`WorkflowModel` work; the one permitted retry failed because `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` changed during compilation. Both logs contain no XCTest `Executed N tests` line (`testsRun=0`, `failureCount=0` test cases observed).
- `WorkflowStepFailurePolicyTests` did not reach test execution. Initial compile stopped while shared Swift files were being modified; retry failed with unresolved `rerunCarriedInbox` in `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`. Both logs contain no XCTest `Executed N tests` line (`testsRun=0`, `failureCount=0` test cases observed).
- These failures are shared-tree readiness/build failures, not passing behavioral evidence. No files outside the permitted progress log and `tmp/` were edited by this plan. `git status --short` also shows concurrent changes in other plans and is included in final evidence.

### Verification evidence

| Command | exitStatus | testsRun | failureCount | Complete log |
|---|---:|---:|---:|---|
| `git show --stat --oneline --no-renames 64a4927f b2543045 && git merge-base --is-ancestor 64a4927f HEAD && git merge-base --is-ancestor b2543045 HEAD` | 0 | 0 | 0 | command output returned directly; `HEAD=1addb368f835fbcd2aa544644fc1c7cc48ef8e85` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter AdapterUtilitiesTests > tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities.log'` | 1 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStepFailurePolicyTests > tmp/issue-sweep-20261024/ISW-175-verify/failure-policy.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/failure-policy.log'` | 1 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/failure-policy.log` |
| Retry: `arch -arm64 /bin/zsh -lc 'swift test --filter AdapterUtilitiesTests > tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-retry.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-retry.log'` | 1 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-retry.log` |
| Retry: `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStepFailurePolicyTests > tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-retry.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-retry.log'` | 1 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-retry.log` |

### Blocker and resume criterion

```json
[
  {
    "blockedOn": "Sources/RielaCore/WorkflowFailureDiagnostics.swift and Sources/RielaCore/WorkflowModel.swift",
    "reason": "The initial AdapterUtilitiesTests build could not resolve WorkflowFailureDiagnostics while the shared #163 implementation was incomplete. Resume after the shared implementation is stable and the focused filter compiles."
  },
  {
    "blockedOn": "Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift",
    "reason": "The AdapterUtilitiesTests retry reported this input changed during compilation. Resume after concurrent edits stop and the file remains stable through a focused build."
  },
  {
    "blockedOn": "Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift and Sources/RielaCore/RerunCarryover.swift",
    "reason": "The WorkflowStepFailurePolicyTests retry could not resolve rerunCarriedInbox at the recovery call site. Resume after the shared #135 implementation is complete and compiles."
  }
]
```

Verdict: blocked; acceptance is incomplete because neither focused test suite produced behavioral test evidence. The plan's single retry allowance was used. Do not treat the failed builds as passing test evidence.

## Recheck — 2026-10-24

Workflow mode: `issue-resolution`.
Issue reference: `tacogips/riela#175` (verify commits `64a4927f`, `b2543045`).
Codex-agent references: none assigned or used.
Review decision: accepted plan review `comm-000014`; no implementation/review findings were supplied for this verification plan.

The focused suites were rerun after the shared #163/#135 implementation became buildable. Both commit ancestry checks still pass at `HEAD=1addb368f835fbcd2aa544644fc1c7cc48ef8e85`. `AdapterUtilitiesTests` passed 24 tests with zero failures, including `AdapterUtilitiesTests.testOutputContractEnvelopeNormalizesFlattenedWhenWithoutPayload` from `64a4927f`. The initial `WorkflowStepFailurePolicyTests` filter passed 4 tests, but did not select the `validationRejected` to `adapterFailure` assertion from `b2543045`; that assertion is in `RunnerNonTerminalStepFailureTests.testValidationRejectionOnLastAttemptStillFailsSession`. The broader filter below ran that case successfully. Earlier failed attempts remain recorded above as historical compile failures; fresh rechecks resolve those verification blockers.

| Command | exitStatus | testsRun | failureCount | Complete log |
|---|---:|---:|---:|---|
| `git show --stat --oneline --no-renames 64a4927f b2543045 && git merge-base --is-ancestor 64a4927f HEAD && git merge-base --is-ancestor b2543045 HEAD` | 0 | 0 | 0 | command output returned directly; `HEAD=1addb368f835fbcd2aa544644fc1c7cc48ef8e85` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter AdapterUtilitiesTests > tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-recheck.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-recheck.log'` | 0 | 24 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/adapter-utilities-recheck.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStepFailurePolicyTests > tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-recheck.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-recheck.log'` | 0 | 4 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-recheck.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowStepFailurePolicyTests|RunnerFailurePolicyTests|RunnerNonTerminalStepFailureTests" > tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-file.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-file.log'` | 0 | 12 | 0 | `tmp/issue-sweep-20261024/ISW-175-verify/failure-policy-file.log`; includes passed `RunnerNonTerminalStepFailureTests.testValidationRejectionOnLastAttemptStillFailsSession` |

Verdict: acceptance criteria met. Only the authorized progress log was changed by this plan; concurrent changes in other plans remain untouched. The active plan's completion checklist is kept unchanged because its write-ownership section authorizes only the progress log.
