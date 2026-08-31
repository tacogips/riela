# Riela Dashboard Desktop App (Tauri v2) — Implementation Plan

**Status**: Ready
**Feature ID**: `tauri-dashboard-app`
**Workflow mode**: `fable-and-improve-opus` (ONE feature, ONE work package, no fan-out)
**Design reference**: `design-docs/tauri-dashboard-app.md`
**Research brief**: `design-docs/research/tauri-dashboard-app-brief.md`
**Branch**: `feat/tauri-dashboard-app` (worktree `/Users/taco/gits/tacogips/riela-worktrees/tauri-dashboard-app`)
**Created**: 2026-08-31
**Last updated**: 2026-08-31

## 1. Objective and Boundaries

Ship the existing `web/` SolidJS dashboard additionally as a Tauri v2 desktop app
(`src-tauri/`, product "Riela Dashboard") that performs every HTTP request in Rust through a
custom `riela_fetch` command (so RielaApp's exact `Host`/`Origin`/`X-Riela-CSRF` rules pass),
discovers or spawns a local Riela server, and reuses the SPA's existing connecting/error
states — while the browser surface, `web/dist` shape, Swift build and Playwright suite stay
exactly as today. The design decisions are final; do not re-open them.

### Included

- `web/src/transport.ts` (host-agnostic late-bound transport) and the single Tauri boundary
  module `web/src/desktop/host.ts` with unit tests.
- Default-parameter wiring in `web/src/api.ts`, `web/src/config/client.ts`,
  `web/src/workflows/client.ts`; host installation in `web/src/index.tsx`.
- `web/vite.config.ts` Tauri-gated dev-server block; `web/package.json` deps/script;
  regenerated `web/bun.lock`.
- New crate `src-tauri/` + root `Cargo.toml` workspace + committed `Cargo.lock`.
- `mise.toml` (`rust` pin, `desktop:*` tasks), `.gitignore` entries.
- README section, this plan, the design doc — all committed on the branch.

### Excluded

- Any change under `Sources/`, `Packages/`, `.github/`, `scripts/`; UI redesign; GraphQL/REST
  semantics; signing/notarization/DMG packaging; auto-update; telemetry; CORS; non-loopback
  binding; making Instances/Run logs work under bare `riela serve` (documented instead).

### Applicable prior knowledge

Knowledge-base recall for `tauri` returned no entries. Repository-derived gotchas that
replace it (from the analysis):

- `web/scripts/audit-source.ts` (inside `bun run lint`) fails on `globalThis.fetch =`,
  `window.fetch =`, any import path matching `/fixture|mock/i`, and `/sampleResponse/i`
  anywhere under `web/src` **including tests** — name fakes `fake*`/`stub*`, never `mock*`.
- `tauri::generate_context!` embeds `frontendDist`; `cargo check`/`clippy` fail if
  `web/dist/index.html` is missing. Always build web first.
- Playwright starts `bun run dev --host 127.0.0.1 --port 4174`; an unguarded Vite `server`
  block breaks it.
- Packaging scripts run `bun install --frozen-lockfile` — commit `web/bun.lock`.
- `cargo` is not on PATH; use `mise x -- cargo …` or `mise run desktop:*` after pinning rust.
- RielaApp's listener is off by default and started from its menu (Open Web Config).

## 2. Modules

### 2.1 Frontend — shared transport seam

#### `web/src/transport.ts` (new)

**Status**: NOT_STARTED

```ts
export type HostTransport = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>
export function setHostTransport(transport: HostTransport): void
export function resetHostTransport(): void
export const requestThroughHost: HostTransport   // delegates to the active transport at call time
```

Default active transport: `(input, init) => fetch(input, init)`.

**Checklist**:
- [ ] Implement module (no top-level side effects, no Tauri imports).
- [ ] `web/src/transport.test.ts`: (a) default delegates to global-fetch-equivalent behaviour by
      injecting a transport and asserting late binding — construct `new RielaAPIClient()`
      *before* `setHostTransport(fake)`, call `bootstrap()`, assert the fake was hit;
      (b) `resetHostTransport()` restores; use `try/finally` to reset in every test.

#### `web/src/api.ts`, `web/src/config/client.ts`, `web/src/workflows/client.ts` (edit)

**Status**: NOT_STARTED

- `api.ts:29-30`: default `transport = requestThroughHost` (import from `./transport`).
- `config/client.ts:18-19`: default `request = requestThroughHost`.
- `workflows/client.ts:187-190`: `defaultClient` uses `request: requestThroughHost`.
- No other changes; explicit-transport tests remain valid.

**Checklist**:
- [ ] Three one-line default swaps + imports.
- [ ] `bun test src` still green (api.test.ts, config/client.test.ts, workflows/client.test.ts).

### 2.2 Frontend — Tauri boundary module

#### `web/src/desktop/host.ts` (new; the ONLY Tauri-aware frontend file)

**Status**: NOT_STARTED

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
export class DesktopHostError extends Error { readonly name = 'RielaDesktopHostError'; constructor(readonly code: string, message: string) }
export function isDesktopRuntime(globalObject: unknown = globalThis): boolean   // `__TAURI_INTERNALS__` in object
export function toDesktopFetchRequest(input: RequestInfo | URL, init?: RequestInit): DesktopFetchRequest
export function fromDesktopFetchResponse(response: DesktopFetchResponse): Response
export function createDesktopTransport(invoke: DesktopInvoke): HostTransport
export async function installDesktopHost(): Promise<boolean>
```

Rules:
- `toDesktopFetchRequest`: accept `string` paths starting with `/` (not `//`), a `URL`/absolute
  string only if it is same-origin-relative is NOT supported → throw
  `DesktopHostError('invalid_request', …)` for absolute URLs and `Request` objects; method
  defaults to `GET` (upper-cased); headers normalised from `Headers`, `[string,string][]`, or
  record; body must be `string | null | undefined`, otherwise `invalid_request`.
- `fromDesktopFetchResponse`: `new Response(body, { status, headers })`; for status 204/205/304
  pass `null` body (Response constructor throws otherwise).
- `createDesktopTransport(invoke)`: `invoke<DesktopFetchResponse>('riela_fetch', { request })`;
  on rejection with `{ code: 'server_unavailable' }` call
  `invoke('riela_server_retry')` once, then re-issue once; any other rejection or second
  failure → throw `DesktopHostError(code ?? 'request_failed', message ?? String(error))`.
- `installDesktopHost()`: `if (!isDesktopRuntime()) return false;`
  `const { invoke } = await import('@tauri-apps/api/core'); setHostTransport(createDesktopTransport(invoke)); return true`.
  This is the only place `@tauri-apps/api` is imported (dynamic import → lazy chunk).

**Checklist**:
- [ ] Implement module.
- [ ] `web/src/desktop/host.test.ts` (bun:test, fakes named `fakeInvoke`):
      runtime detection true/false; header normalisation for `Headers`/array/record; default
      method GET; absolute URL / `Request` / non-string body → `invalid_request`; 204 response
      rebuilds without throwing; `.ok`, `.status`, `.text()`, `.json()` behave; error mapping;
      exactly one retry after `riela_server_retry` on `server_unavailable`; no retry on
      `request_failed`; `createDesktopTransport` forwards `X-Riela-CSRF` and JSON body verbatim.

#### `web/src/index.tsx` (edit)

**Status**: NOT_STARTED

```tsx
async function main() {
  if (isDesktopRuntime()) {
    try { await installDesktopHost() } catch (error) { console.error('Riela desktop host unavailable; falling back to browser fetch', error) }
  }
  render(() => <App />, root)
}
void main()
```

**Checklist**:
- [ ] Edit; keep the root-element guard and `./styles.css` import.

### 2.3 Frontend — build configuration

#### `web/vite.config.ts` (edit)

**Status**: NOT_STARTED

```ts
const tauriDevHost = process.env.TAURI_DEV_HOST
const isTauri = Boolean(process.env.TAURI_ENV_PLATFORM || tauriDevHost)
export default defineConfig({
  plugins: [solid(), tailwindcss()],
  build: { target: 'es2022', sourcemap: true },
  ...(isTauri ? {
    clearScreen: false,
    server: {
      port: 1420, strictPort: true, host: tauriDevHost || false,
      hmr: tauriDevHost ? { protocol: 'ws', host: tauriDevHost, port: 1421 } : undefined,
      watch: { ignored: ['**/src-tauri/**'] },
    },
  } : {}),
})
```

`process` typing: `@types/bun` is already a devDependency and `tsconfig.include` covers
`vite.config.ts`, so `process.env` type-checks (verify with `bun run typecheck`).

**Checklist**:
- [ ] Edit; `bun run build` output unchanged in path/shape (`dist/index.html`, `dist/assets/`).

#### `web/package.json` + `web/bun.lock` (edit)

**Status**: NOT_STARTED

- `scripts.tauri = "tauri"`.
- `dependencies["@tauri-apps/api"] = "^2"`.
- `devDependencies["@tauri-apps/cli"] = "^2"`.
- Run `bun install` in `web/` and commit the updated `bun.lock`.

**Checklist**:
- [ ] Edit + install + lockfile committed; `bun install --frozen-lockfile` succeeds afterwards.

### 2.4 Rust crate

#### `Cargo.toml` (root, new)

```toml
[workspace]
members = ["src-tauri"]
resolver = "2"
```

#### `src-tauri/Cargo.toml` (new)

```toml
[package]
name = "riela-dashboard"
version = "0.1.0"
description = "Riela dashboard desktop shell"
edition = "2021"
license = "MIT"

[lib]
name = "riela_dashboard_lib"
crate-type = ["staticlib", "cdylib", "rlib"]

[build-dependencies]
tauri-build = { version = "2", features = [] }

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tauri = { version = "2", features = [] }
reqwest = { version = "0.12", default-features = false }
tokio = { version = "1", features = ["time", "sync", "macros"] }
thiserror = "2"

[target.'cfg(unix)'.dependencies]
libc = "0.2"
```

#### `src-tauri/build.rs` (new)

```rust
fn main() {
    tauri_build::build();
}
```

#### `src-tauri/tauri.conf.json` (new)

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
    "windows": [
      { "label": "main", "title": "Riela Dashboard", "width": 1280, "height": 820, "minWidth": 960, "minHeight": 640 }
    ],
    "security": {
      "csp": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ipc: http://ipc.localhost"
    }
  },
  "bundle": { "active": false, "icon": ["icons/icon.png"] }
}
```

Verification checkpoint (T12): the Tauri CLI resolves `cwd` relative to the *app root* (the
directory containing `src-tauri`'s parent, i.e. the repo root when invoked as
`bun --cwd web run tauri …`). If the first `tauri build --debug` runs `bun run dev`/`build`
in the wrong directory, switch `cwd` to `../web` — one-line fix, no design change.

#### `src-tauri/capabilities/default.json` (new)

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "Default permissions for the Riela Dashboard main window",
  "windows": ["main"],
  "permissions": ["core:default"]
}
```

