# sac-07-cli-instance-local-mode: `riela instance reload|run|cancel|executions` local mode

- planId: `sac-07-cli-instance-local-mode`
- wave: 3, dependsOn: `sac-01-control-contract`, `sac-02-owner-lock-startup`, `sac-03-sources-and-projection`, `sac-04-control-service`, `sac-05-control-channel`
- design: `design-docs/specs/design-serverless-app-control.md` §3.1, §3.2, §3.6, §3.7, §3.10
- writePaths:
  - `Sources/RielaCLI/RielaAppLocalControl.swift` (new)
  - `Sources/RielaCLI/RielaAppAPIClient.swift` (add a shared failure-mapping helper; `resolveEndpoint` unchanged)
  - `Sources/RielaCLI/InstanceAppCommands.swift`
  - `Tests/RielaCLITests/InstanceAppLocalModeTests.swift` (new)
  - `impl-plans/progress/sac-07-cli-instance-local-mode.md`
  - `tmp/serverless-app-control/build-sac-07` (artifact root only; private SwiftPM scratch path, see Amendment 2026-11-12)
- artifactRoots: `tmp/serverless-app-control/build-sac-07`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-07/`

## Intent and context

Without `--server`, the instance commands work against the local App with no
HTTP:

- live operations go over the owner-only socket;
- `executions` and the execution-detail polls are local SQLite reads;
- `reload` with no App running is a local, lock-holding reload through the
  **same** `RielaAppInstanceControlService` with local ports.

With `--server <url>`, behaviour is byte-identical to today. The command
output JSON shapes do not change in either mode.

Read first:

- `Sources/RielaCLI/InstanceAppCommands.swift`, which holds today's whole
  flow: bootstrap, the reload `--wait-idle` loop, cancel `--wait`, run
  polling, executions, and `localInstanceExists`;
- `Sources/RielaCLI/RielaAppAPIClient.swift`;
- `Sources/RielaApp/RielaAppInstanceReloadAPI.swift`, whose `RielaAppReloadPorts`
  is the App behaviour that the local ports mirror;
- `Sources/RielaCLI/InstanceReloadSupport.swift`.

## Non-goals

- No `--app-root`, `--project-dir` or `--working-dir` option, and no env var
  for the mode.
- No in-process run flag: `run` without an App → `app_not_running`.
- Do not modify `Tests/RielaCLITests/InstanceAppCommandsTests.swift` or
  `Tests/RielaCLITests/InstanceAppCancelCommandTests.swift`. They already pass
  `--server` and must stay unchanged and green.
- Do not change `RielaAppAPIClient.resolveEndpoint`'s behaviour. Its
  nil-server branch stays so the existing `testDiscoveryIsReadOnlyAndValidatesServer`
  passes unchanged (the acceptance criterion "existing HTTP client tests
  unchanged"). Command flow no longer calls it without a server.

## File-level changes

### `RielaAppAPIClient.swift`

Extract the non-2xx mapping from `fetch` into
`static func failure(status: Int, body: Data) -> RielaAppAPIFailure`. It keeps
the same `safeCode` / `app_http_<status>` logic and the 1 MiB check; `fetch`
calls it. No behaviour change.

### `RielaAppLocalControl.swift`

**`protocol RielaAppInstanceControlClient: Sendable`** (internal), with one
method per command need:

```swift
var profile: String { get }
func bootstrapRevision() async throws -> Int
func reload(identity: String, body: [String: Any]) async throws -> Data
func cancel(identity: String, sessionId: String?, body: [String: Any]) async throws -> Data
func run(identity: String, body: [String: Any]) async throws -> Data
func launchStatus(launchId: String) async throws -> Data
func executions(identity: String) async throws -> Data
func executionDetail(identity: String, sessionId: String) async throws -> Data
```

Errors are always `RielaAppAPIFailure(code:status:body:)`.

**`struct RielaAppHTTPInstanceControlClient`** wraps `RielaAppAPIClient`:

- each method makes exactly today's request: the same path, `bootstrap()`
  before every post, and the CSRF and Origin headers;
- `bootstrapRevision()` is `client.bootstrap().revision`.

**`struct RielaAppLocalInstanceControlClient`** has fields `appRoot`,
`homeDirectory`, `profile`, and an injectable `probe` closure (default
`RielaAppLocalControlProbe.resolve`).

The live operations are `bootstrapRevision`, `cancel`, `run` and
`launchStatus`. Each one probes:

| Probe result | Action |
| --- | --- |
| `.channel(c)` | `c.send(op, profile:)`, mapping the result with `RielaAppAPIFailure` via `failure(status:body:)` for non-2xx and returning the body `Data` for 2xx |
| `.notRunning(lock)` | release the lock, throw `app_not_running` (status 0) |
| `RielaAppControlChannelError.code(c)` | throw `c.rawValue` |

Operation mapping:

- `cancel` → `.cancel(identity:sessionId:body:)`;
- `run` → `.run(...)`;
- `launchStatus` → `.launchStatus`.

Bodies are `JSONSerialization` data of today's dictionaries.

`bootstrapRevision` behaves as follows:

- channel → `.bootstrap`, decode `revision`;
- not running → release the lock immediately and return 0. `reload` probes
  again separately (below), so a reload's lock is held only inside `reload`.

`reload` probes:

- `.channel` → send `.reload`;
- `.notRunning(lock)` → **local reload**, holding `lock` until it returns:
  - run `RielaAppInstanceControlService(ports: RielaAppLocalControlPorts(...)).handle(.reload(identity:body:), profile: profile)`;
  - 2xx → body `Data`; non-2xx → `RielaAppAPIFailure` via `failure(status:body:)`;
  - release the lock in `defer`.

`executions` and `executionDetail` need no probe and are local reads:

1. Load `<appRoot>/profiles/<profile>/daemon-workflows.json` read-only with
   `RielaAppDaemonWorkflowStore(...).loadReadOnlyResult()`. Check its
   signature; it must never quarantine or write.
2. Take `preference.sourceIdentity` for the identity.
3. `RielaAppProfileWorkflowSources.resolveSource(...)`. nil → throw
   `invalid_workflow_source` (status 422).
4. For `executions`: `RielaAppInstanceExecutionsProjection.list(identity:, workflowDirectory:, sessionStoreRoot: RielaAppProfileStore.sessionStoreRootURL(homeDirectory:profileName:).path, revision: nil)`,
   encoded as `Data`.
5. For `executionDetail`: `detailStatus` → `{"sessionId","status","updatedAt"}`,
   or 404 `session_not_found` when nil.

**`struct RielaAppLocalControlPorts: RielaAppInstanceControlPorts`** (used
only when no App is running):

| Port | Behaviour |
| --- | --- |
| `profile()` | the CLI profile |
| `bootstrap()` | `{profile, 0}` |
| `isShuttingDown()` | false |
| `serialized` | runs the body directly; the lock provides exclusion |
| `reloadPorts()` | `RielaAppLocalReloadPorts` |
| `cancelPorts()` | unused; returns a ports value whose methods report not found |
| other live ports | return `RielaAppControlResult.error(status: 409, code: "app_not_running")`, or the equivalent `.notReady`, false or empty values; never reached in practice |

**`final class RielaAppLocalReloadPorts: RielaAppInstanceReloadPorts`**
(design §3.7 table), with fields `appRoot`, `homeDirectory`, `profile` and
`deadline: Date` (30 s from the probe).

- `currentInstance`: from `daemon-workflows.json`, using the resolution above:
  `{identity, workflowId: candidate.workflowId, sourceId, workflowDirectory, eventRoot}`.
  nil when the preference or source is missing.
- `validateRevision`: only `expectedProfile == profile`, otherwise throws
  `RielaAppInstanceReloadError(code: .configurationConflict)`.
- `discoverCandidate`: mirrors `RielaAppReloadPorts.discoverCandidate`, with
  `discoverSelectedWorkflowDirectory` for a requested directory or a
  `selected-workflow:` source, and `resolveSource` otherwise.
- `validate`: `InstanceReloadSupport.validateCandidate(...)`, with node patches
  from the preference's `configuration.nodePatches`, exactly like the App.
- `installedStartRecord` → nil; `childRunning` → false; `admission` → throws.
  The coordinator never calls it because no respawn is needed.
- `importDefinition`: **first** check `Date() < deadline`. If the deadline has
  passed, set `timedOut = true` and throw. Otherwise call
  `InstanceReloadSupport.importDefinition(storeRoot: sessionStoreRootURL(...).path, …)`
  exactly like the App.
- `relink`: re-read `daemon-workflows.json` with the normal store `load()`
  under the held lock, apply the same mutation as `RielaAppReloadPorts.relink`
  (append the directory if absent, set `preference.identity` and
  `sourceIdentity`), save with `RielaAppDaemonWorkflowStore.save`, and return 0.
- `refreshCache` → no-op; `replaceChild` → throws (unreachable).
- `profile()` → profile; `revision()` → 0; `liveRevision()` → **nil**.

After the service returns, if `timedOut` is set, the client throws
`app_channel_timeout` (`committed:false`) instead of the service's
`definition_store_failure`.

### `InstanceAppCommands.swift`

- `init(transport:sleep:environment:)`: add `environment: [String: String]? = nil`
  (default `CLIRuntimeEnvironment.mergedProcessEnvironment()`). It feeds
  `appRoot`, `homeDirectory` (`CLIRuntimeEnvironment.homeDirectory(environment:)`)
  and the profile.
- Mode:
  - `args.server != nil` → `RielaAppHTTPInstanceControlClient` with
    `resolveEndpoint(server:…)` (today's path, injected transport honoured);
  - otherwise, on macOS → `RielaAppLocalInstanceControlClient`;
  - on non-macOS → usage error `app_server_required`.
- `localInstanceExists` stays for local mode, as today.
- `reload`, `cancel`, `runInstance` and `executions` call the protocol
  methods instead of building paths. The retry, poll, wait and output logic is
  untouched. Every path and header lives in the HTTP client.
- Error hints:
  - `app_unreachable` keeps today's hint;
  - `app_not_running` → `": start RielaApp, or use --server"`;
  - `app_channel_unavailable` → `": another local riela operation or App startup is in progress; retry"`.

## Pitfalls

- Tests **must** inject `environment` with a temp `RIELA_APP_ROOT` (`/tmp/rac-<8hex>`)
  and `HOME`. Without it, a local-mode test would probe the real
  `~/.riela/rielaapp/run`. Add an assertion helper that fails if the resolved
  appRoot does not start with `/tmp/rac-`.
- The lock is released on **every** path: `defer` right after the probe
  returns `.notRunning`.
- Never call `resolveEndpoint(server: nil…)` from command flow, and never fall
  back to HTTP when the channel fails.
- Local reload must not send admission frames or touch any child.
- Do not add `revision` to the CLI output when it is nil.
- `InstanceAppCommandsTests` and `InstanceAppCancelCommandTests` must pass
  **unmodified**. Their invocations include `--server`, so they exercise the
  HTTP client.

## Tests (`InstanceAppLocalModeTests`)

These use an in-process `RielaAppControlChannelServer` (sac-05) with a scripted
handler, plus `RielaAppRunDirectory` under `/tmp/rac-<8hex>`, a temp HOME, and
`daemon-workflows.json` fixtures.

**App running (channel)**

| Situation | Expected outcome |
| --- | --- |
| `instance run ID --variables '{"a":1}'` | the handler receives `.bootstrap` then `.run(identity:"ID", body)`; body keys `{expectedProfile, expectedRevision, variables}`; output identical to the HTTP-mode output for the same scripted 202 body (compare with an HTTP-mode run using a `ScriptedAppTransport`-style fake) |
| `instance cancel ID --reason fix` | `.cancel(sessionId: nil)`; 202 output identical to HTTP mode |
| `instance reload ID --reason r` | `.reload`; a scripted 409 `instance_run_in_flight` with `--wait-idle` retries and gets a fresh bootstrap each time (injected sleep) |
| `instance run --wait` with `launch.status` scripted to completed | output `status:"completed"` |
| The handler sees the profile from `active-profile.json` in the temp root | yes |

**App not running (lock free, no socket)**

| Situation | Expected outcome |
| --- | --- |
| `run` | exit 1, stdout `{"error":"app_not_running",…}`, stderr contains the hint; `app.lock` released afterwards (`tryAcquire` succeeds) |
| `cancel` | `app_not_running` |
| `executions` on an empty session store | exit 0, `items:[]` |
| `executions` with an unresolvable source | `invalid_workflow_source` |
| Local `reload` of a `selected-workflow:<dirA>` instance with `--workflow-definition-dir dirB` (valid bundles with the same workflowId; copy the minimal bundle from an existing `InstanceReloadSupport` test, found with grep in `Tests/RielaCLITests`) | exit 0; output `definition.outcome == "seeded"`; `runtimeStatus "stopped"`; `handoff "none"`; no `revision` key; `daemon-workflows.json` now has `sourceIdentity` for dirB and `workflowDirectories` contains dirB; the lock is released |
| Local reload with an invalid `workflow.json` | `invalid_workflow_definition`, `committed:false`; `daemon-workflows.json` bytes unchanged |
| Local reload with the deadline injected as already passed | `app_channel_timeout`; nothing written |

**Other**

| Situation | Expected outcome |
| --- | --- |
| Lock held by the test (`tryAcquire`), no socket | `run` → `app_channel_unavailable` |
| Socket chmod `0666` | `app_channel_insecure` |
| `--server http://127.0.0.1:19091` with a scripted HTTP transport | the local probe is never invoked (an injected probe closure fails the test if called) |

