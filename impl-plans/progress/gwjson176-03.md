# gwjson176-03 progress

Status: implementation complete; focused verification passed; pending independent test-integrity and adversarial review.

Issue: tacogips/riela#176. Workflow mode: opus-luna-design-and-implement-review-loop native fanout branch `gwjson176-03` (shared-branch-implementation, index 1). Codex agent: primary implementation owner.

Dependency readiness: `gwjson176-02` is present in the implementation item's acceptedPlanIds. Dependency: accepted.

## Implemented

- Added `XGatewayFailureCategory.classify` in `Sources/RielaCLI/XGatewayProviderFailureOutput.swift` with the closed R2 first-match table. Only `rate-limited` and `transient` report retryable.
- Added finite diagnostic output for recognized X `.providerError` failures in both embedded and container X readers when `providerFailure: "output"` is selected. The default and explicit `"fail"` leave provider error codes/messages unchanged.
- Output mode leaves timeout, policyBlocked, invalidOutput, cancellation, and failures without an allowlisted diagnostic code thrown. No retry metadata or implicit retry was added. `XGatewayReaderSDK.arguments` still emits `--retry 0`.
- Success outputs in output mode set all four X failure when-flags false. `BuiltinPostprocessPlan.apply` skips shaping for provider-failed outputs and leaves `processed` absent.
- The gwjson176-02 providerFailure validation row remains covered by `Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift` and passed in the regression filter; no edit outside this plan's ownership was needed.

Pinned unchanged default provider error message:

`X reader SDK query failed (code=PERMISSION_DENIED, httpStatus=403, providerProblem=spend-cap-reached)`

## Per-edit source hashes

Initial hashes were recorded before edits in `tmp/issue-176/gwjson176-03/pre-edit-hashes.txt`. The latest immutable snapshot was `tmp/riela-fanout/F5C74B9D-DE7A-4E71-9000-5DB0AC8812A8/48229D22-75EF-4EA1-B721-A580EEA7E23F.json`; initially present shared sources matched it. New output and test files were absent at the pre-edit boundary.

| Path | Pre-edit SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCLI/XGatewayProviderFailureOutput.swift` | absent | `2aeb65df7704a1387fd29c2ed241903994b19291e3615c0a8015aaab6cf66a9d` |
| `Sources/RielaCLI/ProductionNodeAdapter+XGatewaySDKAddon.swift` | `424cbd21cfef3056e442199ce572fbb4d95067a03c7235ff035a8f75dbcf349a` | `dde54e69ae0f5660b44a61beab2e90e319c437f42cb504b957855c579b3c25ae` |
| `Sources/RielaCLI/BuiltinPostprocessPlan.swift` | `dc811b49ad92fee8d322929f67acb76315e2a694ef30679a1126a9890fc57475` | `bd91724342b770d91c6f35db5a7aefd93ea1e4fa564ce355c736972e42e89bb9` |
| `Sources/RielaCLI/ContainerGatewayAddonExecutor.swift` (shared path) | `1193137353ab25059b89bf48102567ebc2a5e7b75282fdbd3224933b1433087e` | `dd0e3d5e1a5b57b153a1c5b33fda3ea12d6482faa66a8c0519be2be75711381b` |
| `Tests/RielaCLITests/XGatewayProviderFailureOutputTests.swift` | absent | `8dd716dfdf0bfe075d9cf4677245beb17bb40dfab1318d586bfd90fdda35c5ee` |
| `impl-plans/active/gwjson176-03-x-failure-output.md` | `dbaf5bffe9c4366b3e28f35d8c8386e32da1f39cca76abea24858306419ef684` | `e85d2ed6fcc467034d122e3f264e4f5c4faccf3592271028970ccfa9ed40d37d` |

Per-edit intent is preserved in `tmp/issue-176/gwjson176-03/edit-intent-001.md`; final hashes are also in `tmp/issue-176/gwjson176-03/post-edit-hashes.txt`.

## Verification

| Command | Exit | Tests run | Failures | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-03/build-final-rerun.log 2>&1'` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-03/build-final-rerun.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayProviderFailureOutputTests > tmp/issue-176/gwjson176-03/failure-output-final-rerun-02.log 2>&1'` | 0 | 7 | 0 | `tmp/issue-176/gwjson176-03/failure-output-final-rerun-02.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|XGatewaySDKAddonTests|LegacyGatewayJSONRequestTests|KaibaGatewayPostprocessTests|BuiltinGatewayJSONRequestTests|JSONDataTransform|WorkflowGatewayValidationTests' > tmp/issue-176/gwjson176-03/regression-final-rerun-02.log 2>&1"` | 0 | 56 | 0 | `tmp/issue-176/gwjson176-03/regression-final-rerun-02.log` |
| `changed_swift_manifest=tmp/issue-176/gwjson176-03/changed-swift-files.nul && if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest" > tmp/issue-176/gwjson176-03/lint-final-rerun.log 2>&1; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.' > tmp/issue-176/gwjson176-03/lint-final-rerun.log; fi` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-03/lint-final-rerun.log` |
| `if rg -n 'isRetryable' Sources/RielaCLI/XGatewayProviderFailureOutput.swift > tmp/issue-176/gwjson176-03/no-is-retryable.log; then exit 1; else grep_status=$?; test "$grep_status" -eq 1 && printf '%s\\n' 'No isRetryable references.' > tmp/issue-176/gwjson176-03/no-is-retryable.log; fi` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-03/no-is-retryable.log` |
| `rg -n 'return \\["graphql", "query", document, "--json", "--retry", "0"' Sources/RielaCLI/ProductionNodeAdapter+XGatewaySDKAddon.swift > tmp/issue-176/gwjson176-03/retry-zero.log` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-03/retry-zero.log` |

The required focused test gate has positive counts and zero failures. The strict SwiftLint gate used the exact five-file NUL manifest `tmp/issue-176/gwjson176-03/changed-swift-files.nul`.

## Prior attempts (superseded)

- `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayProviderFailureOutputTests > tmp/issue-176/gwjson176-03/failure-output.log 2>&1'` exited 1 before tests because of initializer argument order; corrected.
- `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayProviderFailureOutputTests > tmp/issue-176/gwjson176-03/failure-output-rerun-01.log 2>&1'` exited 1 before tests because the actor-isolated count was used in an XCTest autoclosure; corrected.
- `arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayProviderFailureOutputTests > tmp/issue-176/gwjson176-03/failure-output-final.log 2>&1'` exited 1 with one fixture failure; corrected the mocked X reader success envelope. Current-source rerun passed 7/0.

No blocker dependencies. Residual risk: independent test-integrity/adversarial review and serial integration review are downstream workflow steps.
