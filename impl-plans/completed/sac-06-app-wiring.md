# sac-06-app-wiring: RielaApp adapters, deferred locked startup, channel host

- planId: `sac-06-app-wiring`
- wave: 3, dependsOn: `sac-02-owner-lock-startup`, `sac-03-sources-and-projection`, `sac-04-control-service`, `sac-05-control-channel`
- design: `design-docs/specs/design-serverless-app-control.md` §3.3, §3.4 (ownership invariant, deferred initialization), §3.5 (lifecycle)
- writePaths:
  - `Sources/RielaApp/RielaAppControlHost.swift` (new: `RielaAppControlPorts` adapter + channel host glue)
  - `Sources/RielaApp/RielaAppInstanceAPI.swift`
  - `Sources/RielaApp/RielaAppInstanceReloadAPI.swift` (handler only; keep `RielaAppReloadPorts` and `reloadStartRecord`)
  - `Sources/RielaApp/RielaAppInstanceCancelAPI.swift` (handler only; keep `RielaAppCancelPorts`)
  - `Sources/RielaApp/RielaAppConfiguredRunAPI.swift`
  - `Sources/RielaApp/EntryPoint.swift`
  - `Sources/RielaApp/EntryPoint+Environment.swift` (`daemonSessionStoreRoot` only)
  - `Sources/RielaApp/EntryPoint+Menu.swift` (waiting-state menu only)
  - `impl-plans/progress/sac-06-app-wiring.md`
  - `tmp/serverless-app-control/build-sac-06` (artifact root only; private SwiftPM scratch path, see Amendment 2026-11-12)
  - `Tests/RielaAppSupportTests/RielaAppBehaviorRegressionTests.swift` (additive fixture fix only, see Amendment 2026-11-12 round 2)
