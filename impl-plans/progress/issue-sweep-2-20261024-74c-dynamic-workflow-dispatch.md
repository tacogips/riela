# ISW2-74c implementation progress

- **Issue**: `tacogips/riela#74` (dynamic workflow dispatch)
- **Workflow mode**: `issue-resolution`, native Riela fanout (`shared-branch-implementation`, index `2`)
- **Fanout branch**: `ISW2-74c-dynamic-workflow-dispatch`
- **Implementation branch**: `feat/issue-sweep-2-20261024`
- **Codex-agent reference**: Codex Step 6 implementation worker, native Riela fanout branch
- **Plan**: `impl-plans/active/issue-sweep-2-20261024-74c-dynamic-workflow-dispatch.md`
- **Status**: Implementation complete. Test-integrity, adversarial, and combined-tree integration reviews remain downstream.
- **Review decision**: No Step 7/8 decision yet; no review findings were supplied to this implementation node.

## Implementation

Added dynamic transition publication independent of mock/static cross-workflow dispatch, including rejection of multiple selected dynamic transitions. A single `prepareDynamicIteration` helper owns iteration budget checks, raw-envelope policy checks, materialization, validation, authority stamping, timeout/loop clamping, and digest generation. The durable pre-commit hook, post-commit in-process child dispatch, and resume recovery use that helper. Child reservations persist dynamic workflow provenance and lineage; result delivery is idempotent for completed, failed, cancelled, and invalid outcomes. Parent cancellation propagates without a result message. Recovery uses the persisted definition and accepted output and does not rerun the brain.

## Changed files

- `Sources/RielaCore/DeterministicWorkflowRunner+DynamicWorkflow.swift`
- `Sources/RielaCore/RuntimePublication.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedPublication.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerDynamicWorkflowTests.swift`
- `impl-plans/active/issue-sweep-2-20261024-74c-dynamic-workflow-dispatch.md`
- `impl-plans/progress/issue-sweep-2-20261024-74c-dynamic-workflow-dispatch.md`

## Final-source verification

All records include integer exit status, test count, and failure count. Logs are complete under `tmp/issue-sweep-2-20261024/isw2-74c/`.

| Command | Exit | Tests run | Failures | Log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74c/build.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74c/build.log; exit $result'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74c/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerDynamicWorkflowTests|DynamicWorkflowPolicyTests|WorkflowDynamicWorkflowContractTests" > tmp/issue-sweep-2-20261024/isw2-74c/focused.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74c/focused.log; exit $result'` | 0 | 25 | 0 | `tmp/issue-sweep-2-20261024/isw2-74c/focused.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerCrossWorkflowDispatchTests|DeterministicWorkflowRunnerFanoutTests|WorkflowCancelledStatusTests|ClientArgumentParserNestedActionTests|SpecialistSupervisorRecoveryTests|Nested" > tmp/issue-sweep-2-20261024/isw2-74c/regression.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74c/regression.log; exit $result'` | 0 | 77 | 0 | `tmp/issue-sweep-2-20261024/isw2-74c/regression.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/issue-sweep-2-20261024/isw2-74c/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/issue-sweep-2-20261024/isw2-74c/lint.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74c/lint.log; exit $result'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74c/lint.log` |
| `grep -rn "dynamic-workflow" Sources/RielaCore > tmp/issue-sweep-2-20261024/isw2-74c/branch-id-grep.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74c/branch-id-grep.log; exit $result` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74c/branch-id-grep.log` |

The strict lint manifest is `tmp/issue-sweep-2-20261024/isw2-74c/changed-swift-files.nul` and lists only the seven changed Swift files owned by this plan. The branch-id grep shows dispatch, hook, and recovery sites.

## Superseded attempts

Earlier failed attempts remain preserved and are not final-source gates. The fixes were applied before the successful final-source logs above:

- `build-attempt-1.log` (exit 1): missing optional-context inference in nested result construction; corrected. `build-attempt-2.log` (exit 0) is an earlier intermediate build; final build is `build.log`.
- `focused-attempt-1.log` (exit 1): cancelled run. Attempts 2-7 found compile/type or fixture/assertion issues (optional store unwrap, authored schema, mock payload selection, generated node payload resolution); corrected in later source.
- `focused-attempt-10.log` (exit 1): Swift concurrency diagnostic in cancellation test; corrected. Attempts 8, 9, 11, and 12 passed successively narrower/intermediate states; final complete focused suite is `focused.log` (25/0). `focused-multi-initial-failed.log` (exit 1) captured the first TI repair test shape, which reached the sequential runner's generic multiple-direct-output rejection; the variants were reshaped to exercise RuntimePublication and the durable hook guards separately. The initial TI regression run used a narrower filter; the final `regression.log` uses the corrected manifest/reviewer filter and includes 16 passing `SpecialistSupervisorRecoveryTests`.
- `lint-attempt-1.log` (exit 1): parameter-count and test type-name rules; corrected. Final strict changed-file lint is `lint.log` (exit 0).


## Test-integrity revision (comm-000160)

- **ISW2-74c-TI-1 addressed**: reran the requested regression filter with `SpecialistSupervisorRecoveryTests` and `Nested`; the final log lists `SpecialistSupervisorRecoveryTests` passed (16 tests) and 77 total tests, 0 failures, exit 0. `ScopedParityCallStepFanoutTests` was removed from the final filter because no matching suite exists in `Tests/`.
- **ISW2-74c-TI-2 addressed**: added `testTwoSelectedDynamicTransitionsAreRejectedInMemory` to drive both selected dynamic routes through `RuntimePublication`'s guard, and `testTwoSelectedDynamicTransitionsAreRejectedDurably` to invoke the durable pre-commit hook with both selected routes. The cases assert rejection, no generated child, and no dynamic result; the durable case also asserts no `dynamic-workflow` records. Both pass in the final focused run (25/0).
- Final build, focused tests, expanded regression, and strict lint all ran after the last test edit. Logs: `build.log`, `focused.log`, `regression.log`, `lint.log` under `tmp/issue-sweep-2-20261024/isw2-74c/`.
- Independent test-integrity re-review remains pending; no review acceptance is claimed.

## Handoff

No implementation blocker or unresolved plan-owned verification remains. No files were staged or committed and nothing was pushed (`gitPush=false`). Formal test-integrity, adversarial, and combined-tree integration review are pending workflow steps.
