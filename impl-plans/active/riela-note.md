# Riela Note Implementation Plan

**Status**: Partially implemented. **Remaining-work reconciliation
(2026-07-12, W8):** the shipped scope (local note store, CLI/GraphQL/App
surfaces, note agent with cited answers, auto-action loop) is implemented
and tested; the prose follow-ups are now enumerated below as explicit
accepted deferrals so completion stays measurable:

- **DEFERRED** Real libsql embedded-replica/sync execution and parity
  (TASK-015 is stubbed: driver fails fast for `.embeddedReplica`). Owner:
  next riela-note session; trigger: Turso/libsql sync becomes a user
  requirement (gated test recipe recorded at the bottom of this plan).
- **DEFERRED** Remote note listener/socket and HTTP registration paths
  beyond the local serve surface. Owner: next riela-note session; trigger:
  a remote client (second machine / RielaApp remote mode) needs note sync.
- **DEFERRED** Vector/embedding retrieval, multi-source RAG, and web-search
  behavior for the note agent (current agent answers from local note
  retrieval with citations). Owner: next riela-note session; trigger:
  adoption decision on retrieval quality (relates to the Hermes H-B/H-C
  decision set).

No other open work remains in this plan; it stays active only as the home
for these three named deferrals.
**Design Reference**: design-docs/specs/design-riela-note.md
**Created**: 2026-07-04
**Last Updated**: 2026-07-04

## Summary

Implement Riela Note: an ontology-oriented note/notebook store on SQLite
with provenance-aware tags, local/S3 file attachments, built-in workflow
add-ons for note operations, a note GraphQL domain (first mutation
surface), a `riela note` CLI family, auto-action workflow dispatch,
packaged ingestion/agent workflows, local note API client management and
auth building blocks, and an iPad-portable SwiftUI UI hosted by
RielaApp. A real remote note socket and libsql sync driver remain
follow-up work.

## Source References

- Design: `design-docs/specs/design-riela-note.md` (decisions D1–D15)
- Requirements memo: `design-docs/riela-note-design.md`
- Code precedents:
  - `Sources/RielaSQLite/SQLiteDatabase.swift` (driver base)
  - `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
    (schema/upsert precedent)
  - `Sources/RielaCLI/ProductionNodeAdapter.swift` (built-in add-on
    dispatch, `riela/memory-*` family)
  - `Sources/RielaGraphQL/GraphQLContracts.swift`,
    `Sources/RielaGraphQL/RielaGraphQL.swift` (DTO/service pattern)
  - `Sources/RielaServer/` (`ServerRequestContext`, route handling)
  - `Sources/RielaCLI/RielaCommand.swift`,
    `Sources/RielaCLI/RielaCLIApplication.swift` (command registration)
  - `Sources/RielaApp/EntryPoint.swift`, window controllers (hosting)

## Scope

**Included**: `RielaNote` target (schema, store, `NoteService`, file
stores, FTS search), `RielaNoteUI` target, note built-in add-ons, note
GraphQL queries + mutations, `riela note` CLI, auto-action dispatch,
packaged example workflows (quick memo, pdf ingest, youtube transcript,
note agent, auto-tagging), note API auth/client-management building
blocks,
RielaApp Notes window + agent/config-agent screens.

**Excluded** (per design Non-Goals): iPhone/iPad apps, Google/Auth0
adapters, vector/embedding RAG, real remote note socket, Turso/libsql
embedded-replica sync driver, OCR/transcription internals, note
revision history.

## Task Breakdown

### TASK-001: RielaNote target — schema and store foundation
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Package.swift` (new `RielaNote` target + `RielaNoteTests`)
- `Sources/RielaNote/NoteDatabaseDriving.swift`
- `Sources/RielaNote/SQLiteNoteDatabaseDriver.swift`
- `Sources/RielaNote/NoteStoreSchema.swift` (tables, seeds,
  `note_schema_version` migrations)
- `Sources/RielaNote/NoteModels.swift` (Notebook, Note, Tag, TagClass,
  TagAssignment/provenance, FileRecord, Comment, Link, AutoAction)
- `Sources/RielaSQLite/SQLiteDatabase.swift` (FTS5 capability probe in
  `SQLiteOpenOptions`, analogous to `requireJSONB`)
- `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`

**Work**:
- Create target depending on `RielaSQLite` only; implement the driver
  seam (D2) over `SQLiteDatabase` with WAL/busy-timeout/JSONB options.
- Create all tables from the design's Data Model section (including
  locator CHECK on `files` and `note_fts_map`), seed system tag
  classes, notebook-kind system tags, and the default AI-tagging
  `auto_actions` rows (`note-created` and `note-updated`). The seeded
  rows reference the TASK-008 packaged workflow id and stay inert
  (skip-with-diagnostic at dispatch) until that workflow is installed —
  no enable/disable flip needed.
- Add the FTS5 capability probe and the contentless `note_fts` table +
  `note_fts_map`.

**Completion criteria**:
- Fresh open creates schema + seeds idempotently; version table gates
  future migrations; FTS probe fails with a clear diagnostic when
  sqlite lacks FTS5.

