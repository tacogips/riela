# Codex Unified-Exec Backend Event Blackout

## Summary

`codex-design-and-implement-review-loop-session-1092` was stopped by its
supervising operator at `step6-implement` after roughly nine minutes with no
recorded backend activity. The session record shows the step "stalled":
`backendEventCount: 2`, last event `turn.started` at `12:30:40Z`, terminal
`failureReason: "workflow run cancelled"` at `12:39:58Z`.

The step was not stalled. The codex rollout for the same window
(`<codex-home>/sessions/2026/07/03/rollout-2026-07-03T21-30-40-*.jsonl`) shows
codex working continuously from `12:30:48Z` to `12:39:46Z` — 45 tool calls
(42 `exec_command`, 3 `write_stdin`) reading the repo, editing, and running
`swift-frontend` verification commands. The cancellation killed an active,
healthy implementation turn twelve seconds after its latest tool call.

The stall verdict was an observability false positive with two stacked
causes:

1. **Codex-side blind spot.** With the `unified_exec` feature (stable,
   enabled by default in codex 0.142.5), command executions run inside
   persistent PTY sessions. Under a riela-spawned codex process these
   sessions never report completion — every command, including
   sub-second `sed` reads, returns `Process running with session ID <n>`
   at the `yield_time_ms` boundary, and an interrupt attempt fails with
   `Operation not permitted (os error 1)`. Because the command item never
   reaches `completed`, `codex exec --json` never emits
   `item.completed` for `command_execution` items, and
   `write_stdin`/poll calls emit no items at all. The entire working
   period is silent on the JSON event stream except `item.started`.
2. **Riela drops `item.started`.** `isCodexJSONEvent`
   (`Sources/CodexAgent/CodexAgentAdapter.swift`) whitelists
   `item.completed` but not `item.started`/`item.updated`, so
   `classifyCodexBackendEvent` and the `codexBackendEventType` fallback
   both return `nil` and the line is discarded before it reaches the
   backend event bridge. Codex emitted an `item.started`
   (`command_execution`, `in_progress`) for each of the 42 new commands
   during step6 — roughly one every 10–30 seconds — and riela discarded
   all of them. Recording them would have shown continuous activity and
   no stall diagnosis would have been made.

The same blindness affected every step of session 1092, not just step6:
steps 1–5 each recorded only `thread.started`, `turn.started`, the final
`agent_message` `item.completed`, and `turn.completed` — zero
`command_execution` events across the whole session despite heavy shell
usage. Step6 was merely the first step long enough for the silence to be
interpreted as a hang.

## Incident Evidence

Persisted execution record (project store,
`.riela/sessions/runtime-records/runtime-message-log.sqlite`,
`workflow_runtime_snapshots`):

```json
{
  "stepId": "step6-implement",
  "executionId": "step6-implement-attempt-1-exec-9",
  "status": "failed",
  "failureReason": "workflow run cancelled",
  "backendEventCount": 2,
  "lastBackendEventType": "turn.started",
  "lastBackendEventAt": "2026-07-03T12:30:40Z",
  "createdAt": "2026-07-03T12:30:40Z",
  "updatedAt": "2026-07-03T12:39:58Z"
}
```

Codex rollout for the same execution (timestamps UTC): first reasoning at
`12:30:48`, then an unbroken sequence of `function_call` /
`function_call_output` pairs until `12:39:46`. Tool-call histogram:
`42 exec_command`, `3 write_stdin`. All 42 `exec_command` calls carried
fresh `cmd` values (no `session_id` reuse), so each produced a new
`command_execution` item — and therefore an `item.started` on stdout.

## Reproduction

A minimal single-step codex workflow (three `echo`/`ls` commands) run
through `riela workflow run` (riela 0.1.15, codex-cli 0.142.5) reproduces
the blackout deterministically:

- Recorded backend events: lifecycle pair, one `item.completed` (the
  skills-budget `error` item), two `agent_message` items, `turn.completed`.
  No command activity, a 24-second silent window while the commands ran.
- The codex rollout shows the tool output for the already-finished
  commands as `Wall time: 10.0007 seconds / Process running with session
  ID 25082`, followed by the model polling with `write_stdin` and a failed
  Ctrl-C (`Unified exec process failed: Operation not permitted (os error
  1)`).
- Running the identical prompt with identical flags via `codex exec
  --json` directly (same model, stdin transport, non-tty stdout) emits
  `item.started` + `item.completed` for `command_execution` items,
  confirming the events exist on the stream riela reads.
- Re-running the riela workflow with the node variable
  `"codexAdditionalArgs": ["--disable", "unified_exec"]` restores full
  observability: one `tool`-channel `item.completed` per command was
  recorded end-to-end through the riela event pipeline.
