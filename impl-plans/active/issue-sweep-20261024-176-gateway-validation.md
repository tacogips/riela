# ISW-176: reconcile `riela workflow validate` with gateway JSON requests

**Status**: Ready
**planId**: ISW-176-gateway-validation
**Issue**: https://github.com/tacogips/riela/issues/176 (riela-side remainder only)
**Design Reference**: design-docs/specs/design-gateway-sdk-addons.md, section "Reconciliation with gateway JSON requests (#176, 2026-10-24)", rules V0-V5
**dependsOn**: none (wave 1)
**Created**: 2026-10-24

## Intent and context

Gateway validation exists today in
`Sources/RielaCore/WorkflowGatewayAddonValidation.swift`, but no production
caller passes a `WorkflowValidationContext`. Every
`DefaultWorkflowValidator()` call site, including
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift:58`, is context-free,
and `WorkflowValidation.swift:98` gates the gateway rules on that context. So
these rules never run.

This plan makes `riela workflow validate` reject four kinds of invalid
catalog-backed gateway node:

- an operation request mixed with legacy keys;
- a non-literal operation or selection;
- an invalid `config.postprocess` program;
- an unknown operation, when the catalog is available.

Valid shapes, aliases and legacy modes must keep validating.

## Non-goals

- No gateway checks in `workflow inspect`, run preflight, the registry or the
  server. They stay context-free.
- No validation for X readers, legacy container readers
  (`riela/x-gateway-read`, `riela/gmail-gateway-read`), Google Service or
  Kaiba nested arguments. These stay runtime-only and are documented as
  remaining.
- No ART migration, release or deployment.
- No change to runtime request building (`BuiltinGatewayJSONRequest`) or
  postprocess execution (`BuiltinPostprocessPlan`).
- `RielaCore` must not import any gateway SDK, `GatewaySDKKit` or
  `JSONDataTransform`.

## Write ownership (writePaths)

- `Sources/RielaCore/WorkflowGatewayAddonValidation.swift`
- `Sources/RielaCLI/WorkflowValidationContext+Production.swift` (new)
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift`
- `Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift` (new)
- `docs/builtin-gateway-json.md`
- `impl-plans/builtin-gateway-json-176.md`
- `impl-plans/progress/issue-sweep-20261024-176-gateway-validation.md`

## File-level changes

### 1. `WorkflowGatewayAddonValidation.swift` (RielaCore)

- **V1.** Add `case notion = "notion-gateway"` to `WorkflowGatewayProvider`,
  with tiers `["reader", "writer"]`. Add `"riela/notion-gateway-read": (.notion, "reader")`
  and `"riela/notion-gateway-write": (.notion, "writer")` to `graphQLAddons`.
- **Context.** Add
  `public var postprocessCompiler: (@Sendable (JSONValue) -> String?)?` to
  `WorkflowValidationContext`. It returns nil when the program is valid, or an
  error message.

  Extend the init to
  `init(gatewayCatalog: ... = nil, postprocessCompiler: ... = nil)`. Keep
  `gatewayCatalog` first. The existing trailing-closure call at
  `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift:65` must still
  bind to `gatewayCatalog`. Verify that it compiles and its test still passes.
- **V2, operation mode.** In `validateGatewayModes`, forbid all of
  `queryTemplate`, `variablesTemplate`, `command`, `argsTemplate` and
  `select`, de-duplicated. This mirrors the guard in
  `Sources/RielaCLI/BuiltinGatewayJSONRequest.swift:request`.
- **V2, Gmail passthrough.** When `provider == .gmail`, a passthrough
  `variablesTemplate` is an error: "is not supported; use operation with
  arguments". This matches runtime `acceptsVariables: false`.
- **V3, literal operation.** `literalOperation` takes a `commandOperation`
  flag (true for document addons). It enforces:
  - at most 256 bytes;
  - no `{{`;
  - regex `^[_A-Za-z][_0-9A-Za-z]*$` for GraphQL and Apple, or
    `^[A-Za-z][A-Za-z0-9_-]*( [A-Za-z][A-Za-z0-9_-]*)*$` for documents.

  Copy the regexes verbatim from `BuiltinGatewayJSONRequest.request`.
- **V3, selection.** `validateSelection` accepts two shapes:
  - an array of 1-256 entries, each matching
    `^[_A-Za-z][_0-9A-Za-z]*(\.[_A-Za-z][_0-9A-Za-z]*)*$` and at most 4,096
    bytes;
  - a brace-leading string (the existing rule) of at most 65,536 bytes with no
    `{{`.

  Aliases inside the literal selection string (`alias: field`) stay valid. Do
  not parse the string.
