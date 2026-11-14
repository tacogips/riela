# eh-10-storage-commands: `riela doctor storage` (read-only) and `riela storage compact` (dry run by default, resumable `--apply`)

```json
{
  "planId": "eh-10-storage-commands",
  "planPath": "impl-plans/active/efficient-history-10-storage-commands.md",
  "dependsOn": ["eh-03-memory-history", "eh-04-definition-history", "eh-06-cli-session-envelope", "eh-07-abandoned-and-retention", "eh-09-definition-surfaces"],
  "wave": 4,
  "writePaths": [
    "Sources/RielaCLI/StorageDoctorCommand.swift",
    "Sources/RielaCLI/StorageCompactCommand.swift",
    "Sources/RielaCLI/StorageRoots.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Tests/RielaCLITests/StorageDoctorCommandTests.swift",
    "Tests/RielaCLITests/StorageCompactCommandTests.swift",
    "impl-plans/progress/eh-10-storage-commands.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "Dispatch only: add the `.doctorStorage`/`.storage` cases next to `case let .doctor(options)` (around :152). Do NOT edit usage/help text; eh-11 owns help text in wave 5."}
  ]
}
```

## Intent and context

Design §8. Operators need to detect bloat and repair it.

**`riela doctor storage`** reports, per database file:

- size, free pages and per-table bytes;
- memory history amplification;
- versions per record and the largest records;
- prune-blocked families by reason;
- reclaimable bytes.

**`riela storage compact`** is a dry run by default. With `--apply` it runs,
in resumable batches:

1. convert legacy rows;
2. apply retention;
3. mark abandoned runs;
4. prune under the configured policy or flags;
5. vacuum.

APIs from earlier plans (pinned; use exactly these names):

- **eh-03:** `RielaMemoryStore.convertLegacyHistory(memoryId:maxRecords:) -> MemoryHistoryConversionReport`.
  Memory tables are `memory_entries`, `memory_evolution`,
  `memory_history_heads` and `memory_history_versions`.
- **eh-04:** `WorkflowDefinitionStore.retentionState()` and
  `backfillPinsAndApplyRetention(foreignSessionStoreRoots:defaultHistoryRetention:)`.
- **eh-05:** `SQLiteWorkflowRuntimePersistenceStore.legacyInlineSessionIds(limit:)`,
  `convertLegacySession(sessionId:)`, `legacyEmbeddedNestedInvocationKeys(limit:)`
  and `convertLegacyNestedInvocation(invocationKey:)`.
- **eh-06:** `CLIWorkflowSessionStore.legacyFullRecordIds(limit:)` and
  `convertLegacyRecord(sessionId:)`.
- **eh-07:** `SessionAbandonedInvocationReconciler(registry:).run(sessionStoreRoot:abandonedAfter:apply:)`.
- **eh-09:** `WorkflowDefinitionHistoryConfiguration.resolve(...)`.

Existing building blocks to reuse, not reimplement:

- `RetentionSQLiteReclaimer.reclaim(databasePath:mode: .manual)`
  (`RetentionSQLiteReclaimer.swift`);
- `RielaRetentionService` manual pass with overrides (`RielaRetentionService.swift`);
- `TerminalRetentionPlan` for the dry-run protections;
- `SessionExecutionLockRegistry.acquire` (`SessionExecutionLock.swift:35`);
- `CLIWorkflowSessionStore.resolveRootDirectory` (`CLIWorkflowSessionStore.swift:57`);
- the memory-root resolution used by `riela memory` (`ParsedMemoryOptions.swift`,
  `MemoryCommands.swift`);
- `RielaMemoryStore.databasePath(memoryId:)` naming (`RielaMemory.swift:17`)
  for enumerating memory databases.

Command wiring patterns:

- `DoctorRoute` and `GarbageCollectionRoute` in
  `RielaClientCommandRouter.swift:83-92`;
- the parse in `RielaCommand.swift:455-470`;
- the dispatch in `RielaCLIApplication.swift:152-156`;
- `SessionReconcileCommand.swift` for ArgumentParser-style flags and JSON
  rendering.

## Non-goals

- No change to the existing `riela doctor` report. `doctor` without
  `storage` behaves exactly as before.
- No new retention policy keys. Prune uses the existing `retention` config
  plus the gc-style override flags only. With neither, prune reports
  `notConfigured` and deletes nothing.
