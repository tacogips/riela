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
