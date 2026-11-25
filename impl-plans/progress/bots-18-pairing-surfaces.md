# bots-18-pairing-surfaces progress

## Implemented

- Implemented in full issue-resolution mode on `feat/bots-overview`, checkpoint `fcd006da53cf39864b7ea9ef948a7e30a8222715`. The dispatch accepted predecessor `bots-17-example-docs`. The implementation follows design §11.1–11.2 and the committed operator amendment. Scope comes from `fable-sol-design-and-implement-review-loop-session-1`, design acceptance `comm-000004`, and plan acceptance `comm-000008`.
- `riela serve` validates the advertised address before binding, then can mint a ten-minute pairing code and print it once on stdout. Local pairing commands and server GraphQL mint, list, and revoke through the same API-key store and append audit records.
- `ServeWebHost.routedResponse` handles redemption before passkey and browser checks. `RielaWebAPIRouteTable` and `SurfaceCatalog` declare the route. This resolves `W6-U1-undeclared-redeem-literal` (`fable-sol-design-and-implement-review-loop-session-1-integration-review-attempt-1-finding-1`). Both web parity assertions pass with the full route literal present.
- Native GraphQL preflight checks all document roots against the credential scope before provider dispatch. The activity wait reauthenticates each poll. Both browser and native GraphQL expose the persisted server identity in bot origins.
- `PairingServeTests`, `PairingScopeEnforcementTests`, and `PairingGraphQLTests` cover isolated CLI and HTTP routing, replay rejection, revocation, scope preflight, GraphQL projection, and identity. Startup validation fixtures use an isolated home and a missing web root to make an erroneous bind bounded.

## Per-edit hashes

Intermediate revisions and exact edit intentions are in `tmp/bots-overview/bots-18-pairing-surfaces/edit-intentions.md`. The entries below show initial and final SHA-256 values.

