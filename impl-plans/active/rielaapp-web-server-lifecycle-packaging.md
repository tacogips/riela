# RielaApp Web Server Lifecycle and Asset Packaging — Implementation Plan

**Status**: Ready
**Feature ID**: `app-lifecycle-packaging`
**Workflow mode**: `issue-resolution`
**Issue**: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`
**Design reference**: `design-docs/specs/design-rielaapp-web-server-lifecycle-packaging.md`
**Created**: 2026-07-17
**Last updated**: 2026-07-17

## 1. Objective and Boundaries

Implement a menu-controlled, persisted, localhost-only RielaApp web server that defaults to port `19091`, serves a real SolidJS UI and existing deterministic/GraphQL routes, exposes app-backed read and mutation APIs, and ships its assets in local and Homebrew Cask app bundles.

### Included

- Real HTTP listener and static asset routing in `RielaServer`.
- App-global server settings and corruption-safe persistence.
- Main-actor RielaApp lifecycle controller and truthful menu presentation.
- Active-profile API facade, app GraphQL executor, revision/CSRF protections, and native refresh/restart coordination.
- Net-new `web/` Bun + SolidJS + Tailwind application for instances, logs/timeline, workflows, and settings.
- Local app and Cask asset build/copy/verification.
- Unit, integration, live HTTP, menu, native-window, browser, and packaging evidence under `tmp/app-lifecycle-packaging/`.

### Excluded

- Non-loopback binding, TLS, remote access, multi-user authentication, HTTP/2, WebSockets, or uploads.
- Removing or redesigning native windows or changing CLI `serve`/GraphQL semantics.
- Changing `RielaServerConfiguration.host`/`.port` defaults (`127.0.0.1:8787`).
- Shipping fixtures/mock data in production frontend bundles.

## 2. Delivery Order

The modules are deliberately ordered so the frontend builds against an accepted API contract and packaging cannot be declared complete from a source-tree-only build.

| Module | Deliverable | Depends on | Initial status |
| --- | --- | --- | --- |
| 1 | settings, DTOs, API/version contract | accepted design | NOT_STARTED |
| 2 | HTTP transport and static asset resolver | module 1 contracts | NOT_STARTED |
| 3 | RielaApp API/GraphQL facade and security guards | modules 1–2 | NOT_STARTED |
| 4 | lifecycle controller, menu, launch/termination | modules 1–3 | NOT_STARTED |
| 5 | SolidJS/Tailwind frontend | frozen module 1/3 contract | NOT_STARTED |
| 6 | local/Cask packaging integration | module 5 build | NOT_STARTED |
| 7 | layered and live verification | modules 1–6 | NOT_STARTED |
| 8 | user/release documentation and progress closure | verified modules 1–7 | NOT_STARTED |

## 3. Module 1 — Settings and Stable Contracts

**Status**: NOT_STARTED

### Write scope

- New `Sources/RielaAppSupport/RielaAppWebServerSettings.swift`
- New `Sources/RielaAppSupport/RielaAppWebAPIContracts.swift`
- New `Tests/RielaAppSupportTests/RielaAppWebServerSettingsTests.swift`
- New `Tests/RielaAppSupportTests/RielaAppWebAPIContractsTests.swift`

### Deliverables

- Define `RielaAppWebServerSettings(version:isEnabled:port:)`, defaulting to disabled/`19091`; host is not a stored field.
- Define `RielaAppWebServerSettingsStore` at `<app-root>/web-server.json`, with atomic sorted JSON writes, default-on-missing, corrupt-file quarantine, and injectable URL/file manager for tests.
- Validate port `1...65535`; keep a failed candidate out of persisted state.
- Define Codable API version/envelope/error/revision DTOs and all browser-facing projections without environment values or credential fields.
- Define route request DTOs separately from app-internal mutable models. Mutations carry an expected revision.
- Add fixture JSON snapshots for API v1 so Swift and TypeScript tests use the same field names and enum values.

### Completion checks

- [ ] Settings default, round-trip, legacy/missing-key decode, invalid port, atomic save, and corrupt quarantine tests pass.
- [ ] Contract encoding snapshots contain no environment values, secret values, raw request body, or absolute machine-local paths.
- [ ] A test constructs `RielaServerConfiguration()` and still asserts port `8787`.

### Verification

```bash
swift test --filter RielaAppWebServerSettingsTests
swift test --filter RielaAppWebAPIContractsTests
swift test --filter ServerContractsTests/testServerConfigurationDefaults
```

## 4. Module 2 — Real HTTP Transport and Static Assets

**Status**: NOT_STARTED

### Write scope

- `Package.swift` (conditional macOS Network framework linkage if required)
- New `Sources/RielaServer/RielaHTTPContracts.swift`
- New `Sources/RielaServer/RielaHTTPRequestParser.swift`
- New `Sources/RielaServer/RielaNetworkHTTPListener.swift`
- New `Sources/RielaServer/RielaHTTPRouteAdapter.swift`
- New `Sources/RielaServer/RielaStaticAssetResolver.swift`
- New `Tests/RielaServerTests/RielaHTTPRequestParserTests.swift`
- New `Tests/RielaServerTests/RielaNetworkHTTPListenerTests.swift`
- New `Tests/RielaServerTests/RielaStaticAssetResolverTests.swift`
- New `Tests/RielaServerTests/RielaHTTPRouteAdapterTests.swift`

### Deliverables

- Add byte-oriented `RielaHTTPRequest`/`RielaHTTPResponse` and async handler/listener protocols without changing `ServerResponseDescriptor`.
- Implement pure request parsing and response serialization with the design limits: 32 KiB headers, 2 MiB body, `Content-Length` only, bounded concurrency, connection close, and explicit status mapping.
- Implement `RielaNetworkHTTPListener` under `#if canImport(Network)` with `NWParameters.requiredLocalEndpoint`/equivalent loopback-only binding, ready/failed/cancelled continuations, and shutdown that awaits cancellation.
- Allow port `0` only through an internal/test initializer and expose the actual bound endpoint.
- Adapt `/healthz`, `/overview`, `/graphql`, and note registration requests to `DeterministicServerRouteHandler` and JSON-encode its existing response.
- Resolve packaged/development roots explicitly; reject traversal, escaped symlinks, malformed percent encoding, directories, and missing concrete assets; permit index fallback only for extensionless non-API navigation routes.
- Apply MIME, cache, CSP, nosniff, frame, and referrer headers in one response-policy helper.

