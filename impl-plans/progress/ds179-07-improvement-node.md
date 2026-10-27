# DS179-07 implementation progress

- Workflow mode: issue-resolution; issue: tacogips/riela#179; plan: `impl-plans/active/ds179-07-improvement-node.md`.
- Accepted plan contract: `impl-plans/active/ds179-dispatch.json` assigns this plan `dependsOn: []`; dependency readiness is satisfied. Review feedback has no findings or repair requests.
- Design alignment: `design-docs/specs/design-workflow-definition-store.md` §§1, 9 and 12 match the plan's three-node shape, service-store pinning, one-time skip, CLI-only audited apply and bounded previous-run digest.
- Initial worktree was clean. Runtime pre-node snapshot: `tmp/riela-fanout/F8ED5245-1F00-4C54-B97F-7FFACA13F666/F1AE8D4C-DECC-4375-B245-0C6A7231353F.json`.
- Initial hashes: `RielaAddons.swift` 8ade25225e3875a6da6d3b3e084baa7c2e3f1c6fc7e980b359c0cb33fa99e383; `BuiltinStatefulAddonRegistry.swift` 91aedb3d5708771a3b664f202972622c3f8b25d87745195fb38a4f3b0ba98d70; `ProductionNodeAdapter.swift` 3d296e60ded476c6d373f081d8a9a797ed36eb7cc6732f5aae1b3fe9a5766c2b; `WorkflowRunCommand.swift` 0f8a2b6447230246863933b233296f466cb08593eaebd238f16a7b7249e3f138; `SessionCommands.swift` 5a6e4893a528efbda5690a09e9e4cee9941a80085a726618a91a323d1ba9652e; `RielaExampleCatalog.swift` 9bcc6adb689e7b32242ebc43748c0ed80affbbb1c00808911970caf53de212ca; `RielaExampleParityTests.swift` eee51b22f79aee8775697e7a0826854893e96c59301e174398586331408f8f52.

## Implementation complete; pending independent review

- Registered version-1 context/apply builtin descriptors and handlers. Service executions pass their persisted definition source and store root into the resolver; resume and rerun keep the same context. One-time executions return `oneTimeRun` before store/session/CLI access.
- Context loads the pinned authored view, picks the newest terminal store-pinned prior session excluding the active session, summarizes bounded deterministic per-step input/output/failure/retry details, and orders evidence with the session first. Apply validates reason, patch, evidence, and recursion guard before invoking only `riela workflow definition update`; it uses the run pin and resolves conflict idempotency from audit history.
- Added and cataloged `definition-store-self-improvement`; mock scenario exercises run 2 audited prompt adoption and run 3 consumption. `expectedMockScenarioCount` is 48.
- Resolver move check: `addonResolver` is initialized in `WorkflowRunCommand.swift` after `storeRoot`; its only use is the runner constructor following the new initialization, so nothing in the moved span reads it.
- Direct-write check: `ProductionNodeAdapter+WorkflowImprovementAddon.swift` contains no `.commit(`, `.update(workflowName`, or `.updatePrompt(` calls.

### File change hashes

For tracked files, pre-edit hashes match the clean initial worktree (`HEAD`); new files and example assets were absent. Post-edit hashes are the final implementation before review.