- `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` — `a39c5061424ede3ccd1535709c5885dddf3b4d05d464b49f5a6fbaf83dc838b6` → `fe7b810bf5651b1960a080bb7e5d8c0427bb8e87b3db1d3442159c8b5a55e0ce`.
- `Sources/RielaCLI/APIKeyGraphQLAuthorization.swift` — `d620191213b9cd75c5cf75906319fea3895ad1de510d05255670fc22e9b230ca` → `d263f5b328dc65455f33cb2702fe8abb751cb1c5b5ceafad312c453bb9b56cde`.
- `Sources/RielaCLI/Bots/BotCommands.swift` — `34101e285f29f48a8a07274e0fdb5153d2a52cb8334883cdeb537bdf07e80e8a` → `7ae861f581ae7a4bf67548e455a162e65d29eaf458ae36907bdc85f5ae701193`.
- `Sources/RielaCLI/Bots/BotsGraphQLProvider.swift` — `fb55244e2c2346aed68c31c6ec874c3fba083703144c42ecef1b24ba7fbfbab2` → `e415d288ba510bf25b1f8bf94a39e1cdf55ec6ba23856b4fc85e7270c39b845f`.
- `Sources/RielaCLI/Bots/BotsService+Activity.swift` — `b2fdcdcb7309d51c3ead2903573090999250cd5ee0ac6eb2a8d6125bf7225c23` → `68a5ff2e67aad4a2f1373fbc4c628c9f01b26c33ccfe7fe7fbe2f7d5ca986633`.
- `Sources/RielaCLI/Bots/BotsService.swift` — `7ff140633f001faa9e84403347c30b565c3107bac848d8dfae5c7adb0614444b` → `6439684ef0087410ffde1ae79bac38b3a2962d347701fcb78968e3e110526c5a`.
- `Sources/RielaCLI/CLISubcommandHelp.swift` — `ecb0ab8ab565a8e2d2f0960721945a537687fc0e25df2d1d4908fbb95a3210dd` → `40ad24f6342237668d3dabf951f0765af44fe199819eee5549bca38f6178d93b`.
- `Sources/RielaCLI/CLISurfaceEnumeration.swift` — `68f87da13804a941552c6f6c3baa0094af38c0cd7186af4a2c8c289c4860b003` → `2aff2c6097101bbe6ef1c1e4b10a268ccf5620413e89df59ba1aa4df0b8878c6`.
- `Sources/RielaCLI/Pairing/BotsRequestGrant.swift` — `absent` → `1431ec16f681e3bbe5056905973e994cf66ccca2dd116e43cd95e97ef1b8064e`.
- `Sources/RielaCLI/Pairing/PairingCommands.swift` — `absent` → `9010f1105b804ca63776cf85db1ab3164f88ab9abe9bc1a098538a85eba4074b`.
- `Sources/RielaCLI/Pairing/PairingService.swift` — `absent` → `08591cd7ea3183926bea5a3b91375839f17325a336bdeacf6fd96fee231b3777`.
- `Sources/RielaCLI/ParityCommandSupport.swift` — `294f30e18dc4dadbc98c231cc37d3dc74d1f382a8638f1257731c1c83f910c56` → `f7f46a8930381aed98b01f0eff9e2edbe67334083f187bbdb11720a9ee1a34aa`.
- `Sources/RielaCLI/RielaCLIApplication.swift` — `c3ca0a3232c1388e796bfe9ed0321bb2031f0060bf836584b79808e3f82ddcc3` → `88cc24488bb2bd23c7ec69fbfeeb1586d1723bf5529c3103c373b95b47897f0d`.
- `Sources/RielaCLI/ScopedParityCommands.swift` — `978779e9f3035c507b8661ed162c10a429c41f02561cfd4e495a1a130766d98b` → `215ae26faa1f09ceaec463696171a730a88141b0df6b9f0ee1012575afa8472d`.
- `Sources/RielaCLI/ServeHTTPCommand.swift` — `901ba859229dd38e81bb216a57bd960ec84459ee923e9af244afaa0df6d6710d` → `84c7be0dffc510010b602ba28e693781558ec51b7d7a49230f0ffc3435fc5cc8`.
- `Sources/RielaCLI/ServeWebHost.swift` — `d2c0727c70b13955c35e2b2f1945f636f2a0c5e17be08308728c74178430c3d0` → `2ccc122de8690a137901add1f86988a9a9ead3e8cb628471d486d6cfd31544ff`.
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` — `30968b716769c678441d6f41f62f8d72b03fbb10cafbb9cf99c36a2766f47c7a` → `124a00d1ac43f0bbfd0bcd8b632d656749532e8c240ea5ec6361de284efbea06`.
- `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift` — `0e0dc54a8fda1af7b4d52da817821a75ce49c8b23d2048607268fba1109604bb` → `09a32c0ea88e85b6297aeee6170804df50320135a2dde11aa337b687cb33af7c`.
- `Sources/RielaGraphQL/Bots/BotActivityGraphQLContracts.swift` — `51f3536037a8b02d93173603e3d6db814820d712fa888598d93aa3ed12ffc2cc` → `cd3d2d8719057133d3c729df227f845aeff9bf15cef21674924da24ae858b423`.
- `Sources/RielaGraphQL/Bots/BotActivitySchemaDescriptors.swift` — `7be077cdf62a666fa535209a6e2b8ad17377fbcef05c087783d988a55e38d726` → `5f7d5fafe26bb50952f6cca68b97fea24d82b09c89a4affa5c159d0aa86d0f4d`.
- `Sources/RielaGraphQL/Bots/BotsGraphQL.swift` — `0f389241cd690038df1198854b7c770d1c61c25fe5879b50487491021370ae50` → `859e8daeb1f2951dac6bb2fb56ea68e31bd5c3f4dc9c46365c030a40c2183c1d`.
- `Sources/RielaGraphQL/Bots/BotsGraphQLContracts.swift` — `8ef037dbd209449e578ccdd3f3d1a12a680ac1e156af194bc090f586bd3fcffa` → `1bb4f078b8380b77d1b5d9097814723ef068a127ee10a48d3d3d3a2325712888`.
- `Sources/RielaGraphQL/Bots/BotsSchemaDescriptors.swift` — `d8bddbbc59ba5bcee4e43a69dbe4d39057b5bf3190fb0cb9ceb754d56f4e85b6` → `d183e8d961c0f46cc6d3955c742b6f48a0e842a758ec0df0fecdb36cad004f87`.
- `Sources/RielaGraphQL/Bots/PairingGraphQL.swift` — `absent` → `4531d0372c582edca7557f17000551993755cf7cd6a7ba2fd22a4e6767350cc2`.
- `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` — `de7660fcc976f3e14d6d725a82d81dd3ad506aafd4a8f20c8908c22c750b32f8` → `e860fa9864f95f5a036acbe081ac13986b96b46f2cd7b51baeb64e490ef2d3f5`.
- `Sources/RielaGraphQL/GraphQLDocumentExecuting.swift` — `1621fe467fbbb6963526da18f277f59e8d074d11f21b425a0b57fcd1cc168d3d` → `a7374ba2b489469aebea7507ce623f561aa8f125c1d33f898bb7a8d7d9fc2f82`.
- `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` — `65e7e20aaaba30e008b6922323660dde763c0e25f37b8466e5012d1383c52df3` → `0230d2ea8e626ca50c6ebc876e7fd2caea2bd988f6118b822fcdf1cb0e84d58a`.
- `Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift` — `fc1e99c8aa769b9e397ff52780457b474fc33eb61f3160fa341d131d05c31af7` → `5962e6127873b690a1c53e8146c62c7094f10549e83bd6003a2d8d48f044571f`.
- `Sources/RielaServer/RielaAPIScopePolicy.swift` — `d1d781b9b0508f21840a1c1ded76891a9c3ac71c0b157de2dbe5654a2ee612bb` → `602fa5ae92be4ce79b5b491224deafdf36d9af897cb8f3d9ae46fc996263247b`.
- `Sources/RielaServer/RielaPairingHTTP.swift` — `787e7613222fcd4a6cde2bfde741841d43c22c58b8c2b97c405f2539823f302d` → `535ed72a88c80b26be1dc0aa49fcf4a8de585ef63123fc76aaad2fd11c9bfe94`.
- `Tests/RielaCLITests/Pairing/PairingScopeEnforcementTests.swift` — `absent` → `c3c883c2af35af12914a0ee69733adb1a6a7d07b09d3b56dbb96424719e2ae95`.
- `Tests/RielaCLITests/Pairing/PairingServeFixture.swift` — `absent` → `c842faff5b5691ac6b04bfc72bc6fac1e3712763b929765a8c7caa59124fd894`.
- `Tests/RielaCLITests/Pairing/PairingServeTests.swift` — `absent` → `55a5191c1cf0c7949c6c6a222249cc1a23f8889cac4ed4058d3219807d72961d`.
- `Tests/RielaGraphQLTests/Bots/BotsGraphQLTests.swift` — `dd9141c4e1a9f2dca3212cd4ef4381c8617805e6aa5fd05357c1dd1be0e31cb7` → `21f3eb849604d20fd5c47c3730d706fedd3efe81245ab255d42227ee84d8778e`.
- `Tests/RielaGraphQLTests/Bots/PairingGraphQLTests.swift` — `absent` → `2d83e4f2ed2a5395357479bc12c4792c19fd0418938c3eac341d1a274b612d97`.

## Verification

All logs are under `tmp/bots-overview/bots-18-pairing-surfaces/`.

```sh
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-18-pairing-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "PairingServeTests|PairingScopeEnforcementTests|PairingGraphQLTests|PairingCodeTests|BotActivityGraphQLTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-18-pairing-surfaces/test.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "APIKeyGraphQLAuthorizationTests|APIScopePolicyTests|PairingHTTPTests|BotsGraphQLTests|BotActivityServiceTests|RielaAppWebAPIRouteTests"' > tmp/bots-overview/bots-18-pairing-surfaces/regressions.log 2>&1
grep -rn "rp1\." tmp/bots-overview/bots-18-pairing-surfaces/test.log
grep -n "/api/v1/pairing/redeem" Sources/RielaCLI/ServeWebHost.swift Sources/RielaAppSupport/RielaWebAPIRouteTable.swift
rg -n 'private func routedResponse|/api/v1/pairing/redeem|browserAccess.rejection' Sources/RielaCLI/ServeWebHost.swift
arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-18-pairing-surfaces/changed-swift.nul
if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'
git diff --check
python3 -B tmp/bots-overview/bots-18-pairing-surfaces/check-scope.py
```

- `sdl.log` exited 0. The regeneration test executed once with zero failures.
- `test.log` exited 0. XCTest reported 64 tests, one skipped and zero failures. The skipped regeneration-only test ran through the SDL command. All eight `SurfaceParityWebAPITests` passed. Held-wait revocation passed in 0.575 seconds.
- `regressions.log` exited 0. XCTest reported 29 tests and zero failures.
- `secret-scan.log` is empty, with expected grep status 1. `route.log` shows both declared literals and the redeem branch before the browser gate. The route checks exited 0.
- `swiftlint.log` and `diff-check.log` exited 0. `scope.log` checks the dispatched paths, runtime snapshot hashes, checkpoint, and empty index.
- `sdl-attempt1.log` is a superseded test build failure due to overlapping names in test JSON extensions. `test-attempt1.log` is a superseded failure of the catalog invariant, corrected by using the `serve.pairing` subfamily. The final gates passed.

## Deviations

- The pairing administration catalog rows use the `serve.pairing` subfamily to preserve their specified IDs and the existing generic serve skill block. The CLI uses `--pairing-scope` as specified in the committed plan.

## Open items

- Independent test-integrity, adversarial, and integration decisions are pending. This step completed the assigned implementation and verification.
