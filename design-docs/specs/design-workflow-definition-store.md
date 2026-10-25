# Workflow definition store: SQLite definitions, audited prompt changes, and the service-vs-CLI execution policy

Status: proposed 2026-10-25 for tacogips/riela#179. In scope:
section 2, the execution-mode policy written in that issue, (A) a
whole-workflow update through the CLI and GraphQL with a mandatory reason
(§5, §8), and (B) the builtin improvement node from section 3, limited to
definition and prompt changes and the bounded latest-run digest it reads
(§9). Open decisions:
`design-docs/user-qa/qa-workflow-definition-store.md`. Out of scope: the
section 1 observability surfaces beyond that digest, the section 3
memory/cache/kv candidates and their history, section 4 (evaluated
adoption and approval) and section 5 (self-improve cleanup), and RielaApp
editor UI changes.

This is the first implemented slice of the definition store in
`design-execution-environment-consolidation.md` §4. It narrows that design
(workflow kind only, no workspace scopes, no activation, fork, consolidate or
package-as-import) and changes one of its decisions, the one-time CLI run
(§10 below). The consolidation design keeps the rest of the E0 scope.

## 1. Policy

| Execution | Definition and prompt source | Run record |
| --- | --- | --- |
| Long-running service: GraphQL `executeWorkflow` (served by `riela serve`, the serve web host and RielaApp), the RielaApp configured-run API, and `riela events serve` (all event sources, including cron and routines, plus RielaApp daemon workflows, which spawn `events serve`) | **The SQLite definition store.** The workflow file only seeds a store entry on first use. Later file changes are ignored until an explicit force import | `definitionSource.kind = store`, pinned `versionId` and `digest` |
| One-time CLI: `riela workflow run`, library `executeWorkflow`, and every other caller that does not set service mode | **Workflow files only.** No definition row is read or written | `definitionSource.kind = file`, source path, scope and `digest` |

Files are default values. In service mode every improvement accumulates in
SQLite. `export` can write the store back to files, but the store stays
authoritative. Improvement follows the same split: the builtin improvement
node (§9) writes store versions only from store-pinned service runs, and
does nothing in a one-time run.

## 2. Verified current state (`f4fcf68c`)

- Every run path reaches `WorkflowRunCommand.runWithoutSpecialistMonitor`
  (`Sources/RielaCLI/WorkflowRunCommand.swift:46`). It calls
  `resolveRunBundle` (`:626`), which uses the injected
  `resolver: any WorkflowBundleResolving` (`:14`, default
  `FileSystemWorkflowBundleResolver`). Callers:
  - GraphQL `executeWorkflow` goes through `WorkflowExecutionProvider`
    (`Sources/RielaCLI/WorkflowExecutionProvider.swift:27`). It is wired in
    `ServeHTTPCommand.swift:175`, `ServeWebHost.swift:213` and
    `RielaApp/RielaAppWebGraphQL.swift:48`.
  - The RielaApp configured-run API goes through `launchConfiguredWorkflow`
    (`WebWorkflowRequestHandler+ConfiguredLaunch.swift:9`, file resolve at
    `:29`).
  - Event runs, including cron through `CronOverlapDispatcher`, go through
    `runEventWorkflow` (`EventReadOnly.swift:27`) and then
    `CLIEventWorkflowRunner` (`EventLiveServe.swift:981`). Event trigger
    defaults come from `CLIWorkflowTriggerDefaultsResolver`
    (`EventLiveServe.swift:967`).
- No field on `WorkflowRunOptions` (`RielaCommand.swift:308`),
  `WorkflowSession` (`RuntimeSession.swift:383`) or
  `PersistedCLIWorkflowSession` says whether a run is a service run or a
  one-time run. No session records which definition it ran
  (`mutableRegistryDigest` is never persisted).
- `ResolvedWorkflowBundle` (`WorkflowRegistryBundleLoader.swift:5`) holds the
  workflow and its node payloads after inheritance and shared-node
  materialization. `PromptTemplateAssetLoader.hydrate`
  (`Sources/RielaCore/PromptTemplateAssets.swift:26`) fills `promptTemplate`,
  `systemPromptTemplate`, `sessionStartPromptTemplate` and their
  `promptVariants.<key>.*` counterparts from the `*File` paths, and keeps
  the paths. `absolutizedStdioPaths` (`:203`) makes relative
  `command.executable`, `command.workingDirectory` and
  `container.workingDirectory` absolute under the workflow directory.
- Callee workflows resolve through `FileSystemWorkflowCalleeResolver`, built
  with the run command's own `resolver` (`WorkflowRunCommand+KaibaPreflight.swift:35`).
  Session resume and rerun resolve again through their own resolvers
  (`SessionCommands.swift:426, 701`).
- The session store database is at schema generation 9
  (`SQLiteWorkflowRuntimePersistenceStore.swift:115`). It migrates only
  through the registered `schemaMigrations`. Any older store without a path
  is deleted by `discardIncompatibleStoreIfNeeded` (`:179`).
- The store root comes from `CLIWorkflowSessionStore.resolveRootDirectory`
  (`CLIWorkflowSessionStore.swift:57`): `--session-store`, then
  `RIELA_SESSION_STORE`, then `~/.riela/sessions` for user scope, otherwise
  `<cwd>/.riela/sessions`.

## 3. Data model (runtime records database)

The definition tables live in the same SQLite file as sessions
(`SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath`). That way a
service run's pin and its session are written to the same store.

- **`definition_blobs`**: `digest TEXT PRIMARY KEY` (sha256 hex),
  `bytes BLOB`, `size INTEGER`, `created_at`. Blobs are content-addressed
  and shared. An identical document, such as the result of a restore,
  reuses its blob.
