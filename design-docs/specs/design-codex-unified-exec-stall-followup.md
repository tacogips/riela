# Codex Unified-Exec Stall Follow-Up And Session-Store Read-Only Open Failure

## Summary

`codex-simple-work-package-session-514` (2026-07-05, riela 0.1.16,
working directory `<workspace>/konjac`, user-scope session
store) appeared stalled to its supervising operator during the
`implement` step and again during the `review` step. The session
completed successfully at `11:43:26Z`, so unlike the session-1092
incident (`design-codex-unified-exec-event-blackout.md`) no healthy run
was cancelled — but each codex step wasted 2–2.5 minutes in silent
polling loops, and the operator's `riela session status` diagnosis
command failed with an opaque
`sqliteFailed("unable to open database file")`, leaving the operator
unable to confirm whether the run was alive.

This document records the two root causes and proposes fixes. It is a
follow-up to `design-codex-unified-exec-event-blackout.md`: the P1 fix
from that document (record `item.started`/`item.updated`) shipped in
0.1.16 and worked as designed — the operator could see codex probing
regex cases live. Session 514 is the evidence that P1 alone is not
sufficient, which that document explicitly said should trigger the
deferred P2 option 3 (default `--disable unified_exec`).

## Incident Timeline (all times UTC)

From the persisted execution record (user store
`<home>/.riela/sessions/runtime-records/runtime-message-log.sqlite`,
`cli_workflow_sessions`) and the codex rollout
(`<home>/.codex/sessions/2026/07/05/rollout-2026-07-05T20-35-52-*.jsonl`,
filename in JST):

- `11:35:52` `implement` step starts; codex `thread.started`.
- `11:36:02` codex issues four commands (`git status --short`,
  `git diff -- <scoped files>`, two `sed -n '1,260p'` reads) via
  unified exec, `yield_time_ms: 10000`.
- `11:36:12` all four return **full output** but report
  `Process running with session ID <n>` — the unified-exec sessions
  never transition to completed, even though the underlying commands
  (sub-second `sed` reads) finished long before the 10 s yield window.
- `11:36:16 → 11:38:16` the model polls each of the four sessions with
  `write_stdin` (`yield_time_ms: 30000`), sequentially: 4 × 30 s = 2
  minutes of wall clock during which codex emits **no items at all** —
  the riela event stream is structurally silent (`write_stdin` polls
  are not represented on `codex exec --json`, per the blackout doc).
- `11:38:19` the model sends Ctrl-C to all four sessions; every attempt
  fails with `Unified exec process failed: Operation not permitted
  (os error 1)`.
- `11:38:23 → 11:38:54` the model investigates its own execution
  environment (`ps | rg 'git status|git diff|sed -n|…'`, `pwd`,
  `exec ruby -e 'puts "ok"'` — which also reports `Process running`
  after 10 s despite printing `ok`).
- `11:39:15 → 11:40:24` the model adapts (treats output-with-running
  status as completion), finishes the review probes, completes the
  turn. Step total: 4.5 minutes, of which ~2.5 minutes were pure
  polling waste.
- `11:40:25 → 11:43:02` `review` step repeats the same pattern from
  scratch (`ps -p <pids>` on its own stuck commands, switch to
  `/bin/bash -c`), because each step is a fresh codex thread that must
  re-learn the broken completion detection.
- `11:43:26` `workflow-output` completes; session succeeds.

The `agent-silence-warning` (default 120 000 ms) fired once during the
implement step's 141-second silent window, then its monitor task
exited — it is one-shot per execution
(`Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`,
`startAgentSilenceMonitorIfNeeded` returns after the first emission).

## Root Cause 1 — Unified exec still enabled by default

The blackout document classified non-completing unified-exec sessions
as an upstream codex limitation and verified that
`--disable unified_exec` restores per-command `item.completed` events
end-to-end. Riela 0.1.16 ships the opt-out knob
(`codexUnifiedExec: false` node variable →
`codexUnifiedExecArguments`,
`Sources/CodexAgent/CodexAgentAdapter.swift:229-234`) but the default
keeps unified exec enabled. Consequences of the default, observed in
session 514 with P1 observability fully working:

