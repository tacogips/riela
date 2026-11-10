# Instance control 05: events-serve admission gate and control frames (child side)

**Status**: Completed; accepted (code in checkpoint ca369733, recorded as acceptedDependency in `instance-control-dispatch.json`)
**planId**: instance-control-05-child-admission-gate
**dependsOn**: instance-control-01-contracts (`WorkflowServeAdmissionFrame`, `WorkflowServeAdmissionAcknowledgement`, `WorkflowServeAdmissionState`, `WorkflowServeAdmissionWire`); instance-control-04-cli-commands (resource ordering only: lane A `.build` ownership, see Amendment 2026-11-10)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 step 6 (child gate, wire contract, closed-gate behaviour, lease), step 8.1; §5 gate tests; §6
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-05-child-admission-gate/

## Intent and context

A reload that must replace the `riela events serve` child cannot rely on parent-side session snapshots, because a cron tick could be admitted between a check and `stop()`. This plan gives the child a serialized **admission gate**. Once `close` returns, no workflow run can start. The parent drives the gate through the existing private stdin/stdout channel (`--runtime-environment-channel`, `Sources/RielaCLI/RuntimeEnvironmentChannel.swift`).

Facts in the code today:

- Every live workflow entry passes `DefaultEventLiveServer.runEventWorkflow` (`Sources/RielaCLI/EventReadOnly.swift:27`). Cron runs reach it from `CronOverlapDispatcher.start` (`Sources/RielaCLI/EventCronOverlapDispatcher.swift:318-357`).
- Non-cron sources (telegram in `EventLiveServe.swift:584`, webhooky, slack, discord, matrix, file-change) call `runEventWorkflow` directly. Their failures go through `recordWorkflowDispatchFailure` (`EventLiveServe.swift:542`).
- The channel reader decodes **every** stdin line as `RuntimeEnvironmentChannelFrame` (`RuntimeEnvironmentChannel.swift`, `state.replace(frame)`) and writes back a `runtime-environment-ack`.

## Non-goals

- No change to environment-frame semantics, overlap policies, receipt formats beyond the new reason/status strings, or the CLI `events` commands.
- Do not open a channel for children started without `--runtime-environment-channel`.
- No parent-side code (plan 06).

## File-level changes

### Sources/RielaCLI/EventAdmissionGate.swift (new)

`actor EventAdmissionGate`:
- `init(clock: any EventServeClock)`.
- State:
  - `open: Bool = true`
  - `running: Int`, `queued: Int`
  - `closedRequestId: String?`
  - `leaseToken: Int`
- `func admit() throws`: if closed, throws `EventAdmissionClosed()`; otherwise `running += 1`.
- `func release()`: `running = max(0, running - 1)`.
- `func noteQueued(_ delta: Int)`: `queued = max(0, queued + delta)`.
- `func close(requestId: String, leaseSeconds: Int) -> WorkflowServeAdmissionAcknowledgement`:
  - sets `open = false` and stores the requestId;
  - starts the lease: a detached task sleeps on `clock` for `leaseSeconds`, then calls `expire(token:)`;
  - returns state `closed` with the current counts.
  - Closing an already-closed gate re-arms the lease with the new requestId.
- `func confirm(requestId:) -> Ack`:
  - state `closed` with counts, if closed with the same requestId;
  - otherwise state `expired` (lease expired or reopened) with counts.
- `func reopen(requestId:) -> Ack`: sets `open = true` and invalidates the lease; returns state `open`.
- `private func expire(token:)`: if the token is current and the gate is still closed → `open = true`, `closedRequestId = nil`, and log the safe code `admission_lease_expired` on stderr. That code is the only output.
- `struct EventAdmissionClosed: Error {}`.

**The key invariant.** `admit` and `close` run on the same actor, so a dispatch is either counted in the `running` returned by `close`, or refused.

### Sources/RielaCLI/EventReadOnly.swift

In `runEventWorkflow`, before `workflowRunner.runWorkflow(request)`:
- `try await admissionGate?.admit()`;
- `defer`-equivalent release after the run, on both success and throw.
- Use structured `do/catch` so release always runs. Do not release if `admit` threw.

The gate is an optional property on `DefaultEventLiveServer` (`admissionGate: EventAdmissionGate?`, nil when there is no channel). Add it in the server type declaration; find where `DefaultEventLiveServer` is declared in `EventLiveServe.swift`.

### Sources/RielaCLI/EventCronOverlapDispatcher.swift

- When a fire is enqueued (`scope.queue.append`), call `gate?.noteQueued(+1)`.
- When one is dequeued, superseded, discarded or cancelled, call `gate?.noteQueued(-1)`.
- In `submit`, before policy handling: if `await gate?.isClosed == true`, record a receipt with status `skipped` and reason `reload-handoff:<bindingId>` through the same write path as `recordRoutineGateSkip`. Imitate `CronOverlapReason` helpers by adding `static func reloadHandoff(_ bindingId:) -> String`. Return the existing skipped outcome. Do **not** enqueue.
- In the run task inside `start`: if `server.runEventWorkflow` throws `EventAdmissionClosed`, the run never started. `finish` must then write status `skipped`, reason `reload-handoff:<bindingId>`, not a failure. Leave the queue untouched.
- The dispatcher receives the gate through its init. It defaults to `nil` so existing tests compile.

