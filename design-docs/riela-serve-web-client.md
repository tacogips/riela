# `riela serve` Serves the Dashboard by Default — Design

Status: accepted for implementation

Feature ID: `riela-serve-web-client`

Workflow mode: `fable-and-improve-opus` (single feature, single work package; no fan-out)

Research brief: `design-docs/research/riela-serve-web-client-brief.md`

Branch: `feat/tauri-dashboard-app`

Date: 2026-08-31

## Objective

Make bare `riela serve` (no `--web-root`) serve the Riela dashboard SPA whenever the built
web assets can be located, while continuing to serve the JSON/GraphQL API either way — and
make that true for a Homebrew-installed `riela`, whose archive today contains no web assets
at all. When nothing can be located, `riela serve` must still start, serve the API, and say
so clearly in its ready output.

The desktop-app half of the operator requirement (Tauri app under `src-tauri/`) is already
on this branch and is only a non-regression target here.

## Verified facts this design depends on

| # | Fact | Evidence |
| - | ---- | -------- |
| F1 | `resolvedServeWebRoot(parsed:)` returns `nil` when `--web-root` is absent; `ServeHTTPCommand.run` then uses the bare `DeterministicServerHTTPAdapter`, otherwise wraps it in `RielaStaticSPAHTTPRouter`. Ready output records are `endpoint=` and, only when set, `webRoot=`. | `Sources/RielaCLI/ServeHTTPCommand.swift:36-55,97-131` |
| F2 | `RielaWebAssetLocator.locate(bundle:executableURL:currentDirectoryURL:)` tries `<bundle.resourceURL>/Web`, `<exe dir>/../Resources/Web` (`.standardizedFileURL` only, no symlink resolution), `<cwd>/web/dist`, and returns the first with an existing `index.html`. Only caller: RielaApp (`EntryPoint+WebServer.swift:9`). It is declared outside `#if canImport(Network)`, so it compiles on Linux. | `Sources/RielaServer/RielaLocalHTTPServer.swift:347-368` |
| F3 | **Symlink trap confirmed empirically** (analysis step, scratch program under `tmp/`, removed): invoked through `link/exe -> ../cellar/bin/exe`, `Bundle.main.executableURL` is the *symlink* path and `Bundle.main.resourceURL` is the *symlink's directory*; `.resolvingSymlinksInPath()` yields the real `cellar/bin/exe`. So for `/opt/homebrew/bin/riela -> ../Cellar/riela/<v>/bin/riela` the current locator looks in `/opt/homebrew/Resources/Web`. | analysis evidence |
| F4 | For a plain CLI (no `.app` bundle) `Bundle.main.resourceURL` equals the executable's directory, so candidate 1 degenerates to `<bin>/Web`. | F3 experiment |
| F5 | `RielaStaticAssetResolver` / `RielaStaticSPAHTTPRouter` route `/api`, `/graphql`, `/healthz`, `/note`, `/overview` (exact or prefix + `/`) to the service; everything else (including `/`, `//`, `///`) is tried as an asset with SPA fallback; NUL, `%00`, `..`, backslash and symlink-escape are already guarded and tested. The root is already `standardizedFileURL.resolvingSymlinksInPath()`. | `Sources/RielaServer/RielaStaticAssetResolver.swift`; `Tests/RielaServerTests/RielaHTTPRoutingAndStaticAssetTests.swift:17-100` |
| F6 | Bare serve API routes: `GET /` and `GET /overview` → overview JSON, `GET /healthz`, `POST /graphql`; 405 for other methods on those paths; 404 `{"error":"unknown path"}` otherwise. `/api/v1/*` therefore 404s under `riela serve`. | `Sources/RielaServer/ServerContracts.swift:121-145` |
| F7 | The SPA treats a 404 from `/api/v1/bootstrap` as `mode:'cli-serve'`, hides Settings and Command deck, and its Instances / Run logs / Workflows-sources fetches hit `/api/v1/*` (ErrorBanner under cli-serve); GraphQL-backed parts work. Playwright covers the hiding. | `web/src/App.tsx:38-47,199-203`; `InstancesView.tsx:54`, `LogsView.tsx:19`, `WorkflowsView.tsx:65`; `web/e2e/workflow-management.spec.ts:401` |
| F8 | `scripts/build-homebrew-release.sh` `build_target()` stages only `bin/riela` and `README.md`; `Formula/riela.rb` does `bin.install "bin/riela"`; **`Formula/riela.rb` is regenerated from the heredoc in `scripts/render-homebrew-formula.sh`**. | those files |
| F9 | `build_web_assets()` (bun install --frozen-lockfile → lint → typecheck → test → build → `test -s web/dist/index.html`) exists in `scripts/build-homebrew-cask-release.sh:311-322` and `scripts/build-riela-menu-bar-app.sh:57-68`; the cask script calls it once in `main()` when not `--dry-run`, and stages `web/dist/.` into `RielaApp.app/Contents/Resources/Web`. | those files |
| F10 | `.github/workflows/linux-release.yml` runs `scripts/build-homebrew-release.sh linux-x64` **inside the official `swift` docker image (no bun)**, asserts `tar -tzf … | grep -Fx './bin/riela'`, and smoke-installs only `bin/riela` on clean Ubuntu. | `.github/workflows/linux-release.yml:53-104` |
| F11 | The Tauri app probes only `GET /api/v1/bootstrap` (19091) and `GET /healthz` (8787); it never parses `riela serve` stdout nor `GET /`. | `src-tauri/src/lifecycle.rs:248-256,301-350`; README "Dashboard" section |
| F12 | `ParsedParityOptions` already parses `--web-root` (tilde-expanded). `ServeHTTPCommandTests` has an explicit-root validation test plus unused `availablePort()`, `curl(...)`, `ReadyOutputBox` helpers; `RielaLocalHTTPServer.startForTesting()` exists. No `RielaWebAssetLocator` test exists. | `Sources/RielaCLI/ParityCommandSupport.swift:60,106`; `Tests/RielaCLITests/ServeHTTPCommandTests.swift` |
| F13 | `web/dist` (gitignored) contains `index.html`, `favicon.svg`, `assets/*.js`, `*.css`, `*.js.map`. `cargo` is only reachable through mise (`mise run desktop:test`). | analysis |

