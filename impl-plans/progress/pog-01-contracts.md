# pog-01-contracts implementation progress

Mode: issue-resolution. Plan: `impl-plans/active/prompt-overflow-guard-01-contracts.md`.
Incident reference: session-471; no GitHub issue. Branch: `feat/agent-prompt-overflow-guard`.

## Implementation log

The fanout pre-node snapshot at `tmp/riela-fanout/B043D033-6333-40ED-8B43-F4FDC86562A5/3524B227-8CA7-4A80-80E8-C297D775009F.json` confirms all assigned source/test files are unchanged from the accepted checkpoint and the two new source/test pairs plus this progress file were missing. No predecessor dependency is required (`dependsOn: []`).

| File | Intended behavior / edit | Pre-edit SHA-256 | Post-edit SHA-256 |
|---|---|---|---|

## Verification

Pending.

| `Sources/RielaCore/RuntimeSession.swift` | Add the extensible `promptTooLarge` failure-kind value and include it in known kinds. | `b1c224297e97602002561267caf689f8cd3877a5ee562073690b74b2ff4fb4c9` | `26314433cf578447a23cced4ce3b88627cd7d98d3ece0de8941595b47da7aabd` |

| `Sources/RielaCore/AdapterContracts.swift` | Add optional adapter failureKind hint with a defaulted trailing initializer parameter. | `e4a081de6af6fe61487baeefb3227dd7354a6a8f2219c49731fb9d602df43da6` | `ae23dd0bb1780062ed1b536b026a7b27f3c28fa81092b323740e4a2d9a4d5a9a` |

| `Sources/RielaCore/PromptOverflowClassification.swift` | Create the exact fixed-phrase classifier; explicit hints win, only providerError/invalidInput are phrase-classified. | `missing` | `681a3c9c683a24cef4276699c6407c770f2df2447e5bd9115157c04c2840f4b8` |

| `Sources/RielaCore/RuntimeVariablesPromptView.swift` | Create pure deterministic runtimeVariables view that elides matching message payload fields and aliases latest payload. | `missing` | `fba742a5d0e0470194ebab39238b9d98178d027d9b0a32a470a86e5ccff1374d` |

| `Sources/RielaCore/RuntimePublication.swift` | Classify both published adapter-failure record paths through adapterFailureKind. | `76aecd77cd90cb6a61e55c901c60592e11499ddb2c3aef08cce715817837f434` | `2308c5bf1759bef9bb0722f42124e3f68b019e304e157916654febbe33c37caf` |

| `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift` | Classify adapter error failure kind while leaving policy and timeout cases intact. | `70164e7c772767ff04cf74170bcc12dc5fe76140bce9fed213dbcf431f560e93` | `fb3e0f0ba0edc1ac10b3399d6e1a909ed4c3f095f16912757bffd50231f83049` |

| `Sources/RielaCore/WorkflowModel.swift` | Add optional default agent prompt byte limit without changing encoding when unset. | `14960452876b8c7cb16ed20317f1be0ebd08d31e27b7e9ea01abfb9275f0812f` | `d63178799a7a7f37f4fdcd5a481f92a42a53fdaac989388d5b61b7a337a06d60` |

| `Sources/RielaCore/WorkflowFanoutScheduling.swift` | Add optional observation inline limit and pinned 200/10000 constants. | `8ea0320d66924a9ad1e6b57ab1c3522a0b9842537c2c8c326b5e5d15cf5fb217` | `cbe2e22d8f69e5fccb8bc3c01d270412b646caceb29f3eadb51d06cee36dd19d` |

| `Sources/RielaCore/AgentNodePayload.swift` | Add optional node prompt byte limit with backward compatible decode and init. | `3fb4bd63270960dc89b91e49352209e105930711c180d8292822cc60208d2499` | `5e851443327df4624f5527df3c8734979dca048e54f0d157c557b2ffc4f726d2` |

