# Research brief: ship the Riela dashboard as a Tauri desktop app while keeping the web surface

Date: 2026-08-31
Branch: `feat/tauri-dashboard-app`
Author: operator pre-run research (verified against the tree at `e8cd1f2`)

This brief is pre-run context for the `fable-and-improve-opus` workflow. Everything
below was verified by reading the repository; treat it as ground truth and re-verify
anything you intend to contradict.

## 1. Goal

The Riela dashboard today is a browser page fetched from a Riela-hosted HTTP server.
Ship it *additionally* as a native desktop application built with Tauri v2, without
removing or degrading the browser surface, and keep exactly one copy of the frontend
source so the two shells never drift.

## 2. Verified current state

### 2.1 Frontend (`web/`)

- Bun + Vite 7 + SolidJS 1.9 + Tailwind 4. `web/package.json` scripts:
  `dev` (`vite`), `build` (`vite build`), `typecheck` (`tsc --noEmit`),
  `lint` (`eslint . && bun run audit`), `test` (`bun test src`),
  `test:e2e` (`playwright test`).
- `web/vite.config.ts` is minimal: `plugins: [solid(), tailwindcss()]`,
  `build: { target: 'es2022', sourcemap: true }`. No `base`, no server block.
- Entry `web/index.html` -> `src/index.tsx` -> `App` (`src/App.tsx`).
- Views: `src/views/{InstancesView,LogsView,RunDetailView,SettingsView,WorkflowsView}.tsx`,
  command deck under `src/ops/`, shared bits in `src/components/`,
  `src/{api,contracts,polling,routes}.ts`, `src/config/client.ts`,
  `src/workflows/{client,types,validation}.ts`.
- Unit tests live beside sources as `*.test.ts` and run under `bun test src`.
  E2E specs live in `web/e2e/` and run under Playwright.

### 2.2 How the frontend talks to Riela — the critical seam

- `web/src/api.ts` exports `class RielaAPIClient` whose constructor already takes an
  injectable transport:
  `constructor(private readonly transport: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> = (input, init) => fetch(input, init))`
  It is instantiated once as the module-level singleton `export const api = new RielaAPIClient()`.
- `RielaAPIClient.request` calls `this.transport(path, { ...init, credentials: 'same-origin' })`
  with **relative** paths only (`/api/v1/bootstrap`, etc.).
- `web/src/config/client.ts` (`RielaConfigurationClient`) has the *same* injectable
  `request` seam and posts GraphQL to a relative path.
- `web/src/workflows/client.ts` follows the same shape — confirm before editing.
- Therefore the entire frontend assumes **same-origin relative fetch**. There is no
  base-URL concept anywhere (`grep` for `apiBase|baseUrl|location.origin` finds only
  hash-routing uses of `window.location` in `App.tsx`).
- Mutations require the `X-Riela-CSRF` header, whose value comes from
  `GET /api/v1/bootstrap` (`Sources/RielaApp/RielaAppWebRouter.swift:85` rejects a
  mismatch with `403 invalid_csrf`).
- `App.tsx:199 discoverHost()` probes `api.bootstrap()`; a `404` means the host is a
  bare `riela serve` (`mode: 'cli-serve'`), anything else means the RielaApp host
  (`mode: 'riela-app'`). `CLI_SERVE_HIDDEN_VIEWS` hides Settings and the command deck
  in `cli-serve` mode because those aggregate APIs are RielaApp-only.

### 2.3 How the assets are served today (two hosts, both must keep working)

1. **`riela serve`** — `Sources/RielaCLI/ServeHTTPCommand.swift`. Bare `riela serve`
   is long-running; defaults `host 127.0.0.1`, `port 8787`; `--web-root <dir>` selects
   static assets, wrapped by `RielaStaticSPAHTTPRouter`.
2. **RielaApp (macOS menu-bar app)** — `Sources/RielaApp/*`, listener default
   `127.0.0.1:19091`, richer API (`/api/v1/*` + GraphQL). Packaging copies
   `web/dist/` into `RielaApp.app/Contents/Resources/Web`
   (`scripts/build-riela-menu-bar-app.sh:117`, and again in
   `scripts/build-homebrew-cask-release.sh`).