### Completion checks

- [ ] No CLI factory/default is changed to the real app listener in this module.
- [ ] A live ephemeral-port test proves health routing and shutdown/rebind.
- [ ] A collision test returns a stable `address_in_use` diagnostic.
- [ ] Missing `assets/app.js` returns `404` rather than `index.html`.
- [ ] Static traversal/symlink tests cannot read outside the fixture root.
- [ ] Linux/non-Network compilation remains guarded; macOS RielaApp links Network successfully.

### Verification

```bash
swift test --filter RielaHTTPRequestParserTests
swift test --filter RielaStaticAssetResolverTests
swift test --filter RielaHTTPRouteAdapterTests
swift test --filter RielaNetworkHTTPListenerTests
swift test --filter RielaServerTests
```

## 5. Module 3 — RielaApp API, GraphQL, and Security

**Status**: NOT_STARTED

### Write scope

- New `Sources/RielaApp/RielaAppWebAPIFacade.swift`
- New responsibility-split extensions such as:
  - `Sources/RielaApp/RielaAppWebAPIFacade+Instances.swift`
  - `Sources/RielaApp/RielaAppWebAPIFacade+Sessions.swift`
  - `Sources/RielaApp/RielaAppWebAPIFacade+Workflows.swift`
  - `Sources/RielaApp/RielaAppWebAPIFacade+Settings.swift`
- New `Sources/RielaApp/RielaAppWebRouter.swift`
- New `Sources/RielaApp/RielaAppGraphQLDocumentExecutor.swift`
- New `Sources/RielaApp/RielaAppWebRequestSecurity.swift`
- Minimal visibility/refactoring changes in existing `Sources/RielaApp/EntryPoint+*.swift` helpers; do not duplicate mutation logic
- App-profile workflow-instance adapter in `Sources/RielaAppSupport/` if required by `GraphQLWorkflowInstanceService`
- New focused tests under `Tests/RielaAppSupportTests/` and, if the executable target is importable, `Tests/RielaAppTests/`

### Deliverables

