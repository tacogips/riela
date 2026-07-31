# Riela Note Configurable Kanban Status Sets and Autonomous Task Orchestration

- Status: Draft (pre self-review)
- Date: 2026-07-31
- Branch: `feat/riela-note-kanban-orchestration`
- Related designs: `design-riela-note.md`, `design-bounded-fanout-join-workflow-execution.md`,
  `design-workflow-json.md`, `design-riela-note-graph-rag.md`

## Purpose

Riela should accept one high-level task, decompose it into concrete subtasks
with a multi-agent workflow, create those subtasks autonomously as kanban cards
in Riela Note, execute them in parallel, route each finished card through a
review status, and converge to done — all observable on the existing kanban
surfaces (web `NotesView`, native `RielaNoteUI`).

Two capability gaps block this today:

1. Kanban statuses are a closed four-value enum (`none`, `progress`, `done`,
   `pending`) hard-coded in schema CHECK constraints, Swift, GraphQL, CLI, and
   web. There is no `review` status and no way to add one, let alone scope a
   status set to one folder tag.
2. No deterministic workflow seam exists for "create a set of kanban task
   notebooks", "move a card with conflict detection", or "read a board"; only
   generic note add-ons and free-form `riela/note-graphql-document` exist.

This design closes both gaps: **Part A** makes kanban status sets configurable
and scopeable per folder tag; **Part B** adds kanban-orchestration add-ons and
an example multi-agent workflow (`note-kanban-orchestrate`) that runs the full
decompose → create cards → parallel execute → review → done loop.

## Code-verified baseline

- `Sources/RielaNote/NoteModels.swift:31` — `NotebookProgress` is a closed
  `String`-raw enum: `none`, `progress`, `done`, `pending`.
- `Sources/RielaNote/NoteStoreSchema.swift:9` — `currentVersion = 4`;
  `notebooks.progress TEXT NOT NULL DEFAULT 'none' CHECK (progress IN
  ('none','progress','done','pending'))` both in the fresh schema
  (`NoteStoreSchema.swift:338`) and the v4 `ALTER TABLE` migration
  (`NoteStoreSchema.swift:214`). SQLite cannot drop a CHECK constraint without a
  table rebuild; the rename→create→copy→drop rebuild pattern is already
  established by `migrateToV3` (`NoteStoreSchema.swift:175`).
- `Sources/RielaNote/NoteStoreSchema.swift:372` — `tags` has `class_id`
  (`tag_classes`), self-FK `parent_tag_id`, and system `folder` class;
  hierarchical expansion via `NoteTagHierarchy.expandedTagFilterNames`
  (recursive CTE). Notebook↔tag is `notebook_tags` many-to-many
  (`NoteStoreSchema.swift:393`).