- `RielaWebAssetLocator.locate` (`Sources/RielaServer/RielaLocalHTTPServer.swift:~348`)
  resolves assets from, in order: `<bundle resources>/Web`,
  `<executable>/../Resources/Web`, then `<cwd>/web/dist`.
- **`web/dist` must keep being produced by `bun run build` at the same path with the
  same shape.** Both packaging scripts hard-assert `test -s web/dist/index.html`.
- The servers emit **no CORS headers** — `design-docs/rielaapp-solidjs-web-ui.md`
  explicitly lists CORS support as out of scope, and the listener is loopback-only.

### 2.4 Repository conventions

- Swift package at the root (`Package.swift`); there is **no Rust/Cargo anywhere in
  riela today**. A Tauri crate introduces the first Rust build to this repo.
- Task runner is **mise** (`mise.toml`), not `task`. Existing app tasks:
  `app:build`, `app:run`, `app:rebuild-run`, `build:homebrew`, `build:homebrew-cask`.
- Tooling pinned in `mise.toml [tools]`: swift 6.3.3, swiftlint, bun, biome, node 22,
  github-cli, podman, uv, gitleaks, pre-commit. **Rust is not pinned yet.**
- `.gitignore` already ignores `dist/`, `node_modules/`, `.build/`, `tmp/`.
  A Rust `target/` and Tauri `gen/schemas` need ignore entries.
- Scratch files go under the repo-root `tmp/` (see `AGENTS.md`), never at the root or
  in `scripts/`.
- CI workflows in `.github/workflows/` are Linux build/release only and run no tests.

## 3. Reference implementations to copy from

### 3.1 `/Users/taco/gits/tacogips/chilla` (closest analogue: Tauri v2 + Vite + SolidJS)

- Layout: frontend `src/` and `index.html` at the repo root, Rust in `src-tauri/`.
- `src-tauri/tauri.conf.json`: `"$schema": "https://schema.tauri.app/config/2"`,
  `build.beforeDevCommand: "bun run dev"`, `build.devUrl: "http://localhost:1420"`,
  `build.beforeBuildCommand: "bun run build"`, `build.frontendDist: "../dist"`;
  one `main` window (1480x920, `decorations: false`); explicit `app.security.csp`
  that allows `connect-src 'self' ipc: http://ipc.localhost http://127.0.0.1:*`.
- `src-tauri/Cargo.toml`: `[lib] name = "chilla_lib"`,
  `crate-type = ["staticlib", "cdylib", "rlib"]`, `tauri = { version = "2", features = ["custom-protocol", "protocol-asset"] }`,
  `tauri-build` as a build dependency, plus `tauri-plugin-dialog` / `tauri-plugin-opener`.
- `src-tauri/build.rs` is just `tauri_build::build()`.
- `src-tauri/capabilities/default.json` grants `core:default`, `core:window:allow-close`,
  `dialog:allow-open`, `opener:default`, `opener:allow-open-path` to `windows: ["main"]`.
- `src-tauri/src/lib.rs` exposes `pub fn run(startup_target: StartupTarget) -> Result<(), String>`
  building `tauri::Builder::default()`, registering plugins, `.setup(...)` that
  constructs services and `app.manage(AppState::new(...))`; `main.rs` parses CLI args
  and calls it. Commands live in `src-tauri/src/commands/`.
- Frontend `vite.config.ts` reads `process.env.TAURI_DEV_HOST`, sets
  `clearScreen: false`, `server: { port: 1420, strictPort: true, host: host || false,
  hmr: host ? { protocol: 'ws', host, port: 1421 } : undefined,
  watch: { ignored: ['**/src-tauri/**'] } }`.
- `package.json` adds `"tauri": "tauri"`, dependency `@tauri-apps/api`, dev dependency
  `@tauri-apps/cli`.

### 3.2 `/Users/taco/gits/tacogips/ign-template/tauri-v1` (the house template)