- Freeze `/api/v1` route inventory and return the Module 1 envelopes.
- Implement `GET /api/v1/bootstrap` with `apiVersion`, active profile, current endpoint/settings, capability flags, revision, and per-launch CSRF token.
- Project active-profile instances from the daemon cache/store and runtime status from `RielaAppDaemonWorkflowRuntime.snapshot(for:)`.
- Route configuration mutations through existing main-actor helpers so validation, atomic save, native refresh, and active-instance restart semantics remain identical.
- Route session/log/timeline reads through `WorkflowViewerLoader`/RielaViewer models; bound large payloads and report truncation.
- Route workflow discovery, source/repository/catalog reads, add/refresh/install operations, and node-patch edits through existing RielaApp actions.
- Route note settings through `RielaAppNoteSettingsStore`; return configured/missing metadata only for credential-backed fields.
- Route assistant settings/messages through the existing daemon-state and assistant submission helpers; bound/redact stored messages.
- Implement an app GraphQL document executor that composes note operations with workflow-instance and runtime/session services. Do not introduce a second schema vocabulary.
- Add active-profile revision generation and reject stale mutations with `409`.
- Enforce exact Host/Origin, JSON mutation content type, per-launch `X-Riela-CSRF`, no CORS, and response security headers before dispatch.
- Telemetry records method, normalized route name, status, duration, and active profile only; never bodies, env values, tokens, or assistant credentials.

### Completion checks

- [ ] Every shipped frontend read and mutation has an explicit live backing seam.
- [ ] API mutation tests assert the existing app helper was invoked and native refresh/restart callback fired.
- [ ] A stale native/web edit returns `409` and does not write the store.
- [ ] Profile switch invalidates the prior revision.
- [ ] Host spoof, hostile Origin, absent/wrong CSRF, form POST, and unsupported GraphQL mutation tests fail closed.
- [ ] GraphQL workflow-instance read matches REST/native projection for the same isolated profile.
- [ ] Redaction tests search serialized responses and telemetry for seeded secret values and find none.

### Verification

```bash
swift test --filter RielaAppWebAPI
swift test --filter RielaAppGraphQL
swift test --filter RielaAppWebRequestSecurity
swift test --filter DaemonWorkflowNodePatchTests
swift test --filter RielaViewerTests
```

## 6. Module 4 — Lifecycle, Menu, Launch, and Termination

**Status**: NOT_STARTED

### Write scope

- New `Sources/RielaApp/RielaAppWebServerController.swift`
- New `Sources/RielaApp/EntryPoint+WebServer.swift`
- `Sources/RielaApp/EntryPoint.swift`
- `Sources/RielaApp/EntryPoint+Menu.swift`
- Existing menu presentation helpers or new `Sources/RielaAppSupport/RielaAppWebServerMenuPresentation.swift` for pure tests
- Targeted lifecycle/menu tests

### Deliverables

- Implement `stopped`, `starting`, `running`, `stopping`, and `failed` state with generation protection and dependency-injected factories.
- Implement Start persistence/autostart, Stop persistence/awaited cancellation, unexpected-failure handling, and transactional running-port replacement.
- Store one controller on `RielaApp`; build its API facade only after app/profile stores initialize.
- Add Start/Stop/Open/Copy URL/Port menu items and a disabled detail row. Derive titles, enabled state, and endpoint exclusively from controller state.
- Use `NSWorkspace.shared.open` only for a running endpoint and `NSPasteboard` for Copy URL.
- Rebuild the menu on every state transition on the main actor; prevent stale listener callbacks from changing it.
- Start persisted-enabled server after initial profile/cache setup, not before.
- Await web shutdown alongside daemon shutdown in `applicationShouldTerminate`, with the existing bounded termination behavior.

### Completion checks

- [ ] State-transition matrix includes double Start, double Stop, Stop-during-Start, failed bind, late ready, unexpected failure, replacement success/failure, and termination.
- [ ] `Open in Browser` is disabled for stopped/starting/stopping/failed.
- [ ] Running is never shown before listener ready; Stopped is never shown before cancellation.
- [ ] Failed autostart retains `isEnabled: true` and offers Start/Port recovery.
- [ ] Changing the port in a healthy running server does not drop the old listener when replacement bind fails.

### Verification

```bash
swift test --filter RielaAppWebServerController
swift test --filter RielaAppWebServerMenuPresentation
swift build --product RielaApp
```

## 7. Module 5 — Bun/SolidJS/Tailwind Frontend

**Status**: NOT_STARTED

### Write scope