#### `src-tauri/icons/icon.png` (new)

Generate from `web/public/favicon.svg`: `cd web && bun run tauri icon ../web/public/favicon.svg -o ../src-tauri/icons`
(if the SVG is rejected, rasterise a 1024×1024 PNG under `tmp/` first with `sips`/`qlmanage`
or `bun x @resvg/resvg-js`). Commit only `icon.png` (+ the generated set if produced; they are
small). Do not commit anything else under `src-tauri/gen/`.

#### `src-tauri/src/endpoint.rs` (new, pure, unit-tested)

**Status**: NOT_STARTED

```rust
pub const DEFAULT_APP_PORT: u16 = 19_091;
pub const DEFAULT_SERVE_PORT: u16 = 8_787;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EndpointKind { RielaApp, CliServe }

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Endpoint { pub origin: String, pub port: u16, pub kind: EndpointKind, pub managed: bool }

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EndpointError {
    #[error("{0}")] InvalidOrigin(String),
    #[error("{0}")] InvalidPath(String),
}

pub fn loopback_origin(port: u16) -> String                       // "http://127.0.0.1:{port}"
pub fn parse_loopback_origin(raw: &str) -> Result<u16, EndpointError>
    // accepts http://127.0.0.1[:port] | http://localhost[:port] | http://[::1][:port], optional trailing '/'
    // default port 80 rejected? -> require explicit port; anything else (https, other hosts, paths) => InvalidOrigin
pub fn validate_relative_path(path: &str) -> Result<(), EndpointError>
    // must start with '/', not '//', no "://", no "/../" or "/.." segments, no whitespace/control chars
pub fn outbound_headers(method: &str, endpoint_origin: &str, incoming: &[(String, String)]) -> Vec<(String, String)>
    // drop (case-insensitive): host, origin, referer, cookie, set-cookie, connection, content-length,
    // transfer-encoding, te, trailer, upgrade, keep-alive, proxy-*, sec-*; keep everything else;
    // if method is not GET/HEAD/OPTIONS push ("Origin", endpoint_origin)

#[derive(Clone, Debug, Default)]
pub struct BinaryLookup { pub env_override: Option<PathBuf>, pub path_entries: Vec<PathBuf>, pub fallback_candidates: Vec<PathBuf> }
impl BinaryLookup {
    pub fn from_environment(cwd: &Path, env_override: Option<OsString>, path_var: Option<OsString>) -> Self
        // fallbacks: cwd/.build/release/riela, cwd/.build/debug/riela, /opt/homebrew/bin/riela, /usr/local/bin/riela
}
pub fn resolve_riela_binary(lookup: &BinaryLookup, exists: impl Fn(&Path) -> bool) -> Option<PathBuf>
    // env_override (if exists) → each path_entries/riela → fallback_candidates
```

