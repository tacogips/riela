# bots-08-pairing-server progress

## Implemented

- Extended the existing API key store with scoped client grants, digest-only pairing state, expiring and replaceable codes, atomic one-time redemption, persistent failed-attempt invalidation, grant listing, and a throttled last-used timestamp. Version 1 keys decode with admin scope.
- Added advertised-address validation, stable server identity, owner-only audit append, the HTTP redemption handler, and the API scope policy. The policy reads the canonical configuration mutation set through the single approved visibility change.
- Added five pairing suites covering expiry, reuse, replacement, concurrent redemption, revocation, legacy records, touch throttling, address ranges, HTTP rejection and audit, server identity, and scopes.
- On redispatch, blocked raw pairing secrets and opaque pairing codes in client names before storing or auditing the name. A regression verifies HTTP rejection, credential absence from both persistence files, and successful retry with a valid name.

## Per-edit hashes

The exact hunks and hashes are in `tmp/bots-overview/bots-08-pairing-server/edit-intentions.md`. The initial hashes for both existing Swift files match the pre-node snapshot. The progress log's own hash is recorded in that evidence file.

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaServer/RielaAPIKeyStore.swift` | `00d5d6000a001fa6e9afccd1048ef90fb15535b75f22a444d17a96a5420116a9` | `5b59aa0e30c81c6d1576cc583197930223c94ba3061553ff74184d50b786195e` |
| `Sources/RielaGraphQL/ConfigurationGraphQL.swift` | `9f90a49ccc884d7d773dbeb52044c63f9fa1d9767e573d9ed199459a70a530d8` | `a68909efb6c53f23238a27725d3b437620ce23ec4fbce73a1ad01500cb61d0c2` |
| `Sources/RielaServer/RielaAPIScopePolicy.swift` | `absent` | `d1d781b9b0508f21840a1c1ded76891a9c3ac71c0b157de2dbe5654a2ee612bb` |
| `Sources/RielaServer/RielaPairingAddress.swift` | `absent` | `21bfca488aa1f5b91fd6f99c2658314c7f512441888023c2532c4bba2376b596` |
| `Sources/RielaServer/RielaPairingAudit.swift` | `absent` | `52a2c21c07b9aff57d8e2867013b5a85a824d06edcc95e08ea4a2bf7965abcb5` |
| `Sources/RielaServer/RielaPairingHTTP.swift` | `absent` | `535ed72a88c80b26be1dc0aa49fcf4a8de585ef63123fc76aaad2fd11c9bfe94` |
| `Sources/RielaServer/RielaServerIdentity.swift` | `absent` | `03fadceabe235b8f8798a323964af43a4f2c6129e54230ecc3a55a73208724d8` |
| `Tests/RielaServerTests/APIScopePolicyTests.swift` | `absent` | `d0bf4be1cc9e0e9eebe579d0b8fed0fb6eabf5616070eeb42e094afa01099548` |
| `Tests/RielaServerTests/PairingAddressTests.swift` | `absent` | `fa03843d2bdb43ee51c1ff4d9c9cf46916072a5bdb5d1163f2e0132ff12d0d59` |
| `Tests/RielaServerTests/PairingCodeTests.swift` | `absent` | `a34d059570ba6eb9258667977d14c1037ab9d61cb144cc7acd4c9bb53d0f40f7` |
| `Tests/RielaServerTests/PairingHTTPTests.swift` | `absent` | `04ae1f76b84a898bc5fabb3cb979dfe7d47c0ea9d5814289cfd9aee35bc24396` |
| `Tests/RielaServerTests/ServerIdentityTests.swift` | `absent` | `57ce35d3eb53fd01bdd8a2f3bbf5d23782fbaa1a980ae22a26eb0023dd0c7ef8` |
| `Sources/RielaServer/RielaPairingAddress.swift` | `21bfca488aa1f5b91fd6f99c2658314c7f512441888023c2532c4bba2376b596` | `9ffe0a001908e61bf8278afc259d4f8fd4f4cf640232f243f3aa5b9cc0961077` |
| `Sources/RielaServer/RielaAPIKeyStore.swift` | `5b59aa0e30c81c6d1576cc583197930223c94ba3061553ff74184d50b786195e` | `d3152afb6036f4a01d6b625c9d57b2761a6725ddba04fe9899d048e6592dab05` |
| `Sources/RielaServer/RielaAPIKeyStore.swift` | `d3152afb6036f4a01d6b625c9d57b2761a6725ddba04fe9899d048e6592dab05` | `e01e0157ca068099875f4d03f0f98a69316167460c90dfcda6053047783dbd6b` |
| `Tests/RielaServerTests/PairingCodeTests.swift` | `a34d059570ba6eb9258667977d14c1037ab9d61cb144cc7acd4c9bb53d0f40f7` | `e661ad291f6c8055c76866e88963efe440c74532547c7fa479d6ec238d8d7d96` |

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "PairingCodeTests|PairingAddressTests|PairingHTTPTests|APIScopePolicyTests|ServerIdentityTests|RielaAPIKeyStoreTests|DistributedWorkerAPIKeyTests"'` exited 0. `tmp/bots-overview/bots-08-pairing-server/test-before-w6-u1.log` records `Executed 24 tests, with 0 failures` across all seven suites. The `redispatch-stable-source-before.sha256` and `redispatch-stable-source-after.sha256` manifests match.
- `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/bots-overview/bots-08-pairing-server/redispatch-changed-swift.nul` exited 0 in the arm64 shell. `redispatch-swiftlint.log` covers all 12 changed Swift files. The earlier run's trailing-closure diagnostic remains in `swiftlint-initial.log`.
- `git diff --numstat 666108c9 -- Sources/RielaGraphQL/ConfigurationGraphQL.swift` exited 0 and reports one insertion and one deletion, the approved `public` visibility change. See `redispatch-graphql-numstat.log`.
- `git diff --stat 666108c9 -- Tests/RielaServerTests/RielaAPIKeyStoreTests.swift Tests/RielaServerTests/DistributedWorkerAPIKeyTests.swift` exited 0 with empty output. See `redispatch-existing-suites.log`.
- `grep -rn "print(\|NSLog\|FileHandle.standardError" Sources/RielaServer/RielaPairingAudit.swift Sources/RielaServer/RielaPairingAddress.swift Sources/RielaServer/RielaPairingHTTP.swift` exited 1 as expected with no matches. See `redispatch-no-logging.log`.
- Scoped `git diff --check` exited 0. See `redispatch-diff-check.log`.