- No catalog rows and no help text; eh-11 owns them.
- Do not edit `Sources/RielaCLI/CLISurfaceEnumeration.swift`,
  `Sources/RielaCLI/RielaClientFamilyArguments.swift` or
  `Tests/RielaCLITests/SurfaceParityCLITests.swift`; eh-11 owns them in
  wave 5. Registering the `storage` router route makes
  `SurfaceParityCLITests` fail until then (`unclassifiedRoutes` contains
  `storage`). That suite is not in this plan's filter; if run, log the
  failure as `outOfScope: SurfaceParityCLITests storage route (eh-11)`.

## Contract

```
riela doctor storage [--scope project|user|auto] [--working-dir <dir>] [--session-store <dir>] [--memory-root <dir>]
                     [--cache-root <dir>] [--kv-root <dir>] [--top <n, default 10>] [--output text|json]
riela storage compact [same root flags] [--apply] [--max-batch <n, default 500, 1...100000>] [--abandoned-after-hours <h, default 24>]
                      [--results-max-age-days N] [--results-max-total-bytes SIZE] [--messages-max-age-days N] [--messages-max-total-bytes SIZE]
                      [--output text|json]
```

- **Doctor JSON:** the per-file report exactly as in design §8.1. Use the
  field names verbatim.
- **Compact JSON:** `{dryRun, stores: [{path, kind, converted: {memoryRecords,
  sessions, cliRecords, nestedInvocations, definitionPins}, convertedBytes,
  reconciled: [...verdicts], prune: <gc target report or {state:
  "notConfigured"}>, reclamation: [RetentionReclamationResult]}],
  workRemaining, warnings}`.
- **Exit codes:**
  - doctor: 0, unless no store can be opened, which is 1;
  - compact: 0 when completed or work remains, 1 when any store failed or
    was busy, 2 on a usage error.

**Pinned parser types (eh-11 registers them in the CLI surface gate,
EH5-F1).** Both live in `Sources/RielaCLI/StorageRoots.swift`:

- `enum StorageClientAction: String, CaseIterable, ExpressibleByArgument { case compact }`.
  The `storage` route parses its first token as this enum. eh-11 expands
  the route from `StorageClientAction.allRawValues` (the existing
  `CaseIterable` helper at `RielaClientFamilyArguments.swift:180-184`).
- `struct ParsedStorageCommandArguments: ParsableArguments`, declaring
  EVERY flag of both commands with swift-argument-parser `@Option` /
  `@Flag`, so `ParsedStorageCommandArguments.helpMessage()` lists every
  `--flag`: `--scope`, `--working-dir`, `--session-store`, `--memory-root`,
  `--cache-root`, `--kv-root`, `--top`, `--output`, `--apply`,
  `--max-batch`, `--abandoned-after-hours`, `--results-max-age-days`,
  `--results-max-total-bytes`, `--messages-max-age-days`,
  `--messages-max-total-bytes`. Imitate `ParsedSessionReconcileArguments`
  (`SessionReconcileCommand.swift:6`).
  - `doctor storage` and `storage compact` both parse their remaining tokens
    with `ParsedStorageCommandArguments.parse(_:)`. A compact-only flag
    (`--apply`, `--max-batch`, `--abandoned-after-hours`, the four
    `--results-*`/`--messages-*` flags) given to `doctor storage` → usage
    error, exit 2. `--top` given to `storage compact` → usage error.
  - Do not hand-parse these flags; the CLI gate reads the help message.
- `doctor` routing: `DoctorRoute` passthrough whose first token is
  `storage` → the storage doctor. Any other `doctor` invocation goes down
  the existing `parseGeneric(scope: "doctor", …)` path unchanged.

## Key points

- **Doctor opens nothing writable.**
  - Runtime databases use `SQLiteOpenMode.strictReadOnly` /
    `strictReadOnlyWithImmutableFallback`, never `.readOnly`
    (`SQLiteDatabase.swift:127-134` falls back to read-write).
  - Memory, cache and KV databases also use strict read-only RielaSQLite
    opens.
  - Never call `ensureSchema` or a migrator, and never create a missing
    file.
  - A test asserts the file checksums and mtimes are unchanged.
- **Table bytes.** Use `SELECT name, SUM(pgsize) FROM dbstat GROUP BY name`
  when the `dbstat` vtable exists. Otherwise sum `length(col)` over the
  known columns with `estimated: true`. Check for dbstat by catching the
  "no such table: dbstat" error.
