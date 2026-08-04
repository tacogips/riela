# Design: Parent-scoped Riela Note folder identity

Status: revised for independent design review

Workflow mode: `issue-resolution`

Issue reference: no GitHub issue URL, repository, or issue number was supplied.
The authoritative issue title is "Allow duplicate Riela Note folder names under
different parents". Intake communication is `comm-000365`, sourced from
`comm-000364`; design feedback is recorded in `comm-000367` and `comm-000370`,
in `codex-design-and-implement-review-loop-session-43`.

Codex-agent references: none supplied. No Cursor CLI or Codex-agent adapter
behavior is involved.

Review mode: `adversarial`; risk level: `high`. Implementation review must reject
unresolved high- or mid-severity migration, ambiguity, or identity findings.

## Goal and boundary

Make `tag_id` the canonical identity of every tag while allowing two `folder`
tags to share a display name only when their parents differ. Folder creation,
assignment, removal, grouped filtering, and Kanban scope use IDs or an exact
`parentTagId` plus `name` lookup. Name-only access must never select an arbitrary
row.

This is one coupled schema-to-Web work package. It includes schema v7, Note
services, additive GraphQL and CLI contracts, Web folder/filter state,
path-qualified labels, the workflow-run notebook convention, and realistic
regressions. It does not redesign tag hierarchy, descendant semantics, Kanban
status models, progress values, authentication, or unrelated note search.

Primary implementation surfaces are:

- `Sources/RielaNote/NoteStoreSchema.swift`,
  `Sources/RielaNote/NoteDatabaseDriving.swift`, the local-connection boundary
  in `Sources/RielaNoteLibSQL/LibSQLNoteDatabaseDriver.swift`, and
  `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`;
- `Sources/RielaNote/NoteService.swift`,
  `Sources/RielaNote/NoteService+Catalog.swift`,
  `Sources/RielaNote/NoteService+Hydration.swift`,
  `Sources/RielaNote/NoteService+NotebookTags.swift`, and
  `Sources/RielaNote/NoteService+Kanban.swift`;
- `Sources/RielaGraphQL/GraphQLContracts.swift`,
  `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
  `Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
  `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`, and
  `Sources/RielaGraphQL/NoteGraphQLService.swift`;
- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift`,
  `Sources/RielaCLI/NoteCommands.swift`, and
  `Tests/RielaCLITests/NoteCommandTests.swift`;
- `web/src/notes/client.ts`, `web/src/notes/types.ts`,
  `web/src/notes/tree.ts`, `web/src/notes/controller.ts`,
  `web/src/views/NotesView.tsx`, and
  `web/src/components/NoteSearchPopup.tsx`; and
- `Sources/RielaApp/EntryPoint+Assistant.swift` and `README.md`, which currently
  tell private assistant runs to use a globally collision-safe date folder,
  plus convention coverage in `Tests/RielaAppSupportTests/` and realistic
  command coverage in `Tests/RielaCLITests/NoteCommandTests.swift`.

## Schema v7 and migration invariants

The `tags.name` table-level `UNIQUE` constraint is removed. `tag_id` remains the
only global tag identity and is never regenerated during migration.

Schema v7 enforces three disjoint uniqueness rules with partial unique indexes:

1. non-folder tags are unique by `name`, including tags whose `class_id` is
   `NULL`;
2. root folders are unique by `name` where `class_id = 'folder'` and
   `parent_tag_id IS NULL`; and
3. nested folders are unique by `(parent_tag_id, name)` where
   `class_id = 'folder'` and `parent_tag_id IS NOT NULL`.

The separate root-folder index is mandatory because SQLite treats `NULL` values
as distinct in ordinary compound unique indexes. A folder and a non-folder may
share a display name; name-only generic lookup is therefore potentially
ambiguous even when every individual index is valid.

Fresh databases create the v7 table and indexes directly in the normal
foreign-key-enabled prepare transaction and record versions 1 through 7. They
do not rebuild `tags`. Older stores first finish any pending v2 through v6 work
with foreign keys enabled, then run v7 through a dedicated connection-level
migration phase. This split is required because `PRAGMA foreign_keys` cannot be
changed inside the transaction currently owned by `NoteStoreSchema.prepare`.

The existing-store phase has one explicit sequence:

1. outside any transaction, require `PRAGMA foreign_keys = 1`, require an empty
   `PRAGMA foreign_key_check`, set `PRAGMA foreign_keys = OFF`, and verify that
   it became `0`;
2. begin one transaction, snapshot tag and assignment identities/counts, and
   create the v7 replacement table with the same columns, primary key,
   self-parent reference, and status-set reference but no inline name
   uniqueness;
3. copy every tag value unchanged, drop the old table, rename the replacement
   to `tags`, and create the three v7 partial unique indexes;
4. without rewriting `note_tags` or `notebook_tags`, compare all pre/post tag
   IDs and assignment identities/counts, run explicit parent/status/assignment
   orphan queries, and require an empty `PRAGMA foreign_key_check`;
5. commit the rebuilt schema only after every in-transaction check succeeds,
   but do not record version 7 while enforcement is disabled;
6. outside the transaction, restore `PRAGMA foreign_keys = ON`, verify it is
   `1`, and require a second empty `PRAGMA foreign_key_check`; and
7. in a final foreign-key-enabled transaction, revalidate the v7 table/index
   shape and integrity, then record version 7 before ordinary seeding or
   service work resumes.

The connection performs no unrelated write while foreign keys are disabled.
An error before rebuild commit rolls back, restores and verifies foreign keys,
and leaves version 7 unrecorded. An error after rebuild commit but before the
version marker leaves a valid, markerless v7 schema; the next prepare detects
the v7 table/index shape, skips the destructive rebuild, repeats enforcement
and integrity checks, and records version 7 only after they pass. A failure to
restore or verify foreign-key enforcement is fatal and quarantines the
connection from service use. This is an orchestration change in
`NoteStoreSchema.prepare`, not a rename-rebuild inside its current outer
transaction.

### Connection restoration and quarantine boundary

`NoteStoreSchema` owns the attempt to restore `PRAGMA foreign_keys = ON` and
verify enforcement and integrity on every migration exit. The
`NoteDatabaseDriving.withDatabase` lifecycle owns quarantine: whenever its body
throws, the cached-connection owner in
`Sources/RielaNote/NoteDatabaseDriving.swift` evicts and releases the exact
`SQLiteDatabase` handle used by that body rather than returning it to the
reusable connection slot. This general failure rule avoids a schema-specific
downcast or an optional quarantine callback. A later call may open a newly
configured handle, but it cannot reuse the failed handle. The normal cache path
is retained only when the body succeeds; schema prepare succeeds only after
foreign keys are enabled and the final integrity check completes.

The local mode of
`Sources/RielaNoteLibSQL/LibSQLNoteDatabaseDriver.swift` delegates to the same
`SQLiteNoteDatabaseConnection` and inherits this eviction contract. Embedded
replica mode remains unavailable and gains no separate migration path. The
driver protocol documents the same throw-invalidates-handle lifecycle for test
drivers; schema code does not downcast to a concrete driver.

Migration tests inject failures before commit, after rebuild commit, and during
restoration verification. They assert that version 7 remains unrecorded when
required, the failed handle is not reused, a subsequent newly opened handle has
`foreign_keys = 1`, and markerless-v7 recovery performs validation rather than
a second destructive rebuild. A restore failure therefore has two independent
safety outcomes: best-effort restoration on the current handle and mandatory
handle eviction even when restoration itself fails.

Schema v6 globally unique names guarantee the source data does not contain
duplicate names. Any unexpected constraint or integrity failure rolls back the
whole migration and leaves version 7 unrecorded.

## Service identity and lookup rules

All internal mutation and membership primitives accept `tagId`. Folder-path
creation resolves each component by `(parentTagId, name, classId = 'folder')`,
where a root component uses a `NULL` parent. It reuses the exact sibling or
creates it atomically; another same-named folder elsewhere is irrelevant.

Lookup outcomes are deterministic:

- ID lookup returns exactly one tag or `notFound`.
- Parent-plus-name folder lookup returns exactly one sibling or `notFound`.
- A duplicate sibling insert returns controlled `invalidInput`; it never
  updates or reparents the existing folder.
- Legacy non-folder name lookup excludes folders, then succeeds only for one
  row. Although the v7 index should guarantee that cardinality, the service
  still checks it and fails closed if storage is inconsistent.
- Legacy generic or folder name-only lookup succeeds only when the complete
  candidate set is singular. Zero candidates return `notFound`; multiple
  candidates return controlled `invalidInput` with no selected tag ID.

`LIMIT 1` is forbidden on name-only identity lookups. The shared
`requireTag(name:)` helper in
`Sources/RielaNote/NoteService+Hydration.swift` is split into purpose-specific
resolution boundaries: exact ID, exact parent-plus-name folder, unambiguous
non-folder name, and unambiguous generic name. Notebook-tag compatibility
adapters and legacy Kanban name fields use the generic resolver and therefore
reject multiple candidates; non-folder definition and note-tag compatibility
paths exclude folders before enforcing singularity. ID-based Kanban fields and
notebook mutations bypass name resolution. Hydration and display may sort
duplicate names, but ordering must include ancestry and `tag_id` so it is
stable.

Notebook assignment and removal have ID-first methods. Existing name-based
methods remain compatibility adapters and apply the rules above before calling
the same ID primitive. Protection and provenance checks are unchanged.

### Insert and conflict handling

No v7 statement may use `ON CONFLICT(name)`: a bare name is no longer a global
conflict target, and SQLite cannot match that target to the new partial indexes.
Conflict behavior is instead identity-specific:

- system and notebook-kind seeds use targetless `ON CONFLICT DO NOTHING`, then
  load and validate the expected stable `tag_id`, non-folder name, class, and
  system ownership; a no-op caused by another constraint never counts as a
  successful seed without that validation;
- `defineTag` determines its identity domain before lookup: a folder uses
  `(parentTagId, name, classId = 'folder')`, while a non-folder uses its globally
  unique non-folder `name`;
- `createOnly` rejects an existing exact sibling for folders or existing
  non-folder name for non-folders, without treating a same-named folder under
  another parent as a collision;
- an update targets the resolved `tag_id`; folder updates cannot reparent or
  reclassify a same-named row, while compatible non-folder updates retain their
  existing validated behavior; and
- a concurrent insert attempts the row once, translates a matching unique-index
  violation into controlled `invalidInput`, and re-queries only the same exact
  identity when idempotent reuse is allowed.

Folder-path creation follows the same insert-and-requery rule for each sibling.
It never falls back to a global-name row after a uniqueness conflict. Every
existing system seed, notebook-kind seed, catalog definition, and folder-path
statement in `Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaNote/NoteService+Hydration.swift`,
`Sources/RielaNote/NoteService+NotebookTags.swift`, and
`Sources/RielaNote/NoteService+Kanban.swift`, and
`Sources/RielaNote/NoteService.swift` is included in this audit. The audit
classifies every name-based caller before changing the shared helper; no caller
may inherit an arbitrary resolver by default.

Descendant expansion starts from tag IDs and follows `parent_tag_id`. Grouped
filter predicates compare `notebook_tags.tag_id`; names are not used after a
legacy request has been resolved. Kanban status-set inheritance and allowed
status calculation likewise walk the selected folder ID and its ancestors.

## Additive GraphQL and CLI contract

Existing name-based fields remain available for compatible, unambiguous calls.
The additive canonical surface is:

- `ApplyNotebookTagIdsInput { notebookId: String!, tagIds: [String!]!, provenance: String, assignedBy: String }`;
- `applyNotebookTagIds(input: ApplyNotebookTagIdsInput!): NoteMutationPayload!`;
- `removeNotebookTagById(notebookId: String!, tagId: String!, provenance: String): NoteMutationPayload!`;
- `notebooks(..., tagFilterIdGroups: [[String!]!]): NotebooksQueryPayload!`;
- `effectiveKanbanStatusesByTagId(tagId: String!): KanbanStatusSetQueryPayload!`; and
- `assignKanbanStatusSetByTagId(tagId: String!, setId: String): NoteMutationPayload!`.

Empty inner ID groups are discarded. An omitted input, or one with no remaining
group, preserves the existing name-filter path. At least one remaining ID group
takes precedence over `tagFilterGroups` and legacy flat `tagFilter`. Each ID
group is a union after descendant expansion; groups intersect. Unknown IDs in
any non-empty group fail closed to an empty result. Existing 64-group,
256-input, and 900-expanded-tag limits apply before query construction.
Malformed nested variables use the existing GraphQL invalid-variable response
and must not become an unfiltered request.

Duplicate IDs and equivalent groups are canonicalized without changing logical
membership. The document executor validates shape, the GraphQL service forwards
typed IDs, and `NoteService` owns precedence, bounds, expansion, and predicates.

The GraphQL data flow has one explicit module boundary. Shared input and payload
types are declared in
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`; the root `Query` and
`Mutation` fields are declared in `Sources/RielaGraphQL/GraphQLContracts.swift`;
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` validates nested ID
variables and dispatches only validated values;
`Sources/RielaGraphQL/NoteGraphQLService.swift` translates those values into the
ID-first `NoteService` methods; and `NoteService` owns lookup, precedence,
descendant expansion, and mutation rules. Both SDL layers, the document parser's
supported-field tables, typed DTOs in
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`, and service dispatch must be
updated together. A field present in only one SDL layer is incomplete and must
fail review.