**Checklist**:
- [ ] Implement.
- [ ] `#[cfg(test)] mod tests`: origin parsing (127.0.0.1, localhost, [::1] → canonical port;
      reject https/other hosts/paths/missing port), path guard (accept `/api/v1/x?y=1`,
      reject `//evil`, `http://x`, `/a/../b`, `api`), header policy (Origin only for
      POST/PUT/DELETE/PATCH; host/origin/cookie/sec-fetch-mode dropped; `X-Riela-CSRF`,
      `X-Riela-Profile`, `Content-Type` kept), binary resolution order with an injected
      `exists` closure.

#### `src-tauri/src/lifecycle.rs` (new)

**Status**: NOT_STARTED

```rust
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServerState { Discovering, Starting { pid: u32 }, Connected(Endpoint), Failed { detail: String } }

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeResult { Status(u16, String /* body */), Unreachable }

pub trait Prober: Send + Sync + 'static {
    fn get(&self, url: &str) -> Pin<Box<dyn Future<Output = ProbeResult> + Send + '_>>;
}
pub struct ReqwestProber(reqwest::Client);   // 1 s timeout per probe

pub trait Spawner: Send + Sync + 'static {
    fn spawn(&self, binary: &Path, port: u16) -> std::io::Result<std::process::Child>;
}
pub struct ProcessSpawner;   // Command::new(binary).args(["serve","--host","127.0.0.1","--port",port]) stdin/stdout null, stderr inherit

pub struct LifecycleConfig {
    pub explicit_port: Option<u16>,          // from RIELA_DESKTOP_SERVER_URL via parse_loopback_origin
    pub app_port: u16,                        // 19091
    pub serve_port: u16,                      // 8787
    pub binary: BinaryLookup,
    pub startup_timeout: Duration,            // 20 s
    pub poll_interval: Duration,              // 250 ms
}

pub struct ServerLifecycle { /* Mutex<ServerState>, tokio::sync::Notify, Mutex<Option<Child>>, config, prober, spawner */ }

impl ServerLifecycle {
    pub fn new(config: LifecycleConfig, prober: Arc<dyn Prober>, spawner: Arc<dyn Spawner>) -> Arc<Self>
    pub async fn discover(self: &Arc<Self>)               // full state machine; idempotent if already Connected
    pub async fn wait_ready(&self, max: Duration) -> Result<Endpoint, LifecycleError>
    pub fn status(&self) -> ServerStatusSnapshot          // {state, endpoint, detail}
    pub fn mark_unreachable(&self, detail: String)        // Connected → Failed
    pub fn shutdown(&self)                                // managed child only: SIGTERM, wait ≤3 s, kill
}
```

