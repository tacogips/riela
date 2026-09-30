---
name: riela-workflow-run
description: Use when running, inspecting, resuming, rerunning or serving existing Riela workflows from a shell. Covers workflow run/list/validate/inspect, session status/progress/health/resume/rerun/continue, and riela serve.
---

# Running Riela workflows

Every command block below is generated from `SurfaceCatalog` and verified by
`SurfaceParitySkillTests`, so a renamed command or flag fails the test suite
instead of misleading you.

## Run a workflow

<!-- surface-catalog:begin workflow -->
```
riela workflow validate
riela workflow inspect
riela workflow usage
riela workflow run
riela workflow list
riela workflow status
riela workflow register
riela workflow update
riela workflow delete
riela workflow activate
riela workflow deactivate
riela workflow consolidate
riela workflow versions
riela workflow version
riela workflow restore
riela workflow checkout
riela workflow create
riela workflow self-improve
riela workflow package
riela workflow manifest validate
```
<!-- surface-catalog:end -->

`riela workflow run` takes the workflow name and, most often,
`--variables` with a JSON object, `--mock-scenario` for a deterministic run,
`--max-steps` for a hard per-session step limit, and `--session-store` to
choose where runtime records are written. Add `--output json` when a program
reads the result.

For an ordinary run on `riela serve`, set `RIELA_MANAGER_AUTH_TOKEN` in the
server's startup environment and provide the same bearer to the client:

```
riela workflow run my-workflow --endpoint https://riela.example/graphql --output json
```

The client also accepts `--auth-token` and `--auth-token-env`. The host chooses
the working directory and session store. The call waits for a persisted result
and returns its actual exit code, including failure. A client timeout can leave
the run continuing; retrying can start another run. Remote runs reject
`--from-registry`, `--mock-scenario`, and `--supervisor-mode`.

## Follow and control a session

<!-- surface-catalog:begin session -->
```
riela session rerun
riela session resume
riela session continue
riela session list
riela session status
riela session progress
riela session health
riela session latest
riela session step-runs
riela session export
riela session logs
```
<!-- surface-catalog:end -->

`riela session progress` accepts `--include-children` to roll up nested
sessions. There is no session-stop command: cancel the running process, which
persists the terminal cancelled state before exiting, or call the `stopSession`
GraphQL mutation against the process that runs the session.

## Serve the API

<!-- surface-catalog:begin serve -->
```
riela serve
riela serve status
riela serve health
riela serve overview
riela serve graphql
```
<!-- surface-catalog:end -->

Bare `riela serve` is the long-running host; it accepts `--host`, `--port`,
`--web-root`, `--session-store` and `--working-dir`. The named actions are
one-shot probes of the same server contract.

## Hand over and resume task work

A handover seals a packet and leaves the task waiting for an answer, a host
with required traits, or operator recovery. Boundary handovers end the session
as `suspended`; a suspended `workflow run` or `session resume` returns exit
code **5**. Treat it as a handover outcome and inspect the packet, not as an
ordinary workflow failure.

- `riela task handover <taskId> --reason "<text>" [--to <host|group>] [--sink <kind[,kind]>]` requests an operator handover. Add `--now` to stop the active node instead of waiting for a step boundary; that node can run again after takeover.
- `riela task answer <taskId> --question <id> (--answer-json <json>|--answer-file <path>|--text <text>|--option <optionId>|--use-default)` records an S1 answer. Then run `riela task run <taskId>` to let the server continue, or take it over elsewhere.
- `riela task takeover <taskId> [--packet <locator|path>] [--endpoint <url>] [--traits <trait,...>] [--clone-into <dir>]` reserves and runs a successor. Use `--endpoint` for another host and `--traits userReachable` when this invocation provides the required presence capability. An S1 takeover requires its recorded answer. `--endpoint` cannot be combined with `--force-orphan`.
- `riela task takeover <taskId> --force-orphan` fences an expired owner before recovery. The lease must already be expired. Optionally run `riela task reconcile --expired-leases` first to seal expired attempts without choosing a successor.
- `riela task handovers <taskId> [--output json]` lists sealed packets, digest-bearing sink references, and successors.
- `riela task reconcile --expired-leases [--dry-run]` seals tasks whose leases expired. Review the result, then use `task takeover` when a successor is ready.
- `riela task serve --takeover [--endpoint <url>] [--traits <trait,...>] [--once]` polls eligible handovers and runs them one at a time. It skips questions without answers. Polling defaults to every 5 seconds.
- `riela session handover <sessionId> [--reason <text>]` adopts a plain session into a task. Adoption reads the checkout at `HEAD`, records dirty paths as unpublished, and does not switch, commit, or push the user's branch. Use `riela session resume <sessionId>` for same-store continuation without adoption.

For a laptop successor, a typical command is:

```sh
riela task takeover <taskId> --endpoint https://controller.example/graphql --traits userReachable --clone-into /path/to/project
```

The endpoint uses the controller's manager bearer authorization. Keep bearer and
lease heartbeat tokens out of shell history and shared logs. `task serve`
requires `--takeover` until the general task server mode is added.

Common task store selectors are `--scope auto|project|user`, `--working-dir`
(or `--working-directory`), and `--session-store`; structured output commands
accept `--output json`.

- `task handover` requires `--reason`; optional controls are `--now`, `--to`, and `--sink`.
- `task answer` requires `--question` and exactly one answer source: `--answer-json`, `--answer-file`, `--text`, `--option`, or `--use-default`.
- `task takeover` also accepts `--handover-id`, `--sink`, `--principal`, `--endpoint`, `--auth-token`, `--auth-token-env`, and `--manager-session-id`. The auth token defaults to `RIELA_MANAGER_AUTH_TOKEN`; the manager session defaults to `RIELA_MANAGER_SESSION_ID`.
- `task reconcile` requires `--expired-leases`; it also accepts `--dry-run` and `--sink`.
- `task serve --takeover` accepts `--poll-interval-ms` (default `5000`), `--once`, `--endpoint`, `--traits`, and the same auth-token and manager-session options.
- `session handover` accepts `--task`, `--sink`, `--principal`, and `--reason` (default `operator handover`).
