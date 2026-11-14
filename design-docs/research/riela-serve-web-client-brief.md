# Research brief: make `riela serve` serve the dashboard by default

Date: 2026-08-31
Branch: `feat/tauri-dashboard-app` (same branch as the Tauri desktop-app work)
Author: operator pre-run research (verified by reading the tree)

Operator requirement, in the operator's words:
「riela serve では web の client, server が動くように。そうでなければ local app で操作可能にするように」
— With `riela serve`, both the web **client** (the SPA) and the **server** (the API) must
work. When that is not the case, the dashboard must be operable through the local desktop
app instead.

The second half is already satisfied by the Tauri desktop app on this branch
(`src-tauri/src/lifecycle.rs` probes `127.0.0.1:19091` then `127.0.0.1:8787` and spawns
`riela serve` itself when neither answers). **This work package is only about the first
half.**

## 1. The verified gap

1. `Sources/RielaCLI/ServeHTTPCommand.swift:108` `resolvedServeWebRoot(parsed:)` starts with

   ```swift
   guard let raw = parsed.webRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
         !raw.isEmpty else {
     return nil
   }
   ```

   so **without an explicit `--web-root` it returns `nil`**. `ServeHTTPCommand.run` then
   uses the bare `DeterministicServerHTTPAdapter` instead of wrapping it in
   `RielaStaticSPAHTTPRouter`, i.e. the API answers but no SPA is served.
2. `RielaWebAssetLocator.locate(bundle:executableURL:currentDirectoryURL:)` in
   `Sources/RielaServer/RielaLocalHTTPServer.swift` already implements the right search
   order — `<bundle resources>/Web`, `<executable>/../Resources/Web`, `<cwd>/web/dist` —
   and is used by RielaApp, but **the CLI serve path never calls it**.
3. `scripts/build-homebrew-release.sh` stages only `<work_dir>/bin/riela` plus
   `README.md` and tars that (see the `mkdir -p "$work_dir/bin"` / `cp "$bin_path/riela"`
   / `tar -C "$work_dir"` lines). `Formula/riela.rb` does exactly `bin.install "bin/riela"`.
   **No web assets are shipped with the CLI at all**, so even an explicit `--web-root`
   has nothing to point at on an installed binary.
4. The cask (`scripts/build-homebrew-cask-release.sh`) does build and ship web assets, but
   only into `RielaApp.app/Contents/Resources/Web`. The `riela` CLI binary is staged
   beside the `.app` in the DMG, so `<executable>/../Resources/Web` does not resolve for it.

Net effect today: `riela serve` shows the dashboard **only** when it is run from a repo
checkout that has a freshly built `web/dist`, or when `--web-root` is passed a path that
happens to exist. From `brew install riela` it never does.

## 2. What "fixed" means

- `riela serve` with no `--web-root` serves the SPA whenever assets can be located,
  and keeps serving the API either way.
- `--web-root` still wins when given, and still rejects an unreadable directory or one
  without `index.html` with the existing `CLIUsageError`.
- When no assets can be located, `riela serve` still starts and serves the API, and says
  so clearly in its ready output rather than failing or silently 404ing the SPA.
- An installed `riela` (Homebrew formula) serves the dashboard out of the box.

## 3. Implementation notes and traps

- The natural fix is to fall back to `RielaWebAssetLocator.locate()` in
  `resolvedServeWebRoot` when `parsed.webRoot` is absent, then keep the existing
  validation for the explicit case. Consider whether the located directory should go
  through the same `index.html`/readability validation (it should — the locator only
  checks that `index.html` exists).
- **Symlink trap:** Homebrew links `/opt/homebrew/bin/riela` to
  `../Cellar/riela/<version>/bin/riela`. `RielaWebAssetLocator` composes
  `executableURL.deletingLastPathComponent()` and only calls `.standardizedFileURL`, not
  `.resolvingSymlinksInPath()`. Verify what `Bundle.main.executableURL` actually returns
  for a symlinked CLI invocation and resolve symlinks if needed, otherwise the shipped
  assets will not be found. Add a unit test for the symlinked-executable case.
- **Layout choice:** pick where the CLI archive puts the assets and make the locator agree.
  A Homebrew-idiomatic option is `<work_dir>/share/riela/web` in the tarball plus
  `pkgshare.install` (or `prefix.install "share"`) in `Formula/riela.rb`, which lands at
  `#{prefix}/share/riela/web`, i.e. `<executable>/../share/riela/web`. Whatever is chosen,
  add the matching candidate to `RielaWebAssetLocator` and keep the existing candidates
  working so RielaApp is unaffected.
- `scripts/build-homebrew-release.sh` must then build the web assets before staging.
  `build-riela-menu-bar-app.sh` and `build-homebrew-cask-release.sh` already contain a
  `build_web_assets()` helper (bun install --frozen-lockfile, lint, typecheck, test,
  build, then `test -s web/dist/index.html`) — reuse that shape rather than inventing a
  new one, and keep the hard assert.
- The Linux release path (`.github/workflows/linux-release.yml`, `.build-linux/`) also
  produces CLI archives; keep it consistent or explicitly out of scope with a reason.
- `RielaStaticSPAHTTPRouter` is the existing wrapper — reuse it, do not write another.
  Note the historical `GET //` force-unwrap crash in `RielaStaticAssetResolver`; do not
  reintroduce unchecked indexing on request paths.
- Loopback only. Do not add CORS, TLS, auth changes, or non-loopback binding.

## 4. Non-negotiable

1. The Tauri desktop app added earlier on this branch keeps working unchanged: it probes
   19091 then 8787 and spawns `riela serve` when neither answers. It does **not** need the
   SPA from `riela serve` (it bundles its own `web/dist`), so this change must not alter
   the API surface or the health/bootstrap endpoints it probes.
2. RielaApp (the menu-bar app, port 19091) keeps serving the dashboard exactly as today.
3. `cd web && bun run build` keeps emitting `web/dist/index.html`; both existing packaging
   scripts keep their `test -s .../web/dist/index.html` asserts.
4. `swift build` and the existing Swift test suites stay green; add tests for the new
   fallback rather than only manual evidence.
5. Do not modify unrelated files, do not rewrite history, do not open a pull request.

## 5. Live-verified fact from the desktop-app run (read this before scoping)

The `fable-and-improve-opus` run that built the desktop app probed a bare `riela serve`
live and recorded:

- `GET /healthz` → 200
- `GET /api/v1/bootstrap` → **404**
- `GET /api/v1/instances` → **404**

So the `riela serve` host answers `/healthz` and `POST /graphql`, but **not** the
RielaApp-only aggregate `/api/v1/*` endpoints. The SPA already handles this: `discoverHost`
in `web/src/App.tsx` treats a 404 from `/api/v1/bootstrap` as `mode: 'cli-serve'` and
`CLI_SERVE_HIDDEN_VIEWS` hides Settings and the command deck. There is a passing Playwright
spec named "cli-serve hides riela-app-only surfaces".

Consequence for this work package: serving the SPA from `riela serve` yields the
**cli-serve subset** of the dashboard, not the full RielaApp experience. That is expected
and acceptable. What this work package must do:

- Make the SPA actually reachable from `riela serve` (the gap in §1).
- **Determine and state honestly, with real HTTP evidence, which views genuinely work
  under `riela serve`** once the SPA is served — do not claim the full dashboard works.
- Do **not** expand `riela serve`'s API surface to close that gap; that is a separate,
  much larger change and is explicitly out of scope here.
