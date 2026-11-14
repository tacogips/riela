# Resident RielaApp instance control from the CLI: reload, manual run, executions

Status: proposed 2026-11-10 on branch `feat/instance-reload-run-cli`. No GitHub
issue; the request text in the workflow input is the source of truth. This is
the generic Riela phase only. A later run builds the ART output monitor on top
of these commands.

Baselines this design extends without changing their decisions:

- `design-workflow-instance-unification.md`: the `riela instance` command group and
  read-only RielaApp profile instances in the CLI.
- `design-rielaapp-web-server-lifecycle-packaging.md`: the loopback App listener,
  `web-server.json`, Host/Origin/CSRF guards. Its §2.2 says "On app launch,
  `isEnabled: true` triggers startup". The code does not do this (§2 below).
- `design-workflow-definition-store.md`: service runs (configured runs and
  `events serve` children) read the SQLite definition store. Files only seed it,
  and later file changes need an explicit force import.
- `design-app-managed-api-auth.md`: auth semantics stay unchanged.

## 1. Goal

An operator or an automated agent uses only the `riela` CLI, without restarting
RielaApp, to:

1. reload a resident App instance so later runs use the updated definition,
   source directory and `.riela-events` bindings. In-flight runs are not
   interrupted unless the caller asks for it. An invalid definition changes
   nothing.
2. start a manual configured run with the credentials the App holds. The command
   takes `--variables`, returns the `sessionId`, and can wait for completion.
3. list recent executions as JSON (session id, status, start and end time), so a
   monitor can tell whether the last scheduled run succeeded.

Non-goals: the ART monitor workflow, any change to `riela environment`, any
change to `riela serve` host routes, a file-based control queue (HTTP is
possible, see §2), editing App instances through `riela instance update`, and
GraphQL surfaces for the new operations.

## 2. Verified current state (base `0ec062c9`)

| Fact | Evidence |
| --- | --- |
| The App starts its listener only when launched with `--start-web-server`. It ignores the persisted `isEnabled`. **Root cause** of "no listener on 19091 despite `isEnabled: true`": `start()` persists `isEnabled = true`, and the next App launch does not honour it. | `EntryPoint+WebServer.swift:23` → `RielaAppWebServerController.startIfRequested(by:)` guards on `options.startsWebServer` (`RielaAppLaunchOptions.swift:44-45`). This contradicts lifecycle design §2.2 |
| The running App can start its listener at runtime without a restart, from Console > Settings > Web Config server (GraphQL `updateHTTPServer(isEnabled: true)` over native IPC) | `RielaAppConfigurationGraphQLProvider.swift:65-100` |
| The listener requires `Host == 127.0.0.1:<configuredPort>`. Non-GET requests also need `Origin == http://127.0.0.1:<port>`, the `x-riela-csrf` token from `GET /api/v1/bootstrap`, and `Content-Type: application/json` | `RielaAppWebRouter.swift`, `RielaWebRequestSecurity.swift:17-33` |
| `riela instance show <id>` searches only the project and user stores. `list --scope all` also returns App profile instances (`scope: app:<profile>`). This is why list identities fail in show with `instance not found` | `FileWorkflowInstanceStore.swift:201-260` (`findInPrecedence` has no App branch) |
| App instance `workflowId` is derived by stripping only `user-workflow:`/`app-workflow:`/`project-workflow:`. A `selected-workflow:<path>` source shows its full source id as `workflowId` | `FileWorkflowInstanceStore.swift` `workflowId(from:)` |
| `riela instance update` writes only project/user `instances.json`. App instances live in `~/.riela/rielaapp/profiles/<p>/daemon-workflows.json`, which the App holds in memory (`daemonState`) and never re-reads at runtime. **`instance update` therefore never reaches the running App** | `InstanceCommands.swift:89-117`, `EntryPoint+DaemonInstanceResolution.swift:49-54` |
| A resident instance runs as a child `riela events serve --workflow-definition-dir <dir> --event-root <root> --session-store <profile sessions>` process. It reads `.riela-events` sources/bindings and `workflow.triggerDefaults` (lookup-only) once at startup | `DaemonWorkflowEventServeProcess.swift:148-200`, `EventLiveServe.swift:427-455, 969-987` |
| Each event run and each configured run resolves its definition through `DefinitionStoreWorkflowBundleResolver` in the profile session store. When a head exists, workflow files are ignored | `WebWorkflowRequestHandler+ConfiguredLaunch.swift:30-51`, definition-store design §1, §4 |
| `restart` (and `stop`) terminates the child process (`process.terminate()`), which kills in-flight event runs. A restart re-reads `.riela-events` but **not** the workflow definition (store head). The candidate comes from a cache (`daemonWorkflowSources` wins in `uniqueDaemonWorkflowSources`), so a moved source directory is not picked up either | `DaemonWorkflowEventServeProcess.swift:366-368`, `RielaAppInstanceAPI.swift:105-140`, `EntryPoint+DaemonInstanceResolution.swift:56-80` |
| `POST /api/v1/instances/{identity}/runs` exists (desktop-only). It returns `202 {id, status, sessionId|null, error|null}`. `sessionId` can be null until the first run event. The launch can be polled at `GET /api/v1/workflow-editor/launches/{id}` (needs `x-riela-profile`; kept in memory for 1 h; App-process launches only) | `RielaAppConfiguredRunAPI.swift`, `WebWorkflowRequestHandler+ConfiguredLaunch.swift:15-79`, `WebWorkflowLaunch.swift`, `WebWorkflowRequestHandler+Launch.swift:7-17` |
| `GET /api/v1/instances/{identity}/executions` exists and returns up to 100 items `{sessionId, workflowId, status, currentStepId, activeStepIds, updatedAt}` for the instance's workflow directory from the profile session store. It has no start time. `GET .../executions/{sessionId}` returns detail | `RielaWebAPIProjection.swift:105-150` |
| `riela environment status|reload` is the existing CLI client: bootstrap → csrf, `x-riela-profile`, `expectedRevision`, no redirects, 1 MiB cap, safe-code error mapping, default `--server http://127.0.0.1:8787` | `EnvironmentCommand.swift` |