| `Sources/RielaCore/WorkflowNodeValidation.swift` | Reject non-positive node promptMaxBytes at its pinned path. | `31f900e9af680967f087cd9bd0de9d6b66151bf593ac17754df64904e0e4a355` | `15f7caabb19e456d6d4832d40a9972ed353387d4e0d9faae5a99a6d2dd16bc03` |

| `Sources/RielaCore/WorkflowRawValidation.swift` | Validate positive defaults byte budget and independent 0...10000 integer inline limit (booleans rejected). | `4fee0e19f3cd95de69b1d8d177332ca8e76510bdd3c3466c167a340881f04503` | `c93f105b4cd52fb5337707b226fb978a2565437e4808454ddca2dc29324600a2` |

| `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` | Render only deduplicated view in runtimeVariablesPrompt and document the markers. | `1d545db093be613ceee7bb8d4466cc7e15b2e545a1d0d1daba4b2a40ee74a28e` | `307930e575ec64dc67ad3e2b1b7573c381c12d119a963fb6196255a134ed9ab9` |

| `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` | Add classifier, explicit hint, validation, decoding and default round-trip tests for shared contracts. | `missing` | `6c23c7dc36daebba0b472b1bf19ba4f7bf5ef06f70a031c7a19f602f0081b0f7` |

| `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` | Test deterministic dedup markers, malformed input preservation, overrides and runner prompt exactly-once rendering. | `missing` | `dd5f58ea5685812a90ee796780b0aa55630b0ba7a01453d944052ebab34ab385` |

| `Sources/RielaCore/WorkflowRawValidation.swift` | Avoid shadowing the fanout validation path parameter while applying the inline-limit error path. | `c93f105b4cd52fb5337707b226fb978a2565437e4808454ddca2dc29324600a2` | `06aa2a5b673cab84a5dd737757052cc482049d2486e652648b6be5652fb7e34d` |

| `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` | Make the large marker a runtime variable and await capture outside XCTest autoclosure. | `dd5f58ea5685812a90ee796780b0aa55630b0ba7a01453d944052ebab34ab385` | `492067a53fcde6ba1dc4742888792757f70204aafa92a4dbd8470a1a074fda3a` |

| `Sources/RielaCore/WorkflowRawValidation.swift` | Reject CFBoolean NSNumber values directly using CoreFoundation because the shared helper is file-private; retain explicit integer range checks. | `06aa2a5b673cab84a5dd737757052cc482049d2486e652648b6be5652fb7e34d` | `add2727cfb443f6a4fcc9b9996184ca59c42577d293f02c4b75a02fb992cc481` |

| `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` | Repair the composed-prompt test string to use a valid newline escape. | `492067a53fcde6ba1dc4742888792757f70204aafa92a4dbd8470a1a074fda3a` | `2b877f23528da374b5a0e8811a1a27865948a6ee03bd545f4f390d39d3053dbf` |

| `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` | Correct enum pattern matching for nonoptional array elements in message payload assertions. | `2b877f23528da374b5a0e8811a1a27865948a6ee03bd545f4f390d39d3053dbf` | `8afcfffd1c5bb4f1d549ca0bc6e454f439041d5798c7499c32b86a94432de15c` |

| `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` | Place fanout validation under the authored transition.fanout schema and assert its exact diagnostic path. | `6c23c7dc36daebba0b472b1bf19ba4f7bf5ef06f70a031c7a19f602f0081b0f7` | `85c81342039531cffc278a3df06b41654b34121d5296db18fb89342f44e4176a` |

| `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` | Check runtime template rendering against available input; this fixture has no prior-message latest payload. | `8afcfffd1c5bb4f1d549ca0bc6e454f439041d5798c7499c32b86a94432de15c` | `c008176a3a9929fa2d0d93862f067f227a92e5804f6d6cdec5582f238cf7aed3` |