## Verification (`tmp/serverless-app-control/sac-07/`)

- `mkdir -p tmp/serverless-app-control/sac-07`
- `[ -d tmp/serverless-app-control/build-sac-07/checkouts ] || { mkdir -p tmp/serverless-app-control/build-sac-07 && cp -cR .build/. tmp/serverless-app-control/build-sac-07/; }`
  seeds the private scratch path once (APFS clone of the quiescent shared `.build`); must exit 0.
- `arch -arm64 /bin/zsh -lc 'swift build --scratch-path tmp/serverless-app-control/build-sac-07 --build-tests' > tmp/serverless-app-control/sac-07/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --scratch-path tmp/serverless-app-control/build-sac-07 --skip-build --filter 'InstanceAppLocalModeTests|InstanceAppCommandsTests|InstanceAppCancelCommandTests'" > tmp/serverless-app-control/sac-07/test.log 2>&1`
  must exit 0.
- `git diff --exit-code -- Tests/RielaCLITests/InstanceAppCommandsTests.swift Tests/RielaCLITests/InstanceAppCancelCommandTests.swift`
  must exit 0.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/RielaAppLocalControl.swift Sources/RielaCLI/RielaAppAPIClient.swift Sources/RielaCLI/InstanceAppCommands.swift Tests/RielaCLITests/InstanceAppLocalModeTests.swift' > tmp/serverless-app-control/sac-07/lint.log 2>&1`
