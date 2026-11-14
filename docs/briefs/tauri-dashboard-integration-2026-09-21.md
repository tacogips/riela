# Tauri Dashboard Integration Brief

**Integrated branch**: `feat/tauri-dashboard-app` at `d2c69918`
**Integration branch**: `integrate/tauri-dashboard-app`
**Resolution date**: 2026-09-21

## Outcome

The branch history is retained, but its product code is not reintroduced. Main
independently shipped the same operator outcome with the opposite and now
canonical topology: Riela launches the shell at `web/src-tauri/`, and the web
console reads through `web/src/console/client.ts` and `rielaFetch` into GraphQL.
The older root `src-tauri/` shell launched `riela serve` itself and would create
a second lifecycle, transport, and authentication boundary.

The resolved merge is therefore documentation-only relative to its main base.
The historical research briefs and designs remain available, with supersession
notes on the two designs and completed implementation plans.

## What the branch contributed

- A Tauri v2 shell and Rust-owned `riela_fetch` bridge.
- A web transport installation seam under `web/src/desktop/`.
- SPA-by-default `riela serve` behavior and web asset discovery/packaging work.
- Tests, release automation, and the original research/design/implementation
  records for that topology.

Main superseded those contributions with `web/src-tauri/`, call-time
`rielaFetch` dispatch, `ServeWebHost` plus `RielaWebAssetLocator`, and
`scripts/lib/riela-web-packaging.sh`.

## Conflict resolution

Each textual conflict was examined and resolved to the integration branch's
pre-merge main content because that side owns the current architecture.

| Path | Resolution |
| --- | --- |
| `.github/workflows/linux-release.yml` | Keep pinned in-container Bun packaging. |
| `Sources/RielaCLI/ServeHTTPCommand.swift` | Keep `ServeWebHost` and locator fallback. |
| `Sources/RielaServer/RielaLocalHTTPServer.swift` | Keep the extracted locator boundary. |
| `Tests/RielaServerTests/RielaWebAssetLocatorTests.swift` | Keep tests for the current locator API. |
| `scripts/build-homebrew-release.sh` | Keep the shared packaging-library flow. |
| `scripts/render-homebrew-formula.sh` | Keep the current scratch/version checks. |
| `web/bun.lock`, `web/package.json` | Keep the current dependency graph and desktop scripts. |
| `web/src/api.ts`, `web/src/config/client.ts`, `web/src/workflows/client.ts` | Keep `rielaFetch`. |
| `web/src/index.tsx` | Keep `AuthEntry` and current authentication startup. |
| `web/src/transport.ts`, `web/src/transport.test.ts` | Keep call-time Tauri detection and remote endpoint support. |

The cleanly merged but superseded root `src-tauri/`, root Cargo workspace, and
`web/src/desktop/` seam were removed. `README.md`, `mise.toml`, `.gitignore`,
`web/vite.config.ts`, and `ServeHTTPCommandTests.swift` were restored to the
pre-merge main versions.

## Verification and residual risks

- Swift build and focused locator, SurfaceParity, SurfaceCatalog, and
  ServeWebHost suites passed.
- Web typecheck, lint, source audit, and 100 unit tests passed.
- `cargo build --locked --manifest-path web/src-tauri/Cargo.toml` passed, so
  the current desktop shell compiles in this environment.
- The full Swift suite executed 2,283 tests. The ten plan-recorded baseline
  test cases failed as expected. Five additional timing/subprocess cases
  failed under the loaded full run; targeted rerun cleared three. Two
  three-second live-persistence waits remained reproducible. They are not
  caused by this documentation-only merge and remain a named repository
  follow-up; they prevent claiming a fully green full-suite gate here.
- No end-to-end signed desktop bundle or interactive Tauri window launch was
  performed. Compile and transport/unit evidence is the available desktop
  evidence.
- The original literal retired-route grep also matches explanatory comments,
  regression-test strings, and still-supported mutation/execution routes.
  The actual read invariant is instead proved by the console-client unit test,
  SurfaceParity console tests, and ServeWebHost GraphQL test.
