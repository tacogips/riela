# Automatic retention: plan set index

Mode: `issue-resolution`. Issue: workflowInput `automatic-config-driven-retention`
("Automatic, config-driven retention for Riela session results, messages and
logs"). There is no GitHub issue number. Codex-agent references: none.

Design: `design-docs/specs/design-automatic-retention.md` (accepted by Step 3),
with the baseline in `design-docs/specs/scoped-terminal-retention.md` and the
non-blocking defaults in `design-docs/user-qa/qa-automatic-retention.md`.

This file is an index. No worker edits it. Serial finalization updates it, along
with `impl-plans/README.md` and `impl-plans/PROGRESS.json`.

## Waves

Resume status (2026-10-19): ar-01..ar-06 were accepted by integration review in session 452 and
are committed in 10e9aa6e. The dispatch manifest lists only the pending plans ar-07, ar-08 and
ar-09; do not add the accepted plans back to it.

| Wave | planId | Plan | dependsOn |
|---|---|---|---|
| done | ar-01-core-config | `automatic-retention-01-core-config.md` | accepted, committed in 10e9aa6e |
| done | ar-02-core-planners | `automatic-retention-02-core-planners.md` | accepted, committed in 10e9aa6e |
| done | ar-03-cli-reclaimer | `automatic-retention-03-cli-reclaimer.md` | accepted, committed in 10e9aa6e |
| done | ar-04-cli-lock-admission | `automatic-retention-04-cli-lock-admission.md` | accepted, committed in 10e9aa6e |
| done | ar-05-cli-executor | `automatic-retention-05-cli-executor.md` | accepted, committed in 10e9aa6e |
| done | ar-06-cli-targets-logs | `automatic-retention-06-cli-targets-logs.md` | accepted, committed in 10e9aa6e |
| 3 | ar-07-cli-service-gc-docs | `automatic-retention-07-cli-service-gc-docs.md` | none (ar-05, ar-06 accepted in 10e9aa6e) |
| 4 | ar-08-cli-triggers | `automatic-retention-08-cli-triggers.md` | ar-07 |
| 4 | ar-09-app-legacy-removal | `automatic-retention-09-app-legacy-removal.md` | ar-07 |

The `writePaths` of all plans are disjoint. The `sharedPaths` are touched by
exactly one plan each, and only for the narrow edit named in that plan's
`sharedPathNotes`.

## Shared worker protocol

Every plan copies this protocol.

- **Workspace.** Work in branch `feat/automatic-retention`, worktree
  `/Users/taco/gits/tacogips/riela/tmp/automatic-retention-worktree`. Do not create
  branches or worktrees. Do not run `git commit`, `stash`, `reset`, `checkout` or
  `add`. The serial finalization step commits.
- **Edit scope.** Edit only your `writePaths`. Edit a `sharedPaths` entry only for
  the edit named in your `sharedPathNotes`.
- **Hash every edit.** Before each edit:
  1. Read the file fresh.
  2. Record `shasum -a 256 <file>` (the pre-hash) and a one-line intent snapshot
     in your progress log.
  3. After the edit, record the post-hash.

  If a pre-hash differs from your last recorded post-hash for that file, another
  writer changed it. Re-read the file, re-apply your intent on top, never revert
  the foreign change, and log the drift.
- **Peer build breakage.** If the build fails in a file outside your
  `writePaths`, log it as peer drift and retry up to 3 times, a few minutes apart.
  Never edit that file. Treat SwiftPM `.build` lock contention as a reason to
  wait and retry.
- **Scratch files.** Scratch files and logs go only under
  `tmp/automatic-retention/<planId>/`.
- **Test roots.** Tests create roots under `<cwd>/tmp/<suite>-<UUID>`, following
  `Tests/RielaCLITests/GarbageCollectionCommandTests.swift:makeRoot` and
  `Tests/RielaCLITests/TerminalRetentionTests.swift:fixture`. Never use
  `/var/folders` (its `/var` symlink is rejected by `TerminalRetentionPaths`) and
  never the real `~/.riela`. Use fake clocks (`Date(timeIntervalSince1970:
  1_800_000_000)`).
- **Progress log.** Write to `impl-plans/progress/<planId>.md` only. It holds:
  - task checkboxes;
  - the hash records;
  - one record per verification, as `{command, logPath, exitStatus, testsRun,
    failureCount}` with integer values. `testsRun` and `failureCount` come from
    the `Executed N tests, with F failures` lines, summed across bundles.

  Note and residual-risk text never starts with a severity word.
- **Commands.** Run all commands in the foreground, from an arm64 shell, in this
  form:

  ```
  arch -arm64 /bin/zsh -lc 'swift test --filter <Suite> > tmp/automatic-retention/<planId>/<name>.log 2>&1'
  ```

  Lint with:

  ```
  arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache <files> > tmp/automatic-retention/<planId>/swiftlint.log 2>&1'
  ```

## Final gate (serial finalization, not a per-plan gate)

```
arch -arm64 /bin/zsh -lc 'swift build && swift test --filter "Retention|GarbageCollection|GarbageCollector|SessionPrune|SessionExecutionLock|CommandParsing"'
```

The gate also runs `swiftlint lint --quiet --no-cache` on every touched Swift
file. A full `swift test` run is not a gate.