## 3. Decisions

### D1. App endpoint and profile discovery (CLI, read-only)

> Superseded 2026-11-12 by `design-serverless-app-control.md` §3.1.
> Without `--server`, the CLI now uses local mode (owner-only Unix socket plus
> local disk reads). The implicit `web-server.json` HTTP endpoint below is no
> longer used. Profile discovery is unchanged.

The new commands `instance reload|run|executions` (and nothing else) resolve the
endpoint like this:

1. `--server <url>` when given. It goes through the same URL validation as
   `EnvironmentCommand`: http(s), no userinfo/query/fragment/path, plain http
   only for `127.0.0.1`/`localhost`/`::1`.
2. Otherwise, read `<appRoot>/web-server.json` with the existing
   `RielaAppWebServerSettingsStore` load path, **without quarantining**. The CLI
   must never move or rewrite App files, so add a read-only decode that returns
   nil on a bad file. `<appRoot>` is `$RIELA_APP_ROOT`, or `~/.riela/rielaapp`.
   The endpoint is `http://127.0.0.1:<port>`. A missing file means the default
   port 19091.
3. If `isEnabled == false` the command still tries the endpoint. On connection
   failure it reports `app_unreachable` with the hint "start the web server in
   RielaApp Console > Settings > Web Config server".

The expected profile is `--profile`, else `RielaAppProfileStore.loadActiveProfileName()`
(`<appRoot>/active-profile.json`, default `default`). The bootstrap `profile`
must equal it, otherwise `app_profile_conflict` and no write. Every request sends
`x-riela-profile`. Every mutation sends `Origin` (the endpoint), `x-riela-csrf`
(from bootstrap), `Content-Type: application/json`, and body `expectedProfile`
plus `expectedRevision` (from bootstrap). Discovery is macOS-only, the same as
`RielaAppWebServerSettings`. On other platforms `--server` is required (usage
error otherwise).

The transport closure, no-redirect delegate, 1 MiB cap and safe-code error
mapping are shared with `EnvironmentCommand` through one small internal client
file (`Sources/RielaCLI/RielaAppAPIClient.swift`). `EnvironmentCommand` defaults
and output stay unchanged; it may call the shared helpers.

### D2. Web server autostart fix (App, minimal, needs a one-time upgrade)

