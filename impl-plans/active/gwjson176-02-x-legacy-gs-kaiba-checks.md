# GWJSON176-02: X / legacy-container / Google Service / Kaiba static checks, X path review

```json
{
  "planId": "gwjson176-02",
  "planPath": "impl-plans/active/gwjson176-02-x-legacy-gs-kaiba-checks.md",
  "dependsOn": ["gwjson176-01"],
  "writePaths": [
    "Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift",
    "Sources/RielaCLI/BuiltinGatewayJSONRequest+XCompatibility.swift",
    "Sources/RielaCLI/XGatewayProviderFailureMode.swift",
    "Sources/RielaCLI/XGatewayOperationCatalog.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift",
    "Sources/RielaCLI/ContainerGatewayAddonExecutor.swift",
    "Sources/RielaKaibaAddons/KaibaAddonInputs.swift",
    "Tests/RielaCLITests/XGatewayJSONDocumentGoldenTests.swift",
    "Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift",
    "Tests/RielaKaibaAddonsTests/KaibaWorkflowGatewayValidationTests.swift",
    "impl-plans/active/gwjson176-02-x-legacy-gs-kaiba-checks.md",
    "impl-plans/progress/gwjson176-02.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/BuiltinGatewayJSONRequest+Inline.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/BuiltinGatewayJSONRequest+Inline.swift", "intendedEdit": "Only if the R3 fact check gives outcome A: add a defaulted maximumBytes parameter to inlineReaderDocument (default ContainerGatewayAddon.legacyDocumentByteLimit) so the embedded X reader keeps its 1,000,000-byte bound. No other edit; untouched for outcomes B and C."}
  ],
  "progressLog": "impl-plans/progress/gwjson176-02.md",
  "status": "planned; design accepted (Step 3 comm-008838)"
}
```

## Authority and intent

- Design: `design-docs/specs/design-gateway-sdk-addons.md`, "#176 remainder",
  rules **R1** (the X, legacy container, Google Service and Kaiba rows) and
  **R3** (X request path review and the SDK fact check).
- Depends on the contract from gwjson176-01:
  - `WorkflowGatewayRequestIssue`;
  - `BuiltinGatewayRequestChecks.leafConfig`, `containsTemplate`,
    `isExactPlaceholder` and `catalogArgumentNameIssues`;
  - the stub `extendedIssues(_:leaf:)`, which this plan replaces.

The goal is that `riela workflow validate` rejects malformed requests for the
following add-ons, using the same pure checks the runtime runs before any
effect:

- `riela/x-gateway-reader`
- `riela/x-gateway-read`
- `riela/gmail-gateway-read`
- `riela/google-service-gateway-read` / `-write`
- named `kaiba/*` nodes with `config.arguments`

The plan also reviews the X-only request path and records which code stays.

## Non-goals

- No runtime behavior change for valid or invalid requests. The same errors,
  codes and order must result.
- No `providerFailure` runtime behavior; gwjson176-03 owns it. This plan only
  pins the parse function and the static check.
- No SDL type parser in riela. No edits to x-gateway, gateway-sdk-kit or other
  SDK repositories, or to `Package.resolved`.
- No retirement of nested `select` and no deprecation warning.
- No changes to `BuiltinGatewayRequestChecks.swift`. It is owned by
  gwjson176-01 and is read-only here.

## Write ownership

writePaths and sharedPaths: as listed in the JSON header. The only shared
path is `BuiltinGatewayJSONRequest+Inline.swift`, and only for outcome A.

## Pinned symbols

- `Sources/RielaCLI/XGatewayProviderFailureMode.swift` (new):
  - `enum XGatewayProviderFailureMode: String, Sendable { case fail, output }`
  - `static func parse(_ config: JSONObject) throws -> XGatewayProviderFailureMode`
  - Behavior: a missing value gives `.fail`. A string `"fail"` or `"output"`
    gives that mode. Anything else throws `AdapterExecutionError(.policyBlocked, "config.providerFailure must be \"fail\" or \"output\"")`.
  - gwjson176-03 calls this at runtime.
