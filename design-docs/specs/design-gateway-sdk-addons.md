# Operation-mode gateway SDK add-ons and schema discovery

## Main integration checkpoint (2026-10-20)

The accepted design and plans below are preserved as historical implementation
inputs. Core validation and its existing tests are integrated as an explicit
`DefaultWorkflowValidator(context:)` opt-in. The default validator retains its
current behavior until operation execution, schema discovery, and catalog wiring
are complete. Plans 03–05 remain unfinished; this merge does not declare them
implemented. Historical progress logs describe the original worktree only.
Current gateway dependency revisions are retained rather than restoring the old
plan 01 pins or adding an unused GatewaySDKKit dependency.

Status: accepted design baseline for plans 01–05 on
`feat/remaining-impl-plans-20260927`. The prior implementation run left plan 01
dependency and lockfile changes in the working tree, but its progress gate still
requires a focused behavioral test with a positive test count. Historical
dependency finding D1 is resolved by the operator-approved Google Documents
v0.3.3 decision. This design does not claim implementation acceptance.
The dependency decision is recorded in
`design-docs/user-qa/qa-gateway-sdk-worktree-dependencies.md`

Issue: `docs/briefs/gateway-sdk-addons-2026-09-04.md`

Workflow: `codex-design-and-implement-review-loop-session-5` (continuing the
accepted design and preserving plan 01 work from session 1)

Reference contract: `docs/briefs/gateway-sdk-2026-09-04.md`, especially sections 2 and 4

## Outcome and boundaries

Riela's existing local gateway add-ons support two authoring modes. Passthrough
mode keeps an authored GraphQL document, or an authored command plus flags for
google-documents. Operation mode names a catalog operation and supplies typed
arguments and an optional selection; `GatewaySDKKit` deterministically builds
the GraphQL document or argv. Both modes retain the add-on's existing fixed
tier, environment allowlist, deadline, envelope handling, selection helpers,
payload extras, and platform fallback.

The same static catalogs power a credential-free `riela/gateway-schema` add-on,
the `riela addon schema` command, and validate-time operation-name checks. No
schema-discovery path may read credentials, contact a provider, or execute a
gateway request.

This is one feature. It does not change container add-ons,
`google-service-gateway`, unrelated Apple add-on families, unrelated package versions, or
release state. The effective workflow input authorizes implementation and
verification of the five existing plans on `feat/remaining-impl-plans-20260927`.
Preserve the GatewaySDKKit checkout, gateway worktrees, and main Riela checkout.

## Dependency and platform boundary

`Package.swift` adds
`https://github.com/tacogips/gateway-sdk-kit.git` at exact version `0.1.0` as an
unconditional `RielaCLI` dependency. The kit is pure Swift and supplies only
gateway-neutral models and builders.

The graph uses public exact-version dependencies for the five gateways:
Wrike `0.2.4`, Google Analytics `0.1.1`, Gmail `0.1.11`, Google Documents
`0.3.3`, and Apple `0.1.7`. Their existing products and macOS conditions remain
unchanged. The six public URLs, exact versions, and tag commits are recorded in
the QA dependency table. The effective workflow input supersedes the brief's
historical Google Documents 0.3.1 pin. Source verification of v0.3.3 confirms
the SDK facade and exact kit dependency; it is not a claim that the future
Riela dependency graph has resolved. No ambient mirror, symlink, or copied
checkout participates.

The dependency readiness gate is `swift package show-dependencies --format
json` from this Riela worktree after the manifest edit. It must exit zero, emit
no conflicting-identity diagnostic, show five distinct remote gateway package
identities, and show `gateway-sdk-kit` once from the public URL at version
`0.1.0`. Release build work cannot start until this gate passes.

Gateway imports and concrete SDK construction remain in `RielaCLI` behind the
existing `#if canImport(...)` guards. `RielaCore` does not import a gateway
package or `GatewaySDKKit`. It owns only a small Sendable validation projection
containing provider, tier, and operation names. `RielaCLI` converts an available
`GatewaySchemaCatalog` into that projection and injects a lookup closure into
`WorkflowValidationContext.gatewayCatalog`. The closure returns the projection,
not the SDK type. Thus shape checks run on every platform while catalog checks
run only when the platform can construct the catalog.

## Add-on execution contract

### Modes

For the wrike, google-analytics, and gmail local GraphQL add-ons, exactly one
mode discriminator is present (presence includes null, which fails its type check).
Operation names are literal catalog names, not templates:

| Mode | Required configuration | Optional configuration | Rejected combination |
| --- | --- | --- | --- |
| passthrough | non-empty `queryTemplate` | object `variablesTemplate` | any `operation`, `arguments`, or `selection` |
| operation | non-empty string `operation`; object `arguments` | `selection` | any `queryTemplate` or `variablesTemplate` |

`arguments` is required even when empty. It is rendered recursively with
`renderJSONTemplates`, so an exact `{{path}}` placeholder keeps its Boolean,
number, array, object, or null type. The rendered object is converted without
loss to `[String: GatewayJSONValue]`.

`selection` is one of:

- absent, producing `GatewaySelection.default`;
- an array of non-empty dot-path strings, producing `.fields`; or
- a non-empty string whose first non-whitespace character is `{`, producing
  `.raw`.

Any other shape is policy-blocked before a provider call. The kit remains the
authority for operation existence, required and unknown variables, result
shape, and selection-path validity.

Gmail no longer has an `acceptsVariables` exception. A passthrough
`variablesTemplate` is encoded and forwarded exactly like the other GraphQL
gateways.

