# Session store efficiency and default GC: implementation plan index

**Status**: Ready
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md (accepted at step 3, comm-010590)
**User QA**: design-docs/user-qa/qa-session-storage-default-gc.md (Q1-Q7 defaults assumed)
**Created**: 2026-10-30
**Branch**: feat/message-log-storage-gc (gitPush=false; local commits only)

## Intent

The runtime session store
`<session-root>/runtime-records/runtime-message-log.sqlite` grows to many GiB.
This plan set has three parts:

- **(A)** Store new execution payloads in a reduced form (inputSnapshot
  fragment dedup).
- **(B1)** Apply a built-in default retention policy when no config is present.
- **(B2)** Make automatic maintenance convert legacy rows and reclaim pages at
  run end and in scheduler hosts.
- **(B3)** Report the remaining reclaimable space and the recovery path in
  `riela doctor storage`.

This file is the index. Each plan file below is a self-contained executable
contract.

## Plans and waves (DAG)

| Wave | planId | Plan file | dependsOn | Design sections |
| --- | --- | --- | --- | --- |
| W1 | sgc-01-payload-fragments | impl-plans/active/session-storage-gc-01-payload-fragments.md | — | §3 |
| W1 | sgc-02-default-retention | impl-plans/active/session-storage-gc-02-default-retention.md | — | §4 |
| W2 | sgc-03-automatic-maintenance | impl-plans/active/session-storage-gc-03-automatic-maintenance.md | sgc-02 | §5 |
| W3 | sgc-04-doctor-storage | impl-plans/active/session-storage-gc-04-doctor-storage.md | sgc-02, sgc-03 | §6 |
| W3 | sgc-05-docs | impl-plans/active/session-storage-gc-05-docs.md | sgc-01, sgc-02, sgc-03 | §7 |

Why the dependencies exist:

- **sgc-03 on sgc-02.** sgc-03 gates maintenance on
  `RielaRetentionConfiguration.effectivePolicy(for:).policy.automatic`, which
  sgc-02 adds.
- **sgc-04 on sgc-02 and sgc-03.**
  - sgc-04 decodes `StorageMaintenanceCursor`, which sgc-03 adds.
  - Its tests change because `pruneEstimateBytes` now reflects the sgc-02
    defaults.
- **sgc-05 on sgc-01, sgc-02 and sgc-03.** It documents shipped behavior.

sgc-01 is independent. It runs alongside W1 and W2.

Every plan has disjoint `writePaths`. No plan edits
`Sources/RielaCLI/RielaCLIApplication.swift`, `Package.swift`,
`Sources/RielaCLI/EventLiveServe.swift` or
`Sources/RielaCLI/ServeHTTPCommand.swift`. Those two hosts already call
`AutomaticRetentionHook.runAutomaticPass`, which sgc-03 extends.

## Shared execution rules (every plan)

- **Shell.** Run every `swift build`, `swift test` and `swiftlint` from an
  arm64 shell: `arch -arm64 /bin/zsh -lc '...'`. Write logs under
  `tmp/session-storage-gc/<planId>/`, and record each command's exit status in
  the log, for example with `set -o pipefail; ... 2>&1 | tee <log>; echo
  "exit=$?" >> <log>`.
- **Editing.** Read a file fresh immediately before each edit. Record its
  sha256 before and after the edit in your progress log. If the pre-edit hash
  differs from the last hash you recorded, another worker changed the file.
  Re-read it and re-apply only your intent. Never revert another plan's
  changes.
- **Git.** Do not run git commands that change state: no commit, stash,
  checkout, reset, rebase or worktree. Do not create branches or worktrees.
  The workflow commits.
- **Build cache (authorized, untracked).** `.build/` (and `.swiftpm/` if
  SwiftPM touches it) is the pre-existing, gitignored SwiftPM build cache that
  every plan shares.
  - Writes to it by `swift build`, `swift test` and `swiftlint` are
    authorized.
  - Those writes are not tracked writes. They are not part of any plan's
    `writePaths`, `sharedPaths` or `artifactRoots`.
  - No plan installs or downloads tools, so `artifactRoots` is intentionally
    empty for every plan.
  - Do not block on `.build` writes, and do not delete `.build`. If SwiftPM
    reports that the build folder is locked or in use, wait and retry.
- **Test stores.** Tests use temporary, realpath-resolved roots
  (`URL.resolvingSymlinksInPath`, because macOS `/var` is a symlink) and
  injected clocks. They never touch `~/.riela` or any real project store.
- **Scope.** Do not bump `VERSION`, do not release, do not push.
- **Progress log.** Each worker writes only its own progress log,
  `impl-plans/progress/<planId>.md`. Record: changed files with their hashes,
  the commands with exit codes and log paths, the acceptance status, and any
  path outside `writePaths` that needs serial reconciliation. Report such a
  path; do not edit it.
- **Serial reconciliation** (after joining, not owned by any plan):
  - full-target build;
  - swiftlint over all touched files;
  - any test outside the owned files that hard-codes behavior this change
    alters, for example a schema generation of 11 or a "no config means no
    deletion" expectation;
  - archiving this index and the plans.

## Final gate (integration)

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter "Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayloadFragment|SQLiteRuntimeExecutionRows|RuntimePersistenceBoundedWrite|SQLiteRuntimeSchemaMigration|CLIWorkflowSessionEnvelope"'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <touched swift files>'
```