### TASK-002: NoteService core (CRUD, tags, links, comments, search)
**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNote/NoteService.swift`
- `Sources/RielaNote/NoteSearch.swift`
- `Tests/RielaNoteTests/NoteServiceTests.swift`
- `Tests/RielaNoteTests/NoteSearchTests.swift`

**Work**:
- Implement notebook/note CRUD with title derivation from the first
  `# ` heading (D4), read-only enforcement (D5), single-note-notebook
  creation path (D3), `listNotebooks` created-desc with first-note
  preview snippet.
- Tag operations enforcing provenance rules (D6): non-deletable guard,
  AI may not remove/overwrite human assignments; tag-class binding (D7).
- Links, comments (allowed on read-only), FTS-backed
  `searchNotes(query, tagFilter, classFilter, limit)` with contentless
  FTS maintenance (delete-command insert + re-insert) inside the write
  transaction.
- `note_number` allocation (`max + 1` in the notebook's write
  transaction) and transactional delete cascades per the design's
  write-semantics rules (bindings + FTS removed; `files` rows retained;
  read-only content rejects deletion).

**Completion criteria**:
- Provenance/read-only/system-tag/deletion rules covered by tests; FTS
  returns ranked snippets and stays consistent after edits/deletes; all
  consumers can operate through `NoteService` only.

### TASK-003: File stores (local + S3) and migration
**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNote/NoteFileStore.swift` (protocol + locator model)
- `Sources/RielaNote/LocalNoteFileStore.swift`
- `Sources/RielaNote/S3NoteFileStore.swift` (SigV4 signed HTTP, storage
  profiles; no AWS SDK)
- `Sources/RielaNote/NoteFileMigration.swift`
- `Tests/RielaNoteTests/NoteFileStoreTests.swift`

**Work**:
- Local store with fan-out layout, atomic writes, sha256 verification;
  attach/resolve APIs on `NoteService` (roles: embedded / related /
  source-page-image / source-document).
- S3-compatible backend against named storage profiles (endpoint,
  region, bucket, credential env refs) from note settings.
- Single-file and `migrateAll` local→S3 migration with verify-then-
  switch locator update, per-file error accumulation (D8).

**Completion criteria**:
- Mixed local/S3 attachments resolve transparently; migration is
  verified-copy-then-delete; S3 tests run against a stub HTTP server.

### TASK-004: Auto-action dispatch
**Status**: COMPLETED
**Depends On**: TASK-002
**Deliverables**:
- `Sources/RielaNote/AutoActionDispatching.swift` (protocol)
- `Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`
  (runtime adapter wiring note triggers to workflow execution through
  existing workflow resolution and `WorkflowRunCommand`)
- `Tests/RielaNoteTests/AutoActionTests.swift`
- `Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift`

**Work**:
- After-commit trigger evaluation (`note-created`, `note-updated`,
  `notebook-created`) with tag/kind filter matching; non-blocking,
  at-least-once dispatch carrying note id + content snapshot as
  workflow input (D11).
- Loop guard: `note-updated` fires on body writes only; writes carrying
  an originating action id are excluded from re-dispatch for the same
  note. Unresolved workflow ids are skipped with a diagnostic (keeps
  seeded actions inert until TASK-008 installs the workflow).

**Completion criteria**:
- Matching rows dispatch exactly the configured workflows; failures are
  diagnosed without failing the originating write; loop-guard and
  unresolved-workflow-skip behavior covered by tests.

### TASK-005: Built-in note add-ons
**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003
**Deliverables**:
- Handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` (or an
  extracted `NoteAddons` file beside it) for: `riela/note-create`,
  `riela/note-update`, `riela/note-get`, `riela/note-search`,
  `riela/note-tag-apply`, `riela/note-attach-file`,
  `riela/note-comment-add`, `riela/notebook-ingest-pages`,
  `riela/note-conversation-save`
- Add-on validation/catalog entries in `Sources/RielaAddons/`
- `Tests/RielaCLITests/NoteAddonTests.swift`

**Work**:
- Implement each add-on over `NoteService`; project event attachments
  via `attachmentReadInputFields`; note root resolved from runtime
  environment (user scope default, D9).
- `notebook-ingest-pages` batch contract per design (pages[],
  sourceDocumentRef, kind tag `imported-material`).

**Completion criteria**:
- Each add-on validated + executable in deterministic mock runs;
  outputs use `candidatePayload` with note ids for downstream steps.

