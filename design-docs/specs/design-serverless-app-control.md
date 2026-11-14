# Server-less local control of RielaApp instances from the CLI

Status: proposed 2026-11-12 on branch `feat/serverless-app-control`. No GitHub
issue; the riela-manager dispatch (comm-019851, session
`opus-terra-design-and-implement-review-loop-session-849`) is the source of
truth.

Baselines. This design keeps their decisions and changes only what is listed
here:

- `design-instance-reload-run-cli.md`: reload algorithm (D4), CLI commands
  (D5), executions projection (D6). **Its D1 (implicit HTTP endpoint
  discovery) is superseded by §3.1 below.**
- `design-instance-cancel.md`: cancel semantics, stop proof, codes.
- `design-rielaapp-workflow-environment.md`: environment snapshot, names and
  readiness only.
- `design-rielaapp-web-server-lifecycle-packaging.md`: loopback HTTP listener,
  Host/Origin/CSRF guards. Unchanged.

## 1. Goal and non-goals

Goal: with no `--server`, `riela instance reload|run|cancel|executions` and
`riela environment status|reload` work while the App web server is disabled.

- Disk/SQLite-only work runs in the CLI process.
- Work that changes live App state goes over an App-owned, owner-only, non-TCP
  channel.
- `--server <url>` keeps today's HTTP behaviour exactly.
- The HTTP handlers and the channel call one shared `RielaAppSupport` service.

Non-goals:

- a new env var for mode selection;
- new app-root, project-dir or working-dir options (§3.1 explains why);
- in-process CLI execution of an instance (`instance run` without an App, see
  §3.9 and `design-docs/user-qa/qa-serverless-app-control.md`);
- channel access for any other App route (GraphQL, editor, packages);
- non-macOS local mode.

## 2. Verified current state (base `fd78a56b`)

| Fact | Evidence |
| --- | --- |
| `instance reload|run|cancel|executions` always use HTTP. Without `--server`, the endpoint is `127.0.0.1:<web-server.json port, default 19091>`. On non-macOS `--server` is required | `Sources/RielaCLI/RielaAppAPIClient.swift` `resolveEndpoint`, `InstanceAppCommands.swift:63-70` |
| `riela environment` defaults to `--server http://127.0.0.1:8787` (the `riela serve` port, not the App) and requires `--profile` | `EnvironmentCommand.swift:11` |
| App root: `$RIELA_APP_ROOT` or `~/.riela/rielaapp` (CLI). The App also accepts `--app-root`. Active profile: `<appRoot>/active-profile.json`. Instances: `<appRoot>/profiles/<p>/daemon-workflows.json` | `RielaAppAPIClient.appRoot/expectedProfile`, `RielaAppLaunchOptions.swift:35` |
| Profile session store: `<home>/.riela/profiles/<p>/sessions`, keyed on home and **not** on the app root | `EntryPoint+Environment.swift:106` |
| Reload and cancel logic already live in `RielaAppSupport` coordinators behind port protocols. The App HTTP handlers do the route parsing, the profile-header check, `distributedControllerOperations.run`, the `terminationShutdownStarted` check and error rendering | `RielaAppInstanceReloadCoordinator.swift`, `RielaAppInstanceCancelCoordinator.swift`, `RielaAppInstanceReloadAPI.swift`, `RielaAppInstanceCancelAPI.swift` |
| Environment status/reload and configured run are inline in App handlers (`performWebInstanceAction` `.reloadEnvironment` branch, `GET …/environment`, `webConfiguredRunResponse`). Environment status is the App's in-memory `daemonRuntime.environmentStatus` | `RielaAppInstanceAPI.swift:11-18,71-94`, `RielaAppConfiguredRunAPI.swift` |
| Executions list comes from `WorkflowViewerLoader.loadBounded` over the profile session store, filtered by the instance's workflow directory. Pure SQLite read | `RielaWebAPIProjection.swift:117-160` |
| Profile source discovery (`daemonWorkflowSources(profileName:state:)`) is App code, but it only composes `RielaAppSupport` calls (`discoverUserDaemonWorkflows`, `RielaAppProfileStore.workflowRootURL/packageRootURL`) | `EntryPoint.swift:657-675` |
| A reusable `flock` primitive exists | `Sources/RielaCore/DistributedStoreLock.swift` |
| The App has no cross-process control channel. Desktop "native IPC" is in-process WebView messaging | `EntryPoint+WebServer.swift:35` |

