# RielaApp Local HTTP Transport and Application API Implementation Plan

**Status**: Ready
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`
**Feature ID**: `http-transport-api`
**Design Reference**: `design-docs/specs/design-rielaapp-web-server-http-transport.md`
**Created**: 2026-07-17
**Last Updated**: 2026-07-17

---

## Design Document Reference

**Source**: `design-docs/specs/design-rielaapp-web-server-http-transport.md`

### Summary

Implement an app-local `NWListener` HTTP/1.1 transport, deterministic route adapter, safe static asset server, versioned RielaApp JSON API, app-global web-server settings, and truthful menu lifecycle at `127.0.0.1:19091` by default. Preserve the native UI and the existing `RielaServerConfiguration`/CLI port `8787` semantics.

### Scope

**Included**:

- Generic HTTP transport/parser/byte responses/static resolver in `RielaServer`.
- App router precedence for deterministic routes, `/api/v1`, and SPA assets.
- Real active-profile API reads/mutations for instances, event sources, timeline/logs, workflow sources/settings, note settings, assistant settings, and app web-server settings.
- Revision conflict protection plus Host/Origin/CSRF mutation controls.
- Persistent enable-at-launch/port settings and menu start/stop/open/state integration.
- Asset copying in local app and Cask packaging paths.
- Unit/integration/live verification for lifecycle, persistence, route behavior, bundle assets, and native/CLI regressions.

**Excluded**:

- Frontend component/view implementation under `web/`; it consumes this plan's API and asset-root contract.
- Remote bind, TLS, authentication, WebSockets, chunked bodies, keep-alive, HTTP/2, or arbitrary file editing.
- Removing/redesigning native windows or changing CLI `serve`/GraphQL behavior.
- Instance runtime start/stop API operations; only app-server lifecycle and declared settings mutations are in scope.

## Delivery Order and Dependency Graph

```text
M0 contracts and fixtures
  -> M1 parser/response/static resolver
  -> M2 NWListener lifecycle
  -> M3 app settings/shared settings relocation
  -> M4 application API facade and router
  -> M5 menu/controller composition
  -> M6 build/Cask asset packaging
  -> M7 deterministic and integration gates
  -> M8 live menu/browser/native verification
