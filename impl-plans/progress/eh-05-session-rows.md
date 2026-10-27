# EH05 — Session rows progress

## Status
Implementation is source-complete against the EH05 plan contract; the required focused behavioral suite remains blocked by the in-progress EH04 generation-11 schema in the shared worktree. Do not treat this progress record as review acceptance. Workflow mode: issue-resolution; workflow execution `nested-v1-c18c57b433458d05b712b3ed1f89bffa59c8e394cd213fa205b6119ec65ba304`; fanout branch `eh-05-session-rows`; accepted dependencies: `eh-01-history-engine`, `eh-02-runtime-contract`.

Issue: owner issue “One shared versioned history (diff, undo/redo, retention: memory 2 / state 1 / workflow definitions 10) and efficient session storage with storage doctor/compact” (no GitHub number). Plan: `impl-plans/active/efficient-history-05-session-rows.md`; design: `design-docs/specs/design-efficient-history-and-storage.md`.

## Changes
- Added generation-11 execution-row schema for `workflow_runtime_payloads`, append-only `workflow_runtime_executions`, and digest-keyed `workflow_nested_invocation_refs`; legacy tables gain the optional abandonment marker idempotently.
- Changed runtime persistence to write header-only snapshot JSON with execution payloads and nested material stored by family-scoped digest references. Reuse fast paths retain witness/fence checks, write only changed/appended ordinal rows, and preserve same-store and foreign-store definition pin hooks.
- Added row reconstruction, legacy inline/embedded conversion APIs, startup identity backfill from ordered execution rows, web summary projection, and bounded root-local orphan payload release.
- Added execution-row/dedupe/legacy/nested/cascade/GC tests and `RuntimePersistenceBoundedWriteTests` for 500 saves with byte/file-growth bounds.
- Shared fixture edit in `Tests/RielaCLITests/PrivateWorkflowTests.swift`, `testCanonicalReuseRefusesRolledBackAndLegacyWriterWitnesses`: before, the raw SQL changed `$.executions[1].inputSnapshot.tag` in the inline session JSON and removed the canonical-write witness; after, SQL changes ordinal 1's `payload_digest` to ordinal 0's same-family digest and removes the header witness. It still exercises cold-path repair of an older writer's altered execution reference. No assertion was edited or removed.
- Split helper responsibilities into `SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` to keep the store file and type within Swift maintainability/lint limits. Final helpers are internal only where the same-type extension needs access.

## Edit identity
Per-edit intended hunks are preserved in `tmp/efficient-history/eh-05-session-rows/edit-intentions.md`. Fresh pre-edit SHA-256 snapshots are in `pre-edit-hashes*.log`; final post-edit SHA-256 values are recorded below. The final lint cleanup edits were recorded explicitly:

| Edit | Path | Pre-edit SHA-256 | Post-edit SHA-256 |
|---|---|---|---|
| 21 intermediate patch, corrected in next edit | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `bec27ca90e91bb732217249ce434404e4d8e9b48cc7ec2a1000a02ef6bee2ecc` | `61d0b465435ff052e3ee0fd58fce3fdc66c3f564b3063924db37bb89bb4b5597` |
| 22 helper relocation | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `61d0b465435ff052e3ee0fd58fce3fdc66c3f564b3063924db37bb89bb4b5597` | `83e1f7c87b876e0c422158d3d8b1328e83360c34640ce4b4781483e58870901a` |
| 22 helper relocation and SQL formatting | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` | `29f239e1608925409b5b977aa186c75a6987622c033672915d1b261bf8fc6768` | `9f28a579cbfedac1ebf4d75fa51b917787610128805dc1bac1c6339539df042a` |
| 23 helper access | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `83e1f7c87b876e0c422158d3d8b1328e83360c34640ce4b4781483e58870901a` | `7393f0106076c805bbdd7cc7dc2b64cdd0895108b16364d81a8e08f5e723fab2` |

Final post-edit hashes:
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`: `7393f0106076c805bbdd7cc7dc2b64cdd0895108b16364d81a8e08f5e723fab2`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`: `346253093ac6067e75ca625e7081f09b9454d2f47ad043863b4d0e8d277c1c6f`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`: `9f28a579cbfedac1ebf4d75fa51b917787610128805dc1bac1c6339539df042a`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift`: `612098c233cde737a24289d2d897525a6a50561d7800b108d90c02d20433d69b`
- `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`: `c5e5ad754ec8bc05f9469f6c76c35049729517643955d339f47185ae99cdd1ed`
- `Sources/RielaCore/RuntimeExecutionReuse.swift`: `fa4c9698a18be3d7ffcddb8cf3645c629eac9630ce69de87784c79eabb7e9c7a`
- `Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift`: `98f51575f0d00ec64c4109fb62e8e51f39b2c74ddeccf0cb7d1b172ce5325814`
- `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`: `dcc02f6cee08ef077e8ea34b405d2f779ca571955f2f902a2640737d1b1b9aa4`
- `Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift`: `8691da9bd698a327caab7d68dc95933c6f0eefa28d6f041e72ea319110de2187`
- `Tests/RielaCLITests/PrivateWorkflowTests.swift`: `3cddd5b3340c4ef81dbea44223d42d0ab3f1dd2a354389c17ade29d2ec1ede7e`

## Acceptance and verification
- `riela_snapshot_execution_parts` has no source match; the repeated `String(repeating: ", ?, jsonb(?)"` assembly has no source match.
- `recordForeignPinIfNeeded` still appears exactly twice in `SQLiteWorkflowRuntimePersistenceStore.swift`.
- All three pinned tables exist in the schema. The 500-save test asserts both the per-save byte bound and bounded late-vs-early database/WAL growth.
- `arch -arm64 /bin/zsh -lc 'swift build'` exited 0; final complete log: `tmp/efficient-history/eh-05-session-rows/build-final-source-3.log`.
- The exact assigned focused suite exited 1, 69 tests run, 49 failures (28 unexpected); complete log: `tmp/efficient-history/eh-05-session-rows/test-final-source-2.log`. Every EH05 test failed before assertions because EH04's current shared-tree schema references missing `main.definition_history_versions`. The in-progress path is `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` (EH04-owned); EH05 did not edit it. Resume the exact suite after EH04 creates the referenced table and its schema migration is integrated.
- Strict SwiftLint over EH05-owned Swift files exited 0: `tmp/efficient-history/eh-05-session-rows/swiftlint-owned-final-2.log`. The exact changed-file manifest check including the shared fixture exited 1 only for the two pre-existing `PrivateWorkflowTests.swift` diagnostics (`optional_data_string_conversion` at line 395 and `statement_position` at line 748); HEAD baseline diagnostics were checked using `PrivateWorkflowTests.baseline.swift` and `swiftlint-private-baseline.log`.
- `git diff --check` over all EH05-owned/shared changed files exited 0; output: `tmp/efficient-history/eh-05-session-rows/acceptance-greps-and-diff-check.log`.

## Handoff
Source implementation and progress evidence are ready for Step 7 review. EH05 behavioral acceptance is incomplete until the exact focused suite is rerun successfully against an integrated EH04 schema. Formal review, final combined-tree gates, commit, rebase, and push remain later workflow steps.