- **V4.** At the top of `validateGatewayAddon`, for any addon whose name has
  the prefix `riela/` or `kaiba/`, check `addon.config?["postprocess"]`. It
  reads config only, matching `BuiltinPostprocessPlan`.

  If the value contains no `{{` in any nested string, and
  `context.postprocessCompiler` is set and returns a message, add an error at
  `"\(path).addon.config.postprocess"`. A templated program is skipped (it is
  deferred to runtime).
- **V5.** No code change: `validateKnownOperation` already runs once a
  catalog is supplied. Make sure Apple still uses tier `"full"`.

### 2. `WorkflowValidationContext+Production.swift` (RielaCLI, new)

Add `extension WorkflowValidationContext { static func production() -> WorkflowValidationContext }`.

- **`postprocessCompiler`:**
  `{ do { _ = try JSONDataTransform.compile($0); return nil } catch { return "invalid postprocess program: \(error)" } }`.
  `JSONDataTransform` is internal to RielaCLI, so this is the same compiler
  the runtime uses.
- **`gatewayCatalog`:** map `(provider, tier)` to
  `WorkflowGatewayCatalogProjection?` using the same SDK constructors the
  runtime descriptors use:
  - Wrike, Analytics: `BuiltinWrikeGatewayAddon` and
    `BuiltinGoogleAnalyticsGatewayAddon` cases matched by `tier`, then
    `descriptor.catalog?()`;
  - Gmail `reader`, `draft`, `sender`: `BuiltinGmailGatewayCLIAddon`.
    `threads` and `message-box` return nil;
  - Notion: `BuiltinNotionGatewayAddon`;
  - documents: the role used by `BuiltinGoogleDocumentsGatewayAddon`, under
    `#if canImport(GoogleDocumentsGatewayCore)`;
  - Apple `full`: `AppleGatewaySDK(role: .full).catalog`, under its
    `#if canImport`.

  A catalog constructor that throws, or an SDK that is not importable,
  returns nil.
- **Operation names.** After `swift build`, inspect `GatewaySchemaCatalog`
  in the resolved `gateway-sdk-kit` checkout under `.build/checkouts`. Find
  its public listing of root operations: the query and mutation root field
  names, or command operation names for documents. Project them into
  `operationNames`.

  Documents names must use the same space-separated command form that
  `BuiltinGatewayJSONRequest.request(commandOperation: true)` and
  `GoogleDocumentsGatewaySDK.buildArgv(operation:)` accept. If no public API
  enumerates names in exactly that form for a provider, return nil for that
  provider (the existence check is skipped) and record it in the progress
  log. Never guess names and never hardcode lists.

### 3. `WorkflowValidateInspectCommands.swift`

In `WorkflowValidateCommand.run` only (around line 58), replace
`DefaultWorkflowValidator()` with
`DefaultWorkflowValidator(context: .production())`. Leave the inspect path
(around line 726) unchanged.

### 4. Docs

- **`docs/builtin-gateway-json.md`.** Replace the sentence "Core catalog
  discovery and validation reconciliation are still acceptance work" with
  the V0-V5 behavior:
  - what `riela workflow validate` now rejects;
  - that templated postprocess and missing catalogs are deferred to runtime;
  - which add-on families stay runtime-only.

  Also update the opening status sentence.
- **`impl-plans/builtin-gateway-json-176.md`.** Mark "Reconcile Core
  validation/catalog discovery with all runtime modes and aliases" done for
  the covered families, with evidence. Keep the X, legacy container, Google
  Service and Kaiba validation items, and the ART, release and deploy items,
  open.

## Invariants

- Without a context, `DefaultWorkflowValidator()` behaves exactly as today.
- Every currently valid legacy shape still validates under the production
  context:
  - `queryTemplate` + `variablesTemplate` for non-Gmail add-ons;
  - documents `command` + `argsTemplate`;
  - Apple `query`/`queryFile`/`variables`/`variablesFile`, including inputs
    precedence and template values;
  - operation mode with empty `arguments`;
  - no selection.
- Diagnostics never echo argument values.

## Pitfalls

- Gmail passthrough `variablesTemplate` must be rejected for the Gmail tiers
  only, not for Wrike, Analytics or Notion.
- Apple validation reads effective config merged with inputs, but
  postprocess reads `addon.config` only.
- Building SDK catalogs must not read credentials or touch the network. Use
  the same constructors as the descriptors, nothing else.
- Do not edit `ProductionNodeAdapter+*GatewayAddons.swift`. If
  `operationCatalog` is private and `descriptor.catalog` is unreachable, use
  `descriptor.catalog`, which is internal. Do not change those files' access
  levels.
