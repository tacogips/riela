# instance-cancel-11: Nested-Riela process-tree cancellation regression (end to end)

**planId**: instance-cancel-11-nested-tree-e2e
**dependsOn**: instance-cancel-03-localprocess-tree, instance-cancel-06-event-serve-child
**Design Reference**: design-docs/specs/design-instance-cancel.md §2 counterexample, §3 C8, §5 (RielaCLITests nested-Riela regression)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-11-nested-tree-e2e.md
**Evidence root**: tmp/instance-cancel/instance-cancel-11-nested-tree-e2e/

## Intent

Prove the ART scenario end to end. An outer command-node wrapper launches a
nested `riela workflow run`, whose own command runs in a separate process
group. Cancelling one execution by sessionId must:

- reclaim every process of that execution before its session is terminal;
- record `cancelled` with the operator reason;
- leave a concurrent execution untouched.

## Non-goals

- Test-only. No source changes. If the test exposes a defect, record it in the
  progress log and stop: the owning plan (03 or 06) is repaired serially.

## File-level changes: Tests/RielaCLITests/InstanceCancelNestedTreeTests.swift (new)

- Locate the built `riela` binary exactly as
  `Tests/RielaCLITests/PrivateWorkflowTests.swift:764-771` does (Darwin:
  `Bundle(for:).bundleURL.deletingLastPathComponent()`; Linux:
  `CommandLine.arguments[0]`). If the binary is missing, `XCTSkip` with the
  message "run `swift build --product riela` first", and record that.
- Fixtures go in a temp dir:
  - The `inner` workflow bundle has one command node:
    `/bin/sh -c 'echo $$ > "$DIR/inner-$RUN.pid"; trap "sleep 1; exit 0" TERM; touch "$DIR/ready-$RUN"; while :; do sleep 1; done'`.
  - The `outer` workflow bundle has one command node, a wrapper:
    `/bin/sh -c 'trap "exit 0" TERM; echo $$ > "$DIR/wrapper-$RUN.pid"; "$RIELA" workflow run inner --workflow-definition-dir "$INNER" --session-store "$STORE/inner-$RUN" & echo $! > "$DIR/nested-$RUN.pid"; wait'`.
  - Copy the command-node JSON shape from an existing command-node fixture in
    `Tests/RielaCLITests` (search for `"command"` node kinds in workflow
    fixtures).
- Drive two outer runs, A and B, concurrently through a
  `DefaultEventLiveServer`-style path with a `LiveSessionCancelRegistry`:
  `runEventWorkflow` with `CLIEventWorkflowRunner`, set up the way
  `Tests/RielaCLITests/EventLiveServeCronTests.swift` builds the server.
  Capture the sessionIds through `onSessionStarted`.
- Wait for `ready-A` and `ready-B`, bounded at 60 s.
- Call `registry.requestCancel(sessionId: A, reason: "dup", actor: "rielaapp-api:default")`
  → `.cancelRequested`.
- Assertions:
  - A's run throws `EventOperatorCancelled`.
  - **Immediately at that return**, `kill(pid, 0) == -1 && errno == ESRCH`
    for `wrapper-A`, `nested-A` and `inner-A`. This proves the ordering.
  - A's root session in the temp store is `cancelled`, with failureKind
    `cancelled` and failureReason
    `operator_cancelled by rielaapp-api:default: dup`.
  - A's nested session in `STORE/inner-A` is terminal, `cancelled`. The inner
    command exits within 1 s of TERM, well inside the 5 s grace.
  - B's `inner-B` pid is alive and B's session is still `running`.
- Then cancel B and assert the same cleanup for B.
- `tearDown`: SIGKILL every recorded pid. The overall test timeout is 120 s.

## Verification (arm64 shell; tee to the evidence root)

- `swift build --product riela` → exit 0 (`build-riela.log`).
- `swift test --filter InstanceCancelNestedTreeTests` → exit 0, 0 failures,
  **not skipped** (`test.log` must show the test executed).
- `pgrep -f "while :; do sleep 1"` after the test → no output (`pgrep.log`).
- `swiftlint lint Tests/RielaCLITests/InstanceCancelNestedTreeTests.swift`
  → no violations.

## Done criteria

- The test passes without a skip.
- No leftover processes.
- Exactly 1 new file.
- The progress log has exit codes, log paths and the pgrep result.

## Drift protocol

Record pre/post sha256 of the new file.
