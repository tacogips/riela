# GWJSON176-01: shared request-checker contract, catalog-family checks, run warnings

```json
{
  "planId": "gwjson176-01",
  "planPath": "impl-plans/active/gwjson176-01-validation-contract.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCore/WorkflowGatewayAddonValidation.swift",
    "Sources/RielaCLI/WorkflowValidationContext+Production.swift",
    "Sources/RielaCLI/BuiltinGatewayRequestChecks.swift",
    "Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift",
    "Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift",
    "Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift",
    "Tests/RielaCLITests/WorkflowRunGatewayValidationWarningTests.swift",
    "impl-plans/active/gwjson176-01-validation-contract.md",
    "impl-plans/progress/gwjson176-01.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/gwjson176-01.md",
  "status": "completed 2026-10-25; accepted dependency at fb928672, combined-tree integration review accepted (session-488); archived to impl-plans/completed/"
}
```

## Authority and intent

- Issue: tacogips/riela#176, riela-side remainder only.
- Design: `design-docs/specs/design-gateway-sdk-addons.md`, section "#176
  remainder (2026-10-25)", rule **R1**.
- User QA: `design-docs/user-qa/qa-issue-176-gateway-json-remainder.md`,
  item 1.
- No codex-agent reference applies.

`riela workflow validate` must reject a malformed gateway request with the
same function the runtime uses before effects. This plan does three things:

- pins the contract (a new optional context closure and its issue type);
- implements the checker for the catalog-backed families (Wrike, Analytics,
  Gmail reader/draft/sender, Notion, Apple GraphQL `full`, Docs/Sheets/Drive);
- makes `riela workflow run` report the extra findings as non-blocking stderr
  warnings.

Plan gwjson176-02 adds the X, legacy-container, Google Service and Kaiba
families through the stub file this plan creates.

## Non-goals

- No X, `riela/gmail-gateway-read`, Google Service or Kaiba checks. Those are
  gwjson176-02; leave `extendedIssues` returning `[]`.
- No change to runtime request building, except extracting the Documents
  operation-argv construction into a reusable function with identical
  behavior.
- No blocking validation in `workflow run`. No new CLI flag, GraphQL field or
  SurfaceCatalog row.
- No change to inspect, catalog commands, task dispatch, `RielaWorkflowRegistry`
  or `RielaServer`. They stay context-free.
- `RielaCore` imports no gateway SDK, `GatewaySDKKit` or `JSONDataTransform`.
- Do not touch the examples, docs or `Package.resolved`.

## Write ownership

writePaths: as listed in the JSON header. sharedPaths: none.

## Contract pinned for later plans (do not rename)

In `Sources/RielaCore/WorkflowGatewayAddonValidation.swift`:

```swift
public struct WorkflowGatewayRequestIssue: Equatable, Sendable {
  public var relativePath: String   // relative to addon.config; "" = config itself
  public var message: String
  public init(relativePath: String, message: String)
}
// added to WorkflowValidationContext, third init parameter, default nil:
public var addonRequestChecker: (@Sendable (WorkflowNodeAddonRef) -> [WorkflowGatewayRequestIssue])?
```

In `Sources/RielaCLI/BuiltinGatewayRequestChecks.swift`, all internal:

- `enum BuiltinGatewayRequestChecks`
- `static func issues(_ addon: WorkflowNodeAddonRef) -> [WorkflowGatewayRequestIssue]`
- `static func leafConfig(_ addon: WorkflowNodeAddonRef) -> JSONObject` returns
  config without `postprocess`.
- `static func containsTemplate(_ value: JSONValue?) -> Bool` is true if any
  string or object key contains `{{`.
- `static func isExactPlaceholder(_ value: JSONValue?) -> Bool` uses the same
  regex as Core `requireArguments`: `^\s*\{\{\s*[a-zA-Z0-9_.-]+\s*\}\}\s*$`.