- `Sources/RielaCLI/BuiltinGatewayJSONRequest+XCompatibility.swift`:
  - `struct XGatewayJSONShape { var operation: String; var selection: JSONObject }`
  - `func xGatewayJSONShape(config: JSONObject, addonName: String) throws -> XGatewayJSONShape?`
    returns nil in legacy mode.
  - `func xGatewayJSONDocument(config: JSONObject, variables: JSONObject, addonName: String) throws -> String?`
  - `builtinGatewayXJSONDocument(_ input:)` keeps its signature and delegates
    to `xGatewayJSONDocument(config:variables: addonVariables(for: input), addonName:)`.
- `Sources/RielaCLI/ContainerGatewayAddonExecutor.swift`:
  - `static func operationDocument(gateway: ContainerGatewayAddon, config: JSONObject, variables: JSONObject, addonName: String) throws -> String?`
    contains the current operation-mode branch and the 120,000-byte limit. It
    returns nil in legacy mode.
  - `static func legacyModeIssue(config: JSONObject, addonName: String) throws`
    contains the current `queryTemplate` guard.
  - `execute` calls both. The legacy template rendering stays in `execute`.
- `Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift`:
  - `GatewayAddonValues` becomes internal (file-level `struct`, not
    `private`).
  - Add an internal `enum GoogleServiceOperationRequest` with one case per
    operation, for example
    `.listServices(ListServicesRequest)`, `.getService(project:service:)`,
    `.getOperation(name:)`, `.enable(project:service:mutation:)`,
    `.disable(project:service:disableDependents:checkUsage:mutation:)`,
    `.batchEnable(project:services:mutation:)`.
  - The mutation payload holds `wait`, `timeoutSeconds` and
    `pollIntervalSeconds` exactly as the current accessors parse them. The
    deadline clamp stays in `invoke`.
  - `static func parse(operation: String, values: GatewayAddonValues, addonName: String) throws -> GoogleServiceOperationRequest`
    is the only place that reads values. `invoke` switches on its result.
  - `static func requestShapeIssue(capability: BuiltinGoogleServiceGatewayAddon, config: JSONObject, inputs: JSONObject?, addonName: String) throws`
    covers the non-empty operation, the tier allowlist, and in arguments mode
    the key-subset and inputs rule and the argument-name table. The runtime
    calls it first.
- `Sources/RielaKaibaAddons/KaibaAddonInputs.swift`:
  - `public enum KaibaNestedArgumentRules`
  - `public static let connectionKeys: Set<String>`, `literalGraphQLKeys`,
    `graphQLDocumentAddonNames`
  - `public static func issues(addonName: String, config: JSONObject, inputs: JSONObject?) -> [WorkflowGatewayRequestIssue]`
  - `KaibaAddonInputs.init` uses the same constants. Keep its checks in the
    current order and with the same messages.

## File-level changes

1. **Golden tests first.** Write
   `Tests/RielaCLITests/XGatewayJSONDocumentGoldenTests.swift` against the
   **unchanged** code. Record the actual documents and pin them as string
   literals. Cases:
   - (a) `homeTimeline`; selection `posts.id`, `posts.author.username`,
     `pageInfo.nextToken`; arguments `maxResults: 25`, `paginationToken: null`.
   - (b) `searchPosts` with the nested `select` equivalent to (a)'s
     selection. Assert it equals the `selection` form.
   - (c) arguments with quotes, a newline and literal `{{c}}` text in a value.
   - (d) a nested object argument and an array argument.
   - (e) integral `25.0` renders as `25`.

   Then refactor and re-run. The goldens must stay byte-identical.
2. **X shape/render split** (XCompatibility). Move the operation and selection
   checks into `xGatewayJSONShape`. Keep the current check order:
   - arguments/select/selection without an operation;
   - mixing with `queryTemplate`, `variablesTemplate` or `nowVariables`;
   - a literal operation;
   - the name rule;
   - `select` XOR `selection`;
   - selection parsing and depth;
   - only then argument rendering.

   Messages stay unchanged.
