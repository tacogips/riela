# RielaApp Local Web UI Design

Status: accepted for implementation

Feature ID: `solidjs-web-ui`

Workflow mode: `issue-resolution`

Issue: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`

## Objective

Add an optional, menu-controlled browser surface to the existing macOS RielaApp without removing, renaming, or changing the concepts of its native windows. The app owns a loopback-only HTTP listener, serves a bundled Bun/SolidJS application, and exposes real reads and mutations for instances, execution logs, workflows, note settings, assistant settings, and web-server settings.

The app server defaults to `127.0.0.1:19091`. It is independent of `RielaServerConfiguration`, whose `127.0.0.1:8787` default and CLI `serve` behavior remain unchanged.

## Scope

### In scope

- A dependency-free macOS HTTP/1.1 transport in `RielaServer`, implemented with Network.framework `NWListener` and reusable with any `ServerRouteHandling` implementation.
- Existing deterministic routes over the real listener: `GET /healthz`, `GET /overview`, and `POST /graphql`.
- Static files from `web/dist`, copied into `RielaApp.app/Contents/Resources/Web`, including safe SPA navigation fallback.
- A RielaApp-specific JSON API composed above `RielaServer` so `RielaServer` does not depend on `RielaAppSupport` or `RielaViewer`.
- Real read and mutation flows for instance configuration, event sources, node patches, workflow sources/settings, note settings, assistant settings, and web-server settings.
- Real execution/session/timeline data loaded through `RielaViewer`.
- Truthful Start, Stop, Open in Browser, and listener-status menu items.
- Persisted app-server enabled state and port.
- Bun, SolidJS, Vite, and Tailwind frontend under `web/`, with no shipped fixtures.
- Build, test, live HTTP, mutation round-trip, packaging, native-window regression, and browser visual verification.

### Out of scope

- Replacing or redesigning the native Instances, Notes, Note Settings, or Viewer windows.
- Changing CLI server configuration, authentication, GraphQL semantics, or port 8787.
- Binding a non-loopback interface, remote access, TLS termination, or CORS support.
- A general-purpose production HTTP server: only bounded HTTP/1.1 request/response behavior needed by the local application is supported.
- Editing arbitrary workflow source files from the browser. Workflow source registration/removal and instance node patches are supported; authored workflow file editing remains in the existing tools.
- Exposing inherited process environment, resolved secret values, keychain content, or S3 credential values. Stored instance environment variables are shown because they are explicitly editable configuration; note S3 settings expose credential environment-variable names only.

## Current system and reference study

Riela already has `ServerRequestEnvelope`, `ServerResponseDescriptor`, and `DeterministicServerRouteHandler` in `Sources/RielaServer/ServerContracts.swift`, but no socket is bound. The deterministic handler returns JSON for `/`, `/overview`, `/healthz`, and `/graphql`. `RielaServerConfiguration` defaults to port 8787 and is used by existing server/CLI semantics.

RielaApp owns live state and mutation seams on `@MainActor`: `RielaAppDaemonWorkflowStore`, `RielaAppDaemonWorkflowRuntime.snapshot(for:)`, workflow discovery, event registration, node patches, assistant settings, and the native menu. `WorkflowViewerLoader` supplies real session summaries, timeline entries, logs/messages, and diagnostics. Note settings currently live inside the app target and need to become shared support models without changing the native window.

The read-only comparison with `<reference-checkout>/ccusage-gauge` established four useful patterns:

- Bind only `127.0.0.1`; own start/stop at the menu delegate and stop on application termination.
- Derive the menu label from actual listener state and start the server before opening the browser.
- Resolve static files from an explicit development root or `Bundle.main/Resources/Web`, reject traversal, and use `index.html` only for extensionless UI navigation.
- Build frontend assets before packaging and copy them into `Contents/Resources/Web`.

Riela differs by using Network.framework rather than the reference's direct POSIX sockets, by preserving deterministic GraphQL routing, and by requiring mutable application services with conflict handling.

## Architecture and dependency boundaries

```text
Status-item menu / app termination
              |
              v
RielaAppWebServerController (@MainActor lifecycle state machine)
              |
              v
LoopbackHTTPServer (RielaServer, NWListener)
              |
              v
RielaAppWebRouter (RielaApp composition root)
     |                 |                 |
     v                 v                 v
deterministic      app JSON API      static asset resolver
RielaServer        facade            Resources/Web
routes             (@MainActor)
                       |
       +---------------+--------------------+
       |               |                    |
