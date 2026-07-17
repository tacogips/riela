# RielaApp Local Web UI Implementation Plan

Status: accepted, implementation not started

Feature ID: `solidjs-web-ui`

Workflow mode: `issue-resolution`

Issue: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`

Accepted design: `design-docs/rielaapp-solidjs-web-ui.md`

## Delivery contract

Implement the accepted design without removing or redesigning native UI concepts, without changing `RielaServerConfiguration`'s port 8787 default, and without shipping frontend fixtures. The completed slice includes generic HTTP transport, app-owned APIs and lifecycle, persisted settings, real-data SolidJS views, bundle assets, tests, live mutation evidence, browser screenshots, and native/CLI regression evidence.

All temporary logs, responses, screenshots, profiles, and helper data belong under `tmp/solidjs-web-ui/`. Do not put scratch files at repository root or under `scripts/`.

## Progress tracking

Progress states are `not-started`, `in-progress`, `blocked`, or `complete`. A phase becomes complete only when its deliverables and listed gates pass. Update this table during implementation and record command/evidence paths in the phase notes.

| Phase | State | Completion gate |
|---|---|---|
| 0. Contract and baseline | not-started | Baseline commands and reference notes captured under `tmp/solidjs-web-ui/`. |
| 1. Generic transport and static assets | not-started | RielaServer transport/static tests pass, including live bind/stop. |
| 2. Shared settings and app service extraction | not-started | AppSupport persistence and native-regression tests pass. |
| 3. Versioned RielaApp web API | not-started | Required real read/mutation API tests and conflict/security tests pass. |
| 4. Controller and menu integration | not-started | Lifecycle/menu matrix, termination, collision, and port persistence tests pass. |
| 5. Bun/SolidJS frontend | not-started | Lint, typecheck, unit tests, build, and fixture audit pass. |
| 6. App bundle packaging | not-started | Built app contains and serves validated `Resources/Web` assets. |
| 7. Full regression and live/visual verification | not-started | Every acceptance and evidence gate is recorded and passing. |
| 8. Documentation and handoff | not-started | Design/plan status, evidence index, risks, and user-facing docs are current. |

## Dependencies and sequencing

- Phase 1 establishes the transport and response contracts used by all later work.
- Phase 2 extracts shared mutation/persistence seams before the API is added, preventing the browser and native UI from diverging.
- Phase 3 freezes `/api/v1` DTOs before Phase 5 generates frontend TypeScript contracts.
- Phase 4 can begin after the transport's state callbacks and web settings store exist.
- Phase 5 can use test adapters after the Phase 3 contracts freeze, but completion requires the real listener.
- Phase 6 depends on a successful production frontend build.
- Phase 7 starts only after Phases 1–6 pass their narrow gates; narrow tests are not completion evidence.

No new third-party Swift server dependency is planned. Any departure from Network.framework or any API route expansion beyond the accepted design requires a design amendment and re-review before implementation.

## Phase 0 — Contract and baseline

Deliverables:

1. Create `tmp/solidjs-web-ui/` and capture the current git status, relevant baseline test output, port availability, and a concise read-only reference comparison.
2. Confirm Bun, Swift, Xcode SDK, SwiftLint, curl, lsof, and browser-verification prerequisites without writing outside `tmp/`.
3. Record existing native-window smoke behavior and the current CLI/config port 8787 assertion.
4. Translate the accepted API table into initial Swift DTO tests before implementation.

Commands:

```bash
mkdir -p tmp/solidjs-web-ui
git status --short
bun --version
swift --version
swiftlint version
swift test --filter RielaServerTests
swift test --filter RielaAppSupportTests
```

Gate: failures are classified as baseline or feature-caused; do not silently normalize a failing baseline.

## Phase 1 — Generic loopback HTTP transport and static assets

Primary files:

- `Sources/RielaServer/ServerContracts.swift`
- New responsibility-sized files under `Sources/RielaServer/`, expected to include transport, parser/writer, deterministic-handler adapter, and static asset resolver files.
- `Tests/RielaServerTests/` transport/parser/static/security test files.

Tasks:

1. Extend `ServerRequestEnvelope` compatibly with raw target/query metadata needed by `/api/v1` while preserving existing initializers and route tests.
2. Add `HTTPTransportResponse`, request limits, lifecycle state, errors, and the deterministic JSON adapter.
3. Implement `LoopbackHTTPServer` using `NWListener` on `.hostPort(host: .ipv4(.loopback), port:)`; inject listener/connection seams where needed for deterministic state tests.
4. Guard Network.framework implementation with `canImport(Network)` and provide an explicit unsupported-platform implementation so the Swift package still compiles where Network.framework is absent; keep parser/router tests platform-neutral.
5. Implement bounded header/body accumulation, Content-Length enforcement, origin-form parsing, supported-method validation, timeouts, and one-response-per-connection behavior.
6. Implement complete response headers, HEAD semantics, standard status reasons, socket cancellation, readiness reporting, and stop completion.
7. Implement static-root resolution, standardization/root containment, symlink escape protection, MIME types, cache rules, service-prefix exclusions, and extensionless SPA fallback.
8. Add telemetry containing only route template, status, method, latency, and lifecycle transitions.

Tests:

- Split headers and bodies across network frames.
- Empty, malformed, duplicate/conflicting length, chunked, premature EOF, invalid target/header, timeout, and size-limit cases.
- GET/HEAD/POST/method rejection and binary response correctness.
- Existing `/healthz`, `/overview`, `/graphql` behavior through the adapter.
- Static exact asset, MIME, hashed cache, index no-store, missing dotted asset, excluded prefix, traversal, percent-encoded traversal, and symlink escape.
- Start readiness, repeated start, stop while starting/running, repeated stop, port collision, listener failure, and verified rebinding after stop.

Phase gate:

```bash
swift test --filter RielaServerTests
swift build --target RielaServer
```

## Phase 2 — Shared settings and app mutation services

Primary files:

- `Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift`
- `Sources/RielaAppSupport/RielaAppDaemonWorkflowPreference.swift`
- New `Sources/RielaAppSupport/RielaAppWebServerSettings.swift`
- New `Sources/RielaAppSupport/RielaAppNoteSettings.swift`
- `Sources/RielaApp/NoteSettingsWindowController.swift`
- `Sources/RielaApp/EntryPoint+DaemonInstances.swift`
- `Sources/RielaApp/EntryPoint+DaemonNodePatch.swift`
- `Sources/RielaApp/EntryPoint+EventSources.swift`
- `Sources/RielaApp/EntryPoint+Assistant.swift`
- `Sources/RielaApp/EntryPoint+DaemonInstanceResolution.swift`
- Relevant `Tests/RielaAppSupportTests/` files.

Tasks:

1. Add versioned `RielaAppWebServerSettings` and atomic/quarantining store with default disabled/19091 and `1024...65535` validation.
2. Move note settings and its store to AppSupport as public Codable values. Keep only AppKit presentation and registration wiring in the window controller.
3. Extract parsing, validation, persistence, refresh, and active-instance restart logic from UI-prompt methods into shared `@MainActor` application services callable by native closures and web API methods.
4. Extract safe event-source registration/removal; validate IDs and ensure resolved source/binding files remain below the instance event root. Pair writes/removals so failures do not leave half-applied state.
5. Extract directory/repository registration/removal services; removal never deletes source content from disk.
6. Add stable revision generation for profile daemon state, note settings, and web settings. Preserve native mutations and have them advance the same observable model.
7. Preserve assistant messages when settings fields change and validate vendor/model through `RielaAppAssistantModelCatalog`.

Tests:

- Defaults, round-trip, atomic replacement, invalid port, corrupt quarantine, and independence from `RielaServerConfiguration()`.
- Native environment/workflow-variable parsing, working directory, node patch, source, event-source, note, and assistant behavior before/after extraction.
- Event-source traversal and paired-write rollback.
- Revision changes and stale-revision detection.
- Assistant message preservation and note credential-env-name behavior.

Phase gate:

```bash
swift test --filter RielaAppSupportTests
swift test --filter RielaAppBehaviorRegressionTests
```

## Phase 3 — RielaApp API facade and router

Primary files:

- New `Sources/RielaApp/RielaAppWebAPIModels.swift`
- New `Sources/RielaApp/RielaAppWebAPIService.swift`
- New `Sources/RielaApp/RielaAppWebRouter.swift`
- `Sources/RielaApp/EntryPoint.swift`
- `Package.swift` only if the AppSupport-to-Viewer test dependency or target dependency must be declared.
- New API tests under `Tests/RielaAppSupportTests/` or a responsibility-specific RielaApp-importing test file.

Tasks:

1. Define explicit Codable request/response DTOs and error envelopes for every route in the accepted design; do not encode internal models directly.
2. Implement path-segment decoding and safe ID validation. Route only `/api/v1`, deterministic service paths, and static UI paths; unknown `/api` routes return JSON 404 without SPA fallback.
3. Implement exact Host validation using the actual bound port; reject cross-site fetch metadata and mismatched Origin. Require JSON content type for GraphQL and every mutation; emit no CORS headers.
4. Provide real bootstrap, instance list/detail, execution list/detail, workflow-source, and settings reads. Resolve sessions through `WorkflowViewerLoader`; do not reconstruct timelines from UI controls.
5. Implement structured instance-configuration, node-patch, event-source, workflow-source, note, assistant, and web-port mutations through Phase 2 services.
6. Require relevant revisions on overwrite mutations, return 409 with fresh revision on conflict, and return field-level 422 errors without persistence.
7. Refresh native caches/windows after successful mutations and restart active instances only for configuration changes that currently require restart.
8. Pass `/healthz`, `/overview`, and `/graphql` to `DeterministicServerRouteHandler`; reserve `/` for static `index.html`.
9. Add route-template telemetry without identifiers, paths, bodies, GraphQL text, or settings values.

Required `/api/v1` implementation inventory:

- Bootstrap and instances: `GET /api/v1/bootstrap`, `GET /api/v1/instances`, `GET /api/v1/instances/{id}`, and `PATCH /api/v1/instances/{id}/configuration`.
- Per-instance patches/events: `PUT|DELETE /api/v1/instances/{id}/node-patches/{nodeId}` and `POST /api/v1/instances/{id}/event-sources` plus `DELETE /api/v1/instances/{id}/event-sources/{sourceId}`.
- Executions: `GET /api/v1/instances/{id}/executions` and `GET /api/v1/instances/{id}/executions/{sessionId}`.
- Workflow sources: `GET /api/v1/workflows/sources`, `POST|DELETE /api/v1/workflows/sources/directories`, and `POST /api/v1/workflows/sources/repositories` plus `DELETE /api/v1/workflows/sources/repositories/{id}`.
- Settings: `GET|PUT /api/v1/settings/notes`, `GET|PUT /api/v1/settings/assistant`, and `GET|PUT /api/v1/settings/web-server`.

Route coverage gate: write a table-driven test containing every method/path row from the accepted design. Each required mutation must assert both persisted state and re-read response.

Phase gate:

```bash
swift test --filter RielaAppWebAPI
swift test --filter RielaServerTests
swift test --filter RielaViewerTests
```

## Phase 4 — Web-server controller, menu, and termination

Primary files:

- New `Sources/RielaApp/RielaAppWebServerController.swift`
- `Sources/RielaApp/EntryPoint.swift`
- `Sources/RielaApp/EntryPoint+Menu.swift`
- New lifecycle/menu tests under `Tests/RielaAppSupportTests/` importing `RielaApp`.

Tasks:

1. Add the `@MainActor` controller with injected settings store, server factory, router factory, browser opener, and state callback for deterministic tests.
2. Load desired enabled state/port during app bootstrap; autostart only when enabled. Do not overload `RielaServerConfiguration`.
3. Implement start, user stop, failure, port-change, and bounded termination behavior exactly as the accepted state machine specifies. `shutdownForTermination()` closes the listener without clearing persisted `isEnabled`; only explicit user Stop clears it.
4. Store the controller on `RielaApp`; initialize it only after profile, daemon store, viewer roots, and note roots are available.
5. Add Start Web Server, Stop Web Server, Open in Browser, and supplementary actual/configured status in `rebuildMenu()`.
6. Make menu enabled states derive from controller state. Use actual bound port for `NSWorkspace.open`; never open on start failure.
7. Fold controller shutdown into the existing asynchronous application termination sequence without regressing daemon/telemetry shutdown.

Tests:

- Full menu matrix for stopped, starting, running, stopping, and failed.
- Persist enabled only after ready; clear on explicit stop/failure; preserve enabled through termination and assert autostart on the next launch.
- Port collision and recovery, configured-versus-bound port, open URL, repeated actions, failure status sanitization, and termination release.
- Existing menu items and native window actions remain present.

Phase gate:

```bash
swift test --filter RielaAppWebServerController
swift test --filter RielaAppBehaviorRegressionTests
swift build --product RielaApp
```

## Phase 5 — Bun, SolidJS, and Tailwind application

Primary files:

- New `web/package.json`, `web/bun.lock`, TypeScript/Vite/Tailwind/ESLint configuration.
- New files under `web/src/` split into API contracts/client, app shell, route views, feature components, and styles.
- Frontend tests under `web/src/**/__tests__/` or `web/tests/` only.

Tasks:

1. Scaffold Bun + SolidJS + Vite + strict TypeScript + ESLint + Tailwind with scripts `lint`, `typecheck`, `test`, and `build`.
2. Implement one typed same-origin API client with JSON headers, abort support, revision retention, stale-conflict errors, and no fallback data.
3. Implement accessible application shell/navigation and route selection for Instances, Logs, Workflows, and Settings.
4. Implement real Instances list/status polling and instance configuration editors for stored environment variables, workflow variables, working directory/environment file, event sources, and node patches.
5. Implement real execution/session selection, timeline, run log/messages, diagnostics, active-only polling, and transient-error retention.
6. Implement real workflow directory/repository lists and add/remove controls; show discovered sources and node-patch visibility.
7. Implement note, assistant, and web-server settings, including credential environment-variable names, model validation choices, configured/bound port distinction, and restart-required messaging.
8. Cover loading, empty, error, conflict, saving, saved, destructive confirmation, and narrow layout states.
9. Add a source audit test/script that fails if shipped source imports test fixtures, contains sample response objects, or intercepts fetch outside tests.

Phase gate:

```bash
cd web
bun install --frozen-lockfile
bun run lint
bun run typecheck
bun run test
bun run build
```

The build gate additionally verifies `web/dist/index.html` and at least one content-hashed JavaScript asset.

## Phase 6 — App bundle packaging

Primary files:

- `scripts/build-riela-menu-bar-app.sh`
- `Taskfile.yml` only when an explicit frontend subtask materially improves the existing `app:build` contract.
- Homebrew Cask build/smoke scripts only where resource validation is otherwise skipped.

Tasks:

1. Require Bun and perform frozen install, lint, typecheck, and build before the Swift product build.
2. Copy `web/dist/.` into `RielaApp.app/Contents/Resources/Web/` and fail on absent index/JS assets.
3. Preserve icon, plist, signing, notarization, version, and existing output-path behavior.
4. Ensure packaged runtime resolves only bundle resources; explicit project-root development mode may resolve `web/dist`.
5. Add/extend a reusable packaged-assets smoke check; no temporary wrapper goes under `scripts/`.

Phase gate:

```bash
CONFIGURATION=debug scripts/build-riela-menu-bar-app.sh
test -f .build/debug/RielaApp.app/Contents/Resources/Web/index.html
find .build/debug/RielaApp.app/Contents/Resources/Web -type f -name '*.js' -print -quit | grep .
task app:build
```

## Phase 7 — Full regression, live mutation, and visual verification

Run from a clean feature test profile so user data is never modified. Capture all command output and screenshots under `tmp/solidjs-web-ui/`.

Automated gates:

```bash
swift build
swift test --filter RielaServerTests
swift test --filter RielaAppSupportTests
swift test --filter RielaViewerTests
swift test --filter RielaCLITests
swift test
swiftlint --config .swiftlint.yml
cd web && bun run lint && bun run typecheck && bun run test && bun run build
```

Live HTTP gates after starting from the menu on the default port:

```bash
curl --fail --silent --show-error http://127.0.0.1:19091/healthz
curl --fail --silent --show-error http://127.0.0.1:19091/overview
curl --fail --silent --show-error http://127.0.0.1:19091/
curl --fail --silent --show-error http://127.0.0.1:19091/api/v1/instances
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data '{"query":"query { __typename }"}' \
  http://127.0.0.1:19091/graphql
