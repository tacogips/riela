# instance-cancel-int-01 Step 6 progress

- DR-01 implemented with read-only terminal status lookup and fail-closed fallback; rule 2 unchanged.
- Explicit overlap, oldest blocker, post-cancel relaunch, and isolated cancelled/pending/running/missing-session cases added. Session allocation order can differ from launch creation order; the blocker assertion uses the actual oldest launch.
- Evidence directory: `tmp/instance-cancel-integration/instance-cancel-int-01-busy-terminal-session/`.
- Test pre-edit SHA-256: `4b9c1e76d0dd950e56a5fd509ad549d44925196c8424634cadead5c9ecacc96b`; final: `e793cd5a70315af553b2fc9c4bd09036b4325c8e73a341a2d6a2cbf22bc0b54e`.
- Source pre-edit SHA-256: `2048ece5fb29ed660ffd20d3e10dea587aeea70accd4caba89b6956cf13a3bf5`; final: `7380eaf212049670253225e1e00a474a08c17e6a8dbef5d4e4d536a1d2d25a6e`.
- Negative control: `swift test --filter ConfiguredLaunchCancelTests/testBusyCheckIgnoresRunningLaunchWhoseSessionIsPersistedTerminal`, exit 1, 1 test, 1 expected failure (409 vs 202), `before.log`.
- Initial post-change suite exposed fixture defaults and ordering errors: exit 1, 3 tests, 2 failures, `after.log`; repaired before final verification.
- Final `swift test --filter ConfiguredLaunchCancelTests`: exit 0, 3 tests, 0 failures, `after-repair.log`.
- Final `swift test --filter 'ConfiguredRunOverlap|InstanceApp|LiveRootSession'`: exit 0, 26 tests, 0 failures, `overlap.log`.
- Strict selected-file SwiftLint via `changed-swift.nul`: exit 0, `lint.log`. Commands ran under `/usr/bin/arch -arm64 /bin/zsh -lc`.
- Formal independent reviews, integration, commit and push remain downstream.
- Exact plan `swiftlint lint` on both files: exit 0, 0 violations, `plan-lint.log`; `git diff --check`: exit 0, `diff-check.log`.