- New `web/package.json`, `web/bun.lock`, `web/tsconfig*.json`, `web/vite.config.ts`, `web/eslint.config.js`
- New `web/src/` application, routes, components, API client, contracts, styles, and tests
- New `web/index.html`
- Generated `web/dist/` remains a build artifact unless repository policy explicitly requires a synchronized copy

### Deliverables

- Scaffold SolidJS + TypeScript + Vite + Tailwind with `lint`, `typecheck`, `test`, and `build` scripts.
- Generate or hand-maintain TypeScript contracts from the frozen API fixture; add a test that decodes Swift fixture JSON.
- Implement a typed fetch client that loads bootstrap, retains CSRF only in memory, sends revision/If-Match on mutation, handles `409`, and never enables CORS workarounds.
- Implement application shell, responsive navigation, error boundary, reconnect/stale banner, loading/empty/error states, and accessible focus management.
- Instances: list/status/readiness, create/remove/relink, start/stop/restart, env/workflow variable editor, working directory, event sources, node patches.
- Logs: sessions, timeline/list detail, backend events, inbox/outbox messages, polling for a running session, bounded rendering.
- Workflows: sources, repositories/catalog state, validation, add/refresh/install, node patch visibility/edit entry points.
- Settings: note settings, assistant vendor/model/assistance/messages, and web-server port with transactional restart feedback.
- Ensure production entry points import no fixtures, mock service worker, or hard-coded instance/workflow/log/settings data.

### Completion checks

- [ ] All four primary routes render live API data and have meaningful empty/error states.
- [ ] At least one real mutation is available from Instances, Workflows, and Settings; logs remain intentionally read-only.
- [ ] Secret fields display configured/missing metadata only.
- [ ] Keyboard navigation, labels, visible focus, non-color status, and narrow-width layout are covered by component tests and visual evidence.
- [ ] Vite outputs hashed assets referenced by `dist/index.html`.

### Verification

```bash
cd web
bun install --frozen-lockfile
bun run lint
bun run typecheck
bun run test
bun run build
```

## 8. Module 6 — Build and Release Packaging

**Status**: NOT_STARTED

### Write scope

- New reusable `scripts/build-rielaapp-web-assets.sh`
- New reusable `scripts/verify-rielaapp-web-assets.sh`
- New `scripts/smoke-rielaapp-web-assets.sh`
- `scripts/build-riela-menu-bar-app.sh`
- `scripts/build-homebrew-cask-release.sh`
- `Taskfile.yml` only if an explicit standalone frontend task improves reuse; `app:build` must still be the complete path
- `Tests/RielaCoreTests/SwiftPackagingReadinessTests.swift`

### Deliverables

- Centralize frozen install, lint/typecheck policy as appropriate for build vs CI, Vite build, index/reference validation, and safe copy to a supplied `Resources/Web` destination.
- Make local app build fail before publishing a bundle when Bun or assets are missing; allow an explicit prebuilt-assets mode only after verification.
- Copy assets into `.build/<configuration>/RielaApp.app/Contents/Resources/Web`.
- Update the Cask builder's independent `write_riela_app_bundle` path to copy verified assets before codesign.
- Add structural tests proving both builders call the shared asset helper and package `Web/index.html`.
- Add unsigned/local packaged smoke coverage for healthy assets and missing-assets failure. Preserve all signing/notarization behavior.
- Confirm no repository-root or `scripts/` scratch artifacts are introduced; all evidence goes under `tmp/app-lifecycle-packaging/`.

### Completion checks

- [ ] `task app:build` produces a bundle containing index plus every referenced hashed asset.
- [ ] Cask dry-run remains side-effect free and reports the same app/binary/signing plan.
- [ ] Cask staging calls asset copy before signing.
- [ ] Missing or incomplete assets fail with an actionable diagnostic.
- [ ] Existing icon, Info.plist, signing, notarization, and Homebrew tests remain green.

### Verification

```bash
task app:build
scripts/verify-rielaapp-web-assets.sh .build/release/RielaApp.app/Contents/Resources/Web
scripts/smoke-rielaapp-web-assets.sh
scripts/build-homebrew-cask-release.sh --dry-run darwin-arm64
swift test --filter SwiftPackagingReadinessTests
```

When Apple credentials are available, the release owner also runs the existing signed/notarized Cask build. Absence of credentials does not permit a notarization-success claim; it does not block local bundle/asset correctness evidence.

## 9. Module 7 — Integrated Verification and Evidence

**Status**: NOT_STARTED

### Preparation