Google-documents retains its existing passthrough discriminator `command` and
its existing `argsTemplate` rendering. Its operation mode uses `operation`, an
object `arguments`, and no GraphQL selection. `GatewayArgvBuilder` produces the
argv. The fixed-role environment allowlist and the refusal of `auth login` and
`auth revoke` apply after either mode is normalized and before execution.

`riela/apple-gateway-graphql` keeps its current passthrough keys and precedence:
`queryFile` over `query`, `variablesFile` over `variables`, refusal of config `binaryPath`, and no `addon.env`. Operation mode is selected by `operation` and
uses `arguments` plus optional `selection` through `AppleGatewaySDK`. It is
mutually exclusive with `query`, `queryFile`, `variables`, and `variablesFile`.
Apple retains rendered `addon.inputs` precedence over config for these keys; checks
use that effective merged input. Passthrough remains on `AppleGatewayInvoker`.
Operation mode uses fixed `.full` (the existing GraphQL role), sanitized Apple
environment and the existing deadline. Map effective `configPath`/`config` to
`APPLE_GATEWAY_CONFIG` in that per-call environment, preserving explicit config
precedence and HOME; never widen the ambient allowlist. New operation keys do not
change role selection. No other Apple admin
or product add-on changes behavior.

### Data flow and provenance

The local GraphQL engine becomes `LocalGatewayOperationEngine`, backed by a
`LocalGatewaySDKDescriptor` containing the fixed-tier catalog and SDK `execute`
closure. Build once with `GatewayDocumentBuilder(catalog:)`, then pass that exact
built document and variables to `sdk.execute` under `localGatewayRunWithDeadline`.
Do not preview and then call `invoke`: Gmail 0.1.11 overrides `invoke` using
`.gmailFull`, whereas its exposed catalog is tier-specific. A single build ensures
pre-dispatch errors are `policyBlocked` and payload provenance equals execution.
The SDK runtime still enforces the fixed tier.

1. Resolve existing variables, nowVariables, and sanitized child environment.
2. Check modes and render typed input; reject malformed shapes before dispatch.
3. Build operation input once; passthrough retains authored document and variables.
4. Execute those exact values through the pinned SDK, within the existing deadline.
5. Preserve raw-envelope parsing and existing common output processing.

The stand-in records the actual document and variables submitted to execute, with
operation metadata available for assertions. It must not merely echo a preview.

Google-documents keeps its separate engine and runner boundary. The verified
v0.3.3 facade at commit `4baeb285f459adb9031273490b922abc8204dedb` supplies
this API. In operation mode that engine constructs the pinned `GoogleDocumentsGatewaySDK`, calls its
public `buildArgv(operation:variables:)`, and passes the resulting argv directly
to the existing `GoogleDocumentsGatewayRunner`. It does not run a generic
`GatewayArgvBuilder` preview followed by `sdk.invoke`, because the facade adds
provider-specific variable validation, argument normalization, and token
limits. Construction failures thrown by this call map to `policyBlocked`,
while the runner supplies the provider envelope. `buildArgv` is a pure
construction boundary, not SDK execution authorization: the facade's `execute`
accepts a JSON argv string and ignores variables, and `invoke` takes a
`GatewayOperationRequest`; those execution paths additionally apply SDK file
policies and bounded execution. This design deliberately retains Riela's
existing command runner, fixed role, environment restrictions, auth-command
refusal, and deadline. It does not claim to inherit SDK snapshot/file-access
policies or SDK execution limits from `buildArgv`. Do not add credential/file
policy options or silently switch execution paths in this feature. The payload records the compact JSON encoding of the exact argv given
to that runner. Tests cover input objects, confirm flags, normalization, limits,
unknown operations, missing variables, and equality with the recorded argv.

Every successful affected add-on payload preserves its existing top-level
fields and existing namespace, then adds within that namespace:

- `mode`: `passthrough` or `operation`;
- `operation`: the operation name in operation mode, otherwise JSON null; and
- `document`: the exact GraphQL text sent, or the compact JSON argv string sent
  through the command SDK contract.

The existing namespace runtime object continues to report `mode: in-process`
and the pinned tier; this runtime mode is distinct from the new authoring mode.

### Error and deadline rules

- Invalid shape, template rendering, JSON conversion, unknown operations,
  missing or unknown arguments, and invalid selection are `policyBlocked` and
  use the kit's stable message where the kit supplied it.
- An invoked gateway envelope with errors or a non-success result is
  `providerError`, preserving current compact diagnostics.
- Malformed raw output remains `invalidOutput`: validate `rawOutput` with the
  existing provider-specific parser before interpreting normalized envelope errors.
  GatewayEnvelope wraps malformed text as errors, so testing `errors` first would
  incorrectly turn existing malformed-output failures into `providerError`.
- The current deadline helper, cancellation behavior, and timeout messages are
  unchanged for both modes.
- Provider code observes only the sanitized per-call environment. Existing
  target-name allowlists cannot be widened through operation arguments.

The resolver seam becomes `localGatewaySDKStandIn`. It records the executed document plus variables and returns a
canned envelope for either mode. Apple operation tests use this contract. Google-documents
operation tests retain `GoogleDocumentsGatewayRunner` as the exact argv recorder
after SDK construction. Existing passthrough-specific fake runners remain
available for regression coverage.

## Static schema discovery

### Catalog registry

`RielaCLI` owns one catalog registry mapping a closed `(gateway, tier)` pair to
the corresponding SDK facade. Supported gateways are:

- `wrike-gateway`;
- `google-analytics-gateway`;
- `gmail-gateway`;
- `google-documents-gateway`; and
- `apple-gateway`.

