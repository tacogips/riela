# Tauri Dashboard Re-integration Progress

**Status**: Implemented and verified with named repository-baseline gaps
**Evidence root**: `tmp/tauri-dashboard-reintegration-20260921/plans/tauri-dashboard-reintegration/attempt-1/`

## Resolution evidence

- The merge stopped at the expected 14 paths; all were resolved per-file to
  the pre-merge main content.
- `git ls-files -u` is empty and `MERGE_HEAD` is
  `d2c69918a14c68791afbffaa64fc0e3def5d0c1a`.
- Superseded artifacts are absent: `src-tauri/`, root `Cargo.toml`, root
  `Cargo.lock`, and `web/src/desktop/`.
- The only staged merge-result paths before the integration brief/progress
  record were the two research briefs, two superseded designs, and two moved
  completed plans.

## Static checks

```text
git diff --check
exit=0

git grep -n -E '^(<{7} |>{7} |\|{7} )'
exit=1 (no tracked conflict markers)

test ! -e src-tauri && test ! -e Cargo.toml &&
  test ! -e Cargo.lock && test ! -e web/src/desktop
exit=0

git grep -n 'riela_fetch\|requestThroughHost\|setHostTransport\|installDesktopHost' -- web/src Sources
exit=1 (no matches)
```

The plan's broader route-string command did not have its expected result:

```text
git grep -n 'api/v1/instances\|api/v1/ops/overview' -- web/src
exit=0
```

Its matches are comments, regression-test literals, the supported instance
creation mutation, action/execution subroutes, and their transport tests. They
are not the deleted console GET reads. Stronger behavioral evidence passed:
`web/src/console/client.test.ts` proves all three console reads use `/graphql`;
`SurfaceParityConsoleReadTests` and `SurfaceParityWebAPITests` prove the GraphQL
surface and deleted GET routes; and `ServeWebHostTests` executes the console
read documents over GraphQL.

## Verification transcript summary

| Gate | Result | Log |
| --- | --- | --- |
| `arch -arm64 ... swift build` | PASS; build completed | `swift-build.log` |
| `swift test --filter RielaWebAssetLocatorTests` | PASS, 3 tests | `swift-locator.log` |
| `swift test --filter SurfaceParity` | PASS, 46 tests, 1 skipped | `swift-surfaceparity.log` |
| `swift test --filter SurfaceCatalogTests` | PASS, 7 tests | `swift-surfacecatalog.log` |
| `swift test --filter ServeWebHost` | PASS, 9 tests | `swift-servewebhost.log` |
| `cd web && bun run typecheck && bun run lint && bun test src` | PASS, 100 tests | `web-checks.log` |
| `cargo build --locked --manifest-path web/src-tauri/Cargo.toml` | PASS | `cargo.log` |
| full `swift test` | 2,283 tests; 26 assertion failures across 15 test cases | `swift-full.log`, `swift-full-failures.log` |
| targeted rerun of five unexpected cases | three passed; two failed | `swift-unexpected-rerun.log` |

The ten expected baseline cases were the six AppKit hierarchy cases across
`RielaAppSettingsEditorNavigationTests`,
`RielaAppUXOnboardingControllerTests`, and
`RielaAppWindowContentInsetTests`; three unix-socket cleanup cases in
`WorkflowRound7AdversarialTests`; and
`WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario`.

The five unexpected full-run cases were targeted once. These three passed on
rerun:

- `testBarrierHeldServiceChildSurvivesExclusionKillAndRestartWithoutRelaunch`
- `testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect`
- `testSessionResumeCompletesBudgetFailedSessionWithRaisedMaxSteps`

These two reproduced and are retained as repository follow-up work rather than
being mixed into this documentation-only integration:

- `testSessionProgressReportsActiveStepDuringLiveSecondStep`
- `testAutoImproveCancellationDoesNotCreateIncidentOrRerun`

## Finalization evidence

- Merge commit `3cf6b91` has `feat/tauri-dashboard-app` at `d2c69918` as its
  second parent.
- The current main tip `d2e6aa60` was merged afterward because main advanced
  after the accepted design recorded base `77616b5`.
- `git diff --name-only main..HEAD` lists exactly 11 documentation/plan paths.
  The accepted plan's ten-path audit list omitted its own dispatch manifest;
  the actual additional path is
  `impl-plans/active/tauri-dashboard-reintegration-20260921-dispatch.json`.
  No `Sources/`, `Tests/`, `web/`, `scripts/`, `.github/`, Cargo, or
  `src-tauri` path differs from current main.
- The remaining publication action at this checkpoint was a non-force push of
  only `integrate/tauri-dashboard-app`.

## 2026-09-23 main rebase-point audit

- Merged main at `9ab2e22936ee7a326c3b61ddb6667e54141e9b8b` into the clean
  integration branch without conflicts. This retained all intervening main
  changes, including Riela 0.1.49.
- `git diff --name-only main...HEAD` still contains exactly the 11 historical
  documentation/plan paths listed above. No runtime, test, web, script, or
  release file is changed by integrating this branch.

## 2026-09-23 current-main residual-test check

On main at `8328e4e`, an ARM64 focused rerun of
`testSessionProgressReportsActiveStepDuringLiveSecondStep` and
`testAutoImproveCancellationDoesNotCreateIncidentOrRerun` passed: 2 tests,
0 failures. The command output is retained at
`tmp/tauri-reintegration-current/residual-tests.log` in the current checkout.
This resolves the earlier isolated reproductions on the present tree, but is
not a fresh full-suite result; the plan's full-suite completion criterion
remains unverified on current main.

## 2026-09-23 current-main ARM64 full suite

On main at `e46eab6`, `/usr/bin/arch -arm64` with the Xcode Swift toolchain
ran the full `swift test --quiet` suite to completion. The process exited 1:
2,393 XCTest cases ran, 2 were skipped, and 6 cases produced 11 assertion
failures (including 1 unexpected XCTest failure). The separate Swift Testing
run passed 17 tests. Full output is retained at
`tmp/tauri-reintegration-current/full-suite.log` in this checkout.

All six failing cases are among the ten baseline cases named above: one in
`RielaAppSettingsEditorNavigationTests`, four in
`RielaAppUXOnboardingControllerTests`, and one in
`RielaAppWindowContentInsetTests`. No unix-socket cleanup or package app
environment case failed in this run. Both cases previously retained as
unexpected follow-ups passed in the full suite:
`testSessionProgressReportsActiveStepDuringLiveSecondStep` and
`testAutoImproveCancellationDoesNotCreateIncidentOrRerun`.

This is a completed full-suite result, but not a green gate. The remaining
AppKit hierarchy failures are still unresolved, so the Tauri reintegration
plan is not claimed fully verified by the full-suite criterion.
