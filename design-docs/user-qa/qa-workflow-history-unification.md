# Workflow History Unification: Open Decisions

Design: `design-docs/specs/design-workflow-history-unification.md`.

Implementation can go ahead with each recommended decision below. Each
question records an interpretation that the user may want to override.

## Q1: Registry, restore and self-improve edits over store-only changes

The intake requires every registry, restore and self-improve file change to
write a definition-store version. The store has one head, so those versions
become the head that service runs use. When the head carries store-only
changes (`definition update`, `update-prompt`, improvement-node edits) made
after the last file-derived version, a file-derived write replaces them.

Recommended decision: write the version anyway. Record the replaced changes
in `overwritten_changes_json`, exactly as `import --force` does. Return a
warning with the overwritten audit ids. The replaced version stays
restorable.

Alternative: refuse the file change with `definition_diverged` unless the
caller passes an explicit override. That would need new flags on `riela
workflow register|update`, GraphQL registry inputs and RielaApp editor
saves.

This reverses `qa-workflow-definition-store.md` Q1 ("registry and editor
edits stay file-only") for these paths.

## Q2: Where the rollback policy lives and which version's policy applies

Recommended decision: `workflow.json` →
`loop.regressionRollback.policy` (`manual | approval-required |
automatic`). The policy comes from the rollback target's stored document,
the version before the improvement. An improvement therefore cannot raise
its own rollback policy. Absent means `manual`.

## Q3: Registry delete

Recommended decision: write an audit-only `registryDelete` row that links
the before-delete bundle snapshot. Write no tombstone version: a version
must be a runnable, validated document, and definition heads cannot be
deleted.

Service resolution is unchanged. A deleted registry workflow whose name
still has a store head keeps running in service mode, as it does today.
Re-registering it continues the same lineage. Blocking service runs after a
delete would be a separate change.

## Q4: Which runs trigger regression evaluation automatically

Recommended decision: the explicit `workflow definition rollback check`
(CLI and GraphQL) always works. The post-run hook evaluates only
store-pinned service runs that declare `loop.regressionRollback`.

One-time runs (`riela workflow run`, `loop start`) keep the #179 rule that
they never open definition tables. Their regressions are evaluated by an
explicit or scheduled check.

## Q6: Store writes while a bundle rollback is in flight

A bundle-mode rollback changes files first and the definition head second.
Between those steps it holds a durable `applying` claim. Store-only writers
do not take the file lock: `definition update`, `update-prompt`, `restore`,
`undo`, `redo`, `import --force`, improvement-node apply and store-mode
rollbacks.

Recommended decision: while the claim exists, those writers fail with the
retryable `definition_rollback_in_progress`. A claim left by a crashed
process is resolved by the next `rollback approve|check`, registry or
coordinator recovery, or `workflow definition import` for that workflow.

The alternative, letting them write and then failing the rollback after
files have already changed, would leave files and the definition out of
step.

## Q5: Manual policy semantics

Recommended decision: `manual` stores a `recorded` proposal for information
only. It cannot be approved. The user rolls back by hand with `riela
workflow definition restore`. `approval-required` stores a `pending`
proposal that can be approved or rejected.

## User answers (2026-11-02)

Q1-Q6: accept the recommended decisions.

Q7 (user requirement, binding): history and proposal storage must stay bounded.
- One-time CLI runs (`riela workflow run`, including `--workflow-json` temporary
  workflows, and `loop start`) must never write definition rows, audit rows or
  proposal rows. Keep a regression test for this.
- A change whose document digest equals the current head must not create a
  version. Repeated unchanged syncs must not accumulate unbounded audit-only
  rows either: collapse or skip a repeated identical no-op, or make those rows
  subject to definition retention.
- Reverse §5.5 "No delete path exists, and retention, `riela gc`, prune and
  compact do not touch the table" for rollback proposals. Terminal proposals
  (`recorded`, `rejected`, `applied`, `failed`) must be pruned by definition
  retention (`prune`/`purge-history`/default history retention) and by
  `riela gc`/automatic retention, e.g. dropped together with, or after, the
  definition versions they reference falling out of retention. Only `pending`
  and `applying` proposals are protected.
