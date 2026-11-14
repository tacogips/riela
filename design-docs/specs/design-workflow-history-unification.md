# Workflow history unification: one definition-store lineage, bundle snapshots as file-restore auxiliary, regression-driven rollback, web history screen

Status: proposed 2026-11-02. Revised the same day after step-3 review
(D3-001 first-use baseline §3.3/§5.3, D3-002 bundle-rollback claim protocol
§5.5, D3-003 durable coordinator sync intents §3.4). The second review round
separated baseline evidence (`baselineTransaction`) from the
change-completion predicate in §3.3. The user's QA Q7 answer (binding,
2026-11-02) was then applied: no-op collapse and predicate (b) in §3.3,
proposal pruning in §5.4 and §5.6, and bounded storage in §8 and §9.
Branch `feat/workflow-history-unification` (off
main `28ce6a28`). No GitHub issue. The source is the workflow input
"make workflow self-improvement history and rollback complete and unified",
parts (A), (B, fallback) and (C), plus the web console screen. Open
decisions, each with the recommended answer this design already assumes, are
in `design-docs/user-qa/qa-workflow-history-unification.md`.

Baselines that this design extends. It does not restart them:

- `design-workflow-definition-store.md` (#179): data model §3, store
  selection §4, operations §5, diff §6, export §7, surfaces §8. This design
  **supersedes its §11 "existing surfaces left unchanged"** and user QA Q1
  ("registry and editor edits stay file-only") for the registry,
  `workflow restore` and `workflow self-improve` paths (§3.6 below).
- `design-efficient-history-and-storage.md`: the shared `VersionedHistory`
  engine, retention, pins, guarded deletes, undo/redo (§2, §4). Reused
  unchanged except for one extra retention pin (§5.6).
- `design-evolution-history.md`: the bundle snapshot format
  (`content-addressed-chunks`, schema 2). Reused; §4 adds one optional
  manifest field.
- `design-loop-engineering-convergence-and-operations.md` S10: baseline and
  regression classification (`loop baseline`, `loop regress`). Reused
  unchanged; §5 consumes its verdict.

Out of scope: RielaApp native (SwiftUI) UI, Kaiba, memory history,
service-run resolution changes (a deleted registry workflow keeps its store
head, QA Q3), releases and `VERSION`.

## 1. Verified current state (`28ce6a28`)

Definition store (`Sources/RielaCore/WorkflowDefinitionStore*.swift`,
`WorkflowDefinitionHistorySchema.swift`), runtime database generation 12
(`SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:124`):

- `WorkflowDefinitionOperation` is `seed | import | forceUpdate |
  updatePrompt | update | restore | undo | redo | prune | purgeHistory`
  (`WorkflowDefinitionStore.swift:5`). Actor kinds `user | cli | api |
  improvementNode` (`:21`). Evidence kinds `session | stepExecution |
  review` (`:38`). `WorkflowDefinitionApprovalState` has only `applied`
  (`:73`).
- `definition_change_audit` columns `operation`, `evidence_refs_json`,
  `actor_kind` and `approval_state` are unconstrained TEXT. UPDATE is
  forbidden by trigger (`WorkflowDefinitionHistorySchema.swift:129`), so the
  audit table cannot carry a mutable proposal status.
- Retention operations already write **audit-only rows** whose
  `version_id = previous_version_id = head` and `diff_json = []`
  (`WorkflowDefinitionStore+Retention.swift:265-283`).
- No registry, `workflow restore` or `workflow self-improve` path writes a
  definition row (#179 §11).
- GraphQL definition DTOs carry `operation` and `actorKind` as `String`
  (`Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift:7,66,150`), so new
  values need no GraphQL enum change.

File change paths that publish bundle snapshots today:

| Path | Code | Snapshots |
| --- | --- | --- |
| Registry update (`replaceLocked`) | `WorkflowMutableRegistry.swift:38-110` | `registry-before-<tx>` (`:64`), `registry-after-<tx>` in `finish` (`:654`) |
| Registry create/register | `WorkflowMutableRegistry+Registration.swift:40-80` | before only when `hadOriginal` (`:62`); after in `finish` |
| Registry delete | `WorkflowMutableRegistry+CRUD.swift:60-110` | `registry-before-<tx>` (`:85`); `finish` skips after for delete |
| `workflow self-improve --yes` | `WorkflowSelfImproveVersioning.swift:249-345` | pre-op snapshot (`createdBeforeChangeSetId`), then `WorkflowDirectoryTransactionCoordinator.commit(kind: .apply)` |
| `workflow restore <snapshot> --yes` | `WorkflowVersionCommands.swift:225-330` | pre-restore snapshot, then `commit(kind: .restore)`; dry-run unless `--yes` |

- Mutable-registry self-improve and restore run inside
  `withWorkflowMutationAccess` (`WorkflowMutableRegistry+Access.swift:88`),
  whose publish closure calls `replaceLocked`, so they also pass through the
  registry `finish`.
- Registry recovery rolls a published replacement forward by calling
  `finish` again (`WorkflowMutableRegistry.swift:462-467`).
- The coordinator holds the per-workflow target lock across commit and its
  `postCommitPublication` callback (`WorkflowDirectoryTransaction.swift:229,367,779`).
- `WorkflowBundleSnapshotManifest` (`WorkflowHistoryModels.swift:265`) has
  no parent link. `workflow version diff` reports file-level kinds only
  (`added | removed | content-modified | executable-bit-only`,
  `WorkflowVersionCommands.swift:13-25,204-223`). `workflow.versions`,
  `workflow.version` and `workflow.restore` are CLI-only catalog rows
  (`SurfaceCatalog+Rows.swift:170-172`).

Regression:

- The intake calls `LoopRegressionVerdict` unused. Correction:
  `LoopRegressionClassifier.verdict` is called by `riela loop regress`
  (`LoopBaselineCommands.swift:137`), which only reports (exit 0, 3 or 4).
  No code reacts to a regression.
- Baselines live in the session store (`setLoopBaseline`,
  `LoopBaselineCommands.swift:229`). `resolveBaselinePair` (`:296`) resolves
  baseline and target (newest completed session with loop evidence unless
  `--session`).
- Loop rows are excluded from GraphQL (`loopDefaults.graphql =
  loopNamesRetired`, `SurfaceCatalog+Rows.swift:391`).
- A best-effort post-terminal hook exists:
  `dispatchLoopNotificationsAfterTerminalPersistence`
  (`WorkflowRunCommand+LoopOperations.swift:61`, called at
  `WorkflowRunCommand.swift:1001`). It never alters the run outcome and
  records failures as session diagnostics.

Web console: SolidJS. `workflow-detail` tabs are `settings | history |
definition` (`web/src/routes.ts`). GraphQL goes through
`web/src/console/client.ts` (`execute`, `/graphql`). Scripts: `bun run lint`
(eslint + source audit), `bun run typecheck`, `bun run build`, `bun test src`.

## 2. Boundary decision: what is unified and what falls back to (B)

**Unified into the definition store (A).** Every change to a workflow's
definition, whatever the path, appears as one lineage in
`definition_versions` / `definition_change_audit` with operation, actor,
reason, evidence and the §6 structural diff. Restore, undo/redo, retention
and the web screen work on this one lineage.

**Not unifiable, kept in bundle snapshots (B).** The definition document
stores only `runtime` plus the own `authoredFiles` (workflow.json, own node
files, own prompt files; #179 §3). It deliberately excludes scripts, mock
scenarios, add-on files, binaries, executable bits and any other owned file.
Byte-exact file restore of those assets therefore cannot come from the
definition store. Storing them there would change the #179 document format
and digest and would make every service-run pin depend on non-definition
bytes.

Decision: bundle snapshots stay, demoted to the **file-restore auxiliary**:

- They are not a competing history. The definition audit references them
  (§3.3 evidence `bundleSnapshotBefore` / `bundleSnapshotAfter`), and a
  snapshot restore records its definition version through the same sync as
  every other file change.
- B applies to them in full, because file restore remains a user-facing
  operation: `parentSnapshotId` (§4.1), a unified text diff (§4.2), and
  GraphQL `workflowVersions` / `workflowVersionDiff` /
  `restoreWorkflowVersion` with dry-run by default (§4.3).

## 3. (A) One lineage: file changes write definition versions

### 3.1 Change paths and attribution

Every committed file change of a workflow runs exactly one **definition
sync** (§3.3). Attribution comes from the path:

| Path | Operation | Actor | Reason (generated, non-empty) | Runtime evidence |
| --- | --- | --- | --- | --- |
| Registry create / register | `registryWrite` | caller surface | `registry create via <surface>` | `fileTransaction:<tx>`, `bundleSnapshotAfter:registry-after-<tx>` |
| Registry update / overwrite register / consolidate replace | `registryWrite` | caller surface | `registry update via <surface>` | `fileTransaction`, `bundleSnapshotBefore:registry-before-<tx>`, `bundleSnapshotAfter` |
| Registry delete | `registryDelete` (audit-only) | caller surface | `registry delete via <surface>` | `fileTransaction`, `bundleSnapshotBefore` |
| `workflow restore <id> --yes` / `restoreWorkflowVersion(apply: true)` | `snapshotRestore` | caller surface | `--reason`/`reason` if given, else `restore bundle snapshot <id>` | `fileTransaction`, `bundleSnapshotBefore:<pre-restore>`, `bundleSnapshotAfter:<source>` |
| `workflow self-improve --yes` | `selfImprove` | `cli` | `self-improve change set <changeSetId>: <proposal rationale>` | `fileTransaction`, `bundleSnapshotBefore:<pre-op>`, `review:<changeSetId>`, `session:<proposal source session>` |
| Regression rollback, bundle mode (§5.5) | `rollback` | approver or `system` | §5.5 | `fileTransaction`, `bundleSnapshotBefore`, `bundleSnapshotAfter`, `rollbackProposal:<id>`, `session:<baseline>`, `session:<target>` |

Caller surface actor: CLI → `cli`, id `--actor` (where the command has it)
or the OS user; GraphQL registry and version mutations → `api` (or `user`
when the GraphQL input says so, as #179 §5); the RielaApp/serve web console
goes through GraphQL. Registry commands gain no new flags.

For a mutable-registry workflow the single sync runs in the registry
`finish` step (§3.4). Self-improve, `workflow restore` and rollback pass
their attribution through `withWorkflowMutationAccess`'s publish closure
into `replaceLocked`. They do not sync again after the coordinator returns.
For a non-registry (project or direct-scope) workflow the sync runs once
after the coordinator commit, under the same target lock (§3.4).
Immutable/installed-package workflows have no file change path.

New `WorkflowDefinitionOperation` values: `registryWrite`, `registryDelete`,
`snapshotRestore`, `selfImprove`, `rollback`. New evidence kinds:
`fileTransaction`, `baselineTransaction`, `bundleSnapshotBefore`,
`bundleSnapshotAfter`, `rollbackProposal`. Only the change-sync audit of a
transaction carries `fileTransaction:<tx>`. Only the §3.3 baseline audit
carries `baselineTransaction:<tx>`. Only runtime code writes these kinds. CLI `--evidence` and
GraphQL `evidence` inputs keep accepting only `session | stepExecution |
review` (runtime records stay runtime-owned). New actor kind `system`
(automatic rollback only), rejected as input on CLI `--actor-kind` and
GraphQL `actorKind`, like `improvementNode` on GraphQL. All are TEXT values,
so (A) needs **no DDL**.

### 3.2 Target store

The sync writes to the store a service run of that workflow would read, so
that the lineage and service execution agree:

1. If a candidate store for the workflow's resolved source scope already
   has a head (`WorkflowDefinitionStoreSelection.rootWithHead`, same
   `--session-store` → `RIELA_SESSION_STORE` → scope order as #179 §4 step
   1), use it.
2. Otherwise use the seed root (`seedRoot`, the store a first service run
   would seed). Mutable-registry workflows resolve as `user` scope.

The store-root rule has one implementation shared by service resolution and
the sync. The registry module cannot import `RielaCLI`, so the pure
root-resolution logic moves down next to `WorkflowDefinitionService`
(`RielaWorkflowRegistry`). The sync is reached through a
`WorkflowDefinitionChangeRecording` dependency on `WorkflowMutableRegistry`
and the coordinator call sites. Production construction uses the real
recorder. Every hosting surface (CLI, `riela serve`, RielaApp GraphQL)
passes the session store root it already passes to
`WorkflowDefinitionGraphQLProvider`. Tests must inject a recorder bound to a
temporary store root and must never reach `~/.riela/sessions` (§8).

### 3.3 Sync semantics

The sync is the #179 `import --force` pipeline applied to the committed
definition document, with the attribution from §3.1. The committed document
is computed before publication (§3.4) with the #179 own-directory overlay
loader: the staged authored files are served at the live source directory,
so the stdio paths come out exactly as a post-publication resolve would make
them.

- **Baseline capture (head absent, workflow already exists).** Under the
  file lock and **before** the file change commits, the change path checks
  the §3.2 store. When it has no head and the workflow existed before this
  change, the path captures the current, still-unchanged files as a
  baseline.
  - "Existed before" means: a registry update/overwrite (`hadOriginal`),
    self-improve, `workflow restore`, or a bundle rollback.
  - The baseline is a `seedIfAbsent` write with operation `import`, reason
    `baseline captured before first tracked <operation> (<tx>)`, the
    change's actor, and evidence `baselineTransaction:<tx>` and
    `bundleSnapshotBefore`. It **never** carries `fileTransaction:<tx>`, so
    it can never satisfy the change-completion predicate below.
  - Its document comes from the same file resolution a first service run
    would seed from. That resolution has already validated the workflow:
    self-improve and restore resolve the bundle first, and registry entries
    were validated when registered.
  - **Concurrent seed.** If a concurrent service-run seed wins, the winner's
    head is used. It was read from the same pre-change files, because the
    file change has not committed.
  - **Failure.** A failed baseline write aborts the file change before any
    file moves, with `definition_baseline_failed`. Nothing changes.
  - **Retry.** A retry finds the head and skips the capture, so capture is
    idempotent. If the file change later fails, the baseline stays. It
    equals the files and is harmless.
  - **Effect.** The following sync then writes the change with `parent =
    baseline`. A first tracked self-improvement therefore always has a
    retained, file-derived parent, and both `undo` and regression rollback
    can return to it (§5.3).
  - **Before-head race closed.** The head exists before the file commit, so
    a service run can no longer seed the post-change files under operation
    `seed` and turn the change into an unattributed audit-only row.
- **No head, genuinely new workflow** (registry create/register without
  `hadOriginal`). Seed a head with the path's operation (not `seed`) and
  `previous_version_id = null`. No earlier definition exists to invent.
- **Head present, digest differs.** Write a new version: parent = current
  head, `last_file_version_id` moves to it (the content came from files),
  and `overwritten_changes_json` is recorded exactly as for
  `forceUpdate` when store-only changes exist after `last_file_version_id`.
  The command result carries a warning naming the overwritten audit ids.
  The overwritten version stays restorable (QA Q1).
- **Head present, digest equal** (only non-definition assets changed, or an
  identical replace), or `registryDelete`. No version is created and the
  revision is not bumped. At most one **audit-only row** is written
  (`version_id = previous_version_id = head`, `diff_json = []`), the same
  shape retention rows use, so the history links the change's bundle
  snapshots.
  - **Bounded by collapsing (QA Q7).** The row is skipped when an audit-only
    row with the same `operation` already exists for the same head
    `version_id`. Repeated identical no-ops therefore add at most one row per
    (head version, operation).
  - **Retention.** Audit-only rows reference only the head, so they fall
    under the existing audit rule (#179 / efficient-history §4: an audit row
    is deleted once both its version ids are dropped) and leave with that
    version.
- **Delete without head.** Nothing is written and no baseline is captured:
  capturing one would make a deleted workflow runnable from the store.
  There is no lineage to attach to. The before-delete bundle snapshot stays
  in the file history.
- **Idempotency: the change-completion predicate.** A transaction `tx`
  whose attributed operation is `op` and whose committed document digest is
  `d` is **complete** iff either of these holds:
  - (a) `EXISTS(definition_change_audit row with workflow_name = W AND
    operation = op AND evidence_refs_json contains {kind: fileTransaction,
    id: tx})`;
  - (b) `op ≠ rollback` and the current head's digest equals `d`. Nothing
    is left to write; a collapsed no-op may have skipped its audit-only
    row.

  A baseline B never satisfies (b) for a definition-changing first-use
  change, because `d ≠ B.digest`.
  - `op` is one of `registryWrite | registryDelete | snapshotRestore |
    selfImprove | rollback`. It is taken from the registry transaction
    record or the coordinator intent, never from whatever row happens to
    exist.
  - A baseline row (operation `import`, evidence `baselineTransaction:tx`)
    and a concurrent service-run `seed` row never match.
  - **Single definition.** The same predicate, and only it, is used by the
    sync before writing, by registry recovery (`finish` replay), by
    coordinator replay and intent deletion (§3.4), and by bundle-rollback
    recovery (§5.5, which additionally requires `rollbackProposal:<id>`).
  - **Outcomes.** If the predicate holds, the sync is a no-op that returns
    that row. Otherwise it writes the change on the current head, or CASes
    on `vT` for a rollback. For a first-use change the current head is the
    baseline, so the change becomes a distinct version with `parent =
    baseline`.
  - **Audit-only rows.** An unchanged-digest change still satisfies the
    predicate, through its audit-only row with `operation = op`.
- **Validation.** The pipeline's existing validators run. A bundle the file
  path already accepted but the store rejects fails the sync (§3.4). It
  never writes a partial row.

### 3.4 Ordering, failure and concurrency

The file publication is the commit point. The sync is a roll-forward step
after it and runs under the per-workflow lock that serialized the file
change, so syncs land in commit order:

- **Registry.** Order: §3.3 baseline capture (and, for a bundle rollback,
  the §5.5 claim) → before-snapshot → transaction record → publish →
  after-snapshot → **sync** → transaction-record removal. The sync, the
  after-snapshot and the record removal run inside `finish`. Everything
  runs under the registry workflow lock. The attribution (operation, actor,
  reason, caller evidence, and `expectedHeadVersionId` for rollback) is
  persisted in the registry transaction record as one new optional field,
  so recovery can replay it. If the sync throws, the record stays. The existing
  recovery (`recoverLocked` → `finish`) re-runs it on the next access to
  that workflow. The §3.3 change-completion predicate (record operation plus
  `fileTransaction:<tx>`) makes the replay idempotent. A baseline written
  for the same `tx` does not count as completion. The failing call reports `definition_sync_failed`, says the
  file change is committed, and says the history entry is pending. Until the
  store accepts the write, later mutations of that workflow fail at
  recovery. This fail-closed choice keeps one lineage.
  Registry replay re-derives the document from the registry directory. That
  is exact: `recoverLocked` calls `finish` only when the directory digest
  equals the record's `replacementDigest` (`WorkflowMutableRegistry.swift:458-467`).
- **Coordinator (non-registry): durable sync intent.**
  `WorkflowDirectoryTransactionCoordinator.commit` gains one locked
  pre-publication callback, run under the target lock after
  `performPreflight` and before the `committing` record. It does the
  following in order:
  1. the §3.3 baseline capture;
  2. for bundle rollback only, the §5.5 claim;
  3. writes the **sync intent**
     `<historyRoot>/definition-sync/<transactionId>.json` (atomic write plus
     fsync), containing:
     - `transactionId`, `workflowName` and the selected store root;
     - the committed definition document (canonical JSON, computed from
       staging, §3.3) and its digest;
     - `expectedAfterBundleDigest`;
     - the full attribution (operation, actor, reason, evidence);
     - `expectedHeadVersionId`, set only for rollback (§5.5).

  After the coordinator reaches `published`, still under the lock, the sync
  writes **the intent's document**, never re-read files. It then deletes
  the intent. A sync failure never rolls back the committed files: the
  callback runs after the publication point, and its error is reported, not
  thrown into the coordinator's rollback path. The command exits non-zero
  with `definition_sync_failed` (files committed, history entry pending).

  **Replay** runs under the same target lock in three places:
  - in the locked preflight of the next coordinator commit for that target,
    before anything else;
  - in `WorkflowDirectoryTransactionCoordinator.recover`;
  - at the start of `riela workflow definition import` for that workflow,
    the documented recovery command, which takes the target lock for the
    replay.

  Replay processes pending intents in transaction commit order:
  - An intent whose transaction never committed is deleted without writing
    anything. "Never committed" means no transaction audit with outcome
    `applied|restored` exists for it and the live digest does not equal its
    `expectedAfterBundleDigest`.
  - An intent whose transaction satisfies the §3.3 change-completion
    predicate (an audit row with the intent's operation and
    `fileTransaction:<tx>`, which happens after a crash between the database
    commit and intent deletion) is deleted without writing. A baseline row
    with `baselineTransaction:<tx>` never satisfies the predicate, so it
    never deletes an intent and never suppresses the change write.
  - Every other intent is written exactly once with its original document
    and attribution, then deleted.

  If replay fails, the next mutation is refused with `definition_sync_pending`
  and nothing changes. The intermediate change is therefore never skipped,
  later changes keep commit order, and attribution is never lost. The intent
  file is runtime-owned state, kept in the history root next to the
  coordinator's `transactions/` records.
- **Store writes** use the existing `BEGIN IMMEDIATE` and head CAS. A
  concurrent store-only write (definition update, improvement node,
  store-mode rollback) between two file changes either is overwritten and
  recorded (§3.3) or, if it lands first, becomes the parent. A plain
  file-change sync appends on the current head and does not CAS on an
  earlier head. A **rollback** sync always CASes on its claimed `vT` and
  never rebases (§5.5). While a bundle rollback is in progress, the §5.5
  guard refuses every other head move for that workflow.
- **Lock order** is always the file lock (registry workflow lock or
  coordinator target lock) first, then short `BEGIN IMMEDIATE` transactions.
  No database transaction is held while waiting for a file lock.

### 3.5 Reads

`workflow definition history|show|diff` and GraphQL
`workflowDefinitionHistory` / `workflowDefinitionDiff` need no new
arguments. They show the new operations, evidence kinds and audit-only rows.
Existing `restore`, `undo` and `redo` work on these versions unchanged, and
remain definition-store operations (files are untouched).

### 3.6 Behavior change for service runs (supersedes #179 §11 and QA Q1)

Registry edits (including RielaApp editor saves through GraphQL), `workflow
restore` and `workflow self-improve` now move the store head. The next
service run uses them without `import --force`. One-time CLI runs still read
files and still write no definition rows (#179 §1). The sync is a registry
or command side effect, not a run.

## 4. (B) Bundle snapshots as the file-restore auxiliary

### 4.1 `parentSnapshotId`

- `WorkflowBundleSnapshotManifest` gains optional `parentSnapshotId`: the
  newest existing snapshot (by `createdAt`, then `snapshotId`) in the same
  history root for the same target identity at creation time, or nil for the
  first.
- It is computed under the lock that already serializes the snapshot
  (registry workflow lock or coordinator target lock). Snapshots taken
  concurrently through different roots may share a parent. The field is
  advisory lineage, not a CAS token.
- The canonical encoding omits the key when nil, so existing schema-2
  manifests re-encode byte-identically and their `manifest.sha256` sidecars
  still verify. `schemaVersion` stays 2. No snapshot is rewritten.
- `workflow versions` JSON and GraphQL `workflowVersions` expose it.

### 4.2 Unified text diff

- `riela workflow version diff <from> <to> --content` (and GraphQL
  `includeContent: true`) adds a `content` object to every `added`,
  `removed` and `content-modified` difference. Without the flag, output is
  unchanged.
- `content` is either `{unified: "<text>"}` or `{binary: true}` or
  `{tooLarge: true, limitBytes}`:
  - `unified`: a deterministic line diff with `--- a/<path>` / `+++
    b/<path>` headers, `@@` hunks and 3 context lines. An added or removed
    file diffs against empty.
  - `binary` when either side is not valid UTF-8 or contains NUL.
  - `tooLarge` when either side exceeds 262144 bytes.
- `executable-bit-only` entries carry no content. `current` stays a valid
  reference.
- The text output prints each unified block after its kind line.

### 4.3 GraphQL file-restore surface

The operations are served by the provider that serves `workflowDefinition*`
(`RielaCLI/WorkflowDefinitionGraphQLProvider`). They delegate to one shared
snapshot service, factored out of `WorkflowVersionCommand`, which the CLI
commands also use:

- Query `workflowVersions(workflowName, scope, limit, beforeSnapshotId)` →
  `{workflow, snapshots[{snapshotId, parentSnapshotId, createdAt,
  bundleDigest, createdBySessionId, createdBeforeChangeSetId,
  createdBeforeRestoreId, mutationReferences, restoreReferences}],
  nextBeforeSnapshotId}`.
- Query `workflowVersionDiff(workflowName, scope, from, to,
  includeContent)` → the §4.2 result. `from`/`to` accept a snapshot id or
  `current`.
- Mutation `restoreWorkflowVersion(input: {workflowName, scope, snapshotId,
  apply: Boolean = false, reason, actorKind, actorId})`:
  - `apply` false (the default) is the dry run. It writes nothing and
    returns the planned files and dirty conflicts.
  - `apply: true` is the explicit approval (the CLI `--yes`). It restores
    through the coordinator or registry exactly as the CLI does, then runs
    the §3 sync as `snapshotRestore`.
  - The result adds `definitionVersionId` and `definitionAuditId` from the
    sync.
- `scope` follows the existing registry GraphQL scope argument. No arbitrary
  filesystem path is accepted. Errors use upper-snake codes:
  `WORKFLOW_VERSION_NOT_FOUND`, `WORKFLOW_RESTORE_DIRTY_CONFLICTS`,
  `WORKFLOW_IMMUTABLE`, `DEFINITION_SYNC_FAILED`.

CLI `workflow restore` gains optional `--reason` (recorded in the sync
audit). Without it the generated reason is used.

## 5. (C) Regression-driven rollback

### 5.1 Policy

`workflow.json` → `loop.regressionRollback: {policy: "manual" |
"approval-required" | "automatic"}` (new optional `WorkflowLoopMetadata`
field, validated as a closed enum).

- **Policy source.** The policy is read from the **rollback target**
  version's stored document (the version that was in effect before the
  improvement). An improvement therefore cannot raise its own rollback
  policy. Absent → `manual`.
- `automatic` is used only when that document explicitly says so, which
  meets the "approval-gated by default" constraint.

### 5.2 Triggers

1. **Explicit check**, CLI and GraphQL:
   - CLI: `riela workflow definition rollback check <workflow> [--session
     <targetSessionId>]`.
   - GraphQL: `checkWorkflowRegressionRollback`.
   - It uses the existing `resolveBaselinePair` (baseline from the session
     store, target = given session or newest completed session with loop
     evidence) and `LoopRegressionClassifier.verdict`. The pair resolution
     moves to a shared helper so `loop regress` and the check use one
     implementation.
   - `loop regress` itself stays read-only and unchanged.
2. **Post-run.** After `dispatchLoopNotificationsAfterTerminalPersistence`,
   with the same contract (best effort, never changes the outcome or exit
   code, failures become session diagnostics). It runs the same evaluation
   with target = the finished session, but only when all of these hold:
   - the run is store-pinned (`definitionSource.kind = store`, a service
     run);
   - the run's workflow declares `loop.regressionRollback`;
   - the session completed with loop evidence;
   - a baseline exists.

   One-time runs (`riela workflow run`, `loop start`) never open definition
   tables (#179 §1, §4). Regressions measured by file-origin runs are
   therefore evaluated only by the explicit check, which a routine or cron
   can schedule.

### 5.3 Evaluation

1. Resolve the pair. A missing baseline or evidence → outcome `noBaseline` /
   `noTargetEvidence`.
2. Verdict without regression → `noRegression`.
3. Resolve the definition versions of baseline and target sessions:
   - `definitionSource.kind = store` → `versionId` in
     `definitionSource.storeRoot`;
   - `kind = file` → the newest version in the §3.2 store whose
     `document_digest` equals the session's file digest (the digests are
     comparable, #179 §3).
   - An unresolved target → `targetVersionUnknown`.
4. Eligibility. All of these must hold, otherwise the outcome is
   `notEligible` with the first failing code:
   - target version `vT` is the current head (`headMoved`);
   - `vT` is an **improvement version**: operation `selfImprove`, or
     operation `update | updatePrompt` with actor kind `improvementNode`
     (`notImprovementVersion`);
   - the baseline version differs from `vT` (`sameVersionAsBaseline`);
   - `vT.parent_version_id` exists (`noParent`).

   An improvement version always has a parent. An improvement-node `update`
   or `updatePrompt` requires an existing head (#179 §5,
   `definition_not_registered`). A `selfImprove` version is written on top
   of either an existing head or the §3.3 baseline captured before the
   first tracked change. The first self-improvement of a previously
   untracked mutable (registry/user-scope) workflow is therefore eligible (project/direct sources stay immutable for self-improve and restore, operator decision 2026-11-02), and its rollback
   target is that baseline. `noParent` remains a fail-closed code for a
   corrupted lineage. It is never an expected first-use outcome.
5. Mode:
   - `bundle` when `vT.operation = selfImprove`. Files changed, so the
     rollback must restore files. The snapshot is `vT`'s
     `bundleSnapshotBefore`.
   - Otherwise `store`. Improvement-node edits never touched files.
6. Policy from §5.1. If `vT` is `selfImprove` and its audit recorded
   overwritten store-only changes, its parent is not the pre-improvement
   file state. The policy is then forced to `manual` with diagnostic
   `divergedParent`.
7. `INSERT … ON CONFLICT(workflow_name, regressed_version_id) DO NOTHING`,
   then read the row:
   - an existing proposal → outcome `existing`, unchanged;
   - a new proposal → `proposed`, with status `recorded` (manual) or
     `pending`.
8. If the new proposal's policy is `automatic`, apply it immediately (§5.5)
   as actor `system`, id `regression-rollback@<targetSessionId>`.

### 5.4 Proposal storage (runtime database generation 12 → 13)

Proposal status must change, and `definition_change_audit` forbids UPDATE.
Proposals therefore get their own table in the definition store's database,
created by an additive `SQLiteSchemaMigration(fromGeneration: 12)` and by
`ensureSchema` for fresh databases:

```
definition_rollback_proposals(
  proposal_id TEXT PRIMARY KEY,            -- defrp-<uuid>
  workflow_name TEXT NOT NULL,
  regressed_version_id TEXT NOT NULL, rollback_to_version_id TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('store','bundle')), bundle_snapshot_id TEXT,
  baseline_session_id TEXT NOT NULL, target_session_id TEXT NOT NULL,
  regressions_json TEXT NOT NULL,
  policy TEXT NOT NULL CHECK (policy IN ('manual','approvalRequired','automatic')),
  status TEXT NOT NULL CHECK (status IN ('recorded','pending','applying','applied','rejected','superseded','failed')),
  claim_transaction_id TEXT, claimed_at TEXT,   -- bundle-mode claim (§5.5)
  created_actor_kind TEXT NOT NULL, created_actor_id TEXT,
  decided_actor_kind TEXT, decided_actor_id TEXT, decision_reason TEXT,
  applied_version_id TEXT, applied_audit_id TEXT, failure_code TEXT,
  diagnostics_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  UNIQUE(workflow_name, regressed_version_id))
index (workflow_name, status, created_at)
```

- Transitions are code-enforced as CAS updates on the expected current
  status:
  - `pending → applied` (store mode) and `pending → rejected | superseded |
    failed`;
  - `pending → applying` (bundle-mode claim);
  - `applying → applied | pending | failed` (bundle completion, claim
    release, permanent failure);
  - `recorded` is terminal and informational.
- At most one `applying` proposal exists per workflow (partial unique index
  on `workflow_name WHERE status = 'applying'`).
- Rows are deleted only by definition retention (§5.6, QA Q7). There is
  no user-facing delete command.
- This is the only DDL in the design. The RielaMemory schema version is
  untouched.

### 5.5 Approve, reject, apply

- **Approve**, available only for `pending`:
  - CLI: `riela workflow definition rollback approve <workflow> --proposal
    <id> [--reason <r>] [--actor <id>]`.
  - GraphQL: `approveWorkflowRollbackProposal`.
  - Approve runs apply.
- **Reject**, available only for `pending`, `--reason` required:
  - CLI: `riela workflow definition rollback reject <workflow> --proposal
    <id> --reason <r>`.
  - GraphQL: `rejectWorkflowRollbackProposal`.
  - Reject sets `rejected` and records the decision. It writes no
    definition row, because nothing changes.
  - Reject is a CAS on `pending`. Rejecting an `applying` proposal returns
    `rollback_in_progress`. A reject that wins before the claim makes the
    later claim fail with `rollback_proposal_not_pending`, so no files
    change.
- **Audit reason** for an applied rollback: `regression rollback of <vT> to
  <parent>: <regression kinds> (baseline <B>, target <T>)`, followed by
  `; approved: <reason>` when one is given.
- **Evidence** always includes `rollbackProposal:<id>`, `session:<B>` and
  `session:<T>`.

Apply:

- **Precondition.** The head must still be `vT`. Otherwise the proposal
  becomes `superseded` and the call returns `rollback_superseded`.
- **Store mode.** One `BEGIN IMMEDIATE` on the definition database does all
  of the following:
  - re-checks the proposal is `pending` and the head is `vT`;
  - writes the parent's document as a new version with operation
    `rollback` (parent = `vT`, `expectedVersionId = vT`), plus its audit;
  - sets the proposal to `applied` with `applied_version_id` and
    `applied_audit_id`.

  The step is atomic and does not touch files.
- **Bundle mode: claim protocol.** Files change before the definition write,
  so pending status and the expected head `vT` are protected for the whole
  operation by a durable claim:
  1. **File lock.** Acquire the workflow's file lock: the registry workflow
     lock inside `withWorkflowMutationAccess`, or the coordinator target
     lock through the §3.4 locked pre-publication callback. Every other
     file-change path for the workflow now waits.
  2. **Claim** (one `BEGIN IMMEDIATE`, before any staging is published).
     Require proposal status `pending` and head `vT`, then set `applying`
     with `claim_transaction_id = <file transaction id>` and `claimed_at`.
     - Head ≠ `vT` → `superseded`, return `rollback_superseded`, release
       the lock.
     - Status not `pending` → `rollback_proposal_not_pending` (or
       `rollback_in_progress` for `applying`).
     - Either way nothing has changed.
  3. **Head guard.** While any proposal of a workflow is `applying`, every
     definition head move for that workflow is refused in its own
     transaction with `definition_rollback_in_progress` (retryable).
     - Refused: `commit` / `update` / `update-prompt` / `restore` /
       `undo` / `redo` / `import --force` / improvement-node apply / any
       other sync or store-mode rollback.
     - Allowed: only the write that carries `rollbackClaim = <proposalId>`
       together with `expectedCurrentVersionId = vT`.
     - Store-only writers do not take the file lock, so this guard is what
       excludes them.
  4. **Restore.** Restore `bundle_snapshot_id` through the shared snapshot
     service (approved). Use registry publication for mutable workflows,
     or the coordinator with a durable intent whose
     `expectedHeadVersionId = vT` for the others.
  5. **Sync.** One transaction writes the rollback version with operation
     `rollback`, `expectedCurrentVersionId = vT` (CAS, never rebased onto a
     newer head, never a force overwrite) and evidence
     `rollbackProposal:<id>`. The same transaction sets the proposal
     `applied` with `applied_version_id` and `applied_audit_id`. Release the
     file lock.

  Failures and recovery (all handled under the file lock, which is
  acquired before the claim):
  - **Restore fails before publication** (dirty conflicts, missing snapshot,
    validation). The claim is released in one transaction: `applying →
    failed` with `failure_code` for a permanent error, or `applying →
    pending` for a transient error. Files and head are unchanged.
  - **Process dies after the claim.** The proposal stays `applying` and the
    guard keeps blocking head moves. An `applying` proposal seen by a holder
    of the file lock is therefore abandoned. Recovery runs before any other
    work in:
    - `rollback approve` and `rollback check` (both mutations; `rollback
      list` stays read-only and just shows `applying`);
    - the registry `recoverLocked`;
    - coordinator replay / `recover`;
    - `workflow definition import`.

    Recovery resolves the claim as follows:
    - an audit row with operation `rollback`, `fileTransaction:<claim tx>`
      and `rollbackProposal:<id>` exists (the §3.3 predicate) → set
      `applied`;
    - the claimed file transaction committed (registry record digest
      matches, or the coordinator intent is valid per §3.4) → replay its
      sync with the persisted rollback attribution and CAS `vT`, then
      `applied`. `vT` is still the head, because the guard blocked every
      other move;
    - the claimed transaction did not commit (files restored to their
      pre-change state by the registry or coordinator recovery) → `applying
      → pending`.

    Each path ends in exactly one of: no file change and `pending`/`failed`,
    or files restored, one `rollback` version and `applied`.
  - **Competing approvals.** The second approver either waits on the file
    lock and then fails the claim CAS (`rollback_proposal_not_pending`), or
    loses the claim CAS outright. Only one rollback is published.
  - **Lock order.** The file lock is taken first, then short database
    transactions (the §3.4 rule). No transaction is held across file I/O
    waits, so registry, coordinator and rollback paths cannot deadlock.
  - **Post-check.** If the new head digest differs from the parent's digest
    (for example, an `extends` base changed), the proposal is still
    `applied`, with diagnostic `rollbackDigestMismatch`.
- **Permanent failures** set `failed` with `failure_code`:
  `rollback_snapshot_unavailable`, `definition_version_not_retained`,
  `restore_dirty_conflicts` and `invalid_definition`. Transient errors (busy
  store, lock timeout) leave the proposal `pending` and return the error.
- **List.** CLI: `riela workflow definition rollback list <workflow>
  [--status <s>] [--limit <n>]`. GraphQL: `workflowRollbackProposals`.

### 5.6 Retention

The definition retention pin set gains one rule: the `regressed_version_id`
and `rollback_to_version_id` of every `pending` or `applying` proposal are
protected, so an approval cannot lose its target. Terminal proposals
(`recorded`, `rejected`, `applied`, `superseded`, `failed`) are not pinned.

**Proposal pruning (QA Q7, binding).**

- **Which rows.** A terminal proposal row is deleted when neither its
  `regressed_version_id` nor its `rollback_to_version_id` is still a
  retained version. This mirrors the audit-row rule. A `pending` or
  `applying` row is never deleted.
- **Where.** The delete runs inside the existing guarded retention
  deletion, in the same transaction, after versions are dropped. That
  deletion is shared by:
  - default per-commit retention;
  - `workflow definition prune`;
  - `workflow definition purge-history`;
  - `riela gc` / automatic retention, which reach definitions through the
    same engine path (`WorkflowDefinitionStore+Retention.swift`).
- **Reporting.** Retention reports carry a `proposalsDropped` count.
- **Effect.** Storage stays bounded by retained versions: there is at most
  one proposal per regressed version, and terminal proposals leave with
  their versions.

### 5.7 No rollback loops

- A `rollback` version is not an improvement version, so a regression
  measured on it never produces a further proposal.
- At most one proposal exists per regressed version.
- A proposal applies only while its version is the head.
- Automatic mode therefore makes at most one head move per improvement
  version.

## 6. Surfaces

**CLI** (help text in `RielaCLIApplication.swift`; `--session-store`,
`--scope`, `--output text|json` as for the other `workflow definition`
commands):

```
riela workflow definition rollback check <workflow> [--session <id>]
riela workflow definition rollback list <workflow> [--status recorded|pending|applying|applied|rejected|superseded|failed] [--limit <n>]
riela workflow definition rollback approve <workflow> --proposal <id> [--reason <r>] [--actor <id>]
riela workflow definition rollback reject <workflow> --proposal <id> --reason <r> [--actor <id>]
riela workflow version diff <from> <to> [--content]
riela workflow restore <snapshot> [--yes] [--reason <r>]
```

Closed CLI error codes:

- `rollback_proposal_not_found`
- `rollback_proposal_not_pending`
- `rollback_superseded`
- `rollback_snapshot_unavailable`
- `rollback_in_progress`
- `reason_required`
- `definition_sync_failed`
- `definition_sync_pending`
- `definition_baseline_failed`
- `definition_rollback_in_progress` (from any definition write while a
  bundle rollback is `applying`)

**GraphQL** (`WorkflowDefinitionGraphQLProviding`, DTOs in `RielaGraphQL`,
implementation in `RielaCLI`). Conformers that do not implement the new
operations return `DEFINITION_OPERATION_UNSUPPORTED` by default (the
existing undo/redo pattern).

- Query `workflowRollbackProposals(workflowName, storeScope, status, limit)`
- Mutation `checkWorkflowRegressionRollback(input: {workflowName, storeScope, targetSessionId})`
  → `{outcome, eligibilityCode, regressions, proposal}`
- Mutation `approveWorkflowRollbackProposal(input: {workflowName, storeScope, proposalId, reason, actorKind, actorId})`
- Mutation `rejectWorkflowRollbackProposal(input: {workflowName, storeScope, proposalId, reason, actorKind, actorId})`
- The §4.3 `workflowVersions`, `workflowVersionDiff`, `restoreWorkflowVersion`.

Error codes are upper-snake: `ROLLBACK_PROPOSAL_NOT_FOUND`,
`ROLLBACK_PROPOSAL_NOT_PENDING`, `ROLLBACK_SUPERSEDED`,
`ROLLBACK_IN_PROGRESS`, `ROLLBACK_FAILED` (with `failureCode`),
`DEFINITION_REASON_REQUIRED`, `DEFINITION_ROLLBACK_IN_PROGRESS`,
`DEFINITION_SYNC_PENDING`.

**SurfaceCatalog.** All rows use `workflowDefaults`, with both `cli` and
`graphql`:

| Row | CLI | GraphQL |
| --- | --- | --- |
| `workflow.definition.rollback.check` (mutation) | `workflow definition rollback check` | `checkWorkflowRegressionRollback` |
| `workflow.definition.rollback.list` (query) | `workflow definition rollback list` | `workflowRollbackProposals` |
| `workflow.definition.rollback.approve` (mutation) | `workflow definition rollback approve` | `approveWorkflowRollbackProposal` |
| `workflow.definition.rollback.reject` (mutation) | `workflow definition rollback reject` | `rejectWorkflowRollbackProposal` |
| `workflow.versions` (existing, gains GraphQL) | `workflow versions` | `workflowVersions` |
| `workflow.version` (existing, CLI path narrowed to `workflow version show`) | `workflow version show` | stays CLI-only |
| `workflow.version.diff` (new row) | `workflow version diff` | `workflowVersionDiff` |
| `workflow.restore` (existing, gains GraphQL) | `workflow restore` | `restoreWorkflowVersion` |

Rows called by the web screen (§7) set `desktop: .implemented`:
`workflow.definition.history|diff|restore|undo`, `rollback.list|approve|reject`.
Regenerate the SDL with `scripts/surface-parity/generate-sdl.sh`, and keep
`swift test --filter SurfaceParity` green. If a parity gate rejects the
`workflow.version` / `workflow.version.diff` split, bind `workflowVersionDiff`
to `workflow.version` instead. The plan records which form passed.

## 7. Web console: workflow history and rollback screen

- **Route.** A new `workflow-detail` tab `versions`:
  `#/workflows/{sourceId}/versions` and
  `#/workflows/{sourceId}/configurations/{configurationId}/versions`.
  `routes.ts` parse and build both, with tests. The tab resolves the
  workflow name from the source's definition (`workflowId`).
- **Code.** `web/src/workflows/history/historyClient.ts` holds the GraphQL
  operations, on the same `execute` transport as `console/client.ts`.
  `web/src/workflows/history/WorkflowVersionsView.tsx` is the view.
  Existing `ConfirmationDialog`, `ActionButton`, `ErrorBanner` and
  `LoadingState` are reused.
- **Version list.** It uses `workflowDefinitionHistory(limit: 50)` and shows
  one row per audit: operation, actor kind/id, reason, time, short version
  id, a head marker, `retained` and the bundle-snapshot evidence ids.
  Audit-only rows are marked as such.
- **Diff.** The user selects any two versions, or one version against the
  current head, and the view calls `workflowDefinitionDiff(fromVersionId,
  toVersionId)`. It renders one entry per `{path, op, before, after}`.
  String leaves render as preformatted before/after blocks.
- **Restore and undo.**
  - Restore uses `restoreWorkflowDefinition`; undo uses
    `undoWorkflowDefinition`.
  - The confirmation dialog shows the diff from the head to the target and
    requires a non-empty reason. It passes `expectedVersionId` = the head
    the user saw (CAS). A `DEFINITION_STALE*` error shows "history changed,
    reload".
  - The dialog states that this restores the service definition and leaves
    workflow files unchanged (#179 semantics). File restore is not on this
    screen.
- **Pending proposals.** `workflowRollbackProposals(status: pending)` lists
  the proposals. Each one shows the regressed and rollback-to versions,
  regressions, baseline and target sessions, and policy.
  - Approve opens a confirmation with the diff from the regressed version
    to the rollback target, and an optional reason.
  - Reject requires a reason.
  - The list refreshes after each action.
- **Unit tests** (`bun test src`) cover route parse/build and the client
  query/variable shapes.

## 8. Rollout constraints

- **Schema.** The runtime database goes from generation 12 to 13 with one
  additive table. Older binaries reject generation 13 through the existing
  newer-generation error. `discardIncompatibleStoreIfNeeded` still refuses
  stores that have definition heads. Memory schema and `Package.swift` are
  untouched. Bundle manifests stay schema 2 (§4.1).
- **Behavior change.** Registry, restore and self-improve edits now reach
  service runs (§3.6). Docs (README workflow-definition section,
  `docs/evolution-history.md` or equivalent CLI docs) must state it.
- **Test isolation.** Every test that constructs `WorkflowMutableRegistry`,
  runs `workflow restore` or `workflow self-improve`, or uses GraphQL
  registry mutations must inject a temporary definition store root (or set
  `RIELA_SESSION_STORE` to a temp dir). Existing tests that assert "zero
  `definition_*` rows" after a registry setup step must assert against their
  own store. The registry sync is not a run, so the #179 one-time-run
  zero-row rule still holds for `riela workflow run` itself.
- **Bounded storage (QA Q7, binding).**
  - One-time runs never write definition, audit or proposal rows. This
    covers `riela workflow run` with a named workflow,
    `--workflow-json` / temporary JSON targets, which resolve as `direct`
    bundles and never touch the registry (`WorkflowRunCommand.loadTemporaryWorkflowIfPresent`),
    and `loop start`.
  - Unchanged-digest changes create no version and at most one audit-only
    row per (head version, operation) (§3.3).
  - Terminal proposals are pruned with their versions (§5.6).
- **Defaults.** No automatic rollback happens without an explicit
  `automatic` policy in the rollback target's document. `restoreWorkflowVersion`
  is a dry run unless `apply: true`.
- `gitPush=false`: commit locally only.

## 9. Verification

Focused suites (names indicative; plans fix them):

- **`WorkflowDefinitionStoreTests` / migration.** Generation 12 → 13 creates
  `definition_rollback_proposals` with existing data intact. The
  `UNIQUE(workflow_name, regressed_version_id)` constraint holds. Pending
  proposals pin `rollback_to_version_id` against retention.
- **`WorkflowRegistryEvolutionTests` / registry sync.**
  - Create seeds (`registryWrite`, previous nil, `bundleSnapshotAfter`).
  - Update writes a version with before/after snapshot evidence, diff and
    actor, visible in `workflow definition history` and GraphQL
    `workflowDefinitionHistory`.
  - Identical replace and asset-only change → audit-only row.
  - Delete → `registryDelete` audit-only row; delete without head → no
    rows.
  - Store-only change then registry update → `overwritten_changes_json` and
    warning.
  - Injected sync failure leaves the transaction record. The next access
    rolls forward exactly once (the §3.3 change-completion predicate).
  - **First tracked registry update** of a pre-existing entry: a baseline
    `import` (`baselineTransaction:tx`) followed by a distinct
    `registryWrite` with `parent = baseline`. With an injected sync failure
    after publication, recovery still writes the `registryWrite`; the
    baseline alone does not count as completion.
  - The next service run pins the new head.
- **`WorkflowSelfImproveTests`.**
  - `--yes` apply writes one `selfImprove` version (mutable workflow: one
    row, not two) with `review`, `session` and `bundleSnapshotBefore`
    evidence.
  - Definition `restore` and `undo` of it work from CLI and GraphQL.
  - **First use** (a project/direct workflow with no head). The apply
    writes an `import` baseline B (evidence `baselineTransaction:tx`, no
    `fileTransaction`) equal to the pre-change file digest. It then writes a
    distinct `selfImprove` version I with `parent = B`, evidence
    `fileTransaction:tx`, and a head digest equal to the committed files.
    Exactly two rows exist, B then I. CLI and GraphQL `undo` return the head
    to B's digest.
    - **Baseline cannot suppress the change.** With B present and the sync
      failed after publication, the intent is still present. Replay writes I
      exactly once with its original attribution and then deletes the
      intent. A second replay is a no-op.
    - **Predicate negative test.** Calling the completion predicate with
      only B in the store returns false, for the sync, registry recovery and
      intent cleanup alike. A baseline-write failure leaves files
    and store unchanged (`definition_baseline_failed`). A retry after a
    file-change failure reuses the baseline. A concurrent service-run seed
    before the commit becomes the parent.
  - **Coordinator sync failure injection** at each point: before the
    database write, after the database commit but before intent deletion,
    and after the commit but before the `published` record.
    - Failure after file commit → `definition_sync_failed`, files
      committed, intent present.
    - The next self-improve or restore (F2) on the target first replays F1
      with its original document and `selfImprove` attribution exactly
      once, then records F2 with `parent = F1`.
    - A crash after the database commit → replay deletes the intent with
      no duplicate row.
    - A transaction that never committed → its intent is discarded.
    - A replay failure refuses F2 with `definition_sync_pending` and
      nothing changes.
    - `workflow definition import` replays pending intents first.
- **`WorkflowVersionCommandsTests`.**
  - `parentSnapshotId` chain; old manifests without the key still verify.
  - `--content` unified diff for text, binary, too-large and added/removed
    files; output without the flag is unchanged.
  - `workflow restore --yes --reason` writes `snapshotRestore`.
- **`WorkflowDefinitionGraphQLTests`.**
  - `workflowVersions`, `workflowVersionDiff(includeContent)`.
  - `restoreWorkflowVersion` dry-run default writes nothing; `apply: true`
    restores and syncs.
  - Proposal list, approve and reject; `actorKind: system` rejected; parity
    with the CLI results.
- **`LoopRegressionRollbackTests`** (fixed baseline and target sessions with
  loop evidence):
  - A regression on an improvement-node version → `pending`
    (approval-required). Approve → `rollback` version equal to the parent
    digest with an audit row (actor/reason/evidence); reject → `rejected`,
    no definition row.
  - `manual` → `recorded` only; approve is refused.
  - `automatic` (declared on the parent) → applied with actor `system`.
    Automatic declared only on the regressed version → treated as `manual`.
  - A rerun check → `existing`, with no second head move.
  - A regression measured on the rollback version → `notEligible
    notImprovementVersion`.
  - Head moved → `superseded`.
  - A `selfImprove` version → bundle-mode file restore plus a `rollback`
    version.
  - **First self-improvement of an untracked workflow.** A regression
    yields an approval-required or automatic proposal whose target is the
    baseline. The policy is read from the baseline document. Applying
    restores the baseline digest.
  - **Deterministic interleavings for bundle mode,** using hook seams
    between the claim, the restore and the sync:
    - a store-only `update` after the claim → `definition_rollback_in_progress`
      and the head stays `vT`;
    - head moved before the claim → `superseded`, files untouched;
    - reject before the claim → the claim fails, files untouched;
    - reject during `applying` → `rollback_in_progress`;
    - two concurrent approvals → exactly one `rollback` version and one
      restore;
    - a crash after the claim but before publication → recovery returns
      `pending`, files unchanged;
    - a crash after publication but before the sync → recovery replays with
      CAS `vT`, then `applied`;
    - a crash after the sync → recovery marks `applied` with no duplicate;
    - restore dirty conflicts → `failed`, head and files unchanged;
    - no lock-order deadlock between registry, coordinator and rollback
      paths (concurrent tasks complete under a timeout).
  - A file-origin target resolves by digest (explicit check).
  - The post-run hook creates the proposal for a service run and never
    changes the run outcome.
  - A one-time run with the same declaration leaves zero `definition_*`
    and proposal rows. This is the Q7 regression test: `riela workflow run
    <named>`, `riela workflow run --workflow-json '<inline>'` and `loop
    start` each leave `definition_heads`, `definition_versions`,
    `definition_change_audit` and `definition_rollback_proposals` at zero
    rows in the run's store.
  - **Proposal pruning.** A terminal proposal whose two versions fall out
    of the window is deleted by the next commit's retention, by `workflow
    definition prune` and `purge-history`, and by `riela gc` / automatic
    retention, and `proposalsDropped` is reported. A `pending` or
    `applying` proposal survives and keeps both of its versions.
  - **No-op collapse.** Five identical registry replaces on the same head
    create zero versions and exactly one `registryWrite` audit-only row.
    Replay of a collapsed no-op is complete via predicate (b).
  - `loop regress` output and exit codes are unchanged.
- **`SurfaceCatalog` / `SurfaceParity`** pass after SDL regeneration.
- **Web.** Route and client unit tests.

Commands:

- `arch -arm64 /bin/zsh -lc 'swift build && swift test --filter "WorkflowDefinition|WorkflowVersionCommands|WorkflowRegistryEvolution|SelfImprove|LoopBaseline|LoopRegression|SurfaceCatalog|SurfaceParity"'`
- `scripts/surface-parity/generate-sdl.sh` (the result must be committed, and
  the second run produces no diff)
- `cd web && bun run lint && bun run typecheck && bun test src && bun run build`
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <changed files>'`

## 10. Documents updated by this design

- `design-workflow-definition-store.md` §11: a pointer to §3.6 here
  (superseded for registry, restore and self-improve).
- `user-qa/qa-workflow-definition-store.md` Q1: a superseded note.
- `user-qa/qa-efficient-history-and-storage.md` Q2: a note that the snapshot
  store now gains the §4 changes.
- `design-evolution-history.md`: a pointer to §2/§4 (the snapshot store's
  role as auxiliary).

## 11. Plan mapping (serial; shared SwiftPM tree)

Suggested split for the implementation-plan step. Plans may merge
neighbours but keep this order:

1. Core model and schema: operations, evidence and actor kinds, the
   generation 13 migration (with `applying` and the claim columns), the
   proposal store API, the retention pin, and the `applying` head guard in
   every store head move.
2. Shared store-root resolution and the `WorkflowDefinitionChangeRecording`
   sync, including baseline capture (§3.2-§3.3).
3. Registry wiring: baseline capture before publication, `finish` sync,
   transaction-record attribution, recovery, delete (§3.4).
4. Coordinator wiring: the locked pre-publication callback, durable sync
   intents and replay, self-improve and `workflow restore` (§3.1, §3.4),
   plus the shared snapshot service.
5. B: `parentSnapshotId`, unified diff, the GraphQL file-restore surface.
6. C: shared pair resolution, evaluation, store-mode apply, the bundle-mode
   claim protocol and recovery, CLI `rollback`, the post-run hook.
7. GraphQL proposal surface, catalog rows, SDL regeneration.
8. Web screen.
9. Docs.