`configureWebServer` starts the listener when
`launchOptions.startsWebServer || store.load().settings.isEnabled`. This
implements lifecycle design §2.2. Binding (`127.0.0.1` only), guards and auth
are unchanged. `isEnabled` becomes true only through an explicit user Start, so
no new exposure. A failed autostart sets `state = .failed(...)` as today and
does not block launch.

Rollout: the running 0.3.1 App can be reached today **without restart** by
starting the server once from Console > Settings (this re-persists
`isEnabled: true`). Then `instance run` and `instance executions` work against
0.3.1. `instance reload` and the `startedAt`/`endedAt` fields need the upgraded
App. **One-time prerequisite: replace RielaApp with a build containing this
change, once.** After that, every reload, run and status operation works without
restarts, and the listener comes back automatically on every launch.

### D3. Identity normalization (CLI)

- `ScopedWorkflowInstanceStore.find(identity:workflowId:scope:)` with scope
  `nil` or `.all` searches project → user → App profiles. Project/user
  precedence is unchanged, so existing callers resolve the same records. An App
  match returns a new `.appProfile(name)` result, rendered as
  `scope: "app:<profile>"` exactly as in `list`. If the same identity exists in
  more than one App profile and `--profile` is not given, the error is
  `ambiguousIdentity` with the profile names listed.
- Accepted identity forms: exactly the `identity` string printed by
  `list` (e.g. `configuration-903fe205-…`). `--profile <name>` narrows App
  lookup. No new qualified syntax is introduced.
- `workflowId(from:)` also strips `selected-workflow:`. For path-based sources
  (`selected-workflow:<dir>`) the workflow id is read from the source
  directory's `workflow.json` `workflowId` when readable, else the stripped
  remainder. This is display only.
- `instance update|remove` on an identity that resolves only to an App profile
  fails with usage error `instance_app_scope_read_only: use 'riela instance
  reload <identity> [--workflow-definition-dir <dir>]'`. It never creates a
  shadow project instance.
- The new App-API commands send the **local** identity (the list identity),
  percent-encoded with the `.alphanumerics` set like `EnvironmentCommand`. The
  App keeps mapping it to its runtime identity (`profileRuntimeIdentity`).
  Before any request, the CLI checks that the identity exists in the discovered
  profile's App instances (read-only file read). Otherwise it reports
  `instance_not_found` with no request sent. This check is skipped when
  `--server` is given, because the remote host is authoritative.

### D4. `reload` App route (new, desktop-only)

`POST /api/v1/instances/{identity}/reload` is registered in
`RielaWebAPIRouteTable.desktopOnly`. It is a separate route rather than a new
`WorkflowInstanceAction` case, so the shared `/actions` contract and the serve
host stay unchanged. It runs inside `distributedControllerOperations.run` (the
same serialization as `/actions` and `/runs`) and is rejected during
termination shutdown.

Request (exact key set, extra keys → 400 `invalid_reload_request`, body ≤ 64 KiB):

```json
{"expectedProfile":"default","expectedRevision":12,"reason":"fix hourly-refresh notion write",
 "workflowDirectory":"/abs/path/or/null","interruptRunning":false}
```

- `reason`: required, 1–512 UTF-8 bytes, the definition-store audit reason.
- `workflowDirectory`: null keeps the instance's current source directory.
  Otherwise it must be an absolute, existing directory containing
  `workflow.json`.

Algorithm. Validate everything first, write once, respawn last:

1. Check the revision and profile (`validateGraphQLConfigurationRevision`) →
   409 `configuration_conflict`. Find the instance in `daemonInstances` → 404
   `instance_not_found`.
2. **Fresh candidate.** With `workflowDirectory` null, rediscover the
   instance's current source from disk (for a `selected-workflow:` source,
   `discoverSelectedWorkflowDirectory(candidate.workflowDirectory)`; for other
   scopes, the profile discovery `daemonWorkflowSources(profileName:state:)`
   filtered to the same source id). The cached candidate is never used. With a
   path, `discoverSelectedWorkflowDirectory(path)`. No candidate → 422
   `invalid_workflow_source`.