## Scope

### In scope

- `Sources/RielaServer/RielaLocalHTTPServer.swift` — `RielaWebAssetLocator`: symlink-resolved
  executable path and a new `../share/riela/web` candidate; optional `bundle` parameter.
- `Sources/RielaCLI/ServeHTTPCommand.swift` — default asset discovery, shared validation,
  injectable locator, richer ready records.
- `Tests/RielaServerTests/RielaWebAssetLocatorTests.swift` (new) and
  `Tests/RielaCLITests/ServeHTTPCommandTests.swift` (extended).
- `scripts/build-homebrew-release.sh` — build and stage web assets into the CLI archive.
- `Formula/riela.rb` **and** `scripts/render-homebrew-formula.sh` — install them.
- `.github/workflows/linux-release.yml` — keep the Linux archive job green and consistent
  (host-side bun build, prebuilt gate, extended archive assertions; SHA-pinned actions).
- `README.md` "Dashboard: browser and desktop" section; this design;
  `impl-plans/active/riela-serve-web-client.md`.

### Out of scope

- `src-tauri/`, `web/src/**` (including `web/src/desktop/`), RielaApp's listener.
- `RielaStaticAssetResolver` / `RielaStaticSPAHTTPRouter` internals (reused verbatim).
- Adding `/api/v1/*` (bootstrap, instances, workflows sources, ops) to bare `riela serve`;
  the cli-serve subset of the dashboard is the accepted result.
- API/GraphQL semantics, auth, CORS, TLS, non-loopback binding, cutting a release,
  `scripts/build-homebrew-cask-release.sh`, `scripts/build-riela-menu-bar-app.sh`.

## Architecture

