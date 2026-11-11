# Control resident RielaApp instances

Use `riela instance list` and `show` to find a resident instance, then use `instance reload`, `instance run`, `instance executions`, and `instance cancel` to update, launch, inspect, and cancel executions of it without restarting the App. Manual runs use the App's in-memory environment.

## Prerequisites

With a running RielaApp 0.3.1, start the listener once in Console > Settings > Web Config server. `run` and `executions` then work without restarting. Reload and execution start/end timestamps require a **one-time App upgrade** to a build containing this feature. Cancel, like reload, requires the upgraded App. Once upgraded, a listener explicitly enabled in Settings starts automatically on subsequent App launches; reloads and runs need no App restart.

## Discovery and identity

On macOS the CLI reads `<app-root>/web-server.json` for the port, defaulting to 19091 if missing or invalid, and connects to `http://127.0.0.1:<port>`. It reads `<app-root>/active-profile.json` for the profile, defaulting to `default`. The root defaults to `~/.riela/rielaapp` and can be overridden with `RIELA_APP_ROOT`. Discovery is read-only. Use `--server URL` and `--profile NAME` to override it; non-macOS requires `--server`. The requested profile must match the running App's active profile.

Identities from `riela instance list` are accepted by `show` and these commands. Project then user scope takes precedence over App scope when resolving existing instances; use `--profile` to disambiguate App profiles. App-only instances are read-only to `instance update` and `instance remove`; use reload to relink a source.

All three commands print JSON on stdout. Exit 0 means success, 2 means invalid arguments, and 1 means an operational failure. Ordinary errors print `{"error":"code","exitCode":1}` (or 2 for usage) and a code on stderr. Some post-commit reload and run failures instead print their result body on stdout and the code on stderr.

## Reload

```sh
riela instance reload ID --reason 'Deploy fixed workflow' [--workflow-definition-dir DIR] [--interrupt-running] [--wait-idle] [--timeout-seconds N] [--server URL] [--profile NAME] [--cwd DIR]
```

`--reason` is required and must contain 1–512 UTF-8 bytes after trimming. Relative source paths resolve against `--cwd` (default current directory). `--wait-idle` retries `instance_run_in_flight` at up to 10-second intervals; timeout defaults to 600 seconds, range 1–86400. Without it, the conflict returns immediately.

Example success (version and digest are illustrative):

```json
{"profile":"default","revision":3,"identity":"ID","workflowId":"example","workflowDirectory":"/work/example","sourceChanged":false,"definition":{"outcome":"unchanged","versionId":"v1","digest":"abc"},"eventBindings":{"respawnRequired":false,"respawned":false},"handoff":"none","runtimeStatus":"running","committed":true}
```

Validation precedes writes. Definition-only reloads do not interrupt runs. A changed source, event binding, or trigger defaults can require replacing the event-serving child; the admission barrier refuses or waits for running and queued work. `--interrupt-running` explicitly permits interruption. A child without the admission channel cannot perform a non-interrupting handoff and reports `instance_handoff_unavailable`.

During a closed barrier, cron ticks are recorded as skipped and other events as rejected with `reload-handoff` receipts. Non-cron events can be replayed with `riela events replay`; skipped cron ticks wait for the next schedule. Force import makes files authoritative and discards store-only definition edits; overwritten changes are audited with the reason. A post-commit failure can include `committed: true` and `partial`. If `handoff` is `lost`, the CLI exits 1 with `reload_handoff_lost`; the child is not replaced and a subsequent reload retries the handoff.

## Run

```sh
riela instance run ID [--variables '<json>|@file'] [--wait] [--timeout-seconds N] [--poll-interval-seconds N] [--server URL] [--profile NAME] [--cwd DIR]
```

Variables must be a JSON object or `@file`, default `{}`; relative files resolve against `--cwd`. The CLI waits for a session ID even without `--wait`, then returns; `--wait` waits for completion. Timeout defaults to 60 seconds without `--wait` and 3600 with it (range 1–86400); polling defaults to 2 seconds (range 1–60).

```json
{"launchId":"launch-1","sessionId":"session-1","status":"completed","error":null}
```

The `error` field is included only with `--wait`. A failed run or timeout exits 1 with `run_failed` or `run_wait_timeout`, respectively, and prints the last known result, including session ID if available.

## Executions

```sh
riela instance executions ID [--limit N] [--server URL] [--profile NAME]
```

The limit defaults to 20 (range 1–100), applied to the App's returned order. Older Apps and old session records can have null timestamps.

```json
{"identity":"ID","profile":"default","items":[{"sessionId":"session-1","status":"completed","startedAt":"2026-11-10T00:00:00Z","endedAt":"2026-11-10T00:01:00Z","updatedAt":"2026-11-10T00:01:00Z","currentStepId":null}],"truncated":false}
```