### TASK-006: Note GraphQL domain (queries + mutations)
**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003
**Deliverables**:
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift` (DTOs)
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- Server route wiring in `Sources/RielaServer/`
- `Tests/RielaGraphQLTests/NoteGraphQLTests.swift`

**Work**:
- Queries: note, notebook, notebooks (created-desc + preview),
  searchNotes, tags, tagClasses, noteFile, autoActions.
- Mutations per design (create/update/delete/readonly/tags/comment/
  link/attach/migrate/configureAutoAction/saveConversation) returning
  `GraphQLControlPlaneResult` envelopes; execution through
  `NoteService` (first non-manager mutation path).

**Completion criteria**:
- Same documents succeed via library execution and via server
  `/graphql`; mutation guard failures surface as diagnostics, not
  transport errors.

### TASK-007: `riela note` CLI family
**Status**: COMPLETED
**Depends On**: TASK-006
**Deliverables**:
- Parser cases in `Sources/RielaCLI/RielaCommand.swift` +
  `RielaArgumentParserHelpers.swift`
- `Sources/RielaCLI/NoteCommands.swift`
- Wiring in `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCLITests/NoteCommandTests.swift`

**Work**:
- Subcommands: add, edit, show, delete, list, search, tag, comment,
  attach, readonly, notebook (list/show/create/delete), storage
  migrate, client (register/list/revoke), `--note-root` override,
  `--output json|text`.
- Execute through GraphQL documents against the local note store (per
  requirement), matching existing output-format conventions.

**Completion criteria**:
- CLI round-trip test: add → list → search → attach → storage migrate
  against a temp note root.

### TASK-008: Packaged workflows (ingestion + auto-tagging)
**Status**: COMPLETED
**Depends On**: TASK-005
**Deliverables**:
- Example workflow bundles: `note-auto-tagging`,
  `note-quick-memo`, `note-pdf-ingest`, `note-youtube-transcript`
  (under `examples/` following existing bundle layout)
- Mock scenarios + `EXPECTED_RESULTS.md` per bundle
- `Tests/RielaCLITests/NoteWorkflowExampleTests.swift`

**Work**:
- Auto-tagging: agent worker proposes tags from note body →
  `riela/note-tag-apply` (provenance ai); enable the seeded default
  auto-action.
- Quick memo: chat event → `riela/note-create` (kind user-memo, fixed
  tag `ノート`).
- PDF ingest: OCR/page-image steps (existing capability) →
  `riela/notebook-ingest-pages`; YouTube: transcript →
  `riela/note-create` + `riela/note-attach-file` (related video).

**Completion criteria**:
- All bundles pass `workflow validate` and deterministic mock runs
  asserting created notebook/note/tag/file rows.

### TASK-009: Note API exposure + QR client registration auth
**Status**: PARTIAL
**Depends On**: TASK-006
**Deliverables**:
- `Sources/RielaServer/NoteAPIAuthenticating.swift` (protocol +
  registry)
- `Sources/RielaServer/QRClientRegistrationAuthenticator.swift`
- Registration route + `api_clients` persistence (store in RielaNote)
- CLI: `riela serve --note-api` dry-run/config descriptor,
  `riela note client register|list|revoke`
- `Tests/RielaServerTests/NoteAPIAuthTests.swift` (or existing server
  test suite location)

**Work**:
- Opt-in mount of the note GraphQL surface; network mutations require
  authenticated identity; in-process/local CLI bypasses adapter auth.
- One-time registration codes (CSPRNG, TTL ≤ 5 min, single use), QR
  rendering (terminal + app), bearer tokens stored as sha256, revocation
  and `last_seen_at` (D14, Security section).

**Completion criteria**:
- Local route/auth units reject unauthenticated requests, accept
  registered clients, reject revoked clients, and cover TTL/single-use
  codes. Not complete for remote exposure: `riela serve --note-api`
  does not bind a socket, so an end-to-end HTTP QR registration flow
  remains future work.

### TASK-010: RielaNoteUI SwiftUI module
**Status**: COMPLETED
**Depends On**: TASK-002 (models), TASK-003 (file resolution)
**Deliverables**:
- `Package.swift` target `RielaNoteUI` (SwiftUI, no AppKit imports)
- Views: notebook list (created-desc, first-note preview, search),
  note view (markdown render, text ↔ source-page-image toggle,
  related-files strip, provenance-distinct tag chips, comments,
  linked notes, read-only lock)
- View models bridging `NoteService` via a client protocol so remote
  (GraphQL) backing can substitute later

**Work**:
- Compact-first adaptive layout (iPhone width → split view on regular),
  per D15; keep chrome minimal per requirements.

**Completion criteria**:
- Module compiles for macOS and iOS destinations; previews/tests for
  list + note view; image/text switch works with local and S3-cached
  files.

### TASK-011: RielaApp Notes window + settings integration
**Status**: COMPLETED
**Depends On**: TASK-010, TASK-009 (settings toggle)
**Deliverables**:
- `Sources/RielaApp/NoteWindowController.swift`
  (`NSHostingController` hosting RielaNoteUI)
- Status-bar/menu entry; profile-aware note root
  (`~/.riela/profiles/<profile>/note/`)
- Settings: note API exposure toggle + client management

**Completion criteria**:
- Notes window opens from the status-bar app, browses/searches/edits
  notes against the active profile's note root.

### TASK-012: Note Agent (RAG chat) and conversation persistence
**Status**: PARTIAL
**Depends On**: TASK-005, TASK-008, TASK-010
**Deliverables**:
- Packaged `note-agent` workflow (retrieve via `riela/note-search` →
  cited answer; web/vector retrieval remains follow-up)
- `RielaNoteUI` chat screen (citations deep-link to notes; temp-chat
  toggle + explicit Save)
- Conversation persistence through `riela/note-conversation-save` /
  `NoteService.appendConversationTurn` + `saveConversation(transcript)`
  (temp-chat transcripts held by the caller, never staged in the store)

**Completion criteria**:
- Current local UI/service flow produces an answer with `note_id`
  citations resolvable in the UI; default auto-save creates an
  `agent-conversation` notebook; temp chat persists nothing until Save.
  Full RAG/web-search behavior remains follow-up.

### TASK-013: Note Config Agent screen
**Status**: COMPLETED
**Depends On**: TASK-012
**Deliverables**:
- Dedicated `RielaNoteUI` config-agent screen wired to an agent-worker
  workflow that manipulates tags/classes/auto-actions through note
  GraphQL mutations and workflow authoring surfaces only

**Completion criteria**:
- Config agent can define a tag class, adjust the auto-tagging action,
  and scaffold an ingestion workflow, all auditable as mutations.

### TASK-014: Documentation and registration
**Status**: COMPLETED
**Depends On**: TASK-007
**Deliverables**:
- README/command docs for `riela note` and `--note-api`
- `impl-plans/README.md` row maintenance; progress log entries here

### TASK-015 (optional): Turso libsql-swift driver
**Status**: EXPERIMENTAL / PARTIAL
**Depends On**: TASK-001
**Deliverables**:
- `RielaNoteLibSQL` target and `LibSQLNoteDatabaseDriver` shape behind
  `NoteDatabaseDriving`, dependency gated so non-note targets are
  unaffected. The shipped driver uses plain SQLite for `.local` and
  fails fast for `.embeddedReplica`; no libsql SQL execution or sync is
  implemented yet.

**Completion criteria**:
- Default SQLite note tests pass. Full libsql embedded-replica/sync test
  parity is not complete.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-002 | TASK-001 | store/schema foundation |
| TASK-003 | TASK-001 | file records in schema |
| TASK-004 | TASK-002 | dispatch fires on service writes |
| TASK-005 | TASK-002, TASK-003 | add-ons call service + file store |
| TASK-006 | TASK-002, TASK-003 | GraphQL executes through service |
| TASK-007 | TASK-006 | CLI goes through GraphQL |
| TASK-008 | TASK-005 | workflows use note add-ons |
| TASK-009 | TASK-006 | exposes the GraphQL surface |
| TASK-010 | TASK-002, TASK-003 | UI reads models/files |
| TASK-011 | TASK-010, TASK-009 | hosts UI, settings toggle |
| TASK-012 | TASK-005, TASK-008, TASK-010 | agent workflow + chat UI |
| TASK-013 | TASK-012 | builds on agent surfaces |
| TASK-014 | TASK-007 | documents shipped surfaces |
| TASK-015 | TASK-001 | driver seam |

## Parallelization

- After TASK-001: TASK-002 and TASK-003 in parallel.
- After TASK-002/003: TASK-004, TASK-005, TASK-006, TASK-010 in
  parallel (distinct modules).
- TASK-007/TASK-009 (CLI/server) parallel after TASK-006; TASK-008
  parallel with them after TASK-005.
- UI track (TASK-010 → 011 → 012 → 013) is independent of the
  CLI/server track after the service layer lands.

## Verification

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
swift test                       # full suite before completion
swiftlint
git diff --check
```

