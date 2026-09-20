# Tauri Dashboard Re-integration Implementation Plan

**Status**: Ready
**Design Reference**: design-docs/tauri-dashboard-reintegration.md
**Created**: 2026-09-21
**Last Updated**: 2026-09-21
**planId**: tauri-dashboard-reintegration (single plan; has_feature_fanout = false)

## Design Document Reference

**Source**: design-docs/tauri-dashboard-reintegration.md

### Summary
Land `feat/tauri-dashboard-app` (d2c6991) onto main (77616b5) as one `--no-ff`
merge on `integrate/tauri-dashboard-app`. Every code intent of the branch is
already on main in a different shape (see design §2), so all 14 conflicts
resolve to main's content and the branch's cleanly-auto-merging superseded
artifacts are removed or reverted; only its docs survive (annotated). The
merged tree's code must be identical to main's.

### Scope
**Included**: merge resolution, artifact disposition, integration brief,
progress log with grep evidence, full verification, one merge commit, push of
`integrate/tauri-dashboard-app`.
**Excluded**: any behavior change vs main; SurfaceCatalog edits (no surface
changes); Tauri toolchain installation; touching main or any other worktree.

## Applicable prior knowledge
Team knowledge-base recall for "tauri-dashboard" returned 0 results. Facts
carried from the analysis step instead: (a) Swift commands need
`arch -arm64 /bin/zsh -lc` (Rosetta default shell breaks xctest dlopen);
(b) exactly ten environmental test failures are the accepted baseline (listed
in Task 6); (c) the riela/git-commit add-on refuses committedFiles paths
missing on disk except exact tracked deletions — for the moved impl-plan files
list only the new path.

