# bots-01-contracts implementation progress

Workflow mode is `issue-resolution`. Implementer is Codex `/root` at `step6-implement`.
Read-only investigators were `/root/migration`, `/root/runner`, and `/root/contracts`.
The workflow input of `fable-sol-design-and-implement-review-loop-session-1` defines the scope.
Design acceptance is `comm-000004` and plan acceptance is `comm-000008`.
The shared branch is `feat/bots-overview` at dispatch checkpoint `666108c9f32fe3f926d5c1448ab8f2063c4f714a`.

## Implemented

- Registered the additive 12 → 13 migration and used the same eleven-table schema for fresh stores.
- Added bot validation, CRUD, pause, deterministic session linkage, and transactional removal guarded by pending permissions.
- Added the shared adapter, activity, permission, bot context, and origin types. The three child constructors inherit the context and recorder.
- Added optional routine linkage to its existing JSON and connected the empty bot family to the surface catalog.
- Added store, migration, and activity contract suites. Updated current-generation expectations and kept the newer-build rejection assertion relative to the current generation.

## Per-edit hashes

Exact intended hunks and before/after SHA-256 hashes are in `tmp/bots-overview/bots-01-contracts/edit-intentions.md`.
Each post-edit hash was rechecked, and repeated edits matched the preceding post-edit hash.

| Path | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` | `9dea04ab4b61f709d5d0e289835e781c279e2d4f6bb2820ec837891e7cb5b769` | `07294ea246f79c70f8472391f18bd34d18f28c47af2cae7243c858a55a9666fc` |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | `dca998f7432cf5c927eb226ef03d24f1a0107419d072d7ed2f9bd46fbaa19257` | `bb0e606e81f21c1ba9e556f779809cffb83bb86e1d5e8613286c240af4a11c91` |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | `5f1640b4d6c3f477da9b26057950c0e19658576b00e674f2f4974eae79e08740` | `b5e3795f1174acf73c8ed684241c37191c45003582fd168595d13f717f7932a4` |
| `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | `a380c84d3f0b3a562669fcb52ab70f1aa6ebd00a934d53ac0e26b346aecd0f72` | `096748fb44f4e6b6f273a28b08f5247988a440331f969cd2ecf6b8d4ff6091a5` |
| `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift` | `3672656cc7085373ada6c4401fd85e8bed305bf3bffedbc8a28feab682c1775f` | `f3299833db2e59e4493d78b55c7e7176895a033573b131c21d2b2fc7f747a462` |
| `Sources/RielaCore/DeterministicWorkflowRunner+DynamicWorkflow.swift` | `5e4c449b596287f58e7188909165d1528f5b605c20c8864ae2a24ae3359b6725` | `0143305c53b800ed15fc1212bf236811bfe1a78fe88c8378a9d6a3a3730f610a` |
| `Sources/RielaCore/RoutineStore.swift` | `24c600161a9e04850c249311f14e30fc7df60cc40271c2c4eb0207ea57e2faa8` | `861baaec4f4a4c0869d2ba9a5fac861c6c39cb5445c656c7d51b802b0b9ce81b` |
| `Sources/RielaCore/SurfaceCatalog+Rows.swift` | `d1e8c1ae3d52f1db9950de018c16e5a0040f1fdfa051dea89013c3d0fb59b59c` | `3f8f18b3f58095e170dcd5174b5204e71a861240f175817220d502168046386e` |
| `Sources/RielaCore/SurfaceCatalog+RowsBots.swift` | `absent` | `cb1b7a20d93f65b2a0908d33679219d2ffdf5470969ccb2df2c721b0baabfa98` |
| `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift` | `c993dea3aefdadd0061439708dd4817fbc0e2df8a41fde1d13e3a36b696060e2` | `ae15170fbfc2db3cefc65dc676fcbb8f0c18bc45a6a98e1057811a73536dfb59` |
| `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` | `2ee28d839c5ea4670f91add31f1f17b1d6ac8b0a7d414e8027e30de1c5357b9a` | `9a81f26ebbf7b99d409cc3091a9f512545b9d34b9b80afd80ba4669c01a92fba` |
| `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift` | `ccedba225ed2df97ed855bbd54afef66c1e5923e59a0eea81612ec7c4127c1b8` | `72fb11a62e73843f8a70b49cdaac04f74209d2cf3cc745ece85cf8afc2108f86` |
| `Sources/RielaCore/AdapterContracts.swift` | `eaee8638b6ed30c00042daad4ac6f40f8736ae07621a5649eeeb252f8c4f33ab` | `f881d1651c55b554a323be253488e6fbbae11d490786f9faf286342e74fa979e` |
| `Sources/RielaCore/Bots/BotRecord.swift` | `absent` | `bb0225f76ff521332c63334176918d43e73238ac29923ef3e1a14f2ab440fa91` |
| `Sources/RielaCore/Bots/BotRunContext.swift` | `absent` | `c115fc9cb2d71d31d41aba080e3970986915e5fb7d54c67ff96f1b6a9244d175` |
| `Sources/RielaCore/Bots/BotOrigin.swift` | `absent` | `5134aba7fe550c17f42d9aa9562551519e62b1a5aa17be68f3e7e51916efa430` |
| `Sources/RielaCore/Bots/ActivityModels.swift` | `absent` | `54c1dd320bd00c34ae7fa84011e1eaf7d1abc19f923fa3fc3ee788610cf80cda` |
| `Sources/RielaCore/Bots/BotRecord.swift` | `bb0225f76ff521332c63334176918d43e73238ac29923ef3e1a14f2ab440fa91` | `63ca9355e8dede5b79df6e03c3085e985cd6156ddc12cf8ce4555f59a3debd4a` |
| `Sources/RielaCore/Bots/BotStoreSchema.swift` | `absent` | `856e1940ed549de95a193a7dcb829fe7480800b81dd7a069b74724130b00198d` |
| `Sources/RielaCore/Bots/BotStore.swift` | `absent` | `1abe4f14b268692a54b8403f0e7b9acc35858bf99934d5d45e54e0a47f1bcc66` |
| `Sources/RielaCore/Bots/BotStore.swift` | `1abe4f14b268692a54b8403f0e7b9acc35858bf99934d5d45e54e0a47f1bcc66` | `63c07db987df800614231b3045089375d57a8dfa909d66dfe8fc8005a3fdeeff` |
| `Tests/RielaCoreTests/Bots/BotStoreTests.swift` | `absent` | `b42da2edc1e0fc003e26610b34d271838e51aa518c1977416e645760d988970b` |
| `Tests/RielaCoreTests/Bots/BotStoreMigrationTests.swift` | `absent` | `f08c78e4b54a3005978200484b6aacc46e8240b6467c060bc4d0e4f7104375c5` |
| `Tests/RielaCoreTests/Bots/ActivityContractTests.swift` | `absent` | `6cda2c47090c7f01458600211441911131224cdcf6469b9b77a4edc2659f65f3` |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | `b5e3795f1174acf73c8ed684241c37191c45003582fd168595d13f717f7932a4` | `a2948faba27f4dc299491c438f013dde165993079c956f2a3a923137f395a932` |
| `Sources/RielaCore/Bots/BotStore.swift` | `63c07db987df800614231b3045089375d57a8dfa909d66dfe8fc8005a3fdeeff` | `9fd47fef8bf7cecc8db8880fab6ce3bf345673ba75dbc62cf7a506aee749f27f` |