| File | Pre-edit SHA-256 | Post-edit SHA-256 | Change |
| --- | --- | --- | --- |
| `Sources/RielaAddons/RielaAddons.swift` | `8ade25225e3875a6da6d3b3e084baa7c2e3f1c6fc7e980b359c0cb33fa99e383` | `9fe8d5b3f355020fbe619da8c7ef84d8b25ab90956aee50925e732c42f2edeae` | v1 descriptors and aggregate registration |
| `Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift` | `91aedb3d5708771a3b664f202972622c3f8b25d87745195fb38a4f3b0ba98d70` | `b16f66221dc6e85cf4f87a23eea0a6373e755064c48aa253aa56b4d11de5d590` | handler registration |
| `Sources/RielaCLI/ProductionNodeAdapter.swift` | `3d296e60ded476c6d373f081d8a9a797ed36eb7cc6732f5aae1b3fe9a5766c2b` | `1ee07f2db9ee90e59adbd1ab95ba677b5df6383538f1167e7300b743f3401078` | run context forwarding and dispatch extraction for strict lint |
| `Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift` | absent | `9ab405c4e58780d997469002a0cc15ddd4ce1e92c2ae2b772d612621ab413336` | context/apply behaviors |
| `Sources/RielaCLI/WorkflowImprovementDigest.swift` | absent | `af7d221c6c10aab642c34581fa74772d96c2b01d27175a95b6f1688dc31e1c33` | deterministic bounded digest and authored-reference recursion guard |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | `0f8a2b6447230246863933b233296f466cb08593eaebd238f16a7b7249e3f138` | `db52a96aa8381cf0e686bbaa1f692f436d2e336af751d4dc6cdaf65cfc5f101c` | workflow run context and CLI process test seam |
| `Sources/RielaCLI/SessionCommands.swift` | `5a6e4893a528efbda5690a09e9e4cee9941a80085a726618a91a323d1ba9652e` | `5f5e6a1361f80bea08216823adbd9b39b6ed5b36716a12e52bd97e2f7c96a9e4` | resume/rerun context forwarding |
| `Tests/RielaCLITests/WorkflowImprovementNodeTests.swift` | absent | `3a45fec9b925cdf7f63e9feb8258d1e41cfe5816db176a4eeab687582842b3d8` | nine behavioral/pure tests, including both recursion-guard reviews |
| `Tests/RielaCLITests/RielaExampleCatalog.swift` | `9bcc6adb689e7b32242ebc43748c0ed80affbbb1c00808911970caf53de212ca` | `48e878f6b2ca8eeee2ed100a2f9ef11dcef1c8963576de1802aea06bbcda109a` | sorted example registration |
| `Tests/RielaCLITests/RielaExampleParityTests.swift` | `eee51b22f79aee8775697e7a0826854893e96c59301e174398586331408f8f52` | `254f075baeada02d7be8ccc6b0e743182ef63deffb716bf01c6a808fdcafe916` | mock scenario count 48 |
| `examples/README.md` | `24f394054e193d2550e334dd11562df93f7619ad8be37cd03181f132cf79d9d6` | `1d6f853fa9f2c12dabcc75f2fbe68e2f45960b209401ea8dd782c098b2da296c` | example catalog documentation |
| `examples/definition-store-self-improvement/EXPECTED_RESULTS.md` | absent | `00ca78fa694e2e3da90068f3306e6004d12e214ab2168db6ba89b281964645e1` | expected behavior |
| `examples/definition-store-self-improvement/mock-scenario.json` | absent | `4c68f632367fafbba248825b1dc0fd0c0268b2770e205b45475577392aafe49a` | proposal and target mock responses |
| `examples/definition-store-self-improvement/nodes/node-improve-propose.json` | absent | `a5ff98af7ee294061eacba8763437e5958cd6610aef90e8bbbe0e75c3d02234b` | proposer node |
| `examples/definition-store-self-improvement/nodes/node-summarize.json` | absent | `babfb5fc9558be91ba21ac474cc886c57084b4988e676065c265d611d6756dbc` | target node |
| `examples/definition-store-self-improvement/nodes/node-workflow-output.json` | absent | `262656f77a0ddb160f788d5f3304a7e49a6683dadbd892585b1b26dc087756bc` | output node |
| `examples/definition-store-self-improvement/prompts/improve-propose.md` | absent | `bb669fe4ff126c401bb022f92273970375c5a9c06d0268579164cee998d1de55` | proposer prompt |
| `examples/definition-store-self-improvement/prompts/summarize.md` | absent | `0877aef39130a8d2d2552729ea38b976e1328dc45596cd72ae0e1832514ae4c2` | initial target prompt |
| `examples/definition-store-self-improvement/workflow.json` | absent | `e65afbb795bd85c8ccee44f9d8cc022fc8b5981f015e0554c96a738ee36e820c` | three-node workflow |
| `impl-plans/active/ds179-07-improvement-node.md` | `164e477e5990bd5d74ffcfeb91b831871224060ef8652710dea7dbc11b8a5fa7` | `2a866bbed7456106251500eb34a906832e70c0b6000a1f82c3a7faa65e820a52` | status and completion criteria |

### Final-source verification

All commands ran in the foreground from the repository root in an arm64 shell. Test counts come from each runner's `Executed N tests, with M failures` output.