```
riela serve [--web-root DIR] [--host H] [--port P]
        │
        ▼
resolvedServeWebRoot(parsed:, locateDefault:)          (RielaCLI)
        │  explicit DIR ──► validate (throws CLIUsageError)  ──► .explicit(DIR)
        │  absent      ──► locateDefault() ─► RielaWebAssetLocator.locate()
        │                     │ nil ────────────────────────► .none
        │                     │ URL ─► validate ─ ok ───────► .located(URL)
        │                              └─ fails ────────────► .none (diagnostic, no throw)
        ▼
ServeHTTPCommand.run
        ├─ root present ─► RielaStaticSPAHTTPRouter(service: adapter, webRoot:)   (unchanged type)
        └─ root absent  ─► DeterministicServerHTTPAdapter (API only)               (unchanged type)
        ▼
ready records (stdout):  endpoint=…  webRoot=…|none  webRootSource=--web-root|auto  [webAssets=missing …]
```

Asset search order after this change (first directory containing `index.html` wins):

1. `<bundle.resourceURL>/Web` — RielaApp.app (unchanged).
2. `<resolved exe dir>/../Resources/Web` — RielaApp.app fallback and DMG layout (unchanged,
   now symlink-resolved).
3. `<resolved exe dir>/../share/riela/web` — **new**: the Homebrew formula / CLI archive layout.
4. `<cwd>/web/dist` — repo checkout with a fresh `bun run build` (unchanged).

### Why `share/riela/web`

Homebrew installs a formula into `#{prefix} = <Cellar>/riela/<version>/` and links
`/opt/homebrew/bin/riela -> ../Cellar/riela/<version>/bin/riela`. `pkgshare` is
`#{prefix}/share/riela`. Staging the assets at `./share/riela/web/` inside the tarball and
installing them with `pkgshare.install "share/riela/web"` lands them at
`#{prefix}/share/riela/web`, i.e. exactly `<bin>/../share/riela/web` relative to the *real*
binary. Because the locator resolves the executable symlink first (F3), the candidate
resolves to the Cellar path and the assets are found. The same tarball layout is used for the
Linux archives (`tar -xzf … -C <root>; install bin/riela` keeps `share/riela/web` next to
`bin/` when the whole tree is copied, and the cwd fallback remains for other installs).

## Component design

### `RielaWebAssetLocator` (`Sources/RielaServer/RielaLocalHTTPServer.swift`)

```swift
public enum RielaWebAssetLocator {
  /// Relative candidates tried from the resolved executable's directory, in order.
  public static let executableRelativeCandidates = ["../Resources/Web", "../share/riela/web"]

  public static func locate(
    bundle: Bundle? = .main,
    executableURL: URL? = Bundle.main.executableURL,
    currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) -> URL? {
    candidates(bundle:executableURL:currentDirectoryURL:).first { hasIndex($0) }
  }

  /// Exposed for tests and for the ready-output diagnostic; same order as `locate`.
  public static func candidates(bundle:executableURL:currentDirectoryURL:) -> [URL]
}
```

- `executableURL` is normalised as
  `executableURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()`
  before appending each relative candidate, then `.standardizedFileURL` again. Resolving a
  non-symlink is the identity, so direct invocation, `.build/debug/riela`, and the `.app`
  bundle (`Contents/MacOS/RielaApp` → `Contents/Resources/Web`) behave as before.
- `bundle` becomes `Bundle?` (default `.main`) so tests can pass `nil` hermetically. All
  existing callers use the default → source compatible.
- `hasIndex` keeps the existing check (`index.html` exists). Deeper validation stays in the
  CLI, as today for RielaApp.
- Nothing else in this file changes; the `#if canImport(Network)` boundary stays where it is.

### `ServeHTTPCommand` (`Sources/RielaCLI/ServeHTTPCommand.swift`)

```swift
enum ServeWebRootSource: String, Sendable { case explicit = "--web-root", located = "auto" }

struct ServeWebRootResolution: Equatable, Sendable {
  var root: URL?                       // nil ⇒ API only
  var source: ServeWebRootSource?      // nil ⇒ API only
  var diagnostic: String?              // set only when root == nil
  static let unavailable: ServeWebRootResolution  // root nil, source nil, default diagnostic
}

/// `locateDefault` is the discovery seam; production passes `RielaWebAssetLocator.locate`.
func resolvedServeWebRoot(
  parsed: ParsedParityOptions,
  locateDefault: () -> URL? = { RielaWebAssetLocator.locate() }
) throws -> ServeWebRootResolution

/// The existing readable-directory + regular-`index.html` + no-escape check, factored out.
/// Throws the unchanged CLIUsageError("--web-root requires a readable directory containing index.html").
private func validatedServeWebRoot(_ raw: String) throws -> URL

struct ServeHTTPCommand: Sendable {
  var locateWebAssets: @Sendable () -> URL? = { RielaWebAssetLocator.locate() }   // test seam
  static func readyRecords(endpoint: String, webRoot: ServeWebRootResolution) -> [String]
}
```

