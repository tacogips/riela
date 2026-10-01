# wh-20-reconcile progress

**Mode**: `issue-resolution` · **Plan**: `wh-20-reconcile` · **Fanout branch**: `wh-20-reconcile` · **Implementation branch**: `feat/work-handover-and-takeover` · **Base**: `01b38f02` · **Checkpoint**: `f56bd72c4817b3a7bbf3d763189ca2eb822ae7e8`

**Issue reference**: No GitHub issue was supplied. Accepted work is tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.

**Codex-agent references**: Native workflow execution `nested-v1-aa5806b2e999f63d5ec4396c9d2e5194686476256fbea60b8c6c939db574dfdb`, step `step6-implement`, plan `wh-20-reconcile`, fanout group `shared-branch-implementation`, branch `wh-20-reconcile`. Read-only join audit agent `/root/join_audit` reported no unexplained drift; its audit did not authorize edits outside this plan's write paths.

## Implementation result

Implemented wh-20's GraphQL root-field catalog and generated SDL registration, CLI/session catalog rows, parity enumeration, docs/README links, R34 generated payload and pending-registration cleanup, and R35 merged-process git environment fix with a hermetic application-ceiling regression test. No Git state changes were made. Changes are incomplete because the final baseline gate found three new catalog test failures that require two files outside this plan's authorized `writePaths` and `sharedPaths`.

Changed paths:

- `README.md`
- `Resources/skills/riela-workflow-run/SKILL.md`
- `Sources/RielaCLI/CLISurfaceEnumeration.swift`
- `Sources/RielaCLI/TaskDispatch+Handover.swift`
- `Sources/RielaCLI/TaskHandoverRuntime.swift`
- `Sources/RielaCore/SurfaceCatalog+Rows.swift`
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`
- `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
- `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`
- `Tests/RielaCLITests/TaskHandoverCommandTests.swift`
- `Tests/RielaCLITests/TaskHandoverTestSupport.swift`
- `Tests/RielaCLITests/TaskRemoteTakeoverTests.swift`
- `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift`
- `Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift`
- `impl-plans/README.md`
- `impl-plans/active/work-handover-and-takeover.md`
- `impl-plans/progress/wh-14-task-dispatch-runtime.md` (superseding closure note for the earlier remaining-work list)
- `impl-plans/progress/wh-20-reconcile.md`

No review feedback was supplied (`findings: []`). Formal test-integrity, adversarial, and integration review remain downstream. No plans were archived; the umbrella completion criteria remain unchecked.

## Verification evidence

All logs are complete and under `tmp/work-handover/wh-20-reconcile/`.

| Gate | Command / evidence | Result |
| --- | --- | --- |
| Build | `arch -arm64 /bin/zsh -lc 'swift build'` · `build-final.log` | exit 0 |
| SDL regeneration | `scripts/surface-parity/generate-sdl.sh` · `sdl-1-retry.log` | exit 0 |
| SDL repeat | `scripts/surface-parity/generate-sdl.sh`; second-generation `git diff` · `sdl-repeat-final.log` | exit 0; `diffExit=0` |
| Surface parity | `arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceParity"'` · `parity-final.log` | exit 0; 46 tests, 0 failures, 1 skipped; includes `SurfaceParitySkillTests` |
| Focused handover suites | Accepted focused filter recorded in `focused-final.log` | exit 0; 211 tests, 0 failures |
| R35 focused suites | `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskHandoverDispatchTests|TaskHandoverRepositoryTests"'` · `r35-focused-final.log` | exit 0; 42 tests, 0 failures |
| R35 ceiling regression | Focused `TaskHandoverCommandTests.testSessionHandoverHonorsApplicationGitCeilingForNonRepositoryWorkingDirectory` · `r35-ceiling.log` | exit 0; 1 test, 0 failures. The prior-behavior experiment failed 1 test with 2 assertions in `r35-ceiling-prefix.log`; restored implementation passes. |
| Examples | Three `workflow validate` and mock `workflow run` commands · `examples.log` | validation exit 0 x3; answer run exit 5; presence run exit 5; orphan run exit 0 |
| Changed-file SwiftLint | Exact changed Swift paths via `changed-swift-files.nul`; `swiftlint lint --strict --quiet --no-cache` · `swiftlint-changed.log` | exit 0; 12 Swift files |
| Branch SwiftLint inventory | `git diff --name-only 01b38f02 -- "*.swift" | xargs swiftlint lint --strict` · `swiftlint.log` | exit 0; 141 Swift files |
| Raw full suite | `arch -arm64 /bin/zsh -lc 'swift test'` · `full-swift-test.log` | `suiteExit=1`; 2,967 tests, 4 failures, 2 skipped. The wh-00 cross-workflow timeout passed in 98.024s. |
| Required baseline comparison | Manifest baseline-comparison command using `wh-00/full-swift-test.log`, `full-swift-test.log`, and generated failure sets · `full-suite-baseline-gate.log` | exit 1; three current failures absent from baseline, listed in `new-failures.txt` |
| Diff check | `git diff --check` · `diff-check-final.log` | exit 0 after progress update |

New current-suite failures:

- `RielaCoreTests.SurfaceCatalogTests.testCatalogInvariantsHold`
- `RielaCoreTests.SurfaceCatalogTests.testIdsCLICommandsGraphQLFieldsAndRoutesAreUnique`
- `RielaCoreTests.SurfaceCatalogTests.testWorkRuntimeReadAndP1TaskCommandsAreCataloged`

The first two expose a duplicate `task.serve` operation row between the console row and wh-20's CLI rows. The third asserts the pre-handover task catalog and GraphQL blocking behavior. The required repairs are to update the existing `task.serve` row in `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift` and revise catalog expectations in `Tests/RielaCoreTests/SurfaceCatalogTests.swift`. Both paths are outside wh-20's declared `writePaths` and `sharedPaths`; neither was edited. This is an ownership blocker, not an accepted-plan dependency failure.

## Blocker and resume criterion

- **Dependency**: Serial integration owner must explicitly extend wh-20 ownership to `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift` and `Tests/RielaCoreTests/SurfaceCatalogTests.swift`.
- **Evidence**: `impl-plans/active/wh-20-reconcile.md` authorized paths omit both; full test and comparison logs above; `new-failures.txt` names all three out-of-baseline failures.
- **Impact**: `implementationIncomplete=true`; final full-suite baseline gate is not green, so do not archive plans or claim acceptance.
- **Resume criterion**: After the accepted plan ownership is amended, reconcile the duplicate `task.serve` row and catalog assertions, rerun affected focused tests, then rerun the exact baseline comparison and all final-source gates required by wh-20.

## Join audit and scope notes

Join audit found no unexplained drift. The audit noted missing posthash manifests for wh-10 and wh-14 through wh-19, while those plans have per-edit records in their progress logs. Existing `.riela/` runtime state and `.build/` build state were present; no scratch artifact was created outside repository-root `tmp/`. The second SDL generation was idempotent. The generated schema contains the wh-12 seven root-field signatures and `HandoverAnswerPayload`; `TaskRemoteTakeoverTests.swift` has no `isPendingSchemaRegistration` or `XCTExpectFailure`; `TaskHandoverRuntime.gitEnvironment()` uses `CLIRuntimeEnvironment.mergedProcessEnvironment()` and does not assign `GIT_CEILING_DIRECTORIES`.

**Review decision**: Not yet reviewed by downstream test-integrity/adversarial/integration gates. Incoming review findings: none. **Plan status**: blocked pending ownership amendment; not archived.
