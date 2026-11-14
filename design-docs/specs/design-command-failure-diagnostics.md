# Opt-in bounded command failure diagnostics (#163)

Issue: https://github.com/tacogips/riela/issues/163

Reference implementation: commit `155f1145` on `fix/command-failure-metadata`
(read-only). It conflicts with the current tree in `README.md` and
`Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`. Port its intent by
hand; do not cherry-pick it. The current executor builds command processes with
`inheritEnvironment: false` (added after `155f1145`), and the port must keep that.

## Problem

When a command node exits nonzero, its stdout is discarded before the session
records anything. Operators cannot see the structured job status a failing
command printed. Accepting failed stdout as output is not the fix: a failed
command must still fail, and its data must never satisfy an output contract.

## Behavior

`WorkflowCommandExecution` gains an optional `failureDiagnostics` policy:

```json
{"command": {"executable": "...", "failureDiagnostics": {
  "path": ["diagnostics"], "maxBytes": 16384,
  "schema": {"type": "object", "additionalProperties": false,
             "properties": {"state": {"type": "string", "enum": ["queued", "failed"]}},
             "required": ["state"]}}}}
```

- **Default (policy absent).** Behavior is exactly as today: nothing from
  failed stdout is captured, and the stdout capture limit is unchanged.
- **Opt-in, nonzero exit.** stdout is decoded as one JSON value. The trusted
  `path` (at most 8 non-empty keys of at most 64 bytes, with no control
  characters) selects an object. That object must satisfy the restricted
  schema, and its encoded size must be at most `maxBytes` (1...65,536, default
  16,384). The executor emits exactly one backend event:
  `provider: "command"`, `eventType: "command_failure_diagnostics"`,
  `channel: .lifecycle`, with metadata
  `{authoritative: false, exitCode, captureStatus: "validated"|"rejected"}`.
  `diagnostics` is included only when `captureStatus` is `validated`. The
  executor then throws the same `providerError` it throws today. The failure
  reason never interpolates diagnostics.
- **Opt-in, zero exit.** The process runner retains at most
  `65,536 + 1` stdout bytes and drains the rest without retaining or streaming
  it. Exit-zero stdout above 65,536 bytes fails with `providerError`
  ("command stdout exceeded diagnostic capture limit"). It is never accepted
  as truncated output.
- **Rejection.** Oversized stdout, invalid JSON, a missing path, a non-object
  selection, an unexpected field, an invalid value, an invalid schema, or
  `maxBytes` out of range all produce only `captureStatus: "rejected"`.
  Rejection retains no raw stdout, no fragment and no raw sibling field.

### Restricted schema

The schema is deliberately smaller than JSON Schema, and it has a maximum
nesting depth of 8:

| type | exact key set | bounds |
| --- | --- | --- |
| `object` | `type, properties, required, additionalProperties:false` | ≤64 properties; required keys unique, declared and present; object keys ≤64 bytes |
| `array` | `type, items, maxItems` | `maxItems` 0...256 |
| `string` | `type, enum` | 1...64 non-empty enum strings ≤64 bytes with no control characters; value ≤64 bytes |
| `integer` | `type, minimum, maximum` | bounds within ±1,000,000,000 and `minimum ≤ maximum` |
| `boolean`, `null` | `type` | — |

Free-form strings, open objects, `$ref`, regex, coercion and annotations are
unsupported. They reject the diagnostic, not the workflow.

## Boundaries and data flow

- Scope: local stdio `command` nodes in `LocalWorkflowStdioNodeExecutor`.
  Container nodes, mock-scenario stdio executors and distributed workers are
  unchanged.
- The existing execution-scoped `context.backendEventHandler` delivers the event,
  which `DeterministicWorkflowRunner+ExecutionEvents` already forwards with
  `metadata`. `InMemoryWorkflowRuntimeStore.appendRecentBackendEvent` retains
  `metadata` only for `eventType == "command_failure_diagnostics"`. Other
  events keep dropping metadata, exactly as today. Persistence and session
  export use the existing session snapshot of `recentBackendEvents`. No new
  artifact files or store tables are added.
- Metadata never becomes `acceptedOutput`, `rootOutput` or a route message. It
  never advances a transition.

## Files (port of `155f1145`)

`Sources/RielaCore/WorkflowFailureDiagnostics.swift` (new),
`Sources/RielaCore/WorkflowModel.swift` (field and both coding-key enums),
`Sources/RielaCore/RuntimeStore.swift` (metadata retention for this event only),
`Sources/RielaAdapters/LocalProcess.swift` (`stdoutCaptureByteLimit`),
`Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`,
`Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift` (new),
`Tests/RielaCoreTests/RuntimeStoreTests.swift`, `README.md` (opt-in paragraph),
and `impl-plans/command-failure-metadata.md` (ported plan record).

## Acceptance evidence

Focused suites:
`arch -arm64 /bin/zsh -lc 'swift test --filter CommandFailureDiagnosticsTests'`,
`--filter WorkflowStdioNodeExecutorTests` and `--filter RuntimeStoreTests`.
They must cover these cases:

- a nonzero exit without a policy captures nothing and still fails;
- a nonzero exit with a valid diagnostic emits `validated` metadata and still
  fails with `providerError`;
- an extra private sibling or field yields `rejected` with no diagnostics;
- oversized stdout yields `rejected` on failure and `providerError` on exit
  zero;
- schema bound violations are rejected;
- `WorkflowCommandExecution` survives a Codable round trip with
  `failureDiagnostics`;
- the store retains metadata only for this event type, `acceptedOutput` stays
  nil, and the metadata survives encoding and decoding.