```

Do not begin menu or packaging integration until the listener, router, and settings tests pass. Do not claim frontend/live acceptance until the separate web frontend produces `web/dist` and all M8 evidence exists.

## Modules

### M0. Lock Contracts and Baseline

**Status**: NOT_STARTED

**Files**:

- `design-docs/specs/design-rielaapp-web-server-http-transport.md` (read-only implementation reference)
- `Tests/RielaServerTests/ServerContractsTests.swift` (existing baseline)
- `Tests/RielaAppSupportTests/DaemonWorkflowSupportTests.swift` (existing persistence baseline)
- `Tests/RielaAppSupportTests/RielaAppBehaviorRegressionTests.swift` (native behavior baseline)
- `tmp/http-transport-api/reference-notes.md` (throwaway evidence only)

**Tasks**:

- [ ] Re-read the accepted design and record implementation deviations before writing code.
- [ ] Capture the relevant `ccusage-gauge` menu, socket lifecycle, asset resolver, and bundle-copy patterns in `tmp/http-transport-api/reference-notes.md`.
- [ ] Run the narrow existing server/app-support tests and record baseline output under `tmp/http-transport-api/baseline/`.
- [ ] Assert in an existing/new test that `RielaServerConfiguration().port == 8787` before introducing app settings.
- [ ] Inventory dirty worktree paths and avoid the unrelated `design-docs/rielaapp-solidjs-web-ui.md` and `impl-plans/rielaapp-solidjs-web-ui.md` artifacts.

**Exit criteria**:

- Existing route/configuration tests pass or pre-existing failures are documented.
- No production file has changed before contracts and baseline are recorded.

### M1. HTTP Contracts, Parser, Response Writer, and Static Resolver

**Status**: NOT_STARTED

**Files**:

- `Sources/RielaServer/HTTPTransportContracts.swift` (new)
- `Sources/RielaServer/HTTPRequestParser.swift` (new)
- `Sources/RielaServer/HTTPResponseWriter.swift` (new)
- `Sources/RielaServer/StaticAssetResolver.swift` (new)
- `Tests/RielaServerTests/HTTPRequestParserTests.swift` (new)
- `Tests/RielaServerTests/HTTPRoutingAndStaticAssetTests.swift` (new)

**Tasks**:

- [ ] Add `RielaHTTPResponse`, `RielaHTTPRouteHandling`, typed public HTTP errors, status reason mapping, security/cache headers, and JSON helpers.
- [ ] Add `DeterministicServerHTTPAdapter` that calls any `ServerRouteHandling`, sorted-key JSON-encodes `ServerResponseDescriptor.body`, preserves status/content type, and does not alter `ServerContracts.swift` semantics.
- [ ] Implement an incremental parser with 32 KiB headers, 1 MiB body, exactly one request, normalized lowercase headers, origin-form targets, `Content-Length`, and typed error responses.
- [ ] Reject conflicting/invalid `Content-Length`, unsupported transfer encoding, NUL/backslash/malformed percent encodings, traversal segments, and oversized input.
- [ ] Separate path and query before creating `ServerRequestEnvelope`; retain raw query data only where an app route explicitly needs it.
- [ ] Implement full-send response writing, `Connection: close`, exact `Content-Length`, HEAD body suppression, and no body/header logging.
- [ ] Implement explicit/bundle/executable asset roots with standardized/resolved containment, symlink-escape rejection, MIME mappings, concrete-file `404`, and extensionless SPA fallback.
- [ ] Keep portable contracts/parser/resolver available across current supported platforms; isolate Network-specific types from this module.

**Tests**:

- [ ] Fragmented header/body parsing and exact body completion.
- [ ] Header/body boundary values plus `431`/`413` overflow.
- [ ] Invalid/conflicting length, chunked/transfer encoding, malformed request line, bad percent encoding, and traversal.
- [ ] Deterministic JSON response encoding/content type/status and no regression of `/healthz`, `/overview`, `/graphql` method behavior.
- [ ] Static MIME types, exact asset, missing hashed asset, root/index, extensionless fallback, API exclusion, encoded traversal, symlink escape, HEAD length, and cache/security headers.

**Exit criteria**:

- Byte/static support requires no change to `ServerResponseDescriptor.body`.
- All parser/resolver tests are deterministic and use only `tmp/` or test temporary directories.

### M2. `NWListener` Server and Awaited Lifecycle

**Status**: NOT_STARTED

**Files**:

- `Sources/RielaServer/LocalHTTPServer.swift` (new, `#if canImport(Network)`)
- `Sources/RielaServer/LocalHTTPConnection.swift` (new, `#if canImport(Network)` if separation is needed to stay below file-size limits)
- `Tests/RielaServerTests/LocalHTTPServerTests.swift` (new, Apple-platform gated)

**Tasks**:

- [ ] Implement actor-isolated Stopped/Starting/Running/Stopping/Failed state with listener generations.
- [ ] Force `NWEndpoint.Host("127.0.0.1")`; production rejects ports outside `1...65535` and never broadens to IPv6/any-interface.
- [ ] Resume start only on `.ready`, propagate `.failed`, capture actual bound port, and make concurrent/repeated start idempotent.
- [ ] Track active connections, apply receive/send timeouts, pass parsed requests to the router, send one response, and close.
- [ ] Await listener cancellation and connection cancellation in `stop()` before publishing Stopped; discard late callbacks from old generations.
- [ ] Provide a bounded state callback/`AsyncStream` suitable for a main-actor controller without retaining it.
- [ ] Add a deliberate ephemeral-port test seam while keeping persisted production validation strict.
- [ ] Map port-in-use and listener failures to stable actionable diagnostics without exposing raw request data.

**Tests**:

- [ ] Ready reports exact loopback address and an actual ephemeral port.
- [ ] Parallel/repeated start produces one listener.
- [ ] A separately occupied port transitions to Failed with a useful diagnostic.
- [ ] Real TCP requests cover fragmented body parsing and deterministic dispatch.
- [ ] Stop cancels idle/partial clients, reaches Stopped, makes curl/connect fail, and allows immediate rebind.
- [ ] Unexpected listener failure cannot report Running/Stopped incorrectly; old-generation callbacks are ignored.

**Exit criteria**:

- Lifecycle tests prove state and socket behavior, not only helper behavior.
- Non-Apple target compilation remains unaffected by Network imports.

### M3. App-Global Web Settings and Shared Note Settings

**Status**: NOT_STARTED

**Files**:

