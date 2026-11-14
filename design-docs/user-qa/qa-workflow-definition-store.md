# Workflow Definition Store: Open Decisions

Design: `design-docs/specs/design-workflow-definition-store.md`
(tacogips/riela#179 section 2, the execution-mode policy, (A) the
whole-workflow CLI/GraphQL update with a reason, and (B) the builtin
improvement node).

Implementation can go ahead with each recommended decision below. Each
question records an interpretation that the user may want to override.

## Q1: Registry and editor edits after a workflow is registered in the store

`riela workflow register|update`, the GraphQL mutable-registry mutations,
and RielaApp editor saves all write workflow files. Under the issue's rule
that registered workflows ignore later file changes, those edits do not
reach service runs (the RielaApp API, `riela serve`, `events serve` and
cron) until someone runs `riela workflow definition import --force --reason
...` or the `importWorkflowDefinition(force: true)` mutation.

**Decision (user, 2026-10-25, reverses the earlier recommendation for CLI
and GraphQL):** whole-workflow updates of a store-registered workflow go
through the CLI and GraphQL as audited store versions with a mandatory
reason. The surface is `riela workflow definition update <workflow>
(--patch <file> | --from-file <path> [--force]) --reason ...` and the
`updateWorkflowDefinition` mutation (design §5 and §8).

The existing `riela workflow update` is not extended. It is keyed by
mutable-registry identity (workflowId, scope, originId) and runs a file
transaction, and the policy keeps file-based CLI behavior as it is. An
`update` against a workflow with no head fails with
`definition_not_registered` and never seeds.

Still file-only: `riela workflow register|update`, the GraphQL
mutable-registry mutations and RielaApp editor saves, because RielaApp
editor UI changes are out of scope. Their edits reach service runs only
through `import --force` or `update --from-file`.

## Q2: Store selection when no store is named

Each project (`<cwd>/.riela/sessions`) and each user (`~/.riela/sessions`)
has its own runtime records database. A service request with `auto` scope
checks the project store first and then the user store. A new head is
seeded into the store where the run's session is written (the existing
`storeRootForRun` rule).

Recommended decision: keep this order. It matches
`design-execution-environment-consolidation.md` §4.2. The head key is the
workflow name within each store. One workflow name therefore means one
definition per store, whichever directory seeded it. A request that names
a different source directory gets a warning diagnostic and still uses the
stored version.

## Q3: Actor and approval values

The issue lists actors as user, improvement node and CLI. This design uses
the actor kinds `user | cli | api | improvementNode`:

- CLI writes are `cli`. `--actor-kind improvementNode` is passed only by
  the `riela/improve-workflow-apply` add-on, which records actor id
  `<workflow>/<nodeId>@<workflowExecutionId>/<operationExecutionId>`.
- GraphQL writes are `api` or `user` (the caller chooses; the default is
  `api`). GraphQL rejects `improvementNode`.
- Automatic seeding uses the triggering service's actor (`api`, or `cli`
  with id `events-serve`).

The earlier generic `addon` kind is dropped, because the improvement node
is its only writer. `approval_state` is always `applied`, because the
section 4 approval flow is out of scope.

Recommended decision: accept these values. Section 4 will add
`pending | approved | rejected` to the same column without a schema change.

## Q4: Run paths that stay one-time

Work Runtime task dispatch, `loop start`, specialists, distributed-worker
runs, editor draft launches, `--workflow-json*` and `--from-registry` keep
reading files and record `definitionSource.kind = file`.

Recommended decision: accept. The issue lists the RielaApp API, daemon,
events serve and cron as the service paths. RielaApp daemon workflows run
through `events serve`, so they are covered.

## Q5: Shape of the builtin improvement node

The issue asks for one builtin improvement node that sees its own
workflow, the latest-run digest and a guideline, and applies a change with
a reason through the riela CLI. Builtin add-ons are deterministic code, and
mock-scenario replaces a listed node's whole output. A single add-on that
also called an LLM would either hide the CLI apply behind the mock, or need
new mock semantics.

Recommended decision: use three nodes. `riela/improve-workflow-context` (a
builtin) builds the input. An ordinary agent node written by the workflow
author proposes `{patch, reason}`; it is the only mocked step.
`riela/improve-workflow-apply` (a builtin) checks the proposal and runs
`riela workflow definition update` as a subprocess. The guideline is the
context add-on's inline `config.guideline`. Design §9.

## Q6: Which run is the "latest run"

Recommended decision: the newest terminal, store-pinned
(`definitionSource.kind = store`) session of the same workflow in the run's
session store, other than the current session. Improve-node executions
are excluded. A digest of the current session is not used, because the
current session is still running and the issue asks for the latest run's
log. The first service run of a workflow therefore never improves, and the
second run reviews the first.

After an earlier improvement has moved the head, the digested session may
have pinned an older version than the current run's base version. Its
evidence then describes the older prompts, while the patch targets the
current run's pinned view. This is accepted for this scope. The audit
records the evidence session ids, so the mismatch stays traceable.

## Q7: Re-deriving the executable form on whole-workflow updates

Recommended decision: `update` edits the authored files, then re-runs the
normal bundle loader at the head's `source_directory`. Own-directory reads
are served from the new authored files. The `extends` base and `nodeRef`
targets are read from disk at write time. This keeps `export` exact and
keeps stdio paths anchored where the scripts actually are. If a base file
changed since the last version, that change appears in the write's diff.
Service runs still never read files.
