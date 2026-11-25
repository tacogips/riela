# bots-10-bot-surfaces progress

**Workflow mode**: issue-resolution  
**Issue**: no GitHub issue. Design accepted in comm-000004 and plans in comm-000008.  
**Checkpoint**: `31f978b26cae649803d0788391278fdcf49f2424` on `feat/bots-overview`.  
**Implementer**: `/root`, `step6-implement`, `nested-v1-fe2cf6eb2f7231a4c4214234e33edbb823f423bb8f2249badebc8b95b926a915`.

## Implemented

- Registered fourteen `riela bot` verbs and seven GraphQL fields. The shared service uses the runtime BotStore and board projector, session families, task ownership, existing routine records, and persisted list state.
- GraphQL applies local trust and operation preflight. All five hosts construct one bots executor. The three existing routine providers retain their own `botExists:` lookup.
- The CLI and GraphQL render the same typed board and overview. The empty text list prints `[]` and an empty read leaves the database absent. JSON emits the typed list object and the nullable overview and detail placeholders.
- Removal checks active sessions and pending requests before detaching routines and removing the bot. List-state validation uses a targeted projection so the closed-history display limit does not reject valid items.

## Per-edit hashes

Before and after each hunk and the generated SDL are recorded in `tmp/bots-overview/bots-10-bot-surfaces/edit-intentions.md`. The scope check matched each first read to the dispatched native snapshot.

| Path | First read SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaApp/RielaAppWebGraphQL.swift` | `b66b32428c15a263c12e3b6aef5ae4dfb5812f4fe6a53f2f5ccb4f9631a228d3` | `47d544ff156c8392403753010296df1ec52895bfa8e3a15b822b336b0971510a` |
| `Sources/RielaCLI/Bots/BotCommands.swift` | `absent` | `356c3bda9ff92bab79a96f2c145150c026b28e0c1825158190976c0fdeb7a7e5` |
| `Sources/RielaCLI/Bots/BotRoutineSchedule.swift` | `absent` | `dd41509091398a022acebe8c4163fffc023f9a72b5439b50645e48df67ee1674` |
| `Sources/RielaCLI/Bots/BotsGraphQLProvider.swift` | `absent` | `7e241ed2ff37c03615c1f16cb7916dc7ff52fd2e02db2da9bc181022ec1861e5` |
| `Sources/RielaCLI/Bots/BotsService+Projection.swift` | `absent` | `680adf3d781225c3093e31954d226823051a50d469455f2bd71e47af29508bcf` |
| `Sources/RielaCLI/Bots/BotsService.swift` | `absent` | `3e3feb59ea45a8328559471c75f908bd8cf9c72740d8f38fd4c1d6aca9efbfd0` |
| `Sources/RielaCLI/CLISurfaceEnumeration.swift` | `be369fff3781814522e42342808ab0048707db11e597ba1181b8d84d34add1c2` | `f4bf8d29fc7e973b2822be85910d6e631a2905db8f289526229353a99e9a838d` |
| `Sources/RielaCLI/RielaCLIApplication.swift` | `4abf296009460a91f25641b4445820a7d68f0068d5de022c687d52e5e619fb49` | `c9d157ac875cafdb8d0ce888392638fcd841c31adbb6ca9aecb9efdbf385f0b3` |
| `Sources/RielaCLI/RielaClientCommandRouter.swift` | `2e2c66ac1a9ba1e359a156f400bfe5b2f7637090f793da7f6cd32436fac20d07` | `8091abedeb1f9474a07686e2b6b991a1e8f6959e84dccef4102bc562250711e9` |
| `Sources/RielaCLI/RielaClientFamilyArguments.swift` | `15c0dc7116b328a31a9ab909f22190db2ecfa3f6c86366c1c7a6f3649cb47c6b` | `27d5205826231b973a4caeb11316e42546dc31e27eae9c556872a8e1539809ed` |
| `Sources/RielaCLI/RielaCommand.swift` | `f3890e3a50258b179ca66510f5725cd17943333060f47625d47bfcfb84dcb0e0` | `936ac4a2e35d963f7c037991a71c623492d40cae7e66b6e0ef8d71ae111880a4` |
| `Sources/RielaCLI/RielaLibrary.swift` | `2edaba8a8dca4e67e865c17bb0b8cae3cb1b0af365aa9681ea5f5acc006af34f` | `4f67c94e8088bed76236af7272dbc1cd427ff62fd96441e0040b6f1185849938` |
| `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift` | `68e266a6eb82412132163f77ca1206d881e20beb5a37855c5d91e77d8e6433b6` | `ab3fa4801d9625bb8ec6a1e01f9abe2fb7a9d467df1e273ab75f36f2650061af` |
| `Sources/RielaCLI/ScopedParityCommands.swift` | `28d251fab0790d5e37d19a026dcc9c0606c3918d32edb8d7db64612bb0699fe3` | `1b062a618f3416bbb342f2870074c30fdc320f8adbfe846e36c45b505cba3d9d` |
| `Sources/RielaCLI/ServeHTTPCommand.swift` | `d21aec1cb7320b2d7b22e70ff27e0bf6c185f8cdcfc05f4619f298ae380d2ec7` | `9efd358125f92da7ef3c6db146c5eebbb4622830ac7ad76ebebd2c8d0f8c7a32` |
| `Sources/RielaCLI/ServeWebHost.swift` | `ab07b42405d2cbfbf005504689d927c245c2ebe87de7cd076a7ae9cf469d9945` | `d2c0727c70b13955c35e2b2f1945f636f2a0c5e17be08308728c74178430c3d0` |
| `Sources/RielaCore/SurfaceCatalog+RowsBots.swift` | `cb1b7a20d93f65b2a0908d33679219d2ffdf5470969ccb2df2c721b0baabfa98` | `03367e9eb8a460791e4d4a419f0b4998530c9ce8843674808f95c89d6a54ff1e` |
| `Sources/RielaGraphQL/Bots/BotsGraphQL.swift` | `absent` | `04c9b0238ccd0c85a80101662c5118047ff82458dd7d0ae9e1707398217342d7` |
| `Sources/RielaGraphQL/Bots/BotsGraphQLContracts.swift` | `absent` | `d9da73761c5d17b0cfa886a1b0483c817813a71525be2a740b667d22b372789e` |
| `Sources/RielaGraphQL/Bots/BotsSchemaDescriptors.swift` | `absent` | `cedd6a765362e7ef83a4ac52cc7a6726ce8a2b851964af412a02ade18f28efb8` |
| `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | `b0b6a8ab61439ce92b8972bc3c3dccde5b0982045a4628cefc3231ab2637ae24` | `088cda2cd6a508d8b12451e9968e312f14e7acd302a4365546fa0f74a4d062e1` |
| `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` | `8c48784047d4b95dfe2bfb772f7558a03c0d024ed727a5e8ec70408cdeac6867` | `233366aca4df049fb798b3bfa0621980f56074b3cd988652a4541bfab8b8f01b` |
| `Tests/RielaCLITests/Bots/BotCommandTests.swift` | `absent` | `8e69ce1692aab707ed885fc70843624cc8376b443db850e86802b818b002aa7e` |
| `Tests/RielaGraphQLTests/Bots/BotsGraphQLTests.swift` | `absent` | `a0d56446513471bf60abc4869477e05d182d326032ed4d03bc3404aae8eec7c6` |
| `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift` | `3e834c17e3b565db789f80dc20d3c7400e3e75a231aa97e3e3cf29bf61ffd3e3` | `30accde1d813322320cf754db0a28af70beb5b843a74be7ffa7d3bcd7067200f` |