- `Sources/RielaNote/NoteService.swift:548` — `setNotebookProgress(notebookId:
  progress: NotebookProgress)`; hydration parses the raw column through the
  closed enum (`NoteService+Hydration.swift:79`).
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift:12` — GraphQL exposes
  `enum NotebookProgress { none progress done pending }` and
  `Notebook.progress: NotebookProgress!`;
  `setNotebookProgress(notebookId: String!, progress: NotebookProgress!)`
  (`GraphQLContracts.swift:1090`), executor dispatch at
  `NoteGraphQLDocumentExecutor.swift:285`, service-side closed-enum validation
  at `NoteGraphQLService.swift:271`.
- CLI consumers: `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift` selects
  `progress` in notebook documents; the note add-on serializers in
  `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` emit notebook JSON.
  Lesson from PR #62: any Note GraphQL schema change must update every
  consumer's field selection and `RielaCLITests` must be in the gate.
- Web consumers: `web/src/notes/client.ts:239` hard-codes
  `['none','progress','done','pending']`; kanban columns and drag/drop logic in
  `web/src/notes/controller.ts` and `web/src/views/NotesView.tsx`. Native
  kanban in `Sources/RielaNoteUI` (`RielaNoteLibraryViewModel+Kanban`).
- Workflow runtime: bounded fan-out/join is implemented
  (`Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`);
  `writeOwnership` is optional and absent means no path-ownership restriction
  (`DeterministicWorkflowRunner+Fanout.swift:282`), so parallel branches may
  each write to the shared note store through add-ons. Review-loop authoring
  patterns (manager step, `promptVariant: self-review`, `sessionPolicy`
  reuse, labeled transitions, `defaults.maxLoopIterations`, fan-out with
  `joinStepId`) are established by
  `examples/design-and-implement-review-loop/workflow.json`.
- Note add-ons already exposed to workflow nodes
  (`ProductionNodeAdapter+NoteAddons.swift:11`): `riela/note-create`,
  `note-update`, `note-get`, `note-search`, `note-graph-neighbors`,
  `note-tag-apply`, `note-attach-file`, `note-graphql-document`,
  `note-comment-add`, `notebook-ingest-pages`, `note-conversation-save`.

## Scope and boundaries

### In scope

- Schema v5: new un-CHECKed `notebooks.status` column superseding the dead
  legacy `progress` column (no table rebuild — see A1); new
  `kanban_status_sets` and `kanban_statuses` tables; `tags.status_set_id`
  binding column; seeded immutable system default set that now includes
  `review`.
- `NoteService` status-set CRUD, effective-set resolution (folder tag →
  ancestor fallback → system default), validated + optionally compare-and-set
  `setNotebookProgress`.
- GraphQL: `Notebook.progress` becomes `String!`; new `KanbanStatusCategory`
  enum, status-set types/queries/mutations; every existing consumer updated
  (CLI documents/serializers, add-on serializers, web client, native UI).
- Web kanban renders columns from the effective status set instead of the
  hard-coded four; native `RielaNoteUI` receives only the minimal
  compile-level adaptation to the string status model (user decision
  2026-07-31: UI feature work is web-only).
- Web read-only board mode: board loads locked (no drag/drop, no status
  selects) with an explicit unlock toggle to enable writes.
- Realtime board sync for the web kanban via a same-origin SSE change feed
  (WebSocket considered; SSE chosen — see A7).
- Three deterministic kanban add-ons: `riela/note-kanban-task-create`,
  `riela/note-kanban-move`, `riela/note-kanban-board`.
- **A scoped RielaCore fan-out extension**: new `failurePolicy:
  "collect-partial"` — waits for all branches like `collect-all`, but always
  appends the join message with per-branch outcome records (success or
  failure + reason) and never fails the dispatch. Required because
  `collect-all` throws before the join when any branch failed
  (`DeterministicWorkflowRunner+Fanout.swift:47-53`; adversarial review F1),
  so one agent timeout would strand the whole board and the failed session
  is not resumable.
- Example workflow `examples/note-kanban-orchestrate` implementing the
  autonomous decompose → create → parallel execute → review-loop → done flow,
  with mock scenario, `EXPECTED_RESULTS.md`, and example-registry
  registration.

### Out of scope

- Native (`RielaNoteUI`) dynamic custom-set columns, read-only mode, and
  realtime sync — native keeps its current tag-scoped board rendering the
  system default set through the category mapping; only compile-level
  adaptation to the string status model is in scope there.
- Per-status WIP limits, swimlanes, or user-configurable colors beyond the
  category palette.
- Changing note-level (as opposed to notebook-level) task modeling; a kanban
  card remains a notebook.
- Cross-machine/libsql sync of status sets (inherits the existing baseline
  deferral in `impl-plans/active/riela-note.md`).
- Replacing `riela/note-graphql-document`; it remains the escape hatch.
- A dedicated daemon/event-source trigger for orchestration; the example
  workflow runs through the normal `riela workflow run` / GraphQL control
  plane. Event-source binding is a follow-up.

## Part A — Configurable kanban status sets

### A1. Data model (schema v5)

```sql
CREATE TABLE IF NOT EXISTS kanban_status_sets (
  set_id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS kanban_statuses (
  status_id TEXT PRIMARY KEY,
  set_id TEXT NOT NULL REFERENCES kanban_status_sets(set_id),
  name TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('none','pending','progress','review','done')),
  position INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (set_id, name),
  UNIQUE (set_id, position)
);
```

- `tags` gains `status_set_id TEXT REFERENCES kanban_status_sets(set_id)`
  (additive `ALTER TABLE`, nullable). Binding is only meaningful — and only
  accepted by the service/GraphQL layer — for tags whose class is `folder`.
- **The `notebooks` table is NOT rebuilt.** (Adversarial review 2026-07-31,
  HIGH-1/HIGH-2: a rename→copy→drop rebuild is unimplementable here —
  `notebooks` has three incoming FKs (`notes`, `notebook_tags`,
  `notebook_files`), the store opens with `PRAGMA foreign_keys=ON`, ALTER
  RENAME rewrites child FK targets, and `foreign_keys=OFF` is a no-op inside
  the single schema transaction; additionally no probe usable in the
  fresh-install flow can guard a rebuild.) Instead, v5 **adds a new column
  and abandons the old one**:
  - migration: `ALTER TABLE notebooks ADD COLUMN status TEXT NOT NULL
    DEFAULT 'none'` (no CHECK) + `UPDATE notebooks SET status = progress` —
    guarded by `columnExists("status", in: "notebooks")`, which is exactly
    the working v4 guard shape: true on fresh installs (schema statements
    already created the final shape earlier in the same transaction → no-op)
    and false on genuine v4→v5 upgrades.
  - fresh schema: `notebooks` has only `status TEXT NOT NULL DEFAULT 'none'`
    (no `progress` column, no CHECK).
  - the legacy `progress` column (with its CHECK) remains **dead** on
    migrated stores: no code reads or writes it again; every INSERT names
    its columns and omits it, so its `DEFAULT 'none'` always satisfies the
    old CHECK. This column-set divergence between fresh and migrated stores
    extends the already-accepted v4 invariant (named-column reads via
    `SQLiteRow` dictionaries only, no `SELECT *` positional access).
  - all RielaNote SQL that touched the `progress` column switches to
    `status`; the Swift/GraphQL surface keeps the `progress` field name.
  Validation moves to the write path (A3). Existing values are preserved
  verbatim; no data rewrite, no FK hazard.
- Seeded system default set (`is_system = 1`, `set_id = 'kanban-default'`,
  name `default`), statuses in position order:

  | position | name | category |
  |---|---|---|
  | 0 | `none` | `none` |
  | 1 | `pending` | `pending` |
  | 2 | `progress` | `progress` |
  | 3 | `review` | `review` |
  | 4 | `done` | `done` |

  The system set is immutable (mutations rejected), which keeps a
  deterministic baseline for every consumer and gives every store a `review`
  column out of the box. Seeding follows the idempotent `ON CONFLICT DO
  NOTHING` pattern used by `seedTagClasses`.
- `NoteStoreSchema.currentVersion` becomes `5`; `migrateToV5` is idempotent
  (guarded by `columnExists` / table-exists probes) exactly like `migrateToV4`.
  Fresh-install schema statements create the final shape directly. The v3/v4
  caveat about ALTER column position remains satisfied: all reads are by named
  column through `SQLiteRow` dictionaries.

`category` is the closed semantic vocabulary. It exists so that:

- automation (Part B) can reason about "cards in a review-category status"
  regardless of custom names;
- UI can map any custom status to a stable palette and rollup semantics;
- typed notebook progress rollups keep working when names are user-defined.

Custom statuses are user-named (`design-review`, `qa`, …) and each maps to
exactly one category.

### A2. Swift model

- `NotebookProgress` (closed enum) is **removed** and replaced by:

  ```swift
  public enum KanbanStatusCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case none, pending, progress, review, done
  }

  public struct KanbanStatus: Equatable, Sendable {
    public var statusId: String
    public var setId: String
    public var name: String
    public var category: KanbanStatusCategory
    public var position: Int
  }

  public struct KanbanStatusSet: Equatable, Sendable {
    public var setId: String
    public var name: String
    public var isSystem: Bool
    public var statuses: [KanbanStatus]  // position order
  }
  ```

- `Notebook.progress` becomes `String` (the status **name**). This is a
  deliberate no-backward-compat change consistent with repo policy; every
  call site that pattern-matched on the enum is updated in the same change.
  Hydration (`NoteService+Hydration.swift:79`) stops parsing through the enum
  and passes the raw name through.

### A3. NoteService API

New/changed public API on `NoteService` (all transactional, all bump
`updated_at` where they mutate):

- `listKanbanStatusSets() -> [KanbanStatusSet]`
- `createKanbanStatusSet(name:statuses:[(name, category)]) -> KanbanStatusSet`
  (positions assigned from array order; **statuses must be non-empty** — this
  guarantees every set has a first column for fallback grouping)
- `updateKanbanStatusSet(setId:statuses:)` — full replace of the ordered,
  non-empty status list; rejected for the system set. Each submitted entry
  may carry the existing `statusId`:
  - same `statusId`, new `name` = **rename**: in the same transaction, cards
    are migrated — `UPDATE notebooks SET status = :new WHERE status = :old`
    restricted to notebooks holding the old name whose folder tags resolve
    (own binding or ancestor fallback, one recursive CTE) to this set.
  - an omitted `statusId` (deletion) is rejected while any such in-scope
    notebook still holds the name, unless the entry-removal request names a
    `reassignTo` status in the new list, in which case those cards are
    updated to `reassignTo` in the same transaction.
- `deleteKanbanStatusSet(setId:)` — rejected for the system set and while any
  tag binds it. **Documented consequence**: the legal sequence
  unbind-tag→delete-set can leave cards holding names no longer defined
  anywhere; such cards stay visible via fallback grouping (below), but the
  orphaned name is no longer writable (validation rejects it). This is
  accepted behavior, not an error state.
- `assignKanbanStatusSet(tagName:setId:?)` — binds/unbinds (`nil`) a set on a
  `folder`-class tag; rejects non-folder tags.
- `effectiveKanbanStatuses(tagName: String?) -> KanbanStatusSet` — resolution
  order: the tag's own `status_set_id`; else walk `parent_tag_id` ancestors
  nearest-first; else the system default set. `nil` tag → system default.
- `setNotebookProgress(notebookId:progress:String, expectedProgress:String?)`
  — validates `progress` against the notebook's **allowed statuses**: the
  union of the system default set and the effective sets of every
  folder-class tag assigned to the notebook. Unknown name →
  `invalid_request`-style error listing the allowed names. When
  `expectedProgress` is non-nil and differs from the stored value the call
  fails with a typed conflict error and performs no write (compare-and-set for
  concurrent branches).

**Scoping ceiling (intentional, explicit)**: because the allowed union always
includes the immutable system default set, every notebook accepts
`none`/`pending`/`progress`/`review`/`done` regardless of folder binding. A
custom set therefore *extends* the vocabulary for its folder; it does not
*restrict* cards to itself. This keeps historical data writable and agents'
default lifecycle universally valid; a strict/restrictive binding mode is out
of scope.

Board grouping rule (shared by web, native UI, and the board add-on): for a
scope tag `T`, columns are `effectiveKanbanStatuses(T)` in position order. A
notebook whose stored `progress` name is not a column of `T`'s set is placed
deterministically:

1. Resolve the name's category: if the system default set defines the name,
   use that category; else if any set in the notebook's allowed union defines
   it, use the category from the defining set with the lexicographically
   smallest `set_id` (deterministic tiebreak — cross-set name collisions with
   divergent categories are legal, `UNIQUE` is per-set only); else the name
   is orphaned → category `none`.
2. Place the card in `T`'s first column (position order) with that category;
   if `T`'s set has no column of that category, fall back to `T`'s first
   `none`-category column; if none exists, **`T`'s first column** (guaranteed
   to exist because sets are non-empty).

Cards are never dropped. Implementation note: resolution is batched — one
recursive CTE resolves tag→bound-set (own → single-parent ancestor chain) for
all distinct folder tags in the result page, and unions are computed from
prefetched maps; no per-notebook queries in the board path.

### A4. GraphQL surface

Schema changes (`GraphQLNoteSchemaContract.swift`, `GraphQLContracts.swift`):

- `enum NotebookProgress` → **removed**; add
  `enum KanbanStatusCategory { none pending progress review done }`.
- `type Notebook { …, progress: String!, … }`.
- New types:

  ```graphql
  type KanbanStatus { statusId: String!, name: String!, category: KanbanStatusCategory!, position: Int! }
  type KanbanStatusSet { setId: String!, name: String!, isSystem: Boolean!, statuses: [KanbanStatus!]! }
  ```

- Queries: `kanbanStatusSets: [KanbanStatusSet!]!`,
  `effectiveKanbanStatuses(tagName: String): KanbanStatusSet!`.
- Mutations: `createKanbanStatusSet(name: String!, statuses:
  [KanbanStatusInput!]!)`, `updateKanbanStatusSet(setId: String!, statuses:
  [KanbanStatusInput!]!)`, `deleteKanbanStatusSet(setId: String!)`,
  `assignKanbanStatusSet(tagName: String!, setId: String)`,
  `setNotebookProgress(notebookId: String!, progress: String!,
  expectedProgress: String)`.
- Executor (`NoteGraphQLDocumentExecutor`) gains the new operations; service
  validation moves from closed-enum parsing to the A3 allowed-status check.

Consumer updates in the same change (the PR #62 lesson, mandatory). Complete
inventory (survey-verified):

- GraphQL layer itself: SDL string literals
  (`GraphQLNoteSchemaContract.swift:12-13`, `GraphQLContracts.swift:1090`),
  the typed Codable DTO `GraphQLNotebookDTO.progress`
  (`NoteGraphQLContracts.swift:58`) — **this DTO is the decode path for CLI
  note commands** (`NoteCommands.swift:356,375`), so it must become `String`
  or every CLI note command throws on a custom status name — resolver enum
  decode (`NoteGraphQLService.swift:271`), and the **field allowlists** that
  gate selections — `supportedNoteGraphQLFields`
  (`NoteGraphQLDocumentExecutor.swift:513-548`, mirror comment `:975`) and
  the `Notebook` field map (`:751-761`) must register every new root field
  and type field.
- **Conflict error contract**: `setNotebookProgress` failures are
  machine-distinguishable — a CAS mismatch surfaces a distinct error code
  (`progress-conflict`) from name-validation failure (`invalid_request`) in
  the mutation payload/diagnostics, on GraphQL and in the add-on output
  alike; the web client branches on it (conflict → refresh/adopt path,
  validation failure → surfaced error).
- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift:19` — shared notebook
  selection set (progress stays selected; now a plain string). CLI currently
  has no progress read/write command; a `note notebook set-progress`-style
  surface is optional scope, not required.
