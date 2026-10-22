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

Admission acquires all requested slots before container launch and retains them
through output validation and owned container cleanup, including cancellation.
Waiting counts against the existing node deadline and never extends it. A full
pool waits asynchronously; deadline expiry returns a timeout without launching
work. Cancellation releases any partially acquired capacity. Kernel file locks
release on process exit; do not delete or replace pool files during live work.

The `riela/private-workflow` add-on can declare this policy on its outer sandbox
to reserve capacity for the whole private graph. Inner nodes do not inherit the
host pool; reserve the graph's maximum concurrent model usage using `weight`.
Do not reserve the same slots again in a controller wrapping an admitted node.

The gate is `admission.lock`, slots are `0` through `capacity - 1`, and `capacity`
records the fixed pool size. Weighted admission releases all partial slots and
the gate before waiting, so a large queued request does not strand capacity.
Files use owner-only permissions, non-following opens and close-on-exec. The
gate/slot protocol interoperates with ART's legacy four-slot `flock` pool during
migration; its Python controller must relinquish its own reservation when the
declared node begins owning admission.
