# DS179-01 Store Core Progress

Workflow mode: `issue-resolution`  
Issue: `tacogips/riela#179`  
Plan: `ds179-01-store-core`  
Codex agent step: `step6-implement` (`fanoutBranchId=ds179-01-store-core`, workflow execution `nested-v1-9a9d396b5a0f7002486146e80aeb21746e25f562d1764eeb9121aac79c22ba75`)  
Implementation branch: `feat/definition-store-179`

## File edits

Every source file was snapshotted before its first edit under `tmp/ds179/ds179-01-store-core/attempt-1/pre/`. Pre/post values are SHA-256 (`shasum -a 256`). New files had no preimage.

| File | Pre SHA-256 | Post SHA-256 | Reason |
|---|---|---|---|
| `Sources/RielaCore/WorkflowDefinitionStoreSchema.swift` | absent | `30ff7e884e7befc5b6812df01987fb4ab31c1a03d5e253c86fa404b2dfd65f7b` | Add schema-10 definition tables, indexes, immutable triggers, and safe incompatible-store detection. |
| `Sources/RielaCore/WorkflowDefinitionStore.swift` | absent | `6831824cf9622e2e6ed2be0eb0f951d236b66f7e4e4545e2071d94c3781a88fa` | Add pinned public models, transactional commit, insert-or-read seeding, history/current reads, digest validation and error mapping. |
| `Sources/RielaCore/WorkflowDefinitionDiff.swift` | absent | `5e087b7b76ae4cc5d1e2f9b6fa07829abc973d1ade92f49a5179d776039cf70c` | Add deterministic JSON structural diff with RFC 6901 escaping. |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `10393f3f5343bea5e99b25dea6d483cf4ac609a33071d8cee49a266a444cdf20` | `75129de665a783e52314d3641f2e38fc7f0dd67f5447905f8ffd4285bdf35f2f` | Bump to generation 10, migrate generation 9 in place, build fresh tables, and preserve stores with definition heads. |
| `Sources/RielaCore/RuntimeSession.swift` | `f5043759830697efe009f4ba7c63f4bbc2da47b25529638b1c21355e2f12f271` | `1456487aed66c6667dcabb1b52182df6268b09bc0f11f7dec1e4bcc7f7a6797b` | Add optional persisted definition source with legacy decode as nil. |
| `Sources/RielaCore/RuntimeStore.swift` | `6cc4f16f4661ea9afc3893373cfff6b3e78ddb19d3c436b48532c23aa4d89586` | `62b2a14ede3a6820dbbbe3269cb5afebe404cc33c75b6a9dbf334bc26e299486` | Carry the optional source through create input into in-memory sessions. |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | `4e67d25cc63d2b50edf4077179ed4fb2f3d60fe6e068ce61bff81fa50a2e529d` | `3ea48e1276cd0cd82ad1ed074ea17ee6ce825fccfd63b722b4bf0d9454a39101` | Add optional request pin. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift` | `480a7164538bd5f1f26851275f0d8fbdc88f3d3e272f57d90ce5b075ed623851` | `6a0f8a354d5bdfc3d9e64ce46df874e2c0f56a7a49fbc0b344803ae25c7f7e26` | Propagate the request pin through new root and rerun sessions. |
| `Sources/RielaCore/WorkflowCalleeResolution.swift` | `e077a2f5791f64d503ceb292823961bf937b1bf4756bd2a8ef06ff5e4966ff61` | `fe94d6f071de693b145281096d48f4166ebca24c5ac926c49daaedb19a008514` | Carry optional definition source on resolved callees. |
| `Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift` | `2c44313a3c10cb7032221a35cfbcf2bbaeb2d53460fa5e82cb45b54a3b0efb3` | `a694c3a465a8efe5b8afbdd89f9034190149c528dafdcb19bdafb7b2d5c69750` | Carry definition source into reserved child sessions. |
| `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift` | `da6e934b38783476bd1802c483b94e91682434df0f80d1fb0a9b386ba4126a9a` | `3672656cc7085373ada6c4401fd85e8bed305bf3bffedbc8a28feab682c1775f` | Forward callee source through cross-workflow child reservation. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | `568fb3c5dcdc067d85acecb6807e749d9c2bc850e3c1e8f535a81b08149c341b` | `c1859e918242ff5acac01f626656563109bedbb2801ce0e6164768d9a505c465` | Forward local or callee source through fanout child request and reservation. |
| `Sources/RielaCore/DeterministicWorkflowRunner+NestedPublication.swift` | `aee18b1134ad9acdf2d094182c947998b24ee98c33e41aa34ac3d38ac4bf31dd` | `e7026209d073c781778a6342e36eb11b1e8d4440d0d799931856bfbb919ba43f` | Preserve callee pin in cross-workflow publication snapshots and reservations. |
| `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` | absent | `87c3ab57d50361937757ad10b17df2d78de1f4098ef0d6106c480127de395be0` | Cover schema, migration, atomic commits, races, append-only enforcement, history, file pins, diff pointers and parsing. |
| `Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift` | absent | `90b93211c9ea438b594bc7e8d0603a087f81ffedfb74ce3911fc3c9331187492` | Cover old snapshot decoding, source round-trip, create-input propagation and root-run propagation. |
| `impl-plans/active/ds179-01-store-core.md` | `38db0aa17bac5610593d2fd2859fb42695a70f8bf09733d9bb80e1ed92a690c6` | `4238673fd841dd6303974bc2341eeb78f697aed1eb6db5fba26af9ed18ebb4a8` | Record implementation status and gate handoff without changing downstream ownership. |
| `impl-plans/progress/ds179-01-store-core.md` | absent | created in this update | Record source hashes, current and prior verification, findings and resume criteria. |

## Final-source verification

Commands ran from the repository root in an arm64 shell, in the foreground. Logs are complete files under `tmp/ds179/ds179-01-store-core/attempt-1/`.

| Command | Exit | Tests run | Failures | Log / outcome |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-01-store-core/attempt-1/build-required.log 2>&1'` | 0 | 0 | 0 | `build-required.log`; build complete. |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|SQLiteWorkflowMessageLogTests|WorkStoreTests' > tmp/ds179/ds179-01-store-core/attempt-1/final-tests.log 2>&1"` | 0 | 44 | 0 | `final-tests.log`; all four selected suites passed. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter SQLiteRuntimeSchemaMigrationTests > tmp/ds179/ds179-01-store-core/attempt-1/migration-tests.log 2>&1'` | 1 | 6 | 1 | `migration-tests.log`; only `testNoGenerationBelowTheCurrentOneHasAMigrationPath` fails because it asserts that generation 9 must not migrate to 10. This file is outside this plan's `writePaths`. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ds179/ds179-01-store-core/attempt-1/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/ds179/ds179-01-store-core/attempt-1/lint-final-2.log 2>&1` | 1 | 0 | 0 | `lint-final-2.log`; strict lint flags the required public `current` three-value tuple (`large_tuple`) and the plan-pinned nested `Op` type name (`type_name`). Renaming either would break the exact API contract consumed by later plans. |
| `grep -n 'schemaGeneration: Int64 = 10' Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift > tmp/ds179/ds179-01-store-core/attempt-1/schema-generation.log 2>&1` | 0 | 0 | 0 | Match recorded. |
| `grep -c 'definition_change_audit' Sources/RielaCore/WorkflowDefinitionStoreSchema.swift > tmp/ds179/ds179-01-store-core/attempt-1/audit-schema-count.log 2>&1` | 0 | 0 | 0 | Count is 4. |
| `git diff --check > tmp/ds179/ds179-01-store-core/attempt-1/diff-check-final.log 2>&1` | 0 | 0 | 0 | Final post-plan diff clean. |

