# bots-13-model-surfaces progress

Plan: `impl-plans/active/bots-13-model-surfaces.md`
Checkpoint: `31f978b26cae649803d0788391278fdcf49f2424`
Issue: workflow input, no GitHub issue. Design accepted in `comm-000004` and plans accepted in `comm-000008`.

## Implemented

- [x] `riela model list` and `riela provider list|show|refresh|add|update|remove` use the scoped runtime store. Custom models can be replaced or cleared, and passive refresh stores the latest health report.
- [x] Six typed catalog GraphQL root fields use the existing bot executor. Selected nullable fields return null when data is absent.
- [x] Accepted activity config and model reports update the provider catalog after the activity transaction commits. Stale executions cannot update the catalog.
- [x] Bot create and update reject missing provider instances and return `model_unknown` warnings for unknown models. The default sentinel does not warn.
- [x] Generated SDL, CLI and catalog parity, behavioral suites and selected-file SwiftLint pass.

## Per-edit hashes

Exact intended hunks and full SHA-256 records are in `tmp/bots-overview/bots-13-model-surfaces/edit-intentions.md`. The generated hunk is in `tmp/bots-overview/bots-13-model-surfaces/sdl-hunks.diff`. This progress file's hash is recorded in the same edit ledger.

| Path | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `Sources/RielaCLI/RielaClientCommandRouter.swift` | `8091abedeb1f9474a07686e2b6b991a1e8f6959e84dccef4102bc562250711e9` | `dec4e19e4fd5173a6101f261fe7ee98b094b6e97b62efb6aa1c1733bd1890874` |
| `Sources/RielaCLI/RielaClientFamilyArguments.swift` | `165bdac806520cdcfeecf5e5b45a906c290d8889957ddf9c80c6713c17a0e42f` | `2cedca1949adb5a6635eaf86f1c9ead841c6a2c3f640363793c4b86d5944a84e` |
| `Sources/RielaCLI/RielaCommand.swift` | `936ac4a2e35d963f7c037991a71c623492d40cae7e66b6e0ef8d71ae111880a4` | `48ef2c8149b3c49c7b32ec05c56f6afcdeb1fee7005a680ad75b02c230849324` |
| `Sources/RielaCLI/ScopedParityCommands.swift` | `1b062a618f3416bbb342f2870074c30fdc320f8adbfe846e36c45b505cba3d9d` | `4172a641320ff2c76210b937ac72cbba3463f3caf4dcad93357732ed27bd7e79` |
| `Sources/RielaCLI/CLISurfaceEnumeration.swift` | `f4bf8d29fc7e973b2822be85910d6e631a2905db8f289526229353a99e9a838d` | `36dbeb9afa068de7f7a519e1c9361992fa08ed94dab5d4179ee1a41d76f6fdfd` |
| `Sources/RielaCLI/RielaCLIApplication.swift` | `c90aabbdd4046afe262773f5d1843fa794640012c220b953d4527d93c21d3d83` | `18652a0650c1821990e3109f8303c084a018b800812661dfa4002f4da3d535a9` |
| `Sources/RielaCLI/RielaCommand.swift` | `48ef2c8149b3c49c7b32ec05c56f6afcdeb1fee7005a680ad75b02c230849324` | `31417f1843b504128b1741e25172dcee1a8d94631a460348b13c00347b3acd2a` |
| `Sources/RielaCLI/ScopedParityCommands.swift` | `4172a641320ff2c76210b937ac72cbba3463f3caf4dcad93357732ed27bd7e79` | `f591d64591064c2671077339fb314c4fd6270025ed03ce94554fee3ec71a0a6d` |
| `Sources/RielaGraphQL/Bots/ModelCatalogGraphQL.swift` | `absent` | `507621f6658b44d08ded6f8d9302c1f2768850e8a2ceb5b9cd71a0b95a69ccf9` |
| `Sources/RielaGraphQL/Bots/BotsGraphQLContracts.swift` | `d9da73761c5d17b0cfa886a1b0483c817813a71525be2a740b667d22b372789e` | `172ff5cb7bc45e32cba06c2e67d1eed0b18ad31c5e716a38d5d88668ee769c0a` |
| `Sources/RielaGraphQL/Bots/BotsGraphQL.swift` | `7993682dc6799fefce728542f54da7e68bb10dde0bced3a7f2862492b706824e` | `471eb5538a9b6d48e1b4260c3266fe16fb26f350a59d99eb7a195b9679bbd912` |
| `Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift` | `absent` | `0d3c763d4ab563f363839aab6f0ee7222b5bd8d64fba876c95b2d4bd704a328e` |
| `Sources/RielaCLI/Bots/BotsService.swift` | `788a974193b5e691923aefc39c03d4bdd3b4722c329c6beaf979673cc2c829a0` | `53fa6c3b8ac5e37a364ce01650ebe0bcc8af084c0c5124bd15afb6af0e8aaaf9` |
| `Sources/RielaCLI/Bots/BotCommands.swift` | `0404d0d21dbd8393649b48314ca9002cbf289ad99324b66abbed19d89a7ea88b` | `eb023952fe89ce1fecec9a30ae1a184821231929c81dd98ad596c667e2c6f956` |
| `Sources/RielaCLI/Bots/BotsGraphQLProvider.swift` | `a04612bcd9246cc9617ae6918dbcce278794d55de1bb37c139c3238dbe6a8f65` | `5987777f7ba58d026f0a5330efdb1f11a833a4bc88f40b806d469003a095ae62` |
| `Sources/RielaCore/BotActivity/SQLiteWorkflowActivityRecorder.swift` | `436d5be070fdb1c483a5495f889d807567a98a1f62a0d10d4a8e390cf1114e7d` | `054d065dee70289b68f059749bf489d93085a9c7e98b4aec56a1f8430c730f18` |
| `Sources/RielaCLI/ModelCatalog/ModelCatalogCommands.swift` | `absent` | `87f9b4edbeb39440986e9da53d7519e3a82093f65b9f9d63be805594912eeb28` |
| `Sources/RielaGraphQL/Bots/ModelCatalogSchemaDescriptors.swift` | `absent` | `67b7bb6c3d223eb6ac2a73644bdf644350401fa68421e11a79294118503ffa5b` |
| `Sources/RielaGraphQL/Bots/BotsSchemaDescriptors.swift` | `da14a5fa552f7e636b36c6c25b516fc814405f4862fbb35694f9f23638737139` | `c8e6631c30b1d51da3baf13d2db06f1cc32039ab77bbc0254113b21763871247` |
| `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` | `5bfd51467fdbab46c6e235c704cc81ec11970050dc58ad789c225bec3172680a` | `b6b89157daa322862ab8d7e46d6e587fd69eb7f4af3f62f0bce05c047954620b` |
| `Sources/RielaCore/SurfaceCatalog+RowsBots.swift` | `5b4b5dd4843e1a9b851222f5d61562f7c657b0f924771b279f2b36f1c2f9ad49` | `e69d642bffc845494e7b6d83f2a8eeefce2d0e7e3b4a5c063fac7a5997e45011` |
| `Tests/RielaCLITests/ModelCatalog/ModelCatalogCommandTests.swift` | `absent` | `80606243a49026cbadde1e97f70d41c072da8400c0516b79b2b363b429140400` |
| `Tests/RielaCoreTests/BotActivity/ActivityCatalogReportTests.swift` | `absent` | `ff15f2f28146316f59e243c504e6c2fde8aeb94b6914f9dc42ad3da707ea4c18` |
| `Tests/RielaGraphQLTests/Bots/BotsGraphQLTests.swift` | `3fb7647c939968bbea96838862ca3cbb18254b6a9cec79969cda623e6a5e6835` | `883bb91d6cdbb9fdf353be2114061298b373984cb389ebe0b343b2bffbabee1c` |
| `Tests/RielaGraphQLTests/Bots/ModelCatalogGraphQLTests.swift` | `absent` | `4859534906167fdee293faa92fed2322d07ba7cb39ad5f3b8d8867b4b453af7b` |
| `Tests/RielaCoreTests/BotActivity/ActivityCatalogReportTests.swift` | `ff15f2f28146316f59e243c504e6c2fde8aeb94b6914f9dc42ad3da707ea4c18` | `c7c1d47a0a18fd7c2fb74f492e067e96a9ba6adbdf9fa06512a4e970ad75af9a` |
| `Tests/RielaGraphQLTests/Bots/ModelCatalogGraphQLTests.swift` | `4859534906167fdee293faa92fed2322d07ba7cb39ad5f3b8d8867b4b453af7b` | `190bb878fea2569ef22f0688f0182498507148c47a019a4240a6dbc6c96e9773` |
| `Tests/RielaCoreTests/BotActivity/ActivityCatalogReportTests.swift` | `c7c1d47a0a18fd7c2fb74f492e067e96a9ba6adbdf9fa06512a4e970ad75af9a` | `f3172a31baf8414209e3ad78ccaf57181dac20476acd8fbe780578d93996e754` |
| `Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift` | `0d3c763d4ab563f363839aab6f0ee7222b5bd8d64fba876c95b2d4bd704a328e` | `670ab5c7bf63b96b5e983b3364cc680a6133cbf2627d7ad39a72213e3fcf4b4a` |
| `Sources/RielaCLI/CLISurfaceEnumeration.swift` | `36dbeb9afa068de7f7a519e1c9361992fa08ed94dab5d4179ee1a41d76f6fdfd` | `d7b8388e573b698465183ab564f627238624db3dee0860c6088dd88a686d065d` |
| `Tests/RielaCLITests/ModelCatalog/ModelCatalogCommandTests.swift` | `80606243a49026cbadde1e97f70d41c072da8400c0516b79b2b363b429140400` | `01580fcb067edeb3be0749d82264aac8a98e5d2630716264127ccda8f3d32902` |
| `Sources/RielaCLI/Bots/BotsService.swift` | `53fa6c3b8ac5e37a364ce01650ebe0bcc8af084c0c5124bd15afb6af0e8aaaf9` | `b95dd1d06e006a8d37b82f9a58c682fc31cf3ef68cd0f7c485ce60f328c44a62` |
| `Sources/RielaGraphQL/Bots/ModelCatalogGraphQL.swift` | `507621f6658b44d08ded6f8d9302c1f2768850e8a2ceb5b9cd71a0b95a69ccf9` | `cadb48c002f395f44c73eba99aac578b0386de24b51c7616316dfff788dd38b7` |
| `Tests/RielaGraphQLTests/Bots/ModelCatalogGraphQLTests.swift` | `190bb878fea2569ef22f0688f0182498507148c47a019a4240a6dbc6c96e9773` | `24de9563dda94f5358a539ed001bc97a2e2e3a10d0939fa3b2c3f0f0b6198d98` |
| `Sources/RielaCLI/ModelCatalog/ModelCatalogCommands.swift` | `87f9b4edbeb39440986e9da53d7519e3a82093f65b9f9d63be805594912eeb28` | `492315a8675e364f8ea46dac84a633f6c2270fe0b5dcedad219834f7bda2fd3c` |
| `Tests/RielaCLITests/ModelCatalog/ModelCatalogCommandTests.swift` | `01580fcb067edeb3be0749d82264aac8a98e5d2630716264127ccda8f3d32902` | `693d0451887259790ed088649c1ba4905bd0f70eaccfd9135367e9ed6a17c2ce` |
| `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | `eb4e8bdd86f49ca6f3aefab2322ecd38186581e26a9a995219abf9668b49b162` | `d908271ab82fdbe24776d38590c7498e1750865bdaae827b0df809e1df477586` |

## Verification

Logs are under `tmp/bots-overview/bots-13-model-surfaces/`.

| Command | Exit | Log | Result |
| --- | ---: | --- | --- |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl.log` | Executed 1 test, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "ModelCatalogCommandTests\|ModelCatalogGraphQLTests\|ActivityCatalogReportTests\|ActivityRecorderTests\|BotCommandTests\|SurfaceCatalogTests\|SurfaceParityCLITests\|SurfaceParityGraphQLTests\|SurfaceParityExecutorCoverageTests\|SurfaceParityDTOSchemaTests\|SurfaceParitySkillTests"'` | 0 | `test.log` | Executed 54 tests, 1 skip, 0 failures. The dedicated generation run above exercised the skipped test. |
| `grep -rn "BackendCapabilityProbe" Sources/RielaCLI/ModelCatalog` | 0 | `probe-locality.log` | One match, in the passive probe invoked by refresh. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-13-model-surfaces/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | `swiftlint.log` | 24 changed Swift files, no diagnostics. |
| `cmp tmp/bots-overview/bots-13-model-surfaces/test-source-before.sha256 tmp/bots-overview/bots-13-model-surfaces/test-source-after.sha256` | 0 | `test-source-stability.log` | 1,802 entries identical. |

The first and second SDL attempts stopped before tests on new fixture compilation errors. The first fixture lacked the `options:` label and the second needed the named `probe:` closure. Both were corrected and the successful generation run superseded them. Complete logs are `sdl-attempt1.log` and `sdl-attempt2.log`. The first pre-SDL lint found the route switch complexity and test closure syntax and was superseded by the final changed-file lint. Its log is `swiftlint-pre-sdl.log`.

## Deviations

- `provider add` and `provider update` both use the same save action. The catalog assigns the GraphQL root to `provider.add` and documents the shared root on `provider.update`, following the existing unique-root registry convention.
- `Sources/RielaCLI/Bots/BotCommands.swift` renders warnings on stderr as required. The file is within the authorized Bots directory and the hunk is limited to create and update output.
- The explicit script generated SDL before the CLI probe-age text edit. The final-source parity run confirmed the generated file is byte-identical to the current generator.

## Open items

- Formal test-integrity and adversarial review, then serial integration gate C5.