Tier values are the catalog-native tier strings exposed by each facade,
namely `reader|writer|admin` for wrike and google-analytics,
`reader|draft|sender|threads|message-box` for gmail,
`docs-read|docs-write|sheets-read|sheets-write|drive-read|drive-write` for
google-documents, and `full|reader` for Apple. Unknown gateway or tier is
rejected with the sorted known values. The same closed provider/tier vocabulary
lives in RielaCore for cross-platform shape validation, with a parity test
against the macOS catalog registry. Registry lookup constructs no authenticated
service and performs no network request.

When a gateway module is unavailable, shape validation still succeeds or fails
deterministically in `RielaCore`, while catalog-dependent execution and CLI
lookup fail closed with the established `requires macOS` policy message. Mock
workflow scenarios remain portable because their recorded node results do not
invoke the live catalog registry.

### `riela/gateway-schema@1`

The new worker add-on is registered in `RielaBuiltinAddonCatalog` and dispatched
by `BuiltinWorkflowAddonResolver`. It accepts required string `gateway` and
`tier`, plus optional string `pattern`, array `kinds`, Boolean
`includeReferencedTypes`, and positive integer `limit`.

With no pattern it returns deterministic SDL and an empty `matches` array. With
a pattern it returns no `sdl` field and ordered search matches. Its payload is:

```text
status, addon, stepId, gateway, tier, sdl?, matches[], count, replyText
matches[] = { kind, name, tier?, matchedOn[], sdl }
```

`count` is the number of returned matches after kind, reference, and limit
processing. Kind names must be members of GatewaySDKKit's public definition
kind vocabulary. Unknown kinds, a non-positive limit, an invalid pattern, or
an unavailable catalog are policy-blocked. No credential or environment input
is accepted.

`riela/apple-gateway-schema` keeps the current no-pattern schema-print behavior
and role precedence. When `pattern` is present it uses the Apple SDK's static
catalog and accepts the same `kinds`, `includeReferencedTypes`, and `limit`
search options. No-pattern payload fields remain backward compatible; pattern
mode adds `matches` and `count`.

### Search-pattern compatibility decision

GatewaySDKKit 0.1.0 intentionally rejects every `(?` regex extension, while
the accepted example and CLI gate require `(?i)draft`. Riela resolves this at
its input adapter without changing or bypassing the kit:

- the exact leading form `(?i)<ASCII literal>` is accepted when the remainder
  contains only ASCII letters, digits, spaces, `_`, `-`, or `.`;
- Riela rewrites each ASCII letter to a two-case character class (for example,
  `(?i)draft` becomes `[dD][rR][aA][fF][tT]`), escapes `.` as a literal, and
  then passes the result through `GatewaySchemaSearch`;
- all other `(?` forms and complex case-insensitive expressions retain the
  kit's `invalidPattern` failure; callers can use explicit character classes
  within the kit's portable subset.

The add-on, Apple schema search, and CLI share this one adapter. Tests cover the
required spelling, its equivalent explicit pattern, and rejection of unsupported
extension forms. This is an intentional, narrow Riela compatibility divergence,
not a change to GatewaySDKKit's regex policy.

## CLI behavior

`riela addon schema <gateway>` is a first-class route in the existing
ArgumentParser front door and in Riela's internal command model/parser. It
requires `--tier` and accepts `--grep`, comma-separated `--kinds`,
`--include-referenced-types`, `--limit`, and `--output json|sdl`.

The CLI calls the same catalog registry and schema service as the built-in
add-on, not a workflow runner and not a provider. JSON output is the
`riela/gateway-schema` payload with `stepId: ""` because no workflow step exists.
The default output is JSON; default search kinds use the kit Options default.
An omitted pattern returns SDL, empty matches, and count zero; search-only options
are type-checked but do not filter that full SDL. SDL output is the full catalog SDL without
`--grep`, or matched fragments in deterministic result order with `--grep`.
Usage errors, invalid search inputs, and unavailable catalogs use nonzero exits
and concise stderr; successful SDL and JSON each end with one newline.

## Workflow validation

`Sources/RielaCore/WorkflowGatewayAddonValidation.swift` owns pure validation
for the affected built-in names and is called from
`WorkflowNodeValidation.swift`.

Validation checks:

- exactly one passthrough or operation discriminator;
- mode-specific required and forbidden keys;
- object shapes for `arguments` and `variablesTemplate`;
- the selection union and non-empty dot-path members;
- known gateway and catalog-native tier for `riela/gateway-schema`;
- array shape and known values for `kinds`;
- Boolean `includeReferencedTypes` and positive integer `limit`; and
- operation existence when the injected catalog projection is available.

Unknown operations report the requested name and a deterministic bounded list
of closest names. An unavailable catalog does not make an otherwise valid
workflow fail on Linux; it skips only the operation-existence check. It never
skips the cross-platform shape checks. Add the currently nonexistent
`WorkflowValidationContext` as a defaulted initializer dependency of
`DefaultWorkflowValidator`; preserve `WorkflowValidating` and existing call sites.
Inject the CLI projection in `WorkflowValidateInspectCommands.swift` for explicit
validation. Other Core callers retain shape-only validation and runtime checks.
Apple uses its effective input/config precedence; defer template-dependent values
until execution rather than rejecting valid existing input-driven passthroughs. Runtime repeats policy-sensitive checks
so a workflow that was not prevalidated still fails closed.

### Reconciliation with gateway JSON requests (#176, 2026-10-24)