## Superseded attempts

- `build-initial.log` and `build-final.log` exited 1. The latter exposed a throwing-expression compile error in the incompatible-store probe; the probe was extracted and the final exact `swift build` above passed.
- `test.log` ran 32 tests and had two failures: the migration-path assertion above, plus the new append-only test initially opening an uninitialized table. The latter was fixed; current final tests pass 44 tests.
- `store-tests.log` ran 26 tests and had one failure from sub-millisecond `Date` precision in a persisted audit comparison. Commit timestamps and returned records are now rounded to the schema's millisecond precision; current final tests pass.
- `lint.log` and `lint-final.log` had additional findings (optional string conversion and the persistence-store type length). Those were fixed; `lint-final-2.log` contains only the two pinned-contract conflicts listed above.

## Handoff and blockers

Implementation is limited to the assigned store-core plan and is ready for integration review after these two concrete items are resolved:

1. **Missing test write path.** The required generation-9 migration makes `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift:37` stale. It is outside `writePaths`. Resume after the serial integration checkpoint extends this plan's authorized paths for that test or routes the test update to its owning plan; then assert generation 9 has the one valid path to 10 while earlier unsupported generations remain unopenable/discardable as specified.
2. **Pinned API versus strict lint.** The exact API requires the three-member `current` result and nested type `Op`, while current strict SwiftLint rejects both. Resolve by an accepted plan/API adjustment or an approved narrow lint exception; do not silently rename the public contract.

Formal test-integrity/adversarial review, review-dependent docs, exact-file staging, commit and push remain downstream workflow steps.
