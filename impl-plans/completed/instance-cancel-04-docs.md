# instance-cancel-04: Operator docs for `riela instance cancel`

**planId**: instance-cancel-04-docs
**dependsOn**: none (wave 1; every value comes from the accepted design)
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C4, C4b, C7, C8, C9
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-04-docs.md

## Intent

Document the new command, both routes, the error codes and the cancellation
tree behavior in `docs/app-instance-control.md`. Follow the existing page
style: short paragraphs, `sh` and `json` blocks, and code tables.

## Non-goals

- Do not edit the existing Reload/Run/Executions sections, except the intro
  sentence, which gains `cancel`.
- No README or skill edits.

## File-level changes: docs/app-instance-control.md

- Intro: list `instance cancel` with the others.
- New section `## Cancel` after `## Executions`:
  - Synopsis:
    `riela instance cancel ID [--session SESSION] --reason TEXT [--wait] [--timeout-seconds N] [--server URL] [--profile NAME] [--cwd DIR]`.
  - `--reason` must be 1–512 UTF-8 bytes after trimming. It is recorded in
    the session as `operator_cancelled by rielaapp-api:<profile>: <reason>`.
  - With `--session`, the CLI posts
    `POST /api/v1/instances/{identity}/executions/{sessionId}/cancel`.
  - Without `--session`, it posts `POST /api/v1/instances/{identity}/cancel`.
    The App decides from its live runs, never from the executions history:
    exactly one live run is cancelled; zero gives `no_running_execution`;
    several, or one plus a run that has not started its session yet, give
    `ambiguous_running_sessions`, the output lists `sessionIds`, and nothing
    is cancelled.
  - `--wait` polls about once per second until the session is terminal.
    `--timeout-seconds` defaults to 60 (range 1–86400) and is only valid with
    `--wait`. A final `cancelled` exits 0, another terminal status exits 1
    with `cancel_not_effective`, and a timeout exits 1 with
    `cancel_wait_timeout`.
  - Example output:
    `{"identity":"ID","profile":"default","sessionId":"session-1","owner":"eventServe","outcome":"cancelRequested","status":"cancelled"}`.
  - Process tree: the command's whole tree is stopped, including processes in
    other process groups such as a nested `riela workflow run`. They get
    SIGTERM, then SIGKILL after a 5 s grace. The session becomes terminal only
    after the tree is gone. Every command cancellation now gives the tree up
    to 5 s, instead of 1 s.
  - Other executions of the instance keep running. The cron receipt of a
    cancelled run reads `cancelled` (`operator-cancelled:<binding>:<session>`).
    A cancelled manual run's launch status reads `failed`, while its session
    reads `cancelled`.
  - Orphan sessions (`running` in the store with no live runner) are not
    cancellable. Use `riela session reconcile`.
- New table `## Cancel error codes`, with code | HTTP | meaning:
  `invalid_cancel_request` 400, `instance_not_found` 404,
  `session_not_found` 404, `configuration_conflict` 409, `not_running` 409,
  `session_not_owned` 409 (no live runner yet or orphan; retry or reconcile),
  `cancel_unavailable` 409 (the instance child cannot answer; restart the
  instance on the upgraded App), `instance_busy` 409,
  `no_running_execution` 409, `ambiguous_running_sessions` 409.
  Then a line with the CLI-only codes: `app_cancel_unsupported` (upgrade the
  App once), `cancel_wait_timeout`, `cancel_not_effective` and
  `instance_reason_required`.
- In Prerequisites, add one sentence: cancel, like reload, needs the upgraded
  App.

## Verification

- `grep -c "instance cancel" docs/app-instance-control.md` ≥ 2, and every code
  above appears (a `grep` loop logged to
  `tmp/instance-cancel/instance-cancel-04-docs/grep.log`, exit 0).

## Done criteria

- The sections exist and list every code.
- Only this file changed.
- The progress log has the grep result.

## Implementation progress

- [x] Document cancellation, routes, behavior, and error codes.
- [x] Run the plan-local grep verification; see the progress log.
- [ ] Complete downstream independent review and workflow finalization.
