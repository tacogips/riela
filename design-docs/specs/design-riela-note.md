# Riela Note

## Summary

Riela Note is an ontology-oriented personal knowledge store ("external
brain") built into Riela. Every piece of user knowledge is captured as a
**note** (markdown body) inside a **notebook**, connected to other notes
through **tags bound to world-model classes** (person, year, event,
document-kind, ...), **note-to-note links**, **comments**, and **related
files** (images, video, audio, source documents). Ingestion, enrichment
(AI tagging), retrieval (RAG), and automation are all expressed as Riela
workflows, so Riela Note is a first-class consumer of the existing
workflow runtime rather than a separate product.

Requirements source: `design-docs/riela-note-design.md` (Japanese
requirements memo). This spec turns that memo into a reviewed design and
is the design reference for `impl-plans/active/riela-note.md`.

Primary capabilities delivered by this design:

- Note / notebook data model on SQLite with an ontology-aware tag system
  that distinguishes human-applied, AI-applied, and system tags.
- File attachments stored on local disk or S3-compatible storage, with
  per-file storage locators and single/bulk local-to-S3 migration.
- Note CRUD exposed as built-in workflow add-ons, a GraphQL surface, and
  a `riela note` CLI family.
- A default, read-only system-memory notebook replaces the standalone
  `RielaMemory` package and gives agents and humans one shared knowledge
  substrate without exposing the privileged system-write bypass to clients.
- Ingestion pipelines as workflows: PDF page-per-note import, YouTube
  transcript notes, quick memo capture from chat event sources.
- Post-create auto-actions (default: AI tagging) expressed as workflows.
- Riela Note Agent local-search chat with citation links and
  conversation-as-notebook persistence; vector/web RAG remains a
  follow-up. Riela Note Config Agent for note/workflow configuration.
- Notebook-level **Expand with Agent** creates a compact-summary-grounded
  agent conversation with lazy, invalidatable summary caching and explicit
  source-note provenance. Its focused contract is defined in
  `design-docs/specs/design-riela-note-notebook-expand.md`.
- Optional remote note API exposure is designed but not shipped; current
  code provides in-process/local GraphQL plus pluggable auth and QR-code
  client-registration building blocks for a future socket transport.
- macOS app screens built with an iPad/iPhone-portable SwiftUI layout.

## Code-Verified Current State

- **F1 — SQLite layer exists, no Turso/libSQL dependency.**
  `Sources/RielaSQLite/SQLiteDatabase.swift` wraps sqlite3 (native
  `SQLite3` on macOS, `CRielaSQLite3` on Linux) with WAL, busy timeout,
  and JSONB validation. Schema/migration precedent lives in
  `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` and
  `Sources/RielaCore/SQLiteWorkflowMessageLog.swift` (create-on-open,
  additive `ALTER TABLE` migration, `INSERT ... ON CONFLICT` upserts).
- **F2 — Built-in add-ons are dispatched by name.** Built-ins such as
  `riela/chat-reply-worker` and the `riela/memory-*` family are handled
  in `Sources/RielaCLI/ProductionNodeAdapter.swift` against the
  contracts in `Sources/RielaAddons/` (`AddonExecutionInput/Output`,
  `AddonSourceMetadata.builtin`, attachment projection).
- **F3 — Event sources already deliver chat attachments.**
  `Sources/RielaEvents/` provides telegram/discord/slack/matrix/webhook
  bindings whose payloads carry `message.attachments`, `imagePaths`,
  and pre-extracted `attachmentText`. OCR / page imaging / YouTube
  transcription are treated as already-achievable workflow steps per the
  requirements memo; Riela Note only defines the note-side contract.
- **F4 — GraphQL is code-first and effectively read-only today.**
  `Sources/RielaGraphQL/GraphQLContracts.swift` defines DTOs and
  `GraphQLRuntimeSnapshotQueryService` serves snapshot queries; the
  server routes `/graphql` through
  `Sources/RielaServer/` (`ServerRequestContext` carries
  `bearerToken` but no validation is enforced).
- **F5 — CLI command registration pattern.** `RielaCommand` +
  `RielaArgumentParser` + injected command runners in
  `Sources/RielaCLI/RielaCLIApplication.swift`; a new top-level
  `note` command family follows the `package`/`session` precedent.
- **F6 — RielaApp is an AppKit status-bar app.**
  `Sources/RielaApp/EntryPoint.swift` (NSApplicationDelegate),
  window controllers for daemon workflows/profiles; profile data roots
  at `~/.riela/profiles/<profile>/`. There is no SwiftUI module yet, so
  an iPad-portable note UI needs a new hosting boundary.
- **F7 — Storage roots.** User scope `~/.riela/...`, project scope
  `./.riela/...`, app profile scope `~/.riela/profiles/<profile>/...`.
- **F8 — Standalone memory duplicates the Note domain.**
  `Packages/RielaMemory`, `riela memory`, the `riela/memory-*` and persona
  memory add-ons, workflow-level `memories` declarations, and memory-specific
  runner/validation code maintain a parallel record, search, attachment, and
  metadata path. Riela Note already owns those concepts through notes, tags,
  links, files, FTS, GraphQL, REST workspace routes, and human-facing views.

## Design Decisions

- **D1 — New `RielaNote` target owns the domain.** Note/notebook/tag/
  file models, the SQLite store, and the `NoteService` facade live in a
  new SwiftPM target `Sources/RielaNote/` depending only on
  `RielaSQLite` (+ Foundation). CLI, GraphQL, add-ons, server, and app
  all consume `NoteService`; no consumer touches SQL directly.
- **D2 — SQLite via a driver seam; Turso SDK as a scoped follow-up.**
  The requirements ask for SQLite "via the Turso SDK". The repository
  currently has zero libSQL dependency (F1), and the note schema needs
  nothing beyond vanilla SQLite + FTS5. Decision: define a narrow
  `NoteDatabaseDriving` protocol inside `RielaNote`; the first driver
  wraps the existing `SQLiteDatabase`, and the schema/SQL is kept
  libSQL-compatible (no sqlite-only extensions except FTS5, which
  libSQL supports). Adopting `tursodatabase/libsql-swift` (embedded
  replica / remote sync) is an explicitly planned follow-up task, not a
  blocker for the first release. Rejected: making libsql-swift the only
  driver now — it would add a second sqlite runtime to every target that
  links RielaNote before any sync use case exists.
- **D3 — Every note lives in a notebook.** A standalone note is a
  notebook containing exactly one note (per requirements). Notebook
  kind (imported material, agent conversation, user memo, ...) is
  modeled as a **system tag** on the notebook, applied at creation and
  non-deletable.
- **D4 — Note title is derived, not stored authoritatively.** The first
  `# ` heading of `body_markdown` is the title. The store caches it in a
  `title` column maintained on every write for list/search performance;
  the markdown remains the source of truth.
- **D5 — Read-only is content-only.** `read_only = 1` blocks body edits
  and note deletion but always permits comments, tags, and links.
- **D6 — Tag provenance is first-class.** Every tag assignment records
  `provenance` (`human` | `ai` | `system`) and `assigned_by` (user id,
  or workflow session/agent identifier). AI and human tags are never
  merged: re-tagging by AI cannot overwrite or delete a human tag, and
  UI/CLI render provenance distinctly. System tags (notebook kind) are
  non-deletable.
- **D7 — Ontology = tag classes.** A `tag_classes` table defines
  world-model classes (`person`, `year`, `event`, `document-kind`,
  `topic`, ...). A tag may bind to at most one class. Classes are
  user-extensible; a seeded set ships as `is_system = 1`. Tag names are
  globally unique (`tags.name UNIQUE`); the class binding is metadata on
  the tag, not part of its identity. Cross-note linking ("this book
  mentions person X → note about X") is realized by shared tags plus
  explicit `note_links` rows.
- **D8 — Files are content-addressed records with storage locators.**
  Each file row stores `storage_kind` (`local` | `s3`), a locator
  (relative path, or bucket/key/profile), sha256, media type, and size.
  Default is local under the note root. Local→S3 migration (single and
  bulk) rewrites the locator after a verified copy; mixed storage is
  normal. Embedded-in-markdown files and "related files" are the same
  `files` rows attached with different roles.
- **D9 — Note store root is user-scoped by default.** Default root
  `~/.riela/note/` (`note-store.sqlite` + `files/`); RielaApp profiles
  use `~/.riela/profiles/<profile>/note/`. Overridable via
  `--note-root` / launch options. Notes are personal knowledge, so the
  project scope is not a default (rejected: project-scoped notes in v1).
- **D10 — All write paths converge on `NoteService`.** Add-ons, GraphQL
  mutations, CLI, and the app call the same service, which enforces
  read-only rules, tag provenance rules, system-tag immutability, and
  fires auto-action triggers exactly once per commit.
- **D11 — Automation is workflows, not bespoke hooks.** Post-create
  auto-actions are rows binding a trigger (`note-created`,
  `note-updated`, `notebook-created`) to a workflow id plus an optional
  tag/kind filter. The default AI-tagging action is a packaged workflow
  (agent worker proposes tags → `riela/note-tag-apply` writes them with
  `provenance = ai`). Loop guard: `note-updated` fires only on body
  writes (tag/comment/link writes never fire triggers), and writes
  performed by a workflow run dispatched from an auto-action carry the
  originating action id so they cannot re-trigger actions on the same
  note — together these prevent tag-write loops.
- **D12 — Agent conversations persist as notebooks.** Each Note Agent
  conversation maps to a notebook tagged `notebook-kind:agent-conversation`;
  each turn (user prompt + agent answer with source-note links) is one
  note. Default auto-save; a "temp chat" runs without materializing the
  notebook until an explicit save. Temp-chat transcripts are held only
  by the caller (UI state / the agent workflow's runtime session); the
  note store holds no staging state until Save.
- **D13 — Retrieval starts with FTS5, embeddings are additive.** v1 RAG
  = FTS5 (`note_fts`) + tag/class filters, surfaced through
  `riela/note-search`. An optional embeddings table and a vector-search
  add-on are designed but deferred (no sqlite-vec / model dependency in
  v1). RAG answers must cite `note_id`s so the UI can deep-link.
- **D14 — Remote note API is opt-in with pluggable auth, but the
  socket transport is still a follow-up.** The shipped note GraphQL
  executor is used in-process by `riela note`, add-ons, and local UI
  clients. `riela serve --note-api` currently prepares serving-layer
  note API configuration but does not bind a network listener. Auth is
  a `NoteAPIAuthenticating` protocol; v1 includes the
  `QRClientRegistrationAuthenticator` building blocks, while a real
  remote listener, reachable registration flow, and Google/Auth0
  adapters remain future work. When the listener lands, network
  reachability is assumed to be VPN (Tailscale), default bind must stay
  `127.0.0.1`, and non-loopback exposure must require an explicit host
  override.
- **D15 — UI is a portable SwiftUI module.** New target
  `Sources/RielaNoteUI/` contains platform-agnostic SwiftUI views
  (compact/regular adaptive layout designed iPhone/iPad-first).
  RielaApp hosts them via `NSHostingController` in a new Note window.
  iPhone/iPad apps are out of scope, but must be able to reuse
  `RielaNoteUI` unchanged.
- **D16 — Tag hierarchy is single-parent and filter expansion is
  descendant-inclusive.** A tag may have one optional parent. Existing
  tag filters remain name-based and retain their current OR semantics,
  but each requested name is resolved to the matching tag and its
  transitive descendants before note or notebook assignments are
  matched. The requested tag itself is always included, so filtering by
  a leaf is unchanged. Unknown names continue to match nothing.
- **D17 — Parent changes reject cycles.** Creating or updating a tag
  parent validates that the parent exists, differs from the child, and
  is not already below the child. Validation and persistence occur in
  one transaction. Descendant reads additionally bound or de-duplicate
  recursive traversal so malformed legacy data cannot loop indefinitely.
- **D18 — Folder is a notebook-applicable system tag class.** The
  seeded `folder` class organizes notebooks through ordinary
  `notebook_tags` assignments. It does not create filesystem folders,
  change notebook ownership, or introduce containment-based deletion.
- **D19 — Notebook progress is a typed workflow state.** Every notebook
  has exactly one state: `none`, `progress`, `done`, or `pending`.
  `none` is the storage default and migration value. Progress is a
  first-class notebook column, not `meta_json`, and changes use the same
  `NoteService` write boundary as other notebook mutations.
- **D20 — System memory is one reserved notebook.** Every prepared note store
  contains the notebook id `notebook-system-memory`, titled `System Memory`,
  tagged with the non-deletable system tag
  `notebook-kind:system-memory`. The fixed id makes bootstrap idempotent; the
  kind tag is the public classification used by clients. Ordinary notebook
  creation cannot claim the reserved id or kind, and ordinary deletion cannot
  remove this notebook.
- **D21 — Notebook read-only is a persisted content lock.**
  `notebooks.read_only` defaults to `0`; the system-memory bootstrap row starts
  at `1`. Effective content read-only is
  `notebook.read_only || note.read_only`. It blocks ordinary note creation,
  body/title updates, note or notebook deletion, attachment mutation, comment
  promotion, and other operations that create or replace notebook content.
  Consistent with D5, navigation, reads, search, tags, comments, links, Kanban
  status, and the lock toggle remain available. This keeps read-only notebooks
  organizable and avoids blocking read-only source use by agent expansion.
- **D22 — The system bypass is capability-shaped, not a Boolean option.**
  Note-backed system-memory add-ons call a dedicated `NoteService` system-memory
  write entry point. That entry point resolves the reserved notebook and may
  bypass only its notebook-level content lock; no GraphQL, REST, CLI, or generic
  note-add-on input can request bypass. System-memory writes do not enqueue note
  auto-actions, preventing an agent-memory write from recursively starting
  enrichment workflows. Writes made by a human after unlocking use ordinary
  NoteService semantics, including auto-actions.
- **D23 — Unlock is a durable notebook mutation.** GraphQL and the same-origin
  RielaApp workspace REST API expose `setNotebookReadOnly`; the SolidJS Notes
  view renders an explicit Unlock button for the locked system-memory notebook
  and a Lock button after unlock. The value is stored in SQLite, survives
  reload/relaunch, and is never reset by bootstrap conflict handling.
- **D24 — Memory records become notes without data-file migration.** Each new
  memory entry is one note in the system-memory notebook. Its `note_id` is the
  durable record identity, markdown is searchable content, note tags carry
  classification, note links carry relationships, note files carry
  attachments, and `meta_json` carries source/provenance fields. Existing
  `.riela/memory/` databases and sidecars remain untouched and unread; there is
  no compatibility shim, importer, or dual write.

## Data Model (SQLite)

Database file: `<note-root>/note-store.sqlite`, opened through
`NoteDatabaseDriving` (WAL, busy timeout, JSONB checks — same options as
existing stores). All ids are ULID-style sortable strings; timestamps
ISO-8601 UTC. Creation is idempotent `CREATE TABLE IF NOT EXISTS`;
future changes use additive migrations guarded by a
`note_schema_version` table (improves on the ad-hoc `ALTER` probing in
existing stores).

```sql
CREATE TABLE notebooks (
  notebook_id   TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  progress      TEXT NOT NULL DEFAULT 'none'
                CHECK (progress IN ('none','progress','done','pending')),
  read_only     INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  meta_json     BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
);

CREATE TABLE notes (
  note_id       TEXT PRIMARY KEY,
  notebook_id   TEXT NOT NULL REFERENCES notebooks(notebook_id),
  note_number   INTEGER NOT NULL,          -- 1-based position (page number)
  title         TEXT,                       -- cache of first "# " heading (D4)
  body_markdown TEXT NOT NULL,
  read_only     INTEGER NOT NULL DEFAULT 0, -- D5
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  meta_json     BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8)),
  UNIQUE (notebook_id, note_number)
);
CREATE INDEX idx_notes_notebook ON notes(notebook_id, note_number);
CREATE INDEX idx_notes_created  ON notes(created_at DESC);

CREATE TABLE tag_classes (
  class_id    TEXT PRIMARY KEY,   -- "person" | "year" | "event" | "document-kind" | ...
  label       TEXT NOT NULL,
  description TEXT,
  is_system   INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL
);

CREATE TABLE tags (
  tag_id        TEXT PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  class_id      TEXT REFERENCES tag_classes(class_id),   -- D7, nullable
  parent_tag_id TEXT REFERENCES tags(tag_id),             -- D16, nullable
  is_system     INTEGER NOT NULL DEFAULT 0,                -- notebook-kind tags etc.
  created_at    TEXT NOT NULL
);

CREATE TABLE note_tags (
  note_id     TEXT NOT NULL REFERENCES notes(note_id),
  tag_id      TEXT NOT NULL REFERENCES tags(tag_id),
  provenance  TEXT NOT NULL CHECK (provenance IN ('human','ai','system')), -- D6
  assigned_by TEXT,                    -- user id / workflow session id / agent id
  deletable   INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  PRIMARY KEY (note_id, tag_id)
);

CREATE TABLE notebook_tags (          -- notebook kind lives here (D3)
  notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
  tag_id      TEXT NOT NULL REFERENCES tags(tag_id),
  provenance  TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
  assigned_by TEXT,
  deletable   INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  PRIMARY KEY (notebook_id, tag_id)
);

CREATE TABLE files (
  file_id           TEXT PRIMARY KEY,
  storage_kind      TEXT NOT NULL CHECK (storage_kind IN ('local','s3')), -- D8
  local_path        TEXT,      -- relative to <note-root>/files/
  s3_profile        TEXT,      -- named endpoint/credential profile
  s3_bucket         TEXT,
  s3_key            TEXT,
  media_type        TEXT NOT NULL,
  byte_size         INTEGER NOT NULL,
  sha256            TEXT NOT NULL,
  original_filename TEXT,
  created_at        TEXT NOT NULL,
  migrated_at       TEXT,
  CHECK ((storage_kind = 'local' AND local_path IS NOT NULL)
      OR (storage_kind = 's3' AND s3_profile IS NOT NULL
          AND s3_bucket IS NOT NULL AND s3_key IS NOT NULL))
);
CREATE INDEX idx_files_sha ON files(sha256);

CREATE TABLE note_files (
  note_id  TEXT NOT NULL REFERENCES notes(note_id),
  file_id  TEXT NOT NULL REFERENCES files(file_id),
  role     TEXT NOT NULL CHECK (role IN
             ('embedded','related','source-page-image')),
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (note_id, file_id, role)
);

CREATE TABLE notebook_files (        -- e.g. the original PDF of an import
  notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
  file_id     TEXT NOT NULL REFERENCES files(file_id),
  role        TEXT NOT NULL CHECK (role IN ('source-document','related')),
  PRIMARY KEY (notebook_id, file_id, role)
);

CREATE TABLE note_links (
  from_note_id TEXT NOT NULL REFERENCES notes(note_id),
  to_note_id   TEXT NOT NULL REFERENCES notes(note_id),
  link_kind    TEXT NOT NULL DEFAULT 'related',
  provenance   TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
  created_at   TEXT NOT NULL,
  PRIMARY KEY (from_note_id, to_note_id, link_kind)
);

CREATE TABLE note_comments (
  comment_id    TEXT PRIMARY KEY,
  note_id       TEXT NOT NULL REFERENCES notes(note_id),
  body_markdown TEXT NOT NULL,
  author        TEXT NOT NULL,        -- 'user' | 'agent:<session-id>'
  created_at    TEXT NOT NULL
);

CREATE TABLE auto_actions (          -- D11
  action_id     TEXT PRIMARY KEY,
  trigger       TEXT NOT NULL CHECK (trigger IN
                  ('note-created','note-updated','notebook-created')),
  workflow_id   TEXT NOT NULL,
  filter_json   BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
  enabled       INTEGER NOT NULL DEFAULT 1,
  position      INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL
);

CREATE TABLE api_clients (           -- D14 / QR registration
  client_id     TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  token_hash    TEXT NOT NULL,       -- sha256 of the bearer token
  created_at    TEXT NOT NULL,
  last_seen_at  TEXT,
  revoked_at    TEXT
);

CREATE VIRTUAL TABLE note_fts USING fts5(   -- D13
  title, body, tags,
  content='', tokenize='trigram'
);
CREATE TABLE note_fts_map (                  -- note_id <-> fts rowid
  fts_rowid INTEGER PRIMARY KEY,
  note_id   TEXT NOT NULL UNIQUE
);
CREATE TABLE auto_action_dispatches (         -- durable outbox for D11
  dispatch_id       TEXT PRIMARY KEY,
  action_id         TEXT NOT NULL,
  action_trigger    TEXT NOT NULL CHECK (action_trigger IN
                    ('note-created','note-updated','notebook-created')),
  workflow_id       TEXT NOT NULL,
  filter_json       BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
  action_enabled    INTEGER NOT NULL,
  action_position   INTEGER NOT NULL,
  action_created_at TEXT NOT NULL,
  event_json        BLOB NOT NULL CHECK (json_valid(event_json, 8)),
  status            TEXT NOT NULL CHECK (status IN ('pending','dispatched')),
  attempt_count     INTEGER NOT NULL DEFAULT 0,
  last_error        TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
-- Contentless FTS5: NoteService maintains the index inside the same
-- transaction as the note/tag write — a 'delete' command insert with
-- the previous column values, then a re-insert with the new values.
```

Write semantics enforced by `NoteService` (the sole writer, D10):

- `note_number` is allocated as `max + 1` within the notebook's write
  transaction; the `UNIQUE (notebook_id, note_number)` constraint
  backstops concurrent writers.
- Deletes are transactional cascades performed by the service (no
  `ON DELETE CASCADE`): deleting a note removes its `note_tags`,
  `note_files`, `note_links`, `note_comments`, FTS entries, and map
  row; deleting a notebook deletes its notes first. Read-only content
  rejects deletion (D5). `files` rows are content records and survive
  note deletion; garbage collection of unreferenced file content is a
  v1 non-goal.

Seeded rows: system tag classes (`person`, `year`, `event`,
`document-kind`, `topic`, `folder`), system tags for notebook kinds
(`notebook-kind:imported-material`, `notebook-kind:agent-conversation`,
`notebook-kind:user-memo`), and default `auto_actions` rows binding
`note-created` **and** `note-updated` (requirement: tagging happens on
create and edit) to the packaged AI-tagging workflow. The seeded rows
are inert — skipped with a diagnostic — until that workflow is
installed (see auto-action dispatch rules below).

### Hierarchy filtering and schema-v4 rollout

All note and notebook filtering follows one logical data flow:

1. Normalize the requested tag names while preserving existing
   name-based filter behavior.
2. Resolve those names to root tag ids.
3. Traverse `tags.parent_tag_id` from each root to obtain the union of
   each root and all transitive descendants.
4. Match `note_tags` or `notebook_tags` against that id set, then apply
   the existing sorting, pagination, text, class, and date predicates.

This flow is shared by notebook listing, note listing, filtered search,
text-search fallback, and composed search predicates. Expansion happens
before assignment filtering; it does not mutate assignments or make a
parent tag appear directly assigned to descendant-tagged items.

Schema version 4 adds nullable `tags.parent_tag_id` and typed
`notebooks.progress`. Migration follows the existing guarded migration
sequence: probe each column, alter only when absent, record version 4
only after both changes succeed, and keep fresh-database table
definitions identical to the migrated shape. Existing notebooks read as
`none`. If the supported SQLite runtime cannot add the constrained
progress column directly, migration uses the established transactional
rename-copy-rebuild pattern without rewriting unrelated tables.

### Schema-v6 and system-memory bootstrap

Schema v6 is additive. `NoteStoreSchema.currentVersion` becomes `6`, fresh
`notebooks` definitions include `read_only INTEGER NOT NULL DEFAULT 0`, and
`migrateToV6` performs only:

```sql
ALTER TABLE notebooks ADD COLUMN read_only INTEGER NOT NULL DEFAULT 0;
```

The migration is appended to `schemaMigrations`; it does not rename, rebuild,
drop, or copy `notebooks` or `notes`. After migrations, the existing bootstrap
transaction seeds `notebook-kind:system-memory`, inserts the reserved notebook
with `read_only = 1` using conflict-ignore semantics, and idempotently attaches
the system tag. Conflict handling must not overwrite `read_only`, so a user's
persisted unlock survives subsequent store preparation. Existing notebooks
retain the default writable value and existing note data is unchanged.

### Memory-to-note field mapping

| Removed memory field | Riela Note owner | Rule |
| --- | --- | --- |
| `recordId` | `notes.note_id` | New outputs and relationships use note ids; legacy integer ids are not translated. |
| `memoryId` | `meta_json.memoryNamespace` | Logical namespace only; storage always resolves to the reserved notebook. |
| `workflowId`, `nodeId` | `meta_json.source.workflowId/nodeId` | Preserve agent provenance without creating high-cardinality tags. |
| `registeredAt` | `notes.created_at` and `meta_json.recordedAt` | Store timestamp is authoritative; caller timestamp is retained when supplied. |
| `payload` | `notes.body_markdown` plus structured `meta_json` | Human-readable content is searchable; bounded structured fields remain machine-readable. |
| `tags[]` | `note_tags` | Apply through NoteService provenance and validation rules. |
| `relatedRecordIds[]` | `note_links` | Successor inputs accept related note ids only. |
| `files[]` | `files` plus `note_files` | Copy/attach through the Note file-store boundary; no path-only sidecar contract remains. |

Persona entries use markdown content plus metadata keys `memoryNamespace`,
`personaId`, `personaName`, `kind`, `importance`, `source`, `recordedAt`, and
source workflow/node ids. Tags include `persona:<id>`,
`memory-kind:<kind>`, and `memory-importance:<importance>`. Reads are bounded to
the reserved notebook, namespace, and persona, newest first, with limit
clamped to `1...30`.

## File Storage

`NoteFileStore` (in `RielaNote`) abstracts content storage:

- `LocalNoteFileStore`: writes to `<note-root>/files/<xx>/<file_id>`
  (fan-out by id prefix), atomic temp-file + rename, sha256 verified.
- `S3NoteFileStore`: S3-compatible via signed HTTP (AWS SigV4) against a
  named **storage profile** (`endpoint`, `region`, `bucket`, credential
  env refs) defined in note settings; no AWS SDK dependency.
- `migrate(fileId, to: .s3(profile:))` copies, verifies sha256/size,
  updates the locator + `migrated_at`, then removes the local copy.
  `migrateAll(filter:)` batches this with per-file progress and
  continues past individual failures (reported at the end).
- Reads resolve through the locator, so mixed local/S3 attachment sets
  render transparently; S3 reads stream to a local cache for the viewer.

## NoteService (library facade)

`Sources/RielaNote/NoteService.swift` — the single write/read API (D10):

- Notebook/note CRUD: `createNotebook`, `createNote`, `updateNoteBody`
  (rejects when either effective content lock is set), `setReadOnly`,
  `setNotebookReadOnly`, `deleteNote`/`deleteNotebook` (rejects effective
  read-only content and protects the reserved system-memory notebook),
  `listNotebooks(sort: .createdAtDesc)` returning first-note preview
  snippets, `getNote`, `getNotebook`, and `setNotebookProgress`.
- Tags: `defineTagClass`, `defineTag` with an optional validated parent,
  `applyTags(noteId, tags, provenance, assignedBy)`, `removeTag`
  (rejects `deletable = 0`; AI provenance may never remove a `human`
  assignment).
- Files: `attachFile(noteId, data/stream, role)`, `attachExistingFile`,
  `resolveFileContent(fileId)`, `migrateFileStorage`, `migrateAllFiles`.
- Links & comments: `linkNotes`, `addComment` (allowed on read-only).
- Search: `searchNotes(query, tagFilter, classFilter, limit)` over FTS5
  + tag joins; returns snippets and matched-tag metadata.
- Conversations: `appendConversationTurn(notebookId, turn)` for
  auto-saved chats, `saveConversation(transcript)` to materialize a
  temp chat in one call. No staging state in the store for temp chats
  (D12) — the transcript stays with the caller until Save.
- Auto-actions: `listAutoActions`, `configureAutoAction`, and an
  internal `AutoActionDispatching` hook: after commit, matching
  `auto_actions` rows are dispatched as workflow runs (reusing the same
  execution entry points the event listener uses) with the note id and
  a content snapshot as workflow input. Dispatch is at-least-once and
  non-blocking for the original write. Workflow ids are resolved
  through the existing workflow catalog at dispatch time; an unresolved
  id is skipped with a diagnostic (this keeps the seeded AI-tagging
  action inert until its packaged workflow is installed). Loop guard
  per D11: action-originated writes carry the action id and are
  excluded from re-dispatch for the same note.
- System memory: `systemMemoryNotebook` resolves the reserved id/tag invariant;
  narrow save/update operations may bypass the notebook content lock and
  suppress auto-action enqueueing. The bypass is internal to these typed
  operations and is not an argument on ordinary CRUD methods.

## Built-in Note Add-ons

Built-ins are registered in the production adapter and operate through
`NoteService` against a
note root resolved in order: explicit `addon.config.noteRoot` →
`RIELA_NOTE_ROOT` environment variable → app profile context →
default `~/.riela/note/` (D9).

| Add-on | Purpose |
| ------ | ------- |
| `riela/note-create` | Create a note (and notebook when `notebookId` omitted); accepts markdown body, tags (with provenance), attachment refs from event payloads. |
| `riela/note-update` | Update body / append section; honors read-only. |
| `riela/note-get` | Fetch note (body, tags, files, links, comments) for downstream steps. |
| `riela/note-search` | FTS + tag/class search; returns ranked notes with `note_id` citations (RAG retrieval primitive, D13). |
| `riela/note-tag-apply` | Apply tags with `provenance: ai` (used by the auto-tagging workflow); creates missing tags/classes when allowed by config. |
| `riela/note-attach-file` | Persist a workflow attachment (image/video/audio/pdf) into the file store and bind it to a note/notebook with a role. |
| `riela/note-comment-add` | Add an agent comment. |
| `riela/notebook-ingest-pages` | Batch: `pages: [{number, markdown, pageImageRef?}]` + optional `sourceDocumentRef` → notebook with one note per page, `source-page-image` files bound, kind tag `imported-material`. |
| `riela/note-conversation-save` | Persist an agent conversation turn (or finalize a temp conversation) as notes in a conversation notebook (D12). |
| `riela/note-memory-save` | Create one system-memory note from markdown or structured payload, tags, related note ids, attachments, and source metadata. |
| `riela/note-memory-update` | Update an identified system-memory note through the privileged system path; reject notes outside the reserved notebook. |
| `riela/note-memory-load` | Load an identified note only when it belongs to the reserved notebook. |
| `riela/note-memory-search` | Search only the reserved notebook, optionally narrowed by namespace/tags, with bounded results. |
| `riela/note-persona-memory-read` | Return recent persona-scoped notes as `memoryMarkdown`, note/file projections, and existing handoff guidance. |
| `riela/note-persona-memory-write` | Persist explicit persona `memoryEntries` as notes while preserving reply/handoff behavior; outputs note ids, never legacy record ids. |

Add-on inputs reuse the existing attachment projection
(`attachmentReadInputFields`) so chat-event files flow in without
custom plumbing (F3).

The six successor ids are new contracts, not aliases. They accept `noteRoot`
rather than `memoryRoot`, return `notebookId`/`noteId` rather than database
paths or integer record ids, and never dispatch through a `riela/memory-`
prefix. The persona pair intentionally retains `memoryMarkdown`,
`memoryGuidance`, `replyText`, and handoff flags because those are chat-node
data-flow contracts rather than storage compatibility. All other standalone
memory add-ons, including `riela/chat-memory-raw-daily-summary`, are removed.

The Slack, Telegram, and Discord trio examples remove every workflow/node
`memories` declaration and select `riela/note-persona-memory-read` or
`riela/note-persona-memory-write` through ordinary add-on configuration. Their
mock scenarios and node descriptions use note-root/notebook terminology.
`examples/chat-memory-raw-and-daily-summary` and its catalog reference are
deleted. Example-name and mock-count fixtures change in the same unit so
`RielaExampleParityTests` remains authoritative.

### Standalone memory removal boundary

Removal is deliberate and atomic across these seams:

- Delete `Packages/RielaMemory/` and all root `Package.swift` products,
  dependencies, and target links.
- Delete the `riela memory` route, models, option parsing, execution, injected
  runner, and help text under `Sources/RielaCLI/`; preserve workflow option
  parsing when splitting the mixed parser file.
- Delete memory adapter implementations and dispatch branches, including the
  `riela/memory-` prefix catch-all. Note-backed successors live with the Note
  add-on surface and depend on `RielaNote`, never `RielaMemory`.
- Delete `WorkflowMemoryScope`, `WorkflowMemoryDeclaration`, every authored or
  resolved `memories` field, tolerant decoding, memory validation, and runner
  resolution under `Sources/RielaCore/`. Repair shared runtime publication,
  persistence, prompt, fanout, failure, and test-support initializers rather
  than retaining empty placeholders.
- Delete memory-specific tests and the project fixture
  `.riela/workflows/riela-memory-design-impl-review/`; replace them with
  RielaNote/add-on coverage. Shared fixtures remain and lose only memory
  arguments/assertions.
- Never enumerate, migrate, rewrite, or delete `.riela/memory/`. After upgrade
  those files are inert operator-owned data; all new writes go to Riela Note.

Authored `memories` keys are no longer part of the workflow model. They follow
the runtime's ordinary unknown-field policy but never restore validation,
resolution, publication, or execution semantics. The three migrated examples
prove the supported path.

## Ingestion Use Cases (workflows, packaged as examples)

- **PDF import**: chat attachment event → existing OCR / page-imaging
  steps (already achievable per requirements memo) →
  `riela/notebook-ingest-pages`. Result: notebook = the book/PDF,
  note *n* = page *n* with markdown text + page image
  (`source-page-image`) + the original PDF on the notebook
  (`source-document`). Viewer can flip text ↔ page image per note.
- **YouTube transcript**: video URL in chat → existing download +
  transcription steps → `riela/note-create` with transcript markdown +
  `riela/note-attach-file` binding the saved video as a `related` file.
- **Quick memo**: short chat message → `riela/note-create` as a
  single-note notebook tagged `notebook-kind:user-memo` plus the always
  present tag `ノート`; auto-tagging then adds topical tags
  (`事業アイデア`, `哲学`, `ライフハック`, ...) with `provenance: ai`.

## GraphQL Surface

Extends `Sources/RielaGraphQL/` (F4) with a note domain module. Queries:
`note(noteId)`, `notebook(notebookId)`, `notebooks(limit, offset,
tagFilter)`, `notes(limit, offset, notebookId, tagFilter)`,
`searchNotes(query, tagFilter, classFilter, limit, offset)`, `tags`,
`tagClasses`, `noteFile(fileId)`, and `autoActions`. The authoritative
SDL lives in `Sources/RielaGraphQL/GraphQLContracts.swift` plus
`GraphQLNoteSchemaContract.swift`; this spec names the shipped surface
rather than duplicating field-by-field SDL.

Mutations: `createNotebook`, `createNote`, `defineNoteTagClass`,
`defineNoteTag`, `scaffoldNoteIngestionWorkflow`, `updateNote`,
`deleteNote`, `deleteNotebook`, `applyNotebookTags`,
`removeNotebookTag`, `setNotebookProgress`, `setNotebookReadOnly`,
`setNoteReadOnly`, `applyNoteTags`,
`removeNoteTag`, `addNoteComment`, `linkNotes`, `attachNoteFile`
(base64 with bounded decoded size for CLI-sized payloads),
`configureNoteAutoAction`, `deleteNoteAutoAction`,
`saveNoteConversation`, `migrateNoteFileStorage`, and
`migrateAllNoteFiles`. All mutations return either the existing
`GraphQLControlPlaneResult` envelope or a note-specific payload carrying
that envelope. Mutations execute through `NoteService`; this introduces
the first non-manager mutation path in `RielaGraphQL`, wired the same
way for CLI (`riela graphql`), server `/graphql`, and the library entry
points.

`NoteTag.parentTagId` and `Notebook.progress` are additive fields.
`defineNoteTag` accepts the optional parent relationship, while
`setNotebookProgress(notebookId, progress)` validates the four-value
enum before calling `NoteService`. Existing `tagFilter` query arguments
keep their public meaning and syntax; descendant expansion occurs in
the shared domain service. Authoritative `type Query` and
`type Mutation` SDL fields remain one line each because server contract
tests assert those strings.

`Notebook.readOnly` is additive in GraphQL DTOs and every notebook selection
used by CLI/web clients. `setNotebookReadOnly(notebookId, readOnly)` calls the
ordinary NoteService toggle and returns the canonical notebook. There is no
GraphQL field or input for privileged system writes.

## CLI Surface

New top-level family (F5 pattern): parser cases in
`Sources/RielaCLI/RielaCommand.swift`, runner
`NoteCommands.swift`, executing GraphQL documents against the local
note store (per requirement: note operations go through GraphQL).

```
riela note add        [--notebook <id>] [--title] [--body|--body-file|-]
                      [--tag <name>...] [--read-only]
riela note edit       <note-id> [--body|--body-file] [--append]
riela note show       <note-id> [--output json|text]
riela note list       [--notebook <id>] [--tag ...] [--limit]   # created desc
riela note search     <query> [--tag ...] [--class ...]
riela note tag        <note-id> --add <name>... | --remove <name>...
riela note comment    <note-id> --body <text>
riela note attach     <note-id> <file-path> [--role related|embedded]
riela note readonly   <note-id> --on|--off
riela note delete     <note-id> | --notebook <id>       # rejects read-only
riela note notebook   list|show|create|delete ...
riela note storage    migrate <file-id>|--all [--to s3 --profile <name>]
riela note client     register|list|revoke ...          # note API clients (Security)
```

The top-level `riela memory` family is deleted, including parser routes,
command models, runner injection, help text, and `RielaMemory` imports. No new
CLI compatibility command is added. Notebook lock/unlock is required through
GraphQL and the web workspace for this work package; a dedicated CLI spelling
is a follow-up only if user demand appears.

## Remote Note API and Auth (Security)

- Current shipped state: note GraphQL is available in-process and via
  the local CLI. `riela serve --note-api` does not yet bind a socket;
  any endpoint/QR URL produced by that path is a configuration
  descriptor, not a reachable remote API.
- `NoteAPIAuthenticating` protocol (in `RielaServer`): given
  `ServerRequestEnvelope` + `ServerRequestContext`, return an
  authenticated client identity or a rejection. Adapters are
  registered per server instance (D14). Google / Auth0 = future
  adapters; no work in v1 beyond the seam.
- **QR client registration design target**:
  1. Operator creates a one-time registration code (TTL ≤ 5 min,
     single use) and renders a QR encoding a configured registration
     URL.
  2. Client posts the code + display name; server issues a long-lived
     bearer token, stores only its sha256 in `api_clients`.
  3. Subsequent requests use `Authorization: Bearer <token>`; lookups
     update `last_seen_at`; `riela note client list|revoke` manage rows.
  - Codes and tokens are generated from a CSPRNG; token is shown once.
  - Default bind stays `127.0.0.1`; exposing on a VPN address requires
    an explicit `--host`. TLS is delegated to the VPN (Tailscale) in
    v1; document this assumption.
- All note mutations require an authenticated identity when arriving
  over the network; local in-process callers bypass adapter auth.

The shipped RielaApp same-origin workspace API adds
`POST /api/v1/notes/notebooks/{notebookId}/read-only` with JSON
`{ "readOnly": Bool, "expectedProfile": String? }`. It uses the existing
Host/Origin/CSRF/session and active-profile checks, calls
`NoteService.setNotebookReadOnly`, and returns the canonical notebook. Invalid
ids or bodies fail as `invalid_request`, missing notebooks as `not_found`, and
profile races as the existing conflict response. No REST route accepts a
system-write bypass.

## Note Agent and Note Config Agent

- **Note Agent** (chat screen): each user turn triggers a packaged
  workflow that (a) retrieves candidate notes via `riela/note-search`,
  (b) optionally performs web search through an agent worker (codex
  agent, existing backends), and (c) answers with citations carrying
  `note_id`s so the UI renders tappable links to source notes.
  Conversation persistence follows D12: auto-save to an
  `agent-conversation` notebook by default; a temp-chat toggle defers
  materialization until an explicit Save action.
- **Note Config Agent** (separate screen): an agent-worker-backed chat
  that edits Riela Note configuration — proposes tag classes/tags,
  creates or adjusts auto-action workflows, and configures ingestion
  workflows. It operates exclusively through the note GraphQL mutations
  and workflow-authoring surfaces (no direct DB access), mirroring the
  existing RielaApp assistant pattern.

## UI Design (RielaNoteUI + RielaApp)

New SwiftUI target `Sources/RielaNoteUI/` (D15), compact-first layout
(iPhone width) that expands to split-view on regular widths (iPad/Mac):

- **Notebook list** (home): sorted by registration date desc (default),
  each row shows notebook title, kind tag chip, and the leading snippet
  of the first note; pull-in search field filters by FTS + tags. Rows
  also show the typed progress state.
- **Per-tag Kanban**: when a tag filter is active, the same
  descendant-inclusive notebook result set can be presented in fixed
  `none`, `progress`, `done`, and `pending` groups. Changing a
  notebook's group calls `setNotebookProgress`; filtering and grouping
  remain separate operations. This is a minimal grouped presentation,
  not a general board designer or folder tree.
- **Note view**: rendered markdown; when the note has a
  `source-page-image`, a one-tap segmented toggle switches text ↔ page
  image (fast, preloaded); related files strip (images/video/audio);
  tag chips visually distinguishing human / AI / system provenance;
  comments section; linked-notes section. Read-only notes show a lock
  and disable body editing while keeping tag/comment actions.
- **Note agent** and **Note config agent** chat screens (message list +
  input bar + citation links; temp-chat toggle and Save button).
- Design principle from requirements: minimal chrome, browsing and
  search must feel light.

The SolidJS web Notes workspace also projects `Notebook.readOnly`. A
system-memory notebook is detected by `notebook-kind:system-memory`, shows a
locked state, and disables content editing/creation controls while locked.
Unlock calls the persisted REST mutation and replaces local state only with
the returned notebook; failure leaves the notebook locked and visible error
handling unchanged. After unlock, the same location shows Lock. Ordinary
notebooks do not gain extra lock chrome in this work package.

RielaApp integration: a "Notes" window (new window controller hosting
`NSHostingController(rootView:)`), menu/status-bar entry, profile-aware
note root, and the note-API exposure toggle in settings. iPhone/iPad
apps are explicitly out of scope; `RielaNoteUI` must compile for iOS
without RielaApp/AppKit imports.

## Gaps in Riela Core Closed by This Design

- First mutation-capable GraphQL domain (F4 read-only today).
- File storage abstraction with S3-compatible backend (none today).
- Server-side pluggable auth + client registry (only pass-through
  bearer context today, item 9 of the architecture survey).
- SwiftUI hosting boundary in RielaApp (AppKit-only today).
- FTS5 usage in the SQLite layer (JSONB-only today) — requires a
  capability probe in `SQLiteOpenOptions` analogous to `requireJSONB`.
- The memory fold removes a second persistence/search/attachment/schema
  surface and makes Riela Note the sole new-write knowledge substrate. The
  broader hub gap-and-waste ranking is recorded separately in
  `docs/briefs/note-hub-gap-and-waste-2026-08-01.md` before implementation.

## Non-Goals / Boundaries

- iPhone/iPad client apps (UI portability only, D15).
- Google/Auth0 authentication implementations (seam only, D14).
- Embedding/vector RAG (schema-compatible follow-up, D13).
- Turso/libSQL sync driver (follow-up behind `NoteDatabaseDriving`, D2).
- OCR / page imaging / video download / transcription internals —
  consumed as existing workflow capabilities, not (re)designed here.
- Note version history (revisions) — `updated_at` only in v1; a
  `note_revisions` table is a compatible future addition.
- Importing, converting, deleting, or otherwise modifying existing
  `.riela/memory/` data.
- Compatibility aliases for `riela memory`, `riela/memory-*`,
  `riela/chat-persona-memory-*`, or workflow `memories` fields.
- Changes to event sources, package management, Kanban, graph-RAG, or workflow
  runtime behavior beyond removing the memory schema and execution surface.

## Acceptance Traceability

| Requirement (riela-note-design.md) | Design owner |
| --- | --- |
| note/notebook, page-per-note, markdown, single note = notebook | Data Model, D3/D4 |
| comments, related files, related notes, title from `#` header | Data Model, D4/D5 |
| tags bound to world-model classes; AI vs human tags separated | D6/D7, note_tags.provenance |
| parent/child tags and descendant-inclusive filters | D16/D17, Hierarchy filtering |
| folder-class notebook organization | D18, notebook_tags |
| typed notebook progress and per-tag Kanban | D19, GraphQL Surface, UI Design |
| read-only notes still taggable/commentable | D5 |
| note edit/get as workflow node built-in add-ons | Built-in Note Add-ons |
| PDF → notebook (pages, page images, source PDF) | notebook-ingest-pages, PDF use case |
| YouTube transcript note + video as related file | YouTube use case |
| local / s3-compatible file storage, per-file kind, bulk migration | D8, File Storage |
| post-create auto operations via workflows (default tagging) | D11, auto_actions |
| list default sort registration-desc + first-note preview | NoteService.listNotebooks, UI |
| note agent (local search, citation links, conversation-as-notebook, temp chat; vector/web RAG follow-up) | D12/D13, Note Agent |
| simple browse/search-first UI | UI Design |
| SQLite (Turso SDK) | D2 (driver seam; libsql follow-up) |
| `riela note` CLI via GraphQL | CLI Surface, GraphQL Surface |
| Mac app with iPhone/iPad-portable design | D15, UI Design |
| optional note API exposure, switchable auth, QR registration, VPN assumption | D14, Security |
| notebook kinds as non-deletable tags | D3, notebook_tags |
| note config agent screen | Note Config Agent |
| default read-only system-memory notebook | D20-D23, Schema-v6 bootstrap, UI Design |
| memory record concepts map onto Note | D24, Memory-to-note field mapping, Built-in Note Add-ons |
| standalone memory package/CLI/schema/add-ons removed without data deletion | D24, CLI Surface, Non-Goals |
| trio-chat examples remain note-backed and parity checked | Built-in Note Add-ons |
| persisted web unlock with no public bypass | D22/D23, GraphQL Surface, Remote Note API, UI Design |

## Verification

- `swift build` / `swift test` including new `RielaNoteTests`,
  `RielaNoteUI` compile check for iOS-compatible targets.
- Schema-v4 migration: migrate a version-3 database, assert nullable
  parent tags and `none` progress for existing notebooks, compare with a
  fresh database, and reject invalid progress values.
- Hierarchy behavior: parent/child/grandchild fixtures for note and
  notebook list/search paths; assert parent transitivity, child scope,
  leaf compatibility, unknown-name behavior, and cycle rejection.
- GraphQL behavior: assert `parentTagId`, `progress`,
  `setNotebookProgress`, folder-class notebook tagging, and
  descendant-inclusive `tagFilter` while preserving one-line SDL
  contract assertions.
- CLI round-trip: `riela note add` → `list` → `search` → `attach` →
  `storage migrate --all` against a temp note root.
- Workflow round-trip: run packaged quick-memo and pdf-ingest example
  workflows with mock scenarios; assert notebook/note/tag/file rows.
- GraphQL parity: same mutation documents via `riela graphql` and via
  `riela serve` HTTP endpoint (with and without `--note-api`).
- Auth: registration-code TTL/single-use tests; revoked client rejected.
- Schema-v6 behavior: fresh and migrated stores expose notebook `readOnly`,
  preserve existing notebooks/data, create exactly one locked system-memory
  notebook, and preserve a persisted unlock across reopen.
- Read-only behavior: ordinary content mutations fail with
  `NoteServiceError.readOnly`; tags/comments/links/progress remain usable;
  typed system-memory writes succeed while locked and cannot target another
  notebook; ordinary unlocked writes retain auto-action behavior.
- GraphQL/REST/web behavior: notebook DTOs include `readOnly`, both lock
  mutations persist, the web Unlock/Lock control follows the canonical
  response, and no public bypass input exists.
- Add-on behavior: all six note-memory successor ids cover save/update/load/
  search and persona read/write, attachment/provenance mapping, bounded reads,
  locked system writes, and preservation of reply/handoff contracts.
- Required implementation gate:

  ```bash
  swift build
  swift test --filter RielaNoteTests
  swift test --filter RielaCLITests
  swift test --filter RielaCoreTests
  riela workflow validate examples/slack-agent-trio-chat
  riela workflow validate examples/telegram-agent-trio-chat
  riela workflow validate examples/discord-agent-trio-chat
  cd web && bun run build
  cd web && bun test src
  rg -n 'RielaMemory|riela/memory-|WorkflowMemoryDeclaration|memories:' --glob '!docs/**' --glob '!design-docs/**' .
  git diff --check
  git branch --show-current
  git status --short
  ```

  The deletion audit must return no production/example/test references. A
  known unrelated full-suite interleaved-submit timing flake is not an excuse
  for failure in the required filtered suites.

Implementation plan: `impl-plans/active/riela-note.md`.

## Post-Implementation Review

The implemented branch (`feature/riela-note`) was reviewed on
2026-07-04; findings, spec deviations, user-perspective UI/UX gap
analysis, and a prioritized remediation plan are recorded in
`design-docs/specs/design-riela-note-review-improvements.md`.
