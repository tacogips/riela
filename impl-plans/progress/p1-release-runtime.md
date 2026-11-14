# p1-release-runtime — Step 6 implementation

Status: implementation complete on `fix/work-runtime-p1-release` at checkpoint
`32163111b6e9f31b91d1e95e535c115e9f798890`. Workflow mode:
`issue-resolution`. Issue reference: `tacogips/riela` Draft PR #113,
`comm-000002`. Execution: native Riela Step 6
`nested-v1-ebe75c1424ab76d16a615f4bb8377988c065f349f8f9400d76258cc8615358c1`,
fanout branch `p1-release-runtime`. Read-only Codex agents:
`/root/guard_investigation`, `/root/admission_investigation`; the Step 6
owner made every edit. No Git writes were performed.

## Assertion ledger and contract evidence

| Historical ID | Boundary | Implemented evidence |
| --- | --- | --- |
| 08 | Live inactivity | `WorkGuardDispatcherTests.swift` now persists a running task and latest attempt, a running runtime session/execution, and an observation matching its execution identity and heartbeat. The fail policy produces a stop decision, no pending rerun, and a failed task after cancellation acknowledgment. A stale heartbeat is rejected by `StaleInactivityObservation` without changing the task, attempt, decisions or pending reservation; only guard evidence written before the decision transaction remains. Contract: `Sources/RielaWork/WorkStore+Decisions.swift` live observation fence and `WorkStore+Reservation.swift` cancellation acknowledgment. |
| 19 | Admission | `DeterministicWorkflowRunnerAdmissionTests.swift` provides an explicit read-only codex-agent sandbox, verifies the callback's specific rejection and invocation, a created session with no executions, and zero adapter calls. A missing-sandbox control rejects during validation before session or callback. Contract: `Sources/RielaCore/DeterministicWorkflowRunner.swift` validation and admission order. |

The historical failures are recorded in
`tmp/work-runtime-p1-7a-native-a2-a5/plans/p1-dispatch/attempt-6/V5-comparison.json`
and `full-comparison.json`. No production contract change was needed.

## Edit evidence

Immutable per-edit preimages, intent, postimages, hashes and patches:
`tmp/p1-release-remediation/p1-release-runtime/edits/{admission-1,admission-2,guard-1,guard-2,progress-1}/`.
The final test-file SHA-256 values are:

- `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`:
  `2b9b5f7042cde9658fa7c3cd878a607a09f54f37e31e17c7e5cc8942c94e1cf1`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift`:
  `4bb83640b4b65cdca0ae5f5a401f9ee56eddad72ad644373cea64ee72d6ad2e2`

## Foreground verification

Command metadata records include UTC start/end, cwd, checkpoint revision,
working-tree diff SHA-256, complete log and terminal exit status under
`tmp/p1-release-remediation/p1-release-runtime/attempt-1/`. Xcode Swift
6.3.3 was selected with the plan's `DEVELOPER_DIR`, `SDKROOT`, `TOOLCHAINS`
and `PATH` values. The final focused/lint/diff receipts use working-tree
diff SHA-256 `b392107e7597858e74832e2b66c814ddbea891d4ccd3e545e7969608f2e921ae`.

| Command | Complete log / metadata | Exit | Result |
| --- | --- | ---: | --- |
| `swift test --scratch-path tmp/p1-release-remediation/p1-release-runtime/build --filter 'WorkGuardDispatcherTests\|WorkflowRunnerAdmissionTests'` | `attempt-1/focused-final.log`, `focused-final.json` | 0 | 16 tests passed, 0 failures, 0 skips |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/p1-release-remediation/p1-release-runtime/attempt-1/changed-swift.nul` | `attempt-1/lint-final.log`, `lint-final.json` | 0 | Exact two changed Swift files, no diagnostics |
| `git diff --check` | `attempt-1/diff-check.log`, `diff-check.json` | 0 | Clean diff |
| `swift --version` | `attempt-1/swift-version.log`, `swift-version.json` | 0 | Apple Swift 6.3.3 |

Prior receipts: `attempt-1/focused.log` / `focused.json` passed 16/16 before
the helper naming edit. `attempt-1/lint.log` / `lint.json` exited 1 with a
new `large_tuple` diagnostic at the guard helper; edit `guard-2` replaced
that tuple with a named fixture, after which lint and focused tests passed.

## Completion

- [x] R1 / ID 08: live persisted fixture, stop/failure semantics, no rerun,
  stale observation and transactional no-mutation regression.
- [x] R2 / ID 19: valid payload, specific admission callback rejection,
  created session and no adapter effect, invalid-payload control.
- [x] R3: assertion/contract ledger, immutable edit evidence and complete
  foreground verification logs with exit statuses and counts.

Downstream dependent integration owns broad combined-tree suites, independent
test-integrity/adversarial/integration reviews, shared release-readiness docs,
Draft PR #113 update, commit and non-force push. Those are pending and are
not part of this plan's Step 6 acceptance.