The source contradicts the injection decision above. Every production
`DefaultWorkflowValidator()` call site passes no context, including
`WorkflowValidateInspectCommands.swift`. `DefaultWorkflowValidator.validate`
calls `validateGatewayNodeAddon` only when a context is present. As a result,
neither the shape checks nor the catalog checks run anywhere today. The
"other Core callers retain shape-only validation" sentence is also stale:
those callers run no gateway checks at all. That stays true after this change,
and the runtime still fails closed. The rules below replace the parts they
contradict.

- **V0 wiring.** Only the explicit `riela workflow validate` path
  (`WorkflowValidateCommand.run`) builds `DefaultWorkflowValidator(context:)`
  with a production context from `RielaCLI`. `workflow inspect`, run preflight,
  the registry and the server stay context-free.
  - The context's `gatewayCatalog` closure projects operation names from the
    same pinned SDK constructors the runtime descriptors use (their
    `operationCatalog`). It returns nil where `#if canImport` excludes the SDK,
    in which case only the existence check is skipped.
  - The context gains one optional closure, `postprocessCompiler`, which the
    CLI implements with the runtime `JSONDataTransform.compile`.
  - `RielaCore` still imports no gateway SDK and no transform compiler.
- **V1 provider coverage.** Add `WorkflowGatewayProvider.notion` with tiers
  `reader` and `writer`. Map `riela/notion-gateway-read` and
  `riela/notion-gateway-write` like the other GraphQL add-ons, with passthrough
  key `queryTemplate`.
- **V2 mixed modes.** In operation mode, reject every legacy key the runtime
  builder (`BuiltinGatewayJSONRequest.request`) refuses: `queryTemplate`,
  `variablesTemplate`, `command`, `argsTemplate` and `select`. This applies to
  the GraphQL and Google Documents/Sheets/Drive add-ons. Apple keeps rejecting
  `query`, `queryFile`, `variables` and `variablesFile` on its effective
  config+inputs. The Gmail tiers also reject passthrough `variablesTemplate`,
  matching the runtime `acceptsVariables: false`. This supersedes the stale
  "no `acceptsVariables` exception" statement above.
- **V3 literals.** These bounds match runtime.
  - `operation`: at most 256 bytes and no `{{`. GraphQL and Apple names must
    match `^[_A-Za-z][_0-9A-Za-z]*$`. Documents command names must match
    `^[A-Za-z][A-Za-z0-9_-]*( [A-Za-z][A-Za-z0-9_-]*)*$`.
  - Array `selection`: 1 to 256 entries. Each entry must match
    `^[_A-Za-z][_0-9A-Za-z]*(\.[_A-Za-z][_0-9A-Za-z]*)*$` and be at most 4,096
    bytes.
  - String `selection`: brace-leading (the existing rule), at most 65,536
    bytes and no `{{`. GraphQL field aliases (`alias: field`) inside a literal
    selection set stay valid.
- **V4 postprocess.** For every add-on named `riela/*` or `kaiba/*` with
  `config.postprocess`, the value is compiled with `postprocessCompiler` when
  it contains no `{{` placeholder. A compile failure is an error at
  `workflow.nodes[i].addon.config.postprocess`. A templated program is
  deferred, because the runtime compiles it after rendering and before any
  provider effect.
- **V5 unknown operations.** Once V0 is wired, the existing
  `validateKnownOperation` runs for these catalogs: Wrike, Analytics, Gmail
  reader/draft/sender (plus threads/message-box when their SDK exposes a
  catalog), Notion, the six Documents roles, and Apple `full`. Documents names
  are projected in the same command-word form that runtime operation mode
  accepts.
- **Unchanged and still valid.**
  - passthrough `queryTemplate` + `variablesTemplate` (non-Gmail);
  - Documents `command` + `argsTemplate`;
  - Apple passthrough with inputs precedence and template-dependent values;
  - empty `arguments`; the default selection;
  - renamed add-on diagnostics.