- `Sources/RielaAppSupport/RielaAppWebServerSettings.swift` (new)
- `Sources/RielaAppSupport/RielaAppNoteSettings.swift` (new)
- `Sources/RielaApp/NoteSettingsWindowController.swift` (remove relocated models/store only)
- `Tests/RielaAppSupportTests/RielaAppWebServerSettingsTests.swift` (new)
- `Tests/RielaAppSupportTests/RielaAppNoteSettingsStoreTests.swift` (new or extracted from existing tests)

**Tasks**:

- [ ] Add `RielaAppWebServerSettings(enabledAtLaunch: false, port: 19091)` plus validation, atomic sorted JSON store, load diagnostics, and corrupt-file quarantine.
- [ ] Persist at `<app-root>/web-server.json`, not inside a profile and not inside `RielaServerConfiguration`.
- [ ] Relocate note settings DTOs/store from the AppKit controller into AppSupport with compatible Codable keys/defaults and public/internal access appropriate to existing consumers.
- [ ] Keep note S3 credential *environment names* in settings; never resolve or serialize credential values through the web settings layer.
- [ ] Add fixture round-trip coverage proving old note settings JSON decodes identically after relocation.

**Tests**:

- [ ] App server default is `19091` and server/CLI default remains `8787`.
- [ ] Valid settings round-trip atomically; invalid port is rejected.
- [ ] Corrupt settings are quarantined and produce a diagnostic instead of silent overwrite.
- [ ] Existing note settings fixtures/defaults/S3 profile metadata are unchanged.

**Exit criteria**:

- Native Note Settings compiles and reads the same file after the pure model/store relocation.
- No app-server setting leaks into daemon profile or CLI configuration.

### M4. Main-Actor Application API and App Router

**Status**: NOT_STARTED

**Files**:

- `Sources/RielaApp/RielaAppWebAPIModels.swift` (new)
- `Sources/RielaApp/RielaAppWebAPIService.swift` (new)
- `Sources/RielaApp/RielaAppHTTPRouter.swift` (new)
- `Sources/RielaApp/EntryPoint+WebAPI.swift` (new composition/shared operations)
- `Sources/RielaApp/EntryPoint+DaemonInstances.swift` (extract shared typed mutation operations)
- `Sources/RielaApp/EntryPoint+Environment.swift` (extract shared typed mutation operations where needed)
- `Sources/RielaApp/EntryPoint+EventSources.swift` (extract shared registration operation)
- `Sources/RielaApp/EntryPoint+Assistant.swift` (reuse typed settings save)
- `Sources/RielaApp/EntryPoint+Notes.swift` (reuse moved settings store/service composition)
- `Sources/RielaServer/WorkflowServingController.swift` (only if extracting a reusable deterministic note-route factory is needed)
- `Tests/RielaAppSupportTests/RielaAppWebAPIServiceTests.swift` (new)
- `Tests/RielaAppSupportTests/RielaAppHTTPRouterTests.swift` (new)

**Tasks**:

- [ ] Define versioned DTO/envelope/error contracts matching the accepted design; avoid exposing AppKit types.
- [ ] Implement `@MainActor RielaAppWebAPIService` over injected closures/protocols so tests can use isolated stores/runtime snapshots without launching an app.
- [ ] Project the active profile's instance list/detail plus `daemonRuntime.snapshot(for:)`; include all declared configuration fields and an opaque revision.
- [ ] Extract one typed instance-configuration mutation path used by both native prompts/editors and the API. It must validate, save atomically, refresh caches/windows, increment revision generation, and restart an active instance consistently.
- [ ] Refactor event-source registration into a typed operation shared by native JSON input and API DTO input; retain source/binding/workflow validation, atomic writes, refresh, and restart.
- [ ] Resolve sessions through existing instance/source/session-store logic and return `WorkflowViewerLoader` projections/diagnostics. Add bounded list/payload behavior with explicit truncation metadata.
- [ ] Project workflow sources from current discovery. Map opaque `fileId` values only to prompt/template files already referenced by inspected workflow data; update through `WorkflowViewerLoader.saveTemplateFile` or equivalent contained resolver with revision checks.
- [ ] Read/save moved note settings for the active profile. Validate partial patches and preserve fields not sent.
- [ ] Read/merge assistant assistance/vendor/model settings while excluding and preserving `messages`.
- [ ] Read/save web settings. Return actual and configured ports separately; running port updates return `restartRequired` without self-restart.
- [ ] Generate a random CSRF token per server generation, constant-time validate it, require exact Host, require matching Origin + token for mutations, and emit no CORS allow headers.
- [ ] Implement app route precedence: exact deterministic routes, `/api/v1`, exact assets, extensionless SPA fallback, then `404`. Intercept app `GET /` for SPA while leaving `DeterministicServerRouteHandler` root behavior unchanged.
- [ ] Compose `/graphql` with the existing deterministic handler and real note executor/authenticator when note API is enabled. Extract the existing note-route construction from `WorkflowServingController` rather than duplicating S3/auth rules; workflow-instance operations remain the app JSON API until a real workflow document executor exists.
- [ ] Ensure telemetry logs route class/status/size/duration only, never headers, bodies, CSRF tokens, environment values, or assistant content.