The CLI's existing name options retain compatibility behavior. Its shared
GraphQL documents include the new fields where used by realistic scenarios;
new ID-specific CLI flags are not required by this issue. CLI regression tests
must exercise duplicate folder names through actual command/document execution,
not only direct service calls.

## Web state, mutations, and labels

Web catalog, tree, filter-chip, selection, and Board scope state retain
`tagId` as identity. A filter constraint sends `[tagId]` through
`tagFilterIdGroups`; folder assignment and removal send the selected `tagId`.
Refresh reconciliation matches by ID and may update names or ancestry without
silently changing the selected tag.

Every folder selection or search surface displays a derived ancestor path,
rendered as `Parent / Child / Leaf`. The segments are derived from the current
catalog by following `parentTagId`, with a visited-ID cycle guard and the
existing hierarchy depth bound. The plain `name` remains available for compact
local labels, but any picker, search result, filter chip, breadcrumb, or
same-name disambiguation surface uses the qualified path. Accessibility labels
include the same path. `web/src/notes/tree.ts` provides one ID-based path-label
helper; `web/src/views/NotesView.tsx` uses it for trees, pickers, chips, and
Kanban selectors and passes the catalog or resolver into
`web/src/components/NoteSearchPopup.tsx` for matched-folder labels. Missing or
cyclic ancestry renders a visibly incomplete path keyed by ID rather than a
fabricated branch or an arbitrary same-named ancestor.

