# Progress: ar-08-cli-triggers

Workflow mode: `issue-resolution`
Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number)
Codex-agent reference: `/root`, Step 6 implementation
Plan: `impl-plans/completed/automatic-retention-08-cli-triggers.md`
Branch: `feat/automatic-retention`
Accepted dependency: `ar-07-cli-service-gc-docs` (present in runtime-owned `acceptedPlanIds`).

## Implemented scope

Added `AutomaticRetentionHook` with command eligibility, lenient request parsing, and a non-throwing automatic pass that maps config/target failures to `riela retention warning:` stderr lines. `RielaCLIMain.run` invokes it after existing stdout/stderr writes and before the unchanged exit code; it skips usage/help/cancelled and unrelated commands. No hook was added to `RielaCLIApplication.run`.

Unbounded `events serve` now starts the retention scheduler after serve configuration and readiness succeed. Bounded event serving does not start it. Bare `riela serve` starts the same scheduler before its long sleep. Both use `runImmediately: false`, write warnings only to stderr, and stop through `defer` on return, cancellation, or later errors.

Added six `AutomaticRetentionTests`: command eligibility, request parsing, temp-HOME no-config behavior, corrupt-config warning, `automatic: false`, and a mock workflow acceptance case. The acceptance test runs the example workflow twice, backdates both SQLite timestamps for both sessions against the injected clock, and verifies that only the old terminal session is pruned while captured stdout and exit code remain unchanged.

Strict SwiftLint initially reported the existing event-serve coordinator's function-body limit. The same diagnostic is present in the committed `HEAD` copy at 208 lines (`tmp/automatic-retention/ar-08-cli-triggers/swiftlint-event-baseline.log`). Scheduler setup was extracted into a focused helper; one `function_body_length` suppression remains on that existing orchestration method with a reason comment. Other strict rules remain enabled and the exact changed-file gate is clean.

## Acceptance status

- Post-run hook eligibility, request resolution, warning handling, and output/exit preservation: implemented and behaviorally covered.
- Unbounded `events serve` and bare `serve` scheduler lifecycle: implemented; bounded event serve remains scheduler-free.
- `AutomaticRetentionTests`: pass, 6 tests and 0 failures.
- `riela` product build: pass.
- Temp-HOME mock workflow run: pass; stdout is completed workflow JSON, exit status 0, and the 20-day-old log was removed under `logs.maxAgeDays: 14`.
- Strict changed-file SwiftLint: pass with empty log. NUL manifest: `tmp/automatic-retention/ar-08-cli-triggers/changed-swift-files.nul`.
- `git diff --check` and the three plan wiring checks: pass.
- RielaApp startup/periodic wiring and legacy removal belong to downstream plan `ar-09-app-legacy-removal`; formal review, integration, and serial finalization also remain downstream.

## Current-source verification

