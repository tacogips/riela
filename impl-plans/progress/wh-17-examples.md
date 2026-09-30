# wh-17 examples progress

## Status

The three example bundles, catalog, parity assertions, answer flow, and presence flow are implemented on `feat/work-handover-and-takeover`. The orphan takeover flow exposes a task-dispatch runtime gap outside wh-17 write paths, so the second completion criterion remains incomplete and is blocked on the serial owner of those runtime files. No Git state changes were made.

## Plan criteria

- [x] Three examples include `workflow.json`, nodes, prompts, `mock-scenario.json`, `EXPECTED_RESULTS.md`, and `README.md`; catalog names are sorted, mock count is 43, and suspended examples are explicitly asserted by the parity loop.
- [ ] Answer and presence harness flows pass; the parity selection passes; all three workflows validate. The orphan harness exposes a runtime error during successor dispatch instead of completing takeover.

## Implementation notes

- `task-handover-answer` requests `q-deploy-target`, validates the `option` answer, resumes at `apply`, verifies the sealed digest after reload, checks imported `plan` history, and asserts the persisted `apply` input contains `arguments.delivered.handover.answer.option == staging`.
- `task-handover-presence` requests `userReachable`. The harness records a takeover request, verifies placement waits with no local traits, then completes with `.userReachable`.
- `task-handover-orphan` has no handover envelope in its plain mock flow. The harness simulates a never-launched owner, refuses force-orphan before expiry, seals the `ownerLost` packet, and checks fencing and takeover lineage. Without fabricating a terminal predecessor session, successor dispatch returns `task attempt has no durable terminal session for guard evaluation`; the task remains `verifying`. The accepted plan permits a never-launched owner, but it does not permit seeding a terminal session the dead owner did not write. The running-owner heartbeat failure and persisted `failed(leaseLost)` path are covered by wh-14 `TaskHandoverLeaseTests`.
- The `handover` envelope remains outside each node's business output schema. The answer mock uses the wire shape `{id,label}` for question options.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-17-examples/build-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/build-final.log'`: exit 0; log `tmp/work-handover/wh-17-examples/build-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverExampleTests|RielaExampleParityTests|TaskRuntimeExampleTests" > tmp/work-handover/wh-17-examples/focused-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/focused-final.log'`: exit 0; 34 tests, 0 failures (9 parity, 3 handover harness, 22 task runtime); log `tmp/work-handover/wh-17-examples/focused-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverExampleTests" > tmp/work-handover/wh-17-examples/harness-final-attempt.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/harness-final-attempt.log'`: exit 0; 3 tests, 0 failures; log `tmp/work-handover/wh-17-examples/harness-final-attempt.log`.
- `arch -arm64 /bin/zsh -lc 'for w in task-handover-answer task-handover-presence task-handover-orphan; do .build/debug/riela workflow validate $w --workflow-definition-dir examples; echo "validate $w exit=$?"; done > tmp/work-handover/wh-17-examples/validate.log 2>&1'`: exit 0; each workflow reports valid with no diagnostics and `validate ... exit=0`; log `tmp/work-handover/wh-17-examples/validate.log`.
- Selected-file strict SwiftLint used NUL manifest `tmp/work-handover/wh-17-examples/changed-swift-files.nul`; `xargs -0 swiftlint lint --strict --quiet --no-cache`: exit 0; final log `tmp/work-handover/wh-17-examples/swiftlint-final.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-17-examples/diff-check.log`.

## Earlier attempts and resolution

- `focused.log` used the initial parked scenarios and ended exit 1 (34 tests, 10 failures): answer question options were strings rather than `HandoverOption` objects; presence had no explicit takeover request; and the answer assertion used the wrong input snapshot key. Those fixture issues were corrected. The later `focused-final.log` (34/34) and `harness-final-attempt.log` (3/3) relied on a fabricated terminal session for the orphan predecessor and are not valid evidence that orphan takeover succeeds.
- `focused-attempt2.log` ended exit 1 before XCTest execution because the fixture referred to a nonexistent `Attempt.createdAt`; it was changed to use the predecessor lease `heartbeatAt` and the final harness and focused runs passed.
- `harness-attempt2.log` and `answer-diagnostic.log` preserve intermediate failures while correcting the input-snapshot assertion. The final harness and focused logs supersede them.
- Per-edit preimages, hashes, and intentions are under `tmp/work-handover/wh-17-examples/attempt-1/` through `attempt-11/`.

## Blocker

```json
{
  "dependency": "Task-dispatch/handover runtime owner: wh-16/wh-18 serial shared ownership or wh-20-reconcile repair authority",
  "evidence": "Without the fabricated predecessor session, successor guard evaluation rejects the fenced dead owner's non-terminal session at Sources/RielaCLI/TaskDispatch.swift:432-439 with 'task attempt has no durable terminal session for guard evaluation'; the task remains verifying.",
  "impact": "A dead owner's force-orphan takeover cannot complete. This leaves the wh-17 orphan harness acceptance criterion unmet.",
  "resumeCriterion": "The owning serial plan makes successor guard evaluation compatible with a fenced reconciled failed(leaseLost) predecessor without violating the R26 terminal-write guard; then rerun the orphan harness and full wh-17 focused selection."
}
```

## Integrity review rerun (2026-10-01)

- The high finding from `step6-test-integrity-check` communication `comm-000290` was addressed within wh-17 paths: removed the fabricated failed/leaseLost `WorkflowSession`, moved the revived-owner heartbeat assertion after the successor dispatch attempt, renamed the test without a completion claim, and corrected this progress record plus `examples/task-handover-orphan/EXPECTED_RESULTS.md`.
- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-17-examples/build-review-fix.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/build-review-fix.log'`: exit 0; log `tmp/work-handover/wh-17-examples/build-review-fix.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverExampleTests/testOrphanExampleFencesNeverLaunchedOwner" > tmp/work-handover/wh-17-examples/orphan-after-review.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/orphan-after-review.log'`: exit 1; 1 test, 2 assertions failed. The real successor dispatch reports `task attempt has no durable terminal session for guard evaluation`; the task remains `verifying`. Fence rejection, attempt lineage, and the `ownerLost` packet assertions pass. This log is current evidence of the unresolved runtime gap, not a passing acceptance gate.
- Selected-file strict SwiftLint: NUL manifest `tmp/work-handover/wh-17-examples/changed-swift-files.nul`; `xargs -0 swiftlint lint --strict --quiet --no-cache` exit 0; log `tmp/work-handover/wh-17-examples/swiftlint-review-fix.log`.
- The earlier `focused-final.log` and `harness-final-attempt.log` passed only with the removed synthetic session and are not evidence that orphan takeover completes. The prior parity, answer, and presence results remain historical; the final focused selection must be rerun after the runtime repair.

## Blocking dependency

The wh-17 orphan completion criterion remains unmet because the runtime behavior to repair is outside this plan's `writePaths`:

```json
{
  "dependency": "Task-dispatch/handover runtime owner: wh-16/wh-18 serial shared ownership or wh-20-reconcile repair authority",
  "evidence": "tmp/work-handover/wh-17-examples/orphan-after-review.log; Sources/RielaCLI/TaskDispatch.swift:432-439 rejects the fenced dead predecessor's non-terminal session with 'task attempt has no durable terminal session for guard evaluation'.",
  "impact": "Force-orphan takeover of a dead owner cannot complete; task state remains verifying.",
  "resumeCriterion": "The owning serial plan makes successor guard evaluation compatible with a fenced, reconciled failed(leaseLost) predecessor without violating the R26 terminal-write guard. Then rerun the orphan harness and the full wh-17 focused selection."
}
```