- `static func catalogArgumentNameIssues(_ arguments: JSONObject, operation: String, catalog: GatewaySchemaCatalog) -> [WorkflowGatewayRequestIssue]`

In `Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift`, a stub that
gwjson176-02 replaces:

- `extension BuiltinGatewayRequestChecks { static func extendedIssues(_ addon: WorkflowNodeAddonRef, leaf: JSONObject) -> [WorkflowGatewayRequestIssue] { [] } }`

## File-level changes

1. **`WorkflowGatewayAddonValidation.swift` (Core).**
   - Add the issue type and the closure. Keep `gatewayCatalog` as the first
     init parameter so the existing trailing-closure call in
     `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` still binds
     to it.
   - In `validateGatewayAddon`, after all existing checks, append the checker
     issues only when all three hold:
     - the existing checks produced no diagnostic for this add-on (an invalid
       postprocess program also counts);
     - the name has the prefix `riela/` or `kaiba/`;
     - `context.addonRequestChecker` is set.
   - Map each issue to `gatewayError(relativePath.isEmpty ? fieldPath : "\(fieldPath).\(relativePath)", message)`.
     `fieldPath` is the existing `"\(path).addon.config"`.
2. **`BuiltinGatewayRequestChecks.swift` (new).**
   - `issues` dispatches by add-on name. Only operation mode
     (`leaf["operation"] != nil`) is checked for the P1 families. Legacy modes
     return `[]`; Core already validates their shape. Any other name goes to
     `extendedIssues(addon, leaf:)`.
   - **Catalog GraphQL** (the 11 names in Core `graphQLAddons`): get the
     catalog from the same descriptor factories as
     `WorkflowValidationContext+Production.swift:productionGatewayCatalog`. A
     nil or throwing factory means no issues.
     - Literal case (`arguments` absent, or an object for which
       `containsTemplate` is false): call
       `BuiltinGatewayJSONRequest.document(config: leaf, variables: [:], catalog:, addonName:)`
       and turn a thrown `AdapterExecutionError` into
       `WorkflowGatewayRequestIssue(relativePath: "", message: error.message)`.
     - Templated object: return `catalogArgumentNameIssues(...)`.
     - Exact placeholder: `[]`.
   - **`catalogArgumentNameIssues`.**
     - Find the operation by name in `catalog.operations`. If it is missing,
       return `[]` (Core V5 reports unknown operations).
     - For each top-level key not in `operation.arguments.map(\.name)`, add
       `relativePath: "arguments.<key>"` with the message
       `is not an argument of operation '<op>'`.
     - For each `isRequired` argument whose key is absent, add
       `relativePath: "arguments"` with the message
       `is missing required argument '<name>'`.
     - Iterate keys in sorted order so the result is deterministic.
   - **Apple** `riela/apple-gateway-graphql`: check only when `addon.inputs` is
     nil or empty, inside `#if canImport(AppleGatewayCore)`. Use the catalog
     `AppleGatewaySDK(role: .full).catalog`. In the literal case call
     `BuiltinGatewayJSONRequest.document(config: leaf, variables: [:], catalog:, addonName:, argumentsAlreadyRendered: true)`.
     That mirrors `ProductionNodeAdapter+AppleGatewayAdminAddons.swift` around
     line 188.
   - **Documents** (the six names in Core `documentAddons`): inside
     `#if canImport(GoogleDocumentsGatewayCore)`.
     - Literal case: call the new extracted Documents function (change 4) with
       empty variables. Map a throw to an issue at `""`.
     - Templated case: run `catalogArgumentNameIssues` against
       `GoogleDocumentsGatewaySDK(role:).catalog`, using the command name as
       the operation.
3. **`WorkflowValidationContext+Production.swift`.** Pass
   `addonRequestChecker: { BuiltinGatewayRequestChecks.issues($0) }`. Do not
   change the existing projection.