- **`definition_versions`**, immutable:
  - `version_id TEXT PRIMARY KEY` (`defv-<uuid>`)
  - `workflow_name`
  - `parent_version_id` (nullable)
  - `document_digest`, which references `definition_blobs`
  - `operation`: `seed | import | forceUpdate | updatePrompt | update | restore`
  - `source_directory`, `source_scope`, `provenance`
  - `actor_kind`, `actor_id`, `created_at`
  - `BEFORE UPDATE` and `BEFORE DELETE` triggers `RAISE(ABORT)`.
- **`definition_heads`**, one row per workflow name per store:
  - `workflow_name TEXT PRIMARY KEY`
  - `current_version_id`
  - `last_file_version_id`: the newest version with operation
    `seed | import | forceUpdate`
  - `revision INTEGER`: bumped on every head move
  - `source_directory`, `source_scope`, `created_at`, `updated_at`
- **`definition_change_audit`**, append-only:
  - `audit_id TEXT PRIMARY KEY` (`defa-<uuid>`), `created_order INTEGER`
    (autoincrement)
  - `workflow_name`, `operation`, `version_id` (the resulting version),
    `previous_version_id`
  - `target_node_id` and `target_field`: set only for `updatePrompt`, null
    for whole-workflow operations (`update`, `forceUpdate`, `restore`, ...)
  - `before_digest`, `after_digest`
  - `diff_json`: the structural diff from §6
  - `reason TEXT NOT NULL`
  - `evidence_refs_json`: `[{kind: session|stepExecution|review, id}]`
  - `actor_kind`: `user | cli | api | improvementNode`. `improvementNode`
    is written only through the CLI `--actor-kind` flag that the §9 apply
    add-on passes.
  - `actor_id`
  - `approval_state`: always `applied` in this scope. Issue section 4 adds
    `pending | approved | rejected` to the same column.
  - `overwritten_changes_json`: force updates only, see §5
  - `created_at`
  - `BEFORE UPDATE` and `BEFORE DELETE` triggers `RAISE(ABORT)`.

**Stored document.** The document is canonical JSON (sorted keys, no
insignificant whitespace) with two parts:

```
{ formatVersion: 1,
  runtime: { workflow, nodePayloads, packageManifest? },
  authoredFiles: { "<relative path>": "<verbatim UTF-8 text>" } }
```

- **`runtime`** is the executable form that service runs decode. It is the
  `ResolvedWorkflowBundle` content from the file resolver, encoded with the
  existing `Codable` conformances. Inheritance (`extends`) and `nodeRef`
  shared nodes are already materialized in it, prompt files are already
  inlined (hydrated), the `*File` paths are kept, and stdio paths are
  already made absolute under `source_directory`. Once a head exists, no
  service path reads a workflow, base, shared-node or prompt file. That
  covers the run, the configured-launch pre-resolve and the events-serve
  preflight (§4). A change to any of those files therefore cannot reach a
  registered workflow. Files are read only to seed a head on first use.
- **`authoredFiles`** holds the verbatim text of the files in the
  workflow's own directory that define it: `workflow.json`, every own
  `nodeFile`, and every prompt `*File` those node files reference
  (including `promptVariants`). Files that resolve outside the directory
  (the `extends` base, `nodeRef` targets) are not included. `export` writes
  this part. `RielaCore` has no `WorkflowDefinition` → authored
  `workflow.json` inverse (`materializeWorkflowDefinition`,
  `WorkflowValidation.swift:605`, is one-way), so the authored text must be
  stored rather than regenerated.

One document is one blob. A prompt edit therefore stores a new
whole-document blob, not a per-prompt blob. Workflow documents are small,
and one blob per version keeps the diff, restore and digest rules trivial.

The **definition digest** is sha256 over this canonical document. The same
function, applied to the file-resolved bundle plus its authored files,
computes the file digest of a CLI run. A file digest and a store digest are
therefore directly comparable, and equality means a non-force import would
report `unchanged`. The `runtime` part must round-trip losslessly through
`Codable`. A test asserts `decode(encode(bundle)) == bundle` for the example
bundles that the new suites use.

Scripts, mock scenarios, add-on files and other non-prompt assets are not
stored. A version records `source_directory`. A run loaded from the store
uses that directory as `workflowDirectory`, exactly as a file-resolved run
does.

**Schema.** `schemaGeneration` goes from 9 to 10. A
`SQLiteSchemaMigration(fromGeneration: 9)` creates the four tables, their
indexes (`definition_versions(workflow_name, created_at)`,
`definition_change_audit(workflow_name, created_order)`) and the triggers
with `CREATE ... IF NOT EXISTS`. `ensureSchema` creates the same objects for
fresh databases. Existing generation-9 stores migrate in place.

Because the database now holds authored data,
`discardIncompatibleStoreIfNeeded` must not delete a database that has a
non-empty `definition_heads` table. In that case the open fails with the
existing "no migration path" error instead. This is the minimal subset of
consolidation §14's quarantine rule. Automatic retention and `riela gc` do
not touch definition tables.

`WorkflowSession` gains an optional `definitionSource` field: `{kind: store
| file, workflowName, versionId?, storeRoot?, digest, sourcePath?,
sourceScope?}`. `storeRoot` is set for `kind store` and names the store
that holds the pinned version. It can differ from the session's own store
under `auto` scope (§4 step 1). It is
optional because session snapshots persisted before generation 10 must
still decode after the in-place migration. It is not a compatibility shim:
every new run writes the field.

