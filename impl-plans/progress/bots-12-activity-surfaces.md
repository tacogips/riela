# bots-12-activity-surfaces

## Implemented

The dispatch accepted both dependencies, `bots-10-bot-surfaces` and
`bots-11-activity-runtime`, at checkpoint
`31f978b26cae649803d0788391278fdcf49f2424`. The implementation follows design
sections 6.5, 6.6 and 12 and the committed activity-surfaces plan.

- `riela bot activity` replays a page by bot or session, resumes from a cursor,
  and follows using the same service. Text includes a recovery summary after
  retention trims the cursor. JSONL streams individual events. Bot selection
  prioritizes Needs you, In progress, then Closed.
- `riela bot answer` and `Mutation.answerBotRequest` preserve provider option
  IDs and support decline. The store resolves a request once. Work questions
  get the `riela task answer` hint.
- `Query.botActivity` exposes the events, state, origin and session status.
  The service caps waits at 25 seconds and 32 concurrent waiters. Authorization
  is rechecked during a wait. Cancellation releases the waiter slot.
- The SurfaceCatalog, help, schema descriptors and generated SDL carry both
  operations. The schema scan found the query at line 913 and the mutation at
  line 964 of `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`.

## Per-edit hashes

The table compares the native pre-node snapshot with the verified source.
Individual edit intentions and intermediate hashes are in
`tmp/bots-overview/bots-12-activity-surfaces/edit-intentions.md` and
`tmp/bots-overview/bots-12-activity-surfaces/service-edit-intentions.md`.

| Path | Pre-node SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCLI/Bots/BotActivityCommands.swift` | `absent` | `f83f9619d7864b87bca74ff8b8b3dfbe5f22f58b647487ca5bc2d1e10c3d1286` |
| `Sources/RielaCLI/Bots/BotActivityWaiters.swift` | `absent` | `806a9f521994685e8249adab1efa2d9b6a3cb2af134711cc4cd5c02b2bbf6e74` |
| `Sources/RielaCLI/Bots/BotCommands.swift` | `356c3bda9ff92bab79a96f2c145150c026b28e0c1825158190976c0fdeb7a7e5` | `0404d0d21dbd8393649b48314ca9002cbf289ad99324b66abbed19d89a7ea88b` |
| `Sources/RielaCLI/Bots/BotsGraphQLProvider.swift` | `7e241ed2ff37c03615c1f16cb7916dc7ff52fd2e02db2da9bc181022ec1861e5` | `a04612bcd9246cc9617ae6918dbcce278794d55de1bb37c139c3238dbe6a8f65` |
| `Sources/RielaCLI/Bots/BotsService+Activity.swift` | `absent` | `b2fdcdcb7309d51c3ead2903573090999250cd5ee0ac6eb2a8d6125bf7225c23` |
| `Sources/RielaCLI/Bots/BotsService.swift` | `3e3feb59ea45a8328559471c75f908bd8cf9c72740d8f38fd4c1d6aca9efbfd0` | `788a974193b5e691923aefc39c03d4bdd3b4722c329c6beaf979673cc2c829a0` |
| `Sources/RielaCLI/RielaCLIApplication.swift` | `c9d157ac875cafdb8d0ce888392638fcd841c31adbb6ca9aecb9efdbf385f0b3` | `c90aabbdd4046afe262773f5d1843fa794640012c220b953d4527d93c21d3d83` |
| `Sources/RielaCLI/RielaClientFamilyArguments.swift` | `27d5205826231b973a4caeb11316e42546dc31e27eae9c556872a8e1539809ed` | `165bdac806520cdcfeecf5e5b45a906c290d8889957ddf9c80c6713c17a0e42f` |
| `Sources/RielaCore/SurfaceCatalog+RowsBots.swift` | `03367e9eb8a460791e4d4a419f0b4998530c9ce8843674808f95c89d6a54ff1e` | `5b4b5dd4843e1a9b851222f5d61562f7c657b0f924771b279f2b36f1c2f9ad49` |
| `Sources/RielaGraphQL/Bots/BotActivityGraphQLContracts.swift` | `absent` | `51f3536037a8b02d93173603e3d6db814820d712fa888598d93aa3ed12ffc2cc` |
| `Sources/RielaGraphQL/Bots/BotActivitySchemaDescriptors.swift` | `absent` | `7be077cdf62a666fa535209a6e2b8ad17377fbcef05c087783d988a55e38d726` |
| `Sources/RielaGraphQL/Bots/BotsGraphQL.swift` | `04c9b0238ccd0c85a80101662c5118047ff82458dd7d0ae9e1707398217342d7` | `7993682dc6799fefce728542f54da7e68bb10dde0bced3a7f2862492b706824e` |
| `Sources/RielaGraphQL/Bots/BotsSchemaDescriptors.swift` | `cedd6a765362e7ef83a4ac52cc7a6726ce8a2b851964af412a02ade18f28efb8` | `da14a5fa552f7e636b36c6c25b516fc814405f4862fbb35694f9f23638737139` |
| `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | `088cda2cd6a508d8b12451e9968e312f14e7acd302a4365546fa0f74a4d062e1` | `eb4e8bdd86f49ca6f3aefab2322ecd38186581e26a9a995219abf9668b49b162` |
| `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` | `233366aca4df049fb798b3bfa0621980f56074b3cd988652a4541bfab8b8f01b` | `5bfd51467fdbab46c6e235c704cc81ec11970050dc58ad789c225bec3172680a` |
| `Tests/RielaCLITests/Bots/BotActivityCommandTests.swift` | `absent` | `ace883f14cb5ea0ee3814227a45f75d55fab841fe0f7282fd49bab251783bc0b` |
| `Tests/RielaCLITests/Bots/BotActivityServiceTests.swift` | `absent` | `48bde6d48526f13cc6390e5e10cf54282d4f5dbf98ee8cb72109c6d4298c41e9` |
| `Tests/RielaGraphQLTests/Bots/BotActivityGraphQLTests.swift` | `absent` | `5ae13b0b2a417d37d1c57ee0ff15a8ad58175d9e648e545eba36c6a36846576e` |
| `Tests/RielaGraphQLTests/Bots/BotsGraphQLTests.swift` | `a0d56446513471bf60abc4869477e05d182d326032ed4d03bc3404aae8eec7c6` | `3fb7647c939968bbea96838862ca3cbb18254b6a9cec79969cda623e6a5e6835` |

