# Tauri Dashboard Branch Re-integration Design

**Status**: Accepted 2026-09-21
**Scope**: Land `feat/tauri-dashboard-app` (tip d2c6991, 6 commits, +10413) onto current
main (77616b5) as one `--no-ff` merge on `integrate/tauri-dashboard-app`.
**Worktree**: `/Users/taco/gits/tacogips/riela-worktrees/tauri-integration` only.

## 1. Problem

The branch predates the control-surface parity change and 23+ other main commits.
It ships a Tauri v2 desktop shell at repo-root `src-tauri/` (Rust `riela_fetch`
command; `lifecycle.rs` spawns and manages a `riela serve` child), a
`web/src/desktop/host.ts` + `setHostTransport` seam, SPA-by-default `riela serve`,
a symlink-aware web-asset locator, and `share/riela/web` packaging.

## 2. Central finding (drives every resolution)

Main has independently superseded every code intent of the branch, in different
shapes:

| Branch intent | Main's superseding shape (evidence) |
|---|---|
| Desktop shell (root `src-tauri/`, spawns riela serve, `riela_fetch`) | `web/src-tauri/` shell spawned **by** riela (`Sources/RielaApp/RielaDesktopController.swift`), stdio bridge via `riela_request`/`riela_remote_request`, passkey login, startup window |
| Transport seam (`web/src/desktop/host.ts`, `setHostTransport`, install at startup) | `web/src/transport.ts` `rielaFetch` detects `__TAURI__` at call time; adds bearer-token and remote-endpoint support; no install step |
| SPA from bare `riela serve` | `resolvedServeWebRoot` falls back to `RielaWebAssetLocator.locate()`; requests route through `ServeWebHost` (`Sources/RielaCLI/ServeHTTPCommand.swift`) |
| Locator symlink/pkgshare fix (edits inside `RielaLocalHTTPServer.swift`) | Locator extracted to `Sources/RielaServer/RielaWebAssetLocator.swift`; main's `RielaWebAssetLocatorTests` covers Cellar-through-binary-symlink, cask sibling, native bundle, `share/riela/web`, dev fallback |
| `share/riela/web` in archives; host-side web prebuild in CI | `scripts/lib/riela-web-packaging.sh` sourced by `build-homebrew-release.sh`; `linux-release.yml` installs SHA-pinned bun inside the container |
| `web/package.json` tauri deps/scripts on old dep set | Main upgraded to TS 6 / ESLint 10 / Vite 8 / solid 1.9.15 with `desktop:build` cargo scripts targeting `web/src-tauri` |
| Console reads | `web/src/console/client.ts` reads instance list/detail/ops overview via GraphQL over `rielaFetch`; JSON reads deleted (`RielaConsoleGraphQLProvider.swift`); only POST create + execution sub-routes remain in `RielaWebAPIRouteTable.swift` |

The two shells have **opposite process topologies** (branch: shell spawns riela;
main: riela spawns shell). The branch's managed-serve lifecycle, orphan
prevention, and discovery logic are moot under main's topology. The operator's
requirement — "the desktop shell must read through the same GraphQL console
client main now uses" — is satisfied only by main's shell; nothing on main
invokes `riela_fetch`.

## 3. Decision: resolution matrix

**Rule applied**: adopt main's structure per file after examining both hunks;
re-apply branch intent only where main lacks it (nowhere, per §2). Never a
wholesale `--ours`.

### 3.1 The 14 conflicts → resolve to main's (HEAD's) content

