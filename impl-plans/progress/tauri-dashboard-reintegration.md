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

## Remaining finalization

- Complete the merge commit with `feat/tauri-dashboard-app` as second parent.
- Reconcile the integration branch with the current main tip, which advanced
  after the accepted design recorded base `77616b5`.
- Re-run the documentation-only tree audit and push only
  `integrate/tauri-dashboard-app`.