## Verification

Logs are under `tmp/bots-overview/bots-10-bot-surfaces/`.

| Command | Exit | Log | Result |
| --- | ---: | --- | --- |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl.log` | Generator test passed |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl-second.log` | Generator test passed and SDL bytes match `sdl-before-second.swift` by `cmp` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotCommandTests\|BotsGraphQLTests\|SurfaceCatalogTests\|SurfaceParityCLITests\|SurfaceParityGraphQLTests\|SurfaceParityExecutorCoverageTests\|SurfaceParityDTOSchemaTests\|SurfaceParityWebAPITests\|SurfaceParityConsoleReadTests\|SurfaceParityLibraryTests\|SurfaceParitySkillTests\|RoutineCommandTests"'` | 0 | `test.log` | 71 executed, 70 passed, 1 generator-only skip, 0 failures, all nine parity suites passed |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela bot --help'` | 0 | `help.log` | All fourteen verbs listed |
| `grep -c "BotsGraphQLDocumentExecutor(" Sources/RielaCLI/ServeWebHost.swift Sources/RielaCLI/ServeHTTPCommand.swift Sources/RielaCLI/RielaLibrary.swift Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift Sources/RielaApp/RielaAppWebGraphQL.swift` | 0 | `host-wiring.log` | Count 1 in each host |
| `grep -c "botExists:" Sources/RielaCLI/RielaLibrary.swift Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift Sources/RielaApp/RielaAppWebGraphQL.swift` | 0 | `routine-wiring.log` | Count 1 per provider |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/bots-overview/bots-10-bot-surfaces/changed-swift.nul'` | 0 | `swiftlint.log` | Strict lint passed for 25 explicit Swift files with the nonempty manifest guard |
| `shasum -a 256 -c tmp/bots-overview/bots-10-bot-surfaces/test-source-after.sha256` | 0 | `final-source-stability.log` | 1,746 matching files. The test source manifests before and after the test are byte-identical |

## Deviations

- Each GraphQL field has one catalog binding. CLI aliases for `setBotPaused` and `setBotListState` have explicit exclusions identifying their shared mutation, following `routine disable` and preserving the unique-field invariant.
- The Work Runtime task model omits its update timestamp. Projection reads the existing `work_tasks.updated_at` column through the read-only store using task IDs from `WorkStore.listTasks`. The isolated task test verifies the timestamp and owner filtering.
- Earlier attempts are retained in `sdl-attempt1.log`, `sdl-attempt2.log`, and `swiftlint-attempt1.log`. They exposed an integer type mismatch, the missing task timestamp property, and router complexity. The final gates above passed after those corrections.

## Open items

Formal test-integrity review, adversarial review, and serial integration review remain pending. The per-plan implementation criteria passed. Routine reads and detachment use the host-configured routine store. Cross-store coordination with a concurrent routine creation is limited by the existing lookup-before-save routine contract.