- Add-on serializer `ProductionNodeAdapter+NoteAddons.swift:879`
  (`notebook.progress.rawValue` → plain string).
- `Sources/RielaNoteUI` bypasses GraphQL and calls `NoteService` directly:
  `RielaNoteUIClient` protocol + default + impl
  (`RielaNoteUIClient.swift:131,237,619-624`) change signature to the string
  status; both `NotebookProgress.allCases` sites — kanban sections
  (`RielaNoteTagKanbanSections.swift:10`) and context-menu move targets
  (`:53`) — iterate the system default set (native stays default-set-only
  per the web-only scope decision); grouping
  (`RielaNoteLibraryViewModel+Kanban.swift:24-26`), the mutation-target map
  (`RielaNoteLibraryViewModel.swift:124`, `[String: NotebookProgress]` →
  `[String: String]`), and the exhaustive label/SF-symbol `switch`es (used
  by the list view too, `RielaNoteNotebookListView.swift:257-258,287-311`)
  map through `KanbanStatusCategory` — labels/symbols are **category-keyed**
  (a status name renders its category's label/symbol), which is total over
  arbitrary names. Compiler surfaces all sites once the enum is removed.
  **Native CAS stance (review finding B1)**: native does NOT adopt
  `expectedProgress` — it passes `nil` and keeps its generation-gated
  newer-wins protocol unchanged, so `RielaNoteKanbanRaceTests` semantics are
  untouched.
- Web: TS union `web/src/notes/types.ts:1` (+ `progressWasUnknown` `:37-38`),
  runtime allowlist `web/src/notes/client.ts:238-244`, the mutation document
  that bakes the GraphQL enum type name into the query string
  (`client.ts:158`, `$progress: NotebookProgress!` → `String!`, plus
  `expectedProgress`), column order/labels (`NotesView.tsx:50-56`), board
  render/drop/select paths (`NotesView.tsx:673-696`) **and the two
  non-kanban progress editors** — list-view row select (`:695` context) and
  detail-pane select (`:707`) — which must also render the effective set,
  controller desired-map typing (`controller.ts:161-255`), and **CSS**:
  `web/src/styles.css:142` hardcodes `repeat(4, …)` board columns and
  name-keyed pill colors (`:140`) — becomes a dynamic column count with a
  category-keyed palette.
  **Raw-name preservation rule (review finding G2)**: the client must stop
  coercing unknown progress values to `'none'` (`client.ts:238-244`) — the
  stored status name is preserved verbatim on the client object and used for
  `expectedProgress`; category grouping is display-only. Otherwise every
  drag of a custom-status card would send `expectedProgress: 'none'` against
  the server's real name and spin in a spurious CAS-conflict loop. The
  `progressWasUnknown` flag and its "Unknown status" banner are removed
  (replaced by fallback-column grouping).
- Web e2e: `web/e2e/dashboard.spec.ts:538,598,602,721` assert
  `.board-column` count `=== 4` — updated to the default-set count (5) or a
  set-driven expectation.
- GraphQL SDL golden tests assert exact arg lists and the root-field set
  (`Tests/RielaGraphQLTests/NoteGraphQLTests.swift:770-858`, invalid-enum
  rejection in `NoteGraphQLHierarchyProgressTests.swift:150-167` becomes an
  invalid-name rejection against the allowed union). Test **documents** that
  declare the enum type in their query text
  (`NoteGraphQLHierarchyProgressTests.swift:82,126,150`, `$progress:
  NotebookProgress!`) fail SDL validation once the enum is removed and must
  switch to `String!` — same class of change as `client.ts:158`.
  `NoteHierarchyProgressTests.swift:454` iterates `allCases` and moves to
  the category enum or default-set names.
- Migration tests: `Tests/RielaNoteTests/NoteHierarchyProgressTests.swift:30-109`
  currently ends by asserting the DB CHECK rejects `progress = 'invalid'`
  (`:100-106`) — that assertion moves to the service write path (validation
  now lives there, not in the schema).
- `RielaCLITests` (NoteCommandTests + NoteAddonTests), `RielaGraphQLTests`,
  `RielaNoteTests`, `RielaNoteUITests` (Kanban + 11 race tests +
  `RielaNoteUIClientCatalogTests`), `RielaAppSupportTests`
  RielaAppNotesIntegrationTests, and web vitest + e2e suites are all in the
  verification gate.

### A5. Web and native UI behavior

- Web board columns render from the scope tag's effective set (position
  order, category palette). No scope tag selected → system default set.