## 3. Decisions

### 3.1 Mode selection and precedence

1. `--server <url>` → **server mode**. The existing HTTP client is used
   unchanged: same URL validation (`app_invalid_server`), bootstrap, CSRF,
   Origin, profile header, 1 MiB cap and error mapping. It works for local and
   remote hosts.
2. No `--server` → **local mode**. There is no implicit HTTP fallback. On
   non-macOS, local mode fails with the existing usage code
   `app_server_required`.

No env var selects the mode. One flag already expresses the choice, and an env
var would add a second precedence rule without an accepted need.

Location discovery is unchanged: app root (`RIELA_APP_ROOT`, default
`~/.riela/rielaapp`), profile (`--profile`, else `active-profile.json`, else
`default`), and home from `CLIRuntimeEnvironment.homeDirectory`. The channel
socket, lock file, `daemon-workflows.json` and session store all derive from
these, so no new location option is needed. The App's `--app-root` launch flag
is already mirrored by `RIELA_APP_ROOT`.

`riela environment` keeps the required `--profile`, and its default `--server`
becomes "none" (local mode). **Behaviour change:** callers that relied on the
implicit `http://127.0.0.1:8787` (`riela serve`) must pass `--server`. The
`web-server.json` port lookup (old D1 step 2/3) is removed from command flow.
`resolveEndpoint` only validates an explicit URL.

### 3.2 Per-command partition

App liveness is decided by §3.4.

| Command | App running | App not running |
| --- | --- | --- |
| `instance executions` | local disk read (SQLite) | local disk read |
| `instance run` (dispatch) | channel `instance.run` | `app_not_running` |
| `instance run --wait` polling | channel `launch.status`; launch 404 → local execution detail read | n/a |
| `instance cancel` | channel `instance.cancel` | `app_not_running` |
| `instance cancel --wait` polling | local execution detail read | n/a |
| `instance reload` | channel `instance.reload` (validate, barrier, commit, respawn in one App-serialized operation) | **local reload** (§3.7): validate + definition import + relink under the App lock, no respawn |
| `environment status` | channel `environment.status` | `app_not_running` |
| `environment reload` | channel `environment.reload` | `app_not_running` |

Why the split looks like this:

- Reload while the App is running must stay in the App. D4 requires
  validate → admission close → commit → respawn as one serialized sequence, and
  the App holds `daemonState`, `webRevision` and the child channel in memory.
  If the CLI committed and the App respawned, the commit would happen outside
  the admission barrier and the in-memory state would go stale.
- Environment status is the in-memory snapshot. Without an App there are no
  credentials, so readiness has no meaning.
- Run needs the App's credentials.
- Cancel targets live processes.
- Executions and execution-detail reads are pure SQLite reads, so they never
  need the App.

The existing CLI pre-check (`localInstanceExists` against
`daemon-workflows.json`) is kept in local mode.

### 3.3 Shared service: `RielaAppInstanceControlService` (RielaAppSupport)

One type with one entry point:

`handle(_ operation: RielaAppControlOperation, profile: String) async -> RielaAppControlResult`

`RielaAppControlResult` is `{status: Int, body: JSONValue}`. `status` and
`body` are byte-for-byte what the HTTP route returns today.

Operations, a closed enum:

- `bootstrap`
- `reload(identity, body)`
- `run(identity, body)`
- `cancel(identity, sessionId?, body)`
- `environmentStatus(identity)`
- `environmentReload(identity, body)`
- `launchStatus(launchId)`

Bodies are the raw JSON bytes of the current HTTP bodies. The service owns the
strict decode, body limits and key sets: reload ≤ 64 KiB with exact keys; run
≤ 512 KiB with the existing key rule; cancel uses
`RielaAppInstanceCancelRequest.decodeStrict`; environment reload uses
`WorkflowInstanceActionInput` with `action == reloadEnvironment` only.

What the service owns:

- the profile check: `profile` must equal `ports.profile()`, otherwise the
  route's existing code (reload/cancel `configuration_conflict`, environment
  `profile_or_instance_conflict`);
- the existing shutdown codes, via `ports.serialized { }` (the App
  implementation is `distributedControllerOperations.run` +
  `terminationShutdownStarted`);
