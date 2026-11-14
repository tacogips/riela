# Workflow definition store

The runtime records database stores the canonical workflow definition used by
long-running service runs. It versions the executable workflow and node
payloads together with the authored files, so prompt and structure changes have
one digest and can be restored or exported. A workflow file supplies the
initial definition; after seeding, the SQLite head is authoritative.

## Service runs and one-time runs

| Run path | Definition and prompt source | Session record |
| --- | --- | --- |
| Service mode: GraphQL `executeWorkflow`, RielaApp configured runs, `riela events serve` (including cron and routines), and daemon workflows | SQLite definition store. On first use, the workflow files seed a head. Later edits to workflow, node, shared-node, base, or prompt files are ignored until an explicit import or update. | `definitionSource.kind = store`, with pinned `versionId`, `digest`, and `storeRoot` |
| One-time `riela workflow run` and callers that do not select service mode | Workflow files only. The run does not read or write definition rows. | `definitionSource.kind = file`, with source path, scope, and digest |

Service store selection uses an explicit session store when supplied; otherwise
it follows the requested project, user, or auto scope. Auto checks the project
store before the user store. A newly seeded definition is stored in the root
selected for that run. A service run continues to use its pinned version even
if its source files change. Resume and rerun of a pinned session use that same
version.

Registry updates, editor saves, and `riela workflow register` or
`riela workflow update` do not write the definition store. They remain
file-based registry operations. Use the `riela workflow definition` commands
below to inspect or change a stored definition.

## Seed, import, force, and restore

The first service use seeds a store head from the resolved workflow files. An
explicit `riela workflow definition import <workflow>` compares files with the
current head. It reports `unchanged` or `differs` and the diff without writing
when the workflow is already registered. `--workflow-definition-dir <path>`
selects the source directory; common store selection options are
`--scope project|user`, `--session-store <path>`, and `--working-dir <dir>`.

To replace the store head with the file state, use
`riela workflow definition import <workflow> --force --reason <reason>` or
`riela workflow definition update <workflow> --from-file <path> --force --reason <reason>`.
Force update creates a new audited version and records the intervening
store-only audit IDs and diff in `overwrittenChanges`. Earlier versions remain
available to restore. Import with `--force` requires a nonblank reason.

Restore a saved version with
`riela workflow definition restore <workflow> --version <version-id> --reason <reason>`.
Restore is also a new version and audit entry; it does not erase the history.

## Whole-workflow updates

`riela workflow definition update` edits the authored view and derives a new
runtime definition at the stored source directory. Provide exactly one of:

```sh
riela workflow definition update <workflow> --patch <json-patch-file> --reason "Clarify the retry prompt" --expected-version <version-id> --evidence session:<session-id> --actor <id> --actor-kind cli
riela workflow definition update <workflow> --from-file <workflow-directory> --reason "Adopt reviewed workflow files"
```

`--patch` accepts an RFC 6902 JSON Patch over the authored view. Inspect that
view with `riela workflow definition show <workflow> --authored`. A
`--from-file` update re-resolves the file bundle and checks its workflow ID
against the stored definition. Add `--force` to `--from-file` to run the force
import behavior described above and report overwritten changes.

Writes require a nonblank `--reason`. Optional `--expected-version` provides
optimistic concurrency: a stale version is rejected with
`definition_conflict`. Repeat `--evidence kind:id` for evidence references;
the accepted kinds are `session`, `stepExecution`, and `review`. `--actor`
identifies the caller. CLI `--actor-kind` accepts `cli` or `improvementNode`
and defaults to `cli`. JSON output includes the outcome, version ID, digest,
audit ID when written, and diff. Invalid patches or definitions are rejected
without creating a version.

## Prompt updates and audit history

`riela workflow definition update-prompt <workflow> --node <node-id> --field <field> (--text <text> | --text-file <path>) --reason <reason>`
updates a prompt field and appends a version and audit entry. Fields are
`promptTemplate`, `systemPromptTemplate`, `sessionStartPromptTemplate`, or
`promptVariants.<key>.<field>` using one of those three field names. If several
runtime fields refer to the same authored prompt file, changing that file
updates all of them in the derived runtime.

Use `riela workflow definition history <workflow> [--node <node-id>] [--limit <n>]`
for audit entries, `riela workflow definition show <workflow> [--version <id>]`
for a stored version, and `riela workflow definition diff <workflow>` to compare
versions. Diff accepts `--from <version-id>`, `--to <version-id>`, or `--file`
to compare the store with the current files. Show accepts `--node <node-id>` to
display a single node payload. Commands support `--output text|json`.

Each append-only audit record includes the operation, target node and field
when applicable, before and after digests, structural diff, required reason,
evidence references, actor kind and ID, `approvalState = applied`, and creation
time. Actor kinds are `user`, `cli`, `api`, and `improvementNode`. Force updates
also retain the overwritten audit IDs and changes. Definition versions and
audit rows cannot be updated or deleted.

## Builtin workflow improvement

The version-1 builtins `riela/improve-workflow-context` and
`riela/improve-workflow-apply` support an explicit three-node flow: deterministic
context collection, an author/proposer agent, and deterministic application.
The context addon reads the pinned authored definition and a bounded digest of
the newest terminal, store-pinned run for the same workflow, excluding the
current run and improvement nodes. The digest contains selected per-step input,
output, failure and retry information; session and step-execution IDs become
audit evidence. `config.guideline` supplies the proposer guidance. Context
configuration can bound step count, field length, and total context bytes.

The apply addon validates the proposed reason, patch, evidence and recursion
guard, then invokes only `riela workflow definition update` as a subprocess
with `--actor-kind improvementNode` and the run's pinned expected version. It
does not write definition rows directly. It skips one-time runs with
`oneTimeRun`, and rejects patches that touch the improvement nodes, their
steps, inbound transitions, or their prompt files. See the registered mock
example [`definition-store-self-improvement`](../examples/definition-store-self-improvement/).

## Export

Export returns the authored files from a stored version. Write them to a
directory with
`riela workflow definition export <workflow> --to <directory> [--version <id>]`.
To overwrite the original source directory, use
`riela workflow definition export <workflow> --to-source --overwrite`.
GraphQL export returns the files and can write to the source when
`writeToSource` is true.

## GraphQL surface and schema

The definition API is available through these fields:

- Queries: `workflowDefinitionHistory`, `workflowDefinition`,
  `workflowDefinitionDiff`.
- Mutations: `updateWorkflowDefinition`, `updateWorkflowDefinitionPrompt`,
  `restoreWorkflowDefinition`, `importWorkflowDefinition`,
  `exportWorkflowDefinition`.

Update mutations require a reason and accept evidence, actor, expected version,
and store scope fields. GraphQL actor kinds are `api` and `user`. Import accepts
`force`, `reason`, evidence, actor, source directory and scope. Export accepts
`versionId` and `writeToSource`.

The runtime records database is at schema generation 10. Generation 9 stores
migrate in place to add `definition_blobs`, `definition_versions`,
`definition_heads`, and append-only `definition_change_audit`. A store with
definition heads is never automatically discarded when no migration path is
available.
