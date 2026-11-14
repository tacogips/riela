# eh-02-runtime-contract progress

## Session: 2026-10-27 — step6-implement

**Workflow:** issue-resolution, workflow execution `opus-luna-design-and-implement-review-loop-session-518`.
**Issue:** Owner issue “One shared versioned history (diff, undo/redo, retention: memory 2 / state 1 / workflow definitions 10) and efficient session storage with storage doctor/compact” (no GitHub number).
**Plan:** `impl-plans/active/efficient-history-02-runtime-contract.md`; dependency list empty and accepted predecessor list empty.
**Codex-agent role:** Step 6 implementation for `eh-02-runtime-contract`.

## Implemented

- Added SQLite BLOB binding and byte-preserving `SQLiteRow.data(_:)` for TEXT/BLOB columns while preserving string access.
- Added `incrementalAutoVacuumForNewFile` and `writableRuntimeStoreDefault`. The new-file condition is captured before SQLite opens the file; `auto_vacuum=INCREMENTAL` runs only for a new/empty schema and before WAL.
- Advanced runtime schema to generation 11, added the frozen generation-10 definition DDL and 10→11 migration seam, and added generation-9/10 migration tests that preserve snapshots.
- Added exact eh-04/eh-05 no-op schema/pin stubs, placed same-store and foreign-store pin calls at the assigned transaction boundaries, and wired schema create calls.
- Switched runtime, message-log, CLI and WorkStore writable openers to the runtime option. CLI and WorkStore each have only the requested one-line change.
- Added BLOB, auto-vacuum, incremental reclamation, generation migration, and CLI/WorkStore first-opener tests.

## Per-edit hashes

Pre-edit SHA-256 values were recorded in `tmp/efficient-history/eh-02-runtime-contract/edit-intentions.md`. Existing-file pre→post pairs:

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaSQLite/SQLiteDatabase.swift` | `9505d037af6546f34114b52eac435bf7075f00b0e6ac01582ae06a57e0fb7062` | `ed3dddc0e0c2292c090bb6dcee3c55f3327073e96a80cf1c5346e6eadedcac40` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `70451aac60385e8c144f83198df9653293f1a0b52bd641ce403efd861ff3e505` | `15008427c2bb0bbfd8a7318c1cc91c6796da01a292a4bd2dfc5d5d197cf01d90` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` | `eb2055e14db0c8278ff112a0d46b3ab3b98f70e42f84ee2b93247716aac6d5ce` | `66fd74fda15c60bc6f77832f5561e0f803b15311286541d187d7a8fc5343f6c8` |
| `Sources/RielaCore/SQLiteWorkflowMessageLog.swift` | `51386b9aa7f4c62f6536adb6863b6cf861aa117fa3209acb7d854c07c407769e` | `8f11b81ae44d5dd7a543166249dc4aeb1dbe0c524c03cb79eb06d917e3a3e7d7` |
| `Sources/RielaCLI/CLIWorkflowSessionStore.swift` | `58239b3b1091b18c26253e4eb53a25f345e00c4dac1fcbcc3795e22e6ec38fb7` | `9e70f8f6ea2c6fcbbe44ffb2ce5da068be7c4a70b44c331a599c08322716a2f5` |
| `Sources/RielaWork/WorkStore.swift` | `9cc5dca58ecd5f805974bdce08ca179c759c227fac84fb2aa9abc24ec3788950` | `442b8a54f6e2aa06c27e5645379dae08a9c83674ebfc381c7dfaf89ad2afc5fe` |
| `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift` | `8ef832e1242c97f59ec2bbb2754c48833d0792035dd9364c7acb9ec7d89fe799` | `16d539d1a135d5df22b337fe6038349dc6607e62223328bf99ddc35e7194b313` |

New files had no pre-edit file hash (absent before creation); their post-edit hashes are recorded here:

- `Tests/RielaSQLiteTests/SQLiteDatabaseBlobAndAutoVacuumTests.swift`: `072713c026adcfdfc7e2df1889cc205fe7734cfb6c37da5a742553ac2ab00413`
- `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift`: `5a34c53efa80c559ea92ae5ad5de2762a3f389d18ff061321f00147772e27815`
- `Sources/RielaCore/WorkflowDefinitionPins.swift`: `2c1339a9e2348835a5fe3f9111aed7ce63e6fa5bcd623d0bd97a246e5812d722`
- `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`: `0c9de6ecc1d6e676a4eee141e2e5ea16248b95c0030c18a5ebe13d18c2499e04`
- `Tests/RielaCoreTests/SQLiteRuntimeAutoVacuumTests.swift`: `a131eec1a3042f3091fbac64001d891e9d94177955179cbebaaf1eff43b54352`
- `Tests/RielaCLITests/RuntimeStoreFirstOpenerAutoVacuumTests.swift`: `e5e22aedb7b80231f4b60831f3a9e63b5873e7654f77a5be9c0966222ce9e266`
- `Tests/RielaWorkTests/WorkStoreFirstOpenerAutoVacuumTests.swift`: `576700a1913bdbfeca91823d654245f47ce7958fcff4f6b5acc63cdfc360b2c8`

The CLI test was corrected after its first run used the wrong expected database root. The intended root is `<session-root>/runtime-records`, as `canonicalRuntimeStoreRoot` defines; the final test computes that root and passes. The correction intent is recorded in `edit-intentions.md`.