3. **Validate the definition from files.** Use the full file resolver
   (`FileSystemWorkflowBundleResolver` with `workflowDefinitionDir` = candidate
   directory) plus the instance's node patches through
   `WorkflowInstanceResolver.resolve`. Failure → 422 `invalid_workflow_definition`.
   The resolved `workflowId` must equal the instance's current workflow id,
   otherwise 422 `workflow_id_mismatch`. The definition-store head is keyed by
   workflow name, so re-pointing to a different workflow is a new instance, not a
   reload.
4. **Validate the event bindings.** Run the same event-root parse and
   validation that `riela events validate` performs (dispatched from `ScopedParityCommands.swift`),
   in process, on the candidate's event root. Failure → 422
   `invalid_event_bindings`. If that logic is not callable from the App without
   a CLI round trip, the implementer extracts the existing validation into a
   function. No new validator is written.
5. **Decide on respawn.** Respawn is needed iff the child for this instance is
   running/starting **and** at least one of these differs from what the child
   started with:
   - `workflowDirectory`
   - `eventRoot`
   - the event-root content digest: SHA-256 over sorted relative path + bytes of
     the regular files under the event root, the same file set `events serve`
     reads
   - the **trigger-defaults fingerprint**: SHA-256 of the canonical JSON of
     `workflow.triggerDefaults` (`null` hashes the literal `none`). The
     proposed value comes from the new file bundle (step 3). It is compared
     with the fingerprint **installed in the running child**, never with the
     store head.

   *Installed start record.* `RielaAppDaemonWorkflowRuntime.start` records an
   in-memory start record on the running entry: `workflowDirectory`,
   `eventRoot`, `eventRootDigest` and `triggerDefaultsFingerprint`.

   The fingerprint is computed in the App immediately before spawn with the
   same resolution the child uses at startup
   (`CLIWorkflowTriggerDefaultsResolver`, `EventLiveServe.swift:969-987`). That
   is the store head when one exists (lookup-only), otherwise the file bundle.
   So it reflects what the child installs.

   **The record is written only when a child starts successfully** (initial
   start, `start`/`restart` actions, or a successful step-8 replacement). A
   rejected reload, a partial commit (`partial: definition`), a lost handoff, or
   a failed replacement start leaves the previous record untouched.

   Consequence: after a reload that committed new trigger defaults but lost its
   handoff, the store head and files both hold the new defaults while the child
   still holds the old fingerprint. A re-run therefore still detects the
   difference and respawns. This holds even for a triggerDefaults-only change
   where the directory, event root and event-root bytes are all unchanged.

   **Definition-only reload (no respawn).** Steps 6 and 9 are skipped, and
   active executions are irrelevant. An in-flight event run keeps its pinned
   store `versionId` (definition-store §4 step 4). The next run of the running
   child looks up the new head. Reload therefore succeeds while a run is in
   flight.
6. **Admission barrier (respawn only, established before any commit).**
   Safety comes from the child itself, never from the App's session-history
   projection. `webExecutions` is bounded (`RielaWebAPIProjection.swift:122-134`)
   and is not used as active-work evidence.

   *Child gate.* `events serve` gains one in-process admission gate. Every
   workflow dispatch passes through it:
   - cron fires, via `CronOverlapDispatcher` starts, including dequeue from its
     overlap queue;
   - every non-cron event-to-workflow run.

   The gate counts `running` (admitted, not yet finished) and `queued`
   (`CronOverlapDispatcher` scope queues and `pendingAfterCancel`). It has two
   states, `open` and `closed`. **Admission and close are serialized in one
   actor:** a dispatch is admitted only if the gate is open at the moment it
   increments `running`, so no dispatch can start after `close` returns.

   *Wire contract.* The control frames extend the existing private
   parent→child channel (`--runtime-environment-channel`,
   `RuntimeEnvironmentChannelWire`, `RuntimeEnvironmentSnapshot.swift:60-106`).
   The frames carry no values:
   - Parent→child: `{"type":"admission-close","requestId":…,"leaseSeconds":120}`,
     `{"type":"admission-confirm","requestId":…}`, `{"type":"admission-open","requestId":…}`.
   - Child→parent: `{"type":"admission-ack","requestId":…,"state":"closed|open|expired","running":n,"queued":n}`.

   *While the gate is closed.*
   - A cron fire is not started. It is persisted as a `skipped` receipt with
     reason `reload-handoff:<bindingId>` (same path as
     `recordRoutineGateSkip`), and the queue is left untouched.
   - A non-cron event is persisted as a receipt with status `rejected`, reason
     `reload-handoff`. It can be re-dispatched with the existing
     `riela events replay`.
   - No receipt is silently dropped.

   *Lease.* If no `admission-confirm` or `admission-open` arrives within
   `leaseSeconds`, the child reopens the gate (state `expired`) and logs the
   safe code `admission_lease_expired`. A stuck or crashed parent therefore
   cannot stop scheduling.

   *Parent sequence.*
   1. Send `admission-close`. Wait at most 5 s for its ack.
   2. Child without the channel (`runtimeEnvironmentGeneration == nil`), no ack,
      or the child exited: send `admission-open` best-effort. Then 409
      `instance_handoff_unavailable` (`interruptRunning` true: continue to
      step 7 and interrupt as requested).
   3. Ack with `running + queued > 0` and `interruptRunning` false: send
      `admission-open`. Then 409 `instance_run_in_flight` with
      `{"running":n,"queued":n,"committed":false}`. **Nothing is written.**
   4. `interruptRunning` true: the barrier stays closed and the active work is
      killed at step 8. This is the explicit opt-in.
