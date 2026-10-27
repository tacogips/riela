# Efficient history and session storage: overview implementation plan

**Status**: Ready
**Design Reference**: design-docs/specs/design-efficient-history-and-storage.md (accepted in step3, comm-009607)
**User QA**: design-docs/user-qa/qa-efficient-history-and-storage.md (Q1-Q7 recommended answers assumed)
**Created**: 2026-10-27
**Last Updated**: 2026-10-27

## Intent

Riela's SQLite stores grew to about 60 GB for data that is small. The fix has
three parts:

- Memory records and workflow definitions move onto ONE shared component,
  `VersionedHistory`, which owns compressed history, retention, diff and
  undo/redo.
- The session store stops duplicating session JSON and stops rewriting it on
  every save.
- Riela gains detection (`riela doctor storage`) and repair (`riela storage
  compact`).

This file is the index. Each plan below is a self-contained executable
contract.

## Plans and waves (DAG)

| Wave | planId | Plan file | dependsOn |
| --- | --- | --- | --- |
| 1 | eh-01-history-engine | impl-plans/active/efficient-history-01-history-engine.md | — |
| 1 | eh-02-runtime-contract | impl-plans/active/efficient-history-02-runtime-contract.md | — |
| 2 | eh-03-memory-history | impl-plans/active/efficient-history-03-memory-history.md | eh-01 |
| 2 | eh-04-definition-history | impl-plans/active/efficient-history-04-definition-history.md | eh-01, eh-02 |
| 2 | eh-05-session-rows | impl-plans/active/efficient-history-05-session-rows.md | eh-02 |
| 3 | eh-06-cli-session-envelope | impl-plans/active/efficient-history-06-cli-session-envelope.md | eh-05, eh-04 |
| 3 | eh-07-abandoned-and-retention | impl-plans/active/efficient-history-07-abandoned-and-retention.md | eh-05 |
| 3 | eh-08-memory-surfaces | impl-plans/active/efficient-history-08-memory-surfaces.md | eh-03 |
| 3 | eh-09-definition-surfaces | impl-plans/active/efficient-history-09-definition-surfaces.md | eh-03, eh-04 |
| 4 | eh-10-storage-commands | impl-plans/active/efficient-history-10-storage-commands.md | eh-03, eh-04, eh-06, eh-07, eh-09 |
| 5 | eh-11-catalog-help-docs | impl-plans/active/efficient-history-11-catalog-help-docs.md | eh-08, eh-09, eh-10 |

### Cross-wave path handoffs

The following paths are owned by an earlier-wave plan and then a later-wave
plan, never by two plans in the same wave:

- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`: eh-02 (the
  generation bump, migration step, open option and pin-hook call), then eh-05
  (the save/load rewrite).
- `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` and
  `Sources/RielaCore/WorkflowDefinitionPins.swift`: eh-02 creates stubs, then
  eh-04 fills them.
- `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`: eh-02 creates
  the stub, then eh-05 fills it.
- `Sources/RielaCLI/RielaCLIApplication.swift`: eh-10 (dispatch only), then
  eh-11 (help text only).
- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`: eh-02 (wave 1, the one
  `openDatabase` options line → `.writableRuntimeStoreDefault`, EH5-F2),
  then eh-06 (wave 3, envelope rewrite plus the
  `recordForeignPinIfNeeded` pre-call before `db.transaction`, EH5-F3).
  eh-06 keeps the eh-02 line byte-identical.
- `Sources/RielaWork/WorkStore.swift`: eh-02 only (the one options line).
- `Sources/RielaCLI/CLISurfaceEnumeration.swift` and
  `Sources/RielaCLI/RielaClientFamilyArguments.swift`: eh-11 only (wave 5,
  no sibling), EH5-F1.

### Interim expected failures between waves

- `SurfaceParityCLITests` is red from wave 3 (eh-09 adds the
  `workflow.definition.undo/redo` rows) and wave 4 (eh-10 registers the
  `storage` route and `doctor storage`) until eh-11 updates the enumerator
  in wave 5. eh-09 and eh-10 log it as outOfScope and keep it out of their
  filters; eh-11 makes it green.

### Definition pin write order (design §4, EH5-F3)

- Same-store pin: `WorkflowDefinitionPins.recordPinIfNeeded` inside the
  snapshot transaction (`completeSnapshotWrite`, eh-02 call, eh-04 body).
- Foreign-store pin: `WorkflowDefinitionPins.recordForeignPinIfNeeded`,
  called with no transaction open, from the runtime store's `save(_:)` and
  `save(_:appendingWorkflowMessages:)` (eh-02 call, kept by eh-05) and from
  the CLI store's `in db:` save overloads (eh-06). eh-04 writes the body.

## Shared rules for every plan (also in the dispatch manifest)

- **Working copy.** There is one working directory, on branch
  `feat/efficient-history`. Workers run no git write operations and never
  create worktrees or branches. Serial finalization commits, rebases on
  `origin/main` and pushes (`gitPush=true`).