Resolution rules (decisions D1–D4):

- **D1 explicit wins.** Non-empty trimmed `--web-root` → `validatedServeWebRoot` →
  `.explicit(root)`. Any failure throws exactly the existing `CLIUsageError`; `locateDefault`
  is not called.
- **D2 default discovery.** Absent/blank `--web-root` → `locateDefault()`. `nil` →
  `.unavailable`. A URL → the same `validatedServeWebRoot` check (readable dir, regular
  readable `index.html`, not escaping the root). Passing → `.located(root)` (symlink-resolved
  path, like the explicit case).
- **D3 never block startup on discovery.** If the located directory fails validation, do not
  throw: return root `nil` with `diagnostic` naming the rejected path. Only the explicit path
  is allowed to fail the command.
- **D4 ready output is the contract.** `readyRecords` (now `static`, unit-testable) emits:
  - served: `endpoint=<url>`, `webRoot=<path>`, `webRootSource=--web-root|auto`
  - API only: `endpoint=<url>`, `webRoot=none`,
    `webAssets=missing; serving the API only. Build the dashboard with 'cd web && bun run build' or pass --web-root <dir>`
    (when D3 rejected a candidate: `webAssets=rejected <path>; serving the API only. …`).
  `endpoint=` stays first; records remain `key=value` strings so `--output json|jsonl`
  consumers keep working (F1). Nothing parses `webRoot=` today (F11).

`run` is otherwise unchanged: with a root it constructs `RielaStaticSPAHTTPRouter(service:
adapter, webRoot:)`, without one it uses the adapter directly. `EntryPoint.swift:25` keeps
`ServeHTTPCommand()` (default locator).

### `scripts/build-homebrew-release.sh`

- Add `require_command()` and `build_web_assets()` **verbatim in shape** from the cask script
  (F9): `cd web; bun install --frozen-lockfile; bun run lint; bun run typecheck; bun run test;
  bun run build`, then `test -s "$repo_root/web/dist/index.html"`.
- `main()`: when not `--dry-run`, before the target loop:
  `if [[ "${RIELA_WEB_ASSETS_PREBUILT:-}" == "1" ]]; then test -s "$repo_root/web/dist/index.html"; else build_web_assets; fi`.
  The env gate exists for containers without bun (F10); the hard assert is never skipped.
- `build_target()`: after copying the binary, `mkdir -p "$work_dir/share/riela/web"`,
  `cp -R "$repo_root/web/dist/." "$work_dir/share/riela/web/"`, then
  `test -s "$work_dir/share/riela/web/index.html"`. Source maps ship as-is (parity with the
  cask; D7).
- `print_plan()` prints `staged web assets: $work_dir/share/riela/web` and the prebuilt gate
  state; `usage()` documents `RIELA_WEB_ASSETS_PREBUILT`.
- Resulting archive layout: `./bin/riela`, `./README.md`, `./share/riela/web/index.html`,
  `./share/riela/web/favicon.svg`, `./share/riela/web/assets/*`.

### `Formula/riela.rb` and `scripts/render-homebrew-formula.sh`

Both the committed formula and the renderer heredoc change identically (F8):

```ruby
def install
  bin.install "bin/riela"
  pkgshare.install "share/riela/web"          # => #{prefix}/share/riela/web
end

test do
  assert_match "Usage:", shell_output("#{bin}/riela --help")
  assert_path_exists pkgshare/"web/index.html"
  … (existing addon-smoke block unchanged)
end
```

Version/sha lines in `Formula/riela.rb` are **not** touched (no release is cut); only the
`install` and `test` blocks change so the committed formula matches the renderer output.

### `.github/workflows/linux-release.yml` (D6)

Keep the Linux archive consistent with macOS instead of declaring it binary-only:

