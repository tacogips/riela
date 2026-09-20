# Monja agent collaboration live acceptance

## Scope

Verify the example in `examples/monja-agent-collaboration` using real Riela
agent executions and Monja REST API authentication. The agents solve one
decision task through a linked Monja discussion.

## Prepared resources

- Task: `01M2H8ZH69JZ71V1FBZGD5K9TR` (Project A task 4).
- Task title: Riela trio: decide reliable webhook delivery semantics.
- Channel: `01M2F80H1T93WQRSWZFBEMF1KY`.
- Coordinator: `01M2F80J3ZJXVVTW2BX7SQAD4W`.
- Aster (architect): `01M2H8YACF1YN17MA5QJ5XV7AK`.
- Flint (skeptic): `01M2H8YAXH0GEB3QWG90DGJ4XZ`.
- Mira (integrator): `01M2H8YBD89V0VFR5T2HA973J4`.

All three persona keys were verified with `GET /api/v1/auth/me`. Each resolves
to the expected bot and grants only `read` and `write` for the discussion
channel. Credentials are stored in Kinko; this document contains no tokens.
Read-only capability probes also confirmed all three bots can read the shared
thread (HTTP 200) while direct task reads are concealed (HTTP 404); the
coordinator supplies task data to the workflow.

## Acceptance status

Passed on 2026-09-15 with Project A task 6,
`01M2HBQB7F2NMHJK05P4HZ1FH3`. All three real agents completed and published
their ordered discussion with distinct bot authors. Mira returned `solved: true`,
an empty `unresolved` list, and ten acceptance criteria. Canonical API reads
confirmed the task is done with one linked root and exactly three replies.
Earlier unsuccessful attempts are recorded below for an honest execution history.

## Final accepted run

- Task: `01M2HBQB7F2NMHJK05P4HZ1FH3` (Project A task 6).
- Root: `01M2HBQPSJKG5GQCF0ZG2V37DM`.
- Aster reply: `01M2HBRF784A8TFHXCKA4PJAXP`.
- Flint reply: `01M2HBSEBP28W5C02YG5X7RKQE`.
- Mira reply: `01M2HBT3P2AK55GCYXX7P2J5W2`.
- Runtime root: `tmp/monja-agent-collaboration/01M2HBQB7F2NMHJK05P4HZ1FH3/riela`.
- Session: `monja-agent-collaboration-session-1` in that runtime root's store.

The three execution records are `architect-attempt-1-exec-1`,
`skeptic-attempt-1-exec-2`, and `integrator-attempt-1-exec-3`; all completed with
the real `codex-agent` backend and `gpt-5.6-luna`. All three nodes use read-only
execution and fresh session policies. Their rendered system prompts differ.

Deep comparisons of accepted outputs and input snapshots confirm that Flint
received Aster's exact output and Mira received Flint's complete cumulative
output containing Aster's original proposal. The final recommendation addresses
atomic consumer effects, external-side-effect idempotency, ordering gaps,
retention expiry, authorized replay, authentication, and monitoring. All ten
acceptance criteria and the empty unresolved list are visible in Monja.

Final same-state replay exited successfully and returned the same root and
reply IDs. Subsequent canonical reads still showed three replies and three
completed Riela executions, proving the replay did not duplicate the discussion
or launch new model calls.

Independent checks and final TypeScript review passed: 21 tests, 62 assertions,
99.47% function coverage, and 98.58% line coverage. The actual local Riela CLI
validated, inspected, and ran the deterministic mock fixture successfully.

## First live attempt

Session `monja-agent-collaboration-session-1` created linked root
`01M2H9G61B3CM3BF3HSHX5KT59`. Aster ran with `gpt-5.6-luna`, but returned only
the `message` field on both attempts. Riela rejected the output with
`output contract $.persona required property is missing`. No persona replies
were published and the task remained open. The prompts required matching a
schema without including its field definitions; the next attempt must use
explicit output shapes. This failure is retained as evidence of the completion
gate, and is not a successful acceptance run.

## Successful recovery

The fixed prompts include each role's exact plain-JSON output shape. The runner
was invoked with `MONJA_COLLABORATION_STATE` pointing to the ignored recovery
directory `tmp/monja-agent-collaboration/01M2H8ZH69JZ71V1FBZGD5K9TR-recovery`.
It reused the existing linked root and retained the failed run's separate
artifacts. `MONJA_API_URL` was the full API base ending in `/api/v1`; the four
Monja credentials were injected by Kinko.

The recovery session `monja-agent-collaboration-session-1` is scoped to that
recovery directory's session store. Its three completed execution records are:

| Persona | Execution | Monja reply |
| --- | --- | --- |
| Aster | `architect-attempt-1-exec-1` | `01M2H9ZAVAHJBD2FD6GEHBVR9A` |
| Flint | `skeptic-attempt-1-exec-2` | `01M2HA04V5A3TSVTKBJXCM8JYN` |
| Mira | `integrator-attempt-1-exec-3` | `01M2HA0WE142QK869BXYC5925A` |

All three used the real `codex-agent` backend with `gpt-5.6-luna`. Each step
declares `sessionPolicy.mode: new`; the adapter starts a fresh conversation
unless reuse is requested. Their persisted system prompts differ. This example
separates execution context and role expertise; it does not provision separate
AI-provider accounts or long-term per-agent knowledge databases.

Independent inspection of canonical session status verified:

- Aster's accepted payload exactly equals the `architect` object in Flint's
  accepted output.
- Mira's runtime inbox contains Flint's review and Aster's complete proposal.
- Mira returned `solved: true` and ten testable acceptance criteria.
- The Monja thread has exactly three ordered replies, authored by the matching
  three bots, all under the original root.
- The task has exactly one link and status `done`.
- Re-running the CLI with the same recovery state exited successfully with the
  same root and reply IDs. A fresh API read still showed exactly three replies,
  and session status still showed three executions: no duplicate discussion or
  new model execution was created.

The discussion produced a recommendation for at-least-once webhook transport
with consumer idempotency. Flint identified transaction-boundary, concurrency,
retention, replay, and monitoring gaps. Mira incorporated those objections into
the final decision and acceptance criteria. Numeric operating limits and
integration-specific ordering remain explicit implementation choices; the
requested decision exercise is complete, not a production rollout.

View the discussion in the [Monja channel](https://monja-api.tacotest.workers.dev/c/01M2F80H1T93WQRSWZFBEMF1KY).

## Strict-gate compatibility attempt

Task 5 created root `01M2HBBSZP7TF5QS3T5BSZA8MF`. Aster and Flint completed
and published real discussion turns, but Mira's outputs were rejected because
the authored `allOf`/`if` conditional used an unsupported runtime schema keyword.
The task remained open. The fix removes that conditional from the schema and
retains the `solved`/`unresolved` invariant in the typed output parser and runner.

The current Swift CLI cannot resume terminal validation failures, and rerun
starts with variables without importing prior discussion executions. This
failed run is retained without editing its runtime records; final acceptance
uses a fresh task after actual CLI mock verification of the corrected schema.