### Sources/RielaCLI/EventLiveServe+Cron.swift

Pass the gate into the dispatcher construction. Edit this file only if the dispatcher is constructed here; otherwise edit `EventLiveServe.swift`.

### Sources/RielaCLI/EventLiveServe.swift

- Construct `EventAdmissionGate(clock:)` only when `parsed.runtimeEnvironmentChannel` is true. Use the same clock the serve loop uses.
- Hand the gate to the channel reader, the server and the dispatcher.
- `recordWorkflowDispatchFailure(...)` gains a trailing `envelope: ExternalEventEnvelope? = nil`. When `error is EventAdmissionClosed`:
  - write `lastIgnoredReason: "reload-handoff"` on the serve record;
  - emit telemetry name `riela.events.workflow.dispatch.rejected` with attribute `reason: reload-handoff`;
  - when `envelope != nil`, persist an `EventReceiptStore` receipt with status `"rejected"`, reason `"reload-handoff"` and the envelope.
  - Imitate `recordReadOnlyEventIfNeeded` (`EventReadOnly.swift`) for receipt id derivation (prefix `event-handoff-` + sha256 of `sourceId\0eventId`) and store usage, so `riela events replay <receiptId>` can re-dispatch it.
- The telegram call site in this file passes its envelope if one is in scope. If none is in scope, pass nil; the serve record still records the reason.

### Non-cron call sites: pass `envelope:` to `recordWorkflowDispatchFailure`

Edit only the call expression in:
- `Sources/RielaCLI/EventLiveServe+Webhooky.swift`
- `Sources/RielaCLI/EventLiveServe+Slack.swift`
- `Sources/RielaCLI/EventLiveServe+Discord.swift`
- `Sources/RielaCLI/EventLiveServe+Matrix.swift`

`Sources/RielaCLI/EventLiveServe+FileChange.swift`: check how its `runEventWorkflow` failure is handled. If it does not call `recordWorkflowDispatchFailure`, add an `EventAdmissionClosed` branch that calls it with its envelope. Otherwise just pass the envelope.

### Sources/RielaCLI/RuntimeEnvironmentChannel.swift

The frame-processing task must route by type **before** decoding as an environment frame:
- If `WorkflowServeAdmissionFrame.decodeControlLine(frame)` succeeds → call `close`, `confirm` or `reopen` on the gate. Use `leaseSeconds ?? WorkflowServeAdmissionWire.defaultLeaseSeconds`, clamped to 1...600.
- Write the encoded `WorkflowServeAdmissionAcknowledgement` line to stdout.
- If the gate is nil, reply with an ack of state `open` and counts 0. A parent without a gate never gets here, because a gate exists whenever the channel exists.
- Everything else follows the existing `state.replace(frame)` path, unchanged.

**Pitfall:** an admission frame must never reach `replace`. That would be treated as `environment_channel_invalid` and could close the channel.

## Tests

**Tests/RielaCLITests/EventAdmissionGateTests.swift (new)** — deterministic. Use `ManualEventServeClock` (`Tests/RielaCLITests/EventCronOverlapTests.swift:954`; reuse it, do not duplicate) and the fake runner and server setup from `EventCronOverlapTests`.

| Situation | Expected |
| --- | --- |
| Boundary race: 200 iterations of `async let a = gate.admit()` and `async let c = gate.close(...)` | each iteration either `admit` succeeded and `c.running == 1`, or `admit` threw and `c.running == 0` |
| After close: cron fire submitted to the dispatcher with a fake runner | the runner is never invoked; a receipt with status `skipped` and reason `reload-handoff:<binding>` exists |
| After close: a queued fire is dequeued when the running one finishes | the dequeued fire is never run and is recorded as skipped `reload-handoff` |
| Non-cron dispatch failure with `EventAdmissionClosed` and an envelope | a receipt with status `rejected`, reason `reload-handoff` exists, and `loadEventReceipt` succeeds for that id |
| `confirm` with matching requestId while closed and idle | state closed, running 0, queued 0 |
| Lease: close with lease 5, advance the manual clock 5 s | `confirm` → `expired`; a following `admit` succeeds |
| `reopen` | `admit` succeeds and the state is `open` |
| Channel routing: feed the reader an `admission-close` line followed by a runtime-environment frame | the first gets an `admission-ack` line; the second gets a `runtime-environment-ack`; the environment state is unaffected by the admission line |

For channel routing, imitate `Tests/RielaCLITests/RuntimeEnvironmentChannelTests.swift` pipes.

- No sleeps on wall clock; use the manual clock or awaits.
- Frames and acks never contain environment values: assert the encoded ack keys are exactly `type, requestId, state, running, queued`.