| Command | Exit | Tests | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-07-improvement-node/attempt-14/final-build.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -20 tmp/ds179/ds179-07-improvement-node/attempt-14/final-build.log; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-14/final-build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests > tmp/ds179/ds179-07-improvement-node/attempt-14/final-improvement-tests.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-14/final-improvement-tests.log; exit $result'` | 0 | 7 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-14/final-improvement-tests.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'RielaExampleParityTests|BuiltinStatefulAddonRegistryTests|KeyValueStoreAddonTests' > tmp/ds179/ds179-07-improvement-node/attempt-14/final-example-addon-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-14/final-example-addon-regressions.log; exit \$result"` | 0 | 19 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-14/final-example-addon-regressions.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionCommandTests' > tmp/ds179/ds179-07-improvement-node/attempt-14/final-chain-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-14/final-chain-regressions.log; exit \$result"` | 0 | 10 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-14/final-chain-regressions.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ds179/ds179-07-improvement-node/attempt-14/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else print -r -- "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-14/swiftlint-retry.log` |
| `git diff --check` | 0 | 0 | 0 | stdout empty; successful command exit recorded during final self-check |

### Superseded attempts

- `attempt-13/regression.log` exited 1 after 19 tests with one failure: the new catalog entry was alphabetically after `design-*`. The entry is now before `design-*`; the final example/add-on regression above passes all 19 tests.
- `attempt-14/swiftlint.log` exited 1 with six diagnostics (two statement formatting, three switch alignment, large local test tuple, existing shared adapter dispatch complexity). The formatting and tuple were corrected, and the persona dispatch checks were extracted without changing order or behavior. `attempt-14/swiftlint-retry.log` is the final-source strict pass.
- `attempt-14/build.log` ran `swift build` but its wrapper then failed with zsh's read-only `status` variable. `attempt-14/build-retry.log` exited 0; the later final-source build is recorded above.
- Earlier compile/test attempts are retained in `attempt-1` through `attempt-12` logs. They exposed intermediate compile errors, an async lock misuse, fixture resolver/date setup, CLI path normalization, type-checker complexity, incorrect digest assertions, and a Swift syntax issue. These intermediate source states were corrected; the final-source positive test suites above supersede them.

## Handoff

- Implementation scope is complete and ready for independent review. `ds179-06` remains downstream in the serial chain; formal review, review-dependent documentation/index updates, staging and commit belong to later workflow steps.
- No review findings were present at dispatch. No GraphQL DTO or SDL changes were made.

## Test-integrity revision: TI-07-001

- Re-read the finding and ordered repair instructions. The gap was real: the previous tests exercised `touchedExcludedNodes` directly but did not verify `applyProposal` rejected recursive targets before starting the CLI.
- Added `testApplyRecursionGuardRejectsImprovementTargetsBeforeSubprocess` and a shared service-mode assertion helper in `Tests/RielaCLITests/WorkflowImprovementNodeTests.swift`. It injects three valid mocked proposals: replace `prompts/improve-propose.md`, change the inbound transition into `improve-context`, and remove the improvable transition into `improve-propose`.
- Each case seeds a store on run 1 and checks run 2 returns `rejected/targetsImprovementNode`, invokes no CLI process, leaves definition history count unchanged, and remains pinned to the seed version. The prior pure recursion test and other assertions remain intact. No production sources changed; no implementation defect was exposed.
- Test source hash changed from `963c18adde21429d4ad5522c55afee4ba7aecef1899ede2ff4e149455c445424` to `e37262ad6d3e93f340b53796fbf0df2ba431390200441e27c32cdb40c3a91867`.

### Attempt 15 verification

| Command | Exit | Tests | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-07-improvement-node/attempt-15/build.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-15/build.log; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-15/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests > tmp/ds179/ds179-07-improvement-node/attempt-15/improvement-tests.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -40 tmp/ds179/ds179-07-improvement-node/attempt-15/improvement-tests.log; exit $result'` | 0 | 8 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-15/improvement-tests.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'RielaExampleParityTests|RielaBuiltinAddonCatalogTests|BuiltinStatefulAddonRegistryTests|KeyValueStoreAddonTests' > tmp/ds179/ds179-07-improvement-node/attempt-15/example-addon-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -35 tmp/ds179/ds179-07-improvement-node/attempt-15/example-addon-regressions.log; exit \$result"` | 0 | 21 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-15/example-addon-regressions.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-07-improvement-node/attempt-15/changed-swift-files.nul > tmp/ds179/ds179-07-improvement-node/attempt-15/swiftlint.log 2>&1; result=$?; print -r -- exitStatus=$result; cat tmp/ds179/ds179-07-improvement-node/attempt-15/swiftlint.log; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-15/swiftlint.log` |
| `git diff --check > tmp/ds179/ds179-07-improvement-node/attempt-15/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-15/diff-check.log` |