7. **Commit** (the barrier, when used, stays closed throughout). Any failure in
   this step sends `admission-open` and returns its error with
   `committed: false`. Writes happen in this order:
   1. **Definition store**, in the profile session store
      (`daemonSessionStoreRoot(profile)`) through
      `WorkflowDefinitionService.importDefinition`
      (`Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift:170-241`),
      actor kind `api`, id `instance-reload`, evidence none:
      - **Head absent:** `force: false` with the `reason`. Outcome `seeded`.
        If a concurrent seeder won the race, the service returns `unchanged`
        (same digest), which is a success with outcome `unchanged`. It can also
        return `differs`, in which case the step continues with the
        existing-head path below (one retry only).
      - **Head present:** `force: true` with the `reason`. The service guards
        on `expectedCurrentVersionId`. Outcome `forceUpdated`, or `unchanged`
        when digests match. A `staleHead` error (concurrent writer) → 409
        `definition_conflict`. Our write did not happen.
      - The service's validation failure → 422 `invalid_workflow_definition`.
        A store I/O error → 500 `definition_store_failure`.
      Each import is one store transaction. On the `differs` retry path, a
      failed second call leaves the competing seeder's head in place, so no
      write from this reload.
   2. **Source relink** (only if the source changed): append the directory to
      `state.workflowDirectories` if absent, set `preference.sourceIdentity` to
      the new candidate id, save `daemon-workflows.json` via
      `makeDaemonStore().save`, then update `daemonState` and
      `webRevision += 1`. The old directory entry is not removed. If the save
      fails after the definition write → 500 `configuration_io_failure` with
      `committed: true` and `"partial":"definition"`. The new head is reported
      truthfully; a retried reload is idempotent (`unchanged` + relink).
   3. `refreshDaemonWorkflowWindow()` so the cached candidate (event summaries,
      required environment) is rediscovered.
8. **Replace the child** (respawn only).
   1. Send `admission-confirm`. Proceed only on an ack with `state: closed` and
      `running == 0` and `queued == 0`, or with any ack when `interruptRunning`
      is true. The gate cannot admit work while closed, so a non-interrupt
      confirm always reports 0 unless the lease expired.
   2. If the lease expired (`state: expired`), or there is no ack: **do not
      stop the child.** Return 200 with `committed: true`,
      `eventBindings.respawned: false` and `handoff: "lost"`. The new
      definition is live for the next run, but the old bindings stay until the
      operator re-runs reload. The start record is not advanced (step 5), so
      the re-run sees the definition as `unchanged` but still detects a
      respawn. The comparison is against the child's installed directory,
      event root, event-root digest and trigger-defaults fingerprint, not
      against the store head.
   3. Otherwise `daemonRuntime.stop(identity)`, then
      `daemonRuntime.start(approved…)` as `restart` does, with readiness
      approval required. The old process exits with its gate still closed.
      The new child starts with an open gate. The start record advances only
      once this start succeeds.
   4. A start failure → 422 `instance_start_failed` with `committed: true`.
      A not-approved instance → 422 `instance_not_ready` with
      `committed: true`.