- calls to `RielaAppInstanceReloadCoordinator` and
  `RielaAppInstanceCancelCoordinator` (unchanged);
- the logic moved out of the App handlers: the environment reload/status logic
  from `performWebInstanceAction` and the GET route, and the configured-run
  validation and dispatch from `webConfiguredRunResponse`;
- error rendering (`reloadErrorResponse`, `cancelErrorResponse`,
  `instanceAPIError`, `environmentResponse`) moved verbatim.

`RielaAppInstanceControlPorts` composes the existing reload and cancel port
protocols with a few new ports:

- `bootstrap() -> (profile, revision)`
- `environmentStatus(identity)`
- `reloadEnvironment(identity) throws` (includes the "start if active and
  approved" step)
- `launchConfiguredRun(identity, variables, allowOverlap, expectedRevision) -> (status, body)`
- `launchStatus(id) -> (status, body)`
- `serialized(_:)`

The App implements them as `@MainActor` adapters over today's calls. Tests
implement a fake.

HTTP handlers become adapters: parse path, method and `x-riela-profile`, call
`service.handle`, and return `.json(status:body)`. These are the HTTP handlers
for `/reload`, `/cancel`, `/executions/{s}/cancel`, `/runs`, `GET /environment`
and the `reloadEnvironment` branch of `/actions`. Other `/actions` and
`POST /instances` stay as they are. HTTP CSRF, Origin and Host guards stay in
the router, untouched.

The executions list projection body moves out of the App route into
`RielaAppInstanceExecutionsProjection.list(workflowDirectory:sessionStoreRoot:identity:revision:)`
plus `detailStatus(...)`, called by the App route and by the CLI local read.
`revision` is nil locally.

`daemonWorkflowSources(profileName:state:)` moves into `RielaAppSupport` as
`RielaAppProfileWorkflowSources.discover(appRoot:profileName:state:)`, so the
App and the CLI resolve an instance's source identically. The profile
session-store path becomes `RielaAppProfileStore.sessionStoreRootURL(homeDirectory:profileName:)`,
used by `daemonSessionStoreRoot` and by the CLI.

### 3.4 App liveness: owner lock + socket

Paths, under `<appRoot>/run/` (directory mode `0700`):

- `app.lock`: the App opens it (`0600`) and holds `flock(LOCK_EX)` for its
  whole lifetime. A crash or kill releases it automatically, so a stale lock
  is impossible.
- `control.sock`: the Unix domain socket (§3.5).

**Ownership invariant.** The App holds `app.lock` whenever it has profile
state in memory or can write it. There is no unlocked startup path. A CLI holds
the lock only while the App does not, so App and CLI writes to
`daemon-workflows.json` never overlap, and the App always loads state that is
newer than any CLI commit.

**App launch (deferred initialization).** `applicationDidFinishLaunching` is
split in two.

*Phase A (lock-independent), runs immediately:*

- menu, status item and windows;
- profile *name* resolution from `active-profile.json`.

Phase A reads only that file and writes no profile state.

*Lock wait.* Create and validate `run/`, then block in `flock(LOCK_EX)` on a
dedicated thread, never the main thread.

- No timeout and no unlocked fallback.
- While waiting, the status shows `Waiting for a local riela CLI operation…`.
- Every action that loads or mutates profile state, or starts workflows, stays
  disabled:
  - `prepareInitialDaemonProfile`;
  - `makeDaemonStore` / `loadDaemonStateReportingCorruption`;
  - instance autostart and web-server autostart;
  - profile switch;
  - instance edits, which require the loaded state.
- If `run/` fails validation (`app_channel_insecure`), the App does not proceed
  to phase B. It shows that error and quits, never running unlocked.

*Phase B (only after the lock is acquired), in this order:*

1. Unlink a stale `control.sock`. This is safe because the holder of the lock
   is the only legitimate socket owner, and a live owner always holds the lock.
2. Bind and listen.
3. `prepareInitialDaemonProfile`.
4. Load daemon state.
5. Refresh caches.
6. Run instance autostart and web-server autostart.

The App never unlinks or binds `control.sock` without holding the lock.

The wait is normally under a second. Its upper bound is the CLI's local-reload
hard cap (§3.7, 30 s). A CLI that is stopped (`SIGSTOP`) while holding the
lock keeps the App in the visible waiting state until that CLI exits or is
killed. A crash releases the lock. This is the deliberate trade: wait visibly
rather than run unlocked.

CLI probe in local mode:

1. Connect to `control.sock`.
   - Success → App running, use the channel.
   - `ENOENT` or `ECONNREFUSED` → step 2.
2. Try `flock(LOCK_EX|LOCK_NB)` on `app.lock` (create it `0600` if absent,
   inside a validated `run/`).
   - Busy → `app_channel_unavailable`. Either another local CLI operation
     holds the lock, or an App is between lock acquisition and listen. The
     message suggests retrying. No write happens.
   - Acquired → App not running. Live-only commands release the lock and fail
     with `app_not_running`. Local reload keeps the lock until it finishes.

The CLI never deletes `control.sock`. Executions reads skip the probe entirely.

### 3.5 Channel transport and protocol

**Transport.** `AF_UNIX` `SOCK_STREAM` at `<appRoot>/run/control.sock`.

- **Path length.** The macOS `sun_path` holds 104 bytes, so the path must be
  ≤ 103 bytes.
  - App, longer path: it keeps the lock, does not start the channel, and logs
    `app_channel_path_too_long`.
  - CLI: it checks the length before connecting and reports
    `app_channel_path_too_long`, with the hint "use a shorter RIELA_APP_ROOT or
    --server".
  - The default `~/.riela/rielaapp/run/control.sock` fits. Tests use
    `/tmp/rac-<8 hex>` roots.
- **Why a socket, not a file inbox.** Request bytes never touch disk, so no
  secret-bearing or variables-bearing files exist to clean up. Peer
  credentials are available, and there is no polling latency.

**Ownership.** The App and the CLI both `lstat` `run/` and require all of:

- a directory, not a symlink;
- owner equal to `geteuid()`;
- mode `& 0o077 == 0`.

The socket file must be a socket, owner euid, mode `0600`. The App binds with
`umask(0o177)` around `bind`, then `chmod 0600`. Any violation gives
`app_channel_insecure`.

- If `run/` is insecure, the App stops before phase B (§3.4): no lock, no
  state load.
- If the bound socket fails its post-bind check, the App keeps the lock and
  its state but closes the listener.
- The CLI does not connect in either case.

**Peer authentication.** The App calls `getpeereid` on every accepted
connection and requires the peer uid to equal `geteuid()`, otherwise it closes
the connection with no response. The CLI applies the same check to the server
peer.

**Framing.** One request and one response per connection. Each frame is a
4-byte big-endian length followed by UTF-8 JSON.

- Request frame ≤ 576 KiB: the 512 KiB run body plus the envelope.
- Response frame ≤ 1 MiB (the existing CLI cap).
- An oversized length prefix gets the response `{status:413, body:{error:{code:"request_too_large"}}}`
  without reading the body.
- The App closes any connection that has not delivered a complete request
  within 5 s.

**Request envelope.** The key set is exact; extra or missing keys give 400
`invalid_request`:

```json
{"version":1,"requestId":"<lowercase uuid>","operation":"bootstrap|instance.reload|instance.run|instance.cancel|environment.status|environment.reload|launch.status",
 "profile":"default","identity":"<id>|null","sessionId":"<id>|null","launchId":"<id>|null","body":{…}|null}
```

The per-operation required fields are the path parameters of the matching HTTP
route. `profile` replaces `x-riela-profile`. Mutating bodies keep
`expectedProfile` and `expectedRevision`, which the CLI obtains from
`bootstrap` exactly as over HTTP.

There is no CSRF or Origin check: same-uid peer authentication replaces the
browser guards. Those guards exist only for the TCP listener.

**Response.** `{"version":1,"requestId":"…","status":<int>,"body":<json>}`.
`status` and `body` are the `RielaAppControlResult` from §3.3, so the CLI
reuses today's HTTP error mapping (`EnvironmentClientStatus.safeCode`, the
`committed`/`partial` handling, `app_http_<status>`).

