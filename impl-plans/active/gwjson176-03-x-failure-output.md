# GWJSON176-03: finite X failure metadata through opt-in `providerFailure: "output"`

```json
{
  "planId": "gwjson176-03",
  "planPath": "impl-plans/active/gwjson176-03-x-failure-output.md",
  "dependsOn": ["gwjson176-02"],
  "writePaths": [
    "Sources/RielaCLI/XGatewayProviderFailureOutput.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+XGatewaySDKAddon.swift",
    "Sources/RielaCLI/BuiltinPostprocessPlan.swift",
    "Tests/RielaCLITests/XGatewayProviderFailureOutputTests.swift",
    "impl-plans/active/gwjson176-03-x-failure-output.md",
    "impl-plans/progress/gwjson176-03.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/ContainerGatewayAddonExecutor.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/ContainerGatewayAddonExecutor.swift", "intendedEdit": "For gateway == .xRead only: parse XGatewayProviderFailureMode before launch, and wrap the existing execute body so an AdapterExecutionError(.providerError) with recognized diagnostics becomes the failure output in output mode. The gwjson176-02 operationDocument/legacyModeIssue extraction stays untouched."}
  ],
  "progressLog": "impl-plans/progress/gwjson176-03.md",
  "status": "planned; design accepted (Step 3 comm-008838)"
}
```

## Authority and intent

- Design rule **R2**.
- User QA item 2: X-only, opt-in.

Today every X provider failure is thrown as an opaque `providerError` whose
message ends with an allowlisted diagnostic suffix, for example
` (code=..., providerProblem=spend-cap-reached, ...)`. Workflows cannot branch
on that.

With `config.providerFailure: "output"`, both X readers
(`riela/x-gateway-reader` and `riela/x-gateway-read`) instead return a
completed output with:

- a closed category;
- a `retryable` flag;
- the allowlisted diagnostics;
- the when-flags `providerFailed`, `providerRetryable`, `spendCapReached` and
  `rateLimited`, so labeled transitions can branch.

The default (`"fail"`, or the key absent) is byte-identical to today.

## Non-goals

- No retry anywhere: X stays `--retry 0`, `AdapterExecutionError.isRetryable`
  stays unset, and no loop is added.
- No change to failure messages or `GatewayFailureDiagnostics`. Reuse the
  existing `GatewayFailureDiagnostics.fields(readerMessage:)` to recover the
  allowlisted fields from the thrown message. This is the pattern in
  `Sources/RielaCLI/XLookupCollection.swift:75`, and it keeps the suffix text
  unchanged by construction.
- No failure output for other gateways, and none for writes.
- No change to usage or user-cache recording.

## Write ownership

writePaths and sharedPaths as in the JSON header.

## File-level changes

