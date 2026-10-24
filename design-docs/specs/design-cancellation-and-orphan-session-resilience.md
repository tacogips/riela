# Cancellation And Orphan Session Resilience

## Summary

An audit of the user-scope session store
(`~/.riela/sessions/runtime-records/runtime-message-log.sqlite`) for
2026-06-28 through 2026-07-02 found roughly 120 workflow sessions, of which:

- **68 step executions failed with `workflow run cancelled`** — every one of
  them caused by an external process kill (SIGTERM/SIGINT) of
  `riela workflow run`, not by a workflow or backend defect.
- **2 step executions failed with
  `policy_blocked: codex-agent authentication is unavailable: The operation
  couldn’t be completed. (Swift.CancellationError error 1.)`** — a
  cancellation misclassified as an authentication outage.
- **43 sessions are permanently stuck in `running`** — the CLI process died
  (or was hard-killed) without ever finalizing the session record, and
  nothing in the runtime ever reconciles them.

None of these three failure shapes is caused by the workflows themselves.
They are all gaps in how the Riela runtime models, reports, and recovers from
externally driven cancellation. This document analyzes the incidents and
proposes fixes. Related open issues #14 (child process-group cleanup on
cancel) and #15 (stale `currentStepId` in live persistence) are adjacent but
do not cover the gaps described here.

## Review Finding Traceability

| Audit finding | Design response |
|---|---|
| External `SIGTERM`/`SIGINT` is routed through `Task` cancellation and persisted as `failed` with `workflow run cancelled`, making driver timeouts indistinguishable from workflow defects. | P1 adds a first-class `cancelled` terminal status for sessions and step executions, updates the interrupted-run finalizer to persist cancellation metadata instead of failure, and requires status/GraphQL/JSONL/supervision surfaces to expose `cancelled`. |
| Adapter preflight catch-alls wrap `CancellationError` as `policy_blocked: ... authentication is unavailable`, leaving false auth incidents in supervision records. | P2 requires every codex, claude-code, and cursor-cli preflight path to rethrow `CancellationError` before policy/auth wrapping, adds a shared cancellation helper, and makes `agentPreflightErrorDetail` cancellation-safe as a defensive backstop. |
| Auto-improve treats cancellation as a failed attempt, burns remaining reruns during shutdown, records incidents, and creates rerun-session orphan cascades such as 141->142->143 and 148->149->150. | P3 makes auto-improve cancellation-aware: cancellation stops the loop immediately, records supervision `status: "cancelled"`, creates no incident/remediation/rerun cascade, and finalizes any already-created rerun session as `cancelled`. |
| Hard-killed runs can remain permanently `running`; there is no PID, heartbeat, passive reconciliation, or cleanup command for the 43 observed orphan sessions. | P4 adds `runnerPid`, `runnerHost`, and `heartbeatAt`, passive orphan detection when stores are opened, `session health` orphan reporting, and an active `riela session reconcile` sweep for dry-run and bulk cleanup. |
| Short-lived shell drivers have only foreground `workflow run`, so they kill long runs and then rerun from scratch instead of detaching and reattaching. | P5 adds detached execution (`workflow run --detach`) plus `session attach`/`wait` so drivers can launch, release the shell, poll or follow progress, and later reattach without killing the runner. |
| Existing issue #14 and #15 are open but do not cover these gaps. | The Related Issue Boundaries section keeps #14 limited to child process-group cleanup and #15 limited to stale `currentStepId`; this design only references them where the new cancellation/orphan model must avoid overlap. |

