# sgc-01-payload-fragments progress

Status: incomplete. The accepted design and plan agree on additive generation-12 fragment-reference DDL. No dependencies are listed. The writer, encoder, readers, release paths, retention guards, and required tests and benchmark remain to be implemented. Do not treat the schema bump alone as feature completion; it makes older binaries reject upgraded stores.

Schema changes: `workflow_runtime_payload_refs` table and index, generation 12, and the 11-to-12 migration. The migration calls the existing idempotent table-creation seam and performs no row rewrite.

Pre/post SHA-256:
- `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`: `c5e5ad754ec8bc05f9469f6c76c35049729517643955d339f47185ae99cdd1ed` / `427e650120fc54269e59334734c24c304966bb7cbc41c929d2783e66a9e0cf0b`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`: `e9aa00359bcd0f25ac53281a198df913e28f5d15f772964aff129459578328be` / `f35a22fea2c3619d8fb604e447c52de2dff9e0d3528acc724c07480df044421b`

Verification: `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build …'` exit 0, `tmp/session-storage-gc/sgc-01-payload-fragments/build-attempt-1.log`. Selected-file strict SwiftLint via `changed-swift.nul` exit 0, `tmp/session-storage-gc/sgc-01-payload-fragments/lint-attempt-1.log`. These check only the partial source; no behavioral completion is established.

Outstanding: implement all fragment lifecycle and hydration requirements; update migration and bounded-write expectations; add fragment, fail-closed, release, nested, legacy and CLI parity tests; run benchmark and record baseline/stored numbers; run the required aggregate and reconcile generation-12 failures. Formal review and finalization belong to later workflow steps.

The first aggregate executed 108 tests with four failures, all generation expectations in the two assigned test files (`test-attempt-1.log`, exit 1). Updated three stamped-generation assertions to 12 and the future-generation rejection fixture to 13. The rerun passed 108 tests with zero failures (`test-attempt-2.log`, exit 0); no fragment test class exists yet, so this is not completion evidence. Other fanout changes were present during these commands; treat both build and test runs as moving-tree evidence and rerun final gates after implementation.

Additional pre/post SHA-256:
- `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`: `717117e477ef0a2be6ec5a63b47683ae76c93cac9a7870d6f904d09d4676690a` / `9f8c79e596826486b33d238d0148626dd0d8686e2cbd05f795ae22d5b57aed43`
- `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`: `1925fd7a0e47826f0f08e542d571756d36d6357dd405642bd80ab53f29c1cba5` / `c993dea3aefdadd0061439708dd4817fbc0e2df8a41fde1d13e3a36b696060e2`

Selected-file strict SwiftLint including both test files passed (exit 0, `lint-attempt-2.log`, manifest `changed-swift-2.nul`). The explicit 11-to-12 preservation test remains outstanding.

Continuation 2: family deletion now removes payload reference rows before payloads when the table exists; tombstone INSERT/UPDATE guards cover the reference table. Pre/post hashes and edit intent are in `tmp/session-storage-gc/sgc-01-payload-fragments/continuation-2/retention-{before,after}.sha256` and `retention-intent.txt`. No fragment writer, reader, release, nested hydration, new tests, or benchmark has been implemented; status remains incomplete. The schema bump alone does not provide the promised space savings.

Verification on the shared tree: selected strict SwiftLint via `continuation-2/changed-swift.nul` exited 0 (`continuation-2/lint.log`); the assigned aggregate with temporary HOME exited 0, 108 tests, zero failures (`continuation-2/aggregate.log`), but selected no fragment test classes, so it does not satisfy the behavioral gate. A narrower retention run exited 0, 29 tests, zero failures (`continuation-2/test.log`); it used ambient HOME and is not evidence of the required isolated fragment tests. The required benchmark values, migration preservation test, CLI parity test, and final build after complete implementation remain outstanding. Formal reviews and finalization are downstream.