1. **`XGatewayProviderFailureOutput.swift` (new).**
   - `enum XGatewayFailureCategory: String, Sendable` with the cases
     `spend-cap-reached`, `rate-limited`, `auth`, `permission`,
     `invalid-request`, `not-found`, `transient` and `unknown`.
     `var retryable: Bool` is true only for `rate-limited` and `transient`.
   - `static func classify(_ diagnostics: JSONObject) -> XGatewayFailureCategory`
     follows the design's first-match table exactly, in this order:
     1. `providerProblem` is `spend-cap-reached`/`usage-capped`, or
        `providerReason` is `usage-capped`.
     2. `code` is `RATE_LIMITED`/`PROVIDER_RATE_LIMITED`, `providerProblem` is
        `rate-limit-exceeded`, `classification` is `rate_limit`, or
        `httpStatus` is 429.
     3. Auth: `code` has the prefix `AUTH_` or is `CREDENTIAL_NOT_FOUND`,
        `classification` is `auth`, or the status is 401.
     4. Permission: `PERMISSION_DENIED`, `ACCESS_MODE_INSUFFICIENT`,
        `classification` `permission`, `providerProblem` in
        {`client-forbidden`, `not-authorized-for-resource`,
        `unsupported-authentication`, `insufficient-scope`}, or the status is
        403.
     5. Invalid request: `VALIDATION_ERROR`, `INVALID_ARGUMENT`,
        `CONFIG_INVALID`, `classification` `validation`, `providerProblem`
        `invalid-request`, or the status is 400 or 422.
     6. Not found: `RESOURCE_NOT_FOUND`, `providerProblem` `resource-not-found`,
        or the status is 404.
     7. Transient: `NETWORK_FAILURE`; `UPSTREAM_FAILURE` with no `httpStatus`
        or a status ≥ 500; `classification` `network`/`upstream`; or
        `retryable == true`.
     8. Otherwise `unknown`.
   - `func xGatewayProviderFailureOutput(_ error: AdapterExecutionError, input: WorkflowAddonExecutionInput, provider: String) -> AdapterExecutionOutput?`
     - Returns nil unless `error.code == .providerError` and
       `GatewayFailureDiagnostics.fields(readerMessage: error.message)["code"]`
       is a string.
     - Otherwise returns:
       - `provider`: the reader's normal provider string;
       - `model`: the add-on name;
       - `promptText`: `""`;
       - `completionPassed`: `true`;
       - `payload`: `{"status":"provider-failed","addon":<name>,"stepId":<stepId>,"xGateway":{"failure":{"category":..,"retryable":..,"diagnostics":<fields>}}}`;
       - `when`: `providerFailed: true`, `providerRetryable`,
         `spendCapReached` and `rateLimited`, each with its boolean.
   - `func xGatewayMarkProviderSuccess(_ output: inout AdapterExecutionOutput)`
     sets all four flags to false.
2. **`ProductionNodeAdapter+XGatewaySDKAddon.swift`.**
   - In `executeXGatewaySDKAddon`, parse the mode first:
     `let mode = try XGatewayProviderFailureMode.parse(input.addon.config ?? [:])`.
     An invalid value throws before any SDK or cache effect.
   - Run the existing engine call inside `do`/`catch`. In `.output` mode, a
     caught `AdapterExecutionError` for which `xGatewayProviderFailureOutput`
     returns non-nil returns that output. Every other error is rethrown
     unchanged, including `.timeout`, `.policyBlocked`, `.invalidOutput`,
     `CancellationError` and errors without diagnostics.
   - On success in `.output` mode, mark success.
3. **`ContainerGatewayAddonExecutor.swift` (shared).** Make the same change in
   `execute` for `gateway == .xRead`: parse the mode at the very top, before
   the version check, and wrap the rest of the body. `.gmailRead` is
   untouched. This covers both call sites (`ProductionNodeAdapter.swift:541`
   and `BuiltinAddonContainerResolver.swift:90`). Use the existing container
   provider string `"container-addon"`.
4. **`BuiltinPostprocessPlan.swift`.** In `apply`, when a program exists and
   `original.when["providerFailed"] == true`:
   - set `payload.postprocess = {"status":"skipped"}`;
   - set `postprocessPassed` and `postprocessFailed` to false;
   - add no `processed`;
   - return.

   All other behavior is unchanged.

## Pitfalls

- `fields(readerMessage:)` requires the message to end with `)` and contain
  ` (code=`. The embedded message is
  `"X reader SDK query failed[ usageCacheStatus=..] (code=...)"`, and the
  container message is `"... container failed with exit code N ... (code=...)"`.
  Both qualify only when the SDK emitted an allowlisted envelope. A missing
  image, with no suffix, keeps throwing.
- Do not catch the node deadline: `localGatewayRunWithDeadline` throws
  `.timeout`, which must stay thrown.
- Usage-cache observations are recorded before the throw; keep that order.
- The default mode must produce identical output and errors. Pin one existing
  failure message string in a test, and compare outputs with and without an
  explicit `"fail"`.
- Do not set `isRetryable` or `retryAfter` on any error.
- The mock path (`ProductionNodeAdapter.swift` around line 262) applies
  `BuiltinPostprocessPlan.apply` to mock outputs. A mock that declares
  `when.providerFailed: true` must also skip shaping.