## 4. Store selection and service resolution

`WorkflowRunOptions` gains `executionMode: oneTime | service(actor)`, with
`oneTime` as the default. These callers, and only these, set `service`:

- `WorkflowExecutionProvider.executeWorkflow` (actor `api`)
- `launchConfiguredWorkflow` (actor `api`)
- `CLIEventWorkflowRunner` (actor `cli`, id `events-serve`)

**Configured launch.** `launchConfiguredWorkflow`
(`WebWorkflowRequestHandler+ConfiguredLaunch.swift:9`) pre-resolves outside
`resolveRunBundle`. Today it calls `FileSystemWorkflowBundleResolver().resolve`
at `:30`, checks the result at `:31-34` (409 `source_changed`, or 422
`run_preflight_failed` on a resolve error), and hands the file bundle to
`EditorPreparedBundleResolver`. Wrapping the run command's resolver
therefore cannot intercept this route, so it changes itself:

- It replaces the `:30` file pre-resolve with a call to the service store
  resolver: lookup, then seed on first use (steps 1-3 below). The candidate
  store is the explicit `context.sessionStoreRoot` the route already passes.
  The resolved bundle is passed to `EditorPreparedBundleResolver` as today.
- When a head exists, no workflow, node or prompt file is read on this
  route. Only the first-use seed reads files.
- The host-selected-source guard keeps its intent but compares against the
  resolved bundle:
  - `workflowId` must equal `source.workflowId`, otherwise 409
    `source_changed`.
  - The directory compared with `source.workflowDirectory` is the stored
    version's `source_directory` when a head exists, or the file bundle's
    directory when seeding. A directory mismatch on a stored head follows
    the step 2 warning rule (run proceeds on the stored version), not 409.
- A resolve failure still returns 422 `run_preflight_failed`. With a head,
  that can only mean a stored document that fails to decode or validate
  (step 2), never a file problem.

**Events-serve preflight.** `CLIWorkflowTriggerDefaultsResolver`
(`EventLiveServe.swift:967`) and the startup required-environment check
`eventRequiredEnvironment` (`RuntimeEnvironmentPreparation.swift:42`) call
the service resolver **lookup only** (steps 1-2, no seed). They use the
stored version when a head exists and fall back to the file bundle when it
does not. Seeding happens only when a run starts, so a broken file cannot
block `events serve` startup for a registered workflow, and a read-only
preflight never writes rows.

In service mode, `WorkflowRunCommand` wraps its injected resolver in a
`DefinitionStoreWorkflowBundleResolver` for named-workflow resolution. That
covers the `resolver.resolve(resolution)` branch and callee resolution
through `FileSystemWorkflowCalleeResolver`. The resolver works in four
steps:

1. **Candidate stores.** If `--session-store` or `RIELA_SESSION_STORE` is
   set, only that store is used. Explicit `project`, `user` or `direct` scope
   maps to that scope's root through `resolveRootDirectory`. `auto` scope
   checks the project store first, then the user store. The order matches
   consolidation §4.2.
2. **Lookup.** The first store with a head for `workflowName` wins. The
   resolver reads the head and its current version document in one read
   transaction, decodes it into a `ResolvedWorkflowBundle`, and does not
   read any workflow file. A stored document that no longer decodes or
   validates fails the run with an error naming `riela workflow definition
   import --force`. There is no file fallback. If the request names a
   `workflowDefinitionDir` or scope whose resolved directory differs from
   the head's `source_directory`, the run gets a warning diagnostic. It
   still uses the stored version.
3. **Seed on first use.** If no candidate store has a head, the resolver
   resolves the file bundle as today. In the store that `storeRootForRun`
   selects for that bundle, it then runs `BEGIN IMMEDIATE`,
   `INSERT ... ON CONFLICT(workflow_name) DO NOTHING` on the head, and
   re-reads the head. A concurrent seeder that lost the race uses the
   winner's version. A seed writes one blob, one version with operation
   `seed`, the head and one audit record:
   - reason: `seeded from <path> on first service run`
   - actor: the run's service actor
4. **Pin.** The run uses the loaded version. `definitionSource` records
   `kind store`, `versionId` and `digest`. Instance node patches and
   runtime variables apply on top of the pinned document, as they do today
   on top of the file bundle. They are not stored. A callee resolved this
   way gets its own pin in its own child session.

These stay one-time and file-based, with `definitionSource.kind = file`:

- temporary or inline workflow payloads (`--workflow-json*`)
- `--from-registry`
- editor-prepared bundles (`webWorkflowEditorLaunch`, which runs unsaved
  drafts)
- Work Runtime task dispatch, loop, specialist, and distributed-worker runs

Every non-service path computes the file digest from the resolved bundle.
It never opens the definition tables. The only exception is resuming or
rerunning a store-pinned session, described next.

**Resume and rerun.** When a persisted session has
`definitionSource.kind = store`, `riela session resume` and `riela session
rerun` load the pinned `versionId` from `definitionSource.storeRoot`. The surface
does not matter: CLI and GraphQL behave the same. They never use the head
or the file, so a resumed service run cannot mix prompt versions.
File-origin sessions keep today's file resolution.

## 5. Operations

All writes run in one `BEGIN IMMEDIATE` transaction that reads the head,
writes the blob, the version and the audit record, and moves the head
(`revision + 1`). The resulting `runtime` part must pass the existing
validators: `DefaultWorkflowValidator().validate(workflow)`, plus
`validateAgentNodePayload` for every node payload. File-sourced operations
(seed, import, force) also get the full file-resolver validation. An invalid
result writes nothing.