**Idempotency.** This is an in-memory App cache keyed by `requestId`, holding
the SHA-256 of the canonical envelope without `requestId`, a state
(`inFlight`/`done(response)`), and a 10 min TTL. It holds at most 512 entries;
it evicts the oldest `done` entries first, and if every entry is in flight it
rejects with 503 `channel_busy`.

| Case | Result |
| --- | --- |
| Same id and digest, still in flight | waits for the same result |
| Same id and digest, done | cached response replayed; the operation is not re-run |
| Same id, different digest | 409 `request_id_conflict` |

Read-only operations (`bootstrap`, `environment.status`, `launch.status`) are
not cached. Cached bodies are the same bodies the HTTP route would return, so
they contain no secrets (§3.8).

**CLI timeouts and retry.**

- Connect timeout is 2 s; the per-request response timeout is 30 s, the same
  as the HTTP transport.
- If the connection closes after the request was fully written and before any
  response byte, the CLI retries once with the **same** `requestId`.
- On timeout it reports `app_channel_timeout`. The outcome is unknown, and the
  message tells the user to check `riela instance executions`. It does not
  retry.
- A malformed or oversized response gives `app_channel_protocol_error`.

**Lifecycle.**

- The listener runs on its own accept task and does not block the main actor.
  Handling hops to the service, and `ports.serialized` hops to the main actor.