Follow-up edit pair for empty BLOB correctness:

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaSQLite/SQLiteDatabase.swift` | `ed3dddc0e0c2292c090bb6dcee3c55f3327073e96a80cf1c5346e6eadedcac40` | `52231147a6e0b0d044daa33565bf31232d83a4f7a5eb52fe24973876b5b7c0bf` |
| `Tests/RielaSQLiteTests/SQLiteDatabaseBlobAndAutoVacuumTests.swift` | `072713c026adcfdfc7e2df1889cc205fe7734cfb6c37da5a742553ac2ab00413` | `a076c2a90dbf2ad5f22e85fb78aa80080f11c0899eb3a1a1083794088f02a0f1` |

Follow-up edit pair for the required generation-11 documentation wording:

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `15008427c2bb0bbfd8a7318c1cc91c6796da01a292a4bd2dfc5d5d197cf01d90` | `500003d7de26d5383c2ee4dd806e1e92d6f1fc1e7ddf4bea8a0ca1357bfafb1b` |

Continuation 1 refactor and acceptance-token edit pairs:

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (move schema helpers to extension) | `500003d7de26d5383c2ee4dd806e1e92d6f1fc1e7ddf4bea8a0ca1357bfafb1b` | `cef02c61f64d300929a5558d6f7a0aacd183263b2a19599a6b14c157cd9f578c` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` (receive schema helpers) | `66fd74fda15c60bc6f77832f5561e0f803b15311286541d187d7a8fc5343f6c8` | `f799d15f5ea6870ceaedd88f11c018b8472c5992e4e1e64758db1b3b6acdeb6d` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (move `openDatabase` into extension) | `cef02c61f64d300929a5558d6f7a0aacd183263b2a19599a6b14c157cd9f578c` | `07c54e465451503ce24324f0f48e8fb90042abe7fe7f4b09f70d75d5c5e2d087` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` (receive `openDatabase`) | `f799d15f5ea6870ceaedd88f11c018b8472c5992e4e1e64758db1b3b6acdeb6d` | `2a7f7b8c86aa43f3362f6332346a3d96a0347d4b14b9b69ba443adffd8950d2c` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` (vertical whitespace cleanup) | `2a7f7b8c86aa43f3362f6332346a3d96a0347d4b14b9b69ba443adffd8950d2c` | `0364b39e770da71f130448fc65b030bbc9c0423a08780c444e7ded822928a29d` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (retain required generation search tokens at primary seam) | `07c54e465451503ce24324f0f48e8fb90042abe7fe7f4b09f70d75d5c5e2d087` | `c300ad58ee5bfeb6ee9e265b883c43be8ac5f6bc1204c3639c3c8e603ef6d77c` |

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build'` — exit 0 on continuation-1 final source; complete log: `tmp/efficient-history/eh-02-runtime-contract/build-continuation-1-final-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteDatabaseBlobAndAutoVacuumTests|SQLiteDatabaseTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeAutoVacuumTests|RuntimeStoreFirstOpenerAutoVacuumTests|WorkStoreFirstOpenerAutoVacuumTests|WorkStoreTests|SQLiteWorkflowMessageLogTests|SQLitePersistenceSessionExistsTests|PrivateWorkflowTests"'` — exit 0; 81 tests, 0 failures; complete continuation-1 final-source log: `tmp/efficient-history/eh-02-runtime-contract/test-continuation-1-final-final.log`.
- The four private workflow fast-path/fence tests passed: canonical reuse metadata, canonical reuse rollback/legacy fences, terminal committed-status fence, and preserved embedded canonical history; see the same test log.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/efficient-history/eh-02-runtime-contract/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` — exit 0 on current source after moving schema/migration helpers and `openDatabase` into the schema extension; complete log: `tmp/efficient-history/eh-02-runtime-contract/swiftlint-continuation-1-final-final.log`.
- `tmp/efficient-history/eh-02-runtime-contract/acceptance-audit.sh` — exit 0 on current source; verifies generation markers, hook placement, runtime option at all four openers, exact CLI/WorkStore 1/1 numstat, and `git diff --check`; complete log: `tmp/efficient-history/eh-02-runtime-contract/acceptance-audit-continuation-1-final-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionStoreTests'` — current-source negative control, exit 1, 10 tests run / 2 failures. Expected out-of-scope generation assertions in `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift:20,43` still expect 10; eh-04 owns those assertions. Complete log: `tmp/efficient-history/eh-02-runtime-contract/out-of-scope-generation-continuation-1-final.log`.

## Superseded attempts (not final-source passing evidence)

- Initial build wrapper used zsh's read-only `status` variable after `swift build`; wrapper exit was 1. Repeated with `result_code`; final build exit 0.
- Initial focused test run failed one CLI first-opener test because the test looked under `<session-root>` instead of `<session-root>/runtime-records`; corrected and rerun.
- Next focused run failed the page reclamation test because `execute` was used for a row-returning PRAGMA (`another row available`); changed to `query` and reran. Final focused run passes.

## Done criteria

- [x] BLOB API and new-file incremental auto-vacuum behavior implemented and tested.
- [x] Generation 11 migration chain and frozen generation-10 schema seam implemented; generation 9/10 migration tests preserve snapshots.
- [x] No-op eh-04/eh-05 stubs and pin-hook call placements implemented.
- [x] All four runtime DB first openers select the runtime-specific writable option; CLI/WorkStore edits are each 1/1.
- [x] Listed behavioral tests pass with non-zero count; private-workflow fast paths/fences stay green.
- [x] Expected eh-04 generation assertion failures logged as out-of-scope.
- [x] Progress log includes pre/post hashes for `SQLiteWorkflowRuntimePersistenceStore.swift` and all existing edited files.
- [x] Strict changed-file SwiftLint passes after moving schema/migration helpers and `openDatabase` into the existing schema extension; no lint rules were suppressed.

Formal implementation review, review-dependent shared docs/index updates, commit, rebase and push belong to later workflow steps.
