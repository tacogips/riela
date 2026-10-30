# ssg2-06 default retention review and isolation — in progress

Design alignment: §4.1–4.6 and §11; no dependencies in dispatch. Review and formal acceptance remain downstream.

Implemented: `runIfApplicable` accepts an injected current directory; added `RielaCLIIsolatedEnvironment` with complete captured environment; replaced three additive compact overrides and isolated the compact test runner helper. Added a partial-policy test for configured messages and default results/logs.

Remaining: isolate all remaining direct CLI, runner and hook calls listed by the §11 audit, including StorageCompactCommandTests, StorageDoctorCommandTests, AutomaticRetentionTests, GarbageCollectionCommandTests and terminal retention tests. Verify temporary project paths. Add missing behavioral coverage for automatic environment opt-out with manual pruning and generated-sweep override; confirm each design §4.6 rule 1–7 with passing test names. Execute the selection, normal and conflicting-HOME tests with matching positive counts, and required build and lint gates.

Verification on moving shared tree: `build.log` exits 1 because `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` exposes internal `RuntimeReducedPayload` from a public extension; this file and `RuntimePayloadFragmentEncoder.swift` belong to another plan. No sibling files were edited. `lint-changed.log` exits 0 for the four Swift files edited here. Both logs and per-edit intent records are under `tmp/ssg2/ssg2-06-default-retention-review-isolation/`. Resume when the sibling compilation error is repaired; rerun all required gates on the resulting tree.

## Integration feedback continuation

IR-SSG2-06-APP-TEST-SCOPE: replaced the obsolete empty-target/no-state assertions with `testMissingConfigurationAppliesBuiltInDefaults`, which checks the user target, results/logs default provenance, a one-day-old retained log and home containment. The request keeps its explicit temporary HOME. Post-edit SHA-256: `d2907f1518cc1a590f4a0dce9bd5b4ed98611861bba8b8d14b088e1a9613d48f`. Behavioral confirmation remains pending.

The earlier UF-03 access-control failure was resolved in `tmp/ssg2/reconcile-wave-001/build.log` (exit 0). A fresh build on the moving shared tree now fails in sibling-owned `Sources/RielaCLI/StorageMaintenanceConversion.swift:141` (throwing operator without `try`): `tmp/ssg2/ssg2-06-default-retention-review-isolation/continuation2-build.log`, exit 1. This plan must not edit that file. Changed-file lint for the app test passed: `continuation2-lint.log`, exit 0. The selected list, both test gates and plan lint remain to be run after the sibling fix; the rule mapping and isolation audit above remain incomplete. Formal review remains downstream.

## Redispatch continuation

The scope amendment is present in the active plan and dispatch. The previous empty-target/no-state app expectation was replaced by `testMissingConfigurationAppliesBuiltInDefaults`, asserting a user target, default results/logs sources, retention of a one-day-old log and temporary-home containment. UF-03 was resolved by the combined-tree build (`tmp/ssg2/reconcile-wave-001/build.log`, exit 0).

Design §4.6 review, passing in `test-final2.log`:

1. Default policy: `RielaRetentionConfigurationTests.testEffectiveDefaultsAndPartialPolicies`, `GarbageCollectionCommandTests.testDefaultDryRunReportsSourcesAndText`.
2. Per-category fill and workflow IDs: `RielaRetentionConfigurationTests.testEffectiveDefaultsAndPartialPolicies`.
3. Opt-outs and manual pruning: `RielaRetentionServiceTests.testEnvironmentDisablesAutomaticButManualPrunesDefaultAge`, `testAutomaticPolicyCanBeDisabled`, `testResultsKeepForeverLeavesSessionsAndMessagesWhileLogsPrune`.
4. Flag source: `GarbageCollectionCommandTests.testDefaultDryRunReportsSourcesAndText`.
5. Generated sweep: `RielaRetentionServiceTests.testAutomaticWithoutPolicyUsesDefaultsAndSkipsGeneratedSweep`, `testResultsMaxAgePrunesGeneratedSnapshotWithoutInformationalFailure`, `GarbageCollectionCommandTests.testResultsAgeStillCollectsOnlyAgedEventReceipts`.
6. Dry run: `GarbageCollectionCommandTests.testDefaultGCDryRunAndApplyOldFamily`, `RielaRetentionServiceTests.testDryRunDoesNotDeleteOrWriteThrottleStamp`.
7. Default protection and age: `RielaRetentionServiceTests.testDefaultRetentionProtectsResumableAndLockedSessions`, `testDefaultAgePrunesOldTerminalAndFollowsMessages`.

Isolation: automatic hook calls and workflow runner use captured HOME and injected project; doctor calls use the isolated helper; compact direct calls and JSON helper use captured environments and temporary stores; gc helper captures HOME/PATH/TMPDIR; terminal prune calls use captured environments. Direct retention requests use explicit dictionaries and homes. Other audited occurrences of currentDirectoryPath construct temporary fixtures or locate examples. Per-edit intentions and pre-edit snapshots, and post-edit SHA-256, are under this plan's evidence directory.

On the moving shared tree: `build-final.log` and `selection-final.log` exit 0; `selected.txt` excludes RunEndStorageMaintenance. `test-final2.log` exits 0, 260 tests, zero failures. `lint-final.log` and `lint-changed-final2.log` exit 0. The conflicting-HOME result is recorded separately. Formal review and integration remain downstream.

Conflicting-HOME verification: `isolation-final2.log` exits 0 with 260 tests and zero failures; the renamed app test passes in both runs. The counts and class-anchored filters match.

Exact manifest gates on the moving tree: `build.log` exit 0, `selection-final.log` exit 0, `test.log` exit 0 (260 tests, 0 failures), `isolation-proof.log` exit 0 (260 tests, 0 failures), and `lint.log` exit 0. Strict changed-file lint via `changed-swift-all.nul` exits 0 in `lint-all-changed.log`.