## Verification

The before and after Swift source identities match in `tmp/bots-overview/bots-01-contracts/verified-source-before.sha256` and `tmp/bots-overview/bots-01-contracts/verified-source-after.sha256`.
Build and tests ran sequentially on the shared checkout. The test process inherited `TMPDIR=tmp/bots-overview/bots-01-contracts/test-tmp` as an absolute path.

| Command | Exit | Tests | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build' > tmp/bots-overview/bots-01-contracts/build.log 2>&1` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotStoreTests|BotStoreMigrationTests|ActivityContractTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeExecutionRowsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|SQLiteWorkflowMessageLogTests|RoutineStoreTests|WorkStoreTests|SurfaceCatalogTests"' > tmp/bots-overview/bots-01-contracts/test.log 2>&1` | 0 | 112 | 0 | `tmp/bots-overview/bots-01-contracts/test.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-01-contracts/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/bots-overview/bots-01-contracts/swiftlint.log 2>&1` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/swiftlint.log` |
| `grep -rnE "user_version = 1[2-9]\|generation 1[2-9]" Tests > tmp/bots-overview/bots-01-contracts/generation-literals.log` | 1 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/generation-literals.log` |
| `grep -n "schemaGeneration: Int64 = 13" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift > tmp/bots-overview/bots-01-contracts/schema-generation.log` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/schema-generation.log` |
| `grep -rn "botFamilyRows" Sources/RielaCore > tmp/bots-overview/bots-01-contracts/catalog-rows.log` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/catalog-rows.log` |
| `git diff --stat 7f04f6e6 -- Package.swift Package.resolved > tmp/bots-overview/bots-01-contracts/package-diff.log` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/package-diff.log` |
| `git diff --check > tmp/bots-overview/bots-01-contracts/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/bots-overview/bots-01-contracts/diff-check.log` |

XCTest summary is `Executed 112 tests, with 0 failures (0 unexpected) in 7.477 (7.494) seconds`. All eleven selected suites passed.
The generation-literal inventory returned no matches. Frozen generation-12 fixtures and explicit current-generation assertions are intentional.
The schema check matched one declaration, the catalog check matched the definition and aggregate use, and the dependency diff was empty.

## Deviations

The first build exited 1 on a row-type mismatch and source edits made while it was compiling. Its complete log is `tmp/bots-overview/bots-01-contracts/build-attempt-1.log`.
The first selected-file lint exited 1 on explicit optional initialization and JSON string conversion. Its complete log is `tmp/bots-overview/bots-01-contracts/swiftlint-attempt-1.log`.
The corrected source passed both final gates.

## Completion criteria

- [x] Additive generation 13 preserves the generation-12 snapshot and creates the eleven tables.
- [x] Shared contract names are in place and the surface catalog aggregates its bot family.
- [x] Dependency manifests produce an empty diff against `7f04f6e6`.
- [x] Build, all selected suites, strict changed-file SwiftLint, and generation inventory are verified.
- [x] Plan-local progress and per-edit evidence are recorded.

## Open items

Independent integrity, adversarial and integration review, the serial wave gate, and finalization remain downstream.
