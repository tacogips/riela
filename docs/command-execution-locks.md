# Command execution locks

A command node can declare nonblocking, process-local advisory locks:

```json
{
  "command": {
    "executable": "/usr/bin/env",
    "arguments": ["python3", "worker.py"],
    "executionLocks": {
      "directoryEnvironment": "WORK_STATE_DIR",
      "defaultDirectory": ".runtime/worker",
      "resources": [{"name": "worker.lock", "mode": "exclusive"}],
      "busyPayload": {"status": "busy"}
    }
  }
}
```

The directory comes from the runtime's trusted host environment, with the literal
fallback resolved relative to the command working directory. Command-authored
environment overrides do not select the lock root. Declare 1–16 distinct simple
filenames; each mode is `shared` or `exclusive`. Existing lock files must be
regular, owned by the current UID, and have one link. Symlinks and unsafe files
fail before acquisition; successfully opened files have permissions 0600.
All participating processes must use the same directory and preserve lock files
while active. These are cooperative local locks, not cross-host leases.

The runtime acquires the whole set without waiting and releases any partial set
on contention. With no busy policy, contention fails the node. `busyPayload`
returns an authored JSON object (at most 64 KiB) without executing the command.
Alternatively, `onBusy: "run"` explicitly delegates contention handling to the
command: the child runs without a lock receipt and must implement its own guard.
This supports commands that must durably admit a request before returning busy.
`onBusy` and `busyPayload` cannot be combined.

On acquisition, the runtime retains the locks through command completion and
cancellation cleanup. It inherits only the acquired file descriptors into the
direct child, accompanied by `RIELA_COMMAND_LOCKS` JSON containing `directory`
and `resources` (`name`, `mode`, `fd`). Incoming values of that environment key
are stripped; the receipt is a description of real descriptors, not a permission
flag. A participating child must validate descriptor identity against the lock
file and retain it until work finishes. Mark it non-inheritable before launching
unrelated descendants. Closing the native owner's descriptor does not unlock a
live child's inherited descriptor. An interpreter or launcher that closes extra
descriptors is incompatible with child-side reuse and must not silently bypass
its own guard. The runtime never persists the descriptor receipt as workflow state;
a resumed invocation acquires fresh resources.
