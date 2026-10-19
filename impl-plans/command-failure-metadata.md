# Opt-in command failure metadata

Issue: https://github.com/tacogips/riela/issues/163

A nonzero command exit currently discards stdout before the session records an
output. Preserve the failed status and default behavior. Add optional command
`failureDiagnostics: {schema, maxBytes}`. This is a finite metadata schema, not
an arbitrary output capture switch: closed objects with required keys, arrays
with maxItems <=256, enum-only strings <=64 bytes, integers bounded within
±1,000,000,000, booleans and null. Maximum nesting8, stdout cap64KiB (default16KiB).
Unexpected fields or invalid values reject the entire diagnostic. No raw stdout
or invalid fragments are retained. No truncation is presented as valid evidence.

Emit `command_failure_diagnostics` through the existing execution-scoped backend
receipt handler before throwing the original provider error. Metadata carries
`authoritative:false`, exitCode, captureStatus and, only when validated, diagnostics.
This neither satisfies output contracts nor advances workflow transitions. It is
not acceptedOutput/rootOutput and is not interpolated into failureReason.

Existing canonical runtime SQLite backend receipt persistence and session export
provide access and retention; no separate raw artifact files are introduced.
ART must explicitly declare a finite jobs-status schema before opting in. Never
apply this to raw private source/gateway output or free-form strings.

Validation: synthetic exit1 stdout regression, default no capture, finite schema
and byte bounds, private extra-key rejection, command Codable roundtrip, persisted
session/backend receipt proof. Public release remains blocked by the existing
private Notion dependency; source branch may be committed and pushed.

The optional trusted `path` (at most eight nonempty object keys, 64 bytes each) selects the finite diagnostic object. Raw stdout is capped at 64 KiB before JSON decoding; subprocess readers drain excess while retaining only a sentinel overflow byte. Selected JSON is independently capped by maxBytes. Oversized successful output fails rather than accepting truncation. No raw siblings or raw-output artifact is retained.

## Verification

47 focused adapter/runtime-store tests passed, plus stdin ownership coverage in the earlier 21-test run. Actual synthetic CLI command exit1 and supported session export verified selected metadata persisted, private sibling sentinel absent, no acceptedOutput/rootOutput. Independent source review passed. SwiftLint and diff checks passed. Public release remains held because the current Riela dependency graph includes a private Notion SDK.