| `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` | Verify provider overflow classification reaches both persisted step execution and session failure records. | `85c81342039531cffc278a3df06b41654b34121d5296db18fb89342f44e4176a` | `649d654a10aa341bd6f6890e0d8cb67ae85acd07196d72c44e591f05cfbba4f7` |

| `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` | Keep the in-scope runner regression compilable by asserting its failed step status and reason; the absent per-step failureKind field requires out-of-plan runtime-store changes and is recorded as a blocker. | `649d654a10aa341bd6f6890e0d8cb67ae85acd07196d72c44e591f05cfbba4f7` | `ad12220fe4dc4637ae20b662def3758ce708770908ec926b2d15a9fc5b5956e7` |

## Handoff / blocker

The accepted fanout contract requires both the failed step execution and the session to persist `failureKind: promptTooLarge`. `WorkflowStepExecution` in `Sources/RielaCore/RuntimeSession.swift` has no `failureKind` property, while `WorkflowStepExecutionUpdateInput.failureKind` is stored at the session level. Implementing per-step persistence requires edits to `Sources/RielaCore/RuntimeStore.swift` and its persistence implementation(s), which are not in this plan's `writePaths`. Stop here pending a checkpoint amendment that authorizes the execution model and runtime-store persistence paths. Resume criterion: amend `pog-01-contracts` writePaths (or assign a follow-up plan) for those files, then add the per-step field end to end and rerun the focused verification.

Earlier verification: arm64 `swift build` passed (exit 0). The focused 7-test run passed before the runner persistence assertion was added; it is not current-source evidence. The required broader test command then failed to compile solely because the model lacks `WorkflowStepExecution.failureKind` (exit 1), recorded at `tmp/prompt-overflow/pog-01-contracts/test-required-final.log`. An earlier broader run also found a misplaced validation test fixture; it was corrected, and the narrowed current-source contracts/view/prompt suites passed (7 tests, 0 failures) before the final runner assertion.

## Final Step 6 completion addendum (2026-10-22)

The operator amendment to `impl-plans/active/prompt-overflow-guard-01-contracts.md` and `impl-plans/active/prompt-overflow-dispatch.json` added `RuntimeStore.swift`, `RuntimeStorePublicationTransactions.swift`, and `SQLiteWorkflowRuntimePersistenceStore.swift` to this plan's `writePaths`. The earlier blocker above is resolved for this run: `WorkflowStepExecution.failureKind` is optional/default nil, `InMemoryWorkflowRuntimeStore.updateStepExecution` assigns `WorkflowStepExecutionUpdateInput.failureKind`, and the SQLite store persists `WorkflowSession` through its existing Codable JSON snapshot encoder/decoder. No schema or direct SQLite codec edit was needed. The runner regression now confirms both the step execution and session retain `promptTooLarge`; an unrelated provider error stays `adapterFailure` in both records.

The separate [mid] recovery-gate finding from session-475 remains allocated to downstream `pog-04` by the accepted contract and this plan's explicit non-goals. No recovery consumer paths were edited here. `pog-01-contracts` owns the shared failure-kind contract and producer classification; it does not own recovery eligibility.

The validation self-check also found and fixed an early return that suppressed later fanout diagnostics after an invalid `observationInlineLimit`. A regression now confirms that the inline-limit and invalid `itemsFrom` diagnostics are both returned.

Final post-edit SHA-256 values for files with changes in this continuation:

| File | Pre-edit SHA-256 | Final SHA-256 |
|---|---|---|
| `Sources/RielaCore/RuntimeSession.swift` | `26314433cf578447a23cced4ce3b88627cd7d98d3ece0de8941595b47da7aabd` | `d5ee26015c07ddba555efecb8a930f74b6ac10e3ca89c4859c6f5cdb145ca7eb` |
| `Sources/RielaCore/RuntimeStore.swift` | `507b45fb3000a8844788c7d5d69db51661cfd2247674be2e25d1ceb66f1b11a6` | `6fe49c2c6c4b54e888182345cac8e4fa220cd05bd28f08f1f4f4a60f0a9c2b74` |
| `Sources/RielaCore/WorkflowRawValidation.swift` | `add2727cfb443f6a4fcc9b9996184ca59c42577d293f02c4b75a02fb992cc481` | `f7feb757cbff25e5c82aeb504aedb7896b57b472a44b05123c12abdb0106c550` |
| `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` | `ad12220fe4dc4637ae20b662def3758ce708770908ec926b2d15a9fc5b5956e7` | `74d3fbd9a04a94b42f8cf61c92a3c7c4c51662157607570cfce8b7a7def033ab` |

The test-file edit intention and intermediate hashes for its additional regressions/fixes are recorded in `tmp/prompt-overflow/pog-01-contracts/edit-intentions.md`. All initial and continuation edits have a corresponding intention entry. `RuntimeStorePublicationTransactions.swift` and `SQLiteWorkflowRuntimePersistenceStore.swift` were inspected but unchanged: normal adapter failure publication uses `updateStepExecution`, and SQLite snapshot persistence encodes/decodes the full `WorkflowSession` value.

Final-source required gates (run in foreground from arm64 shell):

| Command | Exit | Evidence |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `tmp/prompt-overflow/pog-01-contracts/build.log`; `Build complete! (12.79s)` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptOverflowContractsTests\|RuntimeVariablesPromptViewTests\|RuntimeVariablesPromptingTests\|DeterministicWorkflowRunnerTests\|WorkflowOutputContractPreflightTests"'` | 0 | `tmp/prompt-overflow/pog-01-contracts/test.log`; 51 tests, 51 passed, 0 failures |
| selected-file `swiftlint lint --strict --quiet --no-cache` via `tmp/prompt-overflow/pog-01-contracts/changed-swift-files.nul` | 0 | `tmp/prompt-overflow/pog-01-contracts/lint.log`; manifest contains 15 changed Swift paths, including all four new Swift files |
| `grep -n 'adapterFailureKind' Sources/RielaCore/RuntimePublication.swift Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift` | 0 | `tmp/prompt-overflow/pog-01-contracts/grep.log`; exactly 3 call sites |
| `git diff --check` | 0 | no whitespace errors |

Earlier attempts are retained, not treated as current-source passes: `test-first-attempt.log`, `test-session-id-attempt.log`, and `test-backend-preflight-attempt.log` each record 51 tests with 2 failures due to the test looking up the wrong session/preflight identity; the fixture now uses the injected adapter and the runner's `runner-session-1` record, and the final test log passes. `lint-first-attempt.log` preserves the two initial strict lint diagnostics; both were fixed and the final exact-manifest lint log passes. No unresolved assigned-plan implementation or verification task remains.


## Step 6 current-source verification rerun (2026-10-22)

The shared working tree was re-read and the assigned plan's final-source gates were rerun in the foreground from arm64. These logs are separate from earlier attempts and preserve their evidence. Changed Swift paths were selected into `tmp/prompt-overflow/pog-01-contracts/changed-swift-files-step6.nul` (15 NUL-delimited paths).

| Command | Exit | Observed result | Log |
|---|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build complete (8.72s) | `tmp/prompt-overflow/pog-01-contracts/build-step6-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptOverflowContractsTests|RuntimeVariablesPromptViewTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests"'` | 0 | 51 tests, 51 passed, 0 failures | `tmp/prompt-overflow/pog-01-contracts/test-step6-final.log` |
| selected-file `swiftlint lint --strict --quiet --no-cache` through `changed-swift-files-step6.nul` | 0 | 15 changed Swift paths; no diagnostics | `tmp/prompt-overflow/pog-01-contracts/lint-step6-final.log` |
| `grep -n 'adapterFailureKind' Sources/RielaCore/RuntimePublication.swift Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift` | 0 | Exactly 3 classifier call sites | `tmp/prompt-overflow/pog-01-contracts/grep-step6-final.log` |
| `git diff --check` | 0 | No whitespace errors | `tmp/prompt-overflow/pog-01-contracts/diff-check-step6-final.log` |