- On App termination the App stops accepting, unlinks `control.sock`, and
  releases the lock (at process exit).
- On an App profile switch the channel keeps running and serves the new
  `daemonProfileName`. Requests for the old profile get the profile-conflict
  codes.

### 3.6 CLI client

`RielaAppAPIClient` gains a mode, `.http(endpoint)` or
`.local(appRoot, homeDirectory)`. The commands keep one code path:
`bootstrap()` → `post(operation…)` / `get(operation…)`. Each command method
maps to an operation, not to a URL path.

- HTTP mode builds exactly today's requests.
- Local mode builds channel envelopes, or runs the local read or reload
  directly.

The existing `Transport` HTTP injection seam stays. A second seam lets tests
inject the environment (`RIELA_APP_ROOT`, `HOME`) into `InstanceAppCommands`
and `EnvironmentCommand`.

The output JSON shapes of all commands are unchanged. The hint for
`app_unreachable` (HTTP only) stays. The hint for `app_not_running` is "start
RielaApp, or use --server".

### 3.7 Local operations (no App needed)

**Executions list.** Steps:

1. Read `daemon-workflows.json` with the existing read-only loader
   (`loadReadOnlyResult`, which never quarantines).
2. Resolve the instance's source:
   - `selected-workflow:<dir>`: the directory itself;
   - otherwise `RielaAppProfileWorkflowSources.discover` filtered by
     `preference.sourceIdentity`.
3. Call `RielaAppInstanceExecutionsProjection.list` on
   `sessionStoreRootURL(home, profile)`.

If the source can't be resolved, the code is `invalid_workflow_source`.

**Execution detail status** for `run --wait` and `cancel --wait` uses the same
resolution with `detailStatus`. The CLI re-encodes the same closed field set
as today.

**Local reload** runs only when the probe acquired the lock, and holds it from
the probe until the relink save returns.

Hard cap: 30 s. The cap is checked only before the definition import starts.
Exceeding it aborts with `app_channel_timeout` and `committed: false`, with
nothing written. Once the commit starts (one SQLite transaction plus one
atomic file save), it runs to completion before the lock is released. A CLI
therefore never releases the lock mid-commit.

It calls the same
`RielaAppInstanceReloadCoordinator` with `RielaAppLocalReloadPorts` (in
`RielaCLI`, because `InstanceReloadSupport` lives there):

| Port | Local behaviour |
| --- | --- |
| `validateRevision` | checks the profile only. There is no live revision; the lock provides exclusion |
| `currentInstance` / `discoverCandidate` | uses the disk resolution above. `--workflow-definition-dir` uses `discoverSelectedWorkflowDirectory` as in the App |
| `validate`, `importDefinition` | the same `InstanceReloadSupport` calls the App makes, against `sessionStoreRootURL(home, profile)` |
| `childRunning` | `false`, so `respawnRequired` is false and the coordinator sends no admission frames |
| `relink` | re-reads `daemon-workflows.json` under the lock, applies the same mutation as the App, and saves with `RielaAppDaemonWorkflowStore.save` |
| `refreshCache` | no-op |
| `revision` | nil |