- artifactRoots: `tmp/serverless-app-control/build-sac-06`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-06/`

## Intent and context

This plan connects the shared pieces to the real App.

1. The HTTP handlers become thin adapters over `RielaAppInstanceControlService`
   (sac-04), so HTTP and the socket cannot drift.
2. `applicationDidFinishLaunching` is split into phase A and phase B around
   `RielaAppOwnerStartup` (sac-02). The App therefore never loads or writes
   profile state without holding `run/app.lock`.
3. The channel server (sac-05) is bound inside the locked startup and serves
   the same service.
4. `daemonWorkflowSources(profileName:state:)` and `daemonSessionStoreRoot`
   delegate to the sac-03 functions.

There is no RielaApp test target. Correctness is covered by:

- the sac-04 service tests;
- the sac-02 startup regression;
- `swift build`;
- the existing RielaAppSupport route tests.

## Non-goals

- Do not change `/actions` start, stop, restart or enable logic,
  `POST /instances`, the router, CSRF or Host guards, or the web-server
  controller.
- No GraphQL changes.
- Do not run, restart or reconfigure the installed RielaApp. Do not launch the
  built App against the real home.

## File-level changes

### `RielaAppControlHost.swift`

**`@MainActor struct RielaAppControlPorts: RielaAppInstanceControlPorts`**, with
fields `app: RielaApp` and `profileName: RielaAppProfileName`.

| Port | Implementation |
| --- | --- |
| `profile()` | `app.daemonProfileName.rawValue`. Read it live, because the profile can switch at runtime |
| `bootstrap()` | `{profile, app.webRevision}` |
| `isShuttingDown()` | `app.terminationShutdownStarted` |
| `serialized(body)` | `await app.distributedControllerOperations.run { await body() }` |
| `reloadPorts()` | `RielaAppReloadPorts(app:profileName:)` |
| `cancelPorts()` | `RielaAppCancelPorts(app:profileName:)` |
| `validateRevision` | calls `app.validateGraphQLConfigurationRevision`; on a `RielaConfigurationGraphQLError` returns a `RielaAppControlConflict` with `code.lowercased()`, `message`, and status 404 for `SOURCE_NOT_FOUND`, 400 for `INVALID_CONFIGURATION`, otherwise 409 (copied from the `RielaAppInstanceAPI.swift` catch); any other error → 500 `configuration_io_failure` "Could not save execution configuration." |
| `instanceExists` | `app.daemonInstances.contains { $0.identity == identity }` |
| `environmentStatus` | `app.daemonRuntime.environmentStatus(identity: runtimeIdentity, profile:)` |
| `reloadEnvironment` | moves the body of the `.reloadEnvironment` branch of `performWebInstanceAction`, including the "start if active, not running and approved" step, and returns `.notReady` / `.reloaded(status)` / `.failed(status with lastError)` |
| `launchConfiguredRun` | moves the body of `webConfiguredRunResponse` after its input guard (revision checks, approval, `prepareEnvironment`, context, `launchConfiguredWorkflow`, the catch mapping) and converts the returned `RielaHTTPResponse` with `RielaAppControlResult(httpResponse:)` |
| `launchStatus` | builds a `RielaHTTPRequest` `GET /api/v1/workflow-editor/launches/<percent-encoded id>` with header `x-riela-profile: profile` and calls the same App function the router uses for that path (find it with `grep -rn webWorkflowEditorLaunch Sources`), then converts the response |

**`extension RielaApp`**

- `var controlService: RielaAppInstanceControlService`, built with
  `RielaAppInstanceControlService(ports: RielaAppControlPorts(app: self, profileName: daemonProfileName))`.
- `func startOwnerStartup()` creates `RielaAppRunDirectory(appRoot: profileStore.appRootURL)`
  and a `RielaAppControlChannelServer` whose handler hops to the main actor and
  calls `controlService.handle(op, profile: profile)`. Its log closure is
  `logDaemon`. Then it calls `RielaAppOwnerStartup(run:, waitObserver: { status = "Waiting for a local riela CLI operation…" on main }).start(bindChannel: server.bind, phaseB: { lock in self.ownerLock = lock; self.ownerStartupComplete = true; self.runPhaseB() }, failed: { … })`.
  - The `failed` closure shows `app_channel_insecure` in the status, logs, and
    calls `NSApp.terminate(nil)`.
  - A `bind` error (path too long or insecure socket) is logged as
    `app_channel_path_too_long` or `app_channel_insecure`; phase B still runs.

### `EntryPoint.swift`

- Add stored properties: `var ownerLock: RielaAppOwnerLock?`,
  `var ownerStartupComplete = false`, and `var controlChannel: RielaAppControlChannelServer?`.
- **Phase A** (stays in `applicationDidFinishLaunching`):
  1. `appHomeDirectory = …`
  2. `profileStore = …`
  3. color scheme
  4. `daemonProfileName = initialDaemonProfileName()`
  5. `configureStatusItem()`
  6. `rebuildMenu()`
  7. `startOwnerStartup()`

  Check that `initialDaemonProfileName()` only reads; if it writes, move it to
  phase B and use a placeholder name in phase A.
- **Phase B** (`func runPhaseB()`, `@MainActor`): everything else, in the
  current order: `startRetention()`, `prepareInitialDaemonProfile`,
  `daemonDiscovery`, `daemonStore`, `daemonState = load…`,
  `refreshDaemonInstanceCache`, telemetry, `logDaemon`, `configureWebServer`,
  the distributed controller task, `rebuildMenu`, `refreshLaunchAtLoginStatus`,
  the timer, `setStartRecordProvider`, imports, the open-flags, and autostart.
- `daemonWorkflowSources(profileName:state:)` returns
  `RielaAppProfileWorkflowSources.discover(appRootURL: profileStore.appRootURL, profileName:, state:, projectRoot: launchOptions.projectRoot)`.
  The output must be identical.
- `applicationShouldTerminate`: add `controlChannel?.stop()`, then, if
  `ownerLock` is set, `RielaAppOwnerStartup.unlinkSocketIfOwned(run, lock:)`.
  Do this before the existing awaits. Termination while phase B never ran must
  not crash: guard every runtime stop that assumes loaded state, and skip
  `webServerController` when it is nil.

### `EntryPoint+Menu.swift`

In `rebuildMenu()`, when `!ownerStartupComplete`, build only a disabled status
item (the current `status`) plus Quit. No profile, instance, console, worker or
web-server items. This prevents profile switches or edits before the lock.

### `EntryPoint+Environment.swift`

`daemonSessionStoreRoot(profileName:)` returns
`webSessionStoreRootOverride ?? RielaAppProfileStore.sessionStoreRootURL(homeDirectory: appHomeDirectory, profileName:).path`.
The path string must be identical to the old one.

### HTTP adapters

Each handler keeps its path, method and route matching exactly. It extracts
`identity`/`sessionId` (with `removingPercentEncoding`) as today, then returns
`await controlService.handle(op, profile: request.headers["x-riela-profile"]).httpResponse`.

| File | Change |
| --- | --- |
| `RielaAppInstanceReloadAPI.swift` | `webInstanceReloadResponse` → `.reload(identity:body:)`. Delete `reloadErrorResponse` (moved into the service) |
| `RielaAppInstanceCancelAPI.swift` | `webInstanceCancelResponse` → `.cancel(...)`. Delete `cancelErrorResponse` |
| `RielaAppInstanceAPI.swift` | the environment GET → `.environmentStatus`. In the `/actions` path, when the decoded `WorkflowInstanceActionInput.action == .reloadEnvironment`, return `controlService.handle(.environmentReload(identity:body: request.body), profile: nil).httpResponse` **outside** the existing `distributedControllerOperations.run` block, because the service serializes itself. Every other action keeps the existing code. Delete the moved branch and `environmentResponse` only if they are unused |
| `RielaAppConfiguredRunAPI.swift` | the handler → `.run(identity:body:)`. The moved logic now lives in `RielaAppControlPorts.launchConfiguredRun` |

Method-not-allowed (405) and path-parse 400 responses stay in the adapters
exactly as today, because they happen before any service call.

## Pitfalls

- **No unlocked state access.** After this change, `daemonState`,
  `daemonStore`, `prepareInitialDaemonProfile` and autostart must never run
  before `runPhaseB`. Grep `applicationDidFinishLaunching` after editing.
- Do not wrap `/actions` `reloadEnvironment` in `distributedControllerOperations.run`
  twice. Nested runs on the same serializer would deadlock.
- `request.headers["x-riela-profile"]` is passed as-is (it may be nil). The
  service applies the per-operation semantics.
- Keep `RielaAppReloadPorts`, `RielaAppCancelPorts` and `reloadStartRecord`.
  Tests and the reload coordinator depend on them.
- The channel handler runs off the main actor. Hop with
  `await MainActor.run { … }` or an `@MainActor` closure, and never block the
  accept thread.
- Do not touch `RielaAppWebRouter.swift`, `RielaAppWebServerController.swift`
  or `RielaAppConfigurationGraphQLProvider.swift`.

## Tests and verification (`tmp/serverless-app-control/sac-06/`)

There is no App test target. Evidence comes from build, grep invariants and
the shared suites.

- `mkdir -p tmp/serverless-app-control/sac-06`
- `[ -d tmp/serverless-app-control/build-sac-06/checkouts ] || { mkdir -p tmp/serverless-app-control/build-sac-06 && cp -cR .build/. tmp/serverless-app-control/build-sac-06/; }`
  seeds the private scratch path once (APFS clone of the quiescent shared `.build`); must exit 0.
- `arch -arm64 /bin/zsh -lc 'swift build --scratch-path tmp/serverless-app-control/build-sac-06 --build-tests' > tmp/serverless-app-control/sac-06/build.log 2>&1`
  must exit 0, including the RielaApp target.
- `arch -arm64 /bin/zsh -lc "swift test --scratch-path tmp/serverless-app-control/build-sac-06 --skip-build --filter 'RielaAppInstanceReload|RielaAppInstanceCancel|RielaAppInstanceControlServiceTests|RielaAppWebAPIRouteTests|RielaAppInstanceExecutionsProjectionTests|RielaAppOwnerStartupTests|RielaAppControlChannelTests|RuntimeEnvironment'" > tmp/serverless-app-control/sac-06/test.log 2>&1`
  must exit 0.
- `grep -n "loadDaemonStateReportingCorruption\|prepareInitialDaemonProfile()\|autostartDaemonWorkflows()" Sources/RielaApp/EntryPoint.swift > tmp/serverless-app-control/sac-06/phase-grep.log`.
  Record in the progress log that every such call is inside `runPhaseB` or a
  later user action, never in `applicationDidFinishLaunching`.
- `! grep -n "func reloadErrorResponse\|func cancelErrorResponse" Sources/RielaApp`
  must print nothing (the rendering moved).
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaApp/RielaAppControlHost.swift Sources/RielaApp/RielaAppInstanceAPI.swift Sources/RielaApp/RielaAppInstanceReloadAPI.swift Sources/RielaApp/RielaAppInstanceCancelAPI.swift Sources/RielaApp/RielaAppConfiguredRunAPI.swift Sources/RielaApp/EntryPoint.swift Sources/RielaApp/EntryPoint+Environment.swift Sources/RielaApp/EntryPoint+Menu.swift' > tmp/serverless-app-control/sac-06/lint.log 2>&1`

