# instance-cancel-int-03: WorkflowDefinitionStoreTests assert the current schema generation (12)

**planId**: instance-cancel-int-03-definition-store-generation
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-cancel.md §8.3 (D4); design-docs/specs/design-session-storage-efficiency-and-default-gc.md §3.2 (generation 12, additive DDL)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-int-03-definition-store-generation.md
**Evidence root**: tmp/instance-cancel-integration/int-03/

## Intent and context

`SQLiteWorkflowRuntimePersistenceStore.schemaGeneration` is `12`
(`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`),
reached through `SQLiteSchemaMigration(fromGeneration: 11)` →
`SQLiteRuntimeExecutionRowsSchema.migrateToGeneration12`. That generation is
intended by the session-storage-efficiency design. The two tests in
`Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` still assert
`"11"`, so they already fail on main. The code is correct and the tests are
stale.

## Non-goals

- No `Sources/**` change and no migration change.
- Do not touch other tests in the file (seed race, etc.).

## File-level changes

### Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift

- Rename `testFreshStoreCreatesDefinitionSchemaAtGenerationEleven` to
  `testFreshStoreCreatesDefinitionSchemaAtCurrentGeneration`.
- In that test and in `testGenerationNineMigratesInPlaceAndKeepsSession`,
  replace each `"11"` `PRAGMA user_version` expectation with
  `String(SQLiteWorkflowRuntimePersistenceStore.schemaGeneration)`.
- Also add `XCTAssertEqual(SQLiteWorkflowRuntimePersistenceStore.schemaGeneration, 12)`
  once, in the fresh-store test. This pins the intended value, so a future
  bump is a deliberate test edit.
- Keep every table-existence assertion, `definition_blobs` absence, and the
  session-survival `XCTAssertEqual`.

## Invariants

- Same assertion count or more, with no assertion removed.
- The 9 → current migration path (including 11 → 12) stays exercised by the
  migration test.

## Verification

1. `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter WorkflowDefinitionStoreTests" > tmp/instance-cancel-integration/int-03/after.log 2>&1; echo $? > tmp/instance-cancel-integration/int-03/after.exit`
   Expected: exit 0, 0 failures.
2. `/usr/bin/arch -arm64 /bin/zsh -lc "swiftlint lint Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift"`
   Expected: no violations.

## Done criteria (mechanical)

- `grep -c '"11"' Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` returns 0 for the user_version lines.
- `grep -n "AtCurrentGeneration" Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` matches.
- `after.exit` is 0. The progress log has the pre/post sha256, the commands,
  the exit codes and the log paths.

## Concurrency / drift rules

Before the edit, read the file fresh and record its sha256. Re-check it
before writing and stop on drift. Touch no other files. Git use is
read-only.