- The expanded add-on filter explicitly ran `RielaBuiltinAddonCatalogTests` (2 tests), `BuiltinStatefulAddonRegistryTests` (2), `KeyValueStoreAddonTests` (8), and `RielaExampleParityTests` (9), total 21/21.
- TI-07-001 is addressed in source and test evidence; independent review of this correction remains pending.

## Adversarial review revision: AR-07-001

- Re-read design §9 and the adversarial finding. The guard relied on synthetic `nodes/node-<nodeId>.json` paths, `prompts/` prefixes and step IDs matching node IDs; this was a real bypass for valid authored workflows.
- `WorkflowImprovementDigest.touchedExcludedNodes` now derives node-file owners from `workflow.json` `nodes[].nodeFile`, recursively collects authored-view file references from excluded node rows and node-file JSON (including `promptVariants`), and derives excluded step IDs from `steps[].nodeId` while retaining the node-ID compatibility match. It compares node and step rows by ID and flags changed transitions into excluded steps. Both before/after views contribute footprints so node-file and prompt-reference changes are detected.
- Added pure cases for `stepId != nodeId` step edits and inbound edges, a nonconventional `nodes/proposer.json` file edit, a nested `promptVariants` prompt path without a `prompts/` prefix, an unrelated prompt edit, and index-shift stability. Existing service-mode recursion cases and the summarize-prompt run-2/run-3 adoption scenario remain unchanged.
- Pre/post SHA-256 for this revision: `WorkflowImprovementDigest.swift` `ceb96f7780a133c9ae4a9ecec5674f0f633ab06e49738549a4a46a54c0b9bb37` → `af7d221c6c10aab642c34581fa74772d96c2b01d27175a95b6f1688dc31e1c33`; `WorkflowImprovementNodeTests.swift` `e37262ad6d3e93f340b53796fbf0df2ba431390200441e27c32cdb40c3a91867` → `3a45fec9b925cdf7f63e9feb8258d1e41cfe5816db176a4eeab687582842b3d8`.

### Attempt 16 verification

| Command | Exit | Tests | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-07-improvement-node/attempt-16/build.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -30 tmp/ds179/ds179-07-improvement-node/attempt-16/build.log; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests > tmp/ds179/ds179-07-improvement-node/attempt-16/improvement-tests.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -45 tmp/ds179/ds179-07-improvement-node/attempt-16/improvement-tests.log; exit $result'` | 0 | 9 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/improvement-tests.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'RielaExampleParityTests|RielaBuiltinAddonCatalogTests|KeyValueStoreAddonTests' > tmp/ds179/ds179-07-improvement-node/attempt-16/example-addon-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -30 tmp/ds179/ds179-07-improvement-node/attempt-16/example-addon-regressions.log; exit \$result"` | 0 | 19 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/example-addon-regressions.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionCommandTests' > tmp/ds179/ds179-07-improvement-node/attempt-16/chain-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -30 tmp/ds179/ds179-07-improvement-node/attempt-16/chain-regressions.log; exit \$result"` | 0 | 10 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/chain-regressions.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ds179/ds179-07-improvement-node/attempt-16/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else print -r -- "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/swiftlint-strict.log` |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/WorkflowImprovementDigest.swift Tests/RielaCLITests/WorkflowImprovementNodeTests.swift > tmp/ds179/ds179-07-improvement-node/attempt-16/swiftlint.log 2>&1'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/swiftlint.log` |
| `git diff --check > tmp/ds179/ds179-07-improvement-node/attempt-16/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-16/diff-check.log` |

- Adversarial review decision: AR-07-001 implementation criteria are addressed; independent re-review remains pending.