RielaAppSupport   daemon runtime/store   RielaViewer loader
settings/models   and discovery          session/timeline data
```

Dependency rules:

1. `RielaServer` owns only generic transport, bounded HTTP parsing/writing, deterministic route adaptation, and static asset resolution. It must not import `RielaAppSupport`, `RielaViewer`, or AppKit.
2. Shared settings data and atomic persistence belong in `RielaAppSupport`. Move note-settings value/store types there and leave AppKit window code in `RielaApp`.
3. `RielaAppWebAPIService` and `RielaAppWebRouter` live in `RielaApp`, where dependencies on AppSupport, Viewer, Server, and AppKit are already legal. The service invokes the same validation/persistence helpers as the native UI; it does not write `daemon-workflows.json` directly.
4. All mutations and snapshots of app-owned mutable state cross `@MainActor`. Socket callbacks never read `RielaApp` properties directly.
5. Frontend TypeScript contracts are explicit mirrors of versioned JSON DTOs, not serialized internal Swift types.

## Generic HTTP transport

### Types

Add these public transport concepts to `RielaServer`:

- `LoopbackHTTPServerConfiguration(host: "127.0.0.1", port: UInt16, limits: HTTPRequestLimits)`; the host initializer rejects anything except the IPv4 loopback address for this server.
- `HTTPRequestLimits`: header bytes 32 KiB, body bytes 2 MiB, request-target bytes 8 KiB, read timeout 10 seconds, write timeout 30 seconds, and one request per connection.
- `HTTPTransportResponse(status, headers, body: Data)` for JSON or binary/static bodies.
- `HTTPTransportState`: `stopped`, `starting`, `running(boundHost, boundPort)`, `stopping`, or `failed(message)`.
- `LoopbackHTTPServer.start()` reports readiness only after `NWListener.State.ready`; `stop()` cancels the listener and reports stopped only after cancellation. Repeated start/stop calls are idempotent.

### Parsing and response rules

- Accept origin-form HTTP/1.1 requests only. Parse method, percent-decoded path, raw query, lower-cased headers, and an optional fixed-length body into an expanded `ServerRequestEnvelope` while preserving source compatibility through defaulted fields.
- Support `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, and `DELETE`. Reject unsupported methods with 405 and an `Allow` header.
- Require a valid `Content-Length` for request bodies. Reject conflicting/invalid lengths, transfer encoding, chunked bodies, malformed headers, invalid UTF-8 header sections, request-target fragments, oversize inputs, and premature EOF with deterministic 4xx responses.
- Always send `Content-Length`, `Connection: close`, `X-Content-Type-Options: nosniff`, and `Cache-Control: no-store` for API responses. `HEAD` sends headers without body bytes.
- Map standard reasons for 200, 201, 204, 400, 403, 404, 405, 409, 413, 415, 422, 500, and 503.
- Never log request bodies, authorization headers, environment values, or settings payloads.

### Deterministic handler adapter

`DeterministicServerRouteHandler` remains the owner of `/healthz`, `/overview`, and `/graphql`. An adapter JSON-encodes its `JSONObject` body with sorted keys into `HTTPTransportResponse`. The web router reserves `GET /` for the SPA, so deterministic overview remains at `/overview`; direct deterministic-handler tests for `/` remain unchanged.

## Static asset serving

`RielaStaticAssetResolver` searches, in order:

1. An explicit root injected by tests or development launch configuration.
2. `Bundle.main.resourceURL/Web` for the packaged app.
3. Repository `web/dist` only when a development root was explicitly derived from the app's `--project-root` launch option; it does not scan arbitrary parent directories.

Resolution standardizes the requested path and proves it remains below the selected root. Encoded separators, NULs, `..`, symlinks escaping the root, and unreadable files return 404. Exact assets receive extension-based MIME types and immutable caching only when their filenames contain a Vite content hash. `index.html` is `no-store`.

SPA fallback is allowed only for `GET`/`HEAD`, extensionless paths outside `/api/`, `/graphql`, `/healthz`, `/overview`, and `/note/`. Missing asset paths containing an extension return 404 and never return HTML.

## Application-server lifecycle and settings

`RielaAppWebServerSettings` is a Codable AppSupport value with:

- `version: 1`
- `isEnabled: Bool`, default `false`; this is the desired persisted launch state.
- `port: Int`, default `19091`, valid range `1024...65535`.

`RielaAppWebServerSettingsStore` atomically persists it below the app support root as `web-server.json`. Invalid/corrupt settings are quarantined using the daemon-store pattern and defaults are loaded. The type is separate from `RielaServerConfiguration`.

`RielaAppWebServerController` owns the settings, server, router, and observable lifecycle state. Its rules are:

- On app launch, load settings and start only when `isEnabled` is true.
- Start persists `isEnabled = true` only after listener readiness. Start failure keeps the actual state `failed`, persists `isEnabled = false`, and exposes the error.
- User-requested Stop first records `stopping`, waits for listener cancellation, persists `isEnabled = false`, then records `stopped`.
- Application termination uses a distinct `shutdownForTermination()` path: it closes the listener and waits with a bounded timeout before completing the existing termination reply, but preserves `isEnabled`. A clean quit therefore retains the user's autostart intent for the next launch.
- A port edit persists the new configured port. If the listener is running, the API returns `restartRequired: true`; the current bound port remains truthful until the user stops/starts it. This avoids dropping the response or silently moving the browser origin.
- The configured port and bound port are separate values in state and UI.

Menu behavior is derived exclusively from controller state:

| State | Start | Stop | Open in Browser | Status line |
|---|---|---|---|---|
| stopped | enabled | disabled | disabled | `Web server stopped · configured 127.0.0.1:<port>` |
| starting | disabled | enabled | disabled | `Web server starting…` |
| running | disabled | enabled | enabled | actual `http://127.0.0.1:<boundPort>` |
| stopping | disabled | disabled | disabled | `Web server stopping…` |
| failed | enabled | disabled | disabled | sanitized listener error |

Open in Browser never implies success: it is enabled only while running and uses the actual bound port. Every controller transition requests `rebuildMenu()`. App termination and controller deinitialization close the listener; neither deinitialization nor termination rewrites the desired enabled setting.

## Versioned application API

All new JSON routes live under `/api/v1`. Responses use ISO-8601 dates, sorted JSON keys in tests, and an envelope `{ "data": ..., "revision": "..." }`. Errors use `{ "error": { "code": "...", "message": "...", "fieldErrors": {...} } }`. Internal paths may be returned where the native UI already shows them, but errors are sanitized and never include payloads or secrets.

GET responses carry a `revision` derived from the relevant persisted model and active profile. Mutations that can overwrite configuration require the last observed `revision`; a mismatch returns 409 `stale_revision` and the fresh revision. Mutation operations execute on `@MainActor`, validate a fresh current model, persist atomically, refresh app caches/windows, and apply the same active-instance restart behavior as native edits.

### Route contract

| Method and path | Real backing seam | Behavior |
|---|---|---|
| `GET /api/v1/bootstrap` | controller, active profile, cached instances | Navigation counts, active profile, configured/bound server state; no fixture fallback. |
| `GET /api/v1/instances` | discovered/profiled instances plus `daemonRuntime.snapshot(for:)` | Lists real source, availability, active/runtime status, and configuration summary. |
| `GET /api/v1/instances/{id}` | resolved instance and preference | Full editable working directory, environment file path, stored environment variables, workflow variables, event-source documents, and node patches. |
| `PATCH /api/v1/instances/{id}/configuration` | shared preference validators and `updateDaemonPreference` | Partial structured update for working directory, environment file path, environment variables, workflow variables, availability/active flags; restart active instance when required. |
| `PUT /api/v1/instances/{id}/node-patches/{nodeId}` | `saveDaemonNodePatch` | Validate and save one real node patch. |
| `DELETE /api/v1/instances/{id}/node-patches/{nodeId}` | `saveDaemonNodePatch(..., nil)` | Remove one patch. |
| `POST /api/v1/instances/{id}/event-sources` | extracted shared event-source registration service | Validate source/binding JSON, constrain filenames/root, atomically save both, then refresh/restart. |
| `DELETE /api/v1/instances/{id}/event-sources/{sourceId}` | same event-source service | Remove only the matched source and bindings under the resolved `.riela-events` root after safe-ID validation. |
| `GET /api/v1/instances/{id}/executions` | `WorkflowViewerLoader.load` | Real session summaries and diagnostics for the resolved workflow/session store. |
| `GET /api/v1/instances/{id}/executions/{sessionId}` | `WorkflowViewerLoader.load(selectedSessionId:)` | Real timeline entries, step/run-log messages, selected session, and diagnostics. |
| `GET /api/v1/workflows/sources` | daemon workflow/project directories and repositories plus discovery/catalog cache | Real registered sources, discovered workflows, and catalog refresh state. |
| `POST /api/v1/workflows/sources/directories` | shared source-add service | Validate and register an existing directory. |
| `DELETE /api/v1/workflows/sources/directories` | shared source-remove service | Remove the exact registered directory, without deleting disk content. |
| `POST /api/v1/workflows/sources/repositories` | existing repository validation/add path | Register a repository reference. |
| `DELETE /api/v1/workflows/sources/repositories/{id}` | existing remove path | Remove registration only. |
| `GET /api/v1/settings/notes` | shared `RielaAppNoteSettingsStore` | Read API exposure, translation language, S3 profile metadata, and credential env names. |
| `PUT /api/v1/settings/notes` | same store plus native refresh seam | Validate and atomically replace settings; never resolve credential variables. |
| `GET /api/v1/settings/assistant` | `daemonState.assistant` | Read assistance, selected vendor/model, vendor model choices, and folded state; omit chat messages from the settings contract. |
| `PUT /api/v1/settings/assistant` | `saveAssistantSettings` | Validate vendor/model against the bundled catalog and preserve messages while replacing settings fields. |
| `GET /api/v1/settings/web-server` | controller | Read configured and bound ports, desired enabled state, actual lifecycle state, and last error. |
| `PUT /api/v1/settings/web-server` | settings store/controller | Validate and persist port; report `restartRequired` when it differs from the running listener. It does not start or stop the server. |