## Invariants

- With no channel there is no gate (nil), and behaviour is byte-identical to today.
- With an open gate, dispatch behaviour is unchanged apart from counter bookkeeping.
- Existing receipts and statuses are unchanged; only new reason/status strings are added.

## Verification (each exits 0; logs under the evidence root)

1. `mkdir -p tmp/instance-control/instance-control-05-child-admission-gate && arch -arm64 /bin/zsh -lc 'swift test --filter "EventAdmissionGateTests|EventCronOverlapTests|EventCronOverlapServeTests|RuntimeEnvironmentChannelTests" 2>&1 | tee tmp/instance-control/instance-control-05-child-admission-gate/test.log; exit ${pipestatus[1]}'`
   - 0 failures. Run it 3 times; keep `test-run{1,2,3}.log`.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/EventAdmissionGate.swift Sources/RielaCLI/EventReadOnly.swift Sources/RielaCLI/EventCronOverlapDispatcher.swift Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/EventLiveServe+Cron.swift Sources/RielaCLI/RuntimeEnvironmentChannel.swift Sources/RielaCLI/EventLiveServe+Webhooky.swift Sources/RielaCLI/EventLiveServe+Slack.swift Sources/RielaCLI/EventLiveServe+Discord.swift Sources/RielaCLI/EventLiveServe+Matrix.swift Sources/RielaCLI/EventLiveServe+FileChange.swift Tests/RielaCLITests/EventAdmissionGateTests.swift 2>&1 | tee tmp/instance-control/instance-control-05-child-admission-gate/lint.log; exit ${pipestatus[1]}'`

A compile error caused only by sibling files is recorded as `sibling-blocked` and re-run later. Never edit sibling files.

## Edit safety

- Fresh-read before each edit, and record the pre- and post-edit sha256.
- All listed files are owned only by this plan. Plan 04 owns other RielaCLI files; do not touch `InstanceCommands.swift`, `FileWorkflowInstanceStore.swift` or `RielaCLIApplication.swift`.

## Completion criteria

- [x] The gate is implemented and wired.
- [x] All the test situations above pass 3× consecutively.
- [x] Lint exits 0.
- [x] Progress log written.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.

## Amendment 2026-11-10 (blocked-wave-scope-or-contract, round 1)

**Blocker resolved.** The dispatch declared `artifactRoots: []`, while `swift test` writes SwiftPM build output to `.build`. This amendment authorizes build output in two serialized lanes. No design, contract, or source `writePaths` change.

**Lanes:**
- Lane A owns `.build`: plans 04 → 05 → 07 → 09 → 10.
- Lane B owns `tmp/instance-control/swiftpm-lane-b`: plans 03 → 08 → 06.

**This plan is in lane A, after 04.**
- `writePaths` and `artifactRoots` add `.build`.
- `dependsOn` adds `instance-control-04-cli-commands` for resource ordering only. There is no code dependency on plan 04, and plan 04's files must still not be edited.
- The verification commands in `## Verification` are unchanged and authorized as written.
- Write the three runs to `test-run1.log`, `test-run2.log` and `test-run3.log` (the dispatch manifest uses these names).

**Rules:**
- Never pass `--scratch-path`.
- Never touch `tmp/instance-control/swiftpm-lane-b`.
- Never run `swift package clean`, `reset`, `update`, or anything that rewrites `Package.resolved`.
- If dependency resolution fails, record `dependency-resolution` with the log path and stop.
- Wait on a held `.build` lock; never kill another SwiftPM process.
- Compile errors caused only by sibling files are `sibling-blocked` and rerun.
- The 3 consecutive green runs must all happen after the final source edit.

**Progress log.** Record the 3 run exit codes, the lint exit code, and the log paths.


### Implementation progress: 2026-11-10

The child gate, admission channel, workflow boundary, cron accounting and handoff receipts are implemented. The focused filter ran three consecutive times on the final Swift source: 41 tests, zero failures, exit 0 in each of `tmp/instance-control/instance-control-05-child-admission-gate/test-run1.log`, `test-run2.log`, and `test-run3.log`. HOME and RIELA_APP_ROOT were isolated under the plan evidence root. Required lint and strict changed-file lint both exited 0: `lint.log` and `strict-lint.log` in the same evidence root. Earlier compilation attempts and their corrections are retained in `test-attempt1.log` and `test-attempt2.log`. Formal integrity, adversarial and integration reviews remain downstream.

Continuation 1 resolved the receipt-save self-check: save errors now propagate; channel-managed Telegram and Discord advance offsets only after processing, and Slack regression checks that save failure leaves its cursor unchanged. Push-only and file-watch inputs surface the error and terminate the serve operation. Three final-source runs each passed 43 tests with zero failures in `continuation1/final-test-run{1,2,3}.log`; required and strict changed-file lint exited 0 in `continuation1/lint-final2.log` and `continuation1/strict-lint-final2.log`. Formal review and integration remain downstream.