## Adversarial review revision: AR-07-002

- Re-read the finding and design §9. The previous `rowsById` used `Dictionary(uniqueKeysWithValues:)` on proposer-controlled authored rows and could trap on duplicate node or step ids before the apply add-on returned a closed outcome.
- `WorkflowImprovementDigest.rowsById` now groups rows by id into `[String: [JSONValue]]`. Node rows compare as groups; step changes, ownership and transition lists account for every row in each duplicate group. This avoids the process trap while preserving the recursion guard: a duplicate excluded node/step is classified as `targetsImprovementNode`; an unrelated duplicate reaches the CLI validator and returns `invalid_definition`.
- Added `testRecursionGuardGroupsDuplicateRowsWithoutTrapping` for duplicate unrelated steps, duplicate excluded steps and duplicate excluded nodes. Added `testApplyDuplicateRowsAreClosedWithoutCrashing` for service-mode proposals. Both cases assert a terminal rejected output, unchanged definition history and the seed-version pin; the excluded duplicate asserts zero CLI calls, and the unrelated duplicate asserts the single CLI update call. Existing tests and AR-07-001 authored-reference cases remain intact.
- SHA-256 for the AR-07-002 source/test edit: `WorkflowImprovementDigest.swift` `af7d221c6c10aab642c34581fa74772d96c2b01d27175a95b6f1688dc31e1c33` → `878c08bd569515ba1909fef3f837f027bb3cc5ac89f4edb2b022fdbd1a657917`; `WorkflowImprovementNodeTests.swift` `3a45fec9b925cdf7f63e9feb8258d1e41cfe5816db176a4eeab687582842b3d8` → `6fd378a3c3472a15ac4e92788393a885078f9ab8a029f51cda98b7c9057d8134`.

### Attempt 17 final-source verification (retry-2)

All commands ran in the foreground from the repository root through an arm64 shell. Retry-1 records a fixed compile error from the stale local `label` identifier; the first lint pass records the tuple-style diagnostic. Those logs are preserved and superseded by the successful retry-2 final-source gates.

| Command | Exit | Tests | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/build.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -20 tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/build.log; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests > tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/improvement-tests.log 2>&1; result=$?; print -r -- exitStatus=$result; tail -35 tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/improvement-tests.log; exit $result'` | 0 | 11 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/improvement-tests.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'RielaExampleParityTests|RielaBuiltinAddonCatalogTests|KeyValueStoreAddonTests' > tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/example-addon-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/example-addon-regressions.log; exit \$result"` | 0 | 19 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/example-addon-regressions.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionCommandTests' > tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/chain-regressions.log 2>&1; result=\$?; print -r -- exitStatus=\$result; tail -25 tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/chain-regressions.log; exit \$result"` | 0 | 10 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/chain-regressions.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else print -r -- "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/swiftlint.log` |
| `git diff --check > tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-2/diff-check.log` |

- The strict lint manifest is nonempty and contains exactly `Sources/RielaCLI/WorkflowImprovementDigest.swift` and `Tests/RielaCLITests/WorkflowImprovementNodeTests.swift` as NUL-terminated paths.
- AR-07-002 implementation criteria are addressed on final source; independent adversarial re-review remains pending.

### Final verification refresh after terminal-session assertion

- `testApplyDuplicateRowsAreClosedWithoutCrashing` now also asserts run 2 session status `.completed` for both duplicate proposals. This closes the session-terminal outcome check. The final test hash is `157dd37f132425b2217465659c3255356c5df18b16db350a57de747a20cf4709`; `WorkflowImprovementDigest.swift` remains `878c08bd569515ba1909fef3f837f027bb3cc5ac89f4edb2b022fdbd1a657917`.
- Attempt-17 retry-3 is the final-source evidence and supersedes retry-2 after the added assertion: build 0; `WorkflowImprovementNodeTests` 11/11; declared regressions 19/19; chain regressions 10/10; strict changed-file SwiftLint 0; `git diff --check` 0. Complete logs are in `tmp/ds179/ds179-07-improvement-node/attempt-17/retry-3/` (`build.log`, `improvement-tests.log`, `example-addon-regressions.log`, `chain-regressions.log`, `swiftlint.log`, `diff-check.log`).
