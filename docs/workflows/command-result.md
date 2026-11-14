# Bounded command results and trusted cancellation owners

`riela/command-result` version `1` runs one explicitly authored executable using
the standard native process runner and returns its outcome as JSON data. It is
useful inside `collect-all` fanout: one nonzero exit does not prevent peers from
finishing. It performs no retry, scheduler admission, source ACK or publication
verification. Executables and arguments are trusted workflow configuration;
never derive command authority from article/mail instructions.

```json
{
  "executable": "/usr/bin/env",
  "arguments": ["my-worker", "--phase", "collect"],
  "timeoutMs": 300000,
  "maximumStdoutBytes": 65536,
  "cancellationPolicy": "await-owner",
  "stdoutSchema": {
    "type": "object",
    "properties": {"status": {"type": "string", "enum": ["ok", "partial", "failed"]}},
    "required": ["status"],
    "additionalProperties": false
  },
  "context": {"job": "collect"}
}
```

`executable` must be an absolute path. `arguments` is a typed JSON string array;
values substituted as an entire array are literal, without a second template
pass or implicit shell. An explicit shell executable still runs the authored
shell code. `environment` optionally supplies at most 128 string overrides on
top of the runtime process environment; `workingDirectory` defaults to the
workflow directory. Put credentials in the inherited process environment, not
configuration/variables/arguments that may be retained as workflow metadata.
Mailbox/input/output paths and command-lock receipts are stripped: this new
process does not inherit descriptors proving those capabilities. Stdin is closed.

Limits: 1 MB serialized configuration, 1,024 arguments, 32,768 bytes per
argument/environment value, 4,096 bytes of passthrough `context`, a 1–7,200,000 ms
work timeout (default 120,000) clipped to the node deadline, and 1–1,000,000 stdout
bytes (default 65,536). Excess stdout is drained without retaining it; stderr
is discarded natively. NUL-containing executable, argument, environment or path
values are rejected before launch.

Completed processes return `status: "completed"`, integer `exit_code` and
bounded `stdout`; the exit code is data, not a source-completion assertion.
Timeout, spawn failure and invalid/overflowed capture return respectively
`timed_out`, `unavailable` or `invalid_summary`, with no raw error/stderr/output.
Cancellation propagates and never becomes a successful domain receipt.

When `stdoutSchema` is supplied, stdout must be one JSON object. The node
recursively projects declared object properties, drops undeclared and invalid
optional metadata, validates required fields/arrays with the standard output
schema validator, and returns only the projected JSON in `stdout`. Projection
requires a single explicit supported `type` at every level (untyped or composite
subschemas are omitted, or fail when required), and is bounded to 16 levels and
10,000 array items; unknown fields cannot enter
runtime output or artifacts. Without a schema, bounded stdout is returned
literally and may contain sensitive data; callers own that declaration.

## Cancellation policies

The default `terminate-group` retains existing native process behavior: request
TERM, escalate after the normal grace and reclaim the owned group before
returning. `await-owner` is for trusted drivers that themselves cancel and await
all writers/children before exiting. Native cancellation/deadline requests TERM
on the direct owner only, never SIGKILL or group-signals, then retains process,
pipe and admission ownership until owner exit and EOF. Cleanup can exceed the
work deadline. An uncooperative owner can wait indefinitely; this option is not
for arbitrary shell jobs or an owner that abandons children holding its pipes.

The same optional `command.cancellationPolicy` field is available on ordinary
command nodes. It preserves existing executionLocks across cleanup. ART uses
`await-owner` for its root driver and worker commands. Existing commands without
the field keep their default termination behavior.