Plus design-doc verification items: CLI round-trip, packaged-workflow
mock runs, GraphQL parity (library vs server), auth TTL/revocation.

## Completion Criteria

- [x] All non-optional tasks COMPLETED with tests
- [x] Quick-memo, pdf-ingest, youtube, auto-tagging, note-agent bundles
      pass deterministic mock verification
- [x] `riela note` CLI + GraphQL + add-ons all mutate through
      `NoteService` (no duplicate write paths)
- [~] Note API disabled by default; local auth/client persistence exists,
  but `riela serve --note-api` does not bind a remote socket and
  end-to-end QR registration over HTTP remains follow-up work.
- [x] RielaNoteUI compiles for iOS destination with no AppKit imports
- [x] Acceptance Traceability table in the design doc fully satisfied

## Progress Log Expectations

Each implementation session must append: tasks completed / in progress,
files changed, tests added or updated, verification commands run with
results, and limitations or follow-ups.

### Session: 2026-07-04 Plan authored

**Tasks Completed**: — (planning)
**Notes**: Design spec `design-docs/specs/design-riela-note.md` created
from `design-docs/riela-note-design.md`; task breakdown and dependency
map established. Implementation not started.

### Session: 2026-07-04 Self-review pass

**Tasks Completed**: — (planning refinement)
**Notes**: Fixed cross-task references (auto-tagging workflow is
TASK-008, experimental libsql target is TASK-015); added auto-action loop
guard and note-updated trigger semantics; seeded AI-tagging actions now
cover create+update and are inert-until-installed instead of
enable-flipped; added delete to CLI/GraphQL surfaces and delete/FTS
write semantics to the store tasks; clarified temp-chat transcripts are
caller-held (no store staging); moved the FTS5 probe into TASK-001
deliverables (`Sources/RielaSQLite/SQLiteDatabase.swift`).

### Session: 2026-07-04 Implementation slice 1