**Tests**:

- [ ] Bootstrap capabilities/token/server/profile state.
- [ ] Host mismatch, DNS-rebinding hostname, missing/mismatched Origin, missing/wrong CSRF, and cross-origin preflight rejection.
- [ ] Active-profile instance list/detail parity with injected native state.
- [ ] Partial mutation for working directory, env file, environment variables, workflow variables, node patches; omitted-field preservation; stale revision `409`; persistence rollback; active restart callback.
- [ ] Event-source valid/invalid registration and restart callback.
- [ ] Session list/detail/timeline/messages/diagnostics and absent session.
- [ ] Workflow list/detail plus referenced-file update; arbitrary path, traversal, symlink, stale revision, and unreferenced file rejection.
- [ ] Note/assistant settings partial merge; no credential values or assistant messages in output; messages preserved after save.
- [ ] Web port update returns configured/actual distinction and `restartRequired`.
- [ ] `/` SPA versus `/overview` JSON precedence; deterministic health/GraphQL/note registration still route correctly.

**Exit criteria**:

- Every shipped browser view has at least one real read and the declared settings surfaces have real safe mutations; no fixture/mock data is compiled into production API paths.
- Native and browser mutations call the same typed operations.
- The HTTP layer performs no direct runtime SQLite access.

### M5. RielaApp Lifecycle and Truthful Status Menu

**Status**: NOT_STARTED

**Files**:

- `Sources/RielaApp/RielaAppWebServerController.swift` (new)
- `Sources/RielaApp/EntryPoint.swift`
- `Sources/RielaApp/EntryPoint+Menu.swift`
- `Sources/RielaApp/EntryPoint+WebServer.swift` (new actions/composition)
- `Tests/RielaAppSupportTests/RielaAppWebServerMenuStateTests.swift` (new or existing menu-layout suite extension)

**Tasks**:

- [ ] Add `@MainActor RielaAppWebServerController` that owns settings, router/server composition, actual lifecycle state, and state-change callback.
- [ ] Resolve explicit dev assets only from the validated existing launch/project root; production uses bundle assets.
- [ ] Construct the controller after app/profile initialization; autostart only when persisted enabled-at-launch is true.
- [ ] Add selectors for start, stop, and open. Open uses the actual Running URL and never implicitly starts.
- [ ] Add menu mapping exactly for Stopped/Starting/Running/Stopping/Failed, including configured-versus-bound pending port and actionable asset/listener errors.
- [ ] Persist enable true only after menu start reaches ready; persist false after successful menu stop. Preserve true on failed autostart.
- [ ] Refresh API/native state on profile switch without rebinding the app-global listener.
- [ ] Await app-server stop during `applicationShouldTerminate` alongside daemon shutdown; avoid double replies and bound total shutdown time.
- [ ] Keep all existing native menu entries/windows and launch-at-login behavior.

**Tests**:

- [ ] Menu titles, state/enabled values, and supplementary text for all five states.
- [ ] Open disabled outside Running and opens exact actual URL while Running.
- [ ] Autostart success/failure preference behavior and missing-asset failure.
- [ ] Configured port differs from bound port after a browser settings update.
- [ ] Profile switch keeps listener but changes API active profile.
- [ ] Termination requests stop and does not claim completion before listener cancellation.

**Exit criteria**:

- Menu state derives only from controller lifecycle, never from the persisted enable flag alone.
- Existing Instances, Notes, Note Settings, Viewer, Launch on Login, About, and Quit items remain present.

### M6. Frontend Asset and App/Cask Packaging