| # | Path | Why main's side is complete |
|---|---|---|
| 1 | `.github/workflows/linux-release.yml` | pinned in-container bun supersedes host prebuild + `RIELA_WEB_ASSETS_PREBUILT` |
| 2 | `Sources/RielaCLI/ServeHTTPCommand.swift` | `ServeWebHost` + locator fallback supersede branch default-web-root |
| 3 | `Sources/RielaServer/RielaLocalHTTPServer.swift` | locator moved out to its own file on main |
| 4 | `Tests/RielaServerTests/RielaWebAssetLocatorTests.swift` (add/add) | main's version tests main's API and covers all branch cases |
| 5 | `scripts/build-homebrew-release.sh` | web packaging via shared lib on main |
| 6 | `scripts/render-homebrew-formula.sh` | main's scratch-path/version-assert flow |
| 7 | `web/bun.lock` | must match main's package.json |
| 8 | `web/package.json` | main's dep majors + cargo desktop scripts; no `@tauri-apps/*` |
| 9 | `web/src/api.ts` | `rielaFetch` default transport |
| 10 | `web/src/config/client.ts` | same |
| 11 | `web/src/index.tsx` | `AuthEntry` + auth CSS; no desktop-host install needed |
| 12 | `web/src/transport.test.ts` (add/add) | tests main's transport API |
| 13 | `web/src/transport.ts` (add/add) | call-time `__TAURI__` detection supersedes seam |
| 14 | `web/src/workflows/client.ts` | `rielaFetch` + editor projection on main |

### 3.2 Cleanly auto-merging branch artifacts → active disposition

These produce no textual conflict but violate build-green or the no-dead-code
constraint if left in:

**Remove in the merge resolution** (superseded implementations; nothing on main
references them; `web/src/desktop/*` would fail typecheck — imports
`setHostTransport` which main's transport does not export):
- `src-tauri/` (entire directory), root `Cargo.toml`, root `Cargo.lock`
- `web/src/desktop/host.ts`, `web/src/desktop/host.test.ts`

**Revert to main's version** (branch hunks only serve the removed shell, or are
stale docs; branch's serve-test additions call
`resolvedServeWebRoot(parsed:locateDefault:)` returning a resolution struct —
an API that does not exist on main, so they cannot compile):
- `web/vite.config.ts` (Tauri dev-server block; main's shell uses
  `frontendDist: ../dist`, no dev server)
- `README.md` (94-line section documents the removed shell and pre-parity API
  behavior; main already has its own `## Desktop window` section)