**Tasks Completed**: TASK-001
**Tasks In Progress**: TASK-002
**Files Changed**: `Package.swift`,
`Sources/RielaSQLite/SQLiteDatabase.swift`,
`Sources/RielaNote/NoteDatabaseDriving.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaNoteTests/NoteStoreSchemaTests.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(7 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the `RielaNote` target and `RielaNoteTests`; added
SQLite FTS5 capability probing; implemented schema creation, version
table, FTS tables, system tag-class/notebook-kind/default auto-action
seeds, and file locator constraints. Added initial `NoteService`
behavior for notebook/note CRUD, title derivation, created-desc notebook
listing with first-note preview, read-only edit/delete rejection,
comment/tag allowance on read-only notes, provenance-protected tag
application/removal, service-managed delete cascades, and FTS search
maintenance after create/update/tag/delete. Remaining work after this
slice was tracked under TASK-002 until completed by the following
implementation slice.

### Session: 2026-07-04 Implementation slice 2

**Tasks Completed**: TASK-002
**Tasks In Progress**: TASK-003
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Relations.swift`,
`Sources/RielaNote/NoteFileStore.swift`,
`Sources/RielaNote/LocalNoteFileStore.swift`,
`Sources/RielaNote/NoteService+Files.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`,
`Tests/RielaNoteTests/NoteFileStoreTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(13 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Completed TASK-002 by adding `NoteSearch.swift`, explicit
note-to-note link APIs, comment listing, and conversation persistence
(`appendConversationTurn` / `saveConversation`) that creates an
`agent-conversation` notebook and system citation links. Started
TASK-003 with `NoteFileStore`, `LocalNoteFileStore`, and NoteService
attach/list/resolve APIs for note files and notebook source documents.
Local writes use fan-out storage under `<note-root>/files/`, SHA-256
metadata, verified reads, and tests for note deletion preserving file
records/content. Remaining TASK-003 work: S3-compatible store,
local-to-S3 single/bulk migration, storage profiles, and stub HTTP
verification.

### Session: 2026-07-04 Implementation slice 3

**Tasks Completed**: —
**Tasks In Progress**: TASK-003, TASK-004
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteFileStore.swift`,
`Sources/RielaNote/S3NoteFileStore.swift`,
`Sources/RielaNote/NoteFileMigration.swift`,
`Sources/RielaNote/NoteService+Files.swift`,
`Sources/RielaNote/AutoActionDispatching.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaNoteTests/NoteFileStoreTests.swift`,
`Tests/RielaNoteTests/AutoActionTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(18 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Added S3-compatible storage profiles, environment-backed
credential loading, SigV4 signed path-style S3 PUT/GET/DELETE over an
injectable HTTP client plus URLSession-backed default client, mixed
local/S3 `resolveFileContent`, and single/bulk local-to-S3 migration
that copies, verifies by reading back, switches the SQLite locator, and
then deletes the old local object. Started TASK-004 by
adding `AutoActionDispatching`, list/configure auto-action APIs, and
after-commit dispatch from notebook creation, note creation, and body
updates. Dispatch failures are non-blocking and `originatingActionId`
skips same-action note-update loops. Remaining TASK-004 work after this
slice was unresolved-workflow diagnostics and runtime adapter wiring to
actual workflow execution.

### Session: 2026-07-04 Implementation slice 4

**Tasks Completed**: TASK-003
**Tasks In Progress**: TASK-004
**Files Changed**: `Tests/RielaNoteTests/NoteFileStoreTests.swift`,
`Sources/RielaNote/AutoActionDispatching.swift`,
`Tests/RielaNoteTests/AutoActionTests.swift`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(21 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Added a test-only localhost S3 HTTP stub using
`Network.NWListener`, exercising the production `URLSessionS3HTTPClient`
over HTTP for migration and mixed S3 resolution. This closes TASK-003's
stub HTTP verification requirement. Added TASK-004 filter matching for
auto-actions with JSON filters (`noteTags`, `notebookKindTag`) and
tests proving tag/kind filters restrict dispatch. Remaining TASK-004
work: runtime adapter wiring to actual workflow execution and
unresolved-workflow diagnostics at the composition boundary.

### Session: 2026-07-04 Implementation slice 5

**Tasks Completed**: TASK-005
**Tasks In Progress**: TASK-004
**Files Changed**: `Package.swift`,
`Sources/RielaCLI/ProductionNodeAdapter.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`,
`Sources/RielaAddons/RielaAddons.swift`,
`Tests/RielaCLITests/NoteAddonTests.swift`,
`Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(21 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Implemented built-in note add-ons over `NoteService`:
`riela/note-create`, `riela/note-update`, `riela/note-get`,
`riela/note-search`, `riela/note-tag-apply`,
`riela/note-attach-file`, `riela/note-comment-add`,
`riela/notebook-ingest-pages`, and
`riela/note-conversation-save`. Note root resolution now supports
`addon.config.noteRoot`, rendered add-on variables, workflow input,
`RIELA_NOTE_ROOT`, and default `~/.riela/note`. Outputs expose note
ids both top-level and under `candidatePayload`. Added RielaAddons
built-in catalog descriptors for the note add-ons and deterministic CLI
tests covering create/search/tag/comment/get, projected attachment
storage, page ingestion, and conversation citation links. The line-count
audit still reports pre-existing over-1000-line files outside this
slice; changed files remain below 1000 lines.

### Session: 2026-07-04 Implementation slice 6

**Tasks Completed**: —
**Tasks In Progress**: TASK-004, TASK-006
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests/testGraphQLRouteValidatesEnvelopeAndPropagatesContext`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added Note GraphQL DTOs, a `GraphQLNoteGraphQLService`
facade over `NoteService`, tag/tag-class catalog APIs, schema contract
entries for note queries/mutations, and server route coverage proving
the `/graphql` delegated schema exposes the note domain. Library-level
tests cover create/search/tag/read-only rejection, attachment,
conversation citation persistence, and auto-action configuration.

## Implementation slice 6b

**Date**: 2026-07-04
**Task**: TASK-006 completion
**Status**: Completed
**Files**:
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaServer/ServerContracts.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`Package.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests/testGraphQLRouteExecutesNoteDocumentsWhenExecutorIsConfigured`,
and
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests`.
**Notes**: Added a deterministic Note GraphQL document executor for
note/notebook queries and create/update/delete/readonly/tag/comment/
link/attach/configure-auto-action/save-conversation/migrate-file/
migrate-all mutations. Server `/graphql` now executes Note documents
when an executor is configured, while preserving the existing delegated
schema response when no executor handles the document. Server tests
prove create/search round trips and read-only mutation rejection returns
GraphQL diagnostics with HTTP 200 rather than a transport error.

## Implementation slice 7

**Date**: 2026-07-04
**Task**: TASK-007 partial implementation
**Status**: Completed CLI parser/wiring, core note commands, and storage
migration command; TASK-007 remains in progress.
**Files**:
`Sources/RielaCLI/RielaCommand.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`,
`Sources/RielaCLI/RielaArgumentParserHelpers.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteCommandTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the top-level `riela note` parser scope, CLI help,
application dispatch, and a `NoteCommandRunner` for `add`, `edit`,
`show`, `delete`, `list`, `search`, `tag`, `comment`, `attach`,
`readonly`, `notebook list/create/show/delete`, and
`storage migrate`. Commands resolve `--note-root`, `RIELA_NOTE_ROOT`,
or `~/.riela/note`, follow existing output-format conventions, and use
the `GraphQLNoteGraphQLService` facade over the local note store for
note mutations/queries. Storage migration uses the public S3 migration
API with credential environment variable names. Client
register/list/revoke was completed in implementation slice 10. Remaining
TASK-007 work is replacing facade calls with actual GraphQL document
execution once TASK-006's HTTP/library execution path is complete.

## Implementation slice 8

**Date**: 2026-07-04
**Task**: TASK-004 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`,
`Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAutoActionWorkflowDispatcherTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAutoActionWorkflowDispatcherTests --filter NoteCommandTests --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added a production auto-action workflow dispatcher that
preflights configured workflow ids with the filesystem workflow
resolver, skips unresolved workflow ids with diagnostics, launches
resolved workflows asynchronously through `WorkflowRunCommand`, and
records workflow-run failures without failing the originating note
write. Dispatch variables include the trigger event, auto-action
metadata, note id/body snapshot, `originatingActionId` for loop
guards, and `noteRoot` so note add-ons invoked by the workflow operate
on the same store. CLI note commands and built-in note add-ons now
construct `NoteService` with this dispatcher.

## Implementation slice 9

**Date**: 2026-07-04
**Task**: TASK-008 completion
**Status**: Completed
**Files**:
`examples/note-auto-tagging/workflow.json`,
`examples/note-auto-tagging/nodes/node-classify-tags.json`,
`examples/note-auto-tagging/nodes/node-workflow-output.json`,
`examples/note-auto-tagging/prompts/classify-tags.md`,
`examples/note-auto-tagging/mock-scenario.json`,
`examples/note-auto-tagging/EXPECTED_RESULTS.md`,
`examples/note-quick-memo/workflow.json`,
`examples/note-quick-memo/nodes/node-workflow-output.json`,
`examples/note-quick-memo/mock-scenario.json`,
`examples/note-quick-memo/EXPECTED_RESULTS.md`,
`examples/note-pdf-ingest/workflow.json`,
`examples/note-pdf-ingest/nodes/node-extract-pages.json`,
`examples/note-pdf-ingest/nodes/node-workflow-output.json`,
`examples/note-pdf-ingest/prompts/extract-pages.md`,
`examples/note-pdf-ingest/mock-scenario.json`,
`examples/note-pdf-ingest/EXPECTED_RESULTS.md`,
`examples/note-youtube-transcript/workflow.json`,
`examples/note-youtube-transcript/nodes/node-extract-transcript.json`,
`examples/note-youtube-transcript/nodes/node-workflow-output.json`,
`examples/note-youtube-transcript/prompts/extract-transcript.md`,
`examples/note-youtube-transcript/mock-scenario.json`,
`examples/note-youtube-transcript/EXPECTED_RESULTS.md`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-auto-tagging --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-quick-memo --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-pdf-ingest --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-youtube-transcript --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteWorkflowExampleTests`,
and
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests/testAllRielaExampleWorkflowsArePortedAndValidateInSwift --filter RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI`.
**Notes**: Added deterministic note workflow examples for default
auto-tagging, quick memo creation, PDF page ingestion, and YouTube
transcript capture. Mock scenarios only replace external agent/OCR/
transcript work; note add-ons execute through the production built-in
resolver so mock runs mutate a real temporary note store. Dedicated
tests assert the created or updated rows: AI tags on an existing note,
the fixed `ノート` quick-memo tag and user-memo notebook kind, imported
PDF page notes, and a YouTube-related file attachment.

## Implementation slice 10

**Date**: 2026-07-04
**Task**: TASK-009 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteService+APIClients.swift`,
`Sources/RielaServer/RielaServer.swift`,
`Sources/RielaServer/ServerContracts.swift`,
`Sources/RielaServer/NoteAPIAuthenticating.swift`,
`Sources/RielaServer/QRClientRegistrationAuthenticator.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaCLI/RielaCommand.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Tests/RielaServerTests/NoteAPIAuthTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAPIAuthTests --filter ServerContractsTests --filter NoteCommandTests --filter RielaNoteTests`
(35 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added note API client persistence over the existing
`api_clients` table, storing only SHA-256 bearer token hashes and
updating `last_seen_at` on successful authentication. Added the
`NoteAPIAuthenticating` seam, QR registration authenticator with
CSPRNG-backed one-time codes capped at a five-minute TTL, `/note/register`
redeem handling, and note GraphQL auth enforcement when a route handler
is configured with a note API authenticator. Tests cover unauthenticated
rejection, registered bearer success, revoked bearer rejection,
single-use code rejection, expiry rejection, and the default
`RielaServerConfiguration` keeping `host == 127.0.0.1` and
`noteAPIEnabled == false`. Added `riela note client register|list|revoke`
for local operator management of the same client registry. `riela serve
--note-api` currently emits an in-process serving descriptor only; it
does not bind a reachable remote HTTP socket, so QR redemption through a
remote listener remains follow-up work.

## Implementation slice 11

**Date**: 2026-07-04
**Task**: TASK-010 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteDetailView.swift`,
`Sources/RielaNoteUI/RielaNoteComponents.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests --filter RielaNoteTests`
(27 tests),
`env -u TOOLCHAINS -u SDKROOT DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -scheme RielaNoteUI -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath tmp/RielaNoteUI-iOS-DerivedData LD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang build`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the `RielaNoteUI` SwiftPM library target and
`RielaNoteUITests`, with package platform support for iOS 17. The UI is
SwiftUI-only and imports no AppKit: `RielaNoteRootView` hosts a
compact-first `NavigationSplitView`, `RielaNoteNotebookListView`
provides created-desc notebook rows and FTS search-result rows, and
`RielaNoteDetailView` renders markdown, provenance-distinct tag chips,
read-only lock state, related files, links, comments, and a segmented
text/source-page-image switch. Added `RielaNoteUIClient` plus
`NoteServiceRielaNoteUIClient` so a future remote GraphQL client can
substitute for local `NoteService`. `NoteService.listNotes(notebookId:)`
was added for deterministic first-note loading without FTS side effects.
Tests cover list/detail view construction, load/search selection, source
image switching through a mock client, and real local plus S3-migrated
source-page-image resolution through `NoteServiceRielaNoteUIClient`.

## Implementation slice 12

**Date**: 2026-07-04
**Task**: TASK-011 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaApp/EntryPoint.swift`,
`Sources/RielaApp/EntryPoint+Menu.swift`,
`Sources/RielaApp/EntryPoint+Notes.swift`,
`Sources/RielaApp/NoteWindowController.swift`,
`Sources/RielaApp/NoteSettingsWindowController.swift`,
`Sources/RielaAppSupport/RielaAppLaunchOptions.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteDetailView.swift`,
`Tests/RielaAppSupportTests/RielaAppLaunchOptionsTests.swift`,
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed focused checks:
`swift test --filter RielaNoteUITests`,
`swift test --filter RielaAppNotesIntegrationTests --filter RielaAppLaunchOptionsTests`,
`swift build --product RielaApp`, and a direct
`.build/arm64-apple-macosx/debug/RielaApp --open-notes` launch with
isolated `tmp/rielaapp-note-ui` roots. `screencapture` was blocked by
macOS screen-recording masking in this environment, so the UI screenshot
evidence uses an AppKit offscreen render written under `tmp/` by
`RielaAppNotesIntegrationTests`.
**Notes**: Added a status-bar `Notes...` entry and `Note Settings...`
entry. Notes resolve against the active RielaApp profile at
`<home>/.riela/profiles/<profile>/note/`, so the default production path
is `~/.riela/profiles/<profile>/note/` while tests and debug launches can
isolate with `--home-root`. `NoteWindowController` hosts
`RielaNoteRootView` through `NSHostingController`; `RielaNoteUI` now
supports editing non-read-only note bodies through `RielaNoteUIClient`.
`NoteSettingsWindowController` persists per-profile note API exposure in
`note/app-settings.json` and manages API clients through the existing
`NoteService.registerAPIClient`, `listAPIClients`, and
`revokeAPIClient` APIs. Added `--open-notes` for deterministic RielaApp
UI verification.

## Implementation slice 13

**Date**: 2026-07-04
**Task**: TASK-007 completion
**Status**: Completed
**Files**:
`Sources/RielaCLI/NoteCommands.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteCommandTests --filter NoteGraphQLTests`
(8 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter NoteGraphQLTests --filter NoteCommandTests --filter NoteAddonTests --filter NoteWorkflowExampleTests`
(36 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Completed the local `riela note` CLI's GraphQL-document
execution path. `NoteCommandRunner` now drives note create/update/delete,
show/list/search, tag add/remove, comment, attach, read-only toggles,
notebook list/show/create/delete, and storage migration through
`NoteGraphQLDocumentExecutor` against the local note store. Added the
missing `notes` query plus `createNotebook` and `deleteNotebook`
mutations to the note GraphQL service, document executor, and schema
contract. `note list` now lists notes created-desc with optional
`--notebook` and `--tag` filters instead of proxying to notebook list.
CLI ergonomics now accept positional attach paths, `readonly --on|--off`,
`tag --add|--remove`, and `storage migrate --all --to s3 --profile`.
The round-trip test covers add -> list -> search -> tag remove ->
positional attach -> storage migrate --all -> edit -> show ->
notebook list -> delete against a temp note root, plus notebook
create/show/delete and client register/list/revoke.

## Implementation slice 14

**Date**: 2026-07-04
**Task**: TASK-012 completion
**Status**: Completed
**Files**:
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNoteUI/RielaNoteAgentModels.swift`,
`Sources/RielaNoteUI/RielaNoteAgentView.swift`,
`Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests+NoteExamples.swift`,
`examples/note-agent/`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests --filter NoteWorkflowExampleTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter RielaNoteUITests --filter NoteWorkflowExampleTests --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the packaged `note-agent` workflow under
`examples/note-agent`, using `riela/note-search` followed by a
`codex-agent` answer node that returns cited note ids. The local
service-backed UI path answers from one FTS-backed search/template pass;
vector retrieval, multi-source RAG, and web search remain follow-up
work. `RielaNoteUI` now has an Agent tab with a temp-chat toggle,
explicit Save action, agent turn view, and citation buttons that
deep-link back to Library selection. `NoteServiceRielaNoteUIClient`
answers turns from real note search results, saves first auto-saved turns through
`saveConversation`, appends later auto-saved turns through
`appendConversationTurn`, and leaves temporary turns in the caller until
Save. The service-backed UI test verifies citations resolve to real note
ids, default persistence creates an `agent-conversation` notebook, and
conversation notes get `source-citation` links. Also hardened note FTS
query normalization so hyphenated user text such as `source-backed`
does not become invalid SQLite FTS syntax.

## Implementation slice 15

**Date**: 2026-07-04
**Task**: TASK-013 completion
**Status**: Completed
**Files**:
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaNote/NoteWorkflowScaffolder.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentModels.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentView.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`examples/note-config-agent/`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter RielaNoteUITests --filter NoteGraphQLTests --filter NoteWorkflowExampleTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added a dedicated RielaNoteUI Config tab and view model.
The screen submits config-agent requests, displays proposed changes, and
applies them through the `RielaNoteUIClient` boundary. The local
`NoteServiceRielaNoteUIClient` now proposes tag-class/tag,
auto-action, and ingestion-workflow draft changes, then applies them by
defining tag classes/tags, configuring the note auto-action row, and
writing a portable workflow bundle through
`NoteIngestionWorkflowScaffolder`. Added GraphQL mutations and
document-executor support for `defineNoteTagClass`, `defineNoteTag`,
and `scaffoldNoteIngestionWorkflow`, with the note SDL extracted to
`GraphQLNoteSchemaContract` to keep `GraphQLContracts.swift` below the
1000-line threshold. Added packaged `examples/note-config-agent` as the
agent-worker proposal workflow and deterministic mock tests proving the
proposal shape.

## Implementation slice 16

**Date**: 2026-07-04
**Task**: TASK-014 completion and final audit
**Status**: Completed
**Files**:
`README.md`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`env -u LD /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
(1054 tests),
`env -u LD /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`env -u SDKROOT -u TOOLCHAINS -u LD xcodebuild -scheme RielaNoteUI -destination 'platform=iOS Simulator,id=A6768A08-2125-4BB7-B556-AD907C665285' -derivedDataPath tmp/riela-note-ios-derived-data-xcode ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build`,
`env -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`,
`rg -n "import AppKit" Sources/RielaNoteUI || true`, and
`rg --files -g 'riela-package.json'` (no package manifest present, so no
digest refresh was required).
**Notes**: Added README documentation for the shipped `riela note`
command family, default note roots, notebook/storage/client management,
packaged note workflows, RielaApp note root behavior, and the local
`riela serve --note-api` authentication model. Updated the
`impl-plans/README.md` row to partial with the remote socket and real
libsql sync deferred. Final audit confirms the local note store,
GraphQL, CLI, add-on, and UI slices are implemented, while
`RielaNoteUI` compiles for an iOS Simulator destination with no AppKit
imports. The Xcode iOS build must run without the ambient `LD=ld`
environment value; otherwise Xcode imports it as a build setting and
calls `ld` directly with compiler-driver flags.

### 2026-07-04 TASK-015 implementation
**Status**: EXPERIMENTAL / PARTIAL
**Commands**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
- `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 RIELA_NOTE_TEST_DRIVER=libsql /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `env -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
**Notes**: Added a separate `RielaNoteLibSQL` product/target. The
target is experimental: `.local` currently delegates to plain
`SQLiteDatabase`, and `.embeddedReplica` fails fast because SQL
execution through libsql is not implemented. The main `RielaNote`
target remains free of the extra dependency. Real libsql embedded
replica/sync behavior and full suite parity against that driver remain
follow-up work.