**Status**: NOT_STARTED

**Files**:

- `scripts/build-riela-menu-bar-app.sh`
- `scripts/build-homebrew-cask-release.sh` (or the shared app-bundle helper it uses)
- `Taskfile.yml` (only if task wiring/help must expose the existing build dependency)
- `Tests/RielaAppSupportTests/RielaAppBundleAssetLayoutTests.swift` or an existing packaging smoke test

**Dependency**: the frontend feature must provide `web/package.json`, a lockfile, build scripts, and `web/dist/index.html`.

**Tasks**:

- [ ] Use one reusable build/copy path for local and Cask bundles: require Bun, locked install, frontend build, assert `dist/index.html`, copy `web/dist/.` to `Contents/Resources/Web/`.
- [ ] Keep build output out of tracked source directories and keep all scratch logs under `tmp/http-transport-api/`.
- [ ] Ensure app signing occurs after assets are copied.
- [ ] Verify `task app:build` still delegates to `scripts/build-riela-menu-bar-app.sh`; avoid duplicate Bun invocations in Taskfile.
- [ ] Add a packaging smoke assertion that every asset referenced by built `index.html`/manifest exists in the bundle.
- [ ] Confirm Homebrew Cask build/notarization staging includes identical Web assets and no machine-local paths.

**Exit criteria**:

- Local and Cask app bundles contain the same `Resources/Web` tree.
- Starting a packaged app never depends on repository `web/dist`.

### M7. Code Quality and Deterministic Verification Gates

**Status**: NOT_STARTED

**Tasks**:

- [ ] Run frontend lint/typecheck/build from `web/` after the frontend dependency lands.
- [ ] Run focused RielaServer, RielaAppSupport, menu/layout, note settings, and existing server contract tests.
- [ ] Run `swift build` and `swift build --product RielaApp` using the project Xcode toolchain.
- [ ] Run full `swift test` if focused tests pass and time/environment permit; document any unrelated existing failure.
- [ ] Run SwiftLint with `.swiftlint.yml` using the project Xcode environment.
- [ ] Run `git diff --check`.
- [ ] Check non-generated Swift file sizes; split new/modified files by responsibility before any exceeds 1000 lines.
- [ ] Run a non-Apple compile/CI equivalent if available, or at minimum verify all Network imports are compile-gated.

**Exact commands**:

```bash
cd web && bun install --frozen-lockfile && bun run lint && bun run typecheck && bun run build

/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaServerTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppWebServerSettingsTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppWebAPIServiceTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppWebServerMenuStateTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppNoteSettingsStoreTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
/usr/bin/xcrun swiftlint

CONFIGURATION=debug scripts/build-riela-menu-bar-app.sh
test -f .build/debug/RielaApp.app/Contents/Resources/Web/index.html
git diff --check
rg --files -g '*.swift' | xargs wc -l | sort -nr | head -25
```

**Exit criteria**:

- Every applicable command passes with logs under `tmp/http-transport-api/verification/`, or an environmental/non-feature blocker is explicit and reproducible.
- No narrow test is used to claim the live lifecycle/UI acceptance criteria.

### M8. Live Menu, TCP, Mutation, Browser, and Native Regression Evidence

**Status**: NOT_STARTED

**Evidence root**: `tmp/http-transport-api/live/`

**Tasks**:

- [ ] Launch the debug app with isolated `--app-root`, `--home-root`, `--project-root`, and daemon-autostart control arguments.
- [ ] Use the RielaApp UI verification workflow to click **Start Web Server** and capture Starting/Running menu screenshots.
- [ ] Fetch bootstrap, retain CSRF only in a protected temporary shell variable/file under `tmp/`, and issue real TCP checks.
- [ ] Confirm health, overview, SPA HTML, concrete JS asset, and a supported GraphQL request.
- [ ] Read one real instance; patch a workflow variable with Origin/CSRF/revision; save before/after API payloads with sensitive environment values redacted.
- [ ] Confirm the isolated profile's `daemon-workflows.json` changed atomically, re-read through API, and confirm the native Instances window matches.
- [ ] Read a real session timeline/log and workflow/settings resources.
- [ ] Capture browser screenshots for Instances, timeline/logs, Workflows, and Settings after the frontend feature is available.
- [ ] Open native Instances, Notes, Note Settings, and Viewer windows and capture their continued availability.
- [ ] Click **Stop Web Server** and capture Stopping/Stopped state; prove curl failure, clean `lsof`, and immediate test rebind.
- [ ] Re-run an existing CLI serve/GraphQL regression proving `8787` behavior remains unchanged.

