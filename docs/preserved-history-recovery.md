# Preserve accepted discussion during recovery

After a sequential agent workflow fails, repair the target node's prompt or output schema and run:

```sh
riela session rerun SOURCE_SESSION_ID FAILED_STEP_ID --preserve-history --session-store PATH
```

The library equivalent is `DeterministicWorkflowRunRequest(..., rerunFromSessionId: ..., rerunFromStepId: ..., preserveHistory: true)`.

Riela creates a new session. Earlier accepted executions are imported as evidence, not dispatched again. Their accepted messages retain exact payloads and ordering. New session, execution, and communication identities are generated; `_rielaInput` describes those new identities truthfully. Each imported execution has `importedFrom` with source session/execution IDs and a mapping from imported communication IDs to source communication IDs. Follow these pointers for original backend/usage evidence. Imported records carry no new backend events, usage, adapter output, or finalization tokens and do not count as new node executions. The failed source is unchanged, and import lineage survives CLI/SQLite reload.

Supported recovery is intentionally bounded to failed sequential agent invocations: one accepted execution per prefix step, one direct communication per accepted step, and a recorded failed target. Multiple failed validation attempts at that target are allowed, as is recovery of a failed recovery. Repeated accepted loop boundaries, fanout, cross-workflow/addon/command-only histories, missing or changed communication evidence, and absent invocation compatibility snapshots are rejected. Ordinary rerun without the flag still starts with fresh input.

Invocation snapshots record SHA-256 compatibility digests, not raw node configuration or resolved process environments. Earlier accepted node contracts, workflow-step identity/routing, and variables must match. The failed target's input contract must match, while its prompt/output contract may be repaired. Sources recorded before compatibility evidence existed cannot be safely imported and produce an explicit diagnostic.

This is execution recovery, not side-effect deduplication for the failed target itself. A target may have performed external work before failing; use the destination API's idempotency mechanism when retrying that work.
