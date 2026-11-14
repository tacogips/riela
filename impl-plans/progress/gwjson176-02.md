# gwjson176-02 implementation progress

## Status and scope

Step 6 implementation is complete on fanout branch `gwjson176-02` in the shared branch `feat/issue-176-gateway-json-remainder`. The accepted predecessor `gwjson176-01` is present in `acceptedPlanIds`; the assigned plan depends on it and remains within its dispatched `writePaths`. No files outside this plan's write ownership were edited by this plan. The shared tree also contains authorized changes from gwjson176-01 and gwjson176-06; they were preserved. Formal test-integrity, adversarial and combined-tree integration review, then exact-file staging/commit/push, remain downstream workflow steps.

Issue: [tacogips/riela#176](https://github.com/tacogips/riela/issues/176). Workflow mode: `opus-luna-design-and-implement-review-loop`, native Riela fanout shared-branch implementation. Implementer: Codex GPT-6, Step 6. Reviewers: downstream independent review pending.

## Implementation

- Filled `BuiltinGatewayRequestChecks.extendedIssues` for embedded/container X readers, legacy Gmail container reader, Google Service read/write, and named Kaiba arguments. Literal values use shared runtime builders/parsers; templated values retain key-level checks.
- Split X request validation and rendering while retaining the existing serializer and diagnostic order. Added the pinned fail/output parser for gwjson176-03 to call. The structured provider-failure runtime path is explicitly outside this plan.
- Extracted the legacy/container operation and mode checks, typed Google Service request parsing/shape validation, and Kaiba nested argument rules while preserving runtime diagnostic ordering and codes.
- Added pre-refactor byte-exact X document goldens, production-validation/runtime parity rows, Kaiba shared-rule/runtime parity, and the Outcome B X operation-name golden.
- R3 selected **Outcome B (SDL only)**. The X SDK's public in-process `XGatewayCLI.run(arguments: ["graphql", "schema"], environment: [:])` returns the SDK's SDL before provider execution. GatewaySDKKit publicly exposes catalog-to-SDL printing (`schemaSDL()`), but no SDL-to-catalog parser. Therefore a bounded scanner extracts Query root names; Riela leaves rendering/type semantics on the existing SDK path. The scanner is bounded to 2 MiB SDL and 1,024 names and pins 82 operations, including `homeTimeline`, `searchPosts`, and `accountMe`.
- The nested X `select` representation remains a compatibility alias and produces the same document as `selection`.

## R3 evidence

Evidence is under `tmp/issue-176/gwjson176-02/`:

- `r3-x-public-cli.log`: public `XGatewayCLI` initializer and `run` declaration.
- `r3-x-public-schema.log`: public CLI schema action returns `publicGraphQLSchema`; schema constant is module-internal in the SDK source.
- `r3-kit-public-api.log` and `r3-kit-sdl.log`: GatewaySDKKit exposes `schemaSDL()`.
- `r3-kit-parser-symbol-search.log` and `r3-kit-parser-symbol-search.status`: symbol-specific SDL/parser search returned exit status 1, meaning no public parser symbols matched.
- `r3-query-fields-extract.log`: bounded scan output ends with count `82`; includes `homeTimeline`, `searchPosts`, `accountMe`.
- `r3-confirmed-status.txt` records an earlier broad-pattern search that matched a comment; the symbol-specific parser search above is the corrected evidence used for Outcome B.

## Source identities

`pre-edit-sha256.txt` captures pre-edit hashes for existing plan-owned paths. Paths absent before this plan are marked `new`.

| Path | Pre-edit SHA-256 | Final SHA-256 |
|---|---|---|
| `Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift` | `ae516641cdb3c3d41672dc8360fffea57266c219283624a34d5e03cf3d1e9584` | `ef79431042763539aefdf39e6312095ec1ac3b23c6583a41e5fbc648cd3bd4c2` |
| `Sources/RielaCLI/BuiltinGatewayJSONRequest+XCompatibility.swift` | `878d372d62de1e4045f9a349504140d29c28a838c4ee73e3c0f5b6e830c00f82` | `fdd87210ef221985e61f5c9a62742544ca135ae2be9172fcaf0639764fbd7289` |
| `Sources/RielaCLI/XGatewayProviderFailureMode.swift` | new | `4b89bc748eaa128f1866511a043fd84083a875abad2aaf9f2fbbd36d84b6d2b2` |
| `Sources/RielaCLI/XGatewayOperationCatalog.swift` | new | `3ab5c291dda338a8753d527e0afb0b1b93dfcc0eddebe3eb3b6a691f5f8af3b4` |
| `Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift` | `cf040565d26a7932273758adc98284a4edf7e30e42d5689541b6cbd028823716` | `b1c23d24383ba4380535ceecaeb92a972fec277ebebdbacb056e69de92ea48b0` |
| `Sources/RielaCLI/ContainerGatewayAddonExecutor.swift` | `45469f0e41373e69ed5da5bcb12fbcc67e5c40e11ca0e5343bac91365379d6eb` | `1193137353ab25059b89bf48102567ebc2a5e7b75282fdbd3224933b1433087e` |
| `Sources/RielaKaibaAddons/KaibaAddonInputs.swift` | `21edad36e9c5302fa78cc408b3dd5e76d1fcf50c92a5b4fbe5b37a3f5cac9c72` | `a566ffe42ddc2c5e4ee8045bc625c8ec2601df1219b2501f12682bda3b56d09b` |
| `Tests/RielaCLITests/XGatewayJSONDocumentGoldenTests.swift` | new | `48dc885370486a2211241c0a696ce9f2210f0ca8b4e8fadb430d6b3428aa5b78` |
| `Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift` | new | `179b781f217ddcdc5271b4419512b25cfaff72f0e5fccb1d09356c6956ae93dd` |
| `Tests/RielaKaibaAddonsTests/KaibaWorkflowGatewayValidationTests.swift` | new | `584345167346cdd0d383a8aaa48f6a18e016f0c3cd1ae60403d116a3b169835e` |
| `impl-plans/active/gwjson176-02-x-legacy-gs-kaiba-checks.md` | `927faf4254880a2a688c4e88a36478a5ea2c8b1e4709d83cef330554bce548fa` | `00e2f3f26e5fd2921cbeeba1ca100d013e30c673c85155990f8db5dbad7f86fb` |
| `impl-plans/progress/gwjson176-02.md` | new | recorded in `tmp/issue-176/gwjson176-02/final-hash-ledger.txt` |

## Golden capture

`golden-pre-refactor-2.log` records 5 tests passing against the unchanged X renderer before the refactor. `golden-final.log` records all 7 current tests passing, including the same five byte-exact cases and two Outcome B catalog checks. The old and new five document strings remain identical; nested `select` and `selection` are equal.

## Verification

All Swift commands ran from the repository root in an arm64 shell. Logs are complete and plan-local. Final focused suites were run after the last source change, including the Google Service deadline/error precedence assertion.

| Command | Exit | Tests | Failures | Complete log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-02/build-final.log 2>&1'` | 0 | 0 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/build-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayJSONDocumentGoldenTests > tmp/issue-176/gwjson176-02/golden-final.log 2>&1'` | 0 | 7 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/golden-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-02/validation-order-final.log 2>&1'` | 0 | 22 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/validation-order-final.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'BuiltinGatewayJSONRequestTests|LegacyGatewayJSONRequestTests|XGatewaySDKAddonTests|XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|GoogleServiceGatewayAddonTests|KaibaStructuredArgumentsTests' > tmp/issue-176/gwjson176-02/regression-order-final.log 2>&1"` | 0 | 39 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/regression-order-final.log` |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-window-checkpoint --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/validate-x-window-final.log 2>&1'` | 0 | 0 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/validate-x-window-final.log` |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-incremental-posts-kv --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/validate-x-kv-final.log 2>&1'` | 0 | 0 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/validate-x-kv-final.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-176/gwjson176-02/changed-swift-files-final.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-176/gwjson176-02/changed-swift-files-final.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/issue-176/gwjson176-02/lint-strict-final.log 2>&1` | 0 | 0 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/lint-strict-final.log` |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/BuiltinGatewayJSONRequest+XCompatibility.swift Sources/RielaCLI/XGatewayProviderFailureMode.swift Sources/RielaCLI/XGatewayOperationCatalog.swift Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift Sources/RielaCLI/ContainerGatewayAddonExecutor.swift Sources/RielaKaibaAddons/KaibaAddonInputs.swift > tmp/issue-176/gwjson176-02/lint-final.log 2>&1'` | 0 | 0 | 0 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/lint-final.log` |

`changed-swift-files-final.nul` is the NUL-delimited selected-file manifest used by the strict lint command. Both lint logs are empty. The selected files include the three plan-owned test files.

## Superseded attempts

These earlier failures are preserved as debugging evidence and are not current-source gates. Each was corrected and rerun after the relevant source/fixture change:

| Earlier command | Exit | Tests | Failures | Complete log | Correction and current-source rerun |
|---|---:|---:|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayJSONDocumentGoldenTests > tmp/issue-176/gwjson176-02/golden-pre-refactor.log 2>&1'` | 1 | 5 | 1 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/golden-pre-refactor.log` | The literal `{{c}}` fixture was resolved as a template. The corrected pre-refactor capture `golden-pre-refactor-2.log` passed 5/5; current `golden-final.log` passed 7/7. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-02/validation.log 2>&1'` | 1 | 21 | 1 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/validation.log` | Fixture templated the argument key instead of using literal `mediaRootDir`. Corrected fixture; `validation-order-final.log` passed 22/22. |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'BuiltinGatewayJSONRequestTests|LegacyGatewayJSONRequestTests|XGatewaySDKAddonTests|XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|GoogleServiceGatewayAddonTests|KaibaStructuredArgumentsTests' > tmp/issue-176/gwjson176-02/regression.log 2>&1"` | 1 | 39 | 5 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/regression.log` | Restored X shape-before-template and Google credential-before-value-parse ordering. `regression-order-final.log` passed 39/39. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayJSONDocumentGoldenTests > tmp/issue-176/gwjson176-02/golden-outcome-b.log 2>&1'` | 1 | 7 | 1 | `/Users/taco/gits/tacogips/riela-worktrees/issue-176-gateway-json/tmp/issue-176/gwjson176-02/golden-outcome-b.log` | Scanner initially counted nested argument rows (96). Restricted extraction to Query root-field indentation; `golden-final.log` passed 7/7 with the pinned 82. |

## Blockers, risks and handoff

Blockers: none. `providerFailure: "output"` runtime behavior and its runtime parity row are intentionally owned by dependent plan gwjson176-03; this plan only adds the parser and static validation. The full design-matrix and docs updates belong to later plans. Shared-tree integration review, formal independent reviews, commit and push remain pending later workflow steps.

Resolved items: prior implementation-order issues were corrected; final focused validation and regression suites pass on current source. Severity: fixed.

Residual risks: the SDK SDL name scanner intentionally does not validate X argument types or selection field types; SDK execution remains the type authority. The public schema action was verified against the resolved SDK checkout on this host. On non-macOS or SDK-excluded builds, catalog checks guarded by `canImport` are unavailable as designed.

## Step 6 final-source repair rerun (2026-10-25)

The progress record previously ended with an operator note incorrectly leaving
GW176-02-TI-1 open. The current source already contains the Google Service
post-render operation-key subset guard and the resolver-level regression
`testGoogleServiceRuntimeChecksRenderedExactPlaceholderArgumentKeys`, which
checks placeholder deferral, `policyBlocked`, and zero client calls. A clean
cache test compile exposed that the test file needed an explicit
`GoogleServiceGatewayCore` import; that import also made one explicit
`JSONValue.string` fixture ambiguous, so it is now qualified as
`RielaCore.JSONValue.string`.

| Path | Pre-edit SHA-256 | Final SHA-256 |
|---|---|---|
| `Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift` | `720e94def3fec83473b87669d2dd0bfb0551349d6615c3add065d2eb41073c16` | `91634cf752d20ab36d379b92a47ec3cf35bd1bf4d3b2a87f24a859b067342bf9` |
| `Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift` | unchanged this rerun | `e7896d138d0a8f4d7a1c773c415f79a04c990501a44b70029b4939bbfd3c7819` |

Current-source verification ran in the foreground on arm64 from the repository
root. Complete logs are under
`tmp/issue-176/gwjson176-02/step6-rerun/`:

| Command | Exit | Tests | Failures | Complete log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-02/step6-rerun/build-stable.log 2>&1'` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/build-stable.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayJSONDocumentGoldenTests > tmp/issue-176/gwjson176-02/step6-rerun/golden-stable.log 2>&1'` | 0 | 7 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/golden-stable.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-02/step6-rerun/validation-stable.log 2>&1'` | 0 | 23 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/validation-stable.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'BuiltinGatewayJSONRequestTests|LegacyGatewayJSONRequestTests|XGatewaySDKAddonTests|XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|GoogleServiceGatewayAddonTests|KaibaStructuredArgumentsTests' > tmp/issue-176/gwjson176-02/step6-rerun/regression-stable.log 2>&1"` | 0 | 39 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/regression-stable.log` |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-window-checkpoint --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/step6-rerun/validate-x-window-stable.log 2>&1'` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/validate-x-window-stable.log` |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-incremental-posts-kv --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/step6-rerun/validate-x-kv-stable.log 2>&1'` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/validate-x-kv-stable.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-176/gwjson176-02/step6-rerun/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-176/gwjson176-02/step6-rerun/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-02/step6-rerun/lint-strict-stable.log` |

The two X examples validate successfully; `x-incremental-posts-kv` retains its
existing two warnings. The first test attempts before adding the import failed
during test compilation with missing Google Service module symbols; the
attempt after adding the import identified the ambiguous JSONValue fixture.
Their complete logs remain as `step6-rerun/golden.log`, `validation.log`,
`regression.log`, and `golden-final.log`, `validation-final.log`,
`regression-final.log`. A subsequent attempt could not create new logs while
the host had 116 MiB available; `swift package clean` freed the regenerable
SwiftPM cache, after which every final-source gate above passed.

Resolved items: GW176-02-TI-1 fixed. Severity: fixed. Implementation gates are
complete; independent test-integrity/adversarial/integration review and the
later exact-file staging, commit and push remain downstream.