- Drag/drop between columns issues `setNotebookProgress` with the target
  status **name** and `expectedProgress` = the value the client last saw; a
  conflict response triggers the existing refresh/adopt path
  (`web/src/notes/controller.ts` newer-wins contract preserved).
- Status-set management UI (create/edit sets, bind to folder) is **included
  minimally on web** (a settings pane under the Tags tab).
- Native (`RielaNoteUI`) keeps its current board: sections still cover the
  system default statuses (now including `review`) via the category mapping;
  the exhaustive-enum switches become category-keyed. No custom-set columns,
  no lock mode, no realtime — web-only per user decision.

### A6. Read-only board mode (web)

The board is an observation surface for autonomous runs, so it must be safe
to watch without touching:

- The kanban view loads **locked**: drag/drop disabled, per-card and detail
  status `<select>`s disabled, visually indicated by a lock control in the
  board header.
- An explicit unlock toggle switches the board to writable; the choice
  persists per browser (`localStorage`, keyed per scope tag) so a board a
  user unlocked stays unlocked for them, and re-locking is one click.
- This is a client-side UI guard, not a server permission: the `/graphql`
  note API remains write-capable for agents and unlocked clients alike.
  Server-enforced roles are out of scope.

### A7. Realtime board sync (web)

Requirement: card moves made by orchestration agents (or another browser)
appear on the board without manual refresh. Transport decision: **SSE
(`text/event-stream`)** over the existing same-origin HTTP server rather
than WebSocket — the serving stack is a custom Swift HTTP server with no
WebSocket upgrade support today, SSE needs only a long-lived chunked
response, auto-reconnect (`Last-Event-ID`) is built into `EventSource`, and
the flow is strictly server→client (writes keep using GraphQL). WebSocket
remains a possible later upgrade behind the same event contract.