`POST /graphql` is passed unchanged to the configured `GraphQLDocumentExecuting` service. The browser client uses GraphQL where the existing schema already provides a required read; the versioned JSON API remains the canonical contract for app-only state and mutations absent from GraphQL.

## Same-origin and local security policy

Loopback binding is necessary but not sufficient because hostile web pages can target localhost. The router therefore:

- Accepts `Host` only as `127.0.0.1:<boundPort>` or `localhost:<boundPort>`; missing or mismatched hosts receive 403.
- Sends no `Access-Control-Allow-Origin` header and rejects `OPTIONS`.
- For every mutation and GraphQL POST, requires `Content-Type: application/json` and an absent Origin (CLI client) or an Origin exactly matching the request's loopback origin. Browser `Sec-Fetch-Site: cross-site` is rejected.
- Uses no state-changing GET route and does not accept form-encoded or text/plain mutations.
- Applies transport size/time limits and deterministic path-segment validation.
- Returns a restrictive CSP for the SPA: default self, scripts/styles self, connect self, objects none, frames none, base-uri none, and frame-ancestors none.

This design intentionally does not expose the listener beyond the local user session. If remote access is requested later, authentication and TLS require a separate design.

## Frontend design

The `web/` workspace uses Bun scripts, SolidJS, Vite, TypeScript strict mode, ESLint, and Tailwind. The application has a persistent navigation shell and these route-level views:

- Instances: real list/status polling; selected-instance editors for environment variables, workflow variables, event sources, working directory/environment file, and node patches. Save controls show validation, stale-revision recovery, persisted success, and restart effects.
- Logs: real execution list and selected timeline/run log. Poll only while an instance/session is active; keep last successful data visible during transient errors.
- Workflows: real source directories, repository registrations, discovered workflows, and node-patch visibility, with source add/remove mutations and destructive confirmation.
- Settings: note, assistant, and web-server settings. The web-server section distinguishes configured from bound port and explains restart requirements.

The client has one typed fetch layer. It aborts stale requests, surfaces non-2xx error envelopes, sends same-origin JSON headers, retains server revisions, and never substitutes mock data. Loading, empty, error, conflict, saving, and success states are visible and keyboard accessible. Layout supports 1280px desktop and 768px narrow-browser verification; controls have labels, focus states, and sufficient contrast.

No fixture, sample instance, fallback response, or hard-coded log ships under `web/src`. Unit tests may use fixtures only under test directories.

## Packaging and development assets

`scripts/build-riela-menu-bar-app.sh` requires Bun, runs the locked install in frozen mode, then `bun run lint`, `bun run typecheck`, and `bun run build` before the Swift app build. It copies `web/dist/.` to `RielaApp.app/Contents/Resources/Web/` and verifies both `index.html` and at least one built JS asset before reporting success. Task `app:build` continues to call the script.

Development `swift run RielaApp --project-root <repo>` may resolve `<repo>/web/dist`; it fails visibly when assets are absent. Packaged builds never fall back to the source checkout. Homebrew Cask packaging inherits the app build output and must verify the resource directory before signing/notarizing.

## Failure behavior and observability

- Port in use: controller reaches `failed`, menu displays a sanitized bind error, enabled state is false, and no browser-open action is enabled.
- Missing assets: `/healthz`, `/overview`, `/graphql`, and `/api/v1` remain available; UI navigation returns a deterministic 503 `web_assets_unavailable` rather than the JSON overview.
- Invalid/stale mutation: 422/409 with field-level errors; no partial persistence and no automatic restart.
- Viewer/session load failure: 404 for a missing safe ID or 500 with sanitized diagnostics; other views remain usable.
- Listener failure after readiness: state changes to failed, menu rebuilds, and controller relinquishes the listener.
- Telemetry records method, route template, response status, latency, and lifecycle transition only. Instance IDs, paths, query text, and bodies are excluded.