**Representative commands**:

```bash
curl --fail --silent --show-error http://127.0.0.1:19091/healthz
curl --fail --silent --show-error http://127.0.0.1:19091/overview
curl --fail --silent --show-error http://127.0.0.1:19091/
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data '{"query":"query { __typename }"}' \
  http://127.0.0.1:19091/graphql
curl --fail --silent --show-error http://127.0.0.1:19091/api/v1/instances
lsof -nP -iTCP:19091 -sTCP:LISTEN
```

The mutation command must be generated from the actual bootstrap token, exact bound Origin, identity, and revision; do not hard-code or print the token in committed output.

**Exit criteria**:

- Evidence proves menu start -> listener ready -> live reads -> persisted mutation/native parity -> menu stop -> port released.
- Browser screenshots demonstrate usable real-data surfaces; native windows remain available.

## Module Status

| Module | Primary paths | Status | Required evidence |
| --- | --- | --- | --- |
| M0 Contracts/baseline | design + existing tests + `tmp/` | NOT_STARTED | Baseline log/reference notes |
| M1 Parser/static/contracts | `Sources/RielaServer/HTTP*.swift`, `StaticAssetResolver.swift` | NOT_STARTED | Parser/router/asset tests |
| M2 NWListener lifecycle | `Sources/RielaServer/LocalHTTP*.swift` | NOT_STARTED | Live socket lifecycle tests |
| M3 Settings | `Sources/RielaAppSupport/RielaApp*Settings.swift` | NOT_STARTED | Persistence/compatibility tests |
| M4 App API/router | `Sources/RielaApp/RielaAppWebAPI*.swift`, shared EntryPoint operations | NOT_STARTED | API/security/parity tests |
| M5 Menu/controller | `RielaAppWebServerController.swift`, `EntryPoint*.swift` | NOT_STARTED | Menu state/termination tests |
| M6 Packaging | app/Cask build scripts, Taskfile if needed | NOT_STARTED | Bundle asset smoke |
| M7 Deterministic gates | Swift/Bun/lint/build | NOT_STARTED | Verification logs |
| M8 Live evidence | menu/browser/native/TCP | NOT_STARTED | `tmp/http-transport-api/live/` |

## Dependencies

| Dependency | Status | Plan response |
| --- | --- | --- |
| Accepted transport/API design | AVAILABLE | This plan is derived from it. |
| `Network.framework` on macOS 14+ | AVAILABLE | Compile-gate Apple transport; app minimum is macOS 14. |
| Existing deterministic route handler | AVAILABLE | Adapt, do not change root semantics for non-app callers. |
| Existing note GraphQL composition | AVAILABLE but private | Extract reusable route factory instead of duplicating. |
| Workflow-instance GraphQL document executor | NOT_AVAILABLE | Use versioned app JSON API; do not claim GraphQL support. |
| Viewer timeline/message projection | AVAILABLE | Reuse `WorkflowViewerLoader`. |
| SolidJS frontend and `web/dist` | EXTERNAL FEATURE DEPENDENCY | M6/M8 wait for its scripts/build output; transport/API work can proceed. |
| Interactive macOS UI/browser session | ENVIRONMENTAL | Required only for M8 final acceptance. |

## Completion Criteria

- [ ] All design acceptance criteria have mapped implementation evidence.
- [ ] Listener binds only `127.0.0.1`, defaults independently to `19091`, reports truthful state, and releases the socket on awaited stop.
- [ ] `RielaServerConfiguration().port == 8787` and existing CLI behavior remains covered.
- [ ] App `/` serves the SPA while `/overview`, `/healthz`, `/graphql`, and note registration use the deterministic handler adapter.
- [ ] Static byte responses, MIME, containment, missing-asset behavior, and SPA fallback pass adversarial tests.
- [ ] All declared active-profile data surfaces use real app/store/runtime/viewer data.
- [ ] Mutations are Host/Origin/CSRF protected, revision checked, atomically persisted, and native-parity tested.
- [ ] Menu state/actions/autostart/termination match actual listener state.
- [ ] Local and Cask app bundles contain verified `Resources/Web` assets.
- [ ] Bun, Swift build/tests, SwiftLint, diff check, and file-size gates pass.
- [ ] Live evidence proves start/read/mutate/persist/native parity/stop/port release plus browser and native visual checks.
- [ ] No unresolved high or mid design or plan review findings remain.