1. New host step before the docker build, using `oven-sh/setup-bun` pinned by commit SHA
   (look up the current SHA for its latest release at implementation time; never a tag):
   `cd web && bun install --frozen-lockfile && bun run lint && bun run typecheck && bun run test && bun run build && test -s dist/index.html`.
2. Pass `-e RIELA_WEB_ASSETS_PREBUILT=1` into the swift container's `docker run`.
3. Extend "Verify Linux x64 CLI archive" with
   `tar -tzf "$archive" | grep -Fx './share/riela/web/index.html'`.
4. Extend the clean-Ubuntu smoke test: after extraction,
   `test -s /tmp/riela-install/share/riela/web/index.html`.

Permissions stay `contents: read` at the top level / `write` only for the upload job as
today; no new secrets; follow the `secure-github-action` skill (SHA pinning, minimal
permissions, no script injection from inputs).

### `README.md`

Update the "Dashboard: browser and desktop" paragraph: `riela serve` now serves the
dashboard by default from (in order) the app bundle, `<bin>/../share/riela/web` (Homebrew),
or `./web/dist`; `--web-root` overrides; without assets it serves the API only and prints
`webRoot=none` + `webAssets=missing …`; the cli-serve mode still hides Settings/Command deck
and Instances/Run logs need RielaApp (F7). State plainly which views work, based on the
run's HTTP evidence.

## Data flow (request)

1. Browser `GET /` → `RielaLocalHTTPServer` → `RielaStaticSPAHTTPRouter.response` → not a
   service path → `RielaStaticAssetResolver` serves `<root>/index.html`
   (`text/html; charset=utf-8`, `no-cache`, existing CSP `connect-src 'self'`).
2. `GET /assets/index-<hash>.js` → asset with immutable cache header.
3. `GET /healthz`, `GET /overview`, `POST /graphql`, `GET /api/v1/bootstrap` → service
   (`DeterministicServerHTTPAdapter`) → unchanged JSON (`/api/v1/*` → 404, F6).
4. Unknown extension-less path (`/workflows`) → SPA fallback `index.html`; unknown concrete
   asset → 404 (F5).
5. API-only mode: identical to today — `GET /` returns the overview JSON.

## State transitions

`ServeHTTPCommand.run`: parse → resolve web root (D1–D3) → start in-process listener → bind
→ print ready records (D4) → sleep until SIGINT/SIGTERM cancellation → stop server → shut
down listener. No new states; the only new branch is the `.located` source and the
`diagnostic` text. Discovery happens exactly once at startup; a `web/dist` that appears
later requires a restart (same as RielaApp).

## Error handling

| Situation | Behaviour |
| --------- | --------- |
| `--web-root` missing dir / unreadable / `index.html` absent, a directory, or a symlink escaping the root | unchanged `CLIUsageError("--web-root requires a readable directory containing index.html")`, usage exit code, no server started |
| No candidate has `index.html` | start API-only; `webRoot=none`, `webAssets=missing; …` |
| Candidate found but fails validation (e.g. unreadable, `index.html` is a directory) | start API-only; `webAssets=rejected <path>; …` (D3) |
| Asset dir removed while running | resolver returns 404 / no SPA fallback — same as explicit `--web-root` today |
| Port in use / invalid host | unchanged existing errors |

## Compatibility and regression guarantees

- RielaApp: candidates 1–2 unchanged in order; symlink resolution is a no-op for the `.app`
  layout; `EntryPoint+WebServer.swift` untouched. Menu-bar/cask scripts untouched.
- Tauri desktop app: probes only `/healthz` and `/api/v1/bootstrap` (F11); both unchanged.
  `cargo test` in `src-tauri` and `cd web && bun run build` are run as non-regression.
- Behaviour change to document: when assets are found, `GET /` returns `index.html` instead
  of the overview JSON; `/overview` keeps the JSON (F5/F6). Nothing in the repo depends on
  `GET /` JSON.
- Ready output gains records; `--output json|jsonl` shape (`records: [String]`) unchanged.
- Blank `--web-root ""` now means "discover" rather than "API only" — documented, no known
  caller passes it.