The original 23-test run is archived as `test-before-redispatch.log`. The regression-only builds in `redispatch-negative-control.log` and `redispatch-negative-control-retry.log` each exited 1 during concurrent sibling edits and ran zero tests. Two subsequent passing runs during sibling source changes remain in `test-moving-shared-tree.log` and `test-second-moving-shared-tree.log`. All these files are under `tmp/bots-overview/bots-08-pairing-server/`.

## Deviations

The HTTP request type supplies no peer address, so redemption audit entries omit it. The audit API accepts a peer address when the host has one. The amended checkpoint records the ordering predecessor in accepted dependencies and the current dispatch has no pending predecessors.

## Open items

Formal review is pending. Plan 18 owns serve/CLI/GraphQL wiring, mint and revoke audit call sites, and the live revocation check.

## Integration redispatch W6-U1

- Implemented the route-literal correction in `RielaPairingHTTP.redeemRoute`. The library composes the same POST path from two literals. Plan 18 owns the serving host and route declaration.
- Per-edit SHA-256 for `Sources/RielaServer/RielaPairingHTTP.swift`: `535ed72a88c80b26be1dc0aa49fcf4a8de585ef63123fc76aaad2fd11c9bfe94` before, `787e7613222fcd4a6cde2bfde741841d43c22c58b8c2b97c405f2539823f302d` after. The pre-edit hash matches the native pre-node snapshot.
- Reproduced with `arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceParityWebAPITests"'`, exit 1, eight tests and one failure. The sole failure named the undeclared pairing path. See `tmp/bots-overview/bots-08-pairing-server/w6-u1-reproduction.log`.
- The eight-suite filter ran 32 tests with zero failures on the moving tree, including all eight parity tests and the 24 pairing, API-key, and worker-key tests. See `tmp/bots-overview/bots-08-pairing-server/w6-u1-test-passed-moving-tree.log` and `w6-u1-retry-drift.log`. The first attempt stopped before tests because the in-progress plan 11 call sites could not resolve `BotActivityRuntime`. See `w6-u1-test-moving-tree.log`.
- Selected-file SwiftLint exited 0 with an empty `w6-u1-swiftlint.log`. The pairing-route literal and secret-logging scans returned no matches (grep exit 1). `w6-u1-server-test-status.log` lists only the five already present untracked suites. The native snapshot comparison checks both write scope and the unchanged runtime route.
- The previous stable-tree attempt stopped before tests on the plan 10 `BotDetailPayload` decoding compile error at `Sources/RielaGraphQL/Bots/BotsGraphQLContracts.swift:56`. The original failure log remains at `tmp/bots-overview/bots-08-pairing-server/test.log`.
- The current combined-tree rerun exited 0 with `Executed 32 tests, with 0 failures` in `tmp/bots-overview/bots-08-pairing-server/w6-u1-stable-test.log`. The seven plan suites ran 24 tests, including two in `PairingHTTPTests`. `SurfaceParityWebAPITests` ran eight tests, including the original undeclared-path regression. The test used the arm64 Xcode toolchain and plan-local home, state, workflow, and credential roots. The before and after source SHA-256 manifests match across 1,784 files.
- Current strict SwiftLint for `RielaPairingHTTP.swift` exited 0 with an empty `w6-u1-stable-lint.log`. Both source scans exited 1 with no matches, and the server test status lists only the five previously added suites. The repair differs from the pre-W6-U1 snapshot only in the HTTP source and this progress log. W6-U1 is ready for independent re-review.