Design:

- **Change feed, not state push.** `NoteService` mutations that affect the
  board (`setNotebookProgress`, notebook create/delete, notebook tag
  apply/remove, status-set mutations) publish a monotonic-revision change
  event `{ revision, kind, notebookId?, tagNames? }` to an in-process
  broadcaster actor owned by the serving layer.
- **Endpoint**: `GET /note/events` (SSE) beside `/graphql`, same-origin,
  same host/auth gating as the existing note API (bearer where the SPA uses
  bearer, host/CSRF gate in-app). Emits `event: note-change` frames plus
  keep-alive comments.
- **Client**: `EventSource` subscription; an incoming event whose scope
  intersects the current board (tag names or unknown scope) schedules a
  debounced `refresh()` through the existing generation-guarded path — the
  refresh remains the single source of truth, so missed events can never
  corrupt state. On (re)connect the client refreshes once unconditionally,
  which makes gap handling trivial (no server-side event replay buffer
  required; `Last-Event-ID` is accepted but only used to skip the initial
  refresh when nothing changed).
- **Fallback**: if the SSE connection cannot be established (proxy
  buffering, etc.) the client degrades to the current manual/interval
  refresh behavior; realtime is progressive enhancement.
- The optimistic-write controller keeps precedence: self-initiated changes
  arriving back through the feed are deduped by the existing
  `isCurrentNotebookProgressMutation`/desired-map convergence logic.