## Cancel

```sh
riela instance cancel ID [--session SESSION] --reason TEXT [--wait] [--timeout-seconds N] [--server URL] [--profile NAME] [--cwd DIR]
```

`--reason` is required and must contain 1–512 UTF-8 bytes after trimming, with no NUL. The session records `operator_cancelled by rielaapp-api:<profile>: <reason>`. With `--session`, the CLI posts to `POST /api/v1/instances/{identity}/executions/{sessionId}/cancel`; without it, the CLI posts to `POST /api/v1/instances/{identity}/cancel`.

Without `--session`, the App selects from live runs, not executions history. Exactly one live run is cancelled; zero returns `no_running_execution`. Several live runs, or one live run plus a pending run whose session has not started, return `ambiguous_running_sessions` with `sessionIds` and `pendingRunCount`; nothing is cancelled. A single pending run without a session returns `session_not_owned`; retry after it starts.

`--wait` polls about once per second until the session is terminal. `--timeout-seconds` is valid only with `--wait`, defaults to 60, and accepts 1–86400. A final `cancelled` status exits 0; another terminal status exits 1 with `cancel_not_effective`, and a timeout exits 1 with `cancel_wait_timeout`. Without `--wait`, `status` is null. For example, with `--wait`:

```json
{"identity":"ID","profile":"default","sessionId":"session-1","owner":"eventServe","outcome":"cancelRequested","status":"cancelled"}
```

Cancellation stops the command's whole process tree, including descendants in other process groups such as a nested `riela workflow run`. Processes receive SIGTERM, followed by SIGKILL after a 5-second grace period. The session becomes terminal after tracked tree cleanup, subject to a hard bound for survivors stuck in uninterruptible sleep. Every task-cancelled command now gives its tree up to 5 seconds instead of 1 second.

Other executions of the instance keep running. A cancelled cron run's receipt is `cancelled` with reason `operator-cancelled:<binding>:<session>`. A cancelled manual run's launch status reads `failed`, while its session reads `cancelled`. Orphan sessions that are `running` in the store but have no live runner cannot be cancelled; use `riela session reconcile`.

## Cancel error codes

| Code | HTTP | Meaning |
| --- | --- | --- |
| `invalid_cancel_request` | 400 | Request is malformed. |
| `instance_not_found` | 404 | Instance does not exist. |
| `session_not_found` | 404 | Session does not exist for this instance. |
| `configuration_conflict` | 409 | Profile does not match the App. |
| `not_running` | 409 | Session has finished. |
| `session_not_owned` | 409 | No live runner owns the session, or its session has not started; retry or reconcile an orphan. |
| `cancel_unavailable` | 409 | The instance child cannot answer; restart the instance on the upgraded App. |
| `instance_busy` | 409 | Another operation is in progress. |
| `no_running_execution` | 409 | No execution is live. |
| `ambiguous_running_sessions` | 409 | Multiple live or pending runs prevent selecting one. |

CLI-only codes include `app_cancel_unsupported` (upgrade the App once), `cancel_wait_timeout`, `cancel_not_effective`, and `instance_reason_required`.

## Reload error codes

These are the App reload contract's complete code set; HTTP status is shown for diagnosis. CLI failures exit 1.

| Code | HTTP | Meaning |
| --- | --- | --- |
| `invalid_reload_request` | 400 | Request is malformed. |
| `instance_not_found` | 404 | Instance does not exist. |
| `configuration_conflict` | 409 | Profile or revision changed. |
| `invalid_workflow_source` | 422 | Source cannot be resolved. |
| `invalid_workflow_definition` | 422 | Definition is invalid. |
| `workflow_id_mismatch` | 422 | Source workflow differs from instance. |
| `invalid_event_bindings` | 422 | Event bindings are invalid. |
| `instance_run_in_flight` | 409 | Running or queued work prevents handoff. |
| `instance_handoff_unavailable` | 409 | The child cannot perform a safe handoff. |
| `definition_conflict` | 409 | Definition head changed concurrently. |
| `definition_store_failure` | 500 | Definition store operation failed. |
| `configuration_io_failure` | 500 | Configuration could not be saved. |
| `instance_start_failed` | 422 | Replacement child failed to start. |
| `instance_not_ready` | 422 | Instance is not ready. |
| `instance_busy` | 409 | Another operation is in progress. |

Other CLI codes include `app_unreachable` (start the Settings listener), `app_profile_conflict`, `app_reload_unsupported` (upgrade the App), and `app_http_<status>` for unsafe or unavailable server codes.

## Security

The App listener binds to loopback; plain HTTP endpoints must be loopback. Requests retain the existing CSRF, Origin, Host, profile and revision checks. The CLI does not print environment values; protect any input variables and local logs appropriately.
