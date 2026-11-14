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

## History retention

Definition history uses `VersionedHistory`. Automatic retention keeps 10
versions by default and runs inside every definition commit. Set
`workflowDefinitions.historyRetention` in `~/.riela/config.json`, or pass
`--history-retention <n>` on definition import, update, prompt update, or
restore. Values are 0 (unlimited) or 1...10000. The compatibility key
`retention.definitions.keepVersions` aliases the same setting; if both keys
appear in one file, they must match.

The retention window protects the current head, the last-file version, versions
pinned by live sessions, and former heads from the previous 24 hours. A live
session pin remains until its session row is removed; retention releases stale
pins lazily. If migration records `pendingBackfill`, commits skip deletion until
`riela storage compact --apply` completes the definition pin backfill.

Guarded delete triggers restrict version and audit deletion to the engine's
retention transaction. They protect against accidental and ad-hoc deletes, but
are not a security boundary against a local database writer that deliberately
sets the guard. An audit row is removed only when both its version and its
`previous_version_id` were dropped. Immutable version identity rows remain even
after document payloads are pruned, allowing the store to distinguish a known
but unretained version from an unknown ID.

`undo` and `redo` move the current head and append an audit record; they require
`--reason` and accept `--expected-revision <n>` or `--expected-version <id>` for
compare-and-swap. They do not move `last_file_version_id`. The CLI commands are
`riela workflow definition undo <workflow>` and
`riela workflow definition redo <workflow>`; GraphQL exposes
`undoWorkflowDefinition` and `redoWorkflowDefinition`. Diffs use the shared
structured diff format. A known version whose payload has been pruned fails
with `definition_version_not_retained`, with the retained versions and window
in the error details.

Explicit prune and purge-history commands are still available for immediate
cleanup. Each writes an audit record with the reason, actor and removed version
IDs (as `remove` diff entries under `/versions/<id>`, plus removed audit and
blob counts), subject to the protected versions above.

Keep at most N versions of one workflow, or of every workflow in the selected
stores:

```sh
riela workflow definition prune <workflow> --keep 20 --reason "Trim old prompt versions"
riela workflow definition prune --all-workflows --keep 20 --reason "Monthly cleanup" --dry-run
```

`--keep` counts the newest versions. These versions are always kept as well:
the current version, the last file import (the baseline for `import`
comparisons and `overwrittenChanges`), any version pinned by a session, and
recent former heads within the 24 hour grace period. Pins do not depend on
session status. An audit row is removed only when both the version named by
that row and its previous version were dropped. Earlier prune records stay
unless both versions they connect were removed. History rows contain the
document payload, so dropping a version removes its payload. A prune that
would remove nothing writes no record.

Delete the whole history except the protected versions:

```sh
riela workflow definition purge-history <workflow> --reason "Start a clean history" --yes
```

Purge deletes every audit record of the workflow, including earlier `prune`
records, and writes one `purgeHistory` record in their place. It requires
`--yes`. Both commands accept `--dry-run`, which reports the same result
without changing rows and without requiring a reason.

Retention never moves the head or its revision. Restoring, diffing or
exporting a removed version fails with `definition_version_not_retained`. Resuming or
rerunning a completed, failed or cancelled session whose pinned version was
removed fails the same way. Sessions recorded in a different store are
protected through persisted pins. Automatic retention and `riela gc` use the
shared engine with a default window of 10. `retention.definitions.keepVersions`
aliases `workflowDefinitions.historyRetention`; if both keys are present in
one config file, they must match. A value of `0` keeps all generations during
automatic retention and `riela gc`. They use the actor `cli:riela-retention`.

## GraphQL surface and schema

The definition API is available through these fields:

- Queries: `workflowDefinitionHistory`, `workflowDefinition`,
  `workflowDefinitionDiff`.
- Mutations: `updateWorkflowDefinition`, `updateWorkflowDefinitionPrompt`,
  `restoreWorkflowDefinition`, `undoWorkflowDefinition`,
  `redoWorkflowDefinition`, `importWorkflowDefinition`,
  `exportWorkflowDefinition`.

Update mutations require a reason and accept evidence, actor, expected version,
and store scope fields. GraphQL actor kinds are `api` and `user`. Import accepts
`force`, `reason`, evidence, actor, source directory and scope. Export accepts
`versionId` and `writeToSource`.

The runtime records database is at schema generation 11. Generation 9 and 10
stores migrate in place to the shared definition-history tables. A store with
definition heads is never automatically discarded when no migration path is
available.
