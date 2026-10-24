# Preserve accepted discussion during recovery

After a sequential agent workflow fails, repair the target node's prompt or output schema and run:

```sh
riela session rerun SOURCE_SESSION_ID FAILED_STEP_ID --preserve-history --session-store PATH
```

The library equivalent is `DeterministicWorkflowRunRequest(..., rerunFromSessionId: ..., rerunFromStepId: ..., preserveHistory: true)`.

Riela creates a new session. Earlier accepted executions are imported as evidence, not dispatched again. Their accepted messages retain exact payloads and ordering. New session, execution, and communication identities are generated; `_rielaInput` describes those new identities truthfully. Each imported execution has `importedFrom` with source session/execution IDs and a mapping from imported communication IDs to source communication IDs. Follow these pointers for original backend/usage evidence. Imported records carry no new backend events, usage, adapter output, or finalization tokens and do not count as new node executions. The failed source is unchanged, and import lineage survives CLI/SQLite reload.

Supported recovery is intentionally bounded to failed sequential agent invocations: one accepted execution per prefix step, one direct communication per accepted step, and a recorded failed target. Multiple failed validation attempts at that target are allowed, as is recovery of a failed recovery. Repeated accepted loop boundaries, fanout, cross-workflow/addon/command-only histories, missing or changed communication evidence, and absent invocation compatibility snapshots are rejected.

The `--retry-failed-step` option also accepts a current step that timed out. Retrying can repeat side effects performed before the timeout; use the destination API's idempotency mechanism when needed.

Invocation snapshots record SHA-256 compatibility digests, not raw node configuration or resolved process environments. Earlier accepted node contracts, workflow-step identity/routing, and variables must match. The failed target's input contract must match, while its prompt/output contract may be repaired. Sources recorded before compatibility evidence existed cannot be safely imported and produce an explicit diagnostic.

This is execution recovery, not side-effect deduplication for the failed target itself. A target may have performed external work before failing; use the destination API's idempotency mechanism when retrying that work.

## Plain step rerun input carry-over

A plain `riela session rerun SOURCE_SESSION_ID STEP_ID` (without `--preserve-history`) carries the source's inbox state as of the target's latest execution:

- The target's recorded inbox (`_rielaInput.communicationIds`, recorded for agent, command, container, and add-on steps) is carried. Every recorded id must be a delivered or consumed workflow message addressed to the target. A message produced by a source execution that is not completed with accepted output is rejected; manager, handover, and event messages (no producing execution) are skipped.
- Every other step the rerun can reach also gets the workflow messages it had received up to that point (messages no newer than the target's newest recorded message, from accepted completed executions). A loop back-edge therefore still finds its checkpoint: rerunning `integration-review` that routes `plans_remaining` back to `dispatch-plans` gives `dispatch-plans` its `plan-git-push` message.
- Producing executions and messages are imported with new identities and `importedFrom` pointers. They do not count as new executions and do not shift attempt numbers, `RIELA_NODE_EXEC_ID`, or mock-scenario indices of re-executed steps.

Rejected recorded inbox evidence stops the rerun before a new session is created with `cannot carry rerun input: recorded inbox communication <id> is missing or unaccepted; use --preserve-history or rerun an earlier step` (the message names the unaccepted producer when there is one). Carrying requires a failed, suspended, or completed source. A created or running source is rejected only when something would be carried; a rerun that carries nothing (for example of an orphaned `running` session's entry step, or of a step that never ran) starts with fresh input. A plain rerun keeps the caller's session lineage whether or not it carries evidence; its recovery lineage names the source. Carried and bound evidence is not checked against the current workflow or package version, so a rerun after an upgrade reuses evidence produced by the earlier version.

## Protected finalization evidence

For the protected `codex-design-and-implement-review-loop`, a plain or
preserved-history step rerun checks git finalization evidence before creating
the new session. It binds the latest accepted commit, push, integration, and
plan commit/push executions; a completed retry is used when an earlier attempt
failed. Mode evidence is imported only when its step is outside the rerun's
reachable path, so a full restart cannot inherit a stale workflow mode. If the
source cannot provide complete evidence, rerun from the first unbound evidence
step or use `riela session resume SOURCE_SESSION_ID --retry-failed-step`.
Preserved-history reruns that encounter an ambiguous repeated boundary also
recommend rerunning without `--preserve-history` or resuming the failed step.

## Handover history

Task takeover can import accepted history from a same-store source session that
ended `suspended` or `failed` with `.stalled`, `.cancelled`, or `.leaseLost`.
A remote successor can instead import the bounded history bundle carried by the
handover packet. Imported executions record the source session and handover in
`importedFrom`, including `importedFrom.handoverId`, so the original evidence
remains traceable without replaying accepted steps.

A truncated packet history bundle is refused; it is never treated as a complete
history. Read the canonical handover packet from the controller work store and
retry through the supported takeover path.
