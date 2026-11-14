# Opt-in command failure metadata

Issue: https://github.com/tacogips/riela/issues/163

Design: [bounded command failure diagnostics](../design-docs/specs/design-command-failure-diagnostics.md).

A nonzero command exit discards stdout before the session records an output.
Preserve the failed status and default behavior. Add optional command
`failureDiagnostics: {schema, maxBytes, path}`. This is a finite metadata schema,
not an arbitrary output capture switch: closed objects with required keys, arrays
with maxItems <=256, enum-only strings <=64 bytes, integers bounded within
±1,000,000,000, booleans and null. Maximum nesting is 8, stdout cap is 64 KiB
(default selected metadata is capped at 16 KiB). Unexpected fields or invalid
values reject the entire diagnostic. No raw stdout or invalid fragments are
retained. No truncation is presented as valid evidence.

Emit `command_failure_diagnostics` through the existing execution-scoped backend
receipt handler before throwing the original provider error. Metadata carries
`authoritative:false`, exitCode, captureStatus and, only when validated,
diagnostics. This neither satisfies output contracts nor advances workflow
transitions. It is not acceptedOutput/rootOutput and is not interpolated into
failureReason.

The optional trusted `path` (at most eight nonempty object keys, 64 bytes each)
selects the finite diagnostic object. Raw stdout is capped at 64 KiB before JSON
decoding; subprocess readers drain excess while retaining only a sentinel
overflow byte. Selected JSON is independently capped by maxBytes. Oversized
successful output fails rather than accepting truncation. No raw siblings or
raw-output artifact is retained.

## Verification

Verification is recorded in
[`impl-plans/progress/issue-sweep-20261024-163-command-failure-diagnostics.md`](progress/issue-sweep-20261024-163-command-failure-diagnostics.md).

### Adversarial review repair: ISW163-ADV-1

The capped stdout decode now preserves the original uncapped
`String(data:encoding:) ?? ""` path. If capped bytes are not valid UTF-8, the
runner returns only replacement characters sized from the retained bytes, so
the existing executor overflow guard rejects exit-zero output and diagnostic
schema parsing rejects a nonzero capture. Stderr decoding is unchanged. This
avoids accepting an empty result when the capture boundary splits a multibyte
character.

The real-process regression emits one oversized JSON line containing Japanese
multibyte text and exercises both exit 0 and exit 7. Final ARM64 verification
passed: build (`build-r1-final.log`), CommandFailureDiagnosticsTests 8/0
(`cfd-r1-final.log`), WorkflowStdioNodeExecutorTests 14/0
(`stdio-r1-final.log`), LocalProcess 12/0 (`localprocess-r1-final.log`),
RuntimeStoreTests 28/0 (`store-r1-final.log`) and strict SwiftLint 0
(`lint-r1-final.log`). Full commands and integer counts are in the progress
record above.