## Done criteria

- The build is green.
- The listed suites are green.
- The phase-grep invariant is recorded.
- The HTTP handlers call `controlService.handle`, checked with
  `grep -n controlService.handle Sources/RielaApp` showing reload, cancel, run,
  environment and actions.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.

## Amendment 2026-11-12 (blocked-wave-scope-or-contract, round 1)

Blocker (raised on sac-05, applied to every pending plan that builds):
"Authorized build-output location". `artifactRoots` was empty, so SwiftPM
builds had no authorized output location.

Decision:
- This plan owns the private SwiftPM scratch path
  `tmp/serverless-app-control/build-sac-06`. It is in `writePaths` and is the
  plan's only `artifactRoots` entry, recorded as a digest/count manifest only,
  never as content. sac-06, sac-07 and sac-08 run in the same wave, so each
  gets its own scratch path. No two same-wave plans write one build directory.
- This plan must NOT write the shared `.build`. That path belongs to sac-05
  (wave 2). The only allowed access is the one-time read-only seed
  `cp -cR .build/. tmp/serverless-app-control/build-sac-06/` (APFS clone,
  skipped when `checkouts` already exists). Expect a large rebuild on first
  use, because SwiftPM paths are absolute. The seed mainly reuses dependency
  checkouts and avoids network fetches.