- Linux: `Bundle.main.executableURL` comes from `/proc/self/exe` in swift-corelibs-foundation
  (already resolved); `resolvingSymlinksInPath()` is harmless there. Not locally verifiable;
  the linux-release job is the check.

## Security

- Loopback only; no CORS/TLS/auth/network changes. The static resolver's path guards
  (`GET //`, NUL, `%00`, `..`, backslash, symlink escape) are reused untouched — no new
  indexing on request paths anywhere (constraint from the historical force-unwrap crash).
- Discovery adds one filesystem location (`../share/riela/web`) next to the binary and keeps
  the `cwd/web/dist` fallback that RielaApp already has. Running `riela serve` inside an
  untrusted directory containing `web/dist/index.html` would serve those files on loopback to
  the local user — the same trust model as `--web-root` and RielaApp today; the ready output
  always prints the exact `webRoot=` in use so it is visible.
- No secrets; the formula gains no network access; CI actions SHA-pinned.

## Test strategy

Swift (macOS, `swift test --filter 'RielaWebAssetLocatorTests|ServeHTTPCommandTests|RielaHTTPRoutingAndStaticAssetTests'`):

`Tests/RielaServerTests/RielaWebAssetLocatorTests.swift` (new; `bundle: nil` for hermeticity, temp dirs under `FileManager.default.temporaryDirectory`, cleaned in `defer`):
1. `testSymlinkedExecutableResolvesToInstalledShareLayout` — create `cellar/bin/riela`
   (empty file), `cellar/share/riela/web/index.html`, `link/riela -> ../cellar/bin/riela`;
   `locate(bundle: nil, executableURL: link/riela, currentDirectoryURL: emptyDir)` returns
   the cellar share dir (resolved path). Also assert that the *unresolved* location
   (`link/../share/riela/web`) does not exist, proving resolution is what made it work.
2. `testResourcesWebWinsOverShareAndCwd` — precedence 2 > 3 > 4 with all three present.
3. `testShareLayoutFoundForDirectInvocation` — non-symlinked exe still finds
   `../share/riela/web`.
4. `testFallsBackToCurrentDirectoryWebDist` and `testReturnsNilWhenNothingHasIndex`.
5. `testCandidatesOrderIsStable` — `candidates(...)` order equals the documented list.

`Tests/RielaCLITests/ServeHTTPCommandTests.swift` (extend; keep the existing explicit-root test, adjusting to `.root?.path`):
6. `testExplicitWebRootWinsOverDiscovery` — `--web-root A`, `locateDefault` returns B (and
   must not be called) → `.explicit`, root A.
7. `testDefaultWebRootUsesLocatedAssets` — no flag, locator returns valid dir → `.located`.
8. `testDefaultWebRootIsUnavailableWhenNothingLocated` — locator `nil` → root nil,
   source nil, diagnostic contains `missing`.
9. `testLocatedWebRootFailingValidationDoesNotThrow` — locator returns dir whose
   `index.html` is a directory → root nil, diagnostic contains `rejected` and the path.
10. `testReadyRecordsDescribeWebRootState` — three record shapes from D4, `endpoint=` first.
11. `testBareServeServesLocatedSPAAndAPI` (live, `#if canImport(Network)`): temp root with
    `index.html` + `assets/app.css`; `ServeHTTPCommand(locateWebAssets: { root })`
    `.run(["serve","--port","<free>"], onReady:)` in a `Task`; wait on `ReadyOutputBox`;
    `curl /` → body is the HTML; `curl /assets/app.css` → 200; `curl /healthz` → JSON
    `{"service":"riela","status":"ok"}`; ready output contains `webRootSource=auto`; cancel
    the task and await it. Reuses `availablePort()`/`curl(...)`/`ReadyOutputBox` (F12).
12. `testBareServeWithoutAssetsStaysAPIOnly` (live): locator `{ nil }`; ready output has
    `webRoot=none` and `webAssets=missing`; `curl /` returns the overview JSON
    (`"route":"/"`); `curl /healthz` 200.