3. **`extendedIssues`** replaces the stub. Dispatch by name:
   - **X readers (both names).**
     - Run `XGatewayProviderFailureMode.parse(leaf)`. A throw gives an issue
       at `providerFailure`.
     - Run `xGatewayJSONShape(config: leaf, ...)`. A throw gives an issue at
       `""` with the thrown message.
     - If the shape is non-nil and the arguments are literal (`containsTemplate`
       false and not an exact placeholder), run
       `xGatewayJSONDocument(config: leaf, variables: [:], ...)`. A throw
       gives an issue at `""`.
     - Then `riela/x-gateway-reader` (embedded only) applies
       `xGatewayRejectHostMediaArguments(document)` and gives an issue at
       `arguments`. `riela/x-gateway-read` (container only) checks UTF-8 size
       > `ContainerGatewayAddon.legacyDocumentByteLimit` and gives an issue
       at `""` with the runtime message.
     - Templated, embedded only: any operation name, selection path component
       or argument key at any depth equal to `mediaRootDir` gives an issue at
       `arguments`. This matches the runtime name-token rule.
     - Container legacy mode (no operation): run `legacyModeIssue`; a throw
       gives an issue at `""`.
   - **`riela/gmail-gateway-read`.**
     - Operation mode, literal: run `operationDocument(gateway: .gmailRead, config: leaf, variables: [:], ...)`.
     - Operation mode, templated: if the operation is not in the reader
       catalog (`BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog`),
       give an issue at `operation` with
       `unknown operation '<op>'`. Otherwise use
       `catalogArgumentNameIssues`. In both cases, any present
       `queryTemplate`, `variablesTemplate`, `command`, `argsTemplate` or
       `select` gives an issue at that key with `is not allowed in this mode`.
     - Legacy mode: `legacyModeIssue`.
   - **Google Service.** Run `requestShapeIssue`. Then, if `arguments` is
     present and literal, run `parse(operation:values: GatewayAddonValues(config: renderedArguments, variables: [:]))`.
     Use `renderGatewayJSONArguments(leaf["arguments"], variables: [:], addonName:)`
     so the 8 MiB bound and the object rule also apply. A throw gives an issue
     at `arguments`. Flat mode checks only the operation allowlist; values
     come from variables at runtime.
   - **Kaiba**: when `KaibaAddonCatalog.handles(name)` and `leaf["arguments"] != nil`,
     return `KaibaNestedArgumentRules.issues(addonName:, config: leaf, inputs: addon.inputs)`.
     The rules:
     - config keys ⊆ {arguments, kaibaInstanceId};
     - empty inputs;
     - arguments is an object, or an exact placeholder that defers the rest;
     - raw argument keys are disjoint from `connectionKeys`;
     - for `graphQLDocumentAddonNames`, each present `literalGraphQLKeys`
       value is a string without `{{`.