- **Session fields:**
  - `legacyInlineSnapshots`: `json_type(session_json,'$.executions')='array'`
    count.
  - `legacyCLICopies` and `legacyCLICopyBytes`: rows without
    `sessionStorage = "canonical"`, plus `length(record_json)`.
  - `legacyNestedEmbeddedBytes`: nested rows without
    `childSnapshotStorage = "refs"`.
  - `pruneBlocked`: a dry-run `TerminalRetentionPlan` over all workflows,
    reasons counted.
  - `abandonedCandidates`: the reconciler run with `apply: false`.
- **Memory fields:**
  - `historyBytes` = the sum of history blob bytes plus the legacy
    `length(reverse_delta_json)`;
  - `currentBytes` = the payload, tags and related lengths;
  - `amplification` = history / current, or 0 when current is 0;
  - `maxVersionsPerRecord`;
  - `legacyRecords`;
  - `unreferencedAttachmentBytes`: files under the memory root's attachment
    directory not referenced by any retained version or the head. Read only;
    never delete.
- **Compact `--apply` order per store:**
  1. convert, in batches of `--max-batch`;
  2. reconcile abandoned rows;
  3. prune;
  4. reclaim.

  Each conversion call is its own transaction, so the run can be resumed.
  - Session conversions acquire the session's execution lock non-blocking.
    A busy lock → skipped and `workRemaining = true`.
  - Definition: `backfillPinsAndApplyRetention(foreignSessionStoreRoots:
    <the other resolved session stores>)`.
  - `workRemaining` is true when any batch limit was hit or any item was
    skipped busy.
- **Compact dry run.**
  - Read-only: no locks and no writes, like `riela gc --dry-run`.
  - It reports counts and estimated bytes. The estimates are the legacy
    copy bytes plus the history bytes beyond the window plus `freePages ×
    pageSize`.
- **Reclaim** with `RetentionSQLiteReclaimer` manual mode only. It handles
  the NONE → INCREMENTAL conversion with the free-space guard. Do not run a
  `VACUUM` directly.

## Tests

`StorageDoctorCommandTests.swift`:

- A temp store with one legacy inline session, one envelope session and one
  memory database with a legacy 20-version record → the JSON shows:
  - `legacyInlineSnapshots: 1`;
  - `memory.legacyRecords: 1`;
  - `maxVersionsPerRecord: 20`;
  - `amplification > 0`;
  - non-empty `tables`;
  - `autoVacuum` values.
- The text output contains one block per file.
- Every file's SHA-256 and mtime is unchanged after the command.

`StorageCompactCommandTests.swift`:

- A dry run on the same fixture → no file changes, and non-zero estimates.
- `--apply --max-batch 1` → a first run with `workRemaining: true`; repeated
  runs converge to `workRemaining: false`.
- Afterwards:
  - the memory record has 1 previous version;
  - the session loads equal;
  - the CLI row is an envelope;
  - an abandoned nested row has `abandoned_at` set;
  - with `--results-max-age-days 1` and an old terminal family, the family
    is pruned and `reclamation.reclaimedBytes > 0`;
  - the database file is smaller than before.
- No retention config and no flags → `prune.state == "notConfigured"`, and
  no family is deleted.
- A session whose lock is held → skipped, and `workRemaining: true`.
- `riela doctor` without `storage` → output identical to before. Compare
  against the existing `DoctorCommandTests` expectations by running that
  suite.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift test --filter "StorageDoctorCommandTests|StorageCompactCommandTests|DoctorCommandTests|DoctorBackendCapabilityTests|GarbageCollectionCommandTests"' > tmp/efficient-history/eh-10-storage-commands/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0, with every suite executed.

## Done criteria

- [ ] Both commands parse and run, with tests for each.
- [ ] `grep -n "enum StorageClientAction\|struct ParsedStorageCommandArguments" Sources/RielaCLI/StorageRoots.swift`
      matches both, and a test asserts
      `ParsedStorageCommandArguments.helpMessage()` contains every flag
      listed in the contract.
- [ ] The doctor is proven read-only by checksums.
- [ ] Compact is resumable and converges.
- [ ] The existing doctor and gc suites are green.
- [ ] The progress log is complete.