Discovery algorithm (exactly):
1. If `explicit_port`: probe `GET /api/v1/bootstrap` → 200 ⇒ `Connected(RielaApp)`; 404 ⇒
   probe `/healthz` → 200 with body containing `"service":"riela"` ⇒ `Connected(CliServe)`;
   otherwise `Failed("No Riela server answered at http://127.0.0.1:<port> (RIELA_DESKTOP_SERVER_URL)")`. Stop.
2. Probe `http://127.0.0.1:19091/api/v1/bootstrap` → 200 ⇒ `Connected(RielaApp, managed=false)`.
3. Probe `http://127.0.0.1:8787/healthz` → 200 + `"service":"riela"` ⇒ `Connected(CliServe, managed=false)`;
   any other status/body ⇒ `Failed("Port 8787 is in use by a service that is not riela serve …")`.
4. Unreachable on both: resolve binary; none ⇒ `Failed("No Riela server on 127.0.0.1:19091 or 127.0.0.1:8787 and no `riela` binary was found. Start RielaApp's web listener (Open Web Config), run `riela serve`, or set RIELA_DESKTOP_RIELA_BIN.")`.
5. Spawn ⇒ `Starting{pid}`; poll `/healthz` every 250 ms up to 20 s ⇒ `Connected(CliServe, managed=true)`;
   if the child exits early ⇒ `Failed("riela serve exited with <status> before becoming ready")`;
   timeout ⇒ `Failed("riela serve did not become ready within 20s")` and kill the child.
