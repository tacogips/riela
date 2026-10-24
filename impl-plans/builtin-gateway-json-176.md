# Shared gateway JSON requests and finite postprocessing (#176)

The target is workflow-only invocation of every built-in gateway, including
preparation and shaping, without embedded Python. This plan supplements the
historical operation-mode design; it does not mark its unfinished phases done.

## Current implementation under verification

`BuiltinGatewayJSONRequest` builds typed SDK requests using each add-on's fixed
catalog. Gmail, Wrike, Analytics and Notion share the GraphQL engine. Docs,
Sheets and Drive use the same argument contract and their SDK's `buildArgv`,
retaining its construction validation and normalization, while execution keeps
the existing command runner. This does not add SDK file-access policies or SDK
execution limits. Apple GraphQL uses its
full-role catalog and existing invoker/config precedence. Legacy request modes
remain available; Gmail's legacy `variablesTemplate` remains rejected while
operation mode passes typed variables to its async SDK.

X's SDK currently exposes SDL rather than a kit catalog. Its bounded literal
document serializer lives alongside the common request builder. Since the
2026-10-24 review it renders `arguments` through the shared
`renderGatewayJSONArguments` (8 MiB bound), parses `selection` with the shared
`BuiltinGatewayJSONRequest.fieldPaths` validator, and reports `policyBlocked`
like the other gateways. Existing nested `select` objects remain an X-only
compatibility form. Operation and selection names stay literal. Arguments render
once, and source text containing template syntax stays data. No extra gateway
executable is spawned.

Every built-in resolver accepts optional `config.postprocess`. It precompiles
the same finite instructions used by `riela/json-transform` before calling a
provider. The outer container resolver removes the instructions from its leaf
request, so transformation runs once and preserves finalization receipts.

```json
{
  "name": "riela/gmail-gateway-reader",
  "version": "1",
  "config": {
    "operation": "accounts",
    "arguments": {},
    "selection": ["id"],
    "postprocess": [{"pick": "/data/accounts"}]
  }
}
```

The original payload remains present, including pagination cursors. Shaped
output is `payload.processed`; `postprocessPassed`/`postprocessFailed` provide
branch flags. A data-dependent shaping failure preserves the completed provider
result and returns `postprocess.status: failed, retryProvider: false`. It never
replays a successful write. Invalid instruction syntax fails before the effect.

## Remaining acceptance work

- Complete behavioral coverage of typed requests for every affected gateway,
  legacy container gateways and already structured product-specific nodes.
- **Complete for catalog-backed built-ins covered by the Riela CLI production context (V0–V5).** `riela workflow validate` now checks operation/legacy mode conflicts, operation and selection literal bounds, non-templated postprocess programs, and known operations when a pinned SDK catalog is available. Notion read/write are included; aliases and legacy modes remain valid. `GatewaySchemaCatalog.operations` publicly lists GraphQL root operations and full document command names; production projection uses these names. Verification: see `impl-plans/progress/issue-sweep-20261024-176-gateway-validation.md`.
- **Still open:** X readers, legacy container readers (`riela/x-gateway-read`, `riela/gmail-gateway-read`), Google Service and Kaiba nested-argument validation remain runtime-only.
- **Review fixes (2026-10-24):** validation accepts a missing `arguments` like the
  runtime (`{}`) and still rejects a present non-object; a parity table test checks
  that validation and runtime agree. Postprocess bounds the picked values instead of
  the provider payload, so container readers that repeat the response in
  `xGateway.data` and `xGateway.response` no longer fail at about 4 MB. One shared
  8 MiB constant (`GatewayJSONLimits.maximumEncodedBytes`) bounds arguments and
  transforms. The non-existent `riela/gmail-gateway-threads` and
  `riela/gmail-gateway-message-box` validation entries are removed (the gateway
  schema tiers stay). The builtin-addons image now pins the same Analytics and
  Documents revisions as `Package.resolved`, and `scripts/check-container-pins.py`
  checks every Containerfile pin in the Linux CI build.