## Verification

Commands ran on the shared branch in the foreground. Logs are under
`tmp/bots-overview/bots-12-activity-surfaces/`.

| Command | Exit | Evidence |
| --- | --- | --- |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl.log` records one generator test and zero failures. `sdl-initial.log` records the first generation. |
| `cmp tmp/bots-overview/bots-12-activity-surfaces/sdl-before-second.swift Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | 0 | `sdl-identical.log` confirms repeat generation was byte-identical. |
| `grep -n "botActivity\|answerBotRequest" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | 0 | `schema-fields.log` contains both fields. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotActivityCommandTests\|BotActivityGraphQLTests\|BotCommandTests\|BotsGraphQLTests\|SurfaceCatalogTests\|SurfaceParityCLITests\|SurfaceParityGraphQLTests\|SurfaceParityExecutorCoverageTests\|SurfaceParityDTOSchemaTests\|SurfaceParitySkillTests"'` | 0 | `test.log` records 58 selected, 57 passed, one expected generator-only skip and zero failures. All 15 new tests passed. `test.exit` records exit 0. |
| `arch -arm64 /bin/zsh -lc 'manifest=tmp/bots-overview/bots-12-activity-surfaces/changed-swift.nul; if [ -s "$manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | `swiftlint.log` is empty for the 19-file manifest. |
| `cmp tmp/bots-overview/bots-12-activity-surfaces/test-source-before.sha256 tmp/bots-overview/bots-12-activity-surfaces/test-source-after.sha256` | 0 | `test-source-stability.log` confirms all 1,792 entries matched across the run. |
| `git diff --check` | 0 | `diff-check.log` is empty. |
| `python3 tmp/bots-overview/bots-12-activity-surfaces/snapshot-scope.py --progress` | 0 | `scope.log` records the 19 Swift files and this progress log, with no deletion. |

The earlier test run also passed. The initial lint run flagged dispatch
complexity in `RielaCLIApplication.swift`. Its diagnostics are retained in
`swiftlint-before-dispatch-extraction.log`. The final rerun covers the
extracted dispatch.

## Deviations

- The active plan's path note described help-only changes in
  `RielaCLIApplication.swift`. The implementation also replaced the existing
  scoped dispatch call in that authorized file to route the two new commands
  through the async path and reuse the executable's existing follow writer.
- The surface returns the last delivered sequence when a limit stops replay
  early. The runtime journal keeps its actual head. This preserves ordered,
  gap-free cursor paging. With `--follow --output json`, each emitted page is
  one JSON object.

## Open items

Step 7 owns independent review. Serial reconciliation owns the C4 wave gate
under `impl-plans/active/bots-overview.md` section 4.