- `mise.toml` (rust tool + `desktop:*` tasks against root `src-tauri`)
- `.gitignore` (root `/target/`, root src-tauri entries; main already ignores
  its own shell's artifacts)
- `Tests/RielaCLITests/ServeHTTPCommandTests.swift` (branch behavioral cases are
  covered on main by `RielaWebAssetLocatorTests`, `ServeWebHostTests`, and
  `RielaHTTPRoutingAndStaticAssetTests.testStaticResolverServesSPAAndRejectsConcreteAssetFallbackAndSymlinkEscape`)

**Keep from the branch** (history; merges clean):
- `design-docs/research/tauri-dashboard-app-brief.md`,
  `design-docs/research/riela-serve-web-client-brief.md` — keep as-is
- `design-docs/tauri-dashboard-app.md`, `design-docs/riela-serve-web-client.md`
  — keep with a prepended `> **Superseded 2026-09-21** …` status note pointing
  at `web/src-tauri` and this document
- `impl-plans/active/tauri-dashboard-app.md`,
  `impl-plans/active/riela-serve-web-client.md` — move to
  `impl-plans/completed/` with the same supersession note (repo has
  `active/`+`completed/`, no `archive/`)

### 3.3 New artifacts authored by this integration
- `docs/briefs/tauri-dashboard-integration-2026-09-21.md` — what the branch
  contributed, per-file resolution rationale, what was dropped as superseded,
  named residual risks.
- `impl-plans/progress/tauri-dashboard-reintegration.md` — progress log with the
  recorded grep evidence and verification transcript summary.

## 4. Interfaces, data flow, state

No control surface is added, changed, or removed: the merged tree's code is
intentionally identical to main's. Therefore no `SurfaceCatalog*.swift` rows, no
SDL regeneration; the five SurfaceParity gates and `SurfaceCatalogTests` act as
regression proof only. Data flow after the merge: browser SPA and desktop shell
both call `rielaFetch` → (browser) same-origin fetch with optional bearer /
(desktop) `riela_request` stdio bridge → riela HTTP host → GraphQL console
documents for instance list, instance detail, ops overview.

## 5. Errors / compatibility / security

- NO back-compat: no shim between JSON console reads and GraphQL; enforced by
  removing `requestThroughHost`/`host.ts` rather than adapting them.
- Security posture is main's (auth entry, passkeys, CSRF, Host/Origin guard);
  the branch's weaker pre-auth index.tsx must not survive (conflict 11).
- The merge commit must not resurrect `GET /api/v1/instances` reads,
  `/api/v1/ops/overview` instance reads, or any direct JSON console read —
  proven by grep (§6).

## 6. Test & verification strategy

All commands foreground, from the worktree root; Swift via
`arch -arm64 /bin/zsh -lc`; full logs kept under `/tmp/tauri-integ-*.log` and
exit statuses recorded in the progress log.

1. Conflict-marker sweep: `git diff --check` plus
   `grep -rnE '^(<{7} |>{7} |\|{7} )' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist .`
2. Retired-surface grep (recorded in progress log):
   `git grep -n 'api/v1/instances\|api/v1/ops/overview' -- web/src` → expect no
   matches; `git grep -n 'riela_fetch\|requestThroughHost\|setHostTransport\|installDesktopHost' -- web/src Sources` → expect no matches;
   `test ! -e src-tauri && test ! -e Cargo.toml`
3. `swift build`, then targeted `swift test --filter RielaWebAssetLocatorTests`,
   `--filter SurfaceParity`, `--filter SurfaceCatalogTests`,
   `--filter ServeWebHost`
4. Full `swift build && swift test`; failure set must equal exactly the ten
   accepted environmental failures (6 AppKit view-hierarchy:
   RielaAppUXOnboardingControllerTests, RielaAppSettingsEditorNavigationTests,
   RielaAppWindowContentInsetTests; 3 WorkflowRound7AdversarialTests
   unix-socket-unlink; WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario).
   Never truncate/tail the log.
5. `cd web && bun run typecheck && bun run lint && bun test src`
6. Best-effort desktop compile (cargo exists at `~/.cargo/bin/cargo`):
   `cargo build --locked --manifest-path web/src-tauri/Cargo.toml`. On toolchain
   failure: do **not** install anything; record "desktop bundle unverified" as a
   named residual risk in the brief.
7. Tree audit: after the merge commit, `git diff --stat 77616b5 HEAD` must list
   **only** documentation paths (docs/briefs note, 4 design-docs files —
   2 kept, 2 annotated — 2 impl-plans/completed files, 1 progress log). Any
   code path in that diff is a resolution error.

## 7. Rollout

Single merge commit on `integrate/tauri-dashboard-app`; push that branch only.
No force push. Main untouched. The merge preserves the branch's history in the
DAG while the brief records why its implementations were dropped.

## 8. Edge cases

- add/add conflicts (locator test, transport.ts, transport.test.ts): choose
  main's blob, do not hand-merge.
- `git rm` of `src-tauri/` during merge resolution stages deletions relative to
  the merge result; verify with `git status` before committing.
- Moved impl-plan files: when enumerating committedFiles for the riela
  git-commit add-on, list only the new `impl-plans/completed/` paths, never
  old+new of a move; plain `git` fallback is acceptable for the merge commit.
- README/mise.toml/.gitignore reverts use `git checkout HEAD -- <path>` (HEAD =
  main tip during merge), which also stages them.
- Full-suite interleaved-submit timing flake is known; a single unrelated flaky
  failure warrants one targeted re-run of that suite before being treated as a
  real regression.

## 9. Alternatives rejected

- **Keep the branch's root `src-tauri` shell and rewire it to GraphQL**: two
  shells with opposite topologies; duplicates `web/src-tauri`; violates
  no-dead-code; far larger risk than value.
- **Port branch's transport seam onto main**: `rielaFetch`'s call-time detection
  already covers it; the seam would be dead code.
- **Port branch serve tests to main's API**: behaviors already covered by
  main's locator/ServeWebHost/static-router suites; porting would duplicate
  coverage against a different API surface.
- **`git merge -s ours`**: forbidden (wholesale one-side resolution) and would
  discard the docs worth keeping.
