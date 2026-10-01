# wh-13: `riela gc` sweeps handover files and local handover refs of terminal tasks

```json
{
  "planId": "wh-13-gc-sweep",
  "planPath": "impl-plans/active/wh-13-gc-sweep.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaCore/RielaDataGarbageCollector.swift",
    "Tests/RielaCoreTests/RielaDataGarbageCollectorHandoverTests.swift",
    "impl-plans/progress/wh-13-gc-sweep.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-13-gc-sweep.md"
}
```

## Intent and context

Design §13: `riela gc` learns the file sink layout `<root>/handovers/<taskId>/<handoverId>.{json,md}`
(pinned in wh-09) and the local refs `refs/riela/handovers/<taskId>/<handoverId>`. It keeps packets whose task is
not terminal. The collector is `RielaDataGarbageCollector` in `RielaCore`, which cannot import `RielaWork`. So read the
task state with SQL on the session-store database (`work_tasks.state`, a generated column; verify the column name in
`WorkStore+Schema.swift`). Terminal states are `succeeded, failed, cancelled, superseded`.

Non-goals: deleting remote refs (never push deletions), deleting the `work_handovers` rows (they are ledger), and
retention by age beyond the existing `retentionDays` semantics.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-13-gc-sweep/`,
writePaths only, arm64 logs; tests use temp directories and temp repos; no project-repo git state
changes; own progress log).

## Deliverables

- For each session-store root the collector already visits (read `collect(retentionDays:scope:homeDirectory:projectDirectory:dryRun:)`),
  if `<root>/handovers/` exists, then for each `<taskId>` directory: when the task row is terminal **or absent**, remove
  the directory (in dry-run, only report it). If the row is present and non-terminal, keep it. Add report entries in the
  existing report structure (a new category name `handoverFiles`).
- In `projectDirectory`, if it is a git repository, list `git for-each-ref --format=%(refname) refs/riela/handovers/`.
  For refs whose `<taskId>` is terminal or absent in that project's store, run `git update-ref -d <ref>` (dry-run reports only).
  Run git through `Foundation.Process` with `/usr/bin/env git`, `GIT_TERMINAL_PROMPT=0` and a timeout, in the style
  of any existing process helper in `RielaCore` (search `Process()` in RielaCore; reuse, don't duplicate a helper
  if one exists). Report category `handoverRefs`.
- The task database may be missing or locked: skip with a diagnostic entry and delete nothing (fail closed).

## Tests (`RielaDataGarbageCollectorHandoverTests`)

- a store with task A `succeeded` and task B `waiting`, plus handover dirs for A, B and C (no row) → A and C removed, B kept; dry-run removes nothing
  and reports all three decisions
- a temp git repo with refs for A and B → A's ref deleted, B's kept; no remote contacted
- a missing database → nothing deleted, diagnostic reported

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-13-gc-sweep/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-13-gc-sweep/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "RielaDataGarbageCollector|GarbageCollection" > tmp/work-handover/wh-13-gc-sweep/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-13-gc-sweep/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count; the existing gc tests must stay green.

## Done criteria

- [x] File and ref sweeps are implemented fail-closed with dry-run; the tests pass; the progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-13-gc-sweep.md`. Archived to `impl-plans/completed/`.