Duplicate names do not change race protections: stale catalog, membership,
filter, or Kanban completions remain generation-guarded. Error messages may
show a path, but actions and reconciliation always retain the ID captured when
the operation began.

Folder creation replaces the current global `folderNameCollision` preflight
with a sibling-only check over folder tags whose normalized `parentTagId` and
name match the requested parent and name. A same-named folder under another
parent, or a same-named non-folder, does not block the request. The server's v7
constraint remains authoritative: a concurrent duplicate sibling produces a
controlled error, refreshes the catalog, and does not select or reparent either
row. `web/src/notes/tree.ts` owns the pure sibling-collision helper and
`web/src/views/NotesView.tsx` supplies the selected parent ID and renders the
qualified result path.

## Workflow-run notebook convention

A private assistant workflow run writes its history notebook under folder
components `[<workflow-id>, history-YYYY-MM-DD]`. The RielaApp instruction in
`Sources/RielaApp/EntryPoint+Assistant.swift` and its user-facing `README.md`
contract replace the current globally collision-safe date-child guidance. For
example, `build-release/history-2026-08-03` and
`deploy-production/history-2026-08-03` intentionally share the child display
name under different workflow parents.

This convention must call parent-scoped folder creation rather than precompose a
globally unique child name. Repeated runs for one workflow and date reuse the
same leaf; runs for another workflow receive a distinct leaf ID.