4. **`ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift`.**
   - Extract the operation-mode branch (currently about lines 166-181:
     `BuiltinGatewayJSONRequest.request` with `commandOperation: true`, the
     forbidden-command and `selection` guard, `buildArgv`, and error mapping)
     into one internal static function:

     ```swift
     static func operationArgv(config: JSONObject, variables: JSONObject, addonName: String, role: GatewayRole) throws -> (arguments: [String], commandTokens: [String])
     ```

     Put it on `BuiltinGoogleDocumentsGatewayAddon` or the engine. The runtime
     calls it, and the error messages, codes and order stay identical.
     `forbiddenCommands` stays the single set.
   - First confirm that `GoogleDocumentsGatewaySDK.buildArgv` is pure: no
     file, environment or network access. Read the SDK source under
     `.build/checkouts/` after the first `swift build` and record the grep
     commands and findings in the progress log. If it is not pure, skip the
     literal build in the checker, keep only the name checks, and record that.
5. **`WorkflowRunCommand.swift` / `WorkflowRunCommand+KaibaPreflight.swift`.**
   - `validateEffectiveSessionPolicies` keeps throwing
     `WorkflowResolutionError.invalidWorkflow` for errors from the
     context-free `DefaultWorkflowValidator()`, exactly as today.
   - It then runs `DefaultWorkflowValidator(context: .production())` on the
     same bundle. Every diagnostic not contained in the context-free result
     becomes the line `warning: <path>: <message>`.
   - It returns these lines as `[String]`, marked `@discardableResult` if a
     caller ignores them.
   - Thread the lines out of `prepareEffectiveRunBundle` /
     `PreparedWorkflowRunExecution` (add a `gatewayValidationWarnings: [String]`
     field) to every terminal `CLICommandResult` that `workflow run` builds
     after preflight. Prepend them to `stderr` with one `\n` after each line.
     At minimum cover the success/terminal result at about
     `WorkflowRunCommand.swift:966` and the error result at about `:766`.
   - Never write the warnings to stdout. Structured (`json`/`jsonl`) stdout
     must stay byte-identical.

## Pitfalls

- Duplicates: the checker must not run when Core already reported a
  mixed-mode or unknown-operation error for the node. Test this explicitly.
- The leaf view matters: `postprocess` must be removed before any key-set
  rule, because the runtime (`BuiltinPostprocessPlan.init`) strips it.
- Never echo argument values in messages. Runtime builder messages are
  already value-free; reuse them verbatim.
- A missing `arguments` means `{}` and is literal. A present non-object is
  already a Core error, so the checker is not reached.
- Keep `#if canImport` guards. On Linux the macOS-only families return `[]`.
- Do not build the production context once per node inside Core. The closure
  is created once in `.production()`. Catalog factories may be called per
  node; that is acceptable.

## Test cases

`Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` (stub checker):

- stub returns an issue at `arguments` for `riela/x-gateway-reader` → one
  error at `workflow.nodes[0].addon.config.arguments`;
- an issue with `relativePath ""` → path `workflow.nodes[0].addon.config`;
- Wrike operation plus `queryTemplate` (a Core error) → stub call count 0;
- add-on name `custom/thing` → stub call count 0;
- a context without a checker → existing behavior unchanged.

`Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift`:

- Imitate `Tests/RielaCLITests/BuiltinGatewayJSONRequestTests.swift:testValidationAndRuntimeAgreeOnRequestShapes`
  and its `validationErrors` helper.