The response is the D4 shape with `runtimeStatus: "stopped"`,
`handoff: "none"`, `eventBindings.respawned: false`, and `revision` omitted
(the field becomes optional; HTTP and channel responses always include it).
The next App launch reads the committed head and the relinked state. The
definition-store write is a guarded SQLite transaction
(`expectedCurrentVersionId`), so it is safe even against concurrent writers.

### 3.8 Secrets

The channel carries only these:

- the existing request bodies: reason, workflow directory, variables supplied
  by the caller, session ids;
- the existing response bodies: environment status names, readiness and
  generation, never values.

No request or response is written to disk, and the idempotency cache is memory
only. Channel logs record the operation, a request-id prefix, the status and
the safe code only, never bodies. A test asserts that a fake environment
holding a secret value never appears in responses, logs or the cache.

### 3.9 `instance run` without an App

`instance run` without an App returns `app_not_running`. This design adds **no**
in-process run flag. The request allows one ("may … only if explicitly
requested"), but it would run with the CLI's environment instead of the App's
credentials, outside the App's overlap and admission control. That is a
materially different trust and behaviour boundary with no accepted acceptance
test. The question is recorded in `design-docs/user-qa/qa-serverless-app-control.md`.

### 3.10 Error codes

New codes, all safe-code shaped and all exit code 1, except `app_server_required`
(usage, exit 2):

| Code | When |
| --- | --- |
| `app_not_running` | lock acquired; live-only command |
| `app_channel_unavailable` | lock held by the App, socket not answering |
| `app_channel_insecure` | ownership or permission check failed |
| `app_channel_path_too_long` | socket path over 103 bytes |
| `app_channel_timeout` | no response within 30 s, or the local reload lock cap was hit |
| `app_channel_protocol_error` | malformed or oversized response |
| `request_too_large` (413) | oversized request frame |
| `invalid_request` (400) | bad envelope |
| `request_id_conflict` (409) | same request id, different digest |
| `channel_busy` (503) | idempotency cache full of in-flight entries |

Existing route codes pass through unchanged.

### 3.11 Docs

- `docs/app-instance-control.md`:
  - replace "Prerequisites" and "Discovery" with local mode vs `--server`
    precedence;
  - add the `run/` lock and socket, permissions, `app_not_running`, local
    reload semantics, the new codes, and the one-time App upgrade;
  - note the `riela environment` default change.
- `README.md` CLI section: one paragraph on the mode precedence, with a link.
- `design-instance-reload-run-cli.md` D1 gets a "superseded by" pointer.

## 4. Rollout constraints

- **One-time App upgrade.** An App older than this change holds no lock and no
  socket. The CLI then sees "not running", so live commands fail with
  `app_not_running`, and a local `instance reload` would write next to a
  running old App. The old App re-saves its in-memory `daemon-workflows.json`
  on its next change, which could drop a relink. Docs state that the App must
  be upgraded before relying on local mode; `--server` keeps working against
  an old App. Development and tests never touch the App running on this
  machine or `~/Library/Application Support`.
- **Callers relying on implicit HTTP** must add `--server` (§3.1).

## 5. Verification

All tests use temp app roots `/tmp/rac-<8 hex>` and temp `HOME`. None of them
start a real RielaApp.

**`RielaAppSupportTests`**

- Service tests with fake ports; each operation's status and body match the
  pre-refactor App rendering:
  - reload: success, 409 `instance_run_in_flight` with `committed:false`,
    `partial`;
  - cancel: explicit and sole, `ambiguous_running_sessions`;
  - run: 202 / 400 `invalid_configured_run` / 422 `instance_not_ready`;
  - environment status and reload: 200 / 422 with `lastError` / 409
    `profile_or_instance_conflict`;
  - profile mismatch;
  - shutdown → `instance_busy`.
- Channel server tests (in-process server with fake ports):
  - framing round trip;
  - oversized prefix → 413 without reading the body;
  - malformed JSON or extra key → 400;
  - incomplete request closed after the read deadline (injected short
    deadline, no sleeps beyond it);
  - idempotent replay: the fake records one execution for two sends;
  - in-flight dedupe;
  - `request_id_conflict`;
  - `channel_busy`;
  - insecure directory or socket mode refuses to start;
  - path > 103 bytes refused;
  - secrets never in response, log sink or cache.
- Lock: a second process-level `flock` probe sees busy while held and free
  after release.
- **Startup-versus-local-reload regression.** This is deterministic, with no
  sleeps-as-synchronization. The App's lock wait and phase-B sequence are a
  small `RielaAppSupport` type (`RielaAppOwnerStartup`: validate `run/` →
  blocking lock acquire → unlink stale socket → bind → run the phase-B
  closure), so the test can drive them without launching RielaApp. Using a
  temp root with `daemon-workflows.json` whose instance source is directory A:
  1. The test acquires `app.lock` through the CLI local-reload lock path.
  2. It starts `RielaAppOwnerStartup` with an injected wait-deadline observer.
     The phase-B closure records when it runs, loads state with
     `RielaAppDaemonWorkflowStore.load`, and keeps it as an in-memory copy.
  3. Assert that phase B has not run and no socket exists after the observer
     reports a wait longer than the former 10 s policy. Use an injected clock;
     the real wait is an indefinite `flock`.
  4. Complete the local reload relink to directory B, save, and release the
     lock.
  5. Assert that phase B runs only now, that the loaded state has source B,
     and that the socket is bound.
  6. Mutate an unrelated preference on the in-memory copy, save it, re-read
     the file, and assert that the source is still B.
- A startup whose lock is held by a live owner, with a bound socket from an
  in-test server, never unlinks or replaces that socket.
- An insecure `run/` stops startup before phase B: no lock, no socket, no
  state load.
- `RielaAppProfileWorkflowSources.discover` matches the former App function
  output for a fixture profile.
- `RielaAppInstanceExecutionsProjection` output equals the former route items.

**`RielaCLITests`**

- Mode selection: no `--server` → local; `--server` → HTTP; non-macOS
  local → `app_server_required` (compile-guarded).
- With an in-process channel server plus fake App ports on a temp root:
  - `instance reload|run|cancel` and `environment status|reload` succeed;
  - envelopes carry the expected operation and body keys;
  - the JSON output is identical to HTTP-mode output for the same fake
    responses.
- No App (lock free):
  - `run`, `cancel` and `environment *` → `app_not_running`;
  - `executions` reads a fixture SQLite session store;
  - local `reload` imports the definition (outcome `seeded`) and relinks
    `daemon-workflows.json`;
  - local `reload` with an invalid definition → 422-equivalent code, nothing
    written.
- Lock held without a socket → `app_channel_unavailable`.
- Socket owned by another mode (`0666`) → `app_channel_insecure`.
- Connection dropped after write → one retry with the same `requestId`.
- Existing HTTP tests (`InstanceAppCommandsTests`,
  `InstanceAppCancelCommandTests`, `RuntimeEnvironmentChannelTests`):
  - assertions unchanged;
  - cases that relied on the implicit default endpoint gain an explicit
    `--server`;
  - the `resolveEndpoint(server: nil…)` port-discovery assertions are replaced
    by mode-selection assertions (§3.1 removes that discovery).
- App-side HTTP API tests are not modified.

**Commands** (arm64 shell, worktree root; logs under `tmp/serverless-app-control/`):

- `arch -arm64 /bin/zsh -lc 'swift build'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter RielaAppSupportTests'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter RielaCLITests'`
- `arch -arm64 /bin/zsh -lc 'swiftlint'`

## 6. Risks and residual limits

- **Old App running.** See §4. Mitigated only by documentation and the
  one-time upgrade.
- **App waits on a held lock.** The App never runs unlocked, so a local reload
  cannot lose its relink to a concurrent launch (§3.4 ownership invariant,
  regression in §5). The cost: if a CLI holding the lock is stopped
  (`SIGSTOP`), the App stays in the visible "waiting for a local riela CLI
  operation" state until that CLI exits. Normal holds are bounded by the 30 s
  pre-commit cap plus one commit.
- **Default behaviour change** for `riela environment` and
  `instance reload|run|cancel|executions` without `--server` (§3.1).
- **Socket path length** with long custom app roots: reported, not silently
  degraded.
- **Instances whose source only the running App can discover.** Local
  executions and reload report `invalid_workflow_source`; `--server`
  remains available.
- **Refactor drift.** Mitigated by moving rendering code verbatim and by
  service tests that pin status and body per route. App HTTP tests stay
  unchanged.
