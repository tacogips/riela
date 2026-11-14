# sac-02 implementation progress

The owner run-directory validation, flock ownership and dedicated-thread deferred startup are implemented, with tests for lock contention, directory and socket validation, startup/reload ordering, socket preservation, and insecure startup. App and CLI wiring remain assigned to sac-06 and sac-07. Formal reviews and integration are downstream.

Verification on the shared moving tree:

- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 1, `tmp/serverless-app-control/sac-02-owner-lock-startup/build-1.log`. The sibling `Tests/RielaAppSupportTests/RielaAppControlContractTests.swift` lines 52–53 calls throwing `digest()` without `try`; no sac-02 compilation error appeared. The three required focused test runs cannot be established until the package builds. Resume after the sibling owner fixes that file, then rerun build and all three tests on the resulting source.
- Swift 6 typecheck of the two new support files: exit 0, `tmp/serverless-app-control/sac-02-owner-lock-startup/typecheck.log`.
- Strict selected-file SwiftLint: exit 0, `tmp/serverless-app-control/sac-02-owner-lock-startup/lint-strict-2.log`; selected paths in `changed-swift.nul`.
- Plan's selected-file SwiftLint: exit 0, `tmp/serverless-app-control/sac-02-owner-lock-startup/lint-final.log`.
- Forbidden home-path grep: exit 0, `tmp/serverless-app-control/sac-02-owner-lock-startup/home-check.log`.

SHA-256 of implementation and tests at verification:

- `Sources/RielaAppSupport/RielaAppOwnerLock.swift`: `da33e773ef4dd0c47c381ae9b6ec9812fae0a248aaff941d5386a78d2c1db2ae`
- `Sources/RielaAppSupport/RielaAppOwnerStartup.swift`: `a876d829f1af16e8f749342929a732d32d182b4ade3e2c31203c050f2aac0912`
- `Tests/RielaAppSupportTests/RielaAppOwnerStartupTests.swift`: `120645ee3bb05d9ae3fabc13d8164b86f78438d33a891512b0ab0be7fa7c172d`

Completion criteria remain open until the build and three positive behavioral runs pass. Recheck hashes and rerun affected gates if source drifts.

## Verification retry

The sibling compile blocker was repaired. On the shared tree, `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` exited 0 (`tmp/serverless-app-control/sac-02-owner-lock-startup/build-retry.log`). Three consecutive `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter RielaAppOwnerStartupTests'` runs each exited 0 with 4 tests and 0 failures (`test-retry-1.log`, `test-retry-2.log`, `test-retry-3.log` in that directory). Strict selected-file lint and the plan lint both exited 0 (`lint-retry.log`, `lint-plan-retry.log`); the home-path check exited 0 (`home-retry.log`). The source hashes above remain unchanged. The tree and build output were shared during these checks; serial integration should repeat them on the combined tree. Formal reviews and integration are downstream.