Manual/live evidence (pasted in the run output, freshly built binary, per verificationHint):
`swift build`; `.build/debug/riela serve --port <p>` from the repo root (has `web/dist`) →
`curl -i /` HTML, `/assets/<hash>.js` 200, `/healthz` 200, `/api/v1/bootstrap` 404,
`POST /graphql` 200, ready output; same from `tmp/<task>/empty` cwd → API-only records and
JSON `/`; `--web-root web/dist` and `--web-root tmp/<task>/bad` (usage error);
`scripts/build-homebrew-release.sh --dry-run darwin-arm64` plan plus a real staging run
(`RIELA_RELEASE_DIR=tmp/<task>/dist scripts/build-homebrew-release.sh darwin-arm64`, or
`RIELA_WEB_ASSETS_PREBUILT=1` reuse) with `tar -tzf` listing showing `./share/riela/web/index.html`;
optional install simulation: extract the tarball to `tmp/<task>/prefix`, symlink
`tmp/<task>/bin/riela -> ../prefix/bin/riela`, run `serve` through the symlink and show
`webRootSource=auto` with the prefix path; `mise run desktop:test`; `cd web && bun run build`;
`bash -n` on both scripts and `ruby -c Formula/riela.rb`.

Which dashboard views work under `riela serve` must be stated from evidence: expect shell +
navigation (Settings/Command deck hidden), GraphQL-backed content live, Instances/Run
logs/Workflows-sources showing ErrorBanner (F7). Do not claim the full dashboard.

## Rollout

No version bump, no release. Effective immediately for source builds; the formula/renderer
change takes effect at the next `scripts/render-homebrew-formula.sh` + release; the Linux
workflow change is exercised by the next `v*` tag or a `workflow_dispatch` run. Existing
installed binaries are unaffected. Rollback = revert the commits on the branch.

## Edge cases

- `GET //`, `///`, NUL, `%2e%2e`: handled by the reused resolver (tests exist).
- `--web-root` given as a symlink → validated and stored as the resolved path (existing).
- `web/dist` present but partial (only `index.html`): served as-is; assets 404 — user error,
  visible via `webRoot=`.
- Executable invoked via a relative path or via `PATH` symlink: `Bundle.main.executableURL`
  is absolute in both cases (F3); resolution handles the symlink.
- Formula built from source (not our path) is unaffected; `pkgshare.install` fails loudly if
  the archive lacks `share/riela/web`, which the script asserts before tarring.
- `RIELA_WEB_ASSETS_PREBUILT=1` with a stale `web/dist`: accepted by design (the caller
  opted in); local release builds should not set it.
- `--dry-run` never runs bun (parity with the cask script).

## Alternatives considered

| Alternative | Verdict |
| ----------- | ------- |
| Keep `--web-root` mandatory and only document it | Rejected: does not meet the operator requirement or AC2 |
| Embed `web/dist` into the Swift binary as resources (SwiftPM `resources:`) | Rejected: RielaCLIExecutable currently has no resource bundle; adds bundle-lookup complexity on Linux/static-stdlib builds and duplicates what the locator already solves; larger change than the work package |
| Stage assets at `lib/riela/web` or `bin/../Resources/Web` for Homebrew | Rejected: `Resources/` beside `bin/` is not Homebrew-idiomatic; `share/riela` (`pkgshare`) is the FHS/Homebrew convention and keeps one extra locator candidate |
| Throw when a located directory fails validation | Rejected (D3): default discovery must never prevent `riela serve` from starting |
| Declare Linux archives binary-only | Rejected (D6): the script would otherwise fail in the bun-less swift container, breaking the release job; a prebuilt gate plus host-side bun keeps one layout everywhere. Fallback if the CI change proves problematic: keep the gate, document Linux as binary-only |
| Strip `*.js.map` from the shipped assets | Deferred (D7): ship as-is for parity with the cask; revisit if archive size matters |
| Second locator/static router inside RielaCLI | Rejected by constraint; reuse is mandatory |

## Design review record

- Analysis evidence: this design's F1–F13 come from the fable-analysis step of
  `fable-and-improve-opus-session-49` (no prior knowledge-base entries for
  `web-asset-locator`).
- Decisions D1–D7 map to acceptance criteria: D1/D2 → AC2, AC3; D3/D4 → AC4; locator
  symlink resolution → AC5; script/formula/CI → AC6; tests → AC7; compatibility section →
  AC8, AC9.