- **Still runtime-only** (remaining #176 work, designed in "#176 remainder"
  below, which supersedes this list and the V0 "run preflight stays
  context-free" sentence):
  - X readers, including the nested `select` compatibility;
  - legacy container readers (`riela/x-gateway-read`,
    `riela/gmail-gateway-read`);
  - Google Service;
  - Kaiba nested arguments.

V0–V5 gate: focused `WorkflowGatewayValidationTests` (Core rules with a stub
context), a CLI `workflow validate` test that proves the production context is
injected, and `riela workflow validate` staying valid for every gateway
example: `examples/builtin-gateway-json`, `gmail-latest-mail-digest-telegram`,
`wrike-project-kanban-agent`, `wrike-webhook-realtime`, `apple-gateway-admin`
and `apple-gateway-packaging-plan`. `docs/builtin-gateway-json.md` and
`impl-plans/builtin-gateway-json-176.md` record V0–V5 as done. ART migration,
release and deployment remain open.

### #176 remainder (2026-10-25)

Scope: the riela-side gaps in `impl-plans/builtin-gateway-json-176.md`
("What remains of #176, by requirement"). ART Python migration, private image
adoption, App cutover and release/deploy remain outside riela and outside this
design. Everything not named here (V0–V5, Apple host preparation, postprocess
semantics, user/usage caches, transport parity) is unchanged. Intake mapping:
(A) static validation → R1, (B) X failure metadata → R2, (C) X path review →
R3, (D) examples → R4, (E) behavioral tests → R5, (F) docs and rollout → R6.

#### R1. One request checker shared by runtime and validation

Each gateway's runtime pre-effect request check moves into a pure function
(no I/O, credentials, clock or provider call). The runtime and `riela workflow
validate` both call that same function, so they agree by construction.

- `WorkflowValidationContext` gains one optional closure,
  `addonRequestChecker: (WorkflowNodeAddonRef) -> [(relativePath, message)]`.
  `WorkflowValidationContext.production()` implements it in `RielaCLI`.
  `RielaCore` still imports no gateway SDK.
- Core calls the checker for `riela/*` and `kaiba/*` add-ons only when its own
  shape rules found no error for that node, so a node never gets duplicate
  diagnostics. Checker issues are errors at
  `workflow.nodes[i].addon.config.<relativePath>`. Messages never echo argument
  values (same rule as the runtime errors).
- The checker reads the leaf view: `postprocess` is removed first, as
  `BuiltinPostprocessPlan` does before execution. Key-set rules such as
  `config ⊆ {operation, arguments}` therefore match the runtime.
- **Literal vs templated.** If the `arguments` subtree contains no `{{`, the
  checker runs the full runtime builder with empty variables. If it contains a
  placeholder, value-level checks are deferred to runtime. Key-level checks
  still run on an object: argument names, required-argument presence, and
  forbidden keys. An exact-placeholder `arguments` (`"{{input.args}}"`) defers
  everything except mode/operation/selection checks.

Per family:

| Family | Static checks added | Source of truth |
| --- | --- | --- |
| Catalog GraphQL (Wrike, Analytics, Gmail reader/draft/sender, Notion) | literal: `BuiltinGatewayJSONRequest.document` (argument names, types, enums, selection fields, single root field); templated: names ⊆ catalog operation arguments, every `isRequired` argument present | pinned `GatewaySchemaCatalog` |
| Apple `riela/apple-gateway-graphql` (`full`) | same as catalog GraphQL, only when `addon.inputs` is absent (inputs override config at runtime) | Apple `full` catalog |
| Docs/Sheets/Drive | literal: the same request + `buildArgv` + forbidden-command check, extracted into one pure function; templated: names against catalog command arguments | Documents role catalog |
| `riela/x-gateway-reader`, `riela/x-gateway-read` | mode mixing, literal operation, `select` XOR `selection`, selection depth/conflicts, `providerFailure` value (R2); literal: the full X document build, the embedded reader's `mediaRootDir` token rule, and the container's 120,000-byte limit | X shape/serializer split (R3) |
| `riela/gmail-gateway-read` | operation mode: as Gmail reader plus `inlineReaderDocument` and the 120,000-byte limit (literal only); legacy mode: non-empty `queryTemplate`, no `arguments`/`selection`/`select` | Gmail reader catalog |
| `riela/google-service-gateway-read`/`-write` | non-empty operation in the tier allowlist; in `arguments` mode: config ⊆ {operation, arguments}, no `addon.inputs`, names ⊆ the operation table; literal: required keys present and JSON-typed (string, string array, integer, Boolean, `state` enum) | one static table shared with the runtime engine |
| named `kaiba/*` with `config.arguments` | config ⊆ {arguments, kaibaInstanceId}, no `addon.inputs`, object (or exact placeholder), keys disjoint from connection keys; GraphQL compatibility nodes: `query`/`document`/`operationName` are strings without `{{` | pure function extracted from `KaibaAddonInputs.init` |

The Google Service table's type rules copy the runtime `GatewayAddonValues`
accessors exactly. Any value an accessor accepts or converts today must pass
statically; the parity table enforces this.
Kaiba named add-ons have no argument catalog, so names/types stay runtime-only.
X argument types stay SDK-side unless R3 finds an SDL source.
SDK-excluded builds (`#if canImport` false) skip the catalog-dependent rows, as
V0 does.

**Parity table.** `WorkflowGatewayValidationTests` gets a table test with at
least one valid, one invalid-literal and one templated-deferred case for each
family above. For each row, `validate` must report an error exactly when the
runtime, through the same resolver with stub runners, throws before any runner
call (call count 0). Valid and deferred rows must reach the runner (count 1).
The runtime error code is recorded per row (`policyBlocked`, or `invalidInput`
where the runtime uses it today). Every example listed in
`testGatewayWorkflowExamplesValidate`, plus the new examples (R4) and the
existing X examples, must still validate.

**Entry points.**

- `riela workflow validate`: blocking, as today.
- `riela workflow run`: every path through
  `WorkflowRunCommand.validateEffectiveSessionPolicies` also evaluates the
  production context before effects. Errors that only the production context
  finds (the set difference against the context-free run) are printed to
  stderr as `warning:` lines and do not block the run. The context-free errors
  still block, as today.
  - Rationale: a static per-node error is not provably equivalent to a runtime
    failure, because the node may sit on a branch this run never takes.
    Blocking would also change behavior without an opt-in. Adding an opt-in
    flag would extend the `workflow.run` SurfaceCatalog row and GraphQL
    `executeWorkflow`, which this issue does not need.
- Inspect, catalog commands, task dispatch, the registry
  (`RielaWorkflowRegistry`), the server (`RielaServer`), GraphQL and the
  console stay context-free. `RielaWorkflowRegistry` and `RielaServer` do not
  link the gateway SDKs, and the runtime still fails closed. This list is
  documented in `docs/builtin-gateway-json.md`.

#### R2. Finite X failure metadata, opt-in failure output

`GatewayFailureDiagnostics` gains one function that returns the allowlisted
fields as a JSON object. The existing suffix string is rendered from that
object, so its text stays byte-identical (golden test). Failure messages,
codes and step failure reasons in the default mode do not change.

Both X readers accept `config.providerFailure`: `"fail"` (default, current
behavior) or `"output"`. Any other value is `policyBlocked` before the call,
and the R1 checker reports it statically. With `"output"`:

- A provider failure becomes a completed output (`completionPassed: true`,
  `status: "provider-failed"`) carrying `xGateway.failure =
  {category, retryable, diagnostics}`. A provider failure here means a non-ok
  SDK envelope, or a container exit/envelope error whose diagnostics contain an
  allowlisted `code`. `diagnostics` holds only the allowlisted fields. Usage
  and user-cache observations are preserved as today.
- Not converted (still thrown): riela policy errors before the call, the node
  deadline `timeout`, `invalidOutput`, and failures with no recognized
  diagnostics (for example a missing container image).
- `when` gets `providerFailed`, `providerRetryable`, `spendCapReached` and
  `rateLimited`. All four are false on success, so labeled transitions can
  branch (first match). Postprocess is skipped on a failure output
  (`postprocess.status: "skipped"`, both postprocess flags false), so shaping
  never misreports a missing provider payload.

`category` is a closed set. The first matching rule wins:

1. `spend-cap-reached`: providerProblem `spend-cap-reached`/`usage-capped`, or
   providerReason `usage-capped` (retryable false).
2. `rate-limited`: code `RATE_LIMITED`/`PROVIDER_RATE_LIMITED`, providerProblem
   `rate-limit-exceeded`, classification `rate_limit`, or HTTP 429 (true).
3. `auth`: `AUTH_*`, `CREDENTIAL_NOT_FOUND`, classification `auth`, or HTTP 401
   (false).
4. `permission`: `PERMISSION_DENIED`, `ACCESS_MODE_INSUFFICIENT`, classification
   `permission`, the remaining 403 providerProblems, or HTTP 403 (false).
5. `invalid-request`: `VALIDATION_ERROR`, `INVALID_ARGUMENT`, `CONFIG_INVALID`,
   classification `validation`, providerProblem `invalid-request`, or HTTP
   400/422 (false).
6. `not-found`: `RESOURCE_NOT_FOUND`, providerProblem `resource-not-found`, or
   HTTP 404 (false).
7. `transient`: `NETWORK_FAILURE`, `UPSTREAM_FAILURE` with no status or a
   status ≥ 500, classification `network`/`upstream`, or SDK `retryable=true`
   (true).
8. `unknown` (false).

`retryable` comes from this table only. It is advice for workflow branches.
Riela never retries: X stays `--retry 0`, `AdapterExecutionError.isRetryable`
stays unset, and no loop is added. X readers are read-only, so no write can be
re-sent. Other gateways keep their current failure behavior (see the user-QA
file).

#### R3. X request path review

- Split `builtinGatewayXJSONDocument` into a shape phase (mode, operation,
  `select`/`selection` tree) and a render phase (shared
  `renderGatewayJSONArguments` and the literal serializer). R1 uses the shape
  phase alone for templated arguments. Golden tests pin the documents built
  for a fixed config set before and after the split. `select` and the
  equivalent `selection` must produce the identical document.
- **SDK fact check (first task of the X plan; record the outcome in the plan
  and docs).** Does pinned X SDK 0.1.26 expose its read SDL through a public
  API or an in-process CLI subcommand, with no network or credentials? Does
  pinned GatewaySDKKit 0.1.1 publicly build a `GatewaySchemaCatalog` from SDL?
  - Both yes: the X readers move to `BuiltinGatewayJSONRequest.document` plus
    literal inline serialization, as the Gmail container reader does. The X
    serializer is deleted, `select` is kept only as a conversion to
    `selection`, and R1 gains full X catalog checks.
  - SDL only: derive the Query root-field name set with a bounded scanner and
    use it only for the unknown-operation check. A golden test pins the
    derived set. Riela gets no SDL type parser.
  - Neither: the serializer stays as is.
- **Kept and why.** The literal serializer stays because there is no kit
  catalog and the X reader accepts no variables (`acceptsVariables: false`).
  The SDK stays the authority for argument types. Nested `select` stays as a
  documented compatibility alias. No path is retired. Migration: each `true`
  leaf becomes a dot-path entry, for example
  `{"posts":{"id":true,"author":{"username":true}}}` becomes
  `["posts.id","posts.author.username"]`. No validate warning is added, so
  existing examples such as `x-window-checkpoint` stay diagnostic-free.
  Riela has no X Python helper to remove; ART's helpers are outside riela.

#### R4. Examples

Every example is executable with a credential-free `mock-scenario.json` and
has README.md and EXPECTED_RESULTS.md. Each uses only JSON
`operation`/`arguments`/`selection`/`postprocess` (plus `riela/json-transform`
or `riela/collection-checkpoint`), with no Python, shell or jq.

- **New X example.** `riela/x-gateway-reader` with
  `providerFailure: "output"`, a `selection` that includes `pageInfo.nextToken`,
  a cursor argument from `{{workflowInput.cursor}}` (null on the first page),
  and postprocess pick/unique/map/take. Labeled branches handle
  `providerRetryable` (record "retry later" without looping),
  `providerFailed`/`postprocessFailed` (report), and a default (shape
  `{items, nextCursor}`). X has no riela writer tier, so the example does not
  write.
- **New Notion example.** Read with a cursor argument, then
  `riela/notion-gateway-write` creates one page from typed `processed` data
  (a write). Operation names come from the pinned Notion catalog and must pass
  `workflow validate` on macOS.
- **Gmail.** Extend `examples/builtin-gateway-json` beyond `accounts` with a
  cursor-bearing reader operation (`threads`) and one `riela/gmail-gateway-draft`
  write. The mock count for Gmail is unchanged, and EXPECTED_RESULTS.md is
  added.
- Pagination stays workflow-controlled. The original cursor is preserved, and
  the caller (or `riela/collection-checkpoint`, as in `x-window-checkpoint`)
  passes it to the next run. No gateway loop is added.
- Register the two new names in `rielaExampleWorkflowNames()` and raise
  `ExampleCatalog.expectedMockScenarioCount` by 2 in the same change.
  `expectedNodeMockScenarioCount` is unchanged. Mock runs must not need
  per-example variables in `testMockScenarioExamplesRunThroughSwiftCLI`.

#### R5. Behavioral test matrix

Add one new focused suite (for example `BuiltinGatewayJSONBehaviorTests`) that
uses the existing seams: `localGatewayGraphQLRunner`,
`XGatewayReaderSDK.invocationOverride`, the container runner, the Google
Service `clientFactory`, and the Kaiba injected HTTP client. Each family covers
the cases that apply to it:

- quotes, newlines and `{{...}}` text inside argument values reach the
  provider as data, rendered once;
- null vs missing arguments and map fields;
- empty arrays;
- invalid specs (`policyBlocked`, zero runner calls);
- the 8 MiB argument bound, the 120,000-byte legacy bound, and postprocess
  limits;
- for write tiers (Wrike write, Notion write, Gmail draft/sender, Docs write,
  Google Service write, Apple mutation): a postprocess failure after a write
  keeps exactly one runner call, `postprocessFailed`, `retryProvider: false`,
  and no step retry;
- tier boundaries (a reader rejects a mutation or writer operation, Google
  Service read rejects `services.enable`, Kaiba arguments cannot set the
  connection);
- pagination metadata preserved next to `processed`;
- legacy modes still work (`queryTemplate`, Docs command/flags, X `select`,
  Google Service flat mode including its existing `allPages`, which is kept
  for compatibility and not used by examples).

macOS-only SDK cases use `#if canImport` and are skipped elsewhere.

#### R6. Rollout and verification constraints

- All Swift work shares one package, so the plans are chained:
  R1 → R2 → R3 → R5 → R4 (R4 edits the RielaCLITests catalog/parity files).
  Only the docs plan (`docs/builtin-gateway-json.md`, including adding the
  missing `project` operation to its postprocess table;
  `docs/workflows/json-data-processing.md`, switching its example to
  `selection`; and `impl-plans/builtin-gateway-json-176.md`) may run in
  parallel. It records the implemented-vs-outside-riela split and the R3
  outcome last.
- Verify with focused filters only, each inside `arch -arm64 /bin/zsh -lc`:
  `swift build`, `WorkflowGatewayValidationTests`,
  `WorkflowValidateGatewayContextTests`, `JSONDataTransform`,
  `BuiltinGatewayJSONRequestTests`, the new behavior suite,
  `RielaExampleParityTests`, and `swiftlint lint --quiet`.
- `testMockScenarioExamplesRunThroughSwiftCLI` may already fail on
  `x-follower-ai-business-digest` with VALIDATION_ERROR. Attribute it with
  `--skip` only after reproducing it on a clean detached worktree of
  `origin/main` (18f22b7d). Any other pre-existing failure needs the same
  proof. That skip removes the whole mock-run test, so it would also hide the
  new examples. When the skip is used, each R4 example must also be run
  directly (`.build/debug/riela workflow validate` and
  `workflow run <name> --workflow-definition-dir ./examples --mock-scenario
  ... --output json`, logs under `tmp/issue-176/`), and
  `testAllRielaExampleWorkflowsArePortedAndValidateInSwift` must still pass.

## Provider wiring and compatibility

Wrike, google-analytics, and gmail descriptors are made from their facade's
pinned reader/writer/admin or reader/draft/sender constructors. Existing add-on
IDs, tier payload strings, environment allowlists, and macOS fallbacks do not
change. Google-documents uses its six fixed service/access roles. Apple uses
`AppleGatewaySDK(role:)` only for the two explicitly extended admin add-ons.

Passthrough tests are retained as regression tests. Operation tests cover a
Wrike query with variables, mutation with an input object, fields selection,
analytics, gmail variables and passthrough variables, google-documents argv and
confirm flags, and Apple GraphQL operation mode. Contract tests distinguish
policy construction failures from provider errors and compare recorded
provenance with the actual stand-in call.

## Examples, documentation, and rollout

`examples/gmail-operation-thread-digest` demonstrates reader operation
`threads`, typed input-derived arguments, fields selection, and a mocked LLM
summary. `examples/gateway-schema-lookup` searches the gmail draft catalog with
`(?i)draft` and feeds matches to a mocked agent. One node in
`examples/wrike-project-kanban-agent` moves to operation mode. The two new
examples include README, expected results, and mock scenarios; catalog ordering
and expected mock-scenario counts are updated.

`README.md` and `.agents/skills/riela-node-addons` document both modes, Gmail
passthrough variables, schema discovery, and the CLI. The user-owned brief edit
is preserved. Workflow, prompt, script, or skill edits require refreshed
`riela-package.json` digests; ordinary source, test, example, README, and this
design document do not trigger that refresh.

The effective workflow input supersedes the brief's historical no-push instruction
and the earlier planning-only handoff. Implement plans 01–05 in dependency order,
retain complete verification evidence, and obtain independent adversarial and
integration acceptance with no unresolved material findings. Commit and
non-force push accepted work to `feat/remaining-impl-plans-20260927`, then provide
a PR handoff targeting `main`. Final local HEAD must equal the live remote branch
head. Do not merge main, alter other branches, release, or merge the PR.
The review must explicitly check
the resolved SwiftPM graph, execution policy, error classification, provenance,
static/no-network schema behavior, platform guards, validation injection, and
preservation of unrelated add-ons.

## Verification contract

Before plans 02–05, preserve the existing plan 01 `Package.swift` and
`Package.resolved` changes and their recorded posthashes. The successful
`swift package show-dependencies --format json` graph and lockfile checks do
not complete its behavioral gate. Run a focused Swift test filter that compiles
and exercises the changed gateway dependency integration, and record its actual
positive selected test count, zero failures, complete stdout/stderr log, and
terminal exit code in `impl-plans/progress/gateway-sdk-01.md`. Re-evaluate that
gate from the evidence; a zero-test or incomplete run cannot pass.

For each plan-specific focused filter and the final release build, aggregate
Swift suite, strict SwiftLint, example runs, dependency graph, and
`git diff --check`, retain the exact command, complete log path, final exit
code, and observed assertions. Run verification in the foreground. Independent
review must inspect operation construction, authorization boundaries, error
classification, and payload provenance before integration acceptance.

```bash
arch -arm64 /bin/zsh -lc 'swift build -c release'
arch -arm64 /bin/zsh -lc "swift test --filter 'WrikeGatewayAddonTests|GmailGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|GoogleDocumentsGatewayAddonTests|AppleGatewayAdminAddonTests|AddonExecutionContractsTests|RielaExampleParityTests|WorkflowValidation'"
arch -arm64 /bin/zsh -lc 'swift test'
.build/release/riela workflow run gmail-operation-thread-digest --mock-scenario <name> --output jsonl
.build/release/riela workflow run gateway-schema-lookup --mock-scenario <name> --output jsonl
.build/release/riela addon schema gmail-gateway --tier draft --grep '(?i)draft'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint
```

Any interleaved-submit timing failure in the full suite is recorded with the
test name and rerun evidence. It is accepted as the known flake only when the
focused gateway/validation gate and an isolated rerun establish that the
feature did not introduce the failure.

## Issue-to-design mapping

| Brief deliverable | Design section |
| --- | --- |
| 1. Package dependency wiring | Dependency and platform boundary |
| 2. Generic SDK engine | Add-on execution contract |
| 3. Per-provider wiring and stand-in | Add-on execution contract; Provider wiring and compatibility |
| 4. `riela/gateway-schema` | Static schema discovery |
| 5. `riela addon schema` | CLI behavior; Search-pattern compatibility decision |
| 6. Workflow validation | Workflow validation; Dependency and platform boundary |
| 7. Tests and contracts | Provider wiring and compatibility; Verification contract |
| 8. Examples | Examples, documentation, and rollout |
| 9. README and skill documentation | Examples, documentation, and rollout |

## Risks and review decisions

- **D1 / historical high / resolved by corrected release decision.** v0.3.1
  lacked the facade and kit dependency; that finding remains valid. The operator
  approved v0.3.3, whose local tag peels to supplied public release commit
  `4baeb285f459adb9031273490b922abc8204dedb`. Its manifest declares exact kit
  0.1.0 and its source contains the facade contract used above. See the QA
  document for historical rejection and current command evidence. This resolves
  D1, not the independent design-review gate.

- **High — construction failures can look like provider failures.** Preflight
  GraphQL with the identical catalog and builder; use
  `GoogleDocumentsGatewaySDK.buildArgv` followed by the exact runner; compare
  provenance in stand-in tests; and require adversarial review of every error
  path before acceptance.
- **High — operation mode can widen execution authority.** Keep tier selection
  outside authored configuration, reuse environment allowlists, refuse
  interactive document auth commands in both modes, and retain gateway-side
  authorization.
- **Medium — static discovery can accidentally become platform- or
  credential-dependent.** Centralize catalog-only lookup, test absence of
  network/credential reads, retain Linux shape validation, and fail closed when
  a concrete macOS catalog is unavailable.
- **Medium — regex compatibility can drift from the kit.** Limit Riela's
  `(?i)` bridge to the documented ASCII-literal prefix, run the rewritten form
  through the kit, and test both acceptance and rejection boundaries.
- **Medium — the full Swift suite has a known timing flake.** Record the exact
  occurrence and use focused plus isolated rerun evidence to distinguish it
  from a feature regression.
- **Resolved — temporary local dependencies cannot leak into merge.** The
  operator selected public exact-version URLs for all five gateways and the
  kit. Verify the resolved graph before implementation; reject any local path
  or identity collision.

## Step 2 source review evidence (2026-09-23)

Current authoring base: `fd736844cf370c8cef1642ffc3bea20c8a9b7743` on
`feat/gateway-sdk-addons`; initial working tree clean. Current read-only checks
of all six local release tags and manifests, plus the full Google Documents
v0.3.3 facade, exited 0. Expanded commands, complete log paths, and final
statuses are recorded in `tmp/gateway-sdk-design-step2/commands.json`.
The public release identity comes from effective workflow input; local
commit-addressed source corroborates it without claiming a fresh remote check.

No codex-agent reference was supplied by intake; Cursor CLI mapping is not
applicable. No reference-repository adaptation is required by this issue.

Prior source-review corrections are retained: Apple binaryPath refusal and
config/input compatibility; Gmail build-once execution; raw-envelope error
ordering; validator injection; CLI stepId/defaults. GraphQL build-once execution
intentionally diverges from the brief's invoke closure for Gmail catalog parity.
The Google Documents buildArgv/runner split intentionally preserves the existing
runner contract and does not adopt the facade's separate file/execution policies.

The earlier planning review rejected the previous design for D1. Intake
`comm-000002` supplied the corrected release decision; the five implementation
plans now exist. Historical Step 3 feedback `comm-000004` required a handoff
correction because the old planning-only and branch instructions conflicted with
the effective workflow input. Session 5 intake `comm-000020` now requires plan
01 behavioral test evidence before later-plan work. No unresolved user decision
remains.