| Operation | Effect | Reason |
| --- | --- | --- |
| `import` (non-force), head absent | Seeds a head from the file bundle. Audit operation `import` | Optional. Default `initial import from <path>` |
| `import` (non-force), head present | **No write.** Returns outcome `unchanged` (digests equal) or `differs`, with the file-vs-store diff | n/a |
| `import --force` | Requires a head. Writes the file document as a new version with operation `forceUpdate` and parent = current version. Moves the head and `last_file_version_id`. With `--workflow-definition-dir`, that directory becomes the version's and the head's `source_directory` | **Required** |
| `update --patch` / `update --from-file` | Requires a head. Whole-workflow store edit (structure and prompts): a new version with operation `update` and parent = current version, built by the authored-edit pipeline below. Does not move `last_file_version_id` | **Required** |
| `update --from-file <path> --force` | The same operation as `import --force --workflow-definition-dir <dir of path>` (operation `forceUpdate`) | **Required** |
| `update-prompt` | Replaces one prompt field of one node. Implemented as a generated authored-view patch through the same pipeline; operation `updatePrompt` | **Required** |
| `restore --version <id>` | New version whose document is that version's document; parent = current version; operation `restore`. History is never rewritten | **Required** |
| `history`, `show`, `diff` | Read-only | n/a |
| `export` | Writes files and creates no definition rows. See §7 | n/a |

An `update` or `update-prompt` on a workflow with no head fails with
`definition_not_registered`, naming `riela workflow definition import`. It
never seeds. `riela workflow update` (the mutable-registry command) is not
changed; see §11.

**Authored view and the authored-edit pipeline.** Whole-workflow edits
operate on the authored files, never on the `runtime` part directly, so
that `export` stays exact:

- The **authored view** is a JSON object keyed by the `authoredFiles`
  relative paths. A `.json` entry holds the parsed JSON value of that file.
  Every other entry (prompt text) holds its text as a JSON string.
  `show --authored` returns it, and the §9 context add-on emits it.
- `--patch <file>` is an RFC 6902 JSON Patch document applied to the
  authored view. Supported ops are `add`, `remove`, `replace` and `test`. A
  failed `test` or an invalid pointer rejects the update. Example pointer:
  `/prompts~1summarize.md` or `/nodes~1summarize.json/promptTemplate`.
- `--from-file <path>` takes a `workflow.json` file or its directory. The
  new authored files are collected from that directory with the same
  collector the seed uses (`workflow.json`, own node files, their prompt
  `*File`s). Its `workflowId` must equal the target workflow name.
- Pipeline:
  1. Produce the new authored files. A patched `.json` entry is
     re-serialized pretty-printed with sorted keys. Unchanged entries keep
     their verbatim text.
  2. **Re-derive `runtime`** by running the normal bundle loader at the
     head's `source_directory`, with own-directory reads (`workflow.json`,
     node files, prompt files) served from the new authored files instead
     of disk. This is one optional overlay parameter on
     `WorkflowRegistryBundleLoader.loadBundle` and
     `PromptTemplateAssetLoader.hydrate`. Files outside the own directory
     (the `extends` base, `nodeRef` targets) are read from disk at write
     time. Stdio paths are therefore made absolute under `source_directory`,
     exactly as at seed time, and an export followed by a file-mode resolve
     reproduces `runtime`.
  3. The collector re-run on the new authored files must reference exactly
     the new authored file set. A missing referenced file fails the
     resolve. An entry that nothing references is rejected.
  4. Validate (above), then write. If the new digest equals the current
     digest, nothing is written and the outcome is `unchanged`.
- Because step 2 reads the base and `nodeRef` targets at write time, a
  changed base file shows up in that write's diff. Service runs still never
  read files (§3).
- **`--expected-version <id>`** (GraphQL `expectedVersionId`) is optional.
  When given, the write fails with `definition_conflict` and writes nothing
  unless the head's `current_version_id` equals it. The §9 apply add-on
  always passes it.

**Overwritten store-only changes.** A force update records
`overwritten_changes_json = {sinceVersionId: last_file_version_id,
auditIds: [...], diff: [...]}`:

- `auditIds` lists every `updatePrompt`, `update` and `restore` audit
  record after `last_file_version_id`.
- `diff` is the structural diff from the `last_file_version_id` document to
  the current document, which is what the force update throws away.

The replaced version remains restorable through `restore`.

**Validation rules:**

- A reason is required for `import --force`, `update`, `update-prompt` and
  `restore`. After trimming whitespace it must be non-empty. An empty reason
  is rejected before any read. `update` takes exactly one of `--patch` and
  `--from-file`; `--force` is accepted only with `--from-file`.
- `--force` without a reason is a usage error. `--force` on an
  unregistered workflow is an error naming `import` without `--force`.
- `update-prompt` targets `--node <nodeId>` and `--field`, which must be
  one of:
  - `promptTemplate`, `systemPromptTemplate`, `sessionStartPromptTemplate`
  - `promptVariants.<key>.promptTemplate|systemPromptTemplate|sessionStartPromptTemplate`

  The command rejects an unknown node, an unknown variant key, or any other
  field. It also rejects a node whose payload file is not in
  `authoredFiles`, meaning the payload is materialized from an `extends`
  base or a `nodeRef` target. That node's prompt belongs to another
  workflow.
- `update-prompt` generates one authored-view `replace`:
  - **The field has a `*File` path.** The patch replaces the text entry at
    that path. Re-derivation gives every `runtime` prompt field that
    references the same path the new text, because editing a shared prompt
    file changes all of its users. The diff lists every affected pointer.
  - **The field is inline in the node file.** The patch sets that key in
    the node file's JSON entry.

  After either change, an `export` followed by a file-mode resolve
  reproduces the `runtime` part. This is a test.