## Rollout, review, and verification

Rollout order is schema and lookup primitives, service ID APIs, GraphQL/CLI,
Web adoption, then workflow convention. The Web must not send ID operations
until the server schema supports them. No dual-write or tag-ID translation is
permitted.

Adversarial review must inspect table-rebuild rollback, root `NULL` uniqueness,
cross-class same-name ambiguity, every legacy `LIMIT 1` lookup, descendant and
Kanban ID propagation, stale Web state, and realistic migration preservation.
No high- or mid-severity finding may remain unresolved.

Required verification commands are:

```bash
swift build
swift test --filter NoteStoreSchemaTests
swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests'
swift test --filter 'NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'
swift test --filter NoteCommandTests
cd web && bun test src
cd web && ./node_modules/.bin/tsc --noEmit
cd web && bun run lint
cd web && bun run build
cd web && bun run test:e2e
git diff --check
```

Migration tests cover v6-to-v7 preservation, rollback before swap commit,
foreign-key restoration on success and failure, markerless-v7 recovery after a
simulated post-commit interruption, and fresh-v7 creation without rebuild.
Service, GraphQL, and CLI tests cover duplicate children under different
parents, duplicate siblings, root duplicates, folder/non-folder collisions,
exact ID assignment/removal, ambiguous legacy failures, grouped descendant
filtering, and Kanban scope. Web tests cover ID payloads, parent-scoped creation
preflight, catalog reconciliation, path-qualified picker and search labels,
duplicate names in different branches, and stale completion rejection.

## Accepted decisions and open questions

Accepted decisions are: `tag_id` is canonical; folder uniqueness is parent plus
name; duplicate siblings are rejected; legacy non-folder lookup is preserved
only when unambiguous; path-qualified display includes all ancestors; and this
remains one issue-resolution package.

Open user questions: none. Exact implementation helpers may vary, but they may
not weaken the identity, migration, validation, or compatibility contracts.

## Self-review corrections

The rerun following `comm-000367` resolves all author-review findings:

- the high migration finding is closed by the connection-level foreign-key
  disable/rebuild/restore sequence, including rollback and double integrity
  verification;
- the mid conflict-target finding is closed by removing `ON CONFLICT(name)` and
  defining targetless validated seeding plus exact-identity catalog writes; and
- the mid Web finding is closed by parent-scoped sibling validation with the
  database remaining authoritative.

The rerun following independent design review `comm-000370` also closes every
reported finding:

- failed migration handles are now evicted by the cached-connection owner, with
  the local LibSQL boundary and failure-injection verification explicit;
- the shared `NoteService+Hydration.swift` name resolver and each generic,
  non-folder, folder, and ID caller category are included in the service audit;
- `GraphQLContracts.swift` is included as the root SDL owner and the complete
  SDL-to-parser-to-service data flow is specified; and
- the parsing regression verification filter now names the executable XCTest
  class `NoteGraphQLParsingRegressionTests`.
