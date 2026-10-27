# Session cancellation and reconciliation

Riela stores graceful cancellation as the terminal `cancelled` session status
with `failureKind: cancelled`. The CLI exits with code 1 for a cancelled run.
Readers use `WorkflowSession.isCancellation`; legacy rows stored as
`failed` with `failureKind: cancelled` still count as cancellation. Cancelled
sessions cannot be resumed, but can be rerun.

When the host task is cancelled during an agent-gateway turn, the adapter
propagates cancellation instead of reporting a provider, authentication, or
policy failure. A vendor response that says “cancelled” without host task
cancellation keeps its existing behavior. Deadline expiry remains a timeout.

## Reconcile a runner that stopped unexpectedly

Use `riela session reconcile` to inspect running sessions. The command is a
dry run by default. Add `--apply` to mark orphaned sessions cancelled:

```sh
riela session reconcile [--scope project|user] [--session-store <dir>] \
  [--working-dir <dir>] [--session <id>]... \
  [--abandoned-after-hours <h>] [--apply] [--output json|text]
```

The command checks running CLI records and canonical runtime snapshots using
scalar database queries. For each candidate, it attempts the same exclusive
per-session `flock` held by a running persisted runner. A held lock reports
`live` and is not changed; an acquired lock reports `orphaned`. Retention
tombstones report `retired`, read or save races report `skipped`, and an
explicit session id that is not running reports `notRunning`. With `--apply`,
the command re-reads the record while holding the lock, then saves the
cancelled status and reason
`runner process lost; reconciled by riela session reconcile`. Running step
executions are cancelled with that reason as well.

The lock liveness check is supported for session stores on local filesystems
shared by processes on the same host. Network-filesystem stores are unsupported.

Reconcile also inspects unsettled nested invocations whose parent is terminal.
The nested pass runs after running-session reconciliation and uses
`--abandoned-after-hours` (default 24; range 1...8760). A reservation is
eligible when the invocation and parent are older than the threshold, the
child is terminal, absent, or still `created`, and both parent and child
execution locks can be acquired without blocking. Recent reservations are
reported as `recent`; held locks are `live`. Suspended sessions are never
changed.

With `--apply`, reconcile rechecks eligible rows while holding both locks,
records `abandoned_at`, and cancels a reserved `created` child with reason
`reservation abandoned; reconciled by riela session reconcile`. Abandoned rows
no longer keep their session family from terminal retention when the child is
absent. The report's `nestedInvocations` entries include each verdict, whether
it was applied, and an optional reason.

## Follow-ups

P3 cancellation-aware auto-improve supervision does not apply: auto-improve
supervision was removed. P5 detached execution and later attach/reattach
remain a follow-up and are outside this change.

See the [2026-10-24 cancellation contract](../design-docs/specs/design-cancellation-and-orphan-session-resilience.md#2026-10-24-contract-issue-27)
for the accepted issue #27 behavior and scope.