- `ls ~/.riela/rielaapp/run 2>&1 | tee tmp/serverless-app-control/sac-07/real-root-check.log`.
  Record in the progress log that no tests created or changed files there. If
  it exists, compare mtimes before and after the test run.

## Done criteria

- Local and HTTP modes work as in the tables above.
- The existing HTTP tests are unchanged and green.
- No real app root is touched.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.

## Amendment 2026-11-12 (blocked-wave-scope-or-contract, round 1)

Blocker (raised on sac-05, applied to every pending plan that builds):
"Authorized build-output location". `artifactRoots` was empty, so SwiftPM
builds had no authorized output location.

Decision:
- This plan owns the private SwiftPM scratch path
  `tmp/serverless-app-control/build-sac-07`. It is in `writePaths` and is the
  plan's only `artifactRoots` entry, recorded as a digest/count manifest only,
  never as content. sac-06, sac-07 and sac-08 run in the same wave, so each
  gets its own scratch path. No two same-wave plans write one build directory.
- This plan must NOT write the shared `.build`. That path belongs to sac-05
  (wave 2). The only allowed access is the one-time read-only seed
  `cp -cR .build/. tmp/serverless-app-control/build-sac-07/` (APFS clone,
  skipped when `checkouts` already exists). Expect a large rebuild on first
  use, because SwiftPM paths are absolute. The seed mainly reuses dependency
  checkouts and avoids network fetches.
- Every `swift build` and `swift test` command in this plan passes
  `--scratch-path tmp/serverless-app-control/build-sac-07`. Do not add
  `.build/debug/riela`-dependent suites, because they read the shared `.build`.
  The filtered suites in Verification do not use it.
- Evidence logs stay under `tmp/serverless-app-control/sac-07/`. Record the
  scratch path and the seed command's exit code in the progress log.
- Leave the scratch path in place after verification. Removing it belongs to
  serial finalization, not to this plan. No source, contract or design change
  is involved, and all other sections stay in force.
