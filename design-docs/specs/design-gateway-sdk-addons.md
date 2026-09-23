# Operation-mode gateway SDK add-ons and schema discovery

Status: revised for independent Step 3 review; historical dependency finding D1
is resolved by the operator-approved Google Documents v0.3.3 decision. Design
acceptance is pending; no implementation plan or Swift implementation is authored here.
The dependency decision is recorded in
`design-docs/user-qa/qa-gateway-sdk-worktree-dependencies.md`

Issue: `docs/briefs/gateway-sdk-addons-2026-09-04.md`

Workflow: `codex-design-and-implement-review-loop-session-1`

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
release state. This execution is planning-only; implementation and provider calls
are not authorized. Step 2 authors design; independent design review and detailed
implementation-plan authoring remain later workflow steps. It must not modify the GatewaySDKKit checkout, any gateway
worktree, or the main Riela checkout.

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

The effective workflow input supersedes the brief's historical no-push instruction.
Only accepted design, QA, brief, implementation-plan and necessary index changes
may be committed and pushed on `feat/gateway-sdk-addons`; main integration requires
a later implementation run and its independent review; no merge to main is
authorized in this planning-only run. Independent Step 3 design acceptance
must precede actionable plan authoring, and the plan needs its own independent
review before publication. Step 2 performs none of these publication actions. The review must explicitly check
the resolved SwiftPM graph, execution policy, error classification, provenance,
static/no-network schema behavior, platform guards, validation injection, and
preservation of unrelated add-ons.

## Verification contract

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

Historical Step 3 feedback `comm-000004` rejected the previous design for D1.
Current intake `comm-000002` supplies the corrected release decision. This
revision addresses D1 using v0.3.3 evidence, preserves the historical v0.3.1
finding in QA, and awaits a new independent Step 3 decision. No actionable
implementation plan, Swift edits, package resolution, commit, or push occurs
in this author node. No unresolved user decision remains.
