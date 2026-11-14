# EH05 — Session rows progress

## Status
Implementation is source-complete against the EH05 plan contract and the focused behavioral suite passes against the integrated EH04 generation-11 schema. Do not treat this progress record as formal review acceptance. Workflow mode: issue-resolution; workflow execution `nested-v1-c18c57b433458d05b712b3ed1f89bffa59c8e394cd213fa205b6119ec65ba304`; fanout branch `eh-05-session-rows`; accepted dependencies: `eh-01-history-engine`, `eh-02-runtime-contract`, `eh-04-definition-history`.

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
Source implementation and progress evidence are ready for Step 7 review. EH05 behavioral acceptance passes against the integrated EH04 schema. Formal review and final combined-tree gates remain later workflow steps; this implementation handoff performs no commit, rebase, or push.

## Continuation verification — 2026-10-27

Resumed from the source-complete tree after EH04 integration. No EH05 source or
test file changed during this continuation; before/after SHA-256 snapshots
match for every owned file and the allowed shared fixture. They are recorded
in `tmp/efficient-history/eh-05-session-rows/pre-verification-hashes.log` and
`tmp/efficient-history/eh-05-session-rows/post-verification-hashes.log`.

| Exact command | Exit | Result / evidence |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build complete; `tmp/efficient-history/eh-05-session-rows/build-resume.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeExecutionRowsTests|RuntimePersistenceBoundedWriteTests|SQLiteRuntimeSchemaMigrationTests|SQLitePersistenceSessionExistsTests|RuntimeSnapshotDatesTests|WorkflowPreservedHistoryTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|PrivateWorkflowTests|WorkflowRuntimePersistence"'` | 1 | First integrated run: 69 tests, one failure in out-of-scope `WorkflowCommandLivePersistenceTests.testWorkflowRunPersistsLoopEvidenceDuringLiveProgress` (`Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift:309`, missing `LoopEvidenceManifest`). Log: `tmp/efficient-history/eh-05-session-rows/test-resume.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceDuringLiveProgress"'` | 0 | Isolated rerun: 1 test, 0 failures; confirms the first failure was transient. Log: `tmp/efficient-history/eh-05-session-rows/test-out-of-scope-isolated.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeExecutionRowsTests|RuntimePersistenceBoundedWriteTests|SQLiteRuntimeSchemaMigrationTests|SQLitePersistenceSessionExistsTests|RuntimeSnapshotDatesTests|WorkflowPreservedHistoryTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|PrivateWorkflowTests|WorkflowRuntimePersistence"'` | 0 | Final repeat: 69 tests, 0 failures. Log: `tmp/efficient-history/eh-05-session-rows/test-resume-final.log`. All four canonical fast-path/fence tests passed. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift Sources/RielaCore/RuntimeExecutionReuse.swift Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift'` | 0 | Strict lint passed for all EH05-owned Swift files; `tmp/efficient-history/eh-05-session-rows/swiftlint-owned-resume.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift Sources/RielaCore/RuntimeExecutionReuse.swift Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift Tests/RielaCLITests/PrivateWorkflowTests.swift'` | 2 | Only the two previously documented baseline diagnostics in shared `PrivateWorkflowTests.swift`: `optional_data_string_conversion` at line 395 and `statement_position` at line 748. Log: `tmp/efficient-history/eh-05-session-rows/swiftlint-resume.log`. |
| `git diff --check -- Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift Sources/RielaCore/RuntimeExecutionReuse.swift Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift Tests/RielaCLITests/PrivateWorkflowTests.swift` | 0 | No whitespace errors; `tmp/efficient-history/eh-05-session-rows/diff-check-resume.log`. |

Acceptance checks: no source match for `riela_snapshot_execution_parts` or
the old repeated `String(repeating: ", ?, jsonb(?)"` patch loop; the same-store
`recordPinIfNeeded` call remains and `recordForeignPinIfNeeded` occurs twice.
All pinned schema tables and public session conversion/release APIs are
present. `tmp/efficient-history/wave-W2a/handover-eh-05.md` is absent, so
there were no handover items to resolve. No out-of-scope edits were made.

Open risks: formal review and later combined-tree final gates remain pending.
Shared `PrivateWorkflowTests.swift` continues to have the two pre-existing
lint diagnostics listed above. No EH05-specific behavioral risk was found in
the passing focused run.

## Independent review repair — 2026-10-27

No existing test assertions were weakened or removed. Added assertions are
listed below with their purpose; the existing byte and file-growth assertions
remain unchanged. No eh-05 source changes were made outside the plan's
writePaths or the reviewer-named design/progress documents. The shared worktree
also contains concurrent eh-04 definition-store and eh-08 memory-surface edits;
this repair did not touch those implementation files.

| Finding | Resolution |
|---|---|
| H1 identity projection | Fast-path completion writes the full ordered execution ID list after the header trigger invalidates the projection. Added cold-save, three fast appends, no-new-execution terminal-save, projection-equality, and fresh-generator high-water assertions. |
| H2 save-time family scan | Execution-row upserts capture old digests by ordinal; truncation uses `DELETE … RETURNING`; only differing/truncated digests use indexed point cleanup. Family-wide release runs only on the first transition to terminal. Added deterministic `payloadGCChecks` observer data, the 500-vs-50 bound, and a save-50 comparison between a normal family and one seeded with 20,000 unrelated payloads. |
| M3 mixed-version loads | `load`, `loadAll`, rollup assembly, and identity reads now use one `BEGIN` read transaction; web detail already used one. Added a load hook that commits a second-connection save between header selection and row assembly and asserts the prior committed snapshot is returned whole. |
| M4 generation-10 reads | Summary SQL omits execution-row references when the table is absent. Identity backfill selects legacy-only SQL when needed, and startup prepares/migrates schema before backfill. Added a generation-10 historical-store fixture with inline execution data and an embedded nested row, summary read, identity observation, session save conversion, and nested conversion assertions. |
| M5 test gaps | Added projection-integrity, generation-10, 20k-payload work-counter, and terminal-role dedupe-count assertions. Existing migration/legacy tests remain intact. |
| L1 parsing cost | Row-format loads now use SQL JSON assembly and decode the session once; `json_type` in each row query bypasses assembly for inline legacy sessions. |
| L2 nested ref cleanup | Re-encoding deletes old callee refs before writing, replaces role refs with `DELETE … RETURNING`, and releases newly unreferenced payloads. |
| L3 eh-07 contract | Design §5 now requires eh-07 to delete all invocation refs with nested invocation rows, including `callee` refs. |
| L4 bounded header caveat | Design §5 records that `fanoutGroups`/`reviewFindings` remain in rewritten headers and that duplicate CLI `record_json` belongs to eh-06. |

Assertion changes: none to pre-existing tests. New bounds are justified as
follows: the projection and generator assertions catch stale/missing startup
IDs; the `payloadGCChecks` 500-vs-50 ratio and save-50 control comparison with
20,000 extra payloads catch family-size-dependent cleanup work; the read-hook
assertion catches header/row snapshot mixing; the terminal-role count catches
omitted nested-ref deduplication. The nested test also asserts terminal-role
row and digest counts (4 each), proving the stored child header, execution,
output, and diagnostics references are unique.

## Repair verification — 2026-10-27

| Check | Exit | Result |
|---|---:|---|
| arm64 build | 0 | Build complete. |
| Focused test filter | 0 | 74 tests, 0 failures. Includes original fast-path/fence coverage and new projection, family-work, generation-10, nested-ref, and concurrent-read regressions. |
| Targeted generation-10 migration rerun | 0 | 1 test, 0 failures. |
| Strict SwiftLint | 0 | Passed. |
| `git diff --check` | 0 | No whitespace errors. |
| Plan completion greps | 0 | No row-parts or per-key-patch patterns; `recordForeignPinIfNeeded` count 2; `recordPinIfNeeded` remains. `String(repeating:)` matches are only in unrelated `PromptTemplate.swift`. |

Exact build and test commands:

```sh
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeExecutionRowsTests|RuntimePersistenceBoundedWriteTests|SQLiteRuntimeSchemaMigrationTests|SQLitePersistenceSessionExistsTests|RuntimeSnapshotDatesTests|WorkflowPreservedHistoryTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|PrivateWorkflowTests|WorkflowRuntimePersistence"'
arch -arm64 /bin/zsh -lc 'swift test --filter SQLiteRuntimeSchemaMigrationTests/testGenerationTenInlineExecutionFixtureSupportsReadOnlySummaryAndStartupBackfill'
```

Strict lint was run with `xcrun swiftlint lint --strict --quiet --no-cache`
over the eh-05 Swift source and test files. `git diff --check` was run over
the eh-05 source, test, design, and progress files.

The final focused invocation had first failed to build because SwiftPM
reported a concurrent edit to `Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift`;
the exact same command was rerun and passed. The first post-fixture focused
invocation exposed two mistakes in the new
generation-10 fixture (duplicate nested-table DDL, then lookup by a derived
key instead of the fixture's explicit invocation key); it ran 74 tests with
1 failure. Both fixture issues were corrected, the migration regression then
passed independently, and the final 74-test focused invocation passed. A
separate test build briefly encountered an unrelated concurrent
`VersionedHistoryConformanceTests.swift` Sendable-capture error; its owner
corrected it. No out-of-scope implementation files were changed here.

## Independent review repair — round 2 — 2026-10-27

### Findings resolved

- **N1 High — whole-session encode/decode per save.** `encodedHeaderJSON`
  copies the session, clears `executions`, encodes that header-only value,
  then decodes only the small header object to add the marker and witness.
  Its measured `headerEncodeInputBytes` is included in each write sample. The
  500-save regression compares saves 50 and 500 and caps the latter at 1.5×.
- **N2 Low — replace the hand-counted GC metric with SQLite work.** Removed
  `payloadGCChecks` from the write metrics and samples. `SQLiteDatabase`
  accumulates real `sqlite3_stmt_status` VM and full-scan counters, and the
  save sample reports the delta for the write. Catalog lookup scans are
  excluded from `fullScanSteps` because they visit SQLite schema metadata,
  not runtime payload/family rows. The 20,000-unrelated-payload regression
  compares save-50 VM steps within 2% (or 10 steps) and asserts zero
  application-table full-scan steps on both stores.
- **N3 Low — child terminal saves no longer sweep the root family.**
  `releaseAtRunEnd` is true only when the root session (or a session without
  an explicit root id) transitions terminal. A regression saves eight
  terminal children and confirms no family release, then terminates the root
  and confirms one release.
- **N4 — keep the assembly observer out of the public API.** The public
  initializer no longer accepts `loadAssemblyObserver`; an internal overload
  supports the transaction consistency test.
- **L1–L4 from round 1.** SQL assembly still decodes loads once (L1), nested
  refs are released before re-encoding (L2), the eh-07 cleanup contract is in
  design §5 (L3), and the bounded-header caveat is already recorded in design
  §5 (L4). No new changes were needed for those accepted repairs.

### Assertion changes and regression coverage

No existing behavioral test assertion was weakened or removed. In
`RuntimePersistenceBoundedWriteTests`, the two `payloadGCChecks` assertions
were replaced because that hand-maintained counter could not detect a
reintroduced scan. The replacement checks use SQLite VM-step totals, the
actual SQLite full-scan counter for application tables, and the same
20,000-payload control comparison. Added the save-500/header-encode-input
bound and the child-terminal/root-terminal release-count assertions. Existing
byte, database/WAL growth, payload-count, identity-projection, read-transaction,
generation-10, and terminal-role assertions remain intact.

### Scope

EH05 plan writePaths were changed only for the session store, its session
family helper, the bounded-write tests, and this progress log. The additional
`Sources/RielaSQLite/SQLiteDatabase.swift` change is outside the plan's
writePaths but is explicitly named by N2's repair instruction to expose
`sqlite3_stmt_status`; no other out-of-scope implementation files were
changed. No eh-06, eh-07, or eh-09 files were edited. No pre-existing tests
were restored because comparison of the current EH05 test diff found no
weakened or removed pre-existing assertions.

### Round-2 verification

The first post-change focused invocation was interrupted at compile time by a
concurrent edit to `SessionAbandonedInvocationTests.swift` and was rerun as
instructed. That rerun built but exited 1 after 75 tests, with four failures
in the zero-full-scan assertions. A trace showed the raw status included
repeated `sqlite_master` catalog lookups, not payload/family scans. The
application-table metric now excludes catalog SQL while continuing to sum
SQLite's `SQLITE_STMTSTATUS_FULLSCAN_STEP` for application tables. The
required focused rerun passed all 75 tests.

| Exact command | Exit | Result / evidence |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Final build complete; `tmp/efficient-history/eh-05-session-rows/repair-build-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeExecutionRowsTests|RuntimePersistenceBoundedWriteTests|SQLiteRuntimeSchemaMigrationTests|SQLitePersistenceSessionExistsTests|RuntimeSnapshotDatesTests|WorkflowPreservedHistoryTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|PrivateWorkflowTests|WorkflowRuntimePersistence"'` | 0 | 75 tests, 0 failures; `tmp/efficient-history/eh-05-session-rows/repair-focused-final-1.log`. Includes encode-size, 20k-payload VM/full-scan, child/root release, projection, generation-10, nested-ref, and transaction-consistency regressions. |
| `arch -arm64 /bin/zsh -lc 'xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaSQLite/SQLiteDatabase.swift Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift'` | 0 | Strict lint passed; `tmp/efficient-history/eh-05-session-rows/repair-swiftlint-1.log`. |
| `git diff --check -- Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaSQLite/SQLiteDatabase.swift Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift design-docs/specs/design-efficient-history-and-storage.md impl-plans/progress/eh-05-session-rows.md` | 0 | No whitespace errors. Old row-parts pattern absent; foreign pin hook count remains 2 and same-store pin hook remains present. |

The first focused build attempt reported that the concurrent eh-07-owned
`Tests/RielaCLITests/SessionAbandonedInvocationTests.swift` changed during the
build. The same focused command was rerun after that process finished; its
test run then exposed the four catalog-scan assertions described above. After
narrowing the full-scan metric to application tables, the final 75-test run
passed. No changes were made to eh-06, eh-07, or eh-09 files.
