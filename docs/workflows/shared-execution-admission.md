# Shared sandbox execution admission

Sandboxed agent nodes and builtin add-ons can share a host capacity pool across
App instances, workflow runs and separate CLI processes. Declare admission in
the existing `sandbox` object:

```json
{
  "backend": "container",
  "ephemeralHome": true,
  "container": {"runtime": "apple-container", "image": "example:local"},
  "admission": {
    "directoryEnvironment": "MY_MODEL_POOL_DIR",
    "capacity": 4
  }
}
```

The host must supply `MY_MODEL_POOL_DIR` as an absolute, host-owned dedicated
directory, shared by every participant. It is not a workflow input template and
is not automatically passed to the guest. There is no fallback to another pool
when it is missing or unavailable. `weight` defaults to 1; `waitTimeoutSeconds`
defaults to 600. Capacity is 1–64, weight is 1–capacity and the wait bound is
1–3600 seconds. Every participant must declare the same capacity; a mismatch is
rejected. Different pools require different directories.

The pool directory must be on a local filesystem. On NFS or SMB, `flock` is
emulated with per-process record locks, so two leases in one Riela process
could both own a slot. Admission refuses known network filesystems (NFS,
SMB/CIFS, AFP, WebDAV, AFS, Coda) with a `policy_blocked` error. Other
shared or FUSE filesystems are not detected; do not use them for a pool.

Each refusal has its own fixed message without paths, for example "pool
directory variable is not set by the host", "pool directory is not owned by
the current user", "must be on a local filesystem", "lock file must not be a
symbolic link" or "capacity differs from the shared pool".

Since 0.2.41, `minimumRemainingSeconds` (default 0, range 0–3600) reserves a
minimum execution window in the existing node deadline. Admission refuses to
launch when that window is unavailable, both before waiting and immediately
after acquiring capacity. It does not extend the node deadline or guarantee a
full model turn. For example, a brief can wait at most 5 seconds and require
30 seconds remaining with `waitTimeoutSeconds: 5` and
`minimumRemainingSeconds: 30`.

Admission acquires all requested slots before container launch and retains them
through output validation and owned container cleanup, including cancellation.
Waiting counts against the existing node deadline and never extends it. A full
pool waits asynchronously; deadline expiry returns a timeout without launching
work. Cancellation releases any partially acquired capacity. Kernel file locks
release on process exit; do not delete or replace pool files during live work.

Builtin add-on acknowledgment and terminal workers use the same persisted
pool, weight and wait bound as execution, within their own finalization
deadline. Since 0.2.42, these control operations do not apply the execution
startup reserve (`minimumRemainingSeconds`). Scheduling settings are excluded from the
sandbox worker-state directory identity; tuning admission does not relocate
that persistent state.

A busy pool can therefore delay finalization. Acknowledgment runs after each
accepted step and waits at most 60 seconds (or the shorter wait bound). Its
failure never fails the accepted step or the finished session. Instead, the
runner logs a `riela.workflow.addon.finalization.skipped` warning (telemetry)
and, when a run event handler is attached, streams a backend event of type
`riela.addon.finalization.skipped` with the operation (`acknowledge` or
`terminal`), the finite error code and a bounded reason. The add-on keeps its
pending records, so a later resume re-drives the skipped work. A terminal
record that fails for one invocation no longer skips the remaining
invocations; records are removed only after all of them succeed.

The `riela/private-workflow` add-on can declare this policy on its outer sandbox
to reserve capacity for the whole private graph. Inner nodes do not inherit the
host pool; reserve the graph's maximum concurrent model usage using `weight`.
Do not reserve the same slots again in a controller wrapping an admitted node.

The gate is `admission.lock`, slots are `0` through `capacity - 1`, and `capacity`
records the fixed pool size. Weighted admission releases all partial slots and
the gate before waiting, so a large queued request does not strand capacity.
The trade-off is that there is no queue or fairness. Waiters poll every 25 ms
and the first one to find enough free slots wins. A weight-k request needs k
slots free at the same moment, so steady weight-1 traffic can starve it until
its wait bound expires. Finalization workers have no priority over execution
either. Size `capacity`, `weight` and `waitTimeoutSeconds` with that in mind,
or keep heavy and light work in different pools.

The `capacity` record is the decimal pool size followed by a newline. It is
read and written only while holding the gate. A record without the trailing
newline can only come from an interrupted first write. No acquisition ever
succeeds against such a record, so the next participant rewrites it with its
own capacity instead of leaving the pool unusable. A complete record that is
not a number is refused as corrupt; remove it only while the pool is idle.

Files use owner-only permissions, non-following opens and close-on-exec. The
gate/slot protocol interoperates with ART's legacy four-slot `flock` pool during
migration; its Python controller must relinquish its own reservation when the
declared node begins owning admission.