## Git checkpoint (recorded before any edit)
- implementationBranch == baseBranch == `integrate/tauri-dashboard-app`
- originalHead `77616b5a26c7937431ba3f497ddffb3a4570b270` (== main tip)
- remote `origin` = https://github.com/tacogips/riela.git
- merge source `feat/tauri-dashboard-app` @ `d2c6991`; merge-base `e8cd1f2`
- Pre-existing changes: none besides this design/plan pair (authored by the
  design step; they are part of this feature's commit)

## Ordered tasks (serial; no worktrees; no parallel git)

### Task 1 — Start the merge
```
cd /Users/taco/gits/tacogips/riela-worktrees/tauri-integration
git merge --no-ff feat/tauri-dashboard-app
```
Expect it to stop with exactly the 14 conflicts from design §3.1 (verified by
`git merge-tree` dry run during analysis). If the conflict set differs, stop
and re-check `git status` before proceeding — do not improvise.

### Task 2 — Resolve all 14 conflicts to main's content
For each path in design §3.1 (list them explicitly; per-file, examined — not a
wholesale strategy flag):
```
git checkout HEAD -- <path>    # HEAD = 77616b5 during the merge
```
Paths: `.github/workflows/linux-release.yml`,
`Sources/RielaCLI/ServeHTTPCommand.swift`,
`Sources/RielaServer/RielaLocalHTTPServer.swift`,
`Tests/RielaServerTests/RielaWebAssetLocatorTests.swift`,
`scripts/build-homebrew-release.sh`, `scripts/render-homebrew-formula.sh`,
`web/bun.lock`, `web/package.json`, `web/src/api.ts`,
`web/src/config/client.ts`, `web/src/index.tsx`, `web/src/transport.test.ts`,
`web/src/transport.ts`, `web/src/workflows/client.ts`.

### Task 3 — Dispose of the auto-merged superseded artifacts (design §3.2)
Remove (staged deletions in the merge):
```
git rm -r src-tauri
git rm Cargo.toml Cargo.lock
git rm -r web/src/desktop
```
Revert to main's version (stages automatically):
```
git checkout HEAD -- web/vite.config.ts README.md mise.toml .gitignore \
  Tests/RielaCLITests/ServeHTTPCommandTests.swift
```
Keep + annotate: prepend to `design-docs/tauri-dashboard-app.md` and
`design-docs/riela-serve-web-client.md`:
```
> **Superseded 2026-09-21.** This design described a desktop shell at the
> repository root that spawned `riela serve`. Main independently shipped the
> inverse topology at `web/src-tauri/` (riela spawns the shell; GraphQL console
> reads). See design-docs/tauri-dashboard-reintegration.md and
> docs/briefs/tauri-dashboard-integration-2026-09-21.md.
```
Move (one direction only in committedFiles):
```
git mv impl-plans/active/tauri-dashboard-app.md impl-plans/completed/
git mv impl-plans/active/riela-serve-web-client.md impl-plans/completed/
```
and prepend the same supersession note to both moved files. Keep
`design-docs/research/*-brief.md` untouched.

### Task 4 — Author the integration brief and progress log
- `docs/briefs/tauri-dashboard-integration-2026-09-21.md`: what the branch
  contributed; the per-file resolution table (from design §3); explicitly that
  the branch's shell/seam/serve-default/locator/packaging were superseded by
  main's `web/src-tauri`, `rielaFetch`, `ServeWebHost` +
  `RielaWebAssetLocator`, and `riela-web-packaging.sh`; named residual risks
  (at minimum: desktop bundle not verified end-to-end; add the cargo result
  from Task 7).
- `impl-plans/progress/tauri-dashboard-reintegration.md`: paste the exact grep
  commands + outputs from Task 5 and the verification exit statuses + log
  paths from Tasks 6–7.

### Task 5 — Static evidence sweeps (record outputs in the progress log)
```
git diff --check
grep -rnE '^(<{7} |>{7} |\|{7} )' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist . ; echo "exit=$?"   # expect exit=1 (no matches)
git grep -n 'api/v1/instances\|api/v1/ops/overview' -- web/src ; echo "exit=$?"  # expect exit=1
git grep -n 'riela_fetch\|requestThroughHost\|setHostTransport\|installDesktopHost' -- web/src Sources ; echo "exit=$?"  # expect exit=1
test ! -e src-tauri && test ! -e Cargo.toml && test ! -e web/src/desktop && echo removed-ok
```

### Task 6 — Swift verification (arm64 shell, foreground, full logs)
```
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela-worktrees/tauri-integration && swift build' 2>&1 | tee /tmp/tauri-integ-swift-build.log
arch -arm64 /bin/zsh -lc '… && swift test --filter RielaWebAssetLocatorTests' 2>&1 | tee /tmp/tauri-integ-locator.log
arch -arm64 /bin/zsh -lc '… && swift test --filter SurfaceParity' 2>&1 | tee /tmp/tauri-integ-surfaceparity.log
arch -arm64 /bin/zsh -lc '… && swift test --filter SurfaceCatalogTests' 2>&1 | tee /tmp/tauri-integ-surfacecatalog.log
arch -arm64 /bin/zsh -lc '… && swift test --filter ServeWebHost' 2>&1 | tee /tmp/tauri-integ-servewebhost.log
arch -arm64 /bin/zsh -lc '… && swift build && swift test' 2>&1 | tee /tmp/tauri-integ-swift-full.log
```
Record each exit status. Never tail/truncate. The full-suite failure set must
be exactly: 6 AppKit cases in RielaAppUXOnboardingControllerTests,
RielaAppSettingsEditorNavigationTests, RielaAppWindowContentInsetTests; 3
unix-socket-unlink cases in WorkflowRound7AdversarialTests; and
WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario.
Any other failure is a defect to fix (a single suspected timing flake in the
known interleaved-submit area gets one targeted `--filter` re-run before being
treated as real).

### Task 7 — Web + best-effort desktop verification
```
cd web && bun run typecheck && bun run lint && bun test src   # tee /tmp/tauri-integ-web.log, record exits
cargo build --locked --manifest-path web/src-tauri/Cargo.toml 2>&1 | tee /tmp/tauri-integ-cargo.log
```
cargo exists (`~/.cargo/bin/cargo`). If the cargo build fails for
toolchain/environment reasons, do NOT install anything; record "desktop shell
compiles-only / unverified" (or "not even compilable here") as the named
residual risk in the brief. A cargo failure of this kind does not block the
merge; a failure caused by the merged tree does.

### Task 8 — Tree audit vs main
```
git status            # must show a clean, fully staged merge before commit
```
After committing: `git diff --stat 77616b5 HEAD` must contain ONLY:
`docs/briefs/tauri-dashboard-integration-2026-09-21.md`,
`design-docs/tauri-dashboard-reintegration.md`,
`design-docs/tauri-dashboard-app.md` (annotation),
`design-docs/riela-serve-web-client.md` (annotation),
`design-docs/research/tauri-dashboard-app-brief.md`,
`design-docs/research/riela-serve-web-client-brief.md`,
`impl-plans/active/tauri-dashboard-reintegration.md`,
`impl-plans/completed/tauri-dashboard-app.md`,
`impl-plans/completed/riela-serve-web-client.md`,
`impl-plans/progress/tauri-dashboard-reintegration.md`.
Any Sources/, Tests/, web/, scripts/, .github/, Cargo, or src-tauri path in
that diff is a resolution error — fix before commit/push.

### Task 9 — Commit and push
Complete the merge commit (message summarizes the supersession outcome; include
the standard attribution line convention used by this repo's tooling). If the
riela/git-commit add-on is used: committedFiles lists staged paths that exist
on disk plus exact tracked deletions; for the two moved plan files list ONLY
the `impl-plans/completed/` paths. Plain `git commit` completing MERGE_HEAD is
the acceptable fallback. Then:
```
git push origin integrate/tauri-dashboard-app
```
Never push main; never force push.

## Plan metadata
- **dependsOn**: none (single plan)
- **writePaths**: the 14 conflict paths (resolution only), removals
  (`src-tauri/`, `Cargo.toml`, `Cargo.lock`, `web/src/desktop/`), reverts
  (`web/vite.config.ts`, `README.md`, `mise.toml`, `.gitignore`,
  `Tests/RielaCLITests/ServeHTTPCommandTests.swift`), annotations
  (`design-docs/tauri-dashboard-app.md`, `design-docs/riela-serve-web-client.md`),
  moves (2 impl-plans files → `impl-plans/completed/`), new docs
  (`docs/briefs/tauri-dashboard-integration-2026-09-21.md`,
  `impl-plans/progress/tauri-dashboard-reintegration.md`)
- **sharedPaths**: none (single work package; no fanout)
- **acceptanceCriteria / verification**: Tasks 5–8 map 1:1 onto the workflow
  acceptance criteria; see design §6.

## Completion criteria
1. Merge commit exists on `integrate/tauri-dashboard-app` with
   `feat/tauri-dashboard-app` as second parent; `git status` clean; no
   conflict markers (Task 5 evidence).
2. Console reads GraphQL-only, retired-surface greps empty, recorded in
   `impl-plans/progress/tauri-dashboard-reintegration.md`.
3. Task 6 suites green; full-suite failures == the ten accepted environmental
   ones exactly.
4. Task 7 web checks all pass; cargo result recorded either way.
5. `git diff --stat 77616b5 HEAD` shows documentation-only delta (Task 8 list).
6. Brief exists under `docs/briefs/` with contributions, resolutions, and named
   residual risks.
7. Branch pushed to `origin integrate/tauri-dashboard-app` only.
