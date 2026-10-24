# ar-09-app-legacy-removal implementation progress

Plan: `impl-plans/completed/automatic-retention-09-app-legacy-removal.md`
Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number)
Workflow mode: `issue-resolution`
Codex agent: `/root`, Step 6 implementation
Branch: `feat/automatic-retention`

## Implementation

All assigned implementation criteria are complete. RielaApp constructs its automatic request exclusively from `appHomeDirectory`, `launchOptions.projectRoot`, and `launchOptions.environment`; the request uses `.all`, has no explicit session store, no overrides, and is not a dry run. A retained `RielaRetentionScheduler` runs immediately and periodically. Each failed target logs only its first warning with the `RielaApp retention warning:` prefix; thrown errors use the same prefix. Tests exercise the pure request builder and service on temporary roots under repository `tmp/` without constructing `RielaApp`.

Removed `EntryPoint+GarbageCollection.swift`, `RielaGarbageCollectionConfiguration`, the obsolete generated-sweep diagnostic, and the two configuration-specific collector tests. The remaining collector sweep tests were preserved. Search confirms neither removed symbol remains under `Sources` or `Tests`.

## Changed files and source hashes

- `Sources/RielaApp/EntryPoint+GarbageCollection.swift` — deleted.
- `Sources/RielaApp/EntryPoint+Retention.swift` — `0eff8e0119af7079a7d2fd6ff2c730443aba4b9f5135f77299c7e7f64334c5a5`
- `Sources/RielaApp/EntryPoint.swift` — `cdf4b5dbcf0124c9f5ef7fa35eec794b377cea769d95c7f20d3c0a87ab4ca25d`
- `Sources/RielaCore/RielaDataGarbageCollector.swift` — `f45961c26a40bdc80995a472721c8dd2dc2c4fc2960868ebf524aa0deb7ae10a`
- `Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift` — `b223a5921b24fdac9060680b0ce818b13177978579b634548c783e1d45181d5b`
- `Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift` — `8c2e05d90beaa4f05e52d4e5b6901997a2aa6238de911aa0b8ba905b4b86f633`
- `impl-plans/progress/ar-09-app-legacy-removal.md` — progress record; hash omitted because this file records its own implementation state.

## Verification

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppRetentionStartTests|RielaDataGarbageCollectorTests|RielaDataGarbageCollectorHandoverTests" > tmp/automatic-retention/ar-09-app-legacy-removal/test-retry-001.log 2>&1'` | 0 | 10 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/test-retry-001.log` |
| `arch -arm64 /bin/zsh -lc 'swift build --product RielaApp > tmp/automatic-retention/ar-09-app-legacy-removal/build.log 2>&1'` | 0 | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/build.log` |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-09-app-legacy-removal/changed-swift-files.nul` (Xcode Swift toolchain PATH) | 0 | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/swiftlint.log` (empty) |
| `grep -rn "RielaGarbageCollectionConfiguration\\|startGarbageCollection" Sources Tests` | 1 (expected no matches) | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/legacy-symbol-search.log` (empty) |
| `test ! -e Sources/RielaApp/EntryPoint+GarbageCollection.swift` | 0 | 0 | 0 | legacy app file absent |
| `grep -n 'startRetention()' Sources/RielaApp/EntryPoint.swift` | 0 | 0 | 0 | match at line 91 |

The initial focused-test attempt exited 1 during compilation because the new test file had not explicitly imported `RielaCLI`; it ran 0 tests. The complete log is `tmp/automatic-retention/ar-09-app-legacy-removal/test.log`. Added the module import and reran the same suite successfully; the passing source-matched result is the retry above.

## Handoff

Implementation-phase work for this assigned plan is complete. Formal test-integrity/adversarial/integration review and serial finalization remain downstream workflow steps; no approval, staging, commit, or push is claimed here.

## Review-feedback disposition and current-source rerun

The removed `testConfigurationDefaultsToDisabledAndSupportsEnvironmentOverride` and `testConfigurationFileEnablesRetention` exercised `RielaGarbageCollectionConfiguration`, which this plan removes with no compatibility alias. Their behavior is no longer part of the supported configuration surface. Replacement coverage lives in `Tests/RielaCLITests/RielaRetentionServiceTests.swift` (policy parsing and policy execution) and `Tests/RielaCLITests/GarbageCollectionCommandTests.swift` (`testRemovedConfigurationKeyIsUsageError` and `testRemovedRetentionDaysFlagIsRejected`). The collector's four remaining sweep tests were preserved and rerun. This is implementation evidence for downstream test-integrity/adversarial review, not a typed reviewer approval.

Current-source verification after review feedback:

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppRetentionStartTests|RielaDataGarbageCollectorTests|RielaDataGarbageCollectorHandoverTests" > tmp/automatic-retention/ar-09-app-legacy-removal/test-review-rerun-final.log 2>&1'` | 0 | 10 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/test-review-rerun-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift build --product RielaApp > tmp/automatic-retention/ar-09-app-legacy-removal/build-review-rerun.log 2>&1'` | 0 | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/build-review-rerun.log` |
| `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-09-app-legacy-removal/changed-swift-files-review.nul` | 0 | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/swiftlint-review-rerun.log` |
| `grep -rn 'RielaGarbageCollectionConfiguration\\|startGarbageCollection' Sources Tests` | 1 (expected no matches) | 0 | 0 | `tmp/automatic-retention/ar-09-app-legacy-removal/legacy-symbol-search-review.log` |

The first rerun's Swift test process passed all 10 tests, but its outer zsh wrapper returned 1 because it assigned to zsh's read-only `status` variable. Its full output is preserved at `tmp/automatic-retention/ar-09-app-legacy-removal/test-review-rerun.log`; the corrected wrapper rerun above returned 0. Formal typed test-integrity and adversarial decisions remain downstream.