- Evidence references are `kind:id`, with kind `session`, `stepExecution`
  or `review` and a non-empty id. They are recorded as given and not
  checked for existence, because review ids can be external.
- Actor rules:
  - CLI writes use actor kind `cli` by default, with id `--actor <id>` or
    the OS user name. `--actor-kind cli|improvementNode` overrides the
    kind; only the §9 apply add-on passes `improvementNode`. The CLI is a
    local admin surface, so the flag records attribution and is not an
    authorization boundary.
  - GraphQL writes accept an optional `actorKind` of `user` or `api`
    (default `api`) and an optional `actorId`. GraphQL rejects
    `improvementNode`.
- Approval state is `applied` for every write in this scope (section 4 is
  out of scope).

## 6. Diff format

A diff is a list of `{path, op: add|remove|replace, before?, after?}`
entries:

- `path` is an RFC 6901 JSON pointer into the canonical document, for
  example `/runtime/nodePayloads/step1/promptTemplate` or
  `/authoredFiles/prompts~1step1.md`.
- `before` and `after` hold the leaf JSON values.

The entries are computed by a deterministic structural walk. Object keys
are visited in sorted order. Arrays are compared index by index, and a
length change produces `add` or `remove` entries at the tail. Audit records
store this list. `diff` and `import` (`differs`) return it. The CLI prints
one line per entry, followed by the before and after text.

## 7. Export

`export <workflow> [--version <id>]` takes exactly one target:

- **`--to <dir>`** writes a bundle into an empty or new directory.
- **`--to-source --overwrite`** rewrites the head's recorded
  `source_directory`. `--to-source` without `--overwrite` is a usage error.

Writing rules:

- The command writes every `authoredFiles` entry verbatim at its relative
  path. That is `workflow.json`, the own node files and the own prompt
  files, so the authored layout, including `extends` declarations and
  `nodeRef` references, is preserved exactly.
- Each path is validated with the existing workflow-relative path rules
  before anything is written.
- Other files in the target, such as scripts, mock scenarios, the `extends`
  base and `nodeRef` targets, are left alone. Each written file is replaced
  atomically (temporary file plus rename).

After `export --to-source`, a non-force `import` reports `unchanged`, as
long as no `extends` base or `nodeRef` target has changed since the version
was written. This round-trip is a test.

## 8. Surfaces

**CLI.** The `riela workflow definition` subcommand family is new. Every
command takes `--session-store <dir>` or `--scope project|user` to pick
the store (the candidate-store order of §4 step 1 when neither is given) and `--output text|json`.

```
riela workflow definition history <workflow> [--node <id>] [--limit <n>]
riela workflow definition show <workflow> [--version <id>] [--node <id>] [--authored]
riela workflow definition diff <workflow> [--from <versionId>] [--to <versionId> | --file]
riela workflow definition update <workflow> (--patch <json-patch-file> | --from-file <workflow.json|dir> [--force]) --reason <r> [--expected-version <id>] [--evidence <kind:id>]... [--actor <id>] [--actor-kind cli|improvementNode]
riela workflow definition update-prompt <workflow> --node <id> --field <field> (--text <s> | --text-file <path>) --reason <r> [--expected-version <id>] [--evidence <kind:id>]... [--actor <id>] [--actor-kind cli|improvementNode]
riela workflow definition restore <workflow> --version <id> --reason <r> [--evidence <kind:id>]... [--actor <id>]
riela workflow definition import <workflow> [--workflow-definition-dir <dir>] [--force --reason <r>] [--evidence <kind:id>]... [--actor <id>]
riela workflow definition export <workflow> [--version <id>] (--to <dir> | --to-source --overwrite)
```

- `update` with `--output json` returns `{outcome: updated | unchanged,
  versionId, digest, auditId, diff}`. A rejected update (missing reason,
  conflict, invalid patch, validation failure) exits non-zero, writes
  nothing, and returns a closed error code: `reason_required`,
  `definition_not_registered`, `definition_conflict`, `invalid_patch`,
  `invalid_definition`.

- `diff` with no version flags compares the current head with the current
  file bundle, which is what `import --force` would change.
- `import` resolves the file bundle with the normal scope rules. Pass
  `--workflow-definition-dir` to force-update from an explicit directory.
- A non-force `import` against a registered head exits 0 and reports
  `unchanged` or `differs` with the diff.
- Rejected input (missing reason, invalid target, validation failure)
  exits non-zero and writes nothing.

**GraphQL.** `WorkflowDefinitionGraphQLProviding` is a new protocol with
DTOs in `RielaGraphQL` and its implementation in `RielaCLI`, the same split
as `WorkflowExecutionProvider`. Store arguments mirror the CLI as
`storeScope: WorkflowScope`. Unlike the CLI, there is no session-store path
argument.

- Query `workflowDefinitionHistory(workflowName, nodeId, limit, storeScope)`
- Query `workflowDefinition(workflowName, versionId, storeScope)`
- Query `workflowDefinitionDiff(workflowName, fromVersionId, toVersionId, againstFile, storeScope)`
- Mutation `updateWorkflowDefinition(input: {workflowName, storeScope, patch, authoredFiles, expectedVersionId, reason, evidence, actorKind, actorId})`.
  Exactly one of `patch` (JSON Patch array) and `authoredFiles`
  (`[{path, content}]`, the full new authored set, the GraphQL form of
  `--from-file`) is required. It runs the same pipeline and returns the
  same outcome as the CLI `update`. The force form is
  `importWorkflowDefinition(force: true)`.