lsof -nP -iTCP:19091 -sTCP:LISTEN
```

Mutation round-trip:

1. GET an existing test instance and retain its revision and original workflow variables.
2. PATCH one unique workflow variable with the revision.
3. Assert the response, `daemon-workflows.json`, and a new GET contain the exact value.
4. Submit the old revision and assert 409 without a second change.
5. Restore the original configuration through the API and verify the restoration.

Stop/release gate:

```bash
! curl --max-time 2 --fail http://127.0.0.1:19091/healthz
! lsof -nP -iTCP:19091 -sTCP:LISTEN | grep LISTEN
```

Visual/native gates:

- Capture browser screenshots for instances/detail, logs/timeline, workflows/sources, and all settings sections at desktop and narrow widths.
- Verify real empty/error/loading states where the clean profile lacks data; do not seed shipped fixtures.
- Verify keyboard navigation, visible focus, labels, contrast, overflow, destructive confirmations, save/conflict feedback, and configured-versus-bound port copy.
- Open native Instances, Notes, Note Settings, and Viewer windows and capture a smoke record showing they remain usable.
- Confirm menu text/enabled state at start, ready, port-change/restart-required, stop, and failure.
- Confirm CLI `serve`/GraphQL tests and a direct `RielaServerConfiguration().port == 8787` assertion.

Phase gate: create `tmp/solidjs-web-ui/evidence-index.json` mapping every acceptance criterion to commands, outputs, screenshots, and pass/fail status. A missing mapping blocks completion.

## Phase 8 — Documentation and handoff

Tasks:

1. Update this plan's progress table and phase notes with actual file paths, deviations, and evidence.
2. Update the accepted design only for material implementation decisions; record and re-review any changed contract.
3. Update user-facing build/run documentation with Bun prerequisite, menu lifecycle, default port, configured-versus-bound behavior, development assets, and loopback security limits.
4. Review git diff for unrelated changes and scratch artifacts. Keep `tmp/` untracked/ignored.
5. Refresh package/release metadata only if files covered by a package digest were changed.

Final completion requires all phases complete, no open high/mid review finding, no shipped fixture, no untracked scratch file outside `tmp/`, and no unsupported completion claim based only on narrow tests.

## Completion criteria traceability

| Acceptance requirement | Deliverables | Verification |
|---|---|---|
| Truthful Start/Stop/Open menu | Controller state machine and menu integration | Menu matrix tests plus live start/ready/stop/failure record. |
| Loopback default 19091 | Separate AppSupport settings and loopback listener | Defaults tests, lsof evidence, hostile Host rejection. |
| Preserve CLI 8787 | No mutation of `RielaServerConfiguration` | Direct assertion and RielaCLI regression suite. |
| Health/UI/API/GraphQL served | Transport, adapter, static resolver, app router | RielaServer tests and live curl set. |
| Real instance/config mutation | Shared app services and versioned API | API table tests plus persisted mutation round-trip. |
| Real logs/timeline | Viewer-backed execution endpoints and frontend | Viewer/API tests and browser screenshot. |
| Real workflows/settings mutations | Source/note/assistant/web settings services and views | Persistence/re-read tests and screenshots. |
| No shipped fixtures | Typed fetch layer and real endpoint views | Source audit, build, and clean-profile browser run. |
| App assets packaged | Build script resource copy and runtime resolver | Bundle checks and packaged live GET `/`. |
| Preserve native UI | Shared service extraction without removal | Native controller tests and live window smoke. |
| Build/lint/test quality | Swift/Bun test gates and SwiftLint | Phase 7 full command evidence. |

## Implementation review record

### Self-review

Decision: accepted after corrections.

- Mid plan-only defect, corrected: the first sequence started frontend work before DTO and revision contracts were frozen. Phase 5 now depends on Phase 3 route-contract completion.
- Mid plan-only defect, corrected: narrow Swift tests were listed as the final gate. Phase 7 now requires the full Swift suite, SwiftLint, frontend gates, live listener/mutation evidence, visual checks, and native regression checks.
- Mid plan-only defect, corrected: the plan did not require restoration of mutated test data. The live round-trip now uses an isolated profile and restores the original configuration.
- Low plan-only observation, corrected: packaging checked only `index.html`; it now requires a built JavaScript asset and packaged live serving.

### Independent implementation-plan review

Review lens: design-plan consistency, deliverable coverage, dependency order, completion criteria, progress mechanics, safety, and executable verification. No delegated Codex agent was used.

Decision: accepted after corrections; no open high or mid findings.

- High plan-only defect, corrected: event-source deletion and overwrite conflicts were in the design but absent from implementation tests. Phase 2/3 now require safe deletion, revisions, 409 behavior, persistence, and re-read assertions.
- High design/plan defect, corrected: termination originally reused user Stop and would erase persisted autostart intent. Phase 4 now separates preference-preserving termination shutdown from explicit Stop and tests clean-quit relaunch.
- Mid plan-only defect, corrected: controller termination was planned separately from the app's existing asynchronous daemon/telemetry shutdown and could regress termination. Phase 4 now explicitly composes bounded listener shutdown into the existing termination reply.
- Mid plan-only defect, corrected: security requirements lacked an implementation gate. Phase 1/3 now require Host, Origin, Sec-Fetch-Site, content-type, traversal, symlink, body-limit, and no-CORS tests.
- Mid plan-only defect, corrected: completion did not trace every acceptance requirement to evidence. Phase 7 now requires a machine-readable evidence index and the plan includes a traceability table.
- Low residual risk: live AppKit menu and browser verification depend on a macOS graphical session; automated lifecycle and route tests remain mandatory even when visual tooling is temporarily unavailable.
- Low residual risk: Network.framework is macOS-specific. Conditional compilation must keep non-macOS package builds available, while live bind/state tests run on macOS.

## Risks

- Network.framework callbacks and MainActor application state can race during rapid menu actions. Mitigation: generation-token/idempotency tests and explicit stopping/ready transitions.
- App-owned native mutation methods are currently distributed across EntryPoint extensions. Mitigation: extract narrow shared services incrementally and keep regression tests around native callbacks.
- Timeline/session roots may vary by instance/profile. Mitigation: use the exact native Viewer resolution inputs and expose diagnostics rather than guessing paths.
- Stored environment variables may contain sensitive values. Mitigation: bind loopback, enforce same-origin protections, never expose inherited/resolved secrets, avoid telemetry/body logging, and document that the local browser editor shows stored values.
- Frontend packaging can become stale. Mitigation: build before every app bundle, wipe destination, verify index and hashed JS, and smoke the packaged app.
- A port setting changed while running differs from the current listener. Mitigation: expose configured and bound values separately and require menu restart rather than silently rebinding.
