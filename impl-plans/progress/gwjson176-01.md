# GWJSON176-01 implementation progress

## Status

Implementation complete for the assigned gwjson176-01 contract; pending downstream test-integrity and adversarial review. No codex-agent reference applies. Issue: tacogips/riela#176, implementation branch `feat/issue-176-gateway-json-remainder`, workflow execution `opus-luna-design-and-implement-review-loop-session-482`.

## Decisions

- Implemented only R1 catalog-backed checker families and the run warning path. X, legacy Gmail container reader, Google Service and Kaiba request checks remain assigned to serial plan gwjson176-02; `extendedIssues` is intentionally an empty seam.
- Production validation receives the checker once from `WorkflowValidationContext.production()`. Core invokes it only for `riela/` or `kaiba/` add-ons with no existing diagnostics, and reports relative paths beneath `addon.config`.
- Literal request checks use the runtime builder and pinned catalogs; templated argument objects receive deterministic key and required-name checks. Exact whole-object placeholders defer to runtime. The checker strips `postprocess` before the leaf request check.
- `workflow run` keeps context-free errors blocking and emits only production-context additions as `warning:` lines on stderr. The warning fixture uses a templated unknown argument: mixed mode is already rejected by Core and therefore cannot be a production-only warning under the accepted duplicate-suppression contract.
- Google Documents `operationArgv` purity confirmed from `.build/checkouts/google-documents-gateway/Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift:139-149`: the body validates input, builds a request, catalog-builds and validates rendered argv; it performs no file, environment, credential, network or transport access. The pinned SDK spec `.build/checkouts/google-documents-gateway/design-docs/specs/design-gateway-sdk.md:255-260` explicitly states `buildArgv` is construction-only and does not inspect paths, credentials, authorization or transport. The extracted function preserves request/guard/build/error order and the runtime error strings. Initial inspection commands: `rg -n -C 14 "func buildArgv" .build/checkouts/google-documents-gateway` and `rg -n "URLSession|Process|FileManager|ProcessInfo|environment|\\bopen\\("` on the SDK source files.

## Edits and source identity

Each edit intent is preserved in `tmp/issue-176/gwjson176-01/edit-intents.md`; the native pre-node snapshot is `tmp/riela-fanout/8067F614-E72A-45A6-9966-0DDB46A14C53/319048B0-E5E4-4457-9256-610983770F12.json`. Initial and final hashes:

| Path | Pre-edit SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/WorkflowGatewayAddonValidation.swift` | `f2d6a6a1c34fe561ac3cf9127e7a34e55fc5912aee085cbb0bee3400fbd00896` | `5b8f6721d0f58bcbfa120ea10d17b4193f9f398306805f3a5a864ce572d0eb04` |
| `Sources/RielaCLI/WorkflowValidationContext+Production.swift` | `e4addb02a89cf8f134059b564c776ed65fbec2fb028ea2a43c319bd1a3026f9b` | `a8ca4a8e087d278a19b586b7374e64de7330e55d52c378a62f51673fbe5114b9` |
| `Sources/RielaCLI/BuiltinGatewayRequestChecks.swift` | absent | `95fe4f84e18a080b58f28ad8a464852050d90dcd6d4a061109522aa7d8cf2ce7` |
| `Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift` | absent | `ae516641cdb3c3d41672dc8360fffea57266c219283624a34d5e03cf3d1e9584` |
| `Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift` | `87e1988d4a49a3b37841f2cdbea2ba232819c3f1cff89bf6dbc70521424084af` | `2745e7505daa9e1b9180d533e5cea21e393fe92046aa8059733c6c998d758a14` |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | `e71562e737c897b09d4cc1340e2560d325f84657d07ccc0a408d994f147a82c3` | `f876d55ec6f3ac31512be0db7baa2098a0a2296e7387661d2d23daec7c8bef8c` |
| `Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift` | `d7e915b76de1d6bc8fa679a81bc78684fdbb3548809337db90c408f5fb7ddf47` | `d1e5b72ec2f6e1d53a895def387ab950c22f2fc9e09735d5605158cc5eb3016c` |
| `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` | `28d0be7c3c3c75961f79676cfe38b3903618a5758b4070200cb87980ca5c9083` | `2e8a0626eff0a30fdc7500dbd66a9b1d2ca047a905b4a0848e33d3d7bdfaeef3` |
| `Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift` | absent | `92f27351d7192bef6d6bce88e5f0e20a5ba61841cc3154c424504d09e57a2e0a` |
| `Tests/RielaCLITests/WorkflowRunGatewayValidationWarningTests.swift` | absent | `356bb24c2852abde627453c017a1698ecae62a6c4e8041fa7dc3950e2c4e5763` |
| `impl-plans/active/gwjson176-01-validation-contract.md` | `f5cd4609db4337925d1feab8377d15932978c3086fa29c2d28800f6115ce290f` | `acfe4d24ca95a53135f6b930ff94d54b8aaaaa7c75dec3cb475359acfecf205a` |

The progress file was absent before this plan began; its final file hash is returned in the Step 6 payload to avoid a self-referential checksum.

## Final-source verification

All commands ran in the foreground from the repository root inside the required arm64 zsh shell. Logs are complete under `tmp/issue-176/gwjson176-01/`.

| Command | Log path | Exit status | Tests run | Failures |
| --- | --- | ---: | ---: | ---: |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-01/build-final2.log 2>&1'` | `tmp/issue-176/gwjson176-01/build-final2.log` | 0 | 0 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-01/validation-final4.log 2>&1'` | `tmp/issue-176/gwjson176-01/validation-final4.log` | 0 | 13 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowValidateGatewayContextTests > tmp/issue-176/gwjson176-01/context-final3.log 2>&1'` | `tmp/issue-176/gwjson176-01/context-final3.log` | 0 | 3 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter BuiltinGatewayJSONRequestTests > tmp/issue-176/gwjson176-01/request-final3.log 2>&1'` | `tmp/issue-176/gwjson176-01/request-final3.log` | 0 | 6 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter GoogleDocumentsGatewayAddonTests > tmp/issue-176/gwjson176-01/docs-final3.log 2>&1'` | `tmp/issue-176/gwjson176-01/docs-final3.log` | 0 | 13 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowRunGatewayValidationWarningTests > tmp/issue-176/gwjson176-01/run-warning-final4.log 2>&1'` | `tmp/issue-176/gwjson176-01/run-warning-final4.log` | 0 | 1 | 0 |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowGatewayAddonValidation.swift Sources/RielaCLI/BuiltinGatewayRequestChecks.swift Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/WorkflowValidationContext+Production.swift Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift > tmp/issue-176/gwjson176-01/lint-final.log 2>&1'` | `tmp/issue-176/gwjson176-01/lint-final.log` | 0 | 0 | 0 |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/issue-176/gwjson176-01/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | `tmp/issue-176/gwjson176-01/lint-strict-final.log` | 0 | 0 | 0 |

The selected-file strict lint manifest is `tmp/issue-176/gwjson176-01/changed-swift-files.nul` and includes only the ten changed Swift files owned by this plan.

## Superseded attempts

These logs are retained; none is treated as final passing evidence:

| Command | Log path | Exit status | Observed result |
| --- | --- | ---: | --- |
| Initial `swift build` started before source editing was finished | `tmp/issue-176/gwjson176-01/build-initial.log` | 1 | Build reported Core source modified during compilation; clean rerun passed. |
| Initial `WorkflowGatewayValidationTests` | `tmp/issue-176/gwjson176-01/validation.log` | 1 | 13 tests, 5 test assertion failures from parity expectations (literal builder errors were expected at config root; typed template fixture used wrong values). |
| First parity correction compile | `tmp/issue-176/gwjson176-01/validation-rerun.log` | 1 | Runner not started: enum expression return type inference error. |
| Second parity correction compile | `tmp/issue-176/gwjson176-01/validation-final.log` | 1 | Runner not started: nested switch needed explicit returns. |
| Initial warning fixture | `tmp/issue-176/gwjson176-01/run-warning-final.log` | 1 | 1 test, 2 fixture assertions failed; changed the test to use a templated unknown name and JSONSerialization. |
| First changed-file strict lint | `tmp/issue-176/gwjson176-01/lint-strict.log` | 1 | Corrected two strict lint findings; `lint-strict-final.log` passes. |

## Blockers

[]

## Residual risks

- SDK-backed Apple, Documents, Analytics and Notion catalog checks remain guarded by `canImport`; non-macOS builds skip those catalog-dependent checks as accepted by the plan.

## Resolved findings

[]

## Test-integrity repair — GW176-01-TI-1