The first verification set below passed before the final event-scheduler placement adjustment. The following post-adjustment records are the final-source gates and supersede those earlier logs.

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter AutomaticRetentionTests > tmp/automatic-retention/ar-08-cli-triggers/test.log 2>&1'` | 0 | 6 | 0 | Complete log: `tmp/automatic-retention/ar-08-cli-triggers/test.log`. |
| `arch -arm64 /bin/zsh -lc 'swift build --product riela > tmp/automatic-retention/ar-08-cli-triggers/build.log 2>&1'` | 0 | 0 | 0 | Complete log: `tmp/automatic-retention/ar-08-cli-triggers/build.log`. |
| `set +e; repo_root=$PWD; test_home="$repo_root/tmp/automatic-retention/ar-08-cli-triggers/home-final"; HOME="$test_home" .build/debug/riela workflow run worker-only-single-step --workflow-definition-dir "$repo_root/examples" --mock-scenario "$repo_root/examples/worker-only-single-step/mock-scenario.json" --session-store "$test_home/.riela/sessions" --working-dir "$test_home" --output json > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.stdout 2> tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.stderr; exit_code=$?; printf '%s\\n' "$exit_code" > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.exit-status; exit "$exit_code"` | 0 | 0 | 0 | Exit file `tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.exit-status`; stdout/stderr: `mock-run-final.stdout` and `mock-run-final.stderr`; validation: `mock-run-final-check.log` (`validRunJSON=true`, `staleLogRemoved=true`). |
| `test "$(cat tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.exit-status)" = 0 && jq -e '.status == "completed" and .exitCode == 0 and .session.status == "completed"' tmp/automatic-retention/ar-08-cli-triggers/mock-run-final.stdout > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-json-check.log && test ! -e tmp/automatic-retention/ar-08-cli-triggers/home-final/.riela/logs/old.jsonl` | 0 | 0 | 0 | Both JSON and stale-log assertions passed. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/automatic-retention/ar-08-cli-triggers/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/automatic-retention/ar-08-cli-triggers/swiftlint.log 2>&1` | 0 | 0 | 0 | Empty strict lint log. |
| `git diff --check > tmp/automatic-retention/ar-08-cli-triggers/diff-check.log 2>&1` | 0 | 0 | 0 | Empty diff-check log. |
| `rg -n 'AutomaticRetentionHook.runIfApplicable' Sources/RielaCLI/EntryPoint.swift; rg -n 'RielaRetentionScheduler\\(' Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/ServeHTTPCommand.swift; if rg -n 'AutomaticRetentionHook' Sources/RielaCLI/RielaCLIApplication.swift; then exit 1; else printf '%s\\n' 'No AutomaticRetentionHook in RielaCLIApplication.swift'; fi` | 0 | 0 | 0 | Hook matched EntryPoint, both schedulers matched, and app-level hook was absent. |

### Final-source rerun after event lifecycle placement adjustment

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter AutomaticRetentionTests > tmp/automatic-retention/ar-08-cli-triggers/test-final-002.log 2>&1'` | 0 | 6 | 0 | Complete final-source log: `tmp/automatic-retention/ar-08-cli-triggers/test-final-002.log`. |
| `arch -arm64 /bin/zsh -lc 'swift build --product riela > tmp/automatic-retention/ar-08-cli-triggers/build-final-002.log 2>&1'` | 0 | 0 | 0 | Complete final-source log: `tmp/automatic-retention/ar-08-cli-triggers/build-final-002.log`. |
| `set +e; repo_root=$PWD; test_home="$repo_root/tmp/automatic-retention/ar-08-cli-triggers/home-final-002"; HOME="$test_home" .build/debug/riela workflow run worker-only-single-step --workflow-definition-dir "$repo_root/examples" --mock-scenario "$repo_root/examples/worker-only-single-step/mock-scenario.json" --session-store "$test_home/.riela/sessions" --working-dir "$test_home" --output json > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002.stdout 2> tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002.stderr; exit_code=$?; printf '%s\\n' "$exit_code" > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002.exit-status; exit "$exit_code"` | 0 | 0 | 0 | Stdout/stderr/exit files: `mock-run-final-002.stdout`, `mock-run-final-002.stderr`, `mock-run-final-002.exit-status`; `mock-run-final-002-check.log` confirms completed JSON and stale log removal. |
| `test "$(cat tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002.exit-status)" = 0 && jq -e '.status == "completed" and .exitCode == 0 and .session.status == "completed"' tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002.stdout > tmp/automatic-retention/ar-08-cli-triggers/mock-run-final-002-json-check.log && test ! -e tmp/automatic-retention/ar-08-cli-triggers/home-final-002/.riela/logs/old.jsonl` | 0 | 0 | 0 | Both JSON and stale-log assertions passed. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/automatic-retention/ar-08-cli-triggers/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/automatic-retention/ar-08-cli-triggers/swiftlint-final-002.log 2>&1` | 0 | 0 | 0 | Empty final strict lint log. |
| `git diff --check > tmp/automatic-retention/ar-08-cli-triggers/diff-check-final-002.log 2>&1` | 0 | 0 | 0 | Empty final diff-check log. |
| `rg -n 'AutomaticRetentionHook.runIfApplicable' Sources/RielaCLI/EntryPoint.swift; rg -n 'RielaRetentionScheduler\\(' Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/ServeHTTPCommand.swift; if rg -n 'AutomaticRetentionHook' Sources/RielaCLI/RielaCLIApplication.swift; then exit 1; else printf '%s\\n' 'No AutomaticRetentionHook in RielaCLIApplication.swift'; fi` | 0 | 0 | 0 | Final wiring check: hook in EntryPoint, both scheduler constructors found, and no hook in RielaCLIApplication. Full output: `tmp/automatic-retention/ar-08-cli-triggers/wiring-check-final-002.log`. |

## Prior attempts

- `test-initial.log` preserves the first compilation failure from invalid single-line triple-quoted JSON literals. The literals were corrected.
- The first runtime test log (subsequently replaced by the final `test.log`) showed the test decoder needed ISO-8601 handling; corrected to match CLI output.
- The second runtime test log (subsequently replaced by the final `test.log`) showed `defaultDatabasePath` was being passed an already-canonicalized root; corrected to pass the session-store root.
- `mock-run.stdout`, `mock-run.stderr`, and `mock-run.exit-status` preserve the first CLI probe failure (exit 1): relative `--workflow-definition-dir examples` resolved under the temporary working directory. The retry uses absolute repository paths and passed.
- `swiftlint-event-baseline.log` records the strict lint result for the committed `HEAD` EventLiveServe source: exit 2 on the pre-existing 208-line `function_body_length` diagnostic. The changed-file gate passes with the localized suppression.

## Final source SHA-256

- `Sources/RielaCLI/AutomaticRetentionHook.swift`: `7666c45429f80af4a30b6b922c6185c375ffdab25e31686a799ea51e1bdfa5b7`
- `Tests/RielaCLITests/AutomaticRetentionTests.swift`: `d79177c9b33fb0b0b80b889320075794e2a86b6e3629b36c7516db8936133f7b`
- `Sources/RielaCLI/EntryPoint.swift`: `47cf7240c0fea1ce3bd908ec869242d4070b4dd309fd010fc6c096feec9a4dd7`
- `Sources/RielaCLI/EventLiveServe.swift`: `6fbf1a1f91c9b47d21d793ef91351077fc5eec468bd4cc194d543b4dd41bd14f`
- `Sources/RielaCLI/ServeHTTPCommand.swift`: `ebc8040231fb51bd19b263a4009becbece633f04e30aab6d5505c9e9dcddd35b`

Implementation-phase acceptance for this plan is complete. No formal review, serial integration acceptance, commit, or push is claimed here.

## Step 6 retry after output-contract rejection

The earlier fanout response was rejected because `$.workflowMode` was not allowed by that output schema; the branch also had no typed test-integrity/adversarial decisions, so it was not accepted by those review gates. The current-source implementation was retained; no source files required repair for the supplied feedback. This response records implementation evidence only and does not claim formal review approval.

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter AutomaticRetentionTests > tmp/automatic-retention/ar-08-cli-triggers/test-step6-retry-002.log 2>&1'` | 0 | 6 | 0 | Complete log: `tmp/automatic-retention/ar-08-cli-triggers/test-step6-retry-002.log`. |
| `arch -arm64 /bin/zsh -lc 'swift build --product riela > tmp/automatic-retention/ar-08-cli-triggers/build-step6-retry.log 2>&1'` | 0 | 0 | 0 | Complete log: `tmp/automatic-retention/ar-08-cli-triggers/build-step6-retry.log`. |
| `HOME=<repo>/tmp/automatic-retention/ar-08-cli-triggers/home-step6-retry .build/debug/riela workflow run worker-only-single-step --workflow-definition-dir <repo>/examples --mock-scenario <repo>/examples/worker-only-single-step/mock-scenario.json --session-store <repo>/tmp/automatic-retention/ar-08-cli-triggers/home-step6-retry/.riela/sessions --working-dir <repo>/tmp/automatic-retention/ar-08-cli-triggers/home-step6-retry --output json` | 0 | 0 | 0 | Captured stdout/stderr/exit status in `mock-run-step6-retry.stdout`, `.stderr`, and `.exit-status`; JSON and stale-log assertions passed in `mock-run-step6-retry-check.log` and `mock-run-step6-retry-json-check.log`. The fixture log was 20 days old with `logs.maxAgeDays: 14`. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/automatic-retention/ar-08-cli-triggers/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | Complete empty lint output: `tmp/automatic-retention/ar-08-cli-triggers/swiftlint-step6-retry.log`; selected NUL-delimited paths are listed in `changed-swift-files.nul`. |
| `git diff --check` | 0 | 0 | 0 | Passed on the current shared tree. |