9. **Post-commit truthfulness.** After step 7.1 succeeds, no response says
   "unchanged state". Every later failure carries `committed: true`. Every
   pre-commit rejection carries `committed: false` and leaves the store head,
   `daemon-workflows.json`, the cached candidate and the running child
   untouched. The child's gate is reopened.

Response `200`:

```json
{"profile":"default","revision":13,"identity":"configuration-…","workflowId":"hourly-refresh",
 "workflowDirectory":"/…/app-workflows/hourly-refresh","sourceChanged":true,
 "definition":{"outcome":"seeded|unchanged|forceUpdated","versionId":"…","digest":"sha256:…"},
 "eventBindings":{"respawnRequired":true,"respawned":true},"handoff":"none|completed|interrupted|lost",
 "runtimeStatus":"running","committed":true}
```

All error bodies use the existing envelope `{"error":{"code","message"}}` with
the closed codes named above. Only rule-violation codes are returned. Raw
validator text is reduced to `WorkflowWebProjectionPolicy().safeSummary` in
`message`. Environment values never appear.

### D5. CLI commands

```
riela instance reload <identity> --reason <text> [--workflow-definition-dir <dir>]
    [--interrupt-running] [--wait-idle] [--timeout-seconds N] [--server URL] [--profile P]
riela instance run <identity> [--variables <json|@file>] [--wait] [--timeout-seconds N]
    [--poll-interval-seconds N] [--server URL] [--profile P]
riela instance executions <identity> [--limit N] [--server URL] [--profile P]
```

Output is always one JSON object on stdout, the existing `riela instance`
failure shape: `{"error":"<code>","exitCode":n}` on stdout for structured output,
plus `<code>` on stderr. Exit codes: 0 success, 2 (`.usage`) for argument
errors, 1 for remote/HTTP failures.