## Progress Tracking

Update the Module Status table and append a progress entry after each module. Do not mark a module complete from code presence alone; record its test/evidence path.

### Session: 2026-07-17 — feature-local planning

**Tasks Completed**:

- Accepted the design after self and independent review.
- Mapped files, dependencies, test gates, live evidence, and frontend handoff.

**Tasks In Progress**: None; ready for implementation.

**Blockers**:

- The usability skill's project ideal-spec workflow validation stalled without output and was terminated; direct repository/reference review was used.
- M6/M8 require the separate frontend feature to provide a passing `web/dist` build.

**Notes**:

- Implementation has not started.
- All throwaway artifacts must remain under repository-root `tmp/http-transport-api/`.

## Review Record

### Plan self-review

Decision: accepted after corrections.

- Mid, addressed: the first sequencing concept allowed menu work before lifecycle behavior was proven. M5 now depends on M1-M4 exits.
- Mid, addressed: the parent verification listed curl but not protocol/security adversarial cases. M1/M2/M4 add bounded parser, host/origin/CSRF, traversal, and conflict tests.
- Mid, addressed: settings mutation could diverge from native semantics. M4 requires shared typed operations and parity assertions.
- Mid, addressed: app build coverage omitted Cask packaging/signing order. M6 covers local and Cask bundles with assets copied before signing.
- Mid, addressed: browser port mutation could interrupt its response. M4/M5 require configured-versus-actual state and deferred restart.
- Low, addressed: progress tracking had no evidence field. Module status now names required evidence and the progress log must link it.

### Independent plan review

Decision: accepted; no unresolved high or mid findings.

- High, addressed: `/graphql` could have been wired to an empty deterministic handler and still return delegated placeholder JSON. M4 must compose the real existing note executor/authenticator when enabled and test a supported document.
- High, addressed: live mutation evidence could expose environment secrets/CSRF tokens. M8 requires redacted artifacts and forbids hard-coded/printed tokens.
- Mid, addressed: static assets copied only by the local build would fail release Casks. M6 requires one shared copy contract and Cask verification.
- Mid, addressed: API tests alone would not prove native parity. M8 now verifies persisted JSON and the native Instances window after mutation.
- Mid, addressed: timeline APIs could bypass viewer logic or return unbounded payloads. M4 mandates `WorkflowViewerLoader`, explicit bounds, and truncation diagnostics.
- Mid, addressed: conditional `NWListener` compilation lacked a verification gate. M7 explicitly checks Network imports/platform compilation.
- Low, accepted dependency: frontend lint/typecheck/build and screenshots cannot complete until the sibling frontend feature lands; transport/API implementation may proceed independently through M5.

## Addressed Feedback

- Mapped the runtime-supplied logical paths under `docs/design/` and `docs/plans/` to repository-standard `design-docs/specs/` and `impl-plans/active/` as required by the worker contract.
- Converted the parent outline's assumed workflow-instance GraphQL support into an explicit JSON API because no workflow-instance document executor exists.
- Resolved the deterministic root/SPA collision, binary response gap, browser mutation security, stale native/browser writes, app-global port persistence, and port-change lifecycle semantics in the accepted design and this plan.

## Risks and Stop Conditions

- Stop and revise the design if `NWListener` cannot meet awaited port-release behavior without changing the app's supported platform contract.
- Stop before app API implementation if shared typed native mutation extraction would change user-visible native semantics; add characterization tests first.
- Do not weaken Host/Origin/CSRF or revision checks to simplify frontend calls.
- Do not expose raw credential values, assistant messages, request bodies, or CSRF tokens in API projections, logs, or evidence.
- Do not claim acceptance while frontend assets/screenshots or live menu start-stop evidence are absent.
- Keep unrelated dirty/untracked frontend design/plan artifacts untouched.

## Related Plans

- **Frontend dependency**: `impl-plans/rielaapp-solidjs-web-ui.md` (untracked at planning time; owned by another feature path)
- **Design**: `design-docs/specs/design-rielaapp-web-server-http-transport.md`
- **Reference implementation**: `<reference-checkout>/ccusage-gauge` (read-only)
