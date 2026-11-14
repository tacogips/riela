# sdwd-05 progress

The accepted sdwd-01 dependency is present in runtime `acceptedPlanIds`. The plan aligns with `design-wall-clock-deadlines.md` sections 2, 4 and 5.

Implemented absolute deadline scheduling in LocalProcess, wall-clock sleeps for ACP and file-markdown deadlines, timeout-clock documentation, and four scheduler/process tests. Source edit intentions and pre/post identities are in `tmp/stale-definition/sdwd-05-wall-clock-adapters/edit-*.intent` and `edit-*.after`. The SIGKILL grace is unchanged. `grep -n 'asyncAfter(deadline: .now() + delay' Sources/RielaAdapters/LocalProcess.swift` reports only line 504. Selected-file SwiftLint passed; see `lint.log` and `lint.exit`. Initial lint failure and repair are retained as `lint-attempt-1.log` and `edit-6.intent`.

Integration review IR-SDWD05-TEST-GATE authorized the existing tests' runtime scratch under gitignored `tmp/`; it does not authorize editing those tests. The previously reported fixture blocker is resolved. The isolated test gate passed 39 tests with zero failures, including all four LocalProcessWallDeadlineTests. Formal test-integrity and adversarial reviews and final commit remain downstream.

The earlier isolated scratch-path build completed with exit 0 on the shared tree; its evidence is superseded by the fresh build below. Final source hashes are recorded in `source-hashes.txt`.

## IR-SDWD05-TEST-GATE resolution

Before and after the gates, `shasum -a 256 -c tmp/stale-definition/sdwd-05-wall-clock-adapters/source-hashes.txt` verified all five recorded source and documentation hashes without drift. All gates used `arch -arm64 /bin/zsh -lc` with the Xcode toolchain environment. Evidence is under `tmp/stale-definition/sdwd-05-wall-clock-adapters/`:

- `HOME=$PWD/tmp/stale-definition/sdwd-05-wall-clock-adapters/home RIELA_WORKFLOW_HOME=$PWD/tmp/stale-definition/sdwd-05-wall-clock-adapters/workflow-home swift test --filter "LocalProcess|AgentGatewayNodeAdapter|FileMarkdown|WallClockDeadline"`: `test.exit` 0, `test.log`, 39 tests and 0 failures.
- `swift build`: `build.exit` 0, `build.log` and `build-round2.log`.
- `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/stale-definition/sdwd-05-wall-clock-adapters/changed-swift.nul`: `lint.exit` 0, `lint.log` and `lint-round2.log`; the manifest contains the four assigned changed Swift files.

Acceptance checked: absolute scheduling and the sole uptime SIGKILL grace; wall-clock ACP and file-markdown waits; Timeout clock documentation; all four deterministic deadline cases and the existing selected suites; build, test and lint exits all 0. The current shared-tree evidence is subject to the downstream serial integration review.
