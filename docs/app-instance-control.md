# Control resident RielaApp instances

Use `riela instance list` and `show` to find a resident instance, then use `instance reload`, `instance run`, `instance executions`, and `instance cancel` to update, launch, inspect, and cancel executions of it without restarting the App. Manual runs use the App's in-memory environment.

## Modes

On macOS, without `--server`, instance and environment commands use local mode: local disk reads and an owner-only channel to a running RielaApp. No web server is required. `--server URL` selects the existing HTTP mode for a local or remote server, including its CSRF and profile checks. No environment variable selects the mode, and local mode never falls back to HTTP. On non-macOS, specify `--server`; otherwise the CLI reports `app_server_required` (usage exit 2).

This changes existing defaults: instance commands no longer discover the App web server port, and `riela environment` no longer defaults to `http://127.0.0.1:8787`. Pass `--server URL` explicitly to use the App listener or `riela serve`.

**One-time upgrade:** upgrade RielaApp before using local mode. An older running App has neither the lock nor the channel. Do not use local reload alongside it: its in-memory state can overwrite the relink. Use `--server` with the older App until it is upgraded.

## Discovery and identity

The app root is `RIELA_APP_ROOT` when set, otherwise `~/.riela/rielaapp`. The profile comes from `--profile`, then `<app-root>/active-profile.json`, then `default`; environment commands require `--profile`. The profile session store is `~/.riela/profiles/<profile>/sessions`. Discovery is read-only and introduces no new location options. The requested profile must match the running App's active profile.

In local mode the App owns `<app-root>/run/` (mode `0700`), `run/control.sock` (mode `0600`), and `run/app.lock` (mode `0600`). Both peers verify the other has the same user ID. The channel uses length-prefixed JSON, limits requests to 576 KiB and responses to 1 MiB, and has a 5-second request read deadline and a 30-second client response timeout. Request IDs make mutations idempotent; requests and responses are never written to disk. Environment status returns names and readiness, never secret values.

| Command | App running | App not running |
| --- | --- | --- |
| `instance executions` | Local SQLite read | Local SQLite read |
| `instance run` | Channel dispatch | `app_not_running` |
| `instance run --wait` polling | Channel launch status; a 404 falls back to a local execution detail read | Not applicable |
| `instance cancel` | Channel | `app_not_running` |
| `instance cancel --wait` polling | Local execution detail read | Not applicable |
| `instance reload` | Channel: validate, admission barrier, commit and respawn serialized in the App | Local reload under `app.lock` |
| `environment status` | Channel | `app_not_running` |
| `environment reload` | Channel | `app_not_running` |

Local reload without the App validates, imports the definition and relinks the instance while holding `app.lock`. It does not respawn a child; its output has `runtimeStatus: "stopped"`, `handoff: "none"`, and no `revision`. The next App launch uses the committed definition and relink. If the App launches while the CLI holds the lock, it waits and displays “Waiting for a local riela CLI operation…”. Local executions or reload can report `invalid_workflow_source` if only the running App can discover the source; use `--server` in that case.

Identities from `riela instance list` are accepted by `show` and these commands. Project then user scope takes precedence over App scope when resolving existing instances; use `--profile` to disambiguate App profiles. App-only instances are read-only to `instance update` and `instance remove`; use reload to relink a source.

These commands print JSON on stdout. Exit 0 means success, 2 means invalid arguments, and 1 means an operational failure. Ordinary errors print `{"error":"code","exitCode":1}` (or 2 for usage) and a code on stderr. Some post-commit reload and run failures instead print their result body on stdout and the code on stderr.

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
riela instance run ID [--variables '<json>|@file'] [--allow-overlap] [--wait] [--timeout-seconds N] [--poll-interval-seconds N] [--server URL] [--profile NAME] [--cwd DIR]
```

Variables must be a JSON object or `@file`, default `{}`; relative files resolve against `--cwd`. The CLI waits for a session ID even without `--wait`, then returns; `--wait` waits for completion. Timeout defaults to 60 seconds without `--wait` and 3600 with it (range 1–86400); polling defaults to 2 seconds (range 1–60).

```json
{"launchId":"launch-1","sessionId":"session-1","status":"completed","error":null}
```

The `error` field is included only with `--wait`. A failed run or timeout exits 1 with `run_failed` or `run_wait_timeout`, respectively, and prints the last known result, including session ID if available.

A run is refused when the instance already has a live execution, whether started manually or by cron, in the App profile's session store. The CLI exits 1 and prints `{"error":"instance_busy","sessionId":"<id|pending>","exitCode":1}` on stdout; `pending` means the session ID has not yet been allocated. Pass `--allow-overlap` to bypass this check. An older App rejects this flag with `invalid_configured_run`. Orphaned sessions from a crashed process never block a run.

### Cron overlap with manual runs

Live manual runs count as running for the cron binding's `overlapPolicy`. When the binding is otherwise idle, `skip` records `overlap-skip:<bindingId>:<manualSessionId>`; `queue` waits for the manual run to end and preserves FIFO order; `concurrent` counts manual runs toward `maxConcurrentRuns`; and `cancelRunning` skips rather than canceling a manual run. The check has a typically sub-second race window before session allocation, and instances sharing a workflow ID in one profile share the busy and overlap check. If the session probe fails, the check fails open.

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

`--reason` is required and must contain 1–512 UTF-8 bytes after trimming, with no NUL. The session records `operator_cancelled by rielaapp-api:<profile>: <reason>`. In server mode, `--session` uses `POST /api/v1/instances/{identity}/executions/{sessionId}/cancel`; without it, the CLI uses `POST /api/v1/instances/{identity}/cancel`.

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

Other CLI codes include `app_unreachable` (in `--server` mode, check the server and start the Settings listener if needed), `app_profile_conflict`, `app_reload_unsupported` (upgrade the App), and `app_http_<status>` for unsafe or unavailable server codes.

## Local channel error codes

These errors exit 1 unless otherwise stated.

| Code | Meaning |
| --- | --- |
| `app_not_running` | A live operation requires RielaApp; start it or use `--server`. |
| `app_channel_unavailable` | The lock is held but the socket is not answering; retry. |
| `app_channel_insecure` | The run directory or socket failed ownership or permission checks. |
| `app_channel_path_too_long` | The socket path exceeds 103 bytes; use a shorter `RIELA_APP_ROOT` or `--server`. |
| `app_channel_timeout` | The response timed out or the local reload pre-commit time cap was reached. A timed-out channel operation may have completed; check executions. |
| `app_channel_protocol_error` | The response is malformed or oversized. |
| `request_too_large` | The request exceeds the channel limit (413). |
| `invalid_request` | The request envelope is malformed (400). |
| `request_id_conflict` | A request ID was reused with different contents (409). |
| `channel_busy` | The idempotency cache is full of in-flight requests (503); retry. |
| `app_server_required` | Non-macOS requires `--server` (usage exit 2). |

## Security

The App listener binds to loopback; plain HTTP endpoints must be loopback. Requests retain the existing CSRF, Origin, Host, profile and revision checks. The CLI does not print environment values; protect any input variables and local logs appropriately.
