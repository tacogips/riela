# sac-03 implementation progress

- Implemented shared nonisolated profile source discovery, selected-source resolution, session-store path, and bounded executions list/detail projections. Web list delegates while preserving its 404 and JSON shape.
- Added isolated `/tmp/rac-<8hex>` tests for profile discovery, storage override, selected and unknown sources, session path, revision, and missing detail.
- Required `swift build --build-tests`: exit 1; `tmp/serverless-app-control/sac-03-sources-and-projection/build.log`. Only compiler errors reported in sibling `Tests/RielaAppSupportTests/RielaAppControlContractTests.swift:52-53` (throwing calls lacking `try`). The required `swift test --skip-build` cannot run against a completed current build until that file is repaired; rerun build then test on the stable shared tree.
- Scoped strict SwiftLint exit 0: `tmp/serverless-app-control/sac-03-sources-and-projection/strict-lint-final.log`; plan lint exit 0: `tmp/serverless-app-control/sac-03-sources-and-projection/lint.log`; unchanged App and existing projection test diff exit 0: `tmp/serverless-app-control/sac-03-sources-and-projection/unchanged.log`.
- Source SHA-256: discovery `351fcf7f4aae4e2416047ac1ad9a1e84b7e3cfe8449b4c170395835cf2d21ab5`; executions `2d885d966f7e82bd3a483cfab5d494a82c4539ed94caaede5a78066c09a78d56`; web projection `0a9e2cf7e6713acf96f1f853ece158a4cc1b294376a21204d596f454362222a0`; tests `c04e351fccebbb0c3847f02066f31a0f1f912251c6428f8e68bac63de4039b1f`.
- Formal reviews, serial integration, App wiring (sac-06), commit and push remain downstream.

## Verification retry

- The sibling compile blocker was repaired. `swift build --build-tests` exited 0: `tmp/serverless-app-control/sac-03-sources-and-projection/build-retry.log`.
- The required selected `swift test --skip-build` exited 0, with 21 tests and 0 failures: `tmp/serverless-app-control/sac-03-sources-and-projection/test-retry.log`.
- Plan lint and strict changed-file lint exited 0: `lint-retry.log` and `strict-retry.log` in the same evidence directory. The unchanged-file diff exited 0: `unchanged-retry.log`.
- All four source hashes above still match. Verification was on the shared Wave 1 tree; formal review and serial integration remain downstream.