## Test cases (`XGatewayProviderFailureOutputTests`)

- `classify` table, one row per rule plus these precedence rows:
  - `{providerProblem: spend-cap-reached, httpStatus: 403}` → spend-cap-reached, false;
  - `{code: UPSTREAM_FAILURE, httpStatus: 429}` → rate-limited, true;
  - `{code: UPSTREAM_FAILURE, httpStatus: 400}` → invalid-request, false;
  - `{code: UPSTREAM_FAILURE, httpStatus: 503}` → transient, true;
  - `{code: NETWORK_FAILURE}` → transient, true;
  - `{code: INTERNAL_ERROR}` → unknown, false;
  - `{code: AUTH_EXPIRED}` → auth, false.
- Embedded, with an SDK stub returning a non-ok envelope
  (`code: PERMISSION_DENIED, httpStatus: 403, providerProblem: spend-cap-reached`)
  and `providerFailure: "output"` → completed output, category
  `spend-cap-reached`, `providerFailed` and `spendCapReached` true,
  `providerRetryable` false, 1 SDK call.
- The same envelope in the default mode → throws `.providerError`, and the
  message equals the string pinned before this change.
- Explicit `"fail"` → identical to the default.
- `providerFailure: "retry"` → `.policyBlocked`, 0 SDK calls. Add the matching
  validate row (production context error at `providerFailure`). This
  completes the row gwjson176-02 marked pending.
- Output mode on success → the four flags false, and postprocess runs
  (`postprocessPassed` true).
- Output mode with postprocess on a failure → `postprocess.status == "skipped"`,
  both postprocess flags false, no `processed`.
- Container, with a recording runner returning a non-zero exit and a
  `RATE_LIMITED` stderr envelope, in output mode → category `rate-limited`,
  retryable true, 1 launch.
- Container exit 125 with empty output, in output mode → still throws
  `.providerError`.
- An expired deadline in output mode → throws `.timeout`.
- A mock-scenario response with `when: {providerFailed: true}` and a
  postprocess program → shaping skipped.

## Execution rules

- Same branch and working directory. No worktrees or git operations beyond
  read-only commands.
- Fresh-read every file before editing and record pre/post sha256. On drift,
  stop and record it for serial repair.
- Logs go under `tmp/issue-176/gwjson176-03/`.
- Use `arch -arm64 /bin/zsh -lc`, in the foreground.

## Verification (each exit 0; testsRun > 0; failureCount 0)

```
mkdir -p tmp/issue-176/gwjson176-03
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-03/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayProviderFailureOutputTests > tmp/issue-176/gwjson176-03/failure-output.log 2>&1'
arch -arm64 /bin/zsh -lc "swift test --filter 'XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|XGatewaySDKAddonTests|LegacyGatewayJSONRequestTests|KaibaGatewayPostprocessTests|BuiltinGatewayJSONRequestTests|JSONDataTransform|WorkflowGatewayValidationTests' > tmp/issue-176/gwjson176-03/regression.log 2>&1"
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/XGatewayProviderFailureOutput.swift Sources/RielaCLI/ProductionNodeAdapter+XGatewaySDKAddon.swift Sources/RielaCLI/BuiltinPostprocessPlan.swift Sources/RielaCLI/ContainerGatewayAddonExecutor.swift > tmp/issue-176/gwjson176-03/lint.log 2>&1'
```

## Done criteria

- [ ] All test cases above exist and pass. The regression filter shows no
      failures.
- [ ] `git grep -n "isRetryable" Sources/RielaCLI/XGatewayProviderFailureOutput.swift`
      returns nothing.
- [ ] `--retry 0` is unchanged in `XGatewayReaderSDK.arguments`.
- [ ] The progress log has verification records with integer exitStatus,
      testsRun and failureCount, plus per-edit hashes.

## Progress log expectations

`impl-plans/progress/gwjson176-03.md` contains:

- status;
- per-edit hashes, including the shared container file;
- the pinned default message used by the identity test;
- verification records;
- blockers as dependency objects;
- residual risks (no leading severity word).
