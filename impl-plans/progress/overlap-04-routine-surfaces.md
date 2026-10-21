# Progress: overlap-04-routine-surfaces

**Plan:** `impl-plans/completed/schedule-overlap-policy-04-routine-surfaces.md`\
**Mode:** issue-resolution  
**Issue reference:** none (intake comm-008602/comm-008603; design comm-008607; accepted plan overlap-04-routine-surfaces depends on accepted overlap-01-contracts).  
**Codex-agent references:** none.  
**Branch:** `feat/schedule-overlap-policy` (no Git write operations).

## Checklist

- [x] Add optional overlap fields to routine creation and copy them onto cron bindings.
- [x] Implement `RoutineService.setOverlapPolicy`, validating before persistence and rewriting the binding while preserving its enabled state.
- [x] Add CLI create/update flags, clear semantics, and inspect output.
- [x] Add GraphQL enum, routine/create fields, set mutation, executor and provider wiring.
- [x] Add `routine.set-overlap-policy` to SurfaceCatalog and the routine CLI action enumeration.
- [x] Add CLI and GraphQL tests for policy propagation, validation, clear behavior, and disabled routine binding state.
- [x] Regenerate the SDL using `scripts/surface-parity/generate-sdl.sh`.
- [x] Pass V1 build and V4 selected-file SwiftLint.
- [x] Pass the complete V3 focused filter, including CLI surface parity.

## Current-source rerun (2026-10-22)

| Gate | Command / result | Evidence |
| --- | --- | --- |
| V1 build | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`; exit 0. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/rerun-20261022/v1-build.log` |
| V2 SDL | `scripts/surface-parity/generate-sdl.sh`; exit 0, regeneration test 1/1 passed; generated file SHA-256 unchanged (`e2e2419f24935dbf7a7850459abb8bb168456adc488607f78a5313c994ce4b53`). | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/rerun-20261022/v2-sdl.log` |
| V3 focused tests | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "RoutineGraphQLTests|RoutineCommandTests|RoutineAddonTests|EventRoutineBindingTests|SurfaceParity"'`; exit 0, 68 tests, 1 skipped, 0 failures. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/rerun-20261022/v3-tests.log` |
| V4 selected-file lint | nonempty `changed-swift-files.nul` passed to `/usr/bin/xcrun swiftlint lint --strict --quiet --no-cache`; exit 0. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/rerun-20261022/v4-lint.log`; manifest `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/changed-swift-files.nul` |
| Session-observer review regression | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests"'`; exit 0, 18 tests, 0 failures. Includes `testCancelRunningWithRealRunnerRecordsRuntimeSessionId`, exercising the production JSON runner and asserting the actual runtime session id in the cancellation receipt. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/rerun-20261022/v5-session-observer-regression.log` |

The prior session-start observer finding `opus-luna-design-and-implement-review-loop-session-471-step3-design-review-attempt-1-finding-1` is verified fixed: `WorkflowRunCommand.runEventHandler` invokes the observer outside the JSONL-only block, and the current-source real-runner regression passes.

## Changed-file hashes

Hashes are `git hash-object` values before and after this plan's edits. The generated SDL was changed only by the required script.