> **2026-10-24 (issue #27 resolution):** the section
> [2026-10-24 Contract](#2026-10-24-contract-issue-27) near the end of this
> document is authoritative. It records what is already done, what no longer
> applies (P3: auto-improve was removed), and the narrowed P1/P2/P4 contract.
> The text up to that section is the original 2026-07 analysis. Its file
> references to `Sources/CodexAgent`, `Sources/ClaudeCodeAgent`,
> `Sources/CursorCLIAgent` and `WorkflowRunCommand+AutoImprove.swift` describe
> code that no longer exists.

## Incident Evidence (2026-06-28 .. 2026-07-02)

### Wave 1 — codex-adversarial-implementation-review-loop, 06-29..06-30

25 failed sessions (35, 37–42, 44–46, 50, 52, 100–101, 106, 108–111,
113–114, 116, 127, 132, 136–137), all with failure reason
`workflow run cancelled`, working directory `<workspace>/riela`.
Total session durations cluster between ~150 s and ~750 s; the failed step is
whatever happened to be running when the driver killed the process
(`adversarial-review`, `fix-handoff`, `workflow-output`, `exit-gate`, ...).

### Wave 2 — codex-simple-work-package, 07-02 02:32..06:36

30 consecutive failed sessions (145–147, 150, 154–156, 158–162, 164–177,
179–185) in `<workspace>/kestra` and
`<workspace>/gmail-gateway`. From session 168 onward the failed
`implement` step consistently lasted **97–110 s** before
`workflow run cancelled`, and a new session was started every ~4 minutes.
This is the signature of an external driver (an agent loop invoking
`riela workflow run` through a shell tool with a ~2-minute timeout) killing
the run, observing "failed", and blindly retrying for four hours. Riela gave
the driver no signal that the failure was the driver's own timeout rather
than a workflow defect.

### Wave 3 — codex-design-and-implement-review-loop orphans, 07-02 08:21..10:29

Sessions 188–199 in `<workspace>/konjac` were each created
~10 minutes apart, each reached `step2-design-doc-update`, and each is still
`running` in the store. No failure was ever recorded: the process was killed
without the SIGTERM cancellation path completing (or with SIGKILL), so the
sessions were orphaned instead of marked. The same shape affects
`fable-and-improve-session-157`, `codex-simple-work-package-session-200`,
and 29 other sessions across the window.

### Supervised (auto-improve) cascade — sessions 141/142/143 and 148/149/150

The supervision records
(`~/.riela/sessions/runtime-records/codex-design-and-implement-review-loop-session-{143,150}/supervision-record.json`)
show the same three-act failure, twice, one day apart:

1. Attempt 1: the real run is killed externally → incident
   `workflow run cancelled` (sessions 141, 148).
2. Attempt 2: auto-improve immediately spawns a rerun session **while the
   surrounding task is already cancelled**; the rerun is created and never
   finalized → orphaned `running` session (142, 149).
3. Attempt 3: a second rerun's codex auth preflight throws
   `CancellationError`, which the adapter wraps as
   `policy_blocked: codex-agent authentication is unavailable: ...
   Swift.CancellationError error 1.` → a bogus "authentication outage"
   incident recorded 0 s after session creation (143, 150).

All three session records carry the same `updatedAt` second (e.g.
`2026-07-01T12:51:20`), confirming the entire 3-attempt supervision drama ran
during process shutdown.

### Reproduction queries

```bash
sqlite3 ~/.riela/sessions/runtime-records/runtime-message-log.sqlite \
  "SELECT session_id, status, updated_at FROM cli_workflow_sessions
   WHERE updated_at >= '2026-06-28' AND status = 'running' ORDER BY updated_at;"

sqlite3 ~/.riela/sessions/runtime-records/runtime-message-log.sqlite \
  "SELECT json_extract(json(record_json), '$.session.executions') FROM cli_workflow_sessions
   WHERE session_id = 'codex-simple-work-package-session-170';"
```

## Root Cause Analysis

### RC1 — External cancellation is recorded as an ordinary failure

`RielaSwiftCLI.main` installs a SIGINT/SIGTERM handler that cancels the run
task (`Sources/RielaCLI/EntryPoint.swift:15`,
`Sources/RielaCLI/CLISignalCancellation.swift`). The cancellation propagates
as `CancellationError` up to
`DeterministicWorkflowRunner` (`DeterministicWorkflowRunner.swift:307`),
which calls `markInterruptedSessionFailed`
(`DeterministicWorkflowRunner+Cancellation.swift:8`) and persists
`status = failed, failureReason = "workflow run cancelled"`.

`WorkflowSessionStatus` has no terminal state other than
`completed`/`failed` (`Sources/RielaCore/RuntimeSession.swift:3`), so an
interrupted run is indistinguishable — in `session status`, GraphQL, JSONL
output, and supervision records — from a genuine workflow failure. Every
downstream consumer therefore misreacts:

- auto-improve schedules a rerun remediation for a failure that no rerun can
  fix (the driver will kill the rerun too);
- external driver loops read `failed` and retry from scratch (Wave 2's 30
  retries) instead of resuming or extending their timeout;
- failure statistics and review workflows count infrastructure kills as
  workflow defects.

### RC2 — `CancellationError` is misclassified as an authentication outage

Every CLI agent adapter wraps its auth preflight in a catch-all that converts
*any* non-`AdapterExecutionError` into
`policy_blocked: <backend> authentication is unavailable: ...`:

- `Sources/CodexAgent/CodexAgentAdapter.swift:99-101` (injected preflight)
  and `:142-147` (default preflight);
- `Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift:119`;
- `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift:114`.

`agentPreflightErrorDetail` (`Sources/RielaAdapters/AdapterUtilities.swift:65`)
stringifies the error via `localizedDescription`, which for
`CancellationError` yields exactly the recorded incident text. A cancelled
task is thus reported as a *policy-blocked authentication outage*, which is
both wrong and actively misleading for auto-improve (it suggests re-login
remediation) and for humans triaging supervision records.

### RC3 — The auto-improve loop is not cancellation-aware

`runWithAutoImprove` (`Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift:21-37`)
loops `while supervisedAttempts < maxSupervisedAttempts` and its `catch`
converts *any* thrown error — including `CancellationError` — into a
"completed failed" outcome by loading the latest session. It never checks
`Task.isCancelled` before scheduling the next rerun. During shutdown this
burns all remaining attempts within one second, creating one orphaned
`running` session per rerun (RC4) plus a bogus auth incident (RC2), and
records supervision `status: failed` instead of "cancelled".

### RC4 — Hard-killed runs leave `running` sessions forever, with no reconciliation

`markInterruptedSessionFailed` only runs if graceful cancellation completes.
When the process is SIGKILLed (e.g. a driver's kill-after-grace escalation),
or when a rerun session is created during shutdown, the session record stays
`running` permanently. Nothing detects this afterwards:

- the session record carries no owning PID or heartbeat, so
  `session status`/`health`/`list` cannot distinguish "actively running" from
  "abandoned weeks ago";
- stall detection is opt-in (`--stall-timeout-ms`) and deliberately excludes
  CLI agent and official SDK backends, and in practice every observed
  supervision policy had `stallDetectionEnabled: false`;
- there is no sweep command and no on-open reconciliation.

43 abandoned `running` sessions accumulated in four days in one store.

### RC5 — No execution mode survives a short-lived driver

All observed kills came from agent drivers (Claude Code / fable-and-improve
style loops in kestra, gmail-gateway, konjac, riela) whose shell tool enforces
a 2–10 minute timeout, while realistic codex implement steps routinely need
longer. `riela workflow run` only offers foreground execution, so the driver
must hold a process for the entire workflow duration or kill it. Riela
already has `session resume`/`continue`/`rerun`, but a killed foreground run
plus a `failed`-not-`cancelled` status steers drivers toward full reruns
(Wave 2) instead of resumption.

## Proposed Improvements

### P1 — First-class `cancelled` terminal state (fixes RC1)

1. Add `case cancelled` to `WorkflowSessionStatus` and a parallel
   `case cancelled` to `WorkflowStepExecutionStatus` (or an
   `interruptionKind` field if step-level enum growth is too invasive).
2. `markInterruptedSessionFailed` becomes `markInterruptedSessionCancelled`:
   persist `status = cancelled`, keep a machine-readable reason
   (`signal: SIGTERM`, `parent task cancelled`), and set a signal-derived
   `exitCode` in `WorkflowRunResult` using the conventional `128 + signal`
   mapping (for example, SIGINT -> 130 and SIGTERM -> 143).
3. Surface the state everywhere status is read: `session status/progress/
   health`, GraphQL enums, JSONL `session_completed` events, supervision
   records.
4. **Compatibility**: issue #1 showed that installed older CLIs crash on
   unknown enum cases. Decoders in ClaudeCode/Codex/CursorCLI session
   indexes and RielaApp must decode unknown statuses leniently (fallback +
   raw string preservation) before any store starts writing `cancelled`.
   Gate the new value behind a store schema version bump if lenient decoding
   cannot be guaranteed for already-shipped readers.

### P2 — Never classify cancellation as an adapter policy failure (fixes RC2)

In each adapter preflight catch (codex ×2 paths, claude-code, cursor-cli) and
in `executeWithRetry`'s `normalizeError` callers, rethrow first:

```swift
catch let error as CancellationError {
  throw error
} catch let error as AdapterExecutionError {
  throw error
} catch {
  throw AdapterExecutionError(.policyBlocked, "... authentication is unavailable: ...")
}
```

Additionally, `agentPreflightErrorDetail` should defensively map
`CancellationError` to a stable `"preflight cancelled"` string so any future
catch-all cannot regress into the `Swift.CancellationError error 1.` text.
Add a shared helper (e.g. `rethrowIfCancellation(_:)` in `RielaAdapters`) so
all four call sites stay uniform, plus regression tests per adapter.

### P3 — Cancellation-aware auto-improve supervision (fixes RC3)

In `runWithAutoImprove`:

1. `catch let error as CancellationError` (and `Task.isCancelled` checks at
   the top of each loop iteration and before building a rerun request): stop
   immediately, finalize the current session as `cancelled`, and emit a
   supervision record with `status: "cancelled"` — no incident, no
   remediation, no further attempts.
2. Classify incidents: an attempt that ended `cancelled` must not append a
   `category: "failure"` incident nor a rerun remediation. This prevents the
   141→142→143 / 148→149→150 cascade and stops wasting supervised attempts
   on kills that will repeat.
3. Ensure any rerun session created before the cancellation arrived is
   finalized (cancelled) rather than left `running`.
4. Treat cancellation as a terminal supervision outcome, not as an
   auto-improve input: do not decrement or consume the remaining supervised
   attempt budget, do not invoke future supervision analysis/review prompts,
   and do not emit a remediation plan. The only persisted supervision summary
   should be the cancelled status plus the cancellation reason.

### P4 — Orphaned session detection and reconciliation (fixes RC4)

1. **Ownership metadata**: persist `runnerPid`, `runnerHost`, and
   `heartbeatAt` on the session record; the runner refreshes `heartbeatAt`
   on a coarse interval (e.g. every 15 s) piggybacked on existing store
   writes plus a timer.
2. **Passive reconciliation**: whenever a store is opened for
   `session status/progress/health/list` or a new `workflow run`, sessions
   that are `running` but whose PID is dead (same host) or whose heartbeat
   is older than a threshold are reported as `interrupted` and can be
   finalized to `cancelled` with reason `runner process lost`.
3. **Active sweep**: `riela session reconcile [--session-store <dir>]
   [--older-than <duration>] [--dry-run]` finalizes abandoned `running`
   sessions in bulk; `session health` gains an `orphaned` verdict. This also
   gives operators a cleanup path for the 43 existing orphans.
4. Extend heartbeat-based stall visibility to CLI agent backends now that
   response streaming (design-agent-response-streaming) provides live
   `lastBackendEventAt` content signals — "alive but silent for N minutes"
   becomes distinguishable from "runner gone".

### P5 — Detached execution for short-lived drivers (mitigates RC5)

Add `riela workflow run --detach`: fork a daemonized runner (setsid,
stdout/stderr to the session artifact root), print the session id + JSONL
handle immediately, and let drivers poll `session progress`/`status` or
future `session logs --follow`. Combined with P1, a driver with a 2-minute
shell timeout can launch, return, and re-attach instead of killing the run. The
existing `riela serve` / events daemon infrastructure can host the detached
runner lifecycle; scope here is only the CLI ergonomics
(`--detach`, `session attach|wait <session-id>` with an exit code mirroring
the terminal status).

Interim mitigation (documentation-level, no code): the packaged skills that
drive `riela workflow run` from agent shells should either run it in
background mode with polling, or set tool timeouts above
`--timeout-ms`, and should treat `workflow run cancelled` as
"do not blind-retry; resume instead".

## Out Of Scope

- Issue #14's child process-group TERM/KILL escalation (already tracked).
- Issue #15's `currentStepId` live-persistence staleness (already tracked;
  P4's heartbeat makes its symptom less misleading but does not fix it).
- Driver-side (Claude Code skill) retry-policy redesign beyond the interim
  documentation note in P5.
- RielaApp UI for the new `cancelled`/`orphaned` states beyond enum decoding
  compatibility (P1.4).

## Related Issue Boundaries

- **Issue #14 remains about process-tree cleanup**: terminating child
  processes, process groups, and TERM/KILL escalation when a run is cancelled.
  P1/P3 decide how the parent runtime records cancellation; P4 decides how to
  reconcile a missing parent runner. Neither replaces the child cleanup work.
- **Issue #15 remains about live `currentStepId` freshness**: stale progress
  display can still happen even when a runner is alive. P4's heartbeat makes
  "runner gone" detectable, but it does not redefine step-progress persistence
  or close #15.
- **This design owns the cancellation/orphan session contract**: cancelled
  terminal status, cancellation-safe adapter preflights, cancellation-aware
  auto-improve, PID/heartbeat orphan reconciliation, and detached execution.

## Suggested Phasing

1. **Phase 1 (small, high value)**: P2 + P3 — pure control-flow fixes with
   regression tests; removes bogus auth incidents and shutdown-time session
   spawning. No schema impact.
2. **Phase 2**: P1 — `cancelled` status with lenient-decoding groundwork and
   store schema gating.
3. **Phase 3**: P4 — ownership/heartbeat metadata, passive reconciliation,
   `session reconcile` sweep.
4. **Phase 4**: P5 — `--detach` / `attach` / `wait`.

## Test Plan Sketch

- Adapter tests: preflight throwing `CancellationError` propagates unchanged
  for codex/claude-code/cursor-cli (both injected and default preflight
  paths).
- Runner test: cancelling a run mid-step finalizes the session as
  `cancelled` with the signal reason and emits `session_completed` with the
  cancelled status.
- Auto-improve tests: cancellation during attempt N produces no new
  incidents/remediations, no new sessions, supervision `status: cancelled`.
- Store tests: lenient decoding of unknown session/step statuses in every
  SQLite index reader; reconciliation marks dead-PID `running` sessions
  `cancelled` and leaves live-PID sessions untouched.
- CLI test: `session reconcile --dry-run` reports the Wave 3 fixture shape
  without mutating records.

## 2026-10-24 Contract (issue #27)

Verified against the tree at `90d44521`.

### Status per proposal

| Item | State on the current tree | Action |
|---|---|---|
| P1 `cancelled` status | Not done. `WorkflowSessionStatus` (`Sources/RielaCore/RuntimeSession.swift:3`) and `WorkflowStepExecutionStatus` (`:11`) have no `cancelled` case. Cancellation finalizes through `finalizeInterruptedSessionFailed` (`DeterministicWorkflowRunner+Cancellation.swift:9`) into `status=failed, failureKind=cancelled` (`WorkflowSessionFailureKind.cancelled` already exists). | Implement as specified below. |
| P2 adapter preflight | The adapter files RC2 cites were removed: CLI agents now run in-process through `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`, which has no auth preflight catch-all. `executeWithRetry` already calls `rethrowIfCancellation` (`AdapterUtilities.swift:151`). `agentPreflightErrorDetail` (`:98`) maps `CancellationError` to `"preflight cancelled"` but has no callers. One gap remains: a cancelled host task makes the gateway turn end with `stopReason == .cancelled`, which is returned as an ordinary turn (`consumeGatewayTurn`, about line 307). An `ACPError` raised during cancellation is mapped to `providerError` (about line 312), and `executeWithRetry` only checks the error type, not `Task.isCancelled`. | Close the gateway gap (below). Leave `agentPreflightErrorDetail` as is, because it is a defensive helper and unrelated to this fix. |
| P3 auto-improve | Not applicable. Auto-improve supervision was removed (the `riela-auto-improve` skill is migration-only, and no `runWithAutoImprove` source exists). | None. |
| P4 orphan reconcile | Not done (no `session reconcile`). Ownership metadata already exists: `SessionExecutionLockRegistry` (`Sources/RielaCLI/SessionExecutionLock.swift`) holds an exclusive non-blocking `flock` on `runtime-records/execution-locks/<sessionId>.lock` for the whole life of every persisted runner (fresh run id reservation, resume/rerun admission, cross-workflow/fanout children through `sessionExecutionAdmission`). The kernel releases it when the process dies. Terminal retention already uses "acquire every family lock or treat the family as `executionLocked`" (`TerminalRetentionExecutor.swift:88-95`). | Implement reconcile on the flock predicate (below). Drop the `runnerPid`/`runnerHost`/`heartbeatAt` fields: flock liveness is exact for a local store and needs no heartbeat. |
| P5 detach/reattach | Not done. | Follow-up, out of scope for #27. |

### P1 contract: first-class `cancelled`

1. Add `case cancelled` to `WorkflowSessionStatus` and
   `WorkflowStepExecutionStatus`. Both enums get a tolerant `init(from:)`: an
   unknown raw value decodes as `.failed`, which is terminal and not resumable.
   That keeps stores written by a newer binary readable. The raw string is not
   preserved; that limitation is documented.
2. One choke point: `markSessionFailed` (every `WorkflowRuntimeStore`
   implementation) persists `status = .cancelled` when
   `input.failureKind == .cancelled`, and otherwise `.failed`. Its running
   executions become `.cancelled` or `.failed` under the same rule.
   `failureKind = .cancelled`, `failureReason` and `failedAt` (the terminal
   timestamp) are kept, so existing `failureKind` consumers keep working. The
   other handover trigger kinds (`stalled`, `leaseLost`) stay `failed`.
3. Every writer that today writes `failed` + `cancelled` writes `cancelled` +
   `cancelled` instead. That covers the runner finalizer, the handover
   trigger `.cancelled`, `TaskRunCancellation` operator moves (see item 8),
   and the Work Runtime prelaunch/joined cancellation in
   `Sources/RielaWork/WorkStore+Reservation.swift:523-575`.
4. Readers use one predicate, `WorkflowSession.isCancellation`. It is true when
   `failureKind == .cancelled` and `status` is either `.cancelled` or the
   legacy `.failed`. It replaces every `status == .failed && failureKind ==
   .cancelled` test, for example `WorkStore+Reservation.swift:523,566,619` and
   the pending-cancellation guard in
   `SQLiteWorkflowRuntimePersistenceStore.swift:834-836`. This is the only
   read tolerance for older stores; no rows are rewritten.
5. Terminal handling: `cancelled` is terminal everywhere `completed`/`failed`
   are. That includes `SessionObservability.isTerminal`, the persistence
   store's terminal-transition guard (about line 845), and the nested child
   terminal recording in `DeterministicWorkflowRunner+CrossWorkflow.swift`
   (`terminalChild.status == .failed` also accepts `.cancelled`). In
   statistics and exhaustive switches, `cancelled` counts as neither success
   nor failure, so infrastructure kills never inflate failure counts.
6. Recovery: rerun accepts `cancelled` sources, like the `failed`/`suspended`/
   `completed` set in `resolveRerunEntry`. Resume of a `cancelled` session
   stays terminal, the same as today's `failed`+`cancelled`. Making cancelled
   sessions resumable is a follow-up.
7. Surfaces: `session status/progress/list`, JSONL `session_completed` and the
   GraphQL status string all report `cancelled`. The `session list --status`
   filter (`SessionDiscoveryCommand.swift:57`), GraphQL status parsing
   (`RielaGraphQL.swift:156`) and web summaries
   (`SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift:107`) all parse
   through `WorkflowSessionStatus(rawValue:)`, so they accept `cancelled` with
   no extra code. The process exit code for a cancelled run stays `1`; the
   `128 + signal` mapping is a follow-up.
8. Write path: operator moves (`TaskRunCancellation.swift:191`) and the
   handover trigger reach the store through `request.cancellationCause` and
   `finalizeInterruptedSessionFailed`, so the rule in item 2 covers them. Only
   the Work Runtime's direct snapshot writes in item 3 need their own edits.

### P2 contract: gateway turn cancellation

- In `consumeGatewayTurn`, once the prompt stream ends: if `Task.isCancelled`
  is true and the deadline watchdog has not expired, throw `CancellationError`
  instead of returning the turn. A deadline expiry stays `.timeout`.
- In its `ACPError` catch, and in `executeWithRetry` before `normalizeError`:
  if `Task.isCancelled`, throw `CancellationError`. A cancelled task can then
  never be retried or reported as `providerError`, `policyBlocked` or
  `invalidOutput`.
- Test: an injected `AgentGatewayExecutorFactory` whose turn blocks until it
  is cancelled. Cancelling the host task yields `CancellationError` from the
  adapter, and at runner level the session ends `cancelled`, not
  `failed`/`adapterFailure`/`policyBlocked`.

### P4 contract: `riela session reconcile`

```text
riela session reconcile [--scope project|user | --session-store <dir>] [--working-dir <dir>]
                        [--session <id>]... [--apply] [--output text|json]
```

- Candidates: sessions whose canonical snapshot or CLI record has
  `status = running`, optionally restricted by `--session`. `created`
  sessions, which include durable reserved children waiting for a worker,
  and `suspended` sessions are never touched.
- Liveness predicate: try `SessionExecutionLockRegistry.acquire(sessionId:)`
  (non-blocking). `alreadyRunning` means **live**: skip and report `live`.
  `retiredSession` means skip and report `retired`. Success means **orphaned**.
- Default is a dry run. Each candidate is reported as `orphaned` or `live` and
  the lock is released immediately.
- With `--apply`, while still holding the lock, re-read the session. If it is
  still `running`, persist `status = cancelled`, `failureKind = cancelled`,
  `failureReason = "runner process lost; reconciled by riela session reconcile"`,
  and mark running executions `cancelled`. The CLI record and the canonical
  snapshot are written in the existing single-transaction
  `CLIWorkflowSessionStore.save(_:runtimeSnapshot:)`. Then release the lock. A
  save rejected by the persistence guards (for example a pending Work Runtime
  cancellation) is reported per session as `skipped` with the error. It does
  not abort the sweep.
- Output: `{ dryRun, sessions: [{ sessionId, workflowId, verdict: orphaned|live|retired|skipped, applied, reason? }] }`.
  The exit code is 0 unless the store cannot be opened.
- Nested children and nested invocation records are not rewritten. A parent
  resumed later sees a `cancelled` child terminal and fails closed through the
  existing guard.
- Scope boundary: flock liveness covers runners on the local host sharing this
  session store. A store on a network filesystem is unsupported, and the docs
  say so.
- Surface: new `SurfaceCatalog` CLI row `session.reconcile` (kind `.mutation`)
  with local-process exclusions for GraphQL/web/library. Regenerate the SDL
  only if the catalog-derived SDL changes.

### Tests (focused)

- Runner: cancelling a run mid-step persists session `cancelled`, the
  in-flight execution `cancelled`, and `session_completed` reports
  `cancelled`. A fanout or cross-workflow child cancelled with its parent is
  recorded as a `cancelled` terminal.
- Decoding: a stored row with an unknown status decodes as `failed`.
  Legacy `failed`+`cancelled` rows satisfy `isCancellation`.
- Work Runtime: the prelaunch/joined cancellation and acknowledge paths
  accept the new shape (existing Work cancellation suites stay green).
- Reconcile: a `running` session with no lock holder is reported, and with
  `--apply` becomes `cancelled`. A `running` session whose lock a live
  registry in the test holds is reported `live` and stays byte-identical
  (`record_json` unchanged). `created` and `suspended` sessions are untouched.
  A dry run mutates nothing.

### Follow-up (not part of #27 resolution)

- P5 detach/reattach (`workflow run --detach`, `session attach|wait`).
- Passive orphan reporting in `session status/health/list`.
- Resuming `cancelled` sessions; signal-derived exit codes.
- RielaApp/web UI treatment of `cancelled` beyond decoding the raw string.

## Design Evidence Checks

- The incident counts and session chains in this document come from direct
  SQLite/runtime-record inspection of
  `~/.riela/sessions/runtime-records/runtime-message-log.sqlite` and adjacent
  `supervision-record.json` files, not from a workflow-generated review.
- Re-run the reproduction queries above when validating the evidence against a
  live session store. They should still distinguish failed cancellation waves,
  false auth incidents, and abandoned `running` sessions.
- For markdown hygiene while this file is still untracked, use
  `rg -n '[[:blank:]]+$' design-docs/specs/design-cancellation-and-orphan-session-resilience.md`.
  After staging the file, use `git diff --check --cached -- design-docs/specs/design-cancellation-and-orphan-session-resilience.md`.