- Mutation `updateWorkflowDefinitionPrompt(input)`
- Mutation `restoreWorkflowDefinition(input)`
- Mutation `importWorkflowDefinition(input: {workflowName, scope, workflowDefinitionDir, force, reason, evidence, actorKind, actorId})`.
  The result is an outcome of `seeded | unchanged | differs | forceUpdated`
  with version, diff and audit. This is the force-update mutation the
  RielaApp API uses.
- Mutation `exportWorkflowDefinition(input: {workflowName, versionId, writeToSource})`.
  It returns the exported files as `[{path, content}]`. With
  `writeToSource` it also rewrites the recorded source directory under the
  §7 rules. GraphQL never accepts an arbitrary target path.

**Catalog and SDL.**

- Each new operation gets a `SurfaceCatalog` row
  (`workflow.definition.history|show|diff|update|update-prompt|restore|import|export`)
  that declares `cli` and `graphql`. Other surfaces follow the existing
  `workflowDefaults` treatment of registry admin rows.
- The committed SDL in `GraphQLContractProjector+Schema.swift` is
  regenerated with `scripts/surface-parity/generate-sdl.sh`.
- `swift test --filter SurfaceParity` must stay green.

## 9. Builtin improvement node (issue section 3, definitions only)

The improvement node is a fixed three-node shape in the improving
workflow. Two of its nodes are new builtin add-ons, and they are
deterministic Riela code:

1. **`riela/improve-workflow-context`** builds the improvement input.
2. **A proposer**: an ordinary agent node that the workflow author writes,
   on any backend. Its prompt renders the context output and returns
   `{patch, reason}`. It is the only LLM step. Under mock-scenario it is the
   only mocked step.
3. **`riela/improve-workflow-apply`** checks the proposal and applies it
   only by running the §8 CLI `riela workflow definition update` as a
   subprocess.

Both add-ons are registered as builtin descriptors (version `1`) next to
the existing `riela/kv-*` and `riela/cache-*` add-ons and dispatched by
`BuiltinWorkflowAddonResolver`. Under mock-scenario, they run for real
unless the scenario lists a response for their node id (existing
`ScenarioWorkflowAddonResolver` fallback).

**Run-scoped context.** The run command hands the builtin add-on resolver
three run-scoped values: the run's `definitionSource` (§3), its session
store root, and its `workflowExecutionId`. They are not added to the
`WorkflowAddonExecutionInput` contract, so container and third-party
add-ons do not see them.

**Policy gate (both add-ons).** If `definitionSource.kind` is not `store`
(a one-time run), the add-on reads no definition rows, starts no
subprocess, and returns `status: skipped, reason: oneTimeRun` with
`when.improvable = false`. That is the §1 rule "one-time runs do not
improve". The example routes `improvable = false` straight to the end.

**`riela/improve-workflow-context` config.** No field is required.

- `guideline` (string): the improvement guideline text, emitted verbatim.
  It sits inline in the node's `addon.config` (in `workflow.json`
  `nodes[]` or in the node file), so it is part of the stored, audited
  document. There is no `guidelineFile`, because a service run never reads
  files (§3).
- `excludeNodeIds` (string array, default `[]`): extra nodes to exclude,
  normally the proposer.
- `maxStepExecutions` (default 20, range 1-100)
- `maxFieldChars` (default 2000, range 100-20000)
- `maxContextBytes` (default 262144). The node fails with
  `context_too_large` when its output would exceed this.

**Context output payload:**

- `workflowName`, `baseVersionId`, `baseDigest`: the run's pin. The add-on
  reads that pinned version's document (not the head) from
  `definitionSource.storeRoot`, so the proposal is relative to what
  actually ran.
- `definition`: the authored view (§5) of the pinned version, the target of
  the proposer's patch.
- `excludedNodeIds`: the nodes that use either improve add-on, plus
  `excludeNodeIds`.
- `runDigest`: the bounded latest-run digest, described below. It is null
  when there is no previous run.
- `evidence`: `[{kind: session, id}, {kind: stepExecution, id}...]` for the
  digested session and every step execution included in the digest.
- `guideline`
- `when.improvable`: true only for a store-pinned run whose `runDigest` is
  non-null.

**Latest-run digest.** The add-on uses the existing session store read
APIs, never the session chat or message log. It reads the snapshots in
`workflow_runtime_snapshots`:

- **Latest run.** The newest session in the run's session store that
  meets all of these:
  - its `definitionSource.kind` is `store`
  - it has the same workflow name
  - its status is terminal
  - it is not the current session

  File-origin one-time runs ran file prompts, so they are never evidence
  for a store change.
- **Exclusion (recursion guard).** Step executions of every
  `excludedNodeIds` node are dropped before selection. The improvement
  node never reviews its own executions, and the current session is never
  evidence.
- **Entry fields.** One entry per remaining `WorkflowStepExecution`:
  `stepId`, `nodeId`, `stepExecutionId`, `attempt`, `status`,
  `failureKind`, `failureReason`, `inputSnapshot` (canonical JSON text),
  the accepted output payload (canonical JSON text) and `usage`. Each text
  field is cut at `maxFieldChars` and flagged `truncated: true`.
- **Selection.** If there are more than `maxStepExecutions` entries, failed
  executions and executions with `attempt > 1` are kept first, then the
  newest. `omittedCount` reports the rest. Output entries are ordered by
  `createdAt`, then `stepExecutionId`.

**`riela/improve-workflow-apply`.** Inputs are bound with the existing
`addon.inputs` dataflow:

- `patch` and `reason` come from the proposer's output.
- `baseVersionId`, `definition`, `evidence` and `excludedNodeIds` come
  from the context node's output. Evidence therefore never comes from the
  LLM.

Config: `excludeNodeIds` (same meaning as in the context config) and
optional `rielaExecutable`.

Before it spawns anything, the add-on rejects the proposal with `status:
rejected` and a closed `reason` code, without writing:

- `reasonRequired`: the reason is empty after trimming.
- `invalidPatch`: the patch is not a JSON Patch array.
- `targetsImprovementNode`: the add-on applies the patch locally to
  `definition` and compares the before and after views by node id, not by
  array index. The proposal is rejected if any of these differs:
  - the excluded node's authored `workflow.json` `nodes[]` entry (matched
    by `id`)
  - any `steps[]` entry whose `nodeId` is an excluded node
  - any transition whose `toStepId` is one of those steps
  - the excluded node's node file entry
  - any prompt file referenced by an excluded node

  This keeps the node from rewriting its own guideline or wiring. A patch
  that fails to apply locally is `invalidPatch`.
- `noEvidence`: the evidence list is empty.
- An empty patch array returns `status: noChange`, with no subprocess.

Otherwise the add-on writes the patch to a file under the run's artifact
directory and runs:

```
<riela> workflow definition update <workflowName> --patch <file>
  --reason <reason> --expected-version <baseVersionId>
  --evidence session:<id> --evidence stepExecution:<id> ...
  --actor <workflowName>/<nodeId>@<workflowExecutionId>/<operationExecutionId>
  --actor-kind improvementNode --session-store <definitionSource.storeRoot> --output json
```

- **Executable.** `config.rielaExecutable` if it is executable, else a
  `riela` sibling of `Bundle.main.executableURL`, else `riela` on `PATH`.
  This is the order `DaemonWorkflowEventServeProcess` already uses.
- **Process seam.** The subprocess goes through the resolver's existing
  `LocalProcessRunning`. Tests inject a runner that sends the same argv to
  `RielaCLIApplication` in-process, so the CLI contract is exercised
  without a built binary.
- **Output.** The add-on maps the CLI JSON result to `{status: applied |
  unchanged | rejected | failed, versionId?, auditId?, digest?, cliExitCode,
  errorCode?}`. A CLI rejection (`definition_conflict`, `invalid_patch`,
  `invalid_definition`) becomes `status: rejected` with that code and does
  not fail the node. A spawn failure or an unparseable result fails the
  node.
- **Resume.** The actor id carries the runtime-owned
  `operationExecutionId`. On `definition_conflict`, the add-on reads `riela
  workflow definition history --limit 1 --output json`. If the head's
  latest audit has the same actor id, the add-on reports `applied` with
  that version, so a resumed attempt does not fail on its own earlier
  write.
- **No mid-run switch.** The current run keeps its pin, and the next
  service run resolves the new head. The subprocess is an admin write. The
  only files it reads are the §5 step 2 base and `nodeRef` targets, and
  those reads never affect the current run.
- **Writer contention.** The subprocess writes the same SQLite file as the
  parent run. The parent holds no write transaction while an add-on runs,
  and the definition write uses the store's existing busy timeout.

**Example `examples/definition-store-self-improvement/`**, registered in
`rielaExampleWorkflowNames()` and `ExampleCatalog`, with a `mock-scenario`.
Steps:

1. `summarize`: an agent node whose prompt is in
   `prompts/summarize.md`. Its mocked output is flagged as weak.
2. `improve-context`: `riela/improve-workflow-context`, not mocked.
3. `improve-propose`: the proposer. Its mocked output is a fixed patch
   `replace /prompts~1summarize.md` plus a reason.
4. `improve-apply`: `riela/improve-workflow-apply`, not mocked.

The step 3 patch pointer is static, so the scenario is deterministic. The
dynamic ids (session and step executions) come only from the context node.
Under the example parity test (`riela workflow run --mock-scenario`, which
is one-time), steps 2 and 4 return `skipped / oneTimeRun` and the run
completes without writing rows. The dedicated test drives the store path
(§12).

## 10. Deviation from `design-execution-environment-consolidation.md`

- §4.3 says `riela workflow run <dir>` imports an *ephemeral* version. Under
  the issue #179 policy, a one-time CLI run never writes definition rows.
  No ephemeral versions exist, and file-origin runs record only a file
  digest.
- Only the workflow kind exists. The head key is `workflow_name` per
  physical store (project or user). There is no
  `DefinitionScope.workspace`, activation pointer, fork, consolidate,
  submission, or package-as-immutable-head yet. Those stay in E0/E7.
- A version is one canonical-document blob (the executable `runtime` form
  plus the verbatim own `authoredFiles`), not a document plus per-asset
  blobs. Scripts are not stored (§3).
- On a generation mismatch the store is protected (§3), not quarantined.

## 11. Existing surfaces left unchanged

- `riela workflow register|update|delete|activate|deactivate|consolidate|versions|restore`
  and the GraphQL mutable-registry mutations still edit files only.
  `riela workflow update <id> <input>` is keyed by mutable-registry
  identity (workflowId, scope, originId) and runs a file transaction. It is
  not extended. The audited whole-workflow store update is the new
  `riela workflow definition update` and its GraphQL equivalent (§5, §8).
- For a workflow already registered in a definition store, registry edits
  (including RielaApp editor saves) reach service runs only after
  `import --force` or `update --from-file`. This follows the issue's "no
  automatic re-import" rule. See user QA Q1.
- `workflow self-improve` and `.riela/workflow-history` are unchanged
  (issue section 5).

