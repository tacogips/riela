# RielaApp Web Server Lifecycle and Asset Packaging

**Status**: Accepted for implementation
**Feature ID**: `app-lifecycle-packaging`
**Issue**: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`
**Workflow mode**: `issue-resolution`
**Last updated**: 2026-07-17

## 1. Decision Summary

RielaApp will own a second, app-specific HTTP server that is independent from the existing CLI serving configuration. It binds IPv4 loopback only, defaults to `127.0.0.1:19091`, persists its desired enabled state and port at app scope, and is controlled by truthful menu actions. The existing `RielaServerConfiguration` default (`127.0.0.1:8787`) and CLI `riela serve` behavior remain unchanged.

The server has three layers:

1. `RielaServer` supplies a real macOS HTTP/1.1 listener, request limits, byte responses, deterministic route adaptation, and static-asset resolution.
2. `RielaApp` supplies a main-actor lifecycle controller and an app API facade that projects and mutates the same profile, instance, workflow, viewer, note, and assistant state used by native windows.
3. `web/` supplies a Bun-built SolidJS/Tailwind single-page application. Release builders copy `web/dist` into `RielaApp.app/Contents/Resources/Web`; explicit development mode may fall back to the repository `web/dist`.

No native window, store, CLI command, or existing concept is removed or replaced.

## 2. User Contract

### 2.1 Menu journey

After RielaApp initializes its active profile, the status menu contains:

- `Start Web Server`: enabled only when the listener is stopped or failed.
- `Stop Web Server`: enabled while starting or running; a stop requested during startup cancels that generation.
- `Open in Browser`: enabled only when the listener has reported ready and assets are available.
- `Copy Web Server URL`: enabled only while running and copies the actual bound URL.
- `Web Server Port…`: edits the persisted port; while running, the controller performs a replacement-listener handoff.
- a disabled status row that reports `Stopped`, `Starting 127.0.0.1:<port>`, `Running <url>`, `Stopping <url>`, or `Failed: <actionable reason>`.

Start publishes `Running` only after the socket is bound and the asset root passes readiness validation. Stop publishes `Stopped` only after listener cancellation completes. Open never starts a stopped or failed server implicitly; this keeps the menu state and the user's action unambiguous.

### 2.2 Persistence contract

`RielaAppWebServerSettings` is app-global because one process owns one listener while the active profile can change. It is stored under the configured app root, not inside a profile:

```text
<app-root>/web-server.json
```

```json
{
  "version": 1,
  "isEnabled": false,
  "port": 19091
}
```

- Missing or older files decode to `isEnabled: false`, `port: 19091`.
- The persisted host is not configurable; it is always `127.0.0.1`.
- Valid ports are `1...65535`. Bind failures are surfaced without rewriting the setting.
- `Start` persists `isEnabled: true` before attempting startup so an intended autostart remains visible after a failed launch. `Stop` persists `false` before stopping.
- On app launch, `isEnabled: true` triggers startup after profile/store initialization.
- A running port change is transactional: bind and validate the replacement first, persist the new port, publish the new endpoint, then stop the old listener. Failure leaves the old listener and old persisted port intact.

### 2.3 Browser journey

The SPA retains native RielaApp nouns and groups them into four primary routes:

| Route | Reads | Mutations |
| --- | --- | --- |
| `/instances` | active-profile instances, source, readiness, runtime snapshot | start, stop, restart, add/remove/relink, configuration save |
| `/instances/:id/logs` | sessions, execution timeline, backend events, inbox/outbox messages | refresh/select only; logs remain immutable |
| `/workflows` | discovered sources, installed/profile sources, repositories/catalogs, validation, node patches | add directory/URL/repository, refresh/install, save node patch |
| `/settings` | note, assistant, and app web-server settings | save note settings, save/submit assistant settings, change web-server port |

Every shipped view is backed by live data. Empty states explain why no data exists and offer a real recovery action; fixture/mock data is allowed only in tests and development stories.

## 3. Architecture

```text
NSStatusItem menu
      |
      v
RielaAppWebServerController (@MainActor)
      | owns settings + generation + listener handle
      v