- **What remains of #176, by requirement:**
  - Requirement 1 (common validation): argument names and types, X readers,
    legacy container readers, Google Service and Kaiba nested arguments are
    validated only at runtime. The production validation context is applied only by
    `riela workflow validate`, not by `workflow run`, GraphQL, registry activation or
    the console.
  - Requirement 3 (no X-only converter or notation): X keeps its own SDL document
    serializer and the nested `select` form until the X SDK exports a catalog.
  - Requirement 4 (workflow-controlled retry): X failures are all
    `providerError`; spend cap, rate limit and transient errors are not yet
    structured error metadata.
  - Completion criteria: practical X and Notion workflow examples without Python
    (only a Gmail `accounts` mock example exists), ART Python removal, private image
    adoption, App cutover and release-deployment acceptance.
- Reconcile named operations and compatibility surfaces in the final matrix;
  preserve fixed operations of product-specific Apple nodes.
- Complete the provider matrix, workflow examples and user-facing reference.
- Run the requested actual Claude Opus review; resolve actionable findings.
- Release/install the verified runtime and align ART workflow, private guests,
  configuration and App execution before claiming deployment.
- Finish removing ART Python that merely prepares model input, invokes built-ins
  or validates outputs. Preserve source state, receipts and publication behavior.

## Verification checkpoint (2026-10-23)

The initial macOS focused suite passed 68 tests. Actual CLI execution of Gmail
`accounts` plus postprocessing passed against a credential-free local fixture.
Actual `account(id: ...)` calls with `personal` and a nonexistent ID returned the
matching account and null respectively, proving SDK variable binding rather than
only an empty-variable metadata request. No provider network access was needed.

The requested actual Claude Opus 5.5 review completed successfully. Its literal
Apple selection, scenario postprocess and X orphan-selection findings were
fixed; the final focused macOS suite passed 71 tests and the actual Opus 5.5
follow-up review found no blocking issue. The pinned kit parser explicitly
rejects trailing operations and fragments; corresponding injection regressions
are included. A repository source search found no preexisting built-in
`postprocess` configuration consumer. Shaping failures now use explicit flags
also for X reads; downstream workflows must branch before using `processed`.

Riela 0.2.44 is published and locally installed. These newer changes are not
part of that release. ART's configured production CLI remains 0.2.33 until a
verified cutover; changing the global executable does not update that pin.

## Host preparation and Google Service checkpoint

Apple container requests are compiled against the macOS host catalog before
dispatch. A runtime-selected variable namespace carries the built document,
variables and config path through exact placeholders; source template syntax is
never expanded again. Existing host capability capture still authorizes only
the exact resulting argv, with workspace/mount restrictions and no addon.env or
binary override. No wire protocol or portable Apple catalog copy is added.

Focused Apple/container/postprocess tests passed 39 cases. An opt-in real Linux
guest test passed using the existing ART image with the published 0.2.44 Linux
runtime and standard worker wrapper mounted read-only. Its native provider is a
fixture: the test proves real guest transport and host capability enforcement,
without contacting Apple services or requesting permissions. The initial image
alone lacked the required worker entrypoint; the mounted-runtime test is the
successful evidence, not that failed attempt.

Google Service now accepts literal `operation` plus typed `arguments`, rendered
through the shared bounded helper. An explicit argument object excludes flat
overrides and refuses unknown operation arguments before constructing a client.
Its existing flat mode remains supported. Google Service/shared request/Apple
capability focused tests passed 21 cases. The final expanded suite passed 50 cases. Actual Claude Opus 5.5 review
and fixes-only follow-up found no remaining actionable issue. Retry policy is
resolved before host preparation and retained as bounded literal metadata; the
real guest test also verifies zero retries reaches the native provider fixture.
Optional config paths are parsed by fixed argv layout, avoiding values that
look like flag names. Nested Google Service arguments refuse explicit addon
inputs as well as flat config overrides. Full matrix and deployment acceptance
remain outstanding.

## Legacy reader and Kaiba checkpoint

