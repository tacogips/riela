# Schedule Overlap Policy 05 Integration Progress

Workflow mode: `issue-resolution`  
Issue reference: none (no issue URL or issue number); intake `comm-008602` / `comm-008603`, design accepted `comm-008607`, plan communications `comm-008608`–`comm-008611`.  
Codex-agent references: none.  
Workflow execution: `opus-luna-design-and-implement-review-loop-session-471`.  
Plan: `impl-plans/completed/schedule-overlap-policy-05-integration.md`  
Design: `design-docs/specs/design-scheduled-overlap-policy.md`  
Evidence: `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/`

## Checklist

- [x] T1 combined build and focused test suites; V1–V3 recorded.
- [x] T2 regenerate SDL and compare pre/post content hash; V4 recorded.
- [x] T3 run smoke checks S1–S4 and preserve output logs.
- [x] T4 add the Active Plans index paragraph; pre/post README hashes recorded.
- [x] V7 `git diff --check`.
- [x] V5 amended selected-file strict SwiftLint gate; the changed-Swift manifest is nonempty and lint exits 0. The earlier repo-wide lint baseline is retained below as historical context only.

## Verification

All log paths below are relative to the repository root. `testsRun` is 0 for non-test commands. V1's first invocation completed the build successfully, but its status-print wrapper hit zsh's read-only `status` variable; V1's recorded result is the successful retry with `rc` and full log `v1-build-retry.log`.

| Gate | Command | exitStatus | testsRun | failureCount | Log / evidence |
| --- | --- | ---: | ---: | ---: | --- |
| V0 | `mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures` | 0 | 0 | 0 | directory created |
| V1 | `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v1-build-retry.log 2>&1` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v1-build-retry.log`; `Build complete! (5.31s)` |
| V2 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventOverlapPolicyTests|EventOverlapContractValidationTests|RoutineStoreTests|EventRoutineBindingTests|EventDryRunTests|WorkflowLoopValidationTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v2-core-events.log 2>&1` | 0 | 60 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v2-core-events.log` |
| V3 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServe|EventReadOnlyPolicyTests|OverlapPolicyInspectionTests|RoutineCommandTests|RoutineGraphQLTests|RoutineAddonTests|SurfaceParity|WorkflowCommandLivePersistenceEventTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v3-cli-graphql.log 2>&1` | 0 | 153 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v3-cli-graphql.log`; one test skipped |
| V4 | `git hash-object Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-before.txt && scripts/surface-parity/generate-sdl.sh > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl.log 2>&1 && git hash-object Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-after.txt && cmp tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-before.txt tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-after.txt` | 0 (generator), 0 (cmp) | 1 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl.log`; before/after hash `514366f149a04d755c4a5e9f0dac04669aa6f22a` |
| V5 | `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint.log 2>&1` | 2 | 0 | 30 diagnostics | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint.log`; “Found 30 violations, 30 serious in 1197 files.” Checkpoint comparison: identical to V5 baseline; see `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint-comparison.json`. |
| V7 | `git diff --check > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-diff-check.log` |

## CLI smoke checks

Each CLI invocation ran as `arch -arm64 /bin/zsh -lc '<command>' > <log> 2>&1`; all logs contain complete command output.

| Check | Command | exitStatus | Expected evidence |
| --- | --- | ---: | --- |
| S1 | `.build/debug/riela events validate --event-root /Users/taco/gits/tacogips/riela-overlap-policy/tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures/events-bad` | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/s1.log`: `status=failed`; `bindings[5].overlapPolicy: overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'` |
| S2 | `.build/debug/riela events validate --event-root /Users/taco/gits/tacogips/riela-overlap-policy/tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures/events-ok` | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/s2.log`: `status=ok`; `binding=cron-to-arithmetic overlapPolicy=inherit` |
| S3 | `.build/debug/riela workflow validate first-four-arithmetic-pipeline --workflow-definition-dir /Users/taco/gits/tacogips/riela-overlap-policy/tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures/workflows` | 1 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/s3.log`: `path=workflow.triggerDefaults.overlapPolicy`, `message=must be one of skip, cancelRunning, queue, concurrent` |
| S4 | `.build/debug/riela workflow inspect first-four-arithmetic-pipeline --workflow-definition-dir /Users/taco/gits/tacogips/riela-overlap-policy/tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures/workflows-inspect --output text` | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/s4.log`: `triggerDefaults: overlapPolicy=queue maxQueuedRuns=2` |

S1 and S3 encode validation failure in their output and use the CLI's documented JSON result/exit behavior; S1 returns process exit 0 with `status=failed`, while S3 returns exit 1.

## README and scope

- README pre-edit hash: `04e8c184c7cdabc38777c13b41503e2b0e51c75d` (`tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/readme-hash-before.txt`).
- README post-edit hash: `3e5b5b5b00aa5727339ee324bbb4e2949bbe6426` (`tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/readme-hash-after.txt`).
- `grep -n "schedule-overlap-policy" impl-plans/README.md` matched line 58.
- Initial `git status --short` was empty. Before progress creation, only `impl-plans/README.md` was a tracked modification; the plan-local `tmp/` directory is ignored. No Sources or Tests edits were made by this plan. The status snapshot is `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/status-after-before-progress.txt`.

## Historical repo-wide lint baseline

- The earlier repo-wide V5 command exits 2 with 30 diagnostics. Its checkpoint baseline has the same 30 diagnostics (`v5-lint-comparison.json`), so this is inherited baseline evidence. The operator amendment changes the required V5 gate to selected-file lint; see continuation attempt 2 for the passing current result. No failures are handed back by this plan.

## Residual notes

- The earlier S1/S2 attempts had an incomplete copied fixture because its `local-docs` source expects a `watched-docs` sibling under `fixtures/`; those attempt logs are preserved as `s1-fixture-attempt.log` and `s2-fixture-attempt.log`. Final S1/S2 logs pass after copying that fixture data.
- V4 uses the accepted before/after hash comparison, not a diff against HEAD, because the generated SDL is already integrated in the combined tree.
- Workflow mode remains `issue-resolution`; no Git write operations, Sources edits, or Tests edits were performed.

## Final scope reconciliation

After the README and progress edits, the final `git diff --check` command returned exit 0; complete log: `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-final-diff-check.log`. Final `git status --short` is recorded in `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/status-final.txt` and lists only `impl-plans/README.md` and `impl-plans/progress/overlap-05-integration.md`. A final scope query found no `Sources/` or `Tests/` changes.


### Continuation attempt 1: lint baseline disposition

- Checkpoint source/config: `a13864edcf98d39e35062827f2103c784bdef766`; `git diff --quiet HEAD -- '*.swift' .swiftlint.yml` exited 0.
- Exported checkpoint and current tree matched for all 1,197 Swift files plus `.swiftlint.yml`: `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/lint-source-identity.json`.
- Baseline command: `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela-overlap-policy/tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/lint-baseline && swiftlint lint --strict' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-baseline-lint.log 2>&1`; exit 2, 30 diagnostics. Comparison with current V5: identical, zero diagnostic additions/removals (`tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint-comparison.json`).
- Changed Swift manifest is empty; selected-file lint was skipped with output `No Swift files changed; selected-file SwiftLint not run.`
- V5 remains recorded as a non-passing repository gate because its required command returns 2.