- For Wrike read and Gmail reader (always), and for Notion read, Analytics
  read, Docs read and Apple `full` (macOS, `#if canImport`, otherwise
  `XCTSkip`), choose the operation and argument from the catalog at test time.
  Each row records the validation verdict and the runtime verdict
  (`RecordingGatewayGraphQLRunner` call count, or the Documents runner
  override, or the Apple invoker):
  - valid literal arguments → validate ok, runtime 1 call;
  - literal unknown argument name → both reject, runtime 0 calls,
    `policyBlocked`;
  - literal wrong JSON type for a typed scalar argument → both reject;
  - missing required argument (literal) → both reject;
  - templated value `"{{workflowInput.x}}"` under a valid name, with variables
    supplied at runtime → validate ok, runtime 1 call;
  - templated object with an unknown name → validate error at
    `arguments.<name>`, runtime rejects;
  - exact-placeholder `arguments` → validate ok. Runtime without the variable
    rejects; record this as deferred, like the existing table.
  - Apple with non-empty `addon.inputs` → checker silent.

`Tests/RielaCLITests/WorkflowRunGatewayValidationWarningTests.swift`:

- Setup: a temp bundle with one Wrike-read node configured as
  `{"operation":"tasks","queryTemplate":"query { tasks { id } }"}` (mixed
  mode), plus a mock scenario for that node.
  - `RielaCLIApplication().run(["workflow","run",...,"--mock-scenario",...,"--output","json"])`
    → `exitCode == .success`, `stderr` contains
    `warning: workflow.nodes[0].addon.config`, and stdout decodes as a
    completed `WorkflowRunResult`.
- The same bundle with a valid operation-only config → stderr contains no
  `warning: workflow.nodes`.
- Build the CLI arguments as `RielaExampleParityTests` does: workflow name,
  `--workflow-definition-dir`, `--mock-scenario`, `--session-store` under a
  temp dir, `--output json`.

## Execution rules

- Same branch and working directory. No worktrees, branches, stashes or
  index-changing git commands.
- Before each edit, re-read the file, record its sha256 in the progress log,
  and record the post-edit sha256 afterwards. If a file changed unexpectedly
  between reads, stop editing that file and record the drift for serial
  repair.
- Evidence and logs go under `tmp/issue-176/gwjson176-01/` only.
- Run every swift/swiftlint command from the repository root inside
  `arch -arm64 /bin/zsh -lc '...'`, in the foreground.

## Verification (each must show exit 0; tests: testsRun > 0, failureCount 0)

```
mkdir -p tmp/issue-176/gwjson176-01
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-01/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-176/gwjson176-01/validation.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowValidateGatewayContextTests > tmp/issue-176/gwjson176-01/context.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter BuiltinGatewayJSONRequestTests > tmp/issue-176/gwjson176-01/request.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter GoogleDocumentsGatewayAddonTests > tmp/issue-176/gwjson176-01/docs.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowRunGatewayValidationWarningTests > tmp/issue-176/gwjson176-01/run-warning.log 2>&1'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowGatewayAddonValidation.swift Sources/RielaCLI/BuiltinGatewayRequestChecks.swift Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/WorkflowValidationContext+Production.swift Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift > tmp/issue-176/gwjson176-01/lint.log 2>&1'
```

`WorkflowGatewayValidationTests` matches both
`RielaCoreTests.WorkflowGatewayValidationTests` and
`RielaCLITests.CatalogWorkflowGatewayValidationTests`. The log must show both
classes executed.

## Done criteria

- [x] The contract symbols exist with the exact names and signatures above.
- [x] All seven commands exit 0, with test counts > 0 and 0 failures, and
      lint reports no violations in the owned files.
- [x] The progress log records the `buildArgv` purity finding, pre/post
      sha256 for every edited file, and one verification record per command
      (`command`, `logPath`, `exitStatus`, `testsRun`, `failureCount`, all
      integers).
- [x] `git diff --name-only` contains only writePaths.

## Progress log expectations

`impl-plans/progress/gwjson176-01.md` contains:

- status;
- edits with their hashes;
- decisions, including the `buildArgv` purity outcome;
- verification records;
- blockers, written as dependency objects (`{dependency, path, reason}`);
- residual risks (the text must not start with a severity word);
- resolved findings, marked severity `fixed`.