## Part B — Autonomous kanban orchestration

### B1. New deterministic add-ons

All three live beside the existing note add-ons in
`ProductionNodeAdapter+NoteAddons.swift` (same config/validation/serialization
conventions, same `noteRoot` config key with its established resolution chain
config → `workflowInput.noteRoot` → `RIELA_NOTE_ROOT` → `~/.riela/note`,
version `"1"`). Registration touches **both** registries: the runtime
dispatch (`BuiltinNoteAddon` enum + the resolver chain in
`ProductionNodeAdapter.swift:389-390`) and the declarative
`RielaBuiltinAddonCatalog.noteAddons` (`Sources/RielaAddons/RielaAddons.swift:56-66`)
that tests assert against — including fixing the pre-existing drift where
`note-graph-neighbors` is in the enum but missing from the catalog.
Two known hazards shape the tests: `riela workflow validate` has no
addon-name allowlist, and unrecognized `riela/*` names fall through to a
generic `{status:"ok"}` no-op stub — so add-on tests and mock scenarios must
assert output payload shapes, never bare step success.

**`riela/note-kanban-task-create`** — idempotent board + card setup.

- config: `noteRoot`, `folderTagName` (created with `folder` class if
  missing; may be `parent/child` path — created hierarchically),
  `initialProgress` (default `pending`).
- inputs: `tasks: [{ taskKey, title, briefMarkdown, acceptanceMarkdown? }]`.
- behavior: one notebook per task, tagged with the folder tag, first note =
  brief (+ acceptance section), `progress = initialProgress`, `meta_json`
  carries `{ "kanbanTaskKey": taskKey, "orchestration": <runLabel> }`.
  (`createNotebook` has no progress argument — `NoteService.swift:46-94`
  inserts with the column default — so the add-on sets progress via
  `setNotebookProgress` right after creation.)
  Idempotency: an existing non-`done` notebook under the folder tag with the
  same `kanbanTaskKey` is reused, not duplicated (safe re-run after
  interruption).
- output: `{ folderTagName, tasks: [{ taskKey, notebookId, title,
  briefMarkdown, acceptanceMarkdown, progress }] }` in input order — shaped
  for direct use as a fan-out `itemsFrom` source.

**`riela/note-kanban-move`** — one card transition with CAS.

- config: `noteRoot`.
- inputs: `notebookId`, `to` (status name), optional `expectedFrom`.
- behavior: `setNotebookProgress(notebookId, to, expectedProgress:
  expectedFrom)`; surfaces the typed conflict distinctly from validation
  failure so workflows can branch on it.
- output: `{ notebookId, progress, previousProgress }`.

**`riela/note-kanban-board`** — deterministic board read.

- config: `noteRoot`, `tagName`, optional `categories` filter.
- output: `{ tagName, columns: [{ status: {name, category, position},
  notebooks: [{ notebookId, title, progress, updatedAt, metaJSON }] }] }`
  using the A3 grouping rule.

### B2. Example workflow `examples/note-kanban-orchestrate`

Single workflow, manager-coordinated, agent-backend-agnostic (Claude/Codex
node payloads follow existing example conventions):

```
riela-manager
  → step1-decompose            (agent) task → {folderTagName, tasks[]}
  → step2-board-setup          (addon note-kanban-task-create)
  → [fanout itemsFrom /tasks, itemVariable task,
     concurrency 4, failurePolicy collect-partial, joinStepId step6-review]
      step3-claim              (addon note-kanban-move → progress, expectedFrom pending;
                                labeled conflict transition straight to step6-review)
      step4-execute            (agent) do the work, emit resultMarkdown + self-assessment
      step5-record-and-review  (addon note-create result note, then note-kanban-move → review)
  → step6-review               (join; loop gate; agent reviews every task notebook: verdicts[])
      ├─ all_pass → step7-finalize (addon per card note-kanban-move → done; summary note)
      │             → workflow-output
      └─ !(all_pass) → [fanout itemsFrom /failedTasks, join step6-review]
                    back through step3-claim/step4-execute/step5-record-and-review
                    with reviewer feedback + round counter bound into the item
```

Authoring details (each hardened against adversarial-review findings F3–F7):

- **JSON Pointers are relative to the routed (envelope-unwrapped) payload**
  (F4): the fan-out source payload is the candidate payload *after* `{when,
  payload}` unwrapping (`AdapterContracts.swift:298-343`), and add-on outputs
  are flat — so the pointers are `/tasks` and `/failedTasks`, **not**
  `/payload/...`. (The existing `design-and-implement-review-loop` example's
  `/payload/featureFanoutItems` is a latent mismatch never exercised by its
  mock — not a precedent to copy.)