- Do not touch `Sources/RielaCore/WorkflowValidation.swift`. The per-node
  call already passes every addon.

## Tests

**`Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift`** (stub context,
following the existing helper at line ~10):

| Input | Expected outcome |
| --- | --- |
| Wrike `operation` + `queryTemplate` | error at `.queryTemplate` |
| Gmail reader `operation` + `select` | error at `.select` |
| Documents `operation` + `argsTemplate` | error |
| `operation: "{{input.op}}"` | error "must be a literal catalog operation name" |
| `operation: "bad name!"` (GraphQL) | error |
| documents `operation: "docs get"` | valid shape |
| selection `["posts.{{x}}"]`, `[]` | error |
| selection `"{ a: id }"` (alias) | valid |
| selection `"{ id {{x}} }"` | error |
| Gmail passthrough with `variablesTemplate` | error; Wrike passthrough with `variablesTemplate` is valid |
| Notion read `operation` unknown to the stub catalog | unknown-operation error with suggestions |
| Notion write passthrough `queryTemplate` | valid |
| `riela/gmail-gateway-reader` `postprocess: [{"pick": 5}]` with a compiler stub that fails | error at `.addon.config.postprocess` |
| `postprocess` containing `"{{input.n}}"` | no compile call, no error |
| `kaiba/...` addon with an invalid postprocess | error |
| non-`riela/`/`kaiba/` addon with `postprocess` | ignored |
| validator without a context | no gateway diagnostics, as today |

**`Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift`** (new;
imitate `WorkflowValidateCommand` construction in
`Tests/RielaCLITests/WorkflowHostCapabilityTests.swift:145`):

| Situation | Expected outcome |
| --- | --- |
| temp workflow, gmail-gateway-reader `postprocess: [{"bogus": 1}]` | `valid == false`; diagnostic path ends `.addon.config.postprocess` (proves the production compiler is injected) |
| temp workflow, wrike-gateway-read `operation` + `queryTemplate` | `valid == false` |
| `WorkflowValidateCommand` over the six examples `examples/builtin-gateway-json`, `examples/gmail-latest-mail-digest-telegram`, `examples/wrike-project-kanban-agent`, `examples/wrike-webhook-realtime`, `examples/apple-gateway-admin`, `examples/apple-gateway-packaging-plan` | each `valid == true`, with no new gateway diagnostics |
| on a platform where the catalog is available, gmail-gateway-reader `operation: "noSuchOperation"` | unknown-operation diagnostic; skip with `XCTSkip` when `production().gatewayCatalog?(.gmail, "reader")` is nil |

## Verification commands

Run from the repository root. Logs go under
`tmp/issue-sweep-20261024/ISW-176/`, each ending with an `exitStatus=$?` line:

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-176/build.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-sweep-20261024/ISW-176/core.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/core.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowValidateGatewayContextTests > tmp/issue-sweep-20261024/ISW-176/cli.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/cli.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "RielaExampleParityTests|WorkflowHostCapabilityTests" > tmp/issue-sweep-20261024/ISW-176/examples.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/examples.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowGatewayAddonValidation.swift Sources/RielaCLI/WorkflowValidationContext+Production.swift Sources/RielaCLI/WorkflowValidateInspectCommands.swift Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift > tmp/issue-sweep-20261024/ISW-176/lint.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/lint.log'
```

Each command must show exitStatus 0. Every test filter must show testsRun > 0
and failureCount 0, with any skips reported as integers.

If an example fails validation under the new rules, do not edit the example.
Record it as a dependency object naming the example path, with the
diagnostic. Then decide whether the rule is over-strict against runtime
behavior. If it is, fix the rule. If the example is truly invalid at runtime,
report it.

## Edit discipline

Apply the common rules:

- fresh read and pre/post `shasum -a 256` for every edit;
- on drift, stop, re-read, and re-apply the recorded intent only;
- do not edit outside writePaths;
- run no index- or worktree-changing git commands.

## Completion criteria

- [ ] V0-V5 are implemented. Only `WorkflowValidateCommand.run` passes the
      production context.
- [ ] Every test table row passes, and the six examples validate.
- [ ] The docs and the impl-plan record what is done and what remains open.
- [ ] All verification commands exit 0, with the integer fields recorded.
- [ ] `git diff --stat` touches only the writePaths.

## Progress log expectations

`impl-plans/progress/issue-sweep-20261024-176-gateway-validation.md` records:

- hashes, commands, integer fields and log paths;
- the catalog-name API found, per provider (or "nil: reason");
- any drift.