A first test retry command used `status` as a zsh variable and exited before emitting the test command's status because that variable is read-only. Its transcript remains in `test-step6-retry.log`; it is not counted as passing evidence. The corrected command above is the verification record.

## Test-integrity repair: running session under byte cap

The plan's "Tests" section requires a test that a running session is untouched by the hook pass under a 1-byte cap. It had been displaced by the `automatic:false` test. Added `testHookKeepsRunningSessionUnderByteCapWhilePruningTerminalSession` to `Tests/RielaCLITests/AutomaticRetentionTests.swift` (only test-file change; no `Sources/` change).

- Config `retention.results.maxTotalBytes: 1`; two real mock runs (separate root families, asserted); `updated_at` of both sessions set to `fixedNow - 3 days` in both `workflow_runtime_snapshots` and `cli_workflow_sessions`, so age does not protect the running session and the timestamp is not `unknownOrFutureTimestamp`.
- Session B is marked running by rewriting the JSON the generated status columns derive from: `UPDATE workflow_runtime_snapshots SET session_json = jsonb_set(session_json,'$.status','running') WHERE workflow_execution_id = ?` and `UPDATE cli_workflow_sessions SET record_json = jsonb_set(record_json,'$.session.status','running') WHERE session_id = ?`. The test asserts before the hook that `session_status`/`status` read `running` for B and `completed` for A in both tables.
- The hook (`AutomaticRetentionHook.runIfApplicable` with an injected clock) yields no warnings, the completed session A is pruned (proving the pass ran under cap pressure), and running session B remains in `loadAll()`.
- Verification: `swift test --filter AutomaticRetentionTests` exit 0, "Executed 7 tests, with 0 failures" (log `tmp/automatic-retention/ar-08-cli-triggers/test-integrity/repair-test.log`); `swiftlint lint --strict --quiet --no-cache` on the test file exit 0 (`repair-swiftlint.log`). Intent: `test-integrity/edit-intent-running-session-test.md`.