4. **R3 SDK fact check** (record the commands, matched lines and decision in
   the progress log). After `swift build`, run read-only:
   - `grep -rn "public" .build/checkouts/x-gateway/Sources | grep -i -E "sdl|schema"`
   - `grep -rn "\"schema\"" .build/checkouts/x-gateway/Sources`
   - `grep -rn "public" .build/checkouts/gateway-sdk-kit/Sources | grep -i -E "sdl|init\(.*schema|fromSDL"`

   The checkout directory names may differ; locate them with `ls .build/checkouts`.

   Decide one outcome:
   - **A** (the X SDK exposes SDL in-process with no network or credentials,
     AND the kit publicly builds a `GatewaySchemaCatalog` from SDL):
     - Add `XGatewayOperationCatalog.catalog` in `XGatewayOperationCatalog.swift`.
     - `xGatewayJSONDocument` converts `select` to `selection` paths,
       builds through `BuiltinGatewayJSONRequest.document`, and serializes
       with `inlineReaderDocument(..., maximumBytes: 1_000_000)`.
     - Replace the string goldens with assertions that the two ASTs are equal
       (`GatewayGraphQLParser.parse` of the old golden vs the new output).
     - Delete `xGraphQLSelection` / `xGraphQLLiteral`.
     - The checker gains full catalog checks through the shared helpers.
   - **B** (SDL only):
     - `XGatewayOperationCatalog.queryOperationNames: Set<String>?` comes from
       a bounded scanner over the `type Query { ... }` block. Limits: SDL at
       most 2 MiB, at most 1,024 names; out-of-bounds or not-found gives nil.
     - The checker reports a literal operation that is not in the set at
       `operation` with `unknown operation '<op>'`.
     - A golden test pins that the set contains `homeTimeline`, `searchPosts`
       and `accountMe`, and pins the exact count observed for SDK 0.1.26.
     - Runtime unchanged.
   - **C** (neither):
     - No catalog file. Do not create `XGatewayOperationCatalog.swift`; it
       stays an unused declared path.
     - Update the header comment in XCompatibility with the dated rationale:
       no kit catalog, the X reader accepts no variables, the SDK is the type
       authority, and nested `select` is a documented alias.

## Pitfalls

- Error ordering and messages must not change. `LegacyGatewayJSONRequestTests`,
  `XGatewaySDKAddonTests`, `BuiltinGatewayJSONRequestTests`,
  `GoogleServiceGatewayAddonTests` and `KaibaStructuredArgumentsTests` are the
  regression net.
- Google Service: the runtime returns `invalidInput` for value errors and
  `policyBlocked` for shape errors. Do not unify the codes.
  - `GatewayAddonValues.value` reads `variables[key] ?? config[key]`.
  - An explicit `null` for an optional string is an error today; the static
    check must reproduce that.
  - The `operation` is read raw, not rendered. A templated operation fails the
    allowlist both statically and at runtime. Do not defer it.
- Kaiba: the runtime checks connection keys on the **rendered** arguments.
  Keep that post-render check; the static check uses raw keys. Both use the
  shared constants.
- Container X legacy mode accepts `queryTemplate` only. The embedded reader
  falls back to the engine's legacy handling; do not add a stricter embedded
  legacy rule.
- `mediaRootDir` applies only to the embedded reader.
- Outcome A changes the provider-facing document text. Equivalence must be
  proven at AST level. Keep the 1,000,000-byte embedded bound. If anything is
  uncertain, choose B or C and record why.

## Test cases

`Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift` (the class
name contains `WorkflowGatewayValidationTests`) holds parity rows. Each row
pairs the validate verdict (via the production context; imitate the
`validationErrors` helper) with the runtime verdict and its provider call
count:

- X embedded, with an `XGatewayReaderSDK.$invocationOverride` stub imitating
  `XGatewaySDKStub` in `XGatewayEmbeddedReaderRuntimeTests.swift`:
  - valid literal → validate ok, 1 SDK call;
  - `select` and `selection` together → both reject, 0 calls;
  - `operation: "{{x}}"` → both reject;
  - argument `mediaRootDir` → both reject;
  - templated arguments whose key is `mediaRootDir` → validate error, runtime
    rejects;
  - selection depth 17 → both reject;
  - `providerFailure: "retry"` → validate error at `providerFailure`. The
    runtime row is added by gwjson176-03; mark it pending here.
- X container, with a `LegacyJSONRecordingRunner`-style runner (see
  `LegacyGatewayJSONRequestTests.swift`):
  - valid → ok, 1 launch;
  - a literal document over 120,000 bytes → both reject, 0 launches;
  - legacy mode without `queryTemplate` → both reject.
- Gmail container: valid `account` → ok; unknown operation (literal) → both
  reject; templated unknown operation → validate error, runtime rejects;
  `select` present → both reject.