## Verification strategy

Unit and integration coverage must include:

- HTTP request parsing, fixed-length body handling, malformed/oversize rejection, method handling, deterministic route adaptation, host/origin policy, static MIME types, traversal/symlink rejection, SPA fallback, missing assets, port collision, listener failure, repeated start/stop, and stop releasing the socket.
- Settings defaults, corrupt-file quarantine, validation, atomic persistence, independence from `RielaServerConfiguration.port`, and enabled-state survival across clean termination/relaunch.
- API DTO encoding, revisions/conflicts, each required read, each mutation, active-instance restart behavior, event-source safe deletion, note/assistant field preservation, and Viewer-backed session/timeline reads.
- Menu state matrix and termination shutdown behavior through AppKit-accessible controller tests.
- Frontend typed API/error behavior and view states, with no shipped fixture imports.
- Bundle asset presence and content through the packaging script.

Live evidence goes only under `tmp/solidjs-web-ui/` and proves:

1. Start from the menu produces a real listener on 19091 and truthful menu state.
2. `/healthz`, `/overview`, `/graphql`, `/api/v1/instances`, and `/` return the expected real surfaces.
3. A workflow-variable update round-trips through the API, is present in the active profile's `daemon-workflows.json`, and re-reads through the API.
4. Instances, logs/timeline, workflows, and settings render usable real-data states in browser screenshots.
5. Stop from the menu makes curl fail and leaves no 19091 listener.
6. Native Instances, Notes, Note Settings, and Viewer windows still open.
7. CLI `serve` and `RielaServerConfiguration()` still use port 8787.

## Acceptance criteria

- The menu's controls and status reflect actual listener transitions and the actual bound port.
- Default app-server behavior is loopback-only port 19091, persisted independently from the CLI's 8787 configuration.
- Built SolidJS assets, health, overview, GraphQL, and the app API are served by a real listener.
- Every required view is backed by current application/store/viewer data and required settings/configuration changes persist through shared mutation seams.
- No static fixture path exists in shipped frontend code.
- Transport, API, settings, menu, frontend, Swift, packaging, live mutation, port-release, visual, and native regression gates pass.

## Design review record

### Self-review

Decision: accepted after corrections.

- Mid defect, corrected: the initial route concept placed app persistence in `RielaServer`, which would create an invalid dependency direction. The accepted design keeps generic transport in `RielaServer` and composes app APIs in `RielaApp`.
- Mid defect, corrected: loopback binding alone did not address cross-site browser requests to localhost. Exact Host/Origin, JSON content type, fetch metadata, no CORS, and no state-changing GET requirements are now explicit.
- Mid defect, corrected: changing the port from the browser could terminate the request and make menu state misleading. The accepted contract persists the new configured port, reports restart required, and retains the actual bound port until a menu restart.
- High defect, corrected: using the user Stop path during application termination would clear `isEnabled`, making persisted autostart impossible after a clean quit. Termination now has a separate listener shutdown path that preserves desired enabled state.
- Low observation, retained as verification: note-settings types currently reside in the AppKit file and must move to AppSupport without altering native behavior.

### Independent design review

Review lens: fanout contract coverage, dependency legality, mutation truthfulness, security, failure behavior, and verifiability. No delegated Codex agent was used.

Decision: accepted after corrections; no open high or mid findings.

- High defect, corrected: the first API inventory exposed stored mutation data but had no lost-update protection against native-window edits. Relevant GETs now return revisions and overwriting mutations require the observed revision, with 409 conflicts.
- Mid defect, corrected: node patches and event sources were readable but did not both have explicit mutation paths. PUT/DELETE node-patch and POST/DELETE event-source routes are now required.
- Mid defect, corrected: static SPA fallback could mask missing JavaScript as HTML. Fallback is now extensionless UI navigation only and excludes all service prefixes.
- Mid defect, corrected: assistant replacement could erase chat history. The settings mutation now preserves messages and only replaces validated settings fields.
- Mid defect, corrected: Network.framework is unavailable on some Swift package hosts. The transport is guarded by `canImport(Network)` with an explicit unsupported-platform implementation so non-macOS package builds retain compile-time compatibility; live listener tests are conditional while parser/router tests remain portable.
- Low residual risk: NWListener readiness/cancellation timing and AppKit menu transitions require deterministic injected-listener tests plus a live port-release test.
