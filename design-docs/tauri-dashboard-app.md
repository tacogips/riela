# Riela Dashboard Desktop App (Tauri v2) Design

Status: accepted for implementation

Feature ID: `tauri-dashboard-app`

Workflow mode: `fable-and-improve-opus` (single feature, single work package; no fan-out)

Research brief: `design-docs/research/tauri-dashboard-app-brief.md`

Date: 2026-08-31

## Objective

Ship the existing Riela dashboard (`web/`, Bun + Vite + SolidJS) *additionally* as a native
desktop application built with Tauri v2, while:

- keeping the browser surface working exactly as today against both hosts — the macOS
  RielaApp listener (`127.0.0.1:19091`) and bare `riela serve` (`127.0.0.1:8787`) —
  including the `404 → cli-serve` fallback and `CLI_SERVE_HIDDEN_VIEWS`;
- keeping exactly one copy of the SPA source (no forked views, components, styles, API
  clients or Vite config);
- respecting Riela's loopback security model unchanged (no CORS, exact `Host`/`Origin`,
  `X-Riela-CSRF`, JSON content type) and adding no network exposure.

## Verified facts this design depends on

All facts below were re-verified against the tree at `b202e31` during analysis.

| # | Fact | Evidence |
| - | ---- | -------- |
| F1 | Every `/api/v1/*` and `/graphql` request to RielaApp must carry `Host: 127.0.0.1:<port>`; POST/PUT/DELETE additionally need `Origin: http://127.0.0.1:<port>`, `X-Riela-CSRF: <bootstrap token>` and `Content-Type: application/json`, else 403/415. No CORS headers are sent. | `Sources/RielaApp/RielaAppWebRouter.swift:38-55, 71-93` |
| F2 | A webview loaded from `tauri://localhost` therefore cannot call RielaApp directly: its `Origin` is `tauri://localhost` regardless of CORS. | F1 + Tauri asset protocol |
| F3 | `tauri-plugin-http` 2.5.9 strips caller `Host`/`Origin`/`Referer`/`sec-*` headers and *forces* `Origin` to the webview origin unless its `unsafe-headers` cargo feature is enabled. | crate `src/commands.rs:196-212, 284-312, 458-486`; `Cargo.toml:84` |
| F4 | Bare `riela serve` exposes `GET /`, `GET /healthz` (`{"service":"riela","status":"ok"}`), `POST /graphql`, `/note/*`; `/api/v1/bootstrap` and `/api/v1/instances` return `404 {"error":"unknown path"}`. It does not check `Host`. It prints a ready record `{"records":["endpoint=http://127.0.0.1:<port>"],"scope":"serve","status":"running"}` on stdout. | live probe of `.build/release/riela` 0.1.33 on port 18799; `Sources/RielaCLI/ServeHTTPCommand.swift:36-70`; `Sources/RielaServer/ServerContracts.swift:120-140` |
| F5 | Consequently the Instances and Run logs views (which call `/api/v1/instances[/…/executions]`) only have live data on the RielaApp host; under `riela serve` they render the existing `ErrorBanner`. | `web/src/views/InstancesView.tsx:54`, `web/src/views/LogsView.tsx:19-26` |
| F6 | RielaApp's listener is optional and **disabled by default**; it is started from the app menu (Open Web Config) and persisted in `web-server.json`. | `README.md`; `Sources/RielaAppSupport/RielaAppWebServerSettings.swift:6,13` |
| F7 | The only network seams in the SPA are the injectable constructor parameters of `RielaAPIClient` (`web/src/api.ts:26-31`, singleton `api`), `RielaConfigurationClient` (`web/src/config/client.ts:17-20`, singleton `configurationClient`) and `WorkflowRegistryClient` (`web/src/workflows/client.ts:9-12`, module-level `defaultClient`). All paths are relative (`/api/v1/...`, `/graphql`). No `EventSource`/`WebSocket`. | grep of `web/src` |
| F8 | `web/scripts/audit-source.ts` (part of `bun run lint`) fails on `globalThis.fetch =`, `window.fetch =`, `/fixture|mock/` imports and `/sampleResponse/` anywhere under `web/src` (tests included). | file contents |
| F9 | `App.tsx` already renders "Connecting to Riela…" while host discovery is loading and a "Could not connect / Try again" panel when it rejects. | `web/src/App.tsx:143-144` |
| F10 | Playwright starts `bun run dev --host 127.0.0.1 --port 4174` and mocks every API route; it needs no Riela server. | `web/playwright.config.ts` |
| F11 | Packaging scripts run `bun install --frozen-lockfile`, lint, typecheck, test, build and assert `web/dist/index.html`. | `scripts/build-riela-menu-bar-app.sh:57-67,117`; `scripts/build-homebrew-cask-release.sh:273,321` |
| F12 | Toolchain: no `cargo` on PATH, but mise has rust 1.92.0 (chilla's pin) installed; crates.io/npm reachable; `tauri` 2.11.5, `tauri-build` 2.6.3, `@tauri-apps/cli` 2.11.4, `@tauri-apps/api` 2.x available. Tauri app commands are permitted for the app's own windows with only `core:default` (chilla invokes its own commands with exactly that capability). | analysis toolchain probe; `chilla/src-tauri/capabilities/default.json`, `chilla/src/lib/theme.ts` |

## Origin strategy comparison (research brief §4)

| Strategy | Same-origin / F1 compliance | Frontend change | Works before server is up | Moving parts | Verdict |
| -------- | --------------------------- | --------------- | ------------------------- | ------------ | ------- |
| **A. Remote-URL window** — point the Tauri window at `http://127.0.0.1:<port>` | Perfect: the browser engine sends the right `Host`/`Origin`; CSRF flows unchanged | None | No: the window shows a webview error page until the server answers, so a pre-navigation splash window plus lifecycle logic in Rust is still required; Tauri IPC from a remote origin needs a `remote.urls` capability | Two windows/navigation choreography; the "app" is a thin browser with no bundled assets and no offline shell | Rejected: the connecting/not-running requirement forces a second UI anyway, and it depends on the RielaApp listener being started manually (F6) |
| **B. Bundled `web/dist` + transport executed in Rust** (chosen) | Achieved by performing HTTP in the Rust process, which sets `Host` from the URL (`127.0.0.1:<port>`) and stamps `Origin: http://127.0.0.1:<port>` on mutating requests | One thin boundary module + a lazy default-transport indirection in the three existing seams (F7) | Yes: the shell renders immediately from bundled assets; the transport awaits server readiness so `App.tsx` shows its existing connecting/error states (F9) | One Rust crate, three small commands, no plugins | **Chosen** |
| **C. Rust-side reverse proxy** — serve `web/dist` and forward `/api`,`/graphql` from an in-process loopback HTTP server, rewriting `Host`/`Origin` | Achieved | None | Yes (proxy answers 503 until upstream is ready) | An extra HTTP listener, header rewriting, CSRF pass-through, a second loopback port to manage, largest security surface | Rejected: most code and the only option that adds a new listening socket |

### Why B is implemented with a custom Tauri command instead of `tauri-plugin-http`

- F3: the plugin would need the `unsafe-headers` feature *and* every mutation would need
  the boundary module to know the server origin to set `Origin` itself. With a custom
  `riela_fetch` command the frontend keeps sending **relative paths** (zero origin concept
  in the SPA, maximally DRY) and Rust stamps `Origin` from the endpoint it discovered.
- No plugin permission scope to maintain in `capabilities/default.json`; `core:default`
  suffices (F12). The command accepts only relative paths and only talks to the single
  discovered loopback endpoint, so it cannot be used as an open proxy.
- The same Rust module already owns server discovery/spawning, so request routing and
  lifecycle share one state object.

## Scope

### In scope

- `web/src/transport.ts` — a lazily-resolved default transport used by the three seams.
- `web/src/desktop/host.ts` (+ `host.test.ts`) — the single, clearly named Tauri boundary
  module: runtime detection, `invoke`-backed transport, error mapping.
- Minimal edits to `web/src/api.ts`, `web/src/config/client.ts`,
  `web/src/workflows/client.ts` (default parameter → `requestThroughHost`) and
  `web/src/index.tsx` (install the desktop host before render when running under Tauri).
- `web/vite.config.ts` gated Tauri dev-server block; `web/package.json` deps and `tauri`
  script; updated `web/bun.lock`.
- New crate `src-tauri/` (Cargo.toml, build.rs, tauri.conf.json, capabilities/default.json,
  icons/, src/{main.rs, lib.rs, endpoint.rs, lifecycle.rs, commands.rs}) and a root
  `Cargo.toml` workspace + `Cargo.lock`.
- `mise.toml`: `rust = "1.92.0"` in `[tools]` and `desktop:*` tasks.
- `.gitignore` entries for Rust/Tauri build output.
- Documentation: this design, `impl-plans/active/tauri-dashboard-app.md`, README section.

### Out of scope

- Dashboard UI redesign, GraphQL/REST semantic changes, any Swift change under `Sources/`
  or `Packages/`, CI workflows, code signing/notarization, DMG/bundle packaging, auto-update,
  telemetry, remote access, TLS, CORS.
- Making Instances/Run logs work under bare `riela serve` (F5) — documented, not changed.

## Architecture

```
┌──────────────────────────── Tauri process (riela-dashboard) ────────────────────────────┐
│  WebView (tauri://localhost, bundled web/dist)                                          │
│    index.tsx ──installDesktopHost()──► desktop/host.ts ──setHostTransport()──► transport.ts │
│    api.ts / config/client.ts / workflows/client.ts ── requestThroughHost(path, init) ──┐ │
│                                                                                       │ │
│  IPC: invoke('riela_fetch', {path, method, headers, body})  ◄─────────────────────────┘ │
│        invoke('riela_server_status') / invoke('riela_server_retry')                     │
│                                                                                         │
│  Rust: commands.rs ──► lifecycle.rs (state machine, probing, spawn/stop riela serve)    │
│                    ──► reqwest (plain HTTP, loopback only)                              │
└───────────────────────────────┬─────────────────────────────────────────────────────────┘
                                │ http://127.0.0.1:19091 (RielaApp)  or  http://127.0.0.1:8787 (riela serve)
                        ┌───────▼────────┐                       ┌──────────────────────┐
                        │ RielaApp       │                       │ riela serve (managed │
                        │ web listener   │                       │ child or external)   │
                        └────────────────┘                       └──────────────────────┘
```

Browser build: `index.tsx` detects no Tauri runtime, skips installation, and every seam
keeps calling the global `fetch` through `requestThroughHost` — behaviour identical to today.

## Frontend design

### `web/src/transport.ts` (shared, host-agnostic)

```ts
export type HostTransport = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

const browserTransport: HostTransport = (input, init) => fetch(input, init)
let activeTransport: HostTransport = browserTransport

/** Installs the transport every client singleton routes through (called once, before render). */
export function setHostTransport(transport: HostTransport): void
/** Restores the browser transport (tests). */
export function resetHostTransport(): void
/** Late-bound delegate: default parameter of every client, so singletons pick up the installed transport. */
export const requestThroughHost: HostTransport = (input, init) => activeTransport(input, init)
```

- Not a fetch monkey-patch (F8 compliant); the seams stay injectable and the existing
  tests that pass explicit transports are untouched.
- `api.ts`: `transport = requestThroughHost`; `config/client.ts`: `request = requestThroughHost`;
  `workflows/client.ts`: `defaultClient` built with `request: requestThroughHost`.

### `web/src/desktop/host.ts` (the only Tauri-aware frontend code)

```ts
export interface DesktopInvoke { <T>(command: string, args?: Record<string, unknown>): Promise<T> }

export interface DesktopFetchRequest { path: string; method: string; headers: [string, string][]; body: string | null }
export interface DesktopFetchResponse { status: number; headers: [string, string][]; body: string }
export type DesktopServerState = 'discovering' | 'starting' | 'connected' | 'failed'
export interface DesktopServerStatus {
  state: DesktopServerState
  endpoint?: { origin: string; kind: 'riela-app' | 'cli-serve'; managed: boolean }
  detail?: string
}
export interface DesktopInvokeError { code: 'invalid_request' | 'server_unavailable' | 'request_failed'; message: string }

/** True only inside a Tauri webview (`window.__TAURI_INTERNALS__` present). Pure; testable with a fake global. */
export function isDesktopRuntime(globalObject?: unknown): boolean
/** Converts RequestInfo/RequestInit into the IPC payload. Rejects absolute URLs. Normalises Headers | [][] | Record. */
export function toDesktopFetchRequest(input: RequestInfo | URL, init?: RequestInit): DesktopFetchRequest
/** Rebuilds a standard Response from the IPC payload. */
export function fromDesktopFetchResponse(response: DesktopFetchResponse): Response
/** Wraps invoke into a HostTransport. Retries once after `riela_server_retry` when `server_unavailable`. */
export function createDesktopTransport(invoke: DesktopInvoke): HostTransport
/** Entry point for index.tsx: dynamic-imports @tauri-apps/api/core and installs the transport. Returns false in the browser. */
export async function installDesktopHost(): Promise<boolean>
/** Error surfaced to App.tsx's "Could not connect" panel; `name` is 'RielaDesktopHostError'. */
export class DesktopHostError extends Error { constructor(readonly code: string, message: string) }
```

- `@tauri-apps/api/core` is imported **only** inside `installDesktopHost()` via dynamic
  `import()`, so the browser bundle never evaluates Tauri internals; Vite emits it as a
  lazily-loaded chunk under `web/dist/assets/` (index.html and `assets/` layout unchanged).
- Body handling: the SPA only sends `string` JSON bodies; any other `BodyInit` is rejected
  with `invalid_request` (kept deliberately narrow).
- `credentials`, `signal` and `mode` are ignored by the desktop transport; abort support is
  not required by the polling layer beyond ignoring stale results, which it already does.
- Error mapping: an `invoke` rejection `{code, message}` → `DesktopHostError`; `String(error)`
  therefore reads `RielaDesktopHostError: <message>` inside the existing panel (F9).

### `web/src/index.tsx`

```ts
async function main() {
  if (isDesktopRuntime()) {
    try { await installDesktopHost() } catch (error) { console.error('Riela desktop host unavailable, using browser fetch', error) }
  }
  render(() => <App />, root)
}
void main()
```

### `web/vite.config.ts`

```ts
const tauriHost = process.env.TAURI_DEV_HOST
const isTauri = Boolean(process.env.TAURI_ENV_PLATFORM || tauriHost)
export default defineConfig({
  plugins: [solid(), tailwindcss()],
  build: { target: 'es2022', sourcemap: true },
  ...(isTauri ? {
    clearScreen: false,
    server: { port: 1420, strictPort: true, host: tauriHost || false,
              hmr: tauriHost ? { protocol: 'ws', host: tauriHost, port: 1421 } : undefined,
              watch: { ignored: ['**/src-tauri/**'] } },
  } : {}),
})
```

The Tauri CLI exports `TAURI_ENV_*` to `beforeDevCommand`/`beforeBuildCommand`, so the block is
active only under `tauri dev`/`tauri build`; `bun run build`, `bun run dev` and the Playwright
`--port 4174` server (F10) are unaffected. `web/dist` output stays byte-compatible in path
and shape (F11).

### `web/package.json`

- `dependencies`: `@tauri-apps/api ^2`
- `devDependencies`: `@tauri-apps/cli ^2`
- `scripts.tauri`: `"tauri"`
- `web/bun.lock` regenerated and committed (frozen-lockfile in F11).

## Rust crate design (`src-tauri/`)

### Layout and manifests

```
Cargo.toml                      # [workspace] members = ["src-tauri"], resolver = "2"
src-tauri/
  Cargo.toml                    # package riela-dashboard, [lib] name = "riela_dashboard_lib",
                                #   crate-type = ["staticlib", "cdylib", "rlib"]
  build.rs                      # fn main() { tauri_build::build() }
  tauri.conf.json
  capabilities/default.json     # {"identifier":"default","windows":["main"],"permissions":["core:default"]}
  icons/                        # generated with `bun run tauri icon ../web/public/favicon.svg` (or a rendered PNG); at least icon.png
  src/main.rs                   # riela_dashboard_lib::run()
  src/lib.rs                    # tauri::Builder, .manage(ServerState), invoke_handler, RunEvent::Exit hook
  src/endpoint.rs               # pure types + validation + binary resolution (unit-tested)
  src/lifecycle.rs              # state machine, probing, spawning, shutdown
  src/commands.rs               # riela_fetch, riela_server_status, riela_server_retry
```

Dependencies: `tauri = { version = "2", features = [] }`, `tauri-build = "2"` (build),
`serde` (derive), `serde_json`, `reqwest = { version = "0.12", default-features = false }`
(plain HTTP only — no TLS backend is compiled), `tokio = { version = "1", features = ["time", "sync"] }`,
`thiserror = "2"`, `libc = "0.2"` (SIGTERM on unix). No Tauri plugins.

`tauri.conf.json` (shape follows chilla/ign-template; paths adapted to the `web/` layout):

```json
{
  "$schema": "https://schema.tauri.app/config/2",
  "productName": "Riela Dashboard",
  "version": "0.1.0",
  "identifier": "com.tacogips.riela.dashboard",
  "build": {
    "beforeDevCommand": { "script": "bun run dev", "cwd": "web", "wait": false },
    "devUrl": "http://localhost:1420",
    "beforeBuildCommand": { "script": "bun run build", "cwd": "web" },
    "frontendDist": "../web/dist"
  },
  "app": {
    "windows": [{ "label": "main", "title": "Riela Dashboard", "width": 1280, "height": 820, "minWidth": 960, "minHeight": 640 }],
    "security": {
      "csp": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ipc: http://ipc.localhost"
    }
  },
  "bundle": { "active": false, "icon": ["icons/icon.png"] }
}
```

- `frontendDist` is relative to `src-tauri/`; the `cwd` of the before-commands is relative to
  the Tauri app root (repository root). The implementation must confirm both resolutions on
  the first `tauri dev`/`tauri build` and adjust `cwd` (`web` vs `../web`) if the CLI resolves
  it differently — this is a verification checkpoint, not a design freedom.
- `connect-src` deliberately omits `http://127.0.0.1:*`: all HTTP leaves through Rust.
- `bundle.active=false` matches both references; packaging is out of scope.

### `endpoint.rs` (pure, unit-tested)

```rust
pub const DEFAULT_APP_PORT: u16 = 19_091;   // RielaApp listener default
pub const DEFAULT_SERVE_PORT: u16 = 8_787;  // riela serve default

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EndpointKind { RielaApp, CliServe }

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Endpoint { pub origin: String /* http://127.0.0.1:<port> */, pub port: u16, pub kind: EndpointKind, pub managed: bool }

/// Parses RIELA_DESKTOP_SERVER_URL. Accepts only http:// with host 127.0.0.1, localhost or [::1];
/// canonicalises to http://127.0.0.1:<port> so RielaApp's exact Host/Origin check (F1) passes.
pub fn parse_loopback_origin(raw: &str) -> Result<(String, u16), EndpointError>

#[derive(Clone, Debug, Default)]
pub struct BinaryLookup { pub env_override: Option<PathBuf>, pub path_entries: Vec<PathBuf>, pub fallback_candidates: Vec<PathBuf> }
/// Order: RIELA_DESKTOP_RIELA_BIN → `riela` on PATH → <cwd>/.build/release/riela, <cwd>/.build/debug/riela,
/// /opt/homebrew/bin/riela, /usr/local/bin/riela. `exists` is injected for tests.
pub fn resolve_riela_binary(lookup: &BinaryLookup, exists: impl Fn(&Path) -> bool) -> Option<PathBuf>

/// Path guard for riela_fetch: must start with '/', must not start with '//', no scheme, no '..' segments.
pub fn validate_relative_path(path: &str) -> Result<(), EndpointError>

/// Header policy: drop hop-by-hop / forbidden headers (host, origin, connection, content-length,
/// transfer-encoding, cookie, referer, sec-*), keep the rest (incl. X-Riela-CSRF, X-Riela-Profile,
/// Content-Type, Accept); stamp Origin for every method except GET/HEAD/OPTIONS.
pub fn outbound_headers(method: &str, endpoint_origin: &str, incoming: &[(String, String)]) -> Vec<(String, String)>
```

### `lifecycle.rs` — state machine

```
                ┌──────────────┐  probe 19091 /api/v1/bootstrap → 200        ┌───────────┐
 start / retry ─► Discovering  ├──────────────────────────────────────────────► Connected │
                └──────┬───────┘  probe 8787 /healthz → 200 ─────────────────►│ {endpoint}│
                       │ nothing listening                                    └─────┬─────┘
                       ▼                                                            │ request-level connection refused
                ┌──────────────┐ spawn `riela serve --host 127.0.0.1 --port 8787`   │ (managed child died / external stopped)
                │  Starting    ├─ /healthz 200 within 20 s ─► Connected {managed}    ▼
                │ {child pid}  ├─ timeout / spawn error ────► Failed {detail}  ◄── Failed {detail}
                └──────────────┘                                        ▲
                                          no binary / port busy by non-Riela service / RIELA_DESKTOP_SERVER_URL invalid
```

```rust
pub enum ServerState { Discovering, Starting { pid: u32 }, Connected(Endpoint), Failed { detail: String } }

pub struct ServerLifecycle { state: Mutex<ServerState>, changed: tokio::sync::Notify, child: Mutex<Option<std::process::Child>>, config: LifecycleConfig, prober: Box<dyn Prober> }

pub struct LifecycleConfig { pub explicit_origin: Option<(String, u16)>, pub app_port: u16, pub serve_port: u16, pub binary: BinaryLookup, pub startup_timeout: Duration }

#[async_trait-free] pub trait Prober: Send + Sync { async fn get_status(&self, url: &str) -> Result<u16, String>; }  // injected for tests

impl ServerLifecycle {
  pub async fn discover(&self)                      // Discovering → Connected | Starting → Connected | Failed
  pub async fn wait_ready(&self, max: Duration) -> Result<Endpoint, LifecycleError>  // used by riela_fetch
  pub fn status(&self) -> ServerStatus
  pub fn mark_unreachable(&self, detail: String)    // Connected → Failed after a connection error
  pub fn shutdown(&self)                            // SIGTERM managed child, wait ≤3 s, then kill
}
```

Rules:

- Probe order encodes F5/F6: a RielaApp listener wins because it is the only host with
  Instances/Run-logs data; `riela serve` second; spawning last. `RIELA_DESKTOP_SERVER_URL`
  bypasses probing (kind decided by whether `/api/v1/bootstrap` answers 200 → `riela-app`,
  404 → `cli-serve`).
- A port that answers but is neither RielaApp (bootstrap 200) nor Riela (healthz 200 with
  `service == "riela"`) is treated as "busy by another service" → `Failed` with an actionable
  detail; the app never spawns onto a busy port.
- The managed child is started with `Stdio::null()` stdin/stdout and inherited stderr, in the
  process's current working directory; readiness is detected by polling `/healthz` every
  250 ms (the stdout ready record in F4 is not parsed — polling is host-agnostic and also
  covers externally started servers).
- Only a child this process spawned is ever stopped (`managed == true`). Externally started
  RielaApp/`riela serve` processes are left untouched.
- `shutdown()` runs from `RunEvent::Exit` in `lib.rs` (and `ExitRequested` to be safe), so
  closing the window or quitting the app terminates the managed child. Unix: `SIGTERM` via
  `libc::kill`, wait up to 3 s, then `Child::kill()`.
- All origins are `http://127.0.0.1:<port>` — never `localhost` (F1 requires the literal IP).

### `commands.rs`

```rust
#[derive(serde::Deserialize)] pub struct FetchRequest { pub path: String, pub method: String, pub headers: Vec<(String, String)>, pub body: Option<String> }
#[derive(serde::Serialize)]  pub struct FetchResponse { pub status: u16, pub headers: Vec<(String, String)>, pub body: String }
#[derive(serde::Serialize)]  pub struct CommandError { pub code: &'static str /* invalid_request | server_unavailable | request_failed */, pub message: String }
#[derive(serde::Serialize)]  pub struct ServerStatus { pub state: &'static str, pub endpoint: Option<Endpoint>, pub detail: Option<String> }

#[tauri::command] pub async fn riela_fetch(state: tauri::State<'_, Arc<ServerLifecycle>>, request: FetchRequest) -> Result<FetchResponse, CommandError>
#[tauri::command] pub async fn riela_server_status(state: …) -> Result<ServerStatus, CommandError>
#[tauri::command] pub async fn riela_server_retry(state: …) -> Result<ServerStatus, CommandError>
```

`riela_fetch` flow: `validate_relative_path` → `wait_ready(30 s)` (so the SPA shows
"Connecting to Riela…" while discovery/spawn is in flight, F9) → build
`reqwest::Request` for `endpoint.origin + path` with `outbound_headers` → send with a 30 s
timeout → on a connection error call `mark_unreachable` and return `server_unavailable`;
otherwise return status + headers + body text verbatim (the SPA's `request()` parses JSON and
`APIError`s itself, so 4xx/5xx are **not** command errors). Response headers are passed through
except `set-cookie`.

Security properties: loopback-only endpoints (validated), relative paths only, header
allow-policy, no new listening socket, no telemetry, no secrets; the CSRF token still
originates from `GET /api/v1/bootstrap` and is forwarded unchanged by the SPA.

## Data flow (request)

1. `InstancesView` → `api.get('/api/v1/instances')` → `RielaAPIClient.request` →
   `requestThroughHost('/api/v1/instances', {credentials:'same-origin', signal})`.
2. Desktop: `createDesktopTransport` → `toDesktopFetchRequest` → `invoke('riela_fetch', …)`.
3. Rust: path guard → `wait_ready` → `GET http://127.0.0.1:19091/api/v1/instances` with
   `Host` (automatic) and forwarded headers → response → `FetchResponse`.
4. Boundary: `fromDesktopFetchResponse` → `Response` → existing `request()` JSON/`APIError`
   handling → `createPollingResource` → view.
5. Mutations add `Content-Type: application/json` + `X-Riela-CSRF` in the SPA (unchanged);
   Rust stamps `Origin: http://127.0.0.1:19091` → passes `securityRejection` (F1).
6. Browser: step 2 is native `fetch`; nothing else differs.

## State transitions visible to the user

| Situation | Rust state | What the SPA shows (no new UI) |
| --------- | ---------- | ------------------------------ |
| App starts, RielaApp listener running | Discovering → Connected(riela-app) | "Connecting to Riela…" for < 1 s, then full dashboard (Instances/Run logs live) |
| Only `riela serve` running | Connected(cli-serve) | Dashboard in `cli-serve` mode (Settings/Ops hidden, as in the browser today; Instances/Logs show their existing error banners, F5) |
| Nothing running, `riela` binary found | Starting → Connected(cli-serve, managed) | "Connecting to Riela…" during spawn (≤ 20 s), then `cli-serve` dashboard |
| Nothing running, no binary | Failed | "Could not connect — RielaDesktopHostError: No Riela server on 127.0.0.1:19091 or 127.0.0.1:8787 and no `riela` binary was found (set RIELA_DESKTOP_RIELA_BIN or start RielaApp's web listener). Try again" |
| Server dies later | Connected → Failed | Next poll fails → "Could not connect …"; Try again → `riela_server_retry` re-discovers/re-spawns |
| `RIELA_DESKTOP_SERVER_URL` invalid / non-loopback | Failed | Error text names the variable |

## Configuration surface (documented in README)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `RIELA_DESKTOP_SERVER_URL` | unset | Explicit loopback origin (`http://127.0.0.1:<port>`); skips discovery |
| `RIELA_DESKTOP_RIELA_BIN` | unset | Path to the `riela` binary used to spawn `riela serve` |

Ports 19091/8787 are fixed defaults mirroring RielaApp and `riela serve`; a non-default
RielaApp port is reached via `RIELA_DESKTOP_SERVER_URL`.

## Build, tasks and repository plumbing

- `mise.toml [tools]`: add `rust = "1.92.0"` (already installed locally; chilla's pin).
- Tasks (app:* style, `CARGO_TERM_QUIET=true`):
  - `desktop:dev` — `cd web && bun install && bun run tauri dev`
  - `desktop:build` — `cd web && bun install && bun run tauri build` (debug variant via `-- --debug`); binary at `target/{debug,release}/riela-dashboard`
  - `desktop:run` — run the built binary, building first when missing (mirrors `app:run`)
  - `desktop:lint` — `bun --cwd web run build` (dist must exist for `generate_context!`) then `cargo fmt --manifest-path src-tauri/Cargo.toml -- --check`, `cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings`, `cargo check --manifest-path src-tauri/Cargo.toml`
  - `desktop:test` — `cargo test --manifest-path src-tauri/Cargo.toml`
- `.gitignore`: `/target/`, `/src-tauri/target/`, `/src-tauri/gen/schemas/`, `**/*.rs.bk`.
- `Cargo.lock` is committed (application crate).
- README: new "Dashboard: browser and desktop" section (both hosts, discovery order,
  env variables, `mise run desktop:*`, the F5 caveat).

## Compatibility and regression guarantees

- Browser bundle: same entry, same routes, same fetch semantics; `web/dist/index.html` +
  `assets/` produced at the same path (one additional lazy chunk). `discoverHost` 404 →
  `cli-serve` and `CLI_SERVE_HIDDEN_VIEWS` untouched.
- Existing unit tests keep passing (they inject explicit transports). Playwright unaffected
  (F10; Vite block gated).
- Swift side: zero changes; `swift build` is run purely as evidence.
- Packaging scripts: only `web/bun.lock` changes matter and are committed (F11).

## Test strategy

TypeScript (`bun test src`):

- `web/src/transport.test.ts`: `requestThroughHost` delegates to the installed transport at
  call time (install after a client was constructed); `resetHostTransport` restores.
- `web/src/desktop/host.test.ts`: `isDesktopRuntime` true/false by `__TAURI_INTERNALS__`;
  `toDesktopFetchRequest` normalises `Headers`/array/record, defaults method GET, rejects
  absolute URLs and non-string bodies; `fromDesktopFetchResponse` preserves status/headers/body
  and yields a `Response` whose `.text()`/`.json()`/`.ok` behave; `createDesktopTransport`
  passes payloads to `invoke`, maps `{code,message}` rejections to `DesktopHostError`,
  retries exactly once after `riela_server_retry` on `server_unavailable`, and does not retry
  on `request_failed`.

Rust (`cargo test`):

- `endpoint.rs`: loopback parsing/canonicalisation and rejection of non-loopback hosts;
  binary resolution order with injected existence predicate; relative-path guard; header
  policy (Origin stamped for POST/PUT/DELETE only, forbidden headers dropped, CSRF kept).
- `lifecycle.rs` with a fake `Prober`: RielaApp preferred over serve; serve accepted; busy
  non-Riela port → Failed without spawn; no binary → Failed with actionable detail;
  `mark_unreachable` → Failed; `wait_ready` returns after transition.

Evidence runs (pasted output, per verification hint):

1. `cd web && bun install && bun run lint && bun run typecheck && bun test src && bun run build && test -s dist/index.html`.
2. `.build/release/riela serve --port 8787 --web-root web/dist` + curl `/`, an asset,
   `/healthz`, `/api/v1/bootstrap` (expect 404) → stop.
3. `mise run desktop:lint` (fmt --check, clippy -D warnings, cargo check) and, time
   permitting, `bun run tauri build --debug`.
4. `swift build`.
5. `cd web && bun run test:e2e`.
6. Desktop live check: launch `mise run desktop:dev` (a) with RielaApp's web listener started
   from its menu (Open Web Config) → Instances/Run logs live; (b) with nothing running →
   observe spawn of `riela serve` and the `cli-serve` dashboard; (c) with no binary
   (`RIELA_DESKTOP_RIELA_BIN=/nonexistent`, PATH stripped) → "Could not connect" panel. If (a)
   cannot be driven in the run environment, state that explicitly and provide the Rust
   header-policy tests plus a `riela_fetch`-equivalent curl against RielaApp as evidence.

## Rollout

Additive feature on `feat/tauri-dashboard-app`; no runtime behaviour change for browser users
or for the Swift binaries. The desktop binary is developer-built (`mise run desktop:*`); no
signing, notarization or distribution in this work package. Committed with a clean tree, no PR.

## Edge cases

- Non-default RielaApp port → use `RIELA_DESKTOP_SERVER_URL`; probe otherwise falls to 8787/spawn.
- `localhost` given in `RIELA_DESKTOP_SERVER_URL` → canonicalised to `127.0.0.1` (F1).
- Port 8787 occupied by an unrelated service → Failed with "port busy" detail; never spawn.
- Managed child exits immediately (e.g. usage error) → startup timeout → Failed with the exit
  status in the detail.
- RielaApp listener stopped from its menu while the desktop app is open → Failed → Try again.
- App quit while `Starting` → `shutdown()` still terminates the child.
- Response without JSON body (e.g. 403 `invalid_origin` plain text) → passed through; the SPA's
  existing `request()` produces `APIError(request_failed)` exactly as in the browser.
- Second desktop instance → discovers the first instance's managed `riela serve` on 8787 as an
  external server (managed=false) and never kills it.
- Tauri `beforeDevCommand` cwd resolution differs from expectation → covered by the explicit
  verification checkpoint; both `web` and `../web` forms are one-line fixes.

## Design review record

- Considered `tauri-plugin-http` first (brief's suggestion); rejected after reading the crate:
  it forces `Origin: tauri://localhost` unless `unsafe-headers` is enabled, and would push the
  server-origin concept into the SPA. The custom command keeps the SPA origin-free.
- Considered a `HostStatus` SolidJS component for richer desktop status; rejected because the
  shared shell already renders connecting/error states (F9) and DRY forbids desktop-only UI
  beyond the boundary module. The Rust `detail` string carries the actionable message instead.
- Considered parsing the `riela serve` stdout ready record; rejected in favour of `/healthz`
  polling, which also covers externally started servers and RielaApp.