- Running the riela workflow outside any sandbox reproduces the blackout
  unchanged, ruling out the invoking sandbox as the cause. The
  non-completing unified-exec session was also observed in an unrelated
  non-riela codex session on the same machine, so completion detection is
  at least partly an upstream codex issue; riela's spawn environment
  (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`, no controlling TTY) makes
  it consistent.

## Root Cause Classification

- Riela bug (fixable here): `item.started`/`item.updated` are silently
  discarded by the codex event classifier. With unified exec active they
  are the only per-command signal on the stream, so discarding them turns
  a degraded signal into a total blackout.
- Upstream codex limitation (track, work around): unified-exec sessions
  that never report completion suppress `command_execution`
  `item.completed` events entirely; `write_stdin` activity is never
  represented on the `exec --json` stream.
- Operational gap: the operator-facing record gave a supervisor no way to
  distinguish "backend silent because hung" from "backend silent because
  the event stream has a blind spot", so the supervising session cancelled
  a healthy run.

## Proposed Fixes

### P1 — Record `item.started` / `item.updated` (riela bug fix)

In `Sources/CodexAgent/CodexAgentAdapter.swift`:

- Add `item.started` and `item.updated` to `isCodexJSONEvent`.
- Extend `classifyCodexContentEvent` to classify them: for
  `command_execution` / `tool_call` items, emit a `tool`-channel event
  with `eventType` preserved (`item.started`), `toolName`, and a
  truncated `item.command` as `contentSnapshot`; for other item types fall
  through to the existing lifecycle classification.
- Keep them out of `streamedResponseText` (they are not assistant
  content); `updateStreamedResponseText` already filters on the
  `assistant` channel, so no change is needed there.

Effect on the incident scenario: step6 would have recorded ~42 tool events
across the nine minutes (one per new command), `lastBackendEventAt` would
have tracked within ~30 seconds of wall clock, and both `session status`
and the agent-silence monitor would have reported an active backend.

Risk: low. Event volume rises by roughly one event per command; the
existing per-execution `recentBackendEvents` cap (100) and the
`BackendEventCoalescer` already bound memory and chatter.

### P2 — Make unified exec configurable for codex-agent nodes

`--disable unified_exec` is verified to restore reliable per-command
`item.completed` events through the whole riela pipeline. Options, in
increasing order of aggressiveness:

1. Document `"codexAdditionalArgs": ["--disable", "unified_exec"]` as the
   observability workaround in the codex-agent node reference and the
   troubleshooting guide (no code change).
2. Add a first-class node/CLI knob (e.g. `codexUnifiedExec: false`) that
   maps to `--disable unified_exec`, so workflows do not need to know the
   raw codex flag.
3. Default codex-agent nodes to `--disable unified_exec` until the
   upstream completion-detection issue is resolved, with an opt-back-in
   variable.

Recommendation: (1) immediately, (2) alongside P1. Defaulting (3) changes
backend behavior underneath users (unified exec is codex's intended
execution path and persists shell state across commands), so it should
wait for evidence that P1 alone is insufficient in practice.

### P3 — Fold the blind spot into stall/silence semantics

- The agent-silence warning (`--agent-silence-warning-ms`, default 120s)
  should mention the known blind spot for codex unified exec in its
  message or docs: "no backend events" from a codex-agent step is weak
  evidence of a hang while P1 is not deployed and remains weak evidence
  during `write_stdin`-driven interactive phases even after P1.
- The troubleshooting reference should instruct operators to check the
  codex rollout (`<codex-home>/sessions/<date>/rollout-*.jsonl`, matchable by
  the step's `createdAt` timestamp) before cancelling a "silent"
  codex-agent step. That check is what proved session 1092 healthy.

### P4 — Upstream report (tracking)

File a codex-cli issue: unified-exec sessions spawned from a
non-interactive, process-group-isolated parent never transition to
completed (`Process running with session ID <n>` for finished commands;
`write_stdin` interrupt fails with `EPERM`), which suppresses
`command_execution` item completion events on `codex exec --json`.
Include the riela spawn characteristics (`POSIX_SPAWN_SETPGROUP`, piped
stdio, no controlling TTY) and the direct-invocation contrast.

## Validation Plan

- Unit: classifier tests for `item.started`/`item.updated`
  (`command_execution`, `tool_call`, unknown item types) asserting
  channel, toolName, and content truncation; regression test that
  `streamedResponseText` is unaffected.
- Integration (mock runner): feed a captured unified-exec stdout fixture
  (lifecycle + `item.started`-only) through `LocalAgentCommandAdapter`
  and assert the recorded event sequence and `lastBackendEventAt`
  progression.
- Manual: re-run the minimal event-probe workflow with unified exec
  enabled and confirm per-command `item.started` tool events appear in
  `session status --output json`; re-run with `--disable unified_exec`
  and confirm `item.completed` tool events still classify as before.