| File | Before | After |
| --- | --- | --- |
| `Sources/RielaWorkflowRegistry/RoutineService.swift` | `c31766c3a8209802a95e235d6197dea08c56ced0` | `bfbf44f59e11879215a8b13618333de77610a46d` |
| `Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift` | `814238fee9113cc3f9c0860e671832256e17f18a` | `9a9ffab3c06a755ae24028f1a1263baff9401d17` |
| `Sources/RielaGraphQL/RoutineGraphQL.swift` | `a8782b5a07f6f3f02e8503a812cce9a31c097ef4` | `3f1e5931874538fef68250e9155b6e08eddbb058` |
| `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` | `ae8f07a7f649c164365dbc6ec155c8e4e2d71d76` | `076f14d8cc26ba06f8389ab71e5cf9ac19fb3789` |
| `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | `9da0da82d96e4ac3dc9b390656f1fff0826f0b31` | `514366f149a04d755c4a5e9f0dac04669aa6f22a` |
| `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` | `ea1ce9bfc5f5422055c95a3d659dd65bfd5a23fe` | `8d22ca645132669771e0f7cc792723a7dbd0db3c` |
| `Sources/RielaCLI/RielaClientFamilyArguments.swift` | `df069f7bd2f2b2f5727d7247abcb537343c84384` | `eff2f75d64bd7f1ead34b3b6e29f82f1c5ecee30` |
| `Sources/RielaCLI/RoutineCommands.swift` | `2855637f24d57aa28436adc239f1152a8cfcf638` | `6da1a6f8e4bc5b18723356130e9b0aa381ec30ed` |
| `Tests/RielaGraphQLTests/RoutineGraphQLTests.swift` | `b8e58244e48f90e3ef7169ecd785bf4b49e34c23` | `fb3161ae504cf335c7d508c2f1ef949c30a48300` |
| `Tests/RielaCLITests/RoutineCommandTests.swift` | `e2c92fe5fe117e53e6d3068408562bfa713adaaf` | `67f12804cb715dc96ad117e50f09eef22666a80c` |

## Verification

| Gate | Result | Evidence |
| --- | --- | --- |
| V1 `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | Final post-SDL build exit 0; `Build complete! (10.80s)`. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v1-build-post-sdl.log` |
| V2 `scripts/surface-parity/generate-sdl.sh` | Exit 0; generator's `SurfaceParityGraphQLTests/testRegenerateGeneratedSDLWhenRequested` ran 1 test with 0 failures; generated SDL changed by one root mutation line. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v2-sdl-final.log` |
| V3 earlier attempt (historical, superseded) | Exit 1; 68 tests, 1 skipped, 7 failures in baseline CLI route parity, fixed outside this plan. The current-source rerun above passes. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v3-tests-rerun.log` |
| V4 selected-file `swiftlint lint --strict --quiet --no-cache` | Exit 0 on the nonempty NUL-delimited changed-Swift manifest. | `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v4-lint-final.log`; manifest `changed-swift-files.nul` |

Earlier complete attempts are retained: `v1-build.log`, `v1-build-rerun.log`, `v1-build-attempt-3.log`, `v1-build-final.log`, `v2-sdl.log`, `v3-tests-final.log`, and `v4-lint-rerun.log`. The initial V3 attempt used a stale build artifact and reported additional SDL failures; after V2, V1 was rerun and the final V3 log above is the current-source result. No review approval is claimed.

## Residual notes

- The prior combined V3 failure was fixed outside this plan; the fresh current-source V3 run passes. The earlier nonzero log remains preserved as historical evidence.
- No hand edit was made to the generated SDL.
- Formal test-integrity, adversarial and integration review, review-dependent documentation/index updates, staging, commit and push remain downstream workflow steps.

## Resume note (operator, 2026-10-22)

- Wave 2 of session-471 stopped in `implementation-wave-outcome` (the Opus prompt exceeded the context limit), not because of this plan.
- Plans overlap-01, overlap-02 and overlap-03 are committed in `cd109008` and listed as `acceptedDependencies` in the dispatch manifest.
- The V3 blocker was a failure already present on `main`: `SurfaceParityCLITests` lacked catalog rows for `cache` and for `memory history`, `show-version`, `restore-version` and `retire-history`. It was fixed separately in `42b81cd4`, outside this plan's write scope.
- With this plan's uncommitted work applied on top, the operator reran the gates: V1 build exit 0 (`v1-build-after-parity-fix.log`), V2 SDL exit 0 (`v2-sdl-after-parity-fix.log`), V3 exit 0 with 68 tests, 1 skipped (the existing regeneration-only skip), 0 failures (`v3-tests-after-parity-fix.log`).
- The resumed implementer reran V1-V4 on current source and passed; the production session-observer regression also passed. Formal downstream review remains pending.
