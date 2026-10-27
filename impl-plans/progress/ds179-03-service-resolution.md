# DS179-03 Service-Mode Resolution Progress

**Issue:** tacogips/riela#179 section 2, service-vs-one-time execution policy  
**Workflow mode:** issue-resolution  
**Plan:** `impl-plans/active/ds179-03-service-resolution.md`  
**Dependency admission:** `ds179-02-definition-service` is accepted in the dispatched `fanoutItem.acceptedPlanIds`.  
**Workflow execution:** `nested-v1-09fece7e7a74758fb8cee7a8cbd194ae5894563e340138d765f3701756847205` (step `step6-implement`).  
**Issue reference:** [tacogips/riela#179](https://github.com/tacogips/riela/issues/179).  
**Codex agent:** `/root`, implementation owner; read-only code map: `/root/ds17903_code_map`.

## Implementation

- Added `WorkflowExecutionMode` to `WorkflowRunOptions`, defaulting to `.oneTime`. The ordinary workflow run path stays file-only and computes a file `definitionSource`; service runs use a per-run store resolver.
- Added `WorkflowDefinitionStoreSelection` and `DefinitionStoreWorkflowBundleResolver` with explicit/environment/project/user candidate roots, lookup-only and lookup-or-seed modes, stored source-directory warnings, and no database open when the candidate runtime database does not exist.
- Deferred a first service seed until after main workflow preflight succeeds. Successful service runs pin the seeded/current source and preserve instance-applied node payloads and structure.
- Wired GraphQL `executeWorkflow`, configured launches, event runner, events-serve trigger defaults, and required-environment preflight. Configured launch resolves the store first and reads files only on a miss; event preflight and trigger-default lookup never seed.
- Threaded `definitionSource` through cross-workflow callee resolution. Resume and rerun load store-pinned versions from their recorded `storeRoot` and pass that pin to the resumed/rerun request.
- Added six focused tests for seed and prompt use, broken-file isolation, file-only CLI behavior with empty and already-populated definition tables, concurrent first runs, configured launch, event runner/preflight, and pinned resume/rerun.
- Existing tests changed: none. New test file: `Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift`.

## Edit evidence and hashes

Per-edit intentions and grouped pre-edit hashes are preserved under:

- `tmp/ds179/ds179-03-service-resolution/attempt-001/edit-intent-001.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-001/edit-intent-002.md`, `pre-edit-fixup-sha256.txt`, `edit-intent-003.md`, and `pre-edit-test-state.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-003/edit-intent-001.md` and `pre-edit-fixup-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-004/edit-intent-001.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-005/edit-intent-001.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-006/edit-intent-002.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-007/edit-intent-001.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-008/edit-intent-001.md` and `pre-edit-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-009/edit-intent-001.md` and `pre-edit-comment-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-010/edit-intent-001.md` and `pre-edit-seed-fix-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-011/edit-intent-001.md` and `pre-edit-lint-fix-sha256.txt`
- `tmp/ds179/ds179-03-service-resolution/attempt-012/edit-intent-001.md`, `edit-intent-002.md`, `edit-intent-003.md`, `edit-intent-004.md` and their matching pre-edit hash manifests
- `tmp/ds179/ds179-03-service-resolution/attempt-013/edit-intent-001.md`, `edit-intent-002.md`, and matching pre-edit hash manifests

Current post-edit hashes for every ds179-03 Swift file, this plan, and the new test are in `tmp/ds179/ds179-03-service-resolution/attempt-013/final-source-sha256.txt`.

## Final-source verification

| Command | Exit | Tests run | Failures | Complete log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-03-service-resolution/attempt-013/build-final.log 2>&1'` | 0 | 0 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/build-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionServiceResolutionTests > tmp/ds179/ds179-03-service-resolution/attempt-013/test-final.log 2>&1'` | 0 | 6 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/test-final.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowExecutionProviderTests|EventLiveServeCronTests|EventLiveServeTests|WorkflowDefinitionServiceTests' > tmp/ds179/ds179-03-service-resolution/attempt-013/regression-final.log 2>&1"` | 0 | 47 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/regression-final.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/ds179/ds179-03-service-resolution/attempt-010/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-03-service-resolution/attempt-010/changed-swift-files.nul > tmp/ds179/ds179-03-service-resolution/attempt-013/lint-final.log 2>&1; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/lint-final.log` (empty) |
| `arch -arm64 /bin/zsh -lc 'git diff --check > tmp/ds179/ds179-03-service-resolution/attempt-013/diff-check.log 2>&1'` | 0 | 0 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/diff-check.log` |
| `grep -n 'executionMode' Sources/RielaCLI/WorkflowExecutionProvider.swift Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift` | 0 | 0 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/execution-mode-grep.log` |
| `grep -n 'fileResolver.resolve(resolution)' Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift` | 0 | 0 | 0 | `tmp/ds179/ds179-03-service-resolution/attempt-013/configured-file-resolve-grep.log` |

## Superseded attempts and corrections

- `attempt-001/build.log` exited 1 for initializer argument order; corrected, later build passed.
- `attempt-003/test.log` exited 1 while call-site compatibility and an optional key path were being corrected. `attempt-004/test.log` exposed ISO-8601 result decoding; fixed in `attempt-005`.
- `attempt-007/test.log` exited 1 because the test omitted required `history(nodeId:limit:)` arguments; fixed in `attempt-008`.
- `attempt-010/regression.log` exited 1 with 3 existing provider tests failing because lookup created an empty runtime database and preflight seeded too early. Lookup now skips absent databases and first-use seeding happens after preflight; `attempt-011/regression.log` then passed 47/0, and final-source `attempt-013/regression-final.log` passed 47/0.
- `attempt-011/lint.log` and `attempt-012/lint.log` reported SwiftLint body-size, tuple-size and line-length findings. Helpers and fixture formatting were corrected; final strict changed-file lint is clean.
- `attempt-012/test-rerun.log` exposed a missing opening brace in the multiline fixture literal; corrected, and the final focused suite passed 6/0.
- `attempt-013/lint.log` reported the new two-step test's long JSON line; wrapped and reran strict lint successfully.

## Completion

All ds179-03 implementation criteria are complete. Current-source build, focused behavioral tests, the assigned regression filter, strict lint, and diff check pass. Formal combined-tree integration/adversarial review remains downstream. No blocker was found.

## TI-03-001 test-integrity repair (attempt-014)

- Added `testServiceRunCalleeChildCarriesStorePinAndOneTimeRunStaysFileOnly` in `Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift`. It copies both cross-workflow examples into a unique fixture under the repository `tmp/`, runs the caller through `WorkflowExecutionProvider`, and checks the child terminal snapshot is `.store` pinned to the callee's current head. It then runs the same workflow in a fresh store through default one-time `WorkflowRunCommand` and checks the child source is `.file` and all four definition tables contain zero rows.
- The six existing tests and their assertions were left unchanged. No production wiring change was needed.
- Current changed test source SHA-256: `b89e86cc5b6e92303d90300d70d313ac35d312c77329505e37967415eff2f168` (`attempt-014/final-source-sha256.txt`).
- Final verification: build exit 0 (`tmp/ds179/ds179-03-service-resolution/attempt-014/build.log`); focused suite 7 tests / 0 failures (`test.log`); expanded regression 50 tests / 0 failures (`regression-rerun.log`); strict changed-file lint exit 0 over the nonempty NUL manifest (`lint.log`); `git diff --check` exit 0 (`diff-check.log`).
- Superseded attempt-014 evidence retained: the initial focused run had 1 fixture-path failure because the existing repositoryRoot helper points one directory above the checkout; its captured failure output is `attempt-014/test-first-run-fixture-path-failure.log`, and the new fixture now derives its checkout root locally. The first expanded regression run (`regression.log`) had 1 timeout in the existing subprocess recovery test's fresh scratch build (50 tests, 1 failure); the exact same filter then passed 50/0 after that test's scratch build was warmed. Neither failure remains on final-source verification.
- Per-edit intentions and pre-edit hashes are in `attempt-014/edit-intent-001.md` through `edit-intent-005.md` and matching `pre-edit-*.txt` manifests.
