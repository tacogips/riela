# ssg2: session store efficiency and default GC — implementation plan index

**Archived 2026-10-30 (session 564)**: `ssg2-01`, `-02` and `-04` … `-07`
were accepted in sessions 562/563. `ssg2-03` and `ssg2-08` are superseded by
`ssg3-01` and `ssg3-02` (manifest `impl-plans/active/ssg3-dispatch.json`,
design §13). The paths below are historical and now under
`impl-plans/completed/`.

**Status**: Ready
**Design reference**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
(revised and accepted at step 3, 2026-10-30; §12 defines this partition).
**User QA**: `design-docs/user-qa/qa-session-storage-default-gc.md` (Q1-Q9
defaults assumed; none blocking).
**Branch**: `feat/message-log-storage-gc` (`gitPush=false`; local commits by
the workflow only).
**Supersedes**: `impl-plans/completed/session-storage-gc*.md` and
`impl-plans/completed/session-storage-gc-dispatch.json` (archived unexecuted).
The `impl-plans/progress/sgc-0*.md` logs are history. No ssg2 plan reads or
continues them; every ssg2 plan starts its own fresh progress log.

## Intent

`<session-root>/runtime-records/runtime-message-log.sqlite` grows to many GiB.
This plan set finishes the accepted design:

- reduced execution payloads (`inputSnapshot` fragment dedup), §3;
- built-in default retention, §4 (implemented as sgc-02; reviewed here);
- bounded automatic maintenance in every host, §5;
- `riela doctor storage` reporting, §6, and docs, §7;
- the `riela gc` read-only snapshot fix and the `storage compact`
  `workRemaining` fix, §10;
- test isolation from the developer's `~/.riela`, §11.

## Preserved uncommitted work (do not discard)

Design §1.1 lists it. In short:

- default retention: `Sources/RielaCore/RielaRetentionConfiguration.swift`,
  `Sources/RielaCore/RielaRetentionReport.swift`,
  `Sources/RielaCLI/RielaRetentionService.swift`,
  `Sources/RielaCLI/GarbageCollectionCommand.swift` and their tests;
- generation-12 schema: `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`,
  `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`,
  `Sources/RielaCLI/TerminalRetentionExecutor.swift`,
  `Sources/RielaCLI/SessionRetentionTombstones.swift`;
- `Sources/RielaCLI/StorageMaintenanceCursor.swift` (untracked) and the
  `--scope` selection in `Sources/RielaCLI/AutomaticRetentionHook.swift`.

Never `git checkout`, `git restore`, `git stash` or reset these files. Edit
them in place.

## Plans and waves (DAG)

| Wave | planId | Plan file | dependsOn | Design § |
|---|---|---|---|---|
| W1 | ssg2-01-fragment-writer | `impl-plans/active/ssg2-01-fragment-writer.md` | — | §3.1-3.3 Guard, §3.5 |
| W1 | ssg2-04-legacy-conversion | `impl-plans/active/ssg2-04-legacy-conversion.md` | — | §5.3 Step 1 |
| W1 | ssg2-06-default-retention-review-isolation | `impl-plans/active/ssg2-06-default-retention-review-isolation.md` | — | §4.6, §11, §5.1 parameter |
| W2 | ssg2-02-fragment-hydration | `impl-plans/active/ssg2-02-fragment-hydration.md` | ssg2-01 | §3.4 |
| W2 | ssg2-05-maintenance-host-wiring | `impl-plans/active/ssg2-05-maintenance-host-wiring.md` | ssg2-04, ssg2-06 | §5.1-5.4 |
| W2 | ssg2-07-gc-readonly-workremaining | `impl-plans/active/ssg2-07-gc-readonly-workremaining.md` | ssg2-06 | §10 |
| W3 | ssg2-03-fragment-release-benchmark | `impl-plans/active/ssg2-03-fragment-release-benchmark.md` | ssg2-02, ssg2-06 | §3.2 Cascade, §3.6 |
| W4 | ssg2-08-doctor-docs | `impl-plans/active/ssg2-08-doctor-docs.md` | ssg2-03, ssg2-05, ssg2-07 | §6, §7 |

Why the dependencies exist:

- **01 → 02 → 03.** They share
  `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`,
  `+NestedInvocations.swift` and the encoder file. The write-switch default
  becomes `true` only in 03, after release is fully reference-aware. The
  release guard ships in 01, so 02's terminal-session parity tests keep their
  fragments.
- **05 on 04 and 06.** 05 calls 04's `StorageMaintenanceConversion.run` and
  edits `AutomaticRetentionHook.swift` after 06 adds the `currentDirectory`
  parameter and the isolation helper.