## 12. Verification

New focused suites (names are indicative; plans fix the exact names):

- `WorkflowDefinitionStoreTests` (RielaCore) covers:
  - schema migration from generation 9
  - append-only and immutable triggers
  - concurrent seed producing one head
  - the discard guard
- `WorkflowDefinitionServiceResolutionTests` (RielaCLI) covers:
  - a service run seeds on first use
  - an `update-prompt` is used by the next service run with the file
    untouched
  - a changed file is ignored by service runs. This is checked for
    executeWorkflow, events serve and the configured-run API: after
    seeding, the workflow file is made invalid and its `workflowId` is
    changed, then `launchConfiguredWorkflow` is called. The launch returns
    202, the run succeeds, and it pins the stored `versionId`.
  - an events-serve preflight (trigger defaults and the required-environment
    check) with a broken file and an existing head succeeds and writes no
    rows
  - `riela workflow run` is unaffected by a store prompt update and leaves
    zero rows in every `definition_*` table
  - service run records pin `versionId` and `digest`, and CLI run records
    carry `kind file` and the file digest
  - resume uses the pin
  - executeWorkflow and events serve (including a cron fire) cover the
    service entry points
- `WorkflowDefinitionCommandTests` (RielaCLI) covers:
  - a non-force import reports the diff and changes no rows (row counts
    before and after)
  - force import records reason, actor and overwritten changes, and the
    prior version is restorable
  - a missing reason is rejected
  - history, show, diff and restore
  - an export round-trip, including a `nodeRef` example and an inline
    (non-`*File`) prompt update
  - rejection of `update-prompt` on a node materialized from a `nodeRef`
  - `update --patch` changing structure (a transition) and a prompt file in
    one version: operation `update`, audit with reason, evidence, actor and
    diff, visible in history and diff. The next service run uses it, and an
    export followed by a file-mode resolve reproduces `runtime`.
  - `update --from-file` from a separate directory: relative stdio paths in
    the new `runtime` are absolute under the head's `source_directory`, not
    under the from-file directory
  - `update --from-file --force` behaves as `import --force`
    (`forceUpdate`, `overwritten_changes_json` lists the earlier `update`)
  - rejections write zero rows: missing or blank `--reason`, a stale
    `--expected-version` (`definition_conflict`), a failing `test` op or bad
    pointer (`invalid_patch`), an unreferenced added file, a result that
    fails validation, and an unregistered workflow
    (`definition_not_registered`)
  - `--actor-kind improvementNode` is recorded as given
- `WorkflowDefinitionGraphQLTests` (RielaGraphQLTests or RielaCLITests)
  provides GraphQL parity for history, show, diff, update (patch and
  authoredFiles), update-prompt, restore, import and force import, and
  export. It also checks that `actorKind: improvementNode` is rejected.
- `WorkflowImprovementNodeTests` (RielaCLITests) uses the example's
  `mock-scenario` and the in-process process-runner seam:
  - **Service runs.** Two service-mode runs (`executionMode: service`). Run
    1 seeds the head, and `improve-context` reports `improvable = false`
    because there is no previous run. Run 2's context digest references run
    1's session and its `summarize` step execution, and contains no
    improve-node executions. `improve-apply` writes one version with
    operation `update`, actor kind `improvementNode`, the mocked reason, and
    evidence equal to the context evidence. The workflow file is
    byte-unchanged. Run 3 pins the new version and renders the new prompt.
  - **One-time run.** The same example under `riela workflow run` gives
    `skipped / oneTimeRun` for both add-ons, no subprocess, and zero
    `definition_*` rows.
  - **Recursion guard.** A mocked patch that touches `improve-propose`'s
    prompt or a transition into `improve-context` gives `rejected /
    targetsImprovementNode` and no new rows.
  - **Validation.** An empty reason gives `reasonRequired`. An empty
    evidence list gives `noEvidence`. A head moved after the pin gives
    `rejected / definition_conflict`.
  - **Resume.** A resumed apply whose earlier write landed reports
    `applied` with that version.
  - **Digest bounds.** `maxStepExecutions`, `maxFieldChars` and the
    failed/retried-first selection with `omittedCount`.
- `RielaExampleParityTests` pass with the new example registered and the
  mock-scenario counts updated.
- `swift test --filter SurfaceParity` passes after SDL regeneration.

Docs: README and the CLI docs describe `riela workflow definition`
(including `update`), the §1 policy table, and the two improve add-ons.

Command:
`arch -arm64 /bin/zsh -lc 'swift build && swift test --filter <NewSuites> && swift test --filter SurfaceParity && swiftlint lint --quiet <changed files>'`

## 13. Plan mapping (serial DAG)

The existing `impl-plans/active/ds179-01..06` stay the baseline and keep
one serial chain over the shared SwiftPM tree:

- **01, store core.** Adds operation `update` and actor kind
  `improvementNode`.
- **02, definition service.** Adds the authored view, the JSON Patch apply,
  the loader/hydrate own-directory overlay, `update` (patch and from-file),
  `--expected-version`, and `update-prompt` rebuilt on the pipeline.
- **03, service resolution.** Unchanged.
- **04, CLI.** Adds `definition update`, `--actor-kind` and `show
  --authored`.
- **05, GraphQL.** Adds `updateWorkflowDefinition`, a catalog row and SDL
  regeneration.
- **New plan for §9.** The two builtin add-ons, the run-scoped context, the
  example, catalog registration and `WorkflowImprovementNodeTests`. It
  depends on 05.
- **Docs plan.** Stays last and depends on the §9 plan.