Same skeleton, generic: root `Cargo.toml` with `[workspace] members = ["src-tauri"]`,
`resolver = "2"`; `src-tauri/{Cargo.toml,tauri.conf.json,build.rs,capabilities/default.json,icons/icon.png,src/{lib.rs,main.rs}}`;
`vite.config.ts` identical in shape to chilla's; `.agents/scripts/lint-rust.sh` and
`lint-ts.sh`; `mise.toml`. Follow this for file placement and lint-script conventions.

## 4. The hard problem: origin

A Tauri webview loads bundled assets from `tauri://localhost` (macOS) /
`http://tauri.localhost` (Windows), **not** from the Riela HTTP origin. Every
existing `fetch('/api/v1/...')` would therefore hit the Tauri asset protocol and 404,
and even absolutised requests to `http://127.0.0.1:19091` would be blocked because
Riela's loopback servers send no CORS headers and rely on `credentials: 'same-origin'`
plus a CSRF header.

Three candidate designs — the design step should pick one and justify it:

- **A. Remote-URL window.** Point the Tauri window straight at the running Riela
  server URL. Zero frontend change, perfectly same-origin, but the "app" is a thin
  browser: no bundled assets, nothing works before the server is up, and Tauri v2
  restricts IPC for remote origins unless they are declared in capabilities.
- **B. Bundled assets + injected transport (recommended starting point).** Ship
  `web/dist` as `frontendDist`. Introduce one small host seam in the shared frontend
  (e.g. `web/src/host.ts`) exporting the API origin and a transport. On the web build
  it resolves to `''` + plain `fetch` — byte-for-byte today's behaviour. Under Tauri
  it resolves the Riela origin from a Rust command and uses
  `@tauri-apps/plugin-http`'s `fetch`, which performs the request in Rust and so is
  not subject to browser CORS. The existing injectable `transport`/`request`
  constructor seams in `api.ts`, `config/client.ts`, and `workflows/client.ts` are
  exactly the intended attachment points; the only real refactor is that `api` is a
  module-level singleton and needs a one-time configuration entry point.
- **C. Rust-side proxy.** Serve the SPA and reverse-proxy `/api` from inside the Tauri
  process so the webview stays same-origin. Most code, most moving parts.

Whichever is chosen, the Tauri process should also own **server lifecycle**: discover
an already-running Riela server, or spawn `riela serve` (defaults `127.0.0.1:8787`)
and stop it on exit, and surface a clear "connecting / not running" state instead of
a blank window.

## 5. DRY requirement (explicit operator constraint)

The frontend must exist **once**. Acceptable: one `web/` source tree, one component/
view/test set, one Vite config parameterised by a Tauri flag (e.g. `TAURI_ENV_PLATFORM`
or an explicit mode), producing the same `web/dist` both shells consume. Not
acceptable: a second copy of the SPA under `src/` or `src-tauri/`, forked views, or a
duplicated API client. Any Tauri-only code must be a thin, clearly-named boundary
module plus the Rust crate.

## 6. Non-negotiable regressions to avoid

1. `bun run build` still emits `web/dist/index.html` + `assets/` exactly as today;
   `scripts/build-riela-menu-bar-app.sh` and `scripts/build-homebrew-cask-release.sh`
   keep working unchanged (or are updated deliberately and stay green).
2. The browser surface keeps working against **both** hosts: RielaApp (19091) and
   `riela serve` (8787), including the `cli-serve` 404 fallback in `discoverHost`
   and the `CLI_SERVE_HIDDEN_VIEWS` behaviour.
3. `bun run lint`, `bun run typecheck`, `bun test src` stay green; existing
   `web/e2e` Playwright specs keep passing.
4. Swift build and the existing Swift test suites are unaffected.
5. No secrets, no non-loopback binding, no new network exposure.

## 7. Suggested verification

- `cd web && bun install && bun run lint && bun run typecheck && bun test src && bun run build`
- confirm `web/dist/index.html` exists and the served page still boots against a
  locally started `riela serve --port 8787` (or a running RielaApp on 19091)
- `cargo fmt --check` / `cargo clippy` on the new crate, and a `cargo check` or
  `bun run tauri build` for the desktop shell (a debug `tauri build`/`cargo check`
  is acceptable if a full signed bundle is too slow)
- `swift build` to prove the Swift side is untouched