- Every command, however fast, costs at least its `yield_time_ms`
  (10 s floor observed on every `exec_command`).
- Every parallel command batch degrades into sequential
  30-second `write_stdin` polls that are invisible on the event
  stream — the exact silent windows that read as stalls.
- Interrupts fail (`EPERM`), so the model cannot even clean up.
- Every step pays the cost again; nothing is learned across steps.

This affects every codex-agent step of every workflow run through
riela on this codex version (0.142.5+ with unified_exec stable),
i.e. it is the common-case behavior, not an edge case.

### Decision

Flip the default: codex-agent nodes pass `--disable unified_exec`
unless the node explicitly opts back in with `codexUnifiedExec: true`.
This is P2 option 3 from the blackout document, now justified by the
evidence threshold that document set ("wait for evidence that P1 alone
is insufficient in practice"). Trade-off accepted: unified exec's
shell-state persistence across commands is lost by default; workflows
that need it can opt back in per node.

Semantics of the `codexUnifiedExec` node variable after the change:

| Variable value | Arguments passed |
| -------------- | ---------------- |
| unset          | `--disable unified_exec` (new default) |
| `false`        | `--disable unified_exec` (unchanged) |
| `true`         | none — codex's own default (unified exec on) |

Non-goals: no change to `codexAdditionalArgs` passthrough; upstream
codex completion-detection issue remains tracked separately (P4 of the
blackout document).

## Root Cause 2 — Read-only session-store open fails on idle WAL databases

While session 514 was running, the operator (a Claude Code session in
the riela repo) ran:

```
riela session status codex-simple-work-package-session-514 --output json
→ {"error":"sqliteFailed(\"unable to open database file\")","exitCode":1}
```

The failure was cwd-dependent and time-dependent, which made it look
nondeterministic. The actual chain:

1. Riela session stores are WAL-mode SQLite databases
   (`SQLiteDatabase.configure` runs `PRAGMA journal_mode=WAL` on
   writable opens, `Sources/RielaSQLite/SQLiteDatabase.swift`).
   A cleanly-closed WAL database has no `-shm`/`-wal` sidecar files.
2. Read paths open the store with `SQLITE_OPEN_READONLY`
   (`CLIWorkflowSessionStore.openDatabase(readOnly: true)`,
   `Sources/RielaCLI/CLIWorkflowSessionStore.swift:270-277`).
   SQLite cannot open a WAL database from a read-only connection
   unless the `-shm` file already exists (or another read/write
   connection is active): the wal-index cannot be created read-only.
   `sqlite3_open_v2` itself succeeds; the first statement
   (`tableExists` querying `sqlite_master`) fails with
   `SQLITE_CANTOPEN` — message `unable to open database file`,
   **without the database path**, because the path-bearing error
   message is only built in `SQLiteDatabase.open`
   (`Sources/RielaSQLite/SQLiteDatabase.swift:131-140`), not on
   statement errors.
3. With `--scope auto` and no explicit store,
   `CLIWorkflowSessionResolution.loadPersistedSession` searches
   project scope then user scope, but only continues past `.notFound`;
   any other error — including this CANTOPEN — aborts the whole search
   (`Sources/RielaCLI/CLIWorkflowSessionResolution.swift:69-78`).

In the incident: the riela repo's own project store
(`.riela/sessions/runtime-records/runtime-message-log.sqlite`, idle
since Jul 4, WAL mode, no `-shm`) failed the read-only open at the
project-scope stage, so the lookup never reached the user store where
session 514 actually lived. From the konjac cwd (no project store) the
same command succeeded. The "time-dependent" recovery was an artifact
of diagnosis: a read/write `sqlite3` CLI session against the project
store recreated the `-shm`/`-wal` sidecars and left them behind, after
which read-only opens succeeded.

Reproduction (deterministic):

```
# any store whose runtime-message-log.sqlite is WAL with no -shm
python3 -c "import sqlite3; sqlite3.connect('file:<db>?mode=ro', uri=True).execute('select 1 from sqlite_master')"
# → sqlite3.OperationalError: unable to open database file
```

### Decision

Three independent fixes, all in riela:

1. **WAL-safe read opens.** When a read-only open is requested and the
   database file exists, recover from `SQLITE_CANTOPEN` on the first
   statement (or proactively, when the file is writable by the
   process) by reopening read/write without schema mutation. A
   read/write open creates the wal-index and behaves identically for
   SELECT-only usage. Keep read-only as the first attempt so
   genuinely read-only filesystems still work when `-shm` exists.
2. **Scope-search resilience.** `loadPersistedSession` records a
   store-level open/query failure, continues to the next scope, and
   only surfaces the failure if the session is found nowhere — then
   with per-store detail ("project store failed: <path>: <error>;
   user store: not found").
3. **Path-bearing errors.** Statement-level SQLite errors wrap the
   database path (the `SQLiteDatabase` already stores `path`) so an
   operator sees which file failed, not a bare `unable to open
   database file`.

## Root Cause 3 (contributing) — Silence signal is one-shot and context-free

The one-shot `silence_warning` fired 21 seconds before codex resumed
visible activity, and never fired again. During `write_stdin` polling
phases the stream is silent by construction (upstream), so the
warning is the operator's only signal, and it currently:

- does not repeat, so a supervisor cannot distinguish "warned once,
  then recovered" from "warned once, still dead 10 minutes later";
- carries no hint that codex unified exec has a known blind spot
  (P3 of the blackout document proposed documenting this; the message
  itself is the more effective channel).

### Decision

- Re-arm the silence monitor after each emission instead of exiting:
  emit at threshold, then repeat every threshold interval with
  cumulative `silentForMs` (bounded: monitor still stops when the
  execution leaves `running`).
- Include machine-readable staleness in `session status` output:
  `lastBackendEventAt` already persists; add derived
  `backendSilentForMs` to the status projection so supervisors can
  poll status instead of scraping jsonl.

With Root Cause 1 fixed, silent windows should be rare in the default
configuration; this fix covers opted-back-in unified exec nodes and
any future backend blind spot.

## Fix Priority

| # | Fix | Kind | Effect |
| - | --- | ---- | ------ |
| 1 | Default `--disable unified_exec` | behavior default | removes the stall itself (per-command 10 s floor, 30 s poll loops, EPERM interrupts) |
| 2 | WAL-safe read-only store opens + scope-search resilience + path in errors | bug fix | `session status` works while/after runs regardless of cwd; diagnosis no longer blocked |
| 3 | Repeating silence warnings + `backendSilentForMs` in status | observability | supervisors can tell recovered-after-warning from still-silent |

## Validation Plan

- Unit: `codexUnifiedExecArguments` truth table (unset/`false` →
  disable, `true` → empty).
- Unit: read-only open fallback — fixture WAL database without `-shm`
  opens and serves queries through `CLIWorkflowSessionStore.load`;
  assert no schema mutation and that `-shm` left behind by the
  fallback does not break subsequent read-only opens.
- Unit: `loadPersistedSession` continues past a corrupt/unopenable
  project store and finds the session in the user store; error detail
  lists both stores when found nowhere.
- Unit: silence monitor emits repeatedly at threshold intervals and
  stops when execution completes.
- Integration: mock-scenario run asserting `session status --output
  json` includes `backendSilentForMs` for a running execution.
- Manual: from a cwd whose project store is an idle WAL database, run
  `riela session status <user-store-session>` and confirm success;
  run a codex-agent workflow and confirm rollout shows plain
  `exec_command` completions (no `Process running with session ID`)
  under the new default.

## References

- `design-docs/specs/design-codex-unified-exec-event-blackout.md`
  (session-1092 incident; P1–P4)
- Incident session: `codex-simple-work-package-session-514`
  (user store, 2026-07-05)
- Codex rollouts:
  `~/.codex/sessions/2026/07/05/rollout-2026-07-05T20-35-52-*.jsonl`
  (implement), `rollout-2026-07-05T20-40-25-*.jsonl` (review)
- SQLite WAL read-only limitation: https://sqlite.org/wal.html
  ("Read-Only Databases")
