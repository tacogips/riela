# Expected results

- Validation succeeds with steps `work` and `finish`.
- The plain mock workflow completes.
- The task harness simulates an owner dying before execution, refuses `--force-orphan` before lease expiry, seals an `ownerLost` packet after expiry, and fences a revived heartbeat. The successor dispatch currently returns `task attempt has no durable terminal session for guard evaluation`; the predecessor is reconciled as `failed(leaseLost)` and the task remains `verifying` until the task-dispatch runtime gap is repaired.