Continuation completion checks: `git diff --check > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-continuation-final-diff-check.log 2>&1` exited 0. Final continuation status is in `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/status-continuation-final.txt`; it contains only the authorized README and progress changes.

### Continuation attempt 2: current-source integration gates

- Current source identity: `6a5ea0f3317a2e50e81f4d9a0687be57dfd89bf2`. Before this progress update, `git status --short` contained only the authorized README and progress paths; current status snapshot: `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/status-before-final-progress.txt`.
- V0 created the fixtures directory; exit 0.
- V1 `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v1-build-current.log 2>&1`; exit 0, `Build complete! (10.18s)`.
- V2 `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventOverlapPolicyTests|EventOverlapContractValidationTests|RoutineStoreTests|EventRoutineBindingTests|EventDryRunTests|WorkflowLoopValidationTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v2-core-events-current.log 2>&1`; exit 0, 60 tests, 0 failures.
- V3 `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServe|EventReadOnlyPolicyTests|OverlapPolicyInspectionTests|RoutineCommandTests|RoutineGraphQLTests|RoutineAddonTests|SurfaceParity|WorkflowCommandLivePersistenceEventTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v3-cli-graphql-current.log 2>&1`; exit 0, 153 tests, 0 failures, 1 skipped.
- V4 regenerated SDL with exit 0 and compared before/after hash with exit 0. Hash stayed `514366f149a04d755c4a5e9f0dac04669aa6f22a`; logs/hashes: `v4-sdl-current.log`, `v4-sdl-hash-before-current.txt`, `v4-sdl-hash-after-current.txt`.
- V5 selected-file command: `git diff --name-only -z 3e6d4adf HEAD -- '*.swift' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/changed-swift-files-current.nul && if [ -s tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/changed-swift-files-current.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/changed-swift-files-current.nul > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint-current.log 2>&1; ...`; manifest is nonempty (NUL-delimited, so `wc -l` is not a valid entry count), selected-file SwiftLint exit 0, no diagnostics. The manifest is preserved at `changed-swift-files-current.nul`.
- V6 ran each binary invocation via `arch -arm64 /bin/zsh -lc '<command>' > <log> 2>&1`: S1 exit 0 printed `status=failed` and the exact unknown binding policy diagnostic; S2 exit 0 printed `status=ok` and `binding=cron-to-arithmetic overlapPolicy=inherit`; S3 exit 1 printed `workflow.triggerDefaults.overlapPolicy` with `must be one of skip, cancelRunning, queue, concurrent`; S4 exit 0 printed `triggerDefaults: overlapPolicy=queue maxQueuedRuns=2`. Complete current logs: `s1-current.log` through `s4-current.log`.
- V7 `git diff --check > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-final-current.log 2>&1`; exit 0.
- README index check still matches line 58; README hash remains `3e5b5b5b00aa5727339ee324bbb4e2949bbe6426`. No `Sources/` or `Tests/` edits were made. No implementation findings were handed back. Formal integration/adversarial review and later workflow finalization remain downstream.
