# Task handover: orphaned owner

This example uses a short workflow to demonstrate recovery when the attempt owner disappears before executing a node. After the lease expires, an operator can fence the owner and reserve a takeover.

Typical task commands:

```sh
riela task run <task-id>
riela task takeover <task-id> --force-orphan
```

The plain mock workflow completes. The harness uses a never-launched owner because the workflow has no long-running node; the running-owner lease-loss case is covered by `TaskHandoverLeaseTests`.