RielaHTTPListener (RielaServer, Network.framework, 127.0.0.1 only)
      |
      +-- /healthz, /overview, /graphql
      |      -> DeterministicServerRouteHandler
      |
      +-- /api/v1/*
      |      -> RielaAppWebAPIFacade (@MainActor closures)
      |
      +-- /*
             -> RielaStaticAssetResolver -> bundled Web/ or explicit dev root
```

### 3.1 HTTP transport in `RielaServer`

Add a transport separate from `WorkflowServingController`'s current in-process listener so the app feature cannot change CLI serving semantics by accident.

Proposed public contracts:

```swift
public struct RielaHTTPRequest: Sendable {
  public var method: String
  public var target: String
  public var path: String
  public var query: [String: [String]]
  public var headers: [String: String]
  public var body: Data
}

public struct RielaHTTPResponse: Sendable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data
}

public protocol RielaHTTPRequestHandling: Sendable {
  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse
}

public protocol RielaHTTPListenerHandle: Sendable {
  var endpoint: URL { get }
  func shutdown() async
}
```

`RielaNetworkHTTPListener` uses `NWListener` only when `canImport(Network)`. `RielaServer` remains buildable on other supported platforms by keeping Network-specific source conditionally compiled; the app factory is macOS-only. The listener:

- constructs `NWParameters.tcp`, binds the requested numeric port, and rejects any host other than `127.0.0.1` before creating the listener;
- reports readiness only on `NWListener.State.ready` and converts `.failed` into a structured startup error;
- accepts one request at a time per connection and sends `Connection: close`; keep-alive, chunked request bodies, upgrades, and streaming are non-goals;
- reads until `\r\n\r\n`, parses `Content-Length`, then reads exactly that body length;
- rejects malformed request lines/headers with `400`, unsupported transfer encoding with `501`, headers over 32 KiB with `431`, bodies over 2 MiB with `413`, and idle reads after 10 seconds with `408` or connection close;
- limits concurrent connections (default 32) and returns `503` when saturated;
- writes exact `Content-Length`, reason phrase, content type, security headers, and closes the connection;
- awaits `.cancelled` during shutdown so the lifecycle controller does not claim `Stopped` early.

Request parsing, response serialization, and static resolution are pure/testable helpers. Live listener tests use port `0` internally to obtain an ephemeral test port, even though user settings reject `0`.

### 3.2 Deterministic route adaptation

`RielaHTTPRouteAdapter` converts transport requests for `/healthz`, `/overview`, `/graphql`, and existing note registration routes into `ServerRequestEnvelope`, calls `DeterministicServerRouteHandler`, and JSON-encodes its `JSONObject` response. This preserves the existing route handler and its tests rather than changing `ServerResponseDescriptor` to carry arbitrary bytes.

For the app, `DeterministicServerRouteHandler` receives a composite `GraphQLDocumentExecuting` implementation:

- existing note GraphQL fields continue through `NoteGraphQLDocumentExecutor` when note API exposure is enabled;
- app workflow-instance and runtime/session fields call existing `GraphQLWorkflowInstanceService` and runtime snapshot services through app-profile adapters;
- unsupported fields return structured GraphQL errors; they do not silently delegate.

App-specific REST endpoints exist where native mutation orchestration matters (restart-after-configuration-change, source installation, settings stores) and therefore cannot safely be reduced to a file-store write.

### 3.3 Static assets

`RielaStaticAssetResolver` accepts ordered, explicit roots and never searches arbitrary ancestor directories:

1. packaged: `Bundle.main.resourceURL/Web`;
2. SwiftPM resource bundle if the implementation chooses to process a checked-in synchronized copy;
3. development only: `<repository-root>/web/dist`, supplied explicitly by `RIELA_APP_WEB_ASSET_ROOT` or a launch-option-derived repository root.

Release startup requires readable `index.html` and at least one referenced hashed asset. A missing or incomplete root fails startup with `web_assets_missing`; `/healthz` is never reachable from a listener that lacks its UI.

Resolution rules:

- percent-decode once; reject NUL, invalid encoding, absolute paths, `..`, symlinks that escape the canonical root, and directory reads;
- `/` resolves to `index.html`;
- extensionless non-API navigation paths may fall back to `index.html`;
- missing paths with a file extension return `404` and never return HTML;
- `/api/`, `/graphql`, `/healthz`, `/overview`, and `/note/` never use SPA fallback;
- MIME types cover HTML, CSS, JS/MJS, JSON, SVG, PNG, JPEG, WebP, ICO, WOFF/WOFF2, and source maps;
- `index.html` uses `Cache-Control: no-store`; hashed assets use immutable caching; all responses set `X-Content-Type-Options: nosniff`.

### 3.4 App lifecycle controller

`RielaAppWebServerController` is `@MainActor` and owns the only mutable lifecycle state:

```swift
enum RielaAppWebServerState: Equatable {
  case stopped
  case starting(port: Int)
  case running(endpoint: URL)
  case stopping(endpoint: URL?)
  case failed(port: Int, message: String)
}
```

It uses a monotonically increasing generation token. Listener callbacks from an old generation cannot overwrite current state. A single `onStateChange` callback asks `RielaApp` to rebuild the menu on the main actor.

The controller takes factories for the listener, router, assets, and settings store so unit tests can deterministically cover ready, failed, cancellation, stale callback, replacement, and shutdown paths.

`RielaApp.applicationShouldTerminate` awaits both daemon-runtime shutdown and web-listener shutdown under the existing bounded termination path. `applicationWillTerminate` retains a best-effort cancellation fallback.

## 4. App API Contract

### 4.1 Routing and envelopes

All app REST routes live under `/api/v1`. Success responses use:

```json
{"data": {}, "revision": "profile-generation-token"}
```

Errors use:

```json
{
  "error": {
    "code": "stale_revision",
    "message": "The instance changed. Reload and retry.",
    "fieldErrors": {"port": "Port must be between 1 and 65535."}
  }
}
```

Mutations accept an `If-Match`/revision token and return `409` when the active profile or daemon state changed since the editor loaded. This prevents an open browser tab from overwriting newer native-window edits. Profile switches invalidate all previous revisions; the SPA refreshes bootstrap state and returns to the instance list.

### 4.2 Endpoint inventory

| Method and path | Backing seam | Purpose |
| --- | --- | --- |
| `GET /api/v1/bootstrap` | controller/profile state | capabilities, active profile, server endpoint/settings, revision |
| `GET /api/v1/instances` | daemon cache + `snapshot(for:)` | list, readiness, runtime state |
| `GET /api/v1/instances/:id` | daemon store/discovery | configuration, source, env metadata, node patches |
| `POST /api/v1/instances` | existing add-instance action | create from a discovered source |
| `PATCH /api/v1/instances/:id` | existing save/relink helpers | display/source/configuration update |
| `DELETE /api/v1/instances/:id` | existing remove action | remove app-profile instance with confirmation input |
| `POST /api/v1/instances/:id/actions/:action` | daemon runtime | start, stop, restart |
| `POST /api/v1/instances/:id/event-sources` | event-source registration helper | validate and persist source/binding JSON |
| `GET /api/v1/instances/:id/sessions` | `RielaViewer` loader/store | session summaries |
| `GET /api/v1/instances/:id/sessions/:sessionId` | `WorkflowViewerLoader` | timeline, logs, messages, diagnostics |
| `GET /api/v1/workflows` | discovery/profile sources/repositories | workflow sources and catalog state |
| `POST /api/v1/workflow-sources` | existing directory/URL actions | add source |
| `POST /api/v1/repositories` | existing repository action | add repository |
| `POST /api/v1/repositories/:id/refresh` | marketplace refresh action | refresh catalog |
| `POST /api/v1/repositories/:id/install` | marketplace install action | install selected workflow |
| `PUT /api/v1/instances/:id/node-patches/:nodeId` | node-patch helper | validate/save/remove patch |
| `GET/PUT /api/v1/settings/note` | `RielaAppNoteSettingsStore` | note API/language/S3 metadata settings; never return credential values |
| `GET/PUT /api/v1/settings/assistant` | daemon-state assistant settings | vendor/model/assistance; messages are bounded/redacted |
| `POST /api/v1/assistant/messages` | existing assistant submission | run a real assistant request and poll returned state |
| `GET/PUT /api/v1/settings/web-server` | lifecycle controller | read or transactionally change port |

The facade calls existing RielaApp methods on `@MainActor`; it does not write `daemon-workflows.json`, event files, or note settings from a Network callback. Native windows are refreshed by the same mutation helpers, and active instances retain existing restart-after-configuration-change behavior.

### 4.3 Local security boundary

Loopback binding is necessary but not sufficient because a hostile web page can attempt requests to localhost. The server therefore:

- accepts only `Host: 127.0.0.1:<bound-port>` or `Host: localhost:<bound-port>`; no wildcard, alternate IP, or DNS-rebound host;
- allows no cross-origin CORS; requests with `Origin` must exactly match the running endpoint (localhost alias is normalized only for same-endpoint navigation);
- requires `Content-Type: application/json` for every mutation and rejects form-encoded mutations;
- requires a per-launch random CSRF token on `X-Riela-CSRF` for `/api/v1` and app GraphQL mutations; the token is delivered only by same-origin bootstrap and kept in memory, never persisted or logged;
- responds to unapproved preflight with no access-control headers;
- uses `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`, `Referrer-Policy: no-referrer`, and `X-Frame-Options: DENY`;
- redacts environment values, secret material, request bodies, and assistant credentials from responses, diagnostics, and telemetry.

The CSRF token is not a remote-authentication scheme. Remote access, TLS, multi-user authorization, and non-loopback binding are explicit non-goals.

## 5. Frontend Design

`web/` is an independent Bun workspace with committed `bun.lock` and these scripts:

```json
{
  "scripts": {
    "lint": "eslint . --max-warnings 0",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "build": "vite build"
  }
}
```

Core dependencies are SolidJS, `@solidjs/router`, Vite, TypeScript, Tailwind CSS, ESLint, and Vitest. No client-side GraphQL library is required; a small typed fetch client keeps request/revision/CSRF behavior explicit.

The layout uses a persistent sidebar on wide windows and a compact top navigation on narrow windows. Status colors are never the only signal. Editors show field-level errors, unsaved state, revision conflicts, mutation progress, and retry actions. Destructive actions require identity-specific confirmation.

Accessibility and usability requirements:

- keyboard-visible focus, semantic headings/tables/forms, labeled status text, and minimum 44 px pointer targets for primary controls;
- responsive use down to 900 px width without horizontal loss of primary actions;
- loading skeletons, empty states, stale/reconnecting banners, and non-destructive error recovery;
- logs/timeline are virtualized or bounded so large sessions do not freeze the page;
- secrets are represented only as configured/missing metadata, never injected into HTML or returned to the browser.

## 6. Packaging and Development Resolution

### 6.1 Local app bundle

`scripts/build-riela-menu-bar-app.sh` must:

1. require `bun`;
2. run a frozen install (`bun install --frozen-lockfile`) and `bun run build` in `web/` unless an explicit verified prebuilt-assets flag is used;
3. fail if `web/dist/index.html` or referenced asset files are missing;
4. copy the directory to `RielaApp.app/Contents/Resources/Web` before signing/distribution;
5. emit the bundle path only after asset verification succeeds.

`task app:build`, `app:run`, and `app:rebuild-run` inherit this behavior through the script.

### 6.2 Homebrew Cask release

The Cask builder currently constructs its own `RielaApp.app`; updating only the local app builder would produce a signed release without the web UI. `scripts/build-homebrew-cask-release.sh` must use the same frontend build/verification helper and copy `Web` into the staged app before code signing. Packaging readiness tests assert both builders include the asset directory. A packaged-asset smoke script launches an unsigned test bundle, proves UI/hashed assets resolve, and proves a missing asset fails visibly.

### 6.3 Development fallback

`swift run RielaApp` does not imply repository asset discovery. Development fallback is enabled only by an explicit `RIELA_APP_WEB_ASSET_ROOT` or an existing launch option that resolves an absolute repository path. The resolver canonicalizes that root and applies the same traversal/symlink checks as packaged assets. Packaged builds never walk to a source checkout and never silently serve stale assets.

## 7. Failure and Concurrency Semantics

- Port in use: state becomes failed with `Server failed to start on 127.0.0.1:<port>: port already in use.` Start remains available; Open remains disabled; Port remains editable.
- Missing assets: startup fails before listener publication; error names the checked packaged root and recommends rebuilding the app.
- Startup cancellation: Stop invalidates the generation; a late ready callback shuts that listener down and cannot publish running.
- Unexpected listener failure: current generation becomes failed, endpoint actions disable, error is recorded without automatic retry loops.
- Profile switch: reads immediately project the new active profile; outstanding writes with the prior revision return `409`.
- Native/web concurrent edits: revision mismatch prevents last-writer-wins loss; the web editor offers reload, not force overwrite.
- App termination: stop is bounded and awaited; failure is logged, but termination cannot hang indefinitely.
- Frontend/API version mismatch: bootstrap advertises `apiVersion: 1`; unsupported versions show a rebuild/relaunch message rather than issuing mutations.

## 8. Verification Contract

### 8.1 Deterministic tests

- `RielaServerTests`: parser limits, content length, malformed requests, loopback enforcement, deterministic route adaptation, MIME/cache behavior, traversal/symlink rejection, SPA fallback, port collision, ready/failed/cancelled transitions, and port release.
- `RielaAppSupportTests`: settings defaults, migrations, corruption recovery, app-global path, atomic save, and validation.
- `RielaApp` tests: controller transition matrix, stale generations, start/stop persistence, transactional port replacement, menu enablement, profile-revision invalidation, CSRF/Host/Origin guards, facade mapping, mutation delegation, and redaction.
- `web/`: typed client, route rendering, revision conflict, field error, empty/loading/error states, and no fixture import in production entry points.
- packaging readiness: both app builders require and copy `Web/index.html` plus hashed assets.

### 8.2 Live evidence

Use isolated `--app-root`, `--home-root`, `--project-root`, and fixture workflows under `tmp/app-lifecycle-packaging/`; never mutate the user's real profile.

Evidence must prove:

1. menu Start transitions to Running and enables Open;
2. `curl http://127.0.0.1:19091/healthz` reports healthy;
3. `/` and a hashed JS/CSS asset return correct MIME types;
4. GraphQL returns active-profile workflow instances;
5. one workflow-variable mutation persists to the isolated `daemon-workflows.json`, refreshes the native Instances window, and re-reads through the API;
6. instances, logs/timeline, workflows, and settings browser routes are visually usable;
7. native Instances, Notes, Note Settings, and Viewer windows still open;
8. menu Stop reaches Stopped, subsequent curl fails, and `lsof -nP -iTCP:19091 -sTCP:LISTEN` is empty;
9. `riela serve` configuration tests still assert port `8787` and CLI behavior is unchanged;
10. a built app bundle and Cask staging layout contain `Contents/Resources/Web/index.html` and referenced assets.

## 9. Non-Goals

- Remote access, IPv6/wildcard binding, TLS, authentication for other users, or a background daemon.
- Replacing native RielaApp windows or changing their concepts.
- Changing `RielaServerConfiguration`, CLI `serve`, note registration, or GraphQL endpoint defaults.
- WebSocket/SSE streaming, HTTP/2, request chunking, uploads, or arbitrary file serving.
- Displaying environment values, secret-store contents, API credentials, or unrestricted filesystem editors.
- Shipping mock instance/workflow/log/settings data.

## 10. Reference Study

The read-only reference `<reference-checkout>/ccusage-gauge` informed these decisions:

- `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`: menu title derives from the listener's real `isRunning` state; Open targets `127.0.0.1:<configured-port>`; termination stops the server.
- `Sources/AppCore/HTTPService.swift`: loopback socket binding, bounded request reads, explicit content length, asset-root ordering, extensionless SPA fallback, and no HTML fallback for missing module assets.
- `scripts/sync-frontend-assets.sh`, `scripts/build-local-app.sh`, and `scripts/build-homebrew-cask-release.sh`: build output is copied into a stable `Resources/Web` layout.
- `scripts/smoke-packaged-assets.sh`: packaging is tested across concrete layouts and missing assets are a visible failure.

Riela differs by using `NWListener`, main-actor app mutation coordination, revision protection, and the existing deterministic server/GraphQL seams.

## 11. Review Record

### Design self-review

Decision: **accepted after corrections**.

- High — localhost-only binding did not by itself protect mutations from hostile browser origins. Addressed with strict Host/Origin checks, JSON-only mutations, per-launch CSRF token, no CORS, and security headers.
- Mid — a persisted port change while running could have stopped a healthy listener before discovering a collision. Addressed with replacement-first transactional handoff and stale-generation protection.
- Mid — asset readiness was underspecified. Addressed with startup validation, no health publication without assets, strict fallback rules, and missing-module `404` behavior.

### Independent design review

Decision: **accepted after corrections**.

- High — local `build-riela-menu-bar-app.sh` is not the release Cask bundle path. Addressed by requiring the separate Cask builder to use the same build/verification helper before signing.
- Mid — direct network-callback writes could bypass native refresh/restart behavior. Addressed by requiring all app mutations to cross the `@MainActor` facade and existing RielaApp action helpers.
- Mid — native and browser edits could overwrite each other. Addressed with active-profile revision tokens and `409` conflict handling.

No unresolved high or mid design findings remain.