Every transition calls `notify.notify_waiters()`. `wait_ready` loops: `Connected` → Ok,
`Failed` → Err(detail), else await notify with the remaining budget; timeout → Err("Still
connecting to Riela…").

**Checklist**:
- [ ] Implement with the two injected traits.
- [ ] `#[cfg(test)]` with `FakeProber` (scripted responses per URL) and `FakeSpawner`
      (returns a real `Command::new("sleep").arg("30")` child, or a `Command::new("false")`
      child for the early-exit case): RielaApp preferred over serve; serve accepted; busy
      non-Riela 8787 → Failed, spawner never called; no binary → Failed; spawn → Starting →
      Connected(managed) once the fake prober flips healthz to 200; early exit → Failed;
      explicit port paths (200/404/unreachable); `mark_unreachable`; `wait_ready` wakes on
      transition; `shutdown` terminates the managed child and is a no-op for external.
      Use `#[tokio::test]`.

#### `src-tauri/src/commands.rs` (new)

**Status**: NOT_STARTED

```rust
#[derive(serde::Deserialize)] pub struct FetchRequest { pub path: String, pub method: String, pub headers: Vec<(String, String)>, pub body: Option<String> }
#[derive(serde::Serialize)]   pub struct FetchResponse { pub status: u16, pub headers: Vec<(String, String)>, pub body: String }
#[derive(serde::Serialize)]   pub struct CommandError { pub code: &'static str, pub message: String }   // invalid_request | server_unavailable | request_failed
#[derive(serde::Serialize)]   pub struct ServerStatus { pub state: &'static str, pub endpoint: Option<Endpoint>, pub detail: Option<String> }

pub struct AppState { pub lifecycle: Arc<ServerLifecycle>, pub http: reqwest::Client /* 30 s timeout, no redirects */ }

#[tauri::command] pub async fn riela_fetch(state: tauri::State<'_, AppState>, request: FetchRequest) -> Result<FetchResponse, CommandError>
#[tauri::command] pub async fn riela_server_status(state: tauri::State<'_, AppState>) -> Result<ServerStatus, CommandError>
#[tauri::command] pub async fn riela_server_retry(state: tauri::State<'_, AppState>) -> Result<ServerStatus, CommandError>
```

`riela_fetch`: `validate_relative_path` (→ `invalid_request`) → `wait_ready(30 s)` (→
`server_unavailable` with the lifecycle detail) → method parse (→ `invalid_request`) →
`reqwest` request to `endpoint.origin + path` with `outbound_headers` and optional body →
send; `reqwest::Error::is_connect()`/timeout ⇒ `mark_unreachable(detail)` + `server_unavailable`;
other send errors ⇒ `request_failed`; success ⇒ status, headers (skip `set-cookie`), body text.
`riela_server_retry`: `discover()` then `status()`.

**Checklist**:
- [ ] Implement; `#[cfg(test)]` for the method/header mapping helpers if any are extracted
      (keep network-free).

#### `src-tauri/src/lib.rs` + `src-tauri/src/main.rs` (new)

**Status**: NOT_STARTED

```rust
// lib.rs
pub mod commands; pub mod endpoint; pub mod lifecycle;
pub fn run() {
    let config = lifecycle::LifecycleConfig::from_environment(std::env::current_dir().ok(), std::env::var_os("RIELA_DESKTOP_SERVER_URL"), std::env::var_os("RIELA_DESKTOP_RIELA_BIN"), std::env::var_os("PATH"));
    // invalid RIELA_DESKTOP_SERVER_URL => lifecycle starts in Failed{detail} (not a panic)
    let lifecycle = ServerLifecycle::new(config, Arc::new(ReqwestProber::default()), Arc::new(ProcessSpawner));
    tauri::Builder::default()
        .manage(commands::AppState { lifecycle: lifecycle.clone(), http: … })
        .invoke_handler(tauri::generate_handler![commands::riela_fetch, commands::riela_server_status, commands::riela_server_retry])
        .setup(move |_app| { let lc = lifecycle.clone(); tauri::async_runtime::spawn(async move { lc.discover().await }); Ok(()) })
        .build(tauri::generate_context!())
        .expect("failed to build Riela Dashboard")
        .run(move |_handle, event| { if matches!(event, tauri::RunEvent::Exit | tauri::RunEvent::ExitRequested { .. }) { shutdown_lifecycle } });
}
// main.rs
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
fn main() { riela_dashboard_lib::run(); }
```

**Checklist**:
- [ ] Implement; `cargo fmt`, `cargo clippy --all-targets -- -D warnings` clean.

### 2.5 Repository plumbing

#### `mise.toml` (edit)

- `[tools]`: add `rust = "1.92.0"`.
- Tasks (append after `app:rebuild-run`, same style):

```toml
[tasks."desktop:dev"]
description = "Run the Riela Dashboard desktop app (Tauri v2) in development mode"
run = '''
set -euo pipefail
cd web && bun install && bun run tauri dev
'''

[tasks."desktop:build"]
description = "Build the Riela Dashboard desktop binary (pass tauri build args after --, e.g. -- --debug)"
run = '''
set -euo pipefail
cd web && bun install && CARGO_TERM_QUIET=true bun run tauri build "$@"
'''

[tasks."desktop:run"]
description = "Run the built Riela Dashboard binary, building it first when missing"
run = '''
set -euo pipefail
binary="${RIELA_DESKTOP_BINARY:-target/release/riela-dashboard}"
if [ ! -x "$binary" ]; then mise run desktop:build; fi
"$binary" "$@"
'''

[tasks."desktop:lint"]
description = "Rust format check, clippy (-D warnings) and cargo check for the desktop crate"
run = '''
set -euo pipefail
( cd web && bun install && bun run build )
CARGO_TERM_QUIET=true cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
CARGO_TERM_QUIET=true cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
CARGO_TERM_QUIET=true cargo check --manifest-path src-tauri/Cargo.toml
'''

[tasks."desktop:test"]
description = "Run the desktop crate's Rust tests"
run = '''
set -euo pipefail
( cd web && bun install && bun run build )
CARGO_TERM_QUIET=true cargo test --manifest-path src-tauri/Cargo.toml
'''
```

Note: `target/` lands at the repository root (workspace); `desktop:run` path above assumes that.
Confirm on the first build and adjust if Tauri places it under `src-tauri/target/`.

#### `.gitignore` (edit)

Append under "Build output":

```
# Rust / Tauri build artifacts
/target/
/src-tauri/target/
/src-tauri/gen/schemas/
**/*.rs.bk
```

#### `README.md` (edit)

Add a section "Dashboard: browser and desktop" near the existing RielaApp/`riela serve`
paragraph (around line 100): both hosts (RielaApp 127.0.0.1:19091 via Open Web Config; bare
`riela serve --web-root web/dist` on 127.0.0.1:8787 with reduced views), the desktop app
(`mise run desktop:dev`, `mise run desktop:build -- --debug`, `mise run desktop:run`),
discovery order 19091 → 8787 → spawn `riela serve`, the two env vars
`RIELA_DESKTOP_SERVER_URL` / `RIELA_DESKTOP_RIELA_BIN`, the fact that Instances/Run logs need
the RielaApp host, and that all HTTP is loopback-only and performed by the Rust process.

## 3. Ordered Tasks

| # | Task | Files | Depends on |
| - | ---- | ----- | ---------- |
| T1 | Plumbing: pin rust, .gitignore, root Cargo workspace | `mise.toml`, `.gitignore`, `Cargo.toml` | — |
| T2 | `transport.ts` + test | `web/src/transport.ts`, `web/src/transport.test.ts` | — |
| T3 | Wire seams | `web/src/api.ts`, `web/src/config/client.ts`, `web/src/workflows/client.ts` | T2 |
| T4 | Frontend deps + vite gating | `web/package.json`, `web/bun.lock`, `web/vite.config.ts` | — |
| T5 | Boundary module + test | `web/src/desktop/host.ts`, `web/src/desktop/host.test.ts` | T2, T4 |
| T6 | Entry wiring | `web/src/index.tsx` | T5 |
| T7 | Web gate: lint/typecheck/test/build + dist check | — | T3, T6 |
| T8 | Browser proof against `riela serve --web-root web/dist` (curl) | tmp only | T7 |
| T9 | Crate skeleton (manifests, build.rs, conf, capabilities, icons) | `src-tauri/**` | T1 |
| T10 | `endpoint.rs` + tests | `src-tauri/src/endpoint.rs` | T9 |
| T11 | `lifecycle.rs` + tests | `src-tauri/src/lifecycle.rs` | T10 |
| T12 | `commands.rs`, `lib.rs`, `main.rs`; first `cargo check`; confirm `cwd`/`frontendDist`/`target` locations | `src-tauri/src/*` | T7, T11 |
| T13 | Rust gate: fmt --check, clippy -D warnings, cargo check, cargo test; optional `tauri build --debug` | — | T12 |
| T14 | Desktop live checks (RielaApp listener / nothing running / no binary) | tmp only | T13 |
| T15 | `swift build` evidence | — | — (run any time after T1; must be green at the end) |
| T16 | Playwright `bun run test:e2e` | — | T7 |
| T17 | README section; re-read design + this plan for drift, update statuses | `README.md`, `impl-plans/active/tauri-dashboard-app.md` | T14 |
| T18 | Commit(s) on `feat/tauri-dashboard-app`; `git status` clean; no PR | — | all |

Parallelizable groups: {T1, T2, T4} → {T3, T5, T9} → {T6, T10} → {T7, T11} → {T8, T12, T15, T16} → T13 → T14 → T17 → T18.

## 4. Module Status

| Module | File Path | Status | Tests |
| ------ | --------- | ------ | ----- |
| Host transport seam | `web/src/transport.ts` | NOT_STARTED | `transport.test.ts` |
| Desktop boundary | `web/src/desktop/host.ts` | NOT_STARTED | `desktop/host.test.ts` |
| Seam wiring | `web/src/{api,config/client,workflows/client}.ts` | NOT_STARTED | existing suites |
| Entry | `web/src/index.tsx` | NOT_STARTED | build |
| Vite/package | `web/vite.config.ts`, `web/package.json`, `web/bun.lock` | NOT_STARTED | build, e2e |
| Crate skeleton | `src-tauri/{Cargo.toml,build.rs,tauri.conf.json,capabilities/default.json,icons/}` | NOT_STARTED | cargo check |
| Endpoint rules | `src-tauri/src/endpoint.rs` | NOT_STARTED | cargo test |
| Lifecycle | `src-tauri/src/lifecycle.rs` | NOT_STARTED | cargo test |
| Commands / app | `src-tauri/src/{commands,lib,main}.rs` | NOT_STARTED | clippy, live |
| Plumbing | `Cargo.toml`, `mise.toml`, `.gitignore` | NOT_STARTED | mise tasks |
| Docs | `README.md`, design, this plan | NOT_STARTED | review |

## 5. Verification Commands (paste real output; run from the worktree root)

```bash
# 1. web gate
( cd web && bun install && bun run lint && bun run typecheck && bun test src && bun run build ) && test -s web/dist/index.html && ls web/dist/assets | head

# 2. browser surface (bare riela serve)
mkdir -p tmp/tauri-dashboard-app
/Users/taco/gits/tacogips/riela/.build/release/riela serve --port 8787 --web-root web/dist > tmp/tauri-dashboard-app/serve.log 2>&1 & echo $! > tmp/tauri-dashboard-app/serve.pid
for i in $(seq 1 20); do curl -sf -o /dev/null http://127.0.0.1:8787/healthz && break; sleep 0.5; done
curl -s -o /dev/null -w 'index %{http_code}\n' http://127.0.0.1:8787/
asset=$(ls web/dist/assets | grep -m1 '\.js$'); curl -s -o /dev/null -w "asset %{http_code}\n" "http://127.0.0.1:8787/assets/$asset"
curl -s -w ' %{http_code}\n' http://127.0.0.1:8787/healthz
curl -s -w ' %{http_code}\n' http://127.0.0.1:8787/api/v1/bootstrap     # expect 404 unknown path (cli-serve fallback)
kill "$(cat tmp/tauri-dashboard-app/serve.pid)"

# 3. rust gate
mise install rust && mise run desktop:lint && mise run desktop:test
# optional, if time allows:
( cd web && CARGO_TERM_QUIET=true bun run tauri build --debug ) && ls -la target/debug/riela-dashboard

# 4. swift
swift build 2>&1 | tail -3

# 5. e2e
( cd web && bun run test:e2e )

# 6. desktop live checks (macOS session)
#  a) RielaApp listener running (open /Applications/RielaApp.app → menu → Open Web Config; confirm `curl -s http://127.0.0.1:19091/api/v1/bootstrap | head -c 120`)
#     mise run desktop:dev  → Instances and Run logs render live rows; note the log line / screenshot under tmp/tauri-dashboard-app/
#  b) nothing listening on 19091/8787 → mise run desktop:dev → app spawns riela serve (pgrep -f 'riela serve --host 127.0.0.1 --port 8787') → cli-serve dashboard; quit app → child gone
#  c) RIELA_DESKTOP_RIELA_BIN=/nonexistent PATH=/usr/bin:/bin mise run desktop:run → "Could not connect" panel with the actionable message
#  If (a) cannot be driven in the run environment, say so explicitly and attach the Rust header-policy test output plus:
#     curl -s -X POST -H 'Host: 127.0.0.1:19091' -H 'Origin: http://127.0.0.1:19091' -H 'Content-Type: application/json' -H 'X-Riela-CSRF: <token>' http://127.0.0.1:19091/graphql -d '{"query":"{ __typename }"}'
```

Cleanup: `rm -rf tmp/tauri-dashboard-app` before the final commit; never leave files at the repo root.

## 6. Completion Criteria

- [ ] All acceptance criteria in the workflow input are met with pasted evidence.
- [ ] `git ls-files web/src` shows exactly one SPA; Tauri-only frontend code = `web/src/desktop/host.ts` (+ test) and `web/src/transport.ts`.
- [ ] `bun run lint` (incl. audit-source) / `typecheck` / `bun test src` / `bun run build` green; `web/dist/index.html` + `assets/` present.
- [ ] Browser curl proof against `riela serve --web-root web/dist` (index 200, asset 200, healthz 200, bootstrap 404).
- [ ] `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo check`, `cargo test` green via `mise run desktop:lint` / `desktop:test`.
- [ ] `swift build` green; no diff under `Sources/`, `Packages/`, `scripts/`, `.github/`.
- [ ] `bun run test:e2e` green (or the attempt's actual failure output + reason).
- [ ] Desktop launch evidence per §5.6 with the RielaApp caveat stated truthfully.
- [ ] README documents browser + desktop, discovery order and env vars; design + plan committed; plan statuses updated to COMPLETED.
- [ ] Clean `git status` on `feat/tauri-dashboard-app`; no PR opened; no `tmp/`, root scratch, `target/` or `gen/schemas` committed.

## 7. Dependencies

| Feature | Depends On | Status |
| ------- | ---------- | ------ |
| Desktop transport | existing seams in `api.ts`, `config/client.ts`, `workflows/client.ts` | present |
| Server discovery | `riela serve` `/healthz` contract, RielaApp `/api/v1/bootstrap` | present (verified 0.1.33) |
| Rust toolchain | mise rust 1.92.0 (installed locally) | present |
| Crates | tauri 2.11.x, tauri-build 2.6.x, reqwest 0.12, tokio 1 | crates.io reachable |

## 8. Risks and Mitigations

- RielaApp live-data evidence may not be drivable headlessly → state explicitly, attach Rust header-policy tests + curl-equivalent (§5.6).
- Tauri CLI `cwd`/`frontendDist`/`target` resolution for the `web/` layout → T12 checkpoint; one-line fixes.
- Cold Rust build time / new clippy lints on 1.92 → run `desktop:lint` early (after T12), fix lints, don't `#[allow]` blindly.
- `web/bun.lock` forgotten → completion criterion + `bun install --frozen-lockfile` check.
- Vite server block leaking into e2e → env gate + T16.
- Managed child kill semantics → only `managed == true`, SIGTERM first, 3 s grace.