- Google Service read/write, via `googleServiceGatewayClientFactory` and the
  `RecordingGoogleServiceGatewayClient` pattern:
  - `services.get` with literal project/service → ok, 1 client call;
  - an unknown argument name → both reject (`policyBlocked`);
  - `pageSize: "10"` (a string) → both reject (`invalidInput`);
  - `state: "bogus"` → both reject (`invalidInput`);
  - `pageToken: null` → both reject;
  - `services.enable` on the read tier → both reject;
  - arguments plus a flat key → both reject;
  - a templated value → validate ok.
- Kaiba (validate side only): `kaiba/note-create` with `arguments.endpoint` →
  validate error at `addon.config`, not at a deeper path. Keep the relative
  path the rule returns.

`Tests/RielaKaibaAddonsTests/KaibaWorkflowGatewayValidationTests.swift`
compares `KaibaNestedArgumentRules.issues` with runtime
`KaibaAddonCatalog.executeForTesting` (the `KaibaHTTPFixture` pattern from
`KaibaStructuredArgumentsTests.swift`):

- a valid named node → no issues, 1 HTTP request;
- a flat key plus arguments → issue, `policyBlocked`, 0 requests;
- explicit inputs → issue, 0 requests;
- `arguments.apiKey` → issue, 0 requests;
- `note-graphql-document` with a `{{x}}` query → issue, 0 requests;
- exact-placeholder arguments → no static issue.

Golden tests: as described in file-level change 1, plus the outcome-specific
test from change 4.

## Execution rules

- Same branch and working directory. No worktrees, branches, stashes or
  index-changing git commands.
- Fresh-read every file before editing it and record pre/post sha256 in the
  progress log. On drift, stop and record it for serial repair.
- Logs go under `tmp/issue-176/gwjson176-02/`.
- Run every swift/swiftlint command in `arch -arm64 /bin/zsh -lc`, in the
  foreground, from the repository root.

## Verification (each exit 0; testsRun > 0; failureCount 0)

```
mkdir -p tmp/issue-176/gwjson176-02
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-02/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter XGatewayJSONDocumentGoldenTests > tmp/issue-176/gwjson176-02/golden.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-02/validation.log 2>&1'
arch -arm64 /bin/zsh -lc "swift test --filter 'BuiltinGatewayJSONRequestTests|LegacyGatewayJSONRequestTests|XGatewaySDKAddonTests|XGatewayEmbeddedReaderRuntimeTests|XGatewayContainerReaderTests|GoogleServiceGatewayAddonTests|KaibaStructuredArgumentsTests' > tmp/issue-176/gwjson176-02/regression.log 2>&1"
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-window-checkpoint --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/validate-x-window.log 2>&1'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-incremental-posts-kv --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-02/validate-x-kv.log 2>&1'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/BuiltinGatewayJSONRequest+XCompatibility.swift Sources/RielaCLI/XGatewayProviderFailureMode.swift Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift Sources/RielaCLI/ContainerGatewayAddonExecutor.swift Sources/RielaKaibaAddons/KaibaAddonInputs.swift > tmp/issue-176/gwjson176-02/lint.log 2>&1'
```

`WorkflowGatewayValidationTests` must show the Core, Catalog, Legacy and
Kaiba classes executed. The two example validations must exit 0. If outcome A
or B adds `XGatewayOperationCatalog.swift`, append it to the lint command.

## Done criteria

- [ ] Goldens were captured before the refactor and pass unchanged after it
      (or are AST-equal under outcome A).
- [ ] Every parity row passes; the `providerFailure` runtime row is marked as
      pending for gwjson176-03.
- [ ] The progress log records the R3 commands, outputs and chosen outcome
      (A, B or C) with its rationale. gwjson176-07 reads it.
- [ ] All commands exit 0 with the counts recorded; `git diff --name-only` is
      a subset of writePaths ∪ sharedPaths.

## Progress log expectations

`impl-plans/progress/gwjson176-02.md` contains:

- status;
- per-edit hashes;
- the golden capture evidence;
- the R3 fact-check transcript (log paths) and the decision;
- verification records with integer exitStatus, testsRun and failureCount;
- blockers as dependency objects;
- residual risks (no leading severity word);
- resolved items marked severity `fixed`.