Legacy `riela/x-gateway-read` and `riela/gmail-gateway-read` now accept JSON
operation inputs before starting their runtime. X shares the embedded reader's
bounded codec. Gmail builds against its reader catalog and serializes the
validated AST without variable declarations for older reader CLIs. Substitution
uses declared types, including nested input objects, lists and enums; source
strings are JSON-escaped literals. The resulting document is validated again,
and mutations, multiple operations and oversized documents fail before launch.
Existing image, environment framing and read-only runtime restrictions remain.

Kaiba named add-ons accept `config.arguments`; their add-on name already fixes
the operation. They use the same bounded renderer moved to RielaAddonSupport.
Nested arguments exclude flat config/input overrides and cannot select an
endpoint, authentication or a different captured instance. Instance selection
stays in top-level `kaibaInstanceId` and the preflight snapshot. GraphQL
compatibility add-ons still accept an explicit document as data; they no longer
template already-rendered variables a second time in either input mode.

Legacy/shared focused tests passed 21 cases (one existing live-container test
skipped). Kaiba/legacy/shared focused tests passed 19 cases with no skips. Tests
cover reader-only execution, enum and source-text round trips, pre-launch
rejection, named Kaiba HTTP request variables, connection restrictions and
literal GraphQL variables. An attempted credential-free metadata check against
the existing legacy Gmail image returned AUTH_REQUIRED with networking denied;
it is not a passing legacy SDK integration gate. Published 0.2.44 SDK metadata
and variable binding evidence above is a separate, successful check.

The no-script example `examples/builtin-gateway-json` validates successfully and
its one-node mock workflow completed with typed account IDs in `processed` and
the original data retained. Its runtime/session proof lives under
`tmp/gmail-linux/gateway-json-example/`. The provider/input/isolation matrix and
finite instruction reference are in `docs/builtin-gateway-json.md`.

The final regression suite passed 34 cases with no skips, including captured
legacy launch argv, oversized UTF-8 document rejection before runtime launch,
duplicate variable definitions, unsupported catalog `select`, Kaiba literal
GraphQL structure and explicit-input conflicts. An end-to-end common resolver
test combines nested Kaiba arguments with postprocessing: exactly one injected
SDK HTTP request executes, source template text remains literal, and the
original cursor remains available. This fixture does not contact a Kaiba server.
Legacy JSON argv documents are capped at 120,000 bytes; nested Kaiba document
and operation names remain authored literals, with dynamic data in variables.

Actual Claude Opus 5.5 fixes-only follow-up found no additional implementation
bug. Its test-strength suggestions were applied without runtime changes: the
legacy argv gate now proves accepted 119 KB/rejected 121 KB inputs and the X
cap-specific error; Kaiba templates render otherwise plausible valid documents
and operation names. The final 34-test suite passes with zero skips, SwiftLint
reports no warnings, and the no-script example again completes through the
actual workflow runner with its credential-free mock. This completes this
legacy/Kaiba source chunk, not release, ART migration or deployment acceptance.

## Released foundation (0.2.45; ART migration still incomplete)

Tag v0.2.45 is immutable at 40639ca85d86a5421f8b4c4ad576bdd292428863.
All six macOS arm64 / Linux arm64 / Linux x64 archive and checksum assets are
published. Linux release run 39878893182 and amd64 CI 39878863106 succeeded.
The local Homebrew formula was updated, installed CLI reports 0.2.45, and
`brew test tacogips/tap/riela` passes. The installed binary completes the
no-script gateway example against credential-free account metadata, retaining
original data and producing typed processed IDs.

The release-matched macOS host and downloaded Linux arm64 guest also complete
the example through the actual container worker, using read-only fixture/runtime
mounts and denied networking. No credential material or provider service is
used. This is a real guest transport/SDK/postprocess gate, not ART acquisition.
Proofs are under tmp/gmail-linux/release-045-proof.json and release-045-private/.
The initial moved compiler cache failed on stale absolute module paths; only
its inactive generated compilation tree was removed before the successful build.
Published 0.2.44 archives and persistent ART data were preserved.

ART remains pinned to CLI 0.2.33 and its previous production graph. Shared JSON
release/install is complete; Core validation/discovery reconciliation, the full
ART Python migration, private image/config adoption and actual App cutover are
not complete. Issue #176 remains open.
