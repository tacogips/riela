# wh-00: Full-suite baseline before any source edit

**Status**: Completed 2026-09-30 in session `opus-luna-design-and-implement-review-loop-session-228`. Evidence: `impl-plans/progress/wh-00-baseline.md`. Removed from the dispatch DAG; later plans no longer depend on it.

```json
{
  "planId": "wh-00-baseline",
  "planPath": "impl-plans/active/wh-00-baseline.md",
  "wave": "W0 (serial)",
  "dependsOn": [],
  "writePaths": ["impl-plans/progress/wh-00-baseline.md"],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-00-baseline.md"
}
```

## Intent and context

Every later failure must be classified against a recorded baseline (umbrella
§Verification). The branch head at planning time differs from base commit
`01b38f02` only in `design-docs/` and `impl-plans/`. So a baseline taken on the
current head, before any wave-1 edit, is the base-commit baseline for code.

Non-goals: do not fix any failure, do not edit sources or tests, and do not rerun until green.

## Tasks

- [x] Prove there is no code drift: `git diff --stat 01b38f02 -- Sources Tests Package.swift Package.resolved examples Resources`
      must print nothing. Record the output and `git rev-parse HEAD`.
- [x] `mkdir -p tmp/work-handover/wh-00`, then build and run the full serial suite:
  - `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-00/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-00/build.log'`
  - `arch -arm64 /bin/zsh -lc 'swift test > tmp/work-handover/wh-00/full-swift-test.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-00/full-swift-test.log'`
    (`swift test` is serial by default. Do not pass `--parallel`.)
- [x] Extract every failing test (`error: -[… ]` / `failed (` lines) into
      `tmp/work-handover/wh-00/baseline-failures.txt`, sorted and unique, with the
      total executed/failed/skipped counts from the summary line.
- [x] Record in the progress log: HEAD, the drift proof, both log paths, both `exit=`
      lines, counts and the failure list. Tag known environment-dependent tests
      (for example the interleaved-submit timing flake) as `known-flake` only when the log shows it.

## Acceptance

The logs end with `exit=` lines, and the summary line gives counts. The failure list is
committed only as text inside the progress log (the scratch files stay in `tmp/`).
If the suite cannot finish (crash or hang past 90 minutes), record that as a
blocked baseline with the partial log path. Later plans then classify against it
as "baseline incomplete".