Progress pre-edit SHA-256: `f3c39174306c9e2f3dd927d97072bbffddf7f67ee29262c8a2dbca99b50fddb3`.

The selected-file SwiftLint gate was then repeated with `set -o pipefail` inside the arm64 zsh invocation; observed exit was 0 for the same 15-path manifest. Authoritative rerun log: `tmp/prompt-overflow/pog-01-contracts/lint-step6-final-verified.log`.


## POG01-TI-1 test-integrity repair (2026-10-22)

Addressed the mid finding with a test-only correction in `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift`; no `Sources/` files changed in this repair. The previously vacuous single-step test is now two producer→consumer runner passes. A private adapter publishes `{big: marker, small: "s"}` from the producer, with a marker longer than 100 KB; request variables contain only `workflowInput.k`. The default consumer prompt asserts one marker occurrence plus `$rielaSameAs` and `$rielaElidedKeys`. The templated consumer asserts `promptText == "s|value"`. The test also confirms the producer's accepted output and delivered consumer message carry the marker.

The first fixture run showed `AdapterExecutionInput.node.id` was `producer`/`consumer`, matching the step IDs. The final fixture aligns step and node IDs as `producer-node`/`consumer-node`, allowing the per-node adapter branch to publish the producer payload.

Test file SHA-256 transition: `c008176a3a9929fa2d0d93862f067f227a92e5804f6d6cdec5582f238cf7aed3` → `12a9ff769f9be014483b74c2d452368e620a4f178c2b5c045fc0e0e60cd0f751`. Intermediate edit intentions and hashes are in `tmp/prompt-overflow/pog-01-contracts/edit-intentions.md` and the `POG01-TI-1-*-intention.md` evidence files.

Final current-source verification (foreground arm64):

| Command | Exit | Observed result | Complete log |
|---|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 \| tee tmp/prompt-overflow/pog-01-contracts/build-ti1-final.log'` | 0 | Build complete (5.38s) | `tmp/prompt-overflow/pog-01-contracts/build-ti1-final.log` |
| `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "PromptOverflowContractsTests\|RuntimeVariablesPromptViewTests\|RuntimeVariablesPromptingTests\|DeterministicWorkflowRunnerTests\|WorkflowOutputContractPreflightTests" 2>&1 \| tee tmp/prompt-overflow/pog-01-contracts/test-ti1-verified.log'` | 0 | 51 tests passed, 0 failures; rewritten runner test listed as passed | `tmp/prompt-overflow/pog-01-contracts/test-ti1-verified.log` |
| `arch -arm64 /bin/zsh -lc 'set -o pipefail; xargs -0 swiftlint lint --strict < tmp/prompt-overflow/pog-01-contracts/changed-swift-files-ti1.nul 2>&1 \| tee tmp/prompt-overflow/pog-01-contracts/lint-ti1.log'` | 0 | Nonempty 15-path manifest; 0 violations, 0 serious | `tmp/prompt-overflow/pog-01-contracts/lint-ti1.log` |
| `git diff --check` | 0 | No whitespace errors | `tmp/prompt-overflow/pog-01-contracts/diff-check-ti1.log` |

Superseded test-only fixture attempts are preserved: `test-ti1.log` and `test-ti1-final.log` each ran 51 tests with 2 failures; `test-ti1-diagnostic.log` ran 51 with 4 failures; `test-ti1-nodeids.log` ran 51 with 5 failures. The final fixture correction resolves those failures; these logs are not passing evidence. Progress pre-edit SHA-256: `9e6f4b090f2fabebb9607683a61c1ad3f1139e9acb659af85dc2dfd7ca36f2d5`.
