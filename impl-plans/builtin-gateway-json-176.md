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
codec lives alongside the common request builder; `selection` field paths and
existing nested `select` objects address the same read-only SDK. Operation and
selection names stay literal. Arguments render once, and source text containing
template syntax stays data. No extra gateway executable is spawned.

Every built-in resolver accepts optional `config.postprocess`. It precompiles
the same finite instructions used by `riela/data-transform` before calling a
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
- Prepare Apple operation requests on the macOS host for Linux private workers;
  the current Apple operation builder requires the macOS SDK and cannot yet run
  in a Linux guest. Legacy Apple query bridging is unchanged.
- Reconcile Core validation/catalog discovery with all runtime modes and aliases.
- Verify Google Service and Kaiba inputs use the common contract where needed;
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