- **reload**: relative `--workflow-definition-dir` paths are resolved against
  `--cwd`/the current directory to an absolute standardized path before sending.
  `--reason` is required (usage error otherwise). `--wait-idle` retries on 409
  `instance_run_in_flight` every 10 s until `--timeout-seconds` (default 600,
  range 1–86400). On timeout, the code is `instance_run_in_flight`. Each retry
  re-runs bootstrap, so `expectedRevision` is fresh. Without `--wait-idle`, the
  409 is returned immediately. Only `instance_run_in_flight` is retried.
  `instance_handoff_unavailable`, `definition_conflict` and all `committed: true`
  responses are returned at once. The response JSON, including `committed`,
  `handoff` and `partial`, is printed in full. Exit is 0 only for a 200 with
  `handoff != "lost"`. A `lost` handoff exits 1 with code `reload_handoff_lost`
  while still printing the body. Prints the D4 response. On an old App the
  route does not exist. Any 404/405 response whose code is not
  `instance_not_found` maps to `app_reload_unsupported` ("upgrade RielaApp
  once"). The implementer pins the exact old-App response in a test fixture.
- **run**: `--variables` uses `JSONReferenceLoader.object` (JSON object or
  `@file`), default `{}`. Posts to `/runs`. If the 202 has `sessionId: null`, the
  CLI polls `GET /api/v1/workflow-editor/launches/{id}` (interval
  `--poll-interval-seconds`, default 2, range 1–60) until the sessionId appears
  or status is terminal (bounded by `--timeout-seconds`, default 60 without
  `--wait`). Output `{"launchId","sessionId","status"}`. With `--wait` it keeps
  polling the launch until `completed|failed` (`--timeout-seconds` default
  3600). If the launch record disappeared (404), it falls back to
  `GET /api/v1/instances/{id}/executions/{sessionId}` status. Final output adds
  `status` (the terminal value) and `error` (the launch's safe summary or null).
  A wait timeout → exit 1, code `run_wait_timeout`, with the last known
  `sessionId` still printed. `run` failure on a terminal `failed` status → exit
  1, code `run_failed`, body still printed. Server codes are passed through when
  safe-code shaped: `instance_not_ready`, `configuration_conflict`, `run_limit`,
  `run_preflight_failed`, `source_changed`, `invalid_configured_run`, and
  `RuntimeEnvironmentError` codes.
- **executions**: `GET /api/v1/instances/{id}/executions`, then client-side
  `--limit` (default 20, range 1–100). Output
  `{"identity","profile","items":[{"sessionId","status","startedAt","endedAt","updatedAt","currentStepId"}],"truncated"}`.
  Items are newest first, by the order the App returns. `startedAt` and `endedAt`
  are null when the App omits them (0.3.1). The CLI re-encodes a closed set of
  fields and never forwards arbitrary server output, the same rule as
  `EnvironmentCommand.render`.

### D6. Executions projection fields (App)

`WorkflowViewerSessionSummary` gains `startedAt: Date?` (the session's
`createdAt`). `webExecutions` adds `startedAt`, and `endedAt` (= `updatedAt` when
status is terminal: completed/failed/cancelled, else null), in ISO-8601. The
existing fields stay as they are, so the web console is unaffected.

### D7. Docs

- `docs/` gets an `app-instance-control.md` page: the three commands, endpoint
  and profile discovery, the error codes, the Console > Settings runtime start,
  and the **one-time App upgrade** prerequisite (D2).
- The README CLI section links to it.
- `Resources/skills/riela-workflow-run/SKILL.md` gets a short pointer.
- Lifecycle design §2.2 gets a note that autostart was implemented by this
  change.

## 4. Security

- No new listener or binding. Loopback only. Plain http is allowed only for
  loopback hosts.
- CSRF, Origin, Host, profile header and `expectedRevision` are required on
  `/reload` exactly as on `/runs`. The App code checks the profile header, as
  `/runs` does.
- `/reload` cannot name an arbitrary workflow: the workflow id must match the
  instance (`workflow_id_mismatch`). It only adds a directory the caller names,
  which must already contain a valid bundle of that same workflow. This is the
  same trust level as the existing "Add workflow directory" App action, which
  is reachable by the same CSRF-holding local client.
- Manual runs use the App's in-memory environment snapshot, unchanged. The CLI
  never prints environment values. It prints only closed-field JSON and safe
  codes.
- The CLI reads App files read-only (`web-server.json`, `active-profile.json`,
  `daemon-workflows.json`). It never writes under `~/.riela/rielaapp` or
  `~/.riela/profiles`.

## 5. Verification

Tests (focused, no live App writes):

- `RielaCLITests`:
  - `ScopedWorkflowInstanceStore.find` returns App profile instances after
    project/user. Ambiguous across profiles → error. `selected-workflow:`
    workflow-id derivation. `update`/`remove` on App scope → read-only error.
    `show` with a list identity succeeds. Fixtures use temp `homeDirectory`.
  - Endpoint discovery from a temp app root: port, missing file → 19091, corrupt
    file → default without moving it, `--server` override, non-loopback http
    rejected, profile from `active-profile.json`, bootstrap profile mismatch →
    `app_profile_conflict`.
  - Request construction with an injected transport: headers (Origin, csrf,
    profile, content-type), exact body keys for `/reload` and `/runs`,
    percent-encoded identity.
  - Argument validation: missing `--reason`, bad `--limit`/timeouts, bad
    `--variables`.
  - Error mapping: 404 `not_found` → `app_reload_unsupported`, 409
    `instance_run_in_flight` with `--wait-idle` retry then timeout, run launch
    polling (null sessionId → sessionId; completed/failed; 404 launch →
    executions fallback; timeout), unsafe codes replaced.
- `RielaAppSupportTests` (or the existing App test target that covers
  `RielaWebAPIProjection` / route table):
  - The route table contains `/reload` as desktop-only.
  - Executions projection emits `startedAt`/`endedAt`.
  - Web-server autostart decision `startsWebServer || isEnabled`, extracted as a
    pure function on `RielaAppWebServerSettings`/launch options so it is testable.
  - Event-root digest is stable under file order and changes on content change.
  - Respawn decision as a pure function
    `(childRunning, installedStartRecord, newCandidate, newEventDigest, newTriggerDefaultsFingerprint) → respawn: Bool`.
    The store head is not an input.
  - Reload orchestration with a fake admission channel and temp stores. Each
    case asserts the store head, `daemon-workflows.json` and the child-stop
    count:
    - definition-only change with an active run → 200, no barrier frames, child
      not stopped;
    - ack `running: 1` and no interrupt → 409 `instance_run_in_flight`,
      `committed: false`, `admission-open` sent, nothing written, child not
      stopped;
    - **active work beyond history limits**: the fake session store holds more
      than 100 terminal sessions and the child ack reports `running: 1` → still
      409. The decision never consults `webExecutions`;
    - no ack or no channel → 409 `instance_handoff_unavailable`, nothing
      written;
    - interrupt=true with `running: 1` → commit, child stopped,
      `handoff: interrupted`;
    - confirm returns `expired` → `committed: true`, `handoff: lost`, child
      **not** stopped, and the start record is unchanged;
    - **triggerDefaults-only lost-handoff recovery**: the child starts with
      triggerDefaults A, and only `workflow.json` changes to B (same directory,
      event root and event-root bytes). The first reload commits B and gets
      `handoff: lost`. A re-run → definition `unchanged` and respawn still
      required. The replacement succeeds, installs B, and advances the start
      record to fingerprint B. A third, unchanged reload → no respawn. A
      definition-only change made while a run is active still causes no
      barrier and no stop;
    - a failed replacement start or a `partial: definition` result leaves the
      start record at its previous value;
    - invalid definition / invalid bindings → 422 before any frame or write;
    - **fresh store** (no head) → non-force import, outcome `seeded`, no
      preliminary execution;
    - existing head → force import with the audit reason recorded, outcome
      `forceUpdated`;
    - concurrent seed with a different digest (`differs`) → one guarded
      force-import retry; a `staleHead` on that retry → 409
      `definition_conflict` with no write from this reload;
    - relink save failure after the definition write → `committed: true`,
      `partial: definition`.
- `RielaCLITests` (events serve admission gate, deterministic, with a fake
  workflow runner and a manual clock, no sleeps):
  - **boundary race**: a cron fire submitted concurrently with `close` either
    is counted in the returned `running` or is never started (a `skipped`
    receipt `reload-handoff:<binding>`). Asserted over many interleavings
    driven by the actor ordering;
  - fires and queue dequeues after `close` never start;
  - a non-cron event while closed → `rejected` receipt `reload-handoff`;
  - `confirm` while closed reports `running == 0`;
  - the lease expires → `expired` ack and the gate reopens;
  - `admission-open` → normal dispatch resumes;
  - frames never carry environment values.
- `WorkflowDefinitionServiceTests` stays green unchanged. The service contract
  is not modified.

Commands, each run through `arch -arm64 /bin/zsh -lc` from the worktree root:

- `swift build`
- `swift test --filter RielaCLITests`
- `swift test --filter RielaAppSupportTests`
- `swift test --filter WorkflowDefinitionServiceTests`
- `swiftlint` on the changed files

Read-only live probes (no App restart or writes):

- `riela instance list`
- `riela instance show <list identity>` (built binary in this worktree)
- `lsof -nP -iTCP -sTCP:LISTEN | grep -i riela`
- `riela instance executions <identity>` against the running 0.3.1 App. This
  works only if the user has started the listener from Console > Settings.
  Otherwise the expected result is the `app_unreachable` code.

## 6. Risks and residual limits

- No run is terminated without `interruptRunning`. The child's serialized
  admission gate closes the check-to-stop window (D4 steps 6 and 8).
  App-process manual runs are outside the child and are never affected by a
  respawn.
- Events that arrive while the barrier is closed (normally a few seconds, at
  most the 120 s lease) are not run by the old child. Each is recorded as a
  `skipped` cron receipt or a `rejected` event receipt with reason
  `reload-handoff`. A non-cron event can be replayed with `riela events replay`.
  A skipped cron tick is not re-run; the next tick runs under the new
  bindings. This is visible in receipts, never silent.
- A force import discards store-only edits (improvement-node versions). They
  stay recorded in the definition-store audit `overwritten_changes_json`.
  Reload is defined as "files win".
- Post-commit failures (relink save, lost handoff, new child start) return
  `committed: true` and are recoverable by re-running the idempotent reload.
- The running 0.3.1 App has no `/reload`, does not autostart its listener, and
  has no `startedAt`. These all need the single documented App upgrade.
