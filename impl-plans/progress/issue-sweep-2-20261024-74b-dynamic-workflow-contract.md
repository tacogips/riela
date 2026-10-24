# ISW2-74b implementation progress

- Mode: `issue-resolution`; issue: `tacogips/riela#74`.
- Plan: `impl-plans/active/issue-sweep-2-20261024-74b-dynamic-workflow-contract.md`.
- Codex-agent reference: implementation worker for native Riela fanout branch `ISW2-74b-dynamic-workflow-contract`, step `step6-implement`, execution `nested-v1-410c5597f78540140017fc793b14933bf8deb3770701fd385c41815ebd71fb5f`.
- Dependency readiness: `ISW2-27c-session-reconcile` is included in runtime-owned `acceptedPlanIds`.
- Branch: `feat/issue-sweep-2-20261024`, based at `0b09f3112eece290102afd3b8548def2d43b05a8`; uncommitted, `gitPush=false`.

## Implemented

- Added optional `WorkflowStepTransition.dynamicWorkflow`, retaining synthesized Codable behavior for legacy transitions.
- `DefaultWorkflowValidator` rejects combinations with `toWorkflowId`, `resumeStepId`, or `fanout`; appends `DynamicWorkflowPolicy.authoredDiagnostics`; and warns on a self-loop whose `maxLoopIterations` is at or below resolved `maxIterations` (default 4). Existing transition diagnostics retain their prior paths and messages.
- Added `WorkflowGeneratedWorkflowOrigin` and optional `WorkflowSession.generatedWorkflow` persistence with `decodeIfPresent` / `encodeIfPresent`.
- Added `Sources/RielaCore/TemporaryWorkflowPayload.swift`; the shared materializer runs raw and typed authored checks through `validateAuthoredWorkflowData` on the encoded workflow, maps payloads by `nodeFile` before `id`, and returns no node payloads on validation failure.
- Updated the CLI temporary-workflow path to use the shared materializer and removed its private materializer type/helper. The durable runtime setup hunk in `WorkflowRunCommand.swift` remains present.
- Added six contract tests, including raw advisory-terminal-step rejection, for transition Codable, authored validation/policy diagnostics, session provenance round trip and legacy decoding, and materializer mapping/failure behavior.
- Addressed `ISW2-74b-TI-1`: restored the raw validation checks previously used by the CLI and verified rejection of advisory terminal steps with empty materialized payloads. The focused run also executes both requested CLI scenario tests that pass wrapped `{workflow,nodePayloads}` inputs to `riela workflow run`.

## Changed files owned by this plan

- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowValidation.swift`
- `Sources/RielaCore/TemporaryWorkflowPayload.swift`
- `Sources/RielaCore/RuntimeSession.swift` (shared hunk authorized by dispatch `sharedPathNotes`)
- `Sources/RielaCLI/WorkflowRunCommand.swift` (shared hunk authorized by dispatch `sharedPathNotes`)
- `Tests/RielaCoreTests/WorkflowDynamicWorkflowContractTests.swift`
- `impl-plans/active/issue-sweep-2-20261024-74b-dynamic-workflow-contract.md`
- `impl-plans/progress/issue-sweep-2-20261024-74b-dynamic-workflow-contract.md`

Other current worktree changes belong to sibling `ISW2-27c-session-reconcile` and were not edited by this plan.

## Final-source verification

Each record has integer exit/test/failure counts and a complete log under `tmp/issue-sweep-2-20261024/isw2-74b/`.

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74b/build.log 2>&1; build_exit_code=$?; echo exitStatus=$build_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/build.log; exit $build_exit_code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDynamicWorkflowContractTests|DynamicWorkflowPolicyTests|WorkflowCommandCatalogTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|WorkflowCommandTests/testScenarioLookupUsesExecutingStepIdWhenNodeIsReusable|WorkflowCommandTests/testMockScenarioUsesDefaultGuardUnlessCLIExplicitlyOptsOut|WorkflowCommandTests/testSessionResumeUsesMockScenarioForCommandNodes" > tmp/issue-sweep-2-20261024/isw2-74b/focused.log 2>&1; focused_exit_code=$?; echo exitStatus=$focused_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/focused.log; exit $focused_exit_code'` | 0 | 39 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/focused.log`; includes both requested CLI envelope scenario tests |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowValidat" > tmp/issue-sweep-2-20261024/isw2-74b/validation.log 2>&1; validation_exit_code=$?; echo exitStatus=$validation_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/validation.log; exit $validation_exit_code'` | 0 | 18 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/validation.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/issue-sweep-2-20261024/isw2-74b/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest" > tmp/issue-sweep-2-20261024/isw2-74b/lint.log 2>&1; lint_exit_code=$?; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run." > tmp/issue-sweep-2-20261024/isw2-74b/lint.log; lint_exit_code=0; fi; echo exitStatus=$lint_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/lint.log; exit $lint_exit_code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/lint.log`; changed-file manifest: `tmp/issue-sweep-2-20261024/isw2-74b/changed-swift-files.nul` |
| `grep -n "private struct TemporaryWorkflowPayload" Sources/RielaCLI/WorkflowRunCommand.swift` (expected no match; normalized gate) | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/temp-payload-grep.log` |
| `arch -arm64 /bin/zsh -lc 'grep -n "dynamicWorkflow" Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowValidation.swift > tmp/issue-sweep-2-20261024/isw2-74b/dynamic-workflow-grep.log 2>&1; match_exit_code=$?; if [ "$match_exit_code" -eq 0 ]; then gate_exit_code=0; else gate_exit_code=1; fi; echo exitStatus=$gate_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/dynamic-workflow-grep.log; exit $gate_exit_code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/dynamic-workflow-grep.log` |
| `arch -arm64 /bin/zsh -lc 'rg -n "validateAuthoredWorkflowJSON" Sources/RielaCore/TemporaryWorkflowPayload.swift > tmp/issue-sweep-2-20261024/isw2-74b/raw-validator-grep.log 2>&1; rg_exit_code=$?; if [ "$rg_exit_code" -eq 1 ]; then echo "no typed-only validator call" >> tmp/issue-sweep-2-20261024/isw2-74b/raw-validator-grep.log; gate_exit_code=0; else echo "unexpected match or rg error" >> tmp/issue-sweep-2-20261024/isw2-74b/raw-validator-grep.log; gate_exit_code=1; fi; echo exitStatus=$gate_exit_code >> tmp/issue-sweep-2-20261024/isw2-74b/raw-validator-grep.log; exit $gate_exit_code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/raw-validator-grep.log` |
| `shasum -a 256 Sources/RielaCore/RuntimeSession.swift Sources/RielaCLI/WorkflowRunCommand.swift` compared with pre-TI-1 post-edit hashes | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74b/shared-hunks-unchanged.TI-1.log`; hashes: `tmp/issue-sweep-2-20261024/isw2-74b/current-shared-hashes.TI-1.txt` |

## Earlier attempts resolved

- The first focused run exposed a test helper argument-label error. The second exposed an incomplete fanout JSON fixture. Both were corrected; retained logs are `tmp/issue-sweep-2-20261024/isw2-74b/prior/focused-attempt-1.log` and `tmp/issue-sweep-2-20261024/isw2-74b/prior/focused-attempt-2.log`. The pre-review 35-test run is retained in `tmp/issue-sweep-2-20261024/isw2-74b/prior/focused-pre-TI-1.log`; after addressing TI-1 the final current-source run passes 39 tests with 0 failures, including the new sixth contract test and the two requested CLI scenario tests.
- An initial build wrapper used zsh's read-only `status` variable and exited 1 after Swift build output. Its log was overwritten by the corrected final run before it was copied. This wrapper attempt is not counted as build evidence; final-source `swift build` passes with exit 0.

## Handoff

`ISW2-74b-TI-1` is addressed in code and regression tests; the required current-source build, focused, validation, and lint gates pass. This records implementation evidence, not independent re-acceptance. Test-integrity, adversarial, and combined-tree integration review remain downstream. Runtime dispatch and the generated-workflow example remain owned by dependent plans `ISW2-74c-dynamic-workflow-dispatch` and `ISW2-74d-brain-loop-example`.
