# Durable metadata queue

`riela/durable-queue` version `1` owns bounded durable request admission,
immutable request scope, fair pending selection, attempt accounting and completion.
It does not call a provider, scheduler, model or publisher. All configuration is
literal JSON after normal authored variable substitution; pass request objects
through variables to preserve nested strings literally.

```json
{
  "storage": {"directory": ".state/requests", "name": "acquisition"},
  "action": "admit",
  "identity": "window-2026-10-25",
  "request": {"start": "2026-10-25T00:00:00Z", "end": "2026-10-25T01:00:00Z"}
}
```

The directory is relative to the workflow execution directory unless absolute.
Names accept ASCII alphanumerics, `_` and `-`, starting with an alphanumeric;
identities additionally permit `.` and `:`. No path components may be symlinks.

Actions have closed fields, in addition to `storage` and `action`:

| Action | Inputs | Result |
| --- | --- | --- |
| `admit` | `identity`, object `request` | `identity` |
| `pending` | optional `limit` (1–100), `maxAttempts` (1–1,000,000,000) | `found`, nullable `identity` and `request`; `items` and `itemsTruncated` with `limit`; `exhausted` and `exhaustedCount` with `maxAttempts` |
| `attempted` | `identity` | `identity` |
| `finish` | `identity`, boolean `complete`, finite ASCII `status`, optional `completionField` | `identity` |

Admission reopens an existing identity only if its request is unchanged. It does
not reset its registration or attempt history. Selection chooses an unattempted
pending request first, then the oldest attempt, registration instant and identity.
With `limit`, `items` follow the same selection order and `itemsTruncated` indicates the output byte bound stopped the list. `maxAttempts` excludes rows at or above the cap and reports their identities and attempt counts in `exhausted`. Exhausted rows remain pending and are reported on every call until `finish` completes them. Without either option the output remains unchanged.

`pending` also returns the branch label `found` (alongside `always`), so a
workflow can drain a queue in a loop without another routing node.

Selection is an observation, not a lease: callers retain their existing cycle
admission or otherwise coordinate worker ownership. `attempted` records an attempt
without completing it. Only explicit `complete: true` makes `finish` terminal;
`status: "partial"` alone cannot do so. Completion means the caller's stated work
unit, not verification of provider acquisition, research or publication.

The node uses `name.json` and the interoperable `name.lock` flock. It accepts the
existing version-1 `{version:1, requests:{identity:row}}` journal, retaining row
metadata and recognizing `acquired` as a legacy terminal state. Rows contain
`request`, `status`, `registered_at`, `attempts`, and optional `last_attempt_at`.
Native terminal status is `completed`. `finish.completionField` optionally names
an existing boolean observation field (default `complete`); reserved structural
fields cannot be overwritten. This lets callers retain their existing metadata
schema without provider-specific names in the node. Dates compare by instant, accepting
fractional UTC and explicit offsets. No migration rewrites pending scopes or
marks them acquired. Existing writers must use the same lock; cutovers must
preserve the directory and queue name.

Reads reject symlinks, hardlinks and nonregular files. Descriptor-pinned
read/modify/write uses a private temporary file, fsync and atomic rename under
an exclusive lock; files have mode 0600 and newly created directories 0700.
An absent queue read creates no directory or files. Lock contention is bounded
at five seconds and honors cancellation/deadline checks. Cancellation before
rename leaves the old journal intact; after rename a receipt may be unavailable,
so observe durable state before deciding whether to run external work again.

Limits: 10,000 retained requests, 256 KiB per new request, 7,990,000 bytes for
journal/input/output and one billion attempts per item. Exhaustion or malformed
state refuses with a finite error, preserving the previous journal. Completed
rows are retained for immutable-scope validation; the node never silently drops
pending or completed identities. Keep article bodies/images in separate cache
spaces and configure metadata queues per workflow/account as appropriate.