- **Loop bounding uses the real loop-gate mechanism** (F5 — there is no
  `loop_exhausted` label facility): `step6-review` is authored as a loop
  gate (`loop.gateId` / gate role) whose guard corridor
  (`LoopPolicy.swift:113-187`; default synthesized `maxGateVisits`, set
  explicitly to 3) routes exhaustion to `step7-finalize`, which finalizes
  with unresolved cards left in `review` and reported in the output payload.
  The reviewer also threads a `round` counter into each rework item for
  prompt context. Pass/fail transitions are label-exclusive (`all_pass` /
  `!(all_pass)`) because live publication rejects multiple matching
  transitions (`RuntimePublication.swift:770-781`); labels use the
  restricted `WorkflowBranchEvaluator` grammar (identifiers from the
  node's `when` map, `&&`/`||`/`!` only).
- **`failurePolicy: collect-partial`** (the scoped RielaCore extension) so
  one failed card cancels nothing and the join always runs: branch outcome
  records (success or failure + reason) arrive in
  `runtimeVariables.fanoutJoin.branches[]` in input order; the review step
  treats failed branches as failed-review items with the failure reason as
  feedback.
- **CAS conflict is a branch-local success path** (F3): `step3-claim`
  carries a labeled conflict transition directly to `step6-review` — a
  branch transition targeting the join terminates that branch successfully
  (`DeterministicWorkflowRunner+Fanout.swift:62-81`) — so a card that
  already advanced (rerun re-entry, human drag) is skipped, not failed.
- **Task-type constraint** (F6): local fan-out branches share one workspace
  (no branch isolation; `isolated-workspace` is rejected by the runner), so
  `step1-decompose` is instructed to emit only subtasks whose deliverable is
  **notebook content** (analysis, research, writing, planning — recorded as
  result notes). Workspace-mutating code tasks are explicitly out of scope
  for this workflow; the future variant for code tasks is cross-workflow
  fan-out into worktree-isolated executor workflows.
- Card lifecycle uses the system default set (`pending → progress → review →
  done`), i.e. the orchestration exercises Part A's `review` status without
  requiring a custom set; a custom-set variant is a config choice
  (`folderTagName` bound to a custom set beforehand).
- Agent nodes follow the `{when, payload}` output envelope convention;
  fan-out item fields bind into add-on inputs as `{{task.notebookId}}` etc.,
  alongside runtime-provided `fanoutItem`/`fanoutIndex`/`fanoutGroupId`.
- Registered in `rielaExampleWorkflowNames()`
  (`Tests/RielaCLITests/RielaExampleParityTests.swift:7`) and
  `expectedMockScenarioCount` (`:88`, 38 → 39); ships `mock-scenario.json`
  (full pass + one rework round) and `EXPECTED_RESULTS.md`.
- **Mock scenario determinism** (F7): scenario response sequences are
  per-nodeId with counters shared across branch sessions, so the mock run
  pins effective concurrency to 1 (run-level `maxConcurrency`) for
  deterministic sequence consumption. Agent nodes are canned; the kanban
  add-ons execute **for real** against a temp `noteRoot` (precedent:
  `note-auto-tagging`) so idempotency and CAS are actually exercised. The
  scenario asserts add-on **payload shapes**, not just step success, because
  an unregistered `riela/*` addon name silently no-ops with `{status:"ok"}`
  (`ProductionNodeAdapter.swift:395-405`).

### B3. Concurrency, failure, and recovery semantics

- The note store already serializes concurrent writers (SQLite, transactional
  service methods; kanban race coverage exists in `RielaNoteUITests`).
  Parallel fan-out branches touch disjoint notebooks by construction
  (one card per branch); the CAS guard turns any unexpected interleaving
  (human drags a card mid-run, duplicate branch delivery) into the
  branch-local skip path (F3), never a silent lost update.
- **Recovery is rerun-based, not resume-based** (F2): a crash mid-fan-out
  persists `currentStepId` at the branch target step, so `session resume`
  would re-enter the branch path sequentially without fan-out item bindings
  — malformed by construction, and the runtime never re-dispatches a fan-out
  on resume. The documented recovery is `session rerun` (new session) from
  intake: `note-kanban-task-create` idempotency (taskKey reuse of non-`done`
  cards) plus the `step3-claim` CAS-skip path make reruns converge — cards
  already in `review`/`done` are not re-executed.
- Observability: no new mechanism — the board IS the progress surface (web
  kanban live view with realtime sync, A7), and the workflow session remains
  observable through the existing session/GraphQL surfaces.
- Driver: cron and sequential-list event sources are declared but
  unimplemented in the Swift tree (only the three chat gateways serve live),
  so this workflow is invoked via `riela workflow run` / GraphQL; a
  continuous kanban-poller driver is an explicit follow-up, not part of this
  design.

### B4. RielaCore `collect-partial` failure policy (scoped runtime change)

- `WorkflowModel`/raw validation: accept `"collect-partial"` as a third
  `failurePolicy` value (closed set today: `fail-fast`, `collect-all`).
- `DeterministicWorkflowRunner+Fanout.dispatchFanout`: under
  `collect-partial`, wait for all branch terminals (as `collect-all` does),
  then **always** proceed to `appendFanoutJoinMessage` — branch records keep
  their per-branch `status` / `failureReason` fields (already modeled in the
  join payload shape) and the dispatch never throws for branch failures.
  Dispatch-level errors (unresolvable `itemsFrom`, invalid directive) still
  throw for all policies.
- Capability/diagnostic surfaces that enumerate supported fan-out features
  mention the new policy; `WorkflowRuntimeCapabilityGap` untouched (no gap —
  it is implemented in the same change).
- Tests in `DeterministicWorkflowRunnerFanoutTests`: mixed success/failure
  fan-out joins under `collect-partial` with input-order branch records;
  existing `collect-all` semantics unchanged
  (`testFanoutCollectAllRunsEveryBranchBeforeFailing` stays green).

## Alternatives considered

- **Add `review` as a fifth closed enum case only.** Rejected: satisfies the
  immediate orchestration need but not the requested per-folder configurable
  sets; would force a second schema rebuild later (the CHECK constraint has to
  be rebuilt away either way).
- **Keep GraphQL `NotebookProgress` enum and add a parallel `status: String`
  field.** Rejected: two sources of truth, permanent drift risk across the
  many consumers; repo policy prefers a clean break with all consumers
  updated in one change.
- **Store status per notebook as FK to `kanban_statuses.status_id`.**
  Rejected: cards must remain valid when sets are edited or tags are
  reassigned; a name string plus write-time validation against the effective
  union is more robust and keeps existing data untouched during migration.
- **Free-form orchestration via `riela/note-graphql-document` only (no new
  add-ons).** Rejected: agent-composed GraphQL for claim/move/create is
  non-deterministic and unverifiable in mock scenarios; deterministic add-ons
  follow the established catalog pattern and give CAS semantics a typed seam.

## Risks

- **Wide consumer blast radius (progress enum → string).** Mitigated by the
  A4 consumer checklist and putting `RielaCLITests` + web tests in the gate;
  the compiler surfaces every Swift enum match site once the type changes.
- **Legacy `progress` column divergence.** Migrated stores carry a dead
  `progress` column (old CHECK intact, default-satisfied) that fresh stores
  lack; safe under the named-column-reads invariant, but a future `SELECT *`
  or positional read would break on exactly one of fresh-vs-migrated.
  Migration tests must cover fresh v5, v4→v5 with existing data (values
  copied to `status`, `review` writable post-migration, insert path green on
  both shapes), and idempotent re-run.
- **Reviewer/agent JSON contract drift** in the example workflow. Mitigated
  by mock scenarios asserting exact payload shapes and by keeping all
  status transitions in add-on steps (agents never mutate the board
  directly).
- **SSE on the custom HTTP server.** The Swift serving stack has no
  streaming-response precedent in the note path; the implementation must
  verify `RielaLocalHTTPServer` (and the in-app `/graphql` twin) can hold a
  connection open and flush chunked frames. If it cannot without deep
  surgery, the documented fallback is a cheap revision-poll endpoint
  (`GET /note/revision`) driving the same debounced refresh — the client
  contract (event → refresh) is transport-agnostic by design.
- **Self-joining rework fan-out.** The rework dispatch fans out from
  `step6-review` and joins back at `step6-review`. Review verified this is
  mechanically allowed (validation only checks `joinStepId` membership,
  `WorkflowValidation.swift:88-90`; join messages merge latest-wins) but it
  is exercised nowhere yet. If it misbehaves in practice, the fallback
  authoring is a pass-through router step (`step6b-rework-dispatch`) between
  review and the fan-out, joining back at `step6-review`. The mock scenario
  must cover one rework round either way.
- **`collect-partial` touches the core runner.** The change is small
  (dispatch no longer throws on branch failure for the new policy) but sits
  in `DeterministicWorkflowRunner+Fanout`; the existing fail-fast /
  collect-all tests must stay green untouched, and the new policy needs its
  own mixed-outcome join test before the example workflow builds on it.

## Verification plan

- `swift build`; `swift test` filters: `RielaNoteTests` (migration,
  status-set CRUD, effective-set resolution, CAS, allowed-union validation),
  `RielaGraphQLTests` (new operations + progress-as-string),
  `RielaNoteUITests` (dynamic columns, race tests still green),
  `RielaCLITests` (NoteCommandTests, new add-on tests, example registry +
  mock-scenario run for `note-kanban-orchestrate`).
- Web: `npm test` (client/controller updated suites), `npm run build`.
- Known pre-existing local flakes per `riela-known-flaky-local-tests`
  (DaemonWorkflowNodePatch event-source-restart; agent-VM interleaved-submit)
  are not part of this gate.
- Live smoke: `riela workflow run note-kanban-orchestrate` with a mock
  scenario; manual web board check that a `review` column renders, that the
  board loads locked and unlocks, and that a `riela note`-side progress
  change appears on an open board without manual refresh (SSE path).
- Web e2e additions: locked-board interaction guard, unlock toggle
  persistence, and an SSE-driven refresh assertion (mock event source).