- **07 on 06.** Both edit `Sources/RielaCLI/RielaRetentionService.swift`,
  `Tests/RielaCLITests/GarbageCollectionCommandTests.swift` and
  `Tests/RielaCLITests/StorageCompactCommandTests.swift`.
- **08 last.** It decodes the 04 cursor, depends on the 06 defaults for prune
  estimates, and documents shipped behavior from every plan. (Its 08→03, 08→05
  and 08→07 edges cover the rest transitively.)

Within one wave, `writePaths` are disjoint. Check with the dispatch manifest
`impl-plans/active/ssg2-dispatch.json`.

## Shared execution rules (every plan)

- **Read the plan, the design sections it cites, and this section first.**
  The design is the source of truth. If the plan and the design disagree,
  follow the design and record the conflict in your progress log.
- **Shell.** Run every `swift build`, `swift test` and `swiftlint` from an
  arm64 shell: `arch -arm64 /bin/zsh -lc '...'`.
- **Temporary HOME.** Every `swift build` and `swift test` command runs with
  `HOME="$(mktemp -d)"` set before `arch`. Never run tests with the developer
  `HOME`.
- **Logs.** Write logs under `tmp/ssg2/<planId>/`. Each command records its
  status and keeps it as the command's exit status, with this pattern:
  `set -o pipefail; <cmd> 2>&1 | tee <log>; s=$?; echo "exit=$s" >> <log>; exit $s`.
  An incomplete log is not a passing check.
- **Editing protocol.** Read a file fresh immediately before each edit. Record
  its sha256 before and after the edit, with the edit intent, under
  `tmp/ssg2/<planId>/hashes/`. If the pre-edit hash differs from the last hash
  you recorded, another worker changed the file. Re-read it and re-apply only
  your own intent. Never revert another plan's changes. Only edit files in
  your plan's `writePaths` and `sharedPaths`.
- **Git.** Do not run git commands that change state: no commit, stash,
  checkout, restore, reset, rebase, merge, push or worktree. Do not create
  branches. The workflow commits. Read-only `git diff` and `git status` are
  fine.
- **Build cache (authorized, untracked).** `.build/` and `.swiftpm/` are the
  pre-existing, gitignored SwiftPM cache shared by every plan. Writes to them
  by `swift build`, `swift test` and `swiftlint` are authorized. They are not
  part of any plan's `writePaths`, `sharedPaths` or `artifactRoots`, and
  `artifactRoots` is empty for every plan because no plan installs or
  downloads tools. Never delete `.build`. If SwiftPM reports a locked build
  folder, wait and retry.
- **Test stores and isolation (design §11).** Tests use realpath-resolved
  temporary directories (`URL.resolvingSymlinksInPath`; macOS `/var` is a
  symlink) and injected clocks. CLI code under test runs inside
  `CLIRuntimeEnvironment.$captured.withValue(env)` with a complete `env`
  (temporary `HOME`; `PATH` and `TMPDIR` copied from the process; only the
  `RIELA_*` keys the test sets). Every test passes a temporary project
  directory (`--working-dir`, the `currentDirectory:` parameter, or an
  explicit `--session-store`). After `ssg2-06` lands, use its helper
  `RielaCLIIsolatedEnvironment` (`Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift`).
  Plans running in W1 alongside ssg2-06 follow the same rule inline. Never
  read or write `~/.riela` or the repository's `.riela`.
- **Scope.** Another workflow edits `main` concurrently. Stay inside your
  `writePaths`. Do not bump `VERSION`, release or push.
- **Progress log.** Write only your own `impl-plans/progress/<planId>.md`.
  Record changed files with hashes, each command with its exit code and log
  path, acceptance status, and any path outside your `writePaths` that needs
  serial reconciliation (report it; do not edit it).
- **Completion.** A plan is done only when every one of its verification
  commands exited 0 on the current tree and every acceptance criterion is
  checked off in its progress log.

## Serial reconciliation and final gate (integration; not owned by any plan)

- full-target build and strict `swiftlint` over all touched Swift files;
- any out-of-plan test reported in a progress log as broken by this change;
- archiving the ssg2 plans (workflow `plan-archive` node).

Final gate. Every command must exit 0:

```
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'swift build'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc "swift test --filter 'Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration'"
H="$(mktemp -d)" && mkdir -p "$H/.riela" && printf '%s' '{"retention":{"automatic":false,"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"keepForever":true}}}' > "$H/.riela/config.json" && HOME="$H" RIELA_RETENTION_AUTOMATIC=0 arch -arm64 /bin/zsh -lc "swift test --filter 'Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration'"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <every touched Swift file>'
```

The third command is the isolation proof: the same suites must pass with a
`HOME` config and an ambient variable that would disable every default the
tests rely on. A Linux `swift build` (`swift:6.3.3-noble`) runs if available;
it is not a gate.