Use the `rielaapp-ui-verification` skill for native menu/window checks and a browser-computer-use skill for the SolidJS UI. Create only isolated evidence/state roots:

```bash
mkdir -p tmp/app-lifecycle-packaging/{evidence,app-root,home-root,project-root}
```

Seed deterministic workflow/package/session fixtures under the project/home roots. Do not read or mutate the user's normal `~/.riela` state.

### Automated gate

```bash
cd web && bun install --frozen-lockfile && bun run lint && bun run typecheck && bun run test && bun run build
cd ..
swift build
swift build --product RielaApp
swift test --filter RielaServerTests
swift test --filter RielaAppSupportTests
swift test --filter RielaViewerTests
swift test --filter SwiftPackagingReadinessTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
/usr/bin/xcrun swiftlint
git diff --check
rg --files -g '*.swift' | xargs wc -l | sort -nr | head -25
```

Any touched non-generated Swift file over 1000 lines must be split by responsibility before acceptance.

### Live app/HTTP gate

1. Build and launch the current app bundle with isolated roots and `--project-root`; capture the executable/bundle mtimes to rule out a stale bundle.
2. Open the status menu. Capture Stopped, Start-enabled/Open-disabled evidence.
3. Click Start. Capture Starting if observable, then Running with the actual URL and Open enabled.
4. Save the following without persisting the CSRF token:

```bash
base_url=http://127.0.0.1:19091
curl -fsS "$base_url/healthz" | tee tmp/app-lifecycle-packaging/evidence/healthz.json
curl -fsS -D tmp/app-lifecycle-packaging/evidence/index.headers \
  "$base_url/" -o tmp/app-lifecycle-packaging/evidence/index.html
curl -fsS "$base_url/api/v1/bootstrap" \
  | jq 'del(.data.csrfToken)' > tmp/app-lifecycle-packaging/evidence/bootstrap-redacted.json
curl -fsS -H 'Content-Type: application/json' \
  --data '{"query":"query WebInstances { workflowInstances { result { accepted status diagnostics } value { identity workflowId displayName configuration } } }","operationName":"WebInstances"}' \
  "$base_url/graphql" > tmp/app-lifecycle-packaging/evidence/graphql-instances.json
```

5. Keep the bootstrap CSRF token only in a shell variable, perform one workflow-variable update with the current revision, then save redacted request/response evidence. Assert the isolated `daemon-workflows.json` changed and API/GraphQL/native Instances all show the new value/metadata.
6. Verify `/instances`, an instance logs/timeline route, `/workflows`, and `/settings` in the browser at normal and narrow widths; save screenshots under `tmp/app-lifecycle-packaging/evidence/browser/`.
7. Open native Instances, Notes, Note Settings, and Viewer windows and save screenshots under `tmp/app-lifecycle-packaging/evidence/native/`.
8. Click Stop and wait for Stopped. Then require both commands to prove release:

```bash
! curl -fsS --max-time 2 http://127.0.0.1:19091/healthz
test -z "$(lsof -nP -iTCP:19091 -sTCP:LISTEN -t)"
```

9. Re-run CLI serve/config regression assertions for `8787`; do not repurpose the live app-server listener for CLI tests.

### Acceptance matrix

| Acceptance criterion | Required evidence |
| --- | --- |
| truthful Start/Stop/Open | controller tests + native menu screenshots + stop/release probe |
| default loopback `19091` | settings test + `lsof` bound address + health curl |
| built SolidJS application served | Bun gates + bundle file assertions + index/hashed-asset curl |
| real instances/logs/workflows/settings | API integration tests + mutation persistence + four browser screenshots |
| native Swift interfaces preserved | native window screenshots + RielaApp build |
| release integration | local bundle asset verification + Cask structural/dry-run tests |
| CLI semantics preserved | server configuration/CLI serve tests asserting `8787` |

No completion claim is allowed from unit tests alone or from screenshots against mocked data.

## 10. Module 8 — Documentation and Progress Closure

**Status**: NOT_STARTED

### Write scope during implementation

- User-facing RielaApp help/README sections that document Start/Stop/Open, default URL, port recovery, asset failure, and localhost-only scope.
- Release/build documentation that states Bun and bundled asset requirements.
- This plan's status tables, checklists, and progress log.
- `impl-plans/README.md` active-plan index, then move this file to `impl-plans/completed/` only after every non-deferred completion criterion passes.

### Completion checks

