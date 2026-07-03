# Output Step Tool-Use Stall

## Summary

`codex-simple-work-package-session-201` (2026-07-02) completed its
`implement` and `review` steps normally, then sat silent for 4.5 minutes in
the final `workflow-output` step until the operator interrupted the run. The
step's only job is to reformat data it already received into a final JSON
document, yet it runs as a full tool-enabled codex agent with
`danger-full-access` sandboxing. The agent chose to shell out, its exec
session hung, its interrupt attempt failed with `EPERM`, and it fell back to
a 5-minute blocking wait — during which Riela surfaced no signal that
anything was wrong.

This is not an isolated event: `workflow-output`-step failures also appear in
the 06-28..07-02 audit (codex-simple-work-package session 145;
codex-adversarial-implementation-review-loop sessions 35, 38, 40), always as
the step that happened to be running when an external kill arrived. Final
output steps are disproportionately slow and silent for what they do.

Related: `design-cancellation-and-orphan-session-resilience.md` covers how
the interrupt was then recorded (`failed` / `workflow run cancelled` instead
of `cancelled`). This document covers why the step stalled in the first
place.

## Incident Timeline (session 201, times UTC)

Sources: `cli_workflow_sessions` record in
`~/.riela/sessions/runtime-records/runtime-message-log.sqlite`; codex rollout
`~/.codex/sessions/2026/07/02/rollout-2026-07-02T19-46-30-019f226f-*.jsonl`
(cli_version 0.142.5, riela 0.1.14 Homebrew).

| Time | Event |
|---|---|
| 10:41:37 | `implement` starts; completes 10:44:49. |
| 10:44:49 | `review` starts; completes 10:46:27 (`accepted: true`, no findings). |
| 10:46:27 | `workflow-output` starts a fresh codex-agent process (gpt-5.5, sandbox `danger-full-access`, approval `never`). Resolved input already contains the implement and review payloads. |
| 10:46:53 | Instead of emitting JSON, the agent runs `exec_command`: `sed -n '1,220p' ~/.codex/skills/riela-workflow-run/SKILL.md && sed -n '1,220p' .../riela-workflow-test/SKILL.md` (10 s yield). |
| 10:47:03 | Exec returns output but the unified-exec session (id 67308) reports `Process running` — the trivially-terminating `sed` session never reports exit. |
| 10:47:06 | Agent polls stdin (1 s yield): no output, still `running`. |
| 10:47:14 | Agent sends Ctrl-C via `write_stdin`: **`Unified exec process failed: Operation not permitted (os error 1)`**. |
| 10:47:17 | Agent issues `write_stdin` with **`yield_time_ms: 300000`** — a 5-minute blocking wait on the dead session. Last rollout entry. |
| 10:47–10:50 | Riela reports nothing: no backend events, no silence warning. |
| 10:50:54 | Operator interrupts; step recorded `failed` / `workflow run cancelled`; session `failed` despite all substantive work having succeeded. |

## Root Causes

### RC-A — A pure formatting step runs as an unrestricted tool-enabled agent

`nodes/node-workflow-output.json` in the `codex-simple-work-package` package
is an ordinary codex-agent worker: full toolset, `danger-full-access`
sandbox, 1-hour `nodeTimeoutMs`. Its prompt
(`prompts/workflow-output.md`) begins **"Read the latest implementation and
review outputs"** — but those outputs are already embedded in the resolved
input message. "Read" invited the model to go to the filesystem, and the
injected repo `AGENTS.md` (which advertises riela skills) gave it something
to read. A step whose contract is "project inbox JSON → output JSON" has no
reason to execute commands at all.

`kind: "output"` on the node (`WorkflowRegistryNodeKind.output`,
`Sources/RielaCore/WorkflowModel.swift:44`) is currently a registry marker
only — it confers no execution restrictions.

### RC-B — Codex unified-exec session wedged; interrupt EPERM; 300 s blind wait

Codex CLI 0.142.5 behavior, external to Riela: the exec session for a
command that must have exited kept reporting `running`; `kill` on it
returned `EPERM`; the model's fallback was a 300-second blocking yield.
Riela cannot fix this, but Riela chose the agent's sandbox mode and toolset
(RC-A) and therefore how exposed the run is to this class of backend wedge.

### RC-C — No silence signal for agent-backend steps

Stall detection (`--stall-timeout-ms`) deliberately excludes CLI agent
backends, and the only hard bound is `nodeTimeoutMs` (1 h here). A running
agent step that emits no backend events for minutes is indistinguishable —
in `session progress`, `status`, and the JSONL stream — from one that is
thinking. The workflow's own `defaults.supervision.stallTimeoutMs: 300000`
applies only to supervised non-agent executions, so it never fired.

### RC-D (secondary, verify) — Backend-event fields empty for session 201

Session 145 (same workflow, same riela 0.1.14, earlier the same day)
recorded `lastBackendEventType: turn.completed` on its executions; session
201's executions — including the two completed steps — have no
`lastBackendEventAt/Type` at all. If backend-event recording silently
stopped, the silence-watchdog proposed below would be blind. Needs a
reproduction check before P-C relies on those fields.

## Proposed Fixes

### P-A — Harden output-step prompts in the workflow packages (immediate, registry-side)

In `tacogips/riela-packages` for `codex-simple-work-package` (and the same
pattern in `codex-adversarial-implementation-review-loop`,
`codex-design-and-implement-review-loop`, `codex-recent-change-quality-loop`
final steps): rewrite the output prompt to

- state that the implementation and review payloads are provided in the
  input message,
- forbid command execution and file reads ("do not run commands; do not read
  files; produce the JSON immediately from the given input"),
- drop the word "Read" in favor of "Using the provided ... payloads".

Cheap, no runtime change, removes the trigger observed in session 201.

### P-B — Deterministic output projection for `kind: "output"` nodes (runtime)

Give `kind: "output"` real semantics: allow an output node to omit
`executionBackend` and instead declare a built-in projection add-on that
assembles the final payload from inbox messages (field mapping / template
over the accepted upstream outputs). A finalizer that is pure data plumbing
then costs zero LLM calls, zero tools, and cannot stall. LLM-backed output
nodes remain allowed for genuinely generative summaries.

### P-C — Agent-silence telemetry (runtime; extends resilience-doc P4.4)

For running agent-backend executions, track time since the last backend
event (or process output line, once response streaming lands) and:

- emit a `silence_warning` workflow run event and set a
  `silentForMs` field visible in `session progress`/`status` when a
  configurable threshold passes (default suggestion: 120 s),
- optionally escalate per node policy (`onSilence: warn|fail|restart`),
  keeping `warn` the default so long legitimate thinking is not killed.

Prerequisite: resolve RC-D so the runtime actually has a live signal.

### P-D — Per-node sandbox/tool restriction pass-through (adapter)

The codex adapter currently launches every node with the same full-access
profile (`danger-full-access` observed). Add node-payload fields (e.g.
`agentSandbox: read-only|workspace-write|danger-full-access`,
`agentToolPolicy`) that the codex/claude/cursor command builders map to
their CLIs' native flags. Output/review nodes can then run read-only, which
both narrows the blast radius and removes most of the wedge-prone exec
surface.

## Recovery Note

The interrupted run needs no full rerun:
`riela session resume codex-simple-work-package-session-201` re-executes
only the `workflow-output` step on top of the completed implement/review
outputs.

## Suggested Order

1. P-A (registry prompt fix — immediate).
2. RC-D verification, then P-C silence telemetry.
3. P-D sandbox pass-through.
4. P-B deterministic output projection (larger; removes the class).
