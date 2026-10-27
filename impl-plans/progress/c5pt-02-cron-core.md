# c5pt-02-cron-core implementation progress

Status: implementation complete; ready for downstream review.

## Changes

- Added `CronSchedule.previousOccurrence(before:calendar:)` in `Sources/RielaCore/CronSchedule.swift`. It starts at the greatest whole second strictly before the input, uses a calendar-relative nine-year horizon, and skips mismatching month/day/hour/minute units with guarded `Calendar.dateInterval` starts. Seconds advance one at a time. No `Date()`, global state, force unwrap, fixed-duration coarse jump, or `dueTicks` call was added.
- Factored second, minute, hour, month, and dom/dow predicates into private shared helpers. `matches(_:calendar:)` keeps its signature and calendar component extraction; `maximumCatchUpSeconds = 3_600` is unchanged.
- Added 14 XCTest methods in `Tests/RielaCoreTests/CronSchedulePreviousOccurrenceTests.swift`, covering all ten plan table rows, dom/dow OR, fractional and integral strictness, and 20 seeded brute-force comparisons across Tokyo/New York DST windows.

## Verification

- `arch -arm64 /bin/zsh -lc "swift test --filter 'CronSchedulePreviousOccurrenceTests|EventLiveServeCronTests' > tmp/crypto5-prevtick/c5pt-02-cron-core/test.log 2>&1; test_exit_code=$?; printf 'exit=%s\\n' \"$test_exit_code\" >> tmp/crypto5-prevtick/c5pt-02-cron-core/test.log; echo exit=$test_exit_code"` — exit 0; 22 tests passed, 0 failures. Complete log: `tmp/crypto5-prevtick/c5pt-02-cron-core/test.log`.
- `arch -arm64 /bin/zsh -lc 'if [ -s tmp/crypto5-prevtick/c5pt-02-cron-core/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/crypto5-prevtick/c5pt-02-cron-core/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi; lint_exit_code=$?; printf "exit=%s\\n" "$lint_exit_code" >> tmp/crypto5-prevtick/c5pt-02-cron-core/lint.log; echo exit=$lint_exit_code'` — exit 0. The NUL-delimited manifest contains only the two changed Swift files. Complete log: `tmp/crypto5-prevtick/c5pt-02-cron-core/lint.log`.
- API and catch-up constant checks: `tmp/crypto5-prevtick/c5pt-02-cron-core/api-symbol.log` and `tmp/crypto5-prevtick/c5pt-02-cron-core/catchup-constant.log`, both exit 0.

## Acceptance

- Previous occurrence API and documented strict whole-second/nine-year contract: complete.
- DST-aware coarse-to-fine scan; shared match predicates; unchanged catch-up constant: complete.
- Required edge cases and brute-force equivalence; at least 12 tests: 14 tests, complete.
- Focused cron/event tests and changed-file strict lint: pass.

No plan-local blocker. Envelope wiring, broader integration review, commit, and push remain owned by downstream plans or workflow steps.
