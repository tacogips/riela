# ISW2-27c implementation progress

**Plan:** [ISW2-27c-session-reconcile](../active/issue-sweep-2-20261024-27c-session-reconcile.md)  
**Issue:** `tacogips/riela#27` (P4)  
**Workflow mode:** full issue-resolution  
**Codex agent:** step6-implement (GPT-6 Luna)

## Implementation

- Added `riela session reconcile` parsing, routing, help text, CLI surface
  enumeration, and the `session.reconcile` catalog row.
- Candidate discovery uses scalar SQL over running CLI rows and canonical
  snapshots. A single `SessionExecutionLockRegistry` is used for the sweep;
  locks remain held over apply rereads and saves and are released with `defer`.
- Dry runs write no records. Apply marks still-running orphan records and
  canonical snapshots `cancelled`, cancels running executions with the stable
  reason `runner process lost; reconciled by riela session reconcile`, and
  leaves lock-held live sessions untouched.
- `blocksResume` treats cancelled as terminal. The FailClosed terminal
  persistence hook and deferral predicates now use `session.status.isTerminal`;
  the ISW2-32 family hydration code remains present.
- Added focused command tests and
  [session cancellation and reconcile docs](../../../docs/session-cancellation-and-reconcile.md)
  covering cancellation, gateway behavior, flock verdicts, P3, and P5.

## Final-source verification

| Command | Exit | Tests | Failures | Log | Outcome |
| --- | ---: | ---: | ---: | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/build.log 2>&1; result=$?; printf "exitStatus=%s\\n" "$result" >> tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/build.log; exit "$result"'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/build.log` | Build complete. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SessionReconcileCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|CommandParsingTests" > tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/focused.log 2>&1; result=$?; printf "exitStatus=%s\\n" "$result" >> tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/focused.log; exit "$result"'` | 0 | 52 | 0 | `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/focused.log` | Reconcile, CLI parity, catalog, and command parsing selected tests all pass. |
| `arch -arm64 /bin/zsh -lc 'mkdir -p tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/empty-store; .build/debug/riela session reconcile --session-store "$PWD/tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/empty-store" --output json > tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/cli-smoke.log 2>&1; result=$?; printf "exitStatus=%s\\n" "$result" >> tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/cli-smoke.log; exit "$result"'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/cli-smoke.log` | JSON reports dry run and an empty session list. |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/changed-swift-files.nul'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/lint.log` | Strict SwiftLint on the exact eight-file changed Swift manifest. |
| `arch -arm64 /bin/zsh -lc 'if grep -n "status == .completed || session.status == .failed" Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift > tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/failclosed-grep.matches; then cat tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/failclosed-grep.matches; printf "unexpected matches\\n"; result=1; else grep_status=$?; if [ "$grep_status" -eq 1 ]; then printf "empty: cancelled terminal predicates use isTerminal\\n"; result=0; else result=$grep_status; fi; fi; printf "exitStatus=%s\\n" "$result" > tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/failclosed-grep.log; exit "$result"'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/failclosed-grep.log` | No old completed-or-failed terminal predicates found. |

## Prior attempts

- The lowercase `tmp/issue-sweep-2-20261024/isw2-27c/` logs are historical
  attempts. Their focused aggregate predates the operator's cache catalog
  parity fix and failed with that known mismatch; current-source evidence is
  the passing aggregate under `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/`.
- An earlier SwiftLint attempt reported one `control_statement` violation in
  `SessionReconcileCommand.swift`; it was corrected before the current strict
  lint run, whose log is in the current-source evidence directory.
- An initial build wrapper used Zsh's read-only variable name `status` and
  lacked a usable exit record. Later successful build evidence is recorded in
  the current-source directory.

## Test-integrity repair

- Addressed `ISW2-27c-TI-1` in
  `Tests/RielaCLITests/SessionReconcileCommandTests.swift` by preserving the
  existing exit-code and execution-count assertions and asserting that the
  structured failure output contains `cannot be resumed normally`. This makes
  the test discriminate the cancelled `blocksResume` guard from workflow
  resolution failure.
- Re-ran the required focused filter: exit 0, 52 tests, 0 failures, including
  the revised test; complete log:
  `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/focused.log`.
- Re-ran strict lint through the eight-file NUL manifest: exit 0; complete log:
  `tmp/issue-sweep-2-20261024/ISW2-27c-session-reconcile/lint.log`.
- `SessionCommands.swift` and `FailClosedSQLiteWorkflowRuntimeStore.swift`
  remain byte-identical to their pre-repair content, verified by matching
  SHA-256 hashes recorded under the plan-local evidence directory.

## Completion

Implementation, documentation, and assigned behavioral verification are
complete on the current tree. The earlier cache catalog parity failure was
resolved by the operator amendment; the refreshed aggregate now passes. The
test-integrity repair is ready for independent re-review; workflow finalization
remains downstream.