- **Ownership.** Each worker edits only its own `writePaths`. Before each
  edit, read the file fresh and record `shasum -a 256` before and after in the
  plan's progress log. If the hash drifted since the last read, re-read the
  file and re-apply only this plan's intent. Never revert a foreign change.
- **Out-of-scope failures.** A compile or test failure in a file this plan
  does not own is logged as `outOfScope: <file>:<line> <message>`. Do not fix
  it.
- **Command conventions.**
  - Every `swift` and `swiftlint` command runs in the foreground as
    `arch -arm64 /bin/zsh -lc '…'`.
  - Output goes under `tmp/efficient-history/<planId>/<step>.log`.
  - Record the exit status of every command.
  - A `--filter` that matches 0 tests is a failure.
  - A blocked check is never recorded as passing.
- **Forbidden edits.** Never edit the root `Package.swift`,
  `Package.resolved`, `Packages/RielaMemory/Package.resolved`, cron files or
  `VERSION`. The only manifest edit in the whole effort is the CZlib target in
  `Packages/RielaMemory/Package.swift` (eh-01). A concurrent run on main is
  changing pins in that same file, so add the target only and leave every
  dependency line untouched.
- **Scratch files.** All scratch files go under `tmp/efficient-history/` and
  are never committed.
- **Progress log.** Each plan writes only its own
  `impl-plans/progress/<planId>.md`, with sessions, per-edit hashes, commands
  with exit status and log path, outOfScope notes and a final done-criteria
  checklist.

## Final gate (serial reconcile and integration, after eh-11)

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory'
arch -arm64 /bin/zsh -lc 'swift test --filter "VersionedHistory|MemoryHistoryRetention|WorkflowDefinition|SQLiteRuntime|RuntimeStoreFirstOpener|WorkStoreFirstOpener|RuntimePersistenceBoundedWrite|CLIWorkflowSession|PrivateWorkflowTests|SessionReconcile|TerminalRetention|RetentionReclamation|StorageDoctor|StorageCompact|MemoryCommand|MemoryEvolutionCommand|CommandParsing|SurfaceParity"'
arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh' && git diff --exit-code Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift
arch -arm64 /bin/zsh -lc 'swift test'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <every touched Swift file>'
git diff --check
```

## Completion criteria

- [ ] All 11 plans report every done criterion checked in their progress logs.
- [ ] The final gate passes. A full `swift test` failure is compared against
      the known interleaved-submit flake and reported, never hidden.
- [ ] No root `Package.swift`, `Package.resolved`, `VERSION` or cron edits:
      `git diff --stat origin/main -- Package.swift Package.resolved VERSION`
      is empty.

## Progress Log

### Session: 2026-10-27
**Tasks Completed**: plan decomposition authored (step4).
**Blockers**: none.

### Session: 2026-10-27 (step4 self-check revision)
**Tasks Completed**:
- eh-10 `dependsOn` gains eh-09 (it calls `WorkflowDefinitionHistoryConfiguration.resolve`).
- eh-09 owns `Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift`
  so self-improve writes honor `workflowDefinitions.historyRetention`; the
  read-only service sites are listed as unchanged. Added config/self-improve tests.
- eh-04 foreign-pin liveness check opens `SQLiteDatabase` strict read-only,
  never the writable store initializer.
- eh-04 adds a `now:` clock seam to `WorkflowDefinitionStore`/`WorkflowDefinitionService`;
  every definition window test (eh-04, eh-09) advances it 25 h per commit and
  asserts retained sets, because the 24-hour former-head pin otherwise keeps
  every recent version.
- eh-05 done-criterion grep no longer forbids the allowed load-side
  `jsonb_set(session_json,'$.executions',…)` assembly.
**Blockers**: none.

### Session: 2026-10-27 (step5 review revision, comm-009609)
**Tasks Completed**:
- EH5-F1: eh-11 owns `CLISurfaceEnumeration.swift` and
  `RielaClientFamilyArguments.swift` (undo/redo enum cases, doctor →
  [doctor, doctor storage], storage → [storage compact], storage and
  workflow-definition options registered in `optionNames()`). eh-10 pins
  `StorageClientAction` and `ParsedStorageCommandArguments` in
  `StorageRoots.swift`. eh-09 and eh-10 log the interim CLI-gate failure as
  outOfScope.
- EH5-F2: eh-02 owns the one-line options change in
  `CLIWorkflowSessionStore.swift:411` and `WorkStore.swift:390`, with
  first-opener auto_vacuum tests in RielaCLITests and RielaWorkTests. The
  handoff of the CLI store file to eh-06 is recorded.
- EH5-F3: the pin hook is split. The same-store hook stays in the snapshot
  transaction. The new `recordForeignPinIfNeeded` runs before the local
  transaction (runtime-store entry points from eh-02, CLI overloads from
  eh-06). eh-04 adds a held-foreign-lock test. eh-06 now depends on eh-04.
- Step5 low residuals folded in: eh-04 skips the pin for terminal sessions
  whose pinned version was dropped, and compares normalized database paths
  (directory → `defaultDatabasePath`) in the hooks and the backfill.
**Blockers**: none.