- [ ] Docs state app `19091` and CLI `8787` separately.
- [ ] Docs never suggest non-loopback access or expose CSRF/env/credential details.
- [ ] Verification commands and evidence paths match what was actually run.
- [ ] Any deferred signed-notarization check has an owner/trigger and is not represented as passed.

## 11. Dependencies and Risks

| Dependency/risk | Handling | Owner module |
| --- | --- | --- |
| `NWListener` readiness/cancellation races | generation token + deterministic fake listener tests + live rebind | 2, 4 |
| RielaServer is cross-platform | `canImport(Network)` and macOS-only factory/linking | 2 |
| Network callback touching AppKit/app state | all API closures hop to `@MainActor` | 3 |
| native/web concurrent edits | revision token and `409` reload path | 1, 3, 5 |
| localhost CSRF/DNS rebinding | strict Host/Origin, JSON-only mutation, per-launch CSRF, no CORS | 3 |
| logs/sessions can be large | bounded DTOs, pagination/truncation, frontend virtualization | 3, 5 |
| source and Cask builders diverge | one reusable asset helper called by both builders | 6 |
| stale or missing frontend assets | startup/build validation, no implicit packaged fallback | 2, 6 |
| signed Cask needs external credentials | structural/dry-run gate always; signed gate only with credentials and explicit evidence | 6, 7 |
| unrelated dirty/concurrent worktree changes | limit edits to listed files; inspect `git diff --name-only` before each phase | all |

## 12. Completion Criteria

- [ ] Modules 1–6 deliverables and focused tests are complete.
- [ ] Bun install/lint/typecheck/test/build all pass from a clean `web/` state.
- [ ] `swift build`, `swift build --product RielaApp`, focused Swift tests, SwiftLint, and `git diff --check` pass.
- [ ] Live isolated menu → health/UI/API → persisted mutation → stop/port-release journey passes.
- [ ] Browser screenshots cover instances, logs/timeline, workflows, and settings with live data.
- [ ] Native Instances, Notes, Note Settings, and Viewer windows still open in the same isolated run.
- [ ] Local app bundle and Cask staging integration contain verified assets.
- [ ] CLI `RielaServerConfiguration`/serve default remains `8787`.
- [ ] No high or mid implementation/review finding remains unresolved.
- [ ] Documentation and progress records reflect actual evidence; no credential-dependent release claim is fabricated.

## 13. Progress Log

### 2026-07-17 — Planning

- Completed: reference study; required ideal-spec workflow; accepted feature design; implementation-plan self and independent review.
- In progress: none; plan is ready for implementation.
- Blockers: none.
- Evidence: `tmp/app-lifecycle-packaging/ideal-spec-review.md` (workflow baseline; scratch, not a deliverable).
- Notes: runtime-provided `docs/design/...` and `docs/plans/...` paths were normalized to the repository-required `design-docs/specs/...` and `impl-plans/active/...` locations while retaining the feature basename.

## 14. Review Record

### Plan self-review

Decision: **accepted after corrections**.

- High plan-only — frontend work could begin before Swift API fields and error semantics stabilized, causing contract drift. Addressed by making contract fixtures Module 1 and gating Module 5 on the frozen API contract.
- Mid plan-only — initial verification could have mutated the developer's active RielaApp profile. Addressed with mandatory isolated app/home/project roots and fixture-only state.
- Mid plan-only — target tests alone could not prove menu truthfulness or native UI preservation. Addressed with the live menu/HTTP/native-window/browser evidence matrix.
- Mid plan-only — app build coverage did not prove the independent Cask bundle path. Addressed with shared-helper structural tests, Cask dry-run, and staged asset verification.

### Independent plan review

Decision: **accepted after corrections**.

- High plan-only — localhost security acceptance lacked adversarial Host/Origin/CSRF tests. Addressed in Module 3 completion checks and the automated gate.
- Mid plan-only — stop acceptance used menu text without proving socket release. Addressed with both failed curl and empty `lsof` assertions after awaited stop.
- Mid plan-only — signed/notarized release verification could be incorrectly claimed when credentials are absent. Addressed by separating always-required local/structural evidence from credential-gated signed release evidence.
- Mid plan-only — progress closure lacked Swift file-size and dirty-worktree checks. Addressed with explicit file-size, `git diff --check`, and phase-boundary scope checks.

No unresolved high or mid plan-only findings remain. Design findings are tracked separately in the design document and are not duplicated as plan defects.