- Every `swift build` and `swift test` command in this plan passes
  `--scratch-path tmp/serverless-app-control/build-sac-06`. Do not add
  `.build/debug/riela`-dependent suites, because they read the shared `.build`.
  The filtered suites in Verification do not use it.
- Evidence logs stay under `tmp/serverless-app-control/sac-06/`. Record the
  scratch path and the seed command's exit code in the progress log.
- Leave the scratch path in place after verification. Removing it belongs to
  serial finalization, not to this plan. No source, contract or design change
  is involved, and all other sections stay in force.

## Amendment 2026-11-12 (integration-paths-outside-writePaths, round 2)

Finding `IR-SAC06-MENU-REGRESSION-TEST` (mid, serial integration review):
`RielaAppBehaviorRegressionTests.testStatusMenuUsesCompactSummaryItemsAtRuntime`
fails on the combined tree (assertions at lines 449, 450, 451, 457). It builds
`RielaApp()` without owner startup, so `ownerStartupComplete` stays `false`
(`Sources/RielaApp/EntryPoint.swift:80`) and `rebuildMenu()`
(`Sources/RielaApp/EntryPoint+Menu.swift:21`) returns the plan-mandated
waiting-state menu (status + Quit). Evidence:
`tmp/serverless-app-control/serial-reconcile-wave-006/test-targets-2.log`.
The production behaviour is correct; the test fixture predates it.