- Status: repaired for independent review; this does not record a review acceptance.
- Finding: `GW176-01-TI-1` (mid), assigned to this plan. Added executed Docs read and Apple GraphQL full catalog parity rows in `Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift`.
- Docs row compares validation to `GoogleDocumentsGatewayAddonEngine.operationArgv` for a catalog-selected valid literal and unknown literal, checks the exact templated unknown path `workflow.nodes[0].addon.config.arguments.unexpected`, and checks exact-placeholder deferral. Apple row compares validation to `BuiltinGatewayJSONRequest.document(argumentsAlreadyRendered: true)` for valid and unknown literals and asserts the checker is silent with non-empty `addon.inputs`. Existing rows and Core suppression tests were not changed.
- Test file SHA-256: pre-edit `92f27351d7192bef6d6bce88e5f0e20a5ba61841cc3154c424504d09e57a2e0a`; final `353f374488b787ce60567756e54b86183ba95b06e8a8863e51282183ee1630c7`.

| Command | Log path | Exit status | Tests run | Failures |
| --- | --- | ---: | ---: | ---: |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-01/validation-ti1.log 2>&1'` | `tmp/issue-176/gwjson176-01/validation-ti1.log` | 0 | 15 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter GoogleDocumentsGatewayAddonTests > tmp/issue-176/gwjson176-01/docs-ti1.log 2>&1'` | `tmp/issue-176/gwjson176-01/docs-ti1.log` | 0 | 13 | 0 |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift > tmp/issue-176/gwjson176-01/lint-ti1.log 2>&1'` | `tmp/issue-176/gwjson176-01/lint-ti1.log` | 0 | 0 | 0 |

The validation log shows `CatalogWorkflowGatewayValidationTests` executed 4 tests and `WorkflowGatewayValidationTests` executed 11 tests, both with zero failures. The strict lint log is empty. First compile attempt before the local inference correction failed without starting tests; retained as `tmp/issue-176/gwjson176-01/validation-ti1-attempt1.log` (exit 1, testsRun 0, failureCount 0). The repaired run above supersedes it.

Resolved finding: `GW176-01-TI-1`, severity `fixed`, pending independent Opus re-review.

## Adversarial repair — GW176-01-AR-1

- Status: repaired for independent re-review; the Step 7 adversarial decision is not yet accepted.
- Finding: `GW176-01-AR-1` (high), assigned to this plan. Restored the `#if canImport(GoogleDocumentsGatewayCore)` guard around the runtime `operationArgv` call and `operation.role` access, plus the original `#else` policy error `"\(input.addon.name) requires macOS"`. The fallback text matches `main`; the helper remains guarded as before.
- Adapter SHA-256: pre-edit `2745e7505daa9e1b9180d533e5cea21e393fe92046aa8059733c6c998d758a14`; post-edit `365c9022e75c390b256b6d5c4db481e212a130201a456f00d580f701d7600038`.

| Command | Log path | Exit status | Tests run | Failures |
| --- | --- | ---: | ---: | ---: |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-01/build-ar1.log 2>&1'` | `tmp/issue-176/gwjson176-01/build-ar1.log` | 0 | 0 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter GoogleDocumentsGatewayAddonTests > tmp/issue-176/gwjson176-01/docs-ar1.log 2>&1'` | `tmp/issue-176/gwjson176-01/docs-ar1.log` | 0 | 13 | 0 |
| `arch -arm64 /bin/zsh -lc 'swift test --filter CatalogWorkflowGatewayValidationTests > tmp/issue-176/gwjson176-01/catalog-ar1.log 2>&1'` | `tmp/issue-176/gwjson176-01/catalog-ar1.log` | 0 | 4 | 0 |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift > tmp/issue-176/gwjson176-01/lint-ar1.log 2>&1'` | `tmp/issue-176/gwjson176-01/lint-ar1.log` | 0 | 0 | 0 |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/issue-176/gwjson176-01/changed-swift-ar1.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | `tmp/issue-176/gwjson176-01/lint-strict-ar1.log` | 0 | 0 | 0 |
| `rg -n -C 10 'operationArgv|operation\\.role|requires macOS' Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift > tmp/issue-176/gwjson176-01/guard-proof-ar1.log` | `tmp/issue-176/gwjson176-01/guard-proof-ar1.log` | 0 | 0 | 0 |

The guard proof shows the only runtime `operationArgv` and `operation.role` references inside the guarded branch and the restored fallback at its `#else`; the static helper also remains under its existing `canImport` guard. Strict and requested file lint logs are empty. Finding `GW176-01-AR-1` is resolved in source, severity `fixed`, pending independent Opus re-review.