Decision (scope only; no design, contract or production change):
- `Tests/RielaAppSupportTests/RielaAppBehaviorRegressionTests.swift` is added
  to this plan's `writePaths` (here and in
  `impl-plans/active/serverless-app-control-dispatch.json`). sac-06 is its only
  owner. No other plan writes it. It is a source path, not an artifact root.
- Ordered changes:
  1. In `testStatusMenuUsesCompactSummaryItemsAtRuntime`, set
     `app.ownerStartupComplete = true` immediately before `app.rebuildMenu()`
     (line 446). The test already uses `@testable import RielaApp` and sets the
     internal `app.daemonCandidates` the same way.
  2. Add one small test, for example
     `testStatusMenuShowsOnlyStatusAndQuitBeforeOwnerStartup`: a fresh
     `RielaApp()` with `ownerStartupComplete == false`, then `rebuildMenu()` →
     the menu has no `Open Console...`, no `Launch on Login`, no `About Riela`,
     contains `Quit`, and every non-separator, non-Quit item is disabled. This
     pins the waiting state from §EntryPoint+Menu.swift.
  3. Record build/test/lint exit codes and log paths in
     `impl-plans/progress/sac-06-app-wiring.md`.
- Forbidden:
  - Do not change `EntryPoint+Menu.swift` waiting-state behaviour, the lock or
    phase B ordering, or any other production file for this finding.
  - Do not delete, skip, reorder or loosen any existing assertion
    (lines 448–467 stay byte-identical). The diff of the test file must be
    additions only.
  - Do not call `startOwnerStartup()` or `runPhaseB()` in tests, and do not
    touch `~/.riela/rielaapp` or `~/Library/Application Support`.
  - Do not touch `RielaAppWebStartupTests` (dispositioned baseline failure) or
    other plans' files.
- Verification (evidence under `tmp/serverless-app-control/sac-06/`):
  - `arch -arm64 /bin/zsh -lc 'swift build --scratch-path tmp/serverless-app-control/build-sac-06 --build-tests' > tmp/serverless-app-control/sac-06/build-amend2.log 2>&1`
    must exit 0.
  - `arch -arm64 /bin/zsh -lc "swift test --scratch-path tmp/serverless-app-control/build-sac-06 --skip-build --filter 'RielaAppBehaviorRegressionTests'" > tmp/serverless-app-control/sac-06/test-amend2.log 2>&1`
    must exit 0 with `Executed N tests, with 0 failures`, N > 0 and including
    the two menu tests.
  - `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Tests/RielaAppSupportTests/RielaAppBehaviorRegressionTests.swift' > tmp/serverless-app-control/sac-06/lint-amend2.log 2>&1`
    must exit 0.
  - `git diff -U0 -- Tests/RielaAppSupportTests/RielaAppBehaviorRegressionTests.swift > tmp/serverless-app-control/sac-06/test-diff-amend2.log`
    must contain no `-` content lines (additions only).
  - `shasum -a 256 Sources/RielaApp/EntryPoint+Menu.swift` run before the first
    edit and again after verification must print the same digest (the file is
    already uncommitted-modified by sac-06, so `git diff` cannot show this);
    record both digests in the progress log.
- Done when: the four commands above meet their criteria, and at the serial
  gate `RielaAppSupportTests` has only the dispositioned
  `RielaAppWebStartupTests` baseline failure left.

## Implementation progress 2026-11-12

App wiring, locked startup, channel lifecycle, and shared source/session-path delegation are implemented. The private scratch build passed after clearing a cloned module cache; the assigned suites passed 115 tests with no failures, and both plan lint and strict changed-file lint passed. Evidence and source hashes are recorded in `impl-plans/progress/sac-06-app-wiring.md` and `tmp/serverless-app-control/sac-06-app-wiring/`. Independent review and serial integration remain downstream.

Integration repair: the ready-state menu fixture and new waiting-state test pass (16 regression tests); the rebuilt assigned suites pass 115 tests. The test diff is additions only and the production menu hash is unchanged. The serial aggregate gate remains downstream.
