# Riela Note Review — Findings and Improvements

## Review Scope

- Branch: `feature/riela-note` (commits `e9ec58c` "Implement Riela Note",
  `ee1cc71` "Add optional Riela Note libsql driver") reviewed against
  `main` on 2026-07-04.
- Design reference: `design-docs/specs/design-riela-note.md` (D1–D15);
  requirements memo `design-docs/riela-note-design.md`.
- Baseline: `swift build` and `swift test` both pass on macOS
  (1054 tests, 0 failures). All findings below are therefore about
  correctness under untested conditions, spec deviations, and user
  experience — not about broken builds.
- Line references are as of `ee1cc71`.

## Verdict Summary

The domain skeleton is solid: transaction discipline, parameterized
SQL, spec-faithful read-only/provenance rules, seeded inert
auto-actions, and a clean `NoteDatabaseDriving` seam. But four themes
cut across the branch:

1. **Advertised-but-unwired surfaces have been narrowed.** Note API
   serving, QR registration, and the app's "Expose Note API" setting
   are now wired; raw libSQL embedded-replica access is disabled until
   a single-runtime libsql implementation can safely replace it.
2. **Index/loop integrity hazards.** Contentless-FTS delete payloads
   can diverge from insert payloads (index corruption); the auto-action
   loop guard is self-exclusion only and `createNote` has no guard.
3. **The UI now covers the core notebook loop.** Multi-page notebook
   navigation, note creation, tags, comments, links, search filters,
   file chips, S3 image resolution, and compact-width navigation are
   wired; remaining polish is mostly scale and refresh behavior.
4. **Japanese search does not work.** FTS5 `unicode61` does not segment
   CJK text, so the primary user language only matches whole
   whitespace-delimited runs.

## 1. Critical Defects

### 1.1 Contentless FTS5 delete payload mismatch → index corruption

`Sources/RielaNote/NoteSearch.swift:110-134` (insert payload) orders
tags by name (`noteTags()` uses `ORDER BY t.name`,
`NoteService.swift:666-679`), but the delete payload
(`NoteSearch.swift:136-150`) builds tags with
`group_concat(t.name, ' ')` **without ORDER BY** (arbitrary order; in
practice creation order). Contentless FTS5 `'delete'` commands must
reproduce the original insert exactly; any note with ≥2 tags whose
alphabetical order differs from creation order leaves ghost postings on
update/delete (`refreshFTS`, `deleteNoteRows`
`NoteService.swift:541-549`, `updateNoteBody`, `applyTags`,
`removeTag`): removed tags keep matching, and
`INSERT INTO note_fts(note_fts) VALUES('integrity-check')` fails.

**Fix:** one shared payload builder for insert and delete — e.g.
`group_concat(t.name, ' ' ORDER BY t.name)` (SQLite ≥ 3.44) or an
ordered correlated subquery — plus a regression test (multi-tag note
created out of alphabetical order → update → delete →
`integrity-check`). No current test exercises this path.

### 1.2 libSQL driver: writes bypass libsql — remote sync silently loses all local writes

`Sources/RielaNoteLibSQL/LibSQLNoteDatabaseDriver.swift:111-128`.
`withDatabase` creates a libsql `Database`, calls `connect()` and
**discards the connection**, optionally `sync()`s, then opens the same
file with the vanilla `SQLiteDatabase` C-API wrapper and runs all SQL
through that. In embedded-replica mode, writes must go through a libsql
`Connection` to be forwarded to the remote primary; writes made by a
foreign sqlite3 library to the replica file are never propagated to
Turso and can corrupt replica bookkeeping on the next `sync()`.
`syncPolicy: .beforeAndAfter` therefore gives the *appearance* of sync
while every note written in the session is remote-invisible and at
risk locally.

**Fix:** execute SQL through the libsql `Connection` (see §6.2 for the
seam change this requires), or delete the `.embeddedReplica` path and
ship the driver as local-only until the seam is reworked — keeping
D2's "follow-up" honest. At minimum mark `.embeddedReplica` as
unavailable/experimental so nothing adopts a sync path that drops data.

### 1.3 Two SQLite runtimes attached to the same database file

Same lines as 1.2. Even for `.local`, `Database(path)` + `connect()`
opens the file with libsql's bundled runtime while `SQLiteDatabase.open`
opens it with system SQLite3 in the same process — the classic
"multiple copies of SQLite in one process" hazard: POSIX advisory locks
are per-process, so the two libraries can silently break each other's
locks on the shared file → WAL corruption risk. This is precisely the
outcome D2 said it wanted to avoid; here the second runtime is not
merely linked but concurrently attached.

**Fix:** one runtime per file. Route all access through libsql; never
open the path with `SQLiteDatabase` while a libsql handle exists.

### 1.4 Note API route handler is fail-open

`Sources/RielaServer/ServerContracts.swift:191-208`. The auth gate is
`if noteGraphQLRootFieldName(...) != nil, let noteAPIAuthenticator`,
so when an executor is wired but no authenticator is configured, every
note mutation executes **unauthenticated**. This is the exact
configuration a future "wire up serve" change is most likely to produce
by accident, and
`Tests/RielaServerTests/ServerContractsTests.swift:103` currently
asserts this unauthenticated-success behavior as a contract.

**Fix:** fail closed — note-domain documents with no authenticator
configured return 401/503 unless an explicit
`allowUnauthenticatedNoteAPI` local-mode marker is set (for in-process
CLI use). Invert the test and add one asserting
executor-without-authenticator is rejected.

### 1.5 Published GraphQL schema contradicts the executor

`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift` vs
`NoteGraphQLDocumentExecutor.swift:220-248`:

- **Field names:** the schema publishes `noteTags`, `noteTagClasses`,
  `noteAutoActions`; the executor routes only `tags`, `tagClasses`,
  `autoActions` (`supportedNoteGraphQLFields`). A client following
  `riela graphql schema` gets `handled: false` fallthrough to the
  legacy delegated echo.
- **Return shapes:** the schema declares bare types
  (`note(noteId: String!): Note`, `[Notebook!]!`, …) while the executor
  returns the `GraphQLNoteQueryResult` wrapper
  `{ value, result { accepted status diagnostics } }`
  (`NoteGraphQLService.swift:5-13`). The CLI's own documents
  (`NoteCommands.swift:119, 306, 862-877`) query a shape the published
  schema says does not exist.

**Fix:** generate the schema string, `supportedNoteGraphQLFields`, and
executor dispatch from a single field table (name, kind, args, payload
type), and add a parity test asserting every schema-published note root
field is routable by `noteGraphQLRootFieldName`.

### 1.6 UI: stale edit draft can overwrite the wrong note

`Sources/RielaNoteUI/RielaNoteDetailView.swift:6-7, 70-77, 121-130` +
`RielaNoteLibraryViewModel.swift:126-139`. `isEditingBody` /
`draftBodyMarkdown` are `@State` on the detail view and never reset on
selection change. Sequence: Edit note A → select note B in the sidebar
→ editor stays open with A's draft → Save resolves
`selectedDetail?.note.noteId` = **B** and writes A's body into B. This
is user-data corruption reachable in three clicks.

**Fix:** reset edit state on
`.onChange(of: viewModel.selectedDetail?.note.noteId)` (or move the
draft into the view model and clear it in `selectNote`/
`selectNotebook`), and guard `saveSelectedNoteBody` with the note id
captured when editing began.

## 2. Major Issues by Area

### 2.1 Core domain (`Sources/RielaNote`)

- **Auto-action loop guard weaker than D11.**
  `AutoActionDispatching.swift:93-105` excludes only the action whose
  `actionId == event.originatingActionId`. Two `note-updated` actions
  whose workflows both write the body ping-pong forever (A→B→A…), each
  cycle spawning workflow runs. Worse, `NoteService.createNote`
  (`NoteService.swift:66-152`) has **no `originatingActionId` parameter
  at all**, so an auto-action workflow that creates notes (e.g. via
  `riela/note-create`) unconditionally re-fires `note-created` — a
  self-retrigger loop if the action matches. Fix: propagate
  `originatingActionId` through `createNote` (and the addon/GraphQL
  inputs), and suppress *all* re-dispatch for events carrying an
  originating action id (or add a dispatch-generation counter).
- **Conversation writes never fire triggers.**
  `NoteService+Relations.swift:76-128`: `appendConversationTurn` /
  `saveConversation` insert notes and notebooks without dispatching
  `note-created` / `notebook-created`, violating D10 ("fires
  auto-action triggers exactly once per commit"). Either dispatch (with
  loop-guard support) or document the exemption in the spec — skipping
  auto-tagging for chat turns may actually be desirable, but it must be
  a decision, not an accident.
- **`applyTag` upsert can overwrite `system` provenance and flip
  `deletable`.** `NoteService.swift:489-522`: only `human`-vs-`ai` is
  guarded; an existing `provenance='system'` or `deletable=0`
  assignment is silently overwritten by `ON CONFLICT ... DO UPDATE`
  (with `deletable` hard-coded true). Latent today, but any future
  caller violates D3/D6 system-tag immutability. Same pattern in
  `applyNotebookTag` (`NoteService.swift:459-487`); contrast
  `applyConversationNotebookKind` which correctly uses `DO NOTHING`.
  Fix: refuse to demote `system` provenance and never overwrite
  `deletable = 0` in the upsert.
- **S3 handling is fully in-memory and migration double-transfers.**
  `S3NoteFileStore.swift:22-57`, `NoteFileMigration.swift:33-51`,
  `S3HTTPRequest.body: Data`. Primary payloads are videos/PDFs; store,
  read, and the post-upload verification GET each hold the whole file
  in memory (migration peaks ~2× file size, transfers twice). Spec
  calls for streaming reads to a local cache. Fix: streaming/URL-based
  upload (`uploadTask(withFile:)`) and download-to-temp with
  hash-while-streaming; verify uploads via `x-amz-checksum-sha256` /
  HEAD instead of a full GET.
- **SigV4 canonical URI uses the percent-decoded path.**
  `S3NoteFileStore.swift:122-129` signs `url.path` (decoded) while the
  wire request uses the encoded path (lines 144-156); additionally
  `.urlPathAllowed` permits characters SigV4 requires encoded. Any key
  segment needing encoding (space, `+`, unicode) → signature rejected.
  Works today only because generated ids are ASCII-safe. Fix: build the
  canonical URI from SigV4-encoded segments (unreserved chars + `/`
  only) and reuse that exact string for the request URL; collapse
  internal spaces in header canonicalization.
- **`attachFile` writes the blob before validating the target.**
  `NoteService+Files.swift:6-78`: `fileStore.store(data:)` runs before
  the transaction that checks the note/notebook exists — a bad id
  orphans content on disk with no DB row and no cleanup path. Fix:
  validate first, or delete the stored blob in `catch`.

### 2.2 libSQL driver and packaging (`Sources/RielaNoteLibSQL`, `Package.swift`)

- **Default `swift build` breaks on Linux; the dependency is not truly
  optional.** `Package.swift:48` adds `libsql-swift` (exact 0.3.2, an
  xcframework binary with no Linux slice) unconditionally, and
  `RielaNoteLibSQL` is a declared target/product. `swift build` with no
  `--product` builds every target → Linux build failure; CI survives
  only because the Linux job builds `--product riela`. Fix: gate the
  package dependency, target, and product behind a manifest env check
  (the `RIELA_NOTE_ENABLE_LIBSQL_TESTS` trick already used for tests),
  and add a Linux full `swift build && swift test` CI job.
- **Per-call `Database` construction + double network sync.**
  `LibSQLNoteDatabaseDriver.swift:111-116, 124-126`: every
  `withDatabase` (i.e. every `NoteService` method) constructs a fresh
  libsql `Database` and, under `.beforeAndAfter`, performs two blocking
  network syncs; a sync failure (offline) throws before any local work,
  defeating offline-first. `syncIntervalMilliseconds` is meaningless
  because the `Database` is dropped per call. Fix: one long-lived
  `Database` per driver (actor-owned), sync on open/close/timer,
  non-fatal sync failures for local reads.
- **Error surface drift.** The libsql driver throws
  `LibsqlError.runtimeError(String)` (no code/operation/path context)
  where the SQLite driver throws `SQLiteError`; callers matching on
  `SQLiteError` behave differently per driver. Fix: wrap libsql
  failures into `SQLiteError` (new `.sync`/`.replicaOpen` operations)
  including the DB path but never the auth token.
- **Invalid config constructible.**
  `LibSQLNoteDatabaseDriver.swift:97-105`: `.local` +
  `syncPolicy: .beforeAndAfter` passes init and fails on every call.
  Fix: validate in init, or move the policy into the
  `.embeddedReplica` associated value.
- **Secrets:** `LibSQLEmbeddedReplicaConfiguration`
  (`LibSQLNoteDatabaseDriver.swift:23,40`) reflects `authToken` /
  `encryptionKey` in default `String(describing:)` output. Add
  redacting `CustomDebugStringConvertible`.
- **libsql leg proves nothing today.** The driver-conformance switch
  (`RIELA_NOTE_TEST_DRIVER=libsql`, shared `makeNoteDriver()` in
  `Tests/RielaNoteTests/NoteStoreSchemaTests.swift:76-101`) is a good
  pattern, but no CI job sets it — and because of 1.2/1.3 every
  assertion still executes on system SQLite anyway. JSONB flag-8,
  FTS5, and transaction semantics under the libsql engine are
  unverified. Fix: macOS CI job with both env vars after the 1.2
  rework; add `.embeddedReplica` config and error-propagation tests.

### 2.3 CLI, GraphQL, add-ons (`Sources/RielaCLI`, `Sources/RielaGraphQL`)

- **The document executor now performs minimal root-field parsing.**
  `NoteGraphQLDocumentParsing.swift` skips GraphQL comments/strings,
  preserves alias response keys, substitutes `$variables`, and extracts
  root-field literal arguments for dispatch. This fixes the reviewed
  failures where a leading comment containing `{` broke routing,
  aliases mis-keyed responses, and inline root arguments such as
  `deleteNote(noteId: "x")` were ignored. The executor now also
  validates selected fields against the note GraphQL schema before
  dispatch, so unsupported nested selections fail closed instead of
  executing and returning a decorative full DTO.
- **`riela graphql` now executes note documents.**
  `ScopedParityCommands.swift` routes `graphql execute`/`document`/
  `note-document` through `NoteGraphQLDocumentExecutor`, with
  `--query`/`--query-file`, `--variables`, `--operation-name`, and
  `--note-root`. This closes the basic CLI/server/library parity path;
  remaining executor gaps are the parser limitations above.
- **`riela serve --note-api` does not exist.** `--note-api` appears
  only in help text (`RielaCLIApplication.swift:294`); nothing parses
  it, `serverResponse` (`ScopedParityCommands.swift:297-322`)
  constructs the route handler with nil executor/authenticator and
  handles exactly one in-process request; there is no socket listener.
  `RielaServerConfiguration.noteAPIEnabled` is dead config. Fix: wire
  host/port bind + note executor + `QRClientRegistrationAuthenticator`
  behind the flag, or remove the flag from help and mark D14
  not-yet-shipped.
- **CLI surface gaps vs the spec grid** (`NoteCommands.swift`):
  `note edit --append`, stdin bodies via `-`, and
  `note delete --notebook <id>` now work; storage migration still
  requires raw `--s3-endpoint/--s3-region/--s3-bucket` per invocation
  instead of named settings-persisted profiles (777-798).
- **`note storage migrate` without a file id silently migrates
  everything; `--all` is a no-op** (`NoteCommands.swift:373-390`,
  `:720-721`). A bulk operation must require explicit `--all`; error
  when neither a file id nor `--all` is given.
- **PDF use case is partially delivered.**
  `riela/notebook-ingest-pages` now preserves page `number` and
  `pageImageRef` in per-note metadata, stores explicit page numbers in
  `notes.note_number`, attaches inline/local `pageImageRef` content
  with role `source-page-image`, and attaches local/file
  `sourceDocumentRef` content with role `source-document` while keeping
  remote refs as notebook metadata. Local/file source refs now use
  URL-backed storage instead of materializing into `Data` first.
  Remaining work: streaming remote refs and inline workflow
  attachments, plus reduced fan-out for very large notebook ingests.
- **`riela/note-tag-apply` provenance is forgeable.**
  `ProductionNodeAdapter+NoteAddons.swift:197-203`
  (`noteProvenance(context.string("provenance")) ?? .ai`): workflow
  config can pass `provenance: "human"`, letting automation forge
  human tags — and thereby bypass the "AI can't remove human tags"
  protection. Fix: clamp the addon to `.ai` (allow `system` at most)
  and record `assignedBy` from the workflow id.
- **Remote migrate mutations are now profile-gated.**
  `NoteGraphQLDocumentExecutor` defaults to named server-side
  `S3StorageProfile` values only and rejects raw endpoint/env fields,
  including attempts to bundle raw fields with a valid profile name.
  Raw endpoint/env refs are enabled only by explicit local CLI
  executors that construct the GraphQL executor with
  `allowRawS3ProfileInput: true`.

### 2.4 Server auth and auto-action dispatch (`Sources/RielaServer`, dispatchers)

- **QR registration flow is now wired through one-time challenges for
  the local CLI/App client-management paths, with direct minting kept as
  an explicit CLI `--direct` administrative mode.** Remaining work:
  expose the interactive remote registration contract so another device
  can redeem a challenge without the local operator immediately seeing
  the bearer token.
- **Terminal and app QR registration now exist.**
  `QRClientRegistrationAuthenticator` renders a terminal half-block QR
  when CoreImage is available and falls back to URL text otherwise. The
  app Note Settings window now opens a CoreImage QR challenge sheet with
  code, expiry, and Copy URL support. The registration URL carries the
  code as a query parameter (`/note/register?code=<code>`) so a client
  can observe it. Remaining work: publish an explicit client contract
  for redeeming the code.
- **Malformed legacy `filter_json` no longer disables an entire
  trigger.** New configurations reject malformed filter shapes up front;
  legacy rows are evaluated per action, skipped on decode/evaluation
  failure, and reported through a RielaNote-level diagnostic naming the
  bad action id. CLI and built-in note add-on service construction wire
  that diagnostic recorder to stderr.
- **Dispatch is at-most-once fire-and-forget; CLI dispatches are
  lost.** `NoteAutoActionWorkflowDispatcher.swift:15-23` runs the
  workflow in a detached background `Task` nothing awaits; `riela note
  add` renders its result and the process exits, killing the task —
  the seeded AI-tagging action will essentially never complete from
  CLI writes, despite the spec's "at-least-once". Fix: bounded await
  before CLI exit, a detached child process, or (preferred, fixes the
  loop guard too) a durable outbox table — see §6.4.
- Minor but worth tracking: no rate limiting/telemetry on registration
  redemption and bearer auth; `pendingCodes` never prunes expired
  entries (`QRClientRegistrationAuthenticator.swift:48,70,103`);
  unauthenticated `/graphql` schema output includes the note mutation
  surface; 404-vs-410 registration error oracle.

## 3. User-Perspective UI/UX Analysis

Requirement anchor: 「UIのデザインはなるべくシンプルに。noteの閲覧、
検索を軽く行えるようなUIにする」 plus the external-brain promise. What
shipped matches the spec's *screen inventory* (list with previews,
created-desc sort, provenance-distinct tag chips, text/image toggle,
temp-chat toggle + Save with auto-save default, tappable citations that
deep-link, AppKit-free portable SwiftUI module). The remaining product
gaps are now narrower scale, refresh, and polish issues. Prioritized
gaps with concrete proposals:

### P0 — blocks core value

- **B1. Multi-note notebook navigation is now wired.**
  `RielaNoteUIClient` exposes paged
  `listNotes(notebookId:limit:offset:)`; the view model tracks loaded
  notebook notes, selected note index, next/previous state, and more
  pages. The UI can move past the first note and inspect imported PDF
  pages while preserving the selected content mode across page flips,
  and the pager buttons expose `Cmd-Left`/`Cmd-Right` shortcuts.
  Remaining polish: better large-notebook count/virtualization behavior.
- **B2. UI capture is now wired.** `RielaNoteUIClient` exposes
  `createUserMemo`, `NoteServiceRielaNoteUIClient` creates a human
  memo with `assignedBy: "riela-note-ui"`, and the notebook list has a
  `Cmd-N` "New memo" toolbar action that refreshes and selects the new
  note. The UI client and view model also support creating an editable
  user note inside the selected notebook through `Cmd-Shift-N`. Both
  creation commands now open a first-draft sheet for title/body capture
  before creating the note, with blank drafts still falling back to the
  existing untitled memo/note markdown. Creating inside a notebook that
  was loaded from a later notebook page preserves that notebook in the
  sidebar after the post-create refresh.
- **B3. Tags, comments, and links are interactive now.** The detail
  view can add/remove human tags, always shows a comment composer, can
  add links, resolves linked-note titles through `linkedNotesById`,
  opens linked notes via buttons, and offers existing tag suggestions
  while adding tags. The link composer now suggests loaded target notes
  by title/id, performs an isolated cross-notebook target lookup through
  the UI client's search API as the user types, and source-citation
  links use distinct presentation.

### P1 — high friction

- **B4. Search is now incremental, tag-filtered, and paged.**
  `RielaNoteLibraryViewModel` searches as text and tag filters change,
  the list exposes tag and tag-class filter chips, `Cmd-F` opens the
  search field, and search now fetches one extra result to expose a
  "Load more" row backed by service/GraphQL offset support. Remaining
  polish: debounce to avoid one request per keystroke, keep previous
  results visible during refresh, match highlighting, and notebook
  captions.
- **B5. Text↔page-image switching is now cached, preloaded, and decoded
  off the render path.** The current implementation caches resolved
  files, prefetches current and adjacent source-page images on note
  selection, preserves image mode while paging within a notebook, decodes
  source images off the main actor through a downsampled ImageIO
  thumbnail cache, exposes zoom + retry controls in image mode, and
  shows an in-panel loading state while explicit source-image
  fetch/decode work is in flight. Remaining polish: consider a bounded
  LRU if very large notebooks make the in-memory cache too broad.
- **B6. Related-files strip is inert and S3 files are unusable in the
  shipped app.** File capsules do nothing on tap
  (`RielaNoteDetailView.swift:134-154`) — no Quick Look, open, save,
  or reveal; and the app constructs its client with `s3Profiles: []`
  (`Sources/RielaApp/NoteWindowController.swift:25`), so any
  S3-migrated file (including page images) throws — the image toggle
  silently breaks after a bulk migration. *Proposal:* chips become
  buttons → resolve to temp file → `.quickLookPreview` (SwiftUI,
  iOS-portable) with context menu (Open / Save As… / Copy / Reveal in
  Finder for local); cloud badge for `storageKind == .s3` + download
  progress; `RielaAppNoteSettings` now persists named S3 profile
  definitions, the Note window passes them into the client, Note Settings
  can edit a persisted environment-backed profile, and served note API
  migrations receive those profiles as allowed `s3ProfileName` targets.
  The Note UI also prefetches and caches source-page images so S3-backed
  pages are not re-downloaded on ordinary text/image toggles, and S3
  reads from the Note UI use `AsyncS3HTTPClient`/`URLSession.data(for:)`
  instead of the semaphore-backed synchronous client path. Remaining
  work: multi-profile management and storage-layer streaming reads to the
  local cache per spec.
- **B7. Note Agent is a canned FTS echo, not an agent.**
  `answerNoteAgentTurn` (`RielaNoteUIClient.swift:115-129, 240-248`)
  runs one FTS query and templates "I found N relevant note
  source(s):" — no LLM, no workflow dispatch, no web search, no
  streaming or stop. The good parts (tappable citations that
  deep-link + tab switch, temp toggle + Save, auto-save default) are
  real, and the current UI now surfaces agent errors, restores a
  failed draft for retry, supports Return-to-send and New Chat, labels
  temp mode as not saved, and prevents temp-Save duplication by saving
  only unsaved turns before flipping the conversation back to autosave.
  *Proposal:* dispatch the packaged note-agent workflow
  (retrieval via `riela/note-search` → agent worker answer) through
  the same execution entry points the event listener uses; protocol
  becomes `AsyncThrowingStream<TurnDelta, Error>` for streaming
  (existing `design-agent-response-streaming.md` infrastructure) with
  a Stop button. Remaining ride-along polish: auto-scroll to newest
  turn, confirm-on-close with unsaved temp turns, and richer progress
  state during streamed answers.
- **B8. Compact-width navigation is now reachable.** The root view
  uses a compact-width `NavigationStack` with a detail destination, and
  note/search rows are driven by `List(selection:)` with tagged rows and
  a selected-note binding instead of plain button-only mutation. Opening
  a note still refreshes the view model detail and pushes the compact
  detail path, while macOS gets first-class list selection state and
  selected-row accessibility traits. Remaining polish: run a visual
  iPhone/iPad pass for `TabView` + split/stack behavior and tune row
  selection styling if native platform defaults conflict with the
  custom note icon highlight.
- **B9. Notebook pagination is now wired.** The view model fetches one
  extra notebook to detect more pages, tracks `hasMoreNotebooks`, and
  the notebook list exposes a "Load more" row that appends by offset so
  notebook 51+ is reachable. The service now batches per-notebook list
  metadata (`firstNotePreview` and note count) instead of issuing
  per-row queries, and refresh/post-create reloads append pages as
  needed to keep the selected notebook visible. Remaining scale work:
  infinite-scroll trigger/spinner polish.
- **B10. Data freshness now has an explicit refresh path.**
  `RielaNoteLibraryViewModel.refresh()` reloads notebooks, tags,
  active search results, notebook notes, and the currently selected
  detail so background workflow/CLI writes can be pulled into the open
  window without losing selection. The list toolbar exposes Refresh with
  `Cmd-R`, `.refreshable` uses the same selected-detail-preserving
  path, and the root view refreshes after subsequent
  `scenePhase.active` transitions. The service-backed UI client now
  exposes the SQLite database/WAL/SHM paths, and `RielaNoteRootView`
  starts a debounced `DispatchSource` watcher so cross-process CLI or
  workflow writes refresh the open window while the app remains active.
  Remaining work: split error state per surface (list vs detail vs
  image) with inline recovery.
- **B11. Note Settings registration is no longer placebo.**
  The "Expose Note API" checkbox feeds daemon server configuration for
  the profile, and "Register Client" now opens a CoreImage QR challenge
  sheet with code, expiry, and Copy URL support instead of minting and
  echoing a bearer token locally. Remaining polish: show the active
  host/port in the window, support an explicit VPN/public bind override
  per D14, and add richer client metadata such as last-seen.

### P2 — polish

- **B12. Config Agent is deterministic string-mangling presented as
  AI.** `proposeNoteConfigAgentChange`
  (`RielaNoteUIClient.swift:158-189`) slugifies the message and always
  emits the same four-part proposal; asking "delete the year class"
  proposes creating a class named `delete-the-year-class`. No proposal
  preview/editing, no view of existing classes/auto-actions, raw text
  path for workflow root, silent errors. *Short term:* label honestly
  ("Scaffold ingestion config"), editable proposal form before Apply,
  folder picker, and a read-only panel listing current tag classes and
  auto-actions (doubles as the missing auto-action management UI).
  *Longer term:* route through an agent-worker workflow like the
  RielaApp assistant, per spec.
- **B13. Markdown rendering is inline-only.**
  `AttributedString(markdown:)` (`RielaNoteComponents.swift:65-77`)
  drops headings/lists/code blocks and never renders embedded images —
  significant when note bodies are OCR'd book pages. Parse blocks into
  a `LazyVStack` of styled views; resolve `![...](file-id)` embedded
  images through `resolveFile`. Keep `textSelection(.enabled)`
  (already present — good).
- **B14. Mac operability polish.** Core window-local shortcuts now
  cover `Cmd-N`, `Cmd-R`, `Cmd-F`, `Cmd-Left`/`Cmd-Right` paging, and
  Return-to-send; remaining keyboard/menu polish includes menu-level
  shortcuts (menu items in
  `EntryPoint+Menu.swift:19-20` have empty key equivalents and a
  status-bar app has no Edit/View menu — use window-local
  `.keyboardShortcut`/Commands where appropriate). Remaining polish:
  context menus (notebook: Open/Copy ID/Delete; note: Copy as
  Markdown/Copy deep link; tag chip: Remove/Filter), loading indicators
  for `.loading` state, a richer empty state ("Create a note with ⌘N or
  `riela note add`…"), accessibility labels on provenance chips ("AI
  tag: philosophy") and the temp toggle, and mapping
  `String(describing: error)` to human text.
- **B15. List rows.** Notebook rows now render relative created-time
  text instead of raw ISO-8601 timestamps and show the per-notebook
  note count populated by service, GraphQL, and document-executor
  paths. Fractional timestamp parsing and count pluralization are
  covered by UI tests. Remaining polish: consider updated-desc / title
  sort alternatives (created-desc default matches spec).

### UI code-level defects (beyond 1.6)

- Blocking `DispatchSemaphore` network call on the Swift concurrency
  pool: the Note UI now prefers an `AsyncS3HTTPClient` path backed by
  `URLSession.data(for:)`; the synchronous `S3HTTPClient` implementation
  remains for legacy CLI/server call sites until storage-layer streaming
  replaces whole-`Data` transfers.
- Source-page image decode now happens in `RielaNoteSourceImageDecoder`
  and is cached by `RielaNoteLibraryViewModel`; explicit fetch/decode
  work now exposes in-panel loading feedback.
- `assignPersistedNoteIds` silently no-ops when the service returns a
  different note-per-turn count
  (`RielaNoteAgentViewModel.swift:82-89`) — return per-turn ids from
  the client instead.
- Positive: main-actor annotations, `Sendable` client, weak-self in
  window close callbacks, and zero AppKit imports in `RielaNoteUI`
  (ImageIO/SwiftUI only) all check out.

## 4. Minor Issues (condensed)

- `riela note readonly <id>` now requires exactly one explicit value
  flag (`--on`, `--off`, or `--value`) instead of silently setting
  read-only off.
- `note tag --add a --remove b` now applies additions and removals in
  one command and returns a structured `{applied, removed}` result
  instead of silently ignoring adds.
- `note add --title` now flows through `CreateNoteInput.title` and is
  stored without rewriting `bodyMarkdown`; inline `--output=json` is
  covered by parser and CLI round-trip regression tests.
- Text-mode renderers for `list`/`search` now print GraphQL
  diagnostics on `accepted=false`; `note list --notebook <missing>` is
  covered by a CLI regression.
- Migrate mutations now keep expected failures inside the payload
  envelope (`accepted=false`); mixed bulk migrations return
  `status:"partial"` and all-failed bulk results return `"failed"`.
- The document executor now clamps list/search limits and offsets before
  dispatch; `notebooks` now accepts a `tagFilter` argument backed by
  `notebook_tags`, while the public `attachNoteFile` GraphQL mutation
  is still base64-only. The local CLI attach path now stores from a
  file URL directly instead of base64-encoding whole files through a
  GraphQL document.
- `note client` is the only CLI path bypassing GraphQL documents.
- Addon note-root resolution omits the spec's "app profile context"
  step (`ProductionNodeAdapter+NoteAddons.swift:84-88`). Add-on input
  validation failures now use `invalid_input`, output no longer
  duplicates the candidate payload, and `noteTitleFallback` now strips
  only leading Markdown heading markers.
- Note example workflows now cover the reviewed behavior: rendered
  numeric add-on config values are coerced for `note-agent` limits,
  `note-youtube-transcript` attaches supplied `video/mp4` bytes, and
  `note-config-agent` applies its proposal through note GraphQL
  document mutations.
- Auto-action filter failures are now skipped with diagnostics;
  `deleteNoteAutoAction`, `applyNotebookTags`, and
  `removeNotebookTag` cover row deletion and post-creation notebook tag
  updates.
- `note_schema_version` now rejects future schema versions before
  applying seeds or migrations; schema prepare now dispatches versioned
  migrations and records applied versions. The v2 migration upgrades
  legacy FTS tables to trigram, while prepare still performs an
  idempotent FTS table-shape repair for already-current stores that
  drifted outside the migration path.
- `PRAGMA foreign_keys` is now enabled through `SQLiteOpenOptions` by
  default, with an opt-out for compatibility, and the note store verifies
  that the pragma is active. `ensureTag` validates class ids before
  insert/update so dangling tag-class refs fail as `notFound`.
- JSONB + FTS5 capability probes now run once per process through
  `NoteSQLiteCapabilityCache`; per-store schema creation, future-version
  checks, seeds, and FTS table shape checks still run on each prepare.
- `LocalNoteFileStore.store` now uses `FileManager.replaceItemAt` for
  existing blobs and cleans temporary files with `defer`.
- Note timestamps now use a shared locked ISO8601 formatter with
  fractional seconds, reducing same-second `created_at DESC`
  ambiguity and avoiding per-call formatter allocation.
- `resolveFileContent(fileId:)` local-only overload now rejects s3
  records as `unsupportedStorageKind(.s3)` instead of reporting a
  misleading missing locator.
- `ensureNotebookKindTag` now derives dynamic tag ids from the full
  UTF-8 tag name, so `"foo"` and `"notebook-kind:foo"` no longer
  collide.
- `linkNotes` upsert now preserves existing human/system link
  provenance when an AI write repeats the same link, matching the tag
  demotion boundary.
- `makeNoteId` is millis+UUIDv4, not a real ULID — fine unless
  lexicographic sortability is relied on.
- Note-domain root-field names include very generic identifiers
  (`tags`, `notes`) that a future GraphQL domain could collide with in
  the auth gate (`ServerContracts.swift:191`).
- RielaNote tests now clean their per-test `./tmp/RielaNoteTests/<test>`
  roots from `NoteTestCase.tearDownWithError`, keeping scratch
  artifacts under the repo `tmp/` while avoiding stale test data.

## 5. Test Coverage Gaps

Priority additions (each maps to a finding above):

1. FTS integrity: multi-tag note created out of alphabetical order →
   update/remove/delete → `integrity-check` + search assertions
   (catches §1.1 — fails today).
2. Fail-closed auth: invert
   `testGraphQLRouteExecutesNoteDocumentsWhenExecutorIsConfigured`;
   assert executor-without-authenticator is rejected (§1.4).
3. Schema↔executor parity test over every published note root field
   (§1.5).
4. Loop scenarios: two `note-updated` actions ping-pong;
   action-originated `createNote`; negative-trigger assertions that
   tag/comment/link/file writes dispatch nothing (§2.1).
5. Malformed/mistyped `filter_json` must not disable the trigger
   (§2.4).
6. libsql leg in CI (macOS job with `RIELA_NOTE_TEST_DRIVER=libsql` +
   `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1`) and a Linux full
   `swift build && swift test` job (§2.2).
7. Executor semantics: query-typed documents now cannot invoke
   mutations; `riela graphql execute` now routes note documents
   through the same executor; root aliases, leading comments, inline
   root arguments, `$variable` substitution, and unsupported selection
   rejection are now covered (§2.3).
8. API clients: register/authenticate/revoke round trip, revoked
   rejection, plaintext-absent assertion on `token_hash`, TTL clamp,
   `pendingCodes` pruning.
9. `deleteNotebook` cascade completeness; concurrent `note_number`
   allocation; Japanese-text FTS search (documents the tokenizer
   limitation, §6.1); S3 error paths (checksum mismatch, verification
   failure must leave the local file + locator intact).
10. CLI: `readonly --on/--off`, `tag --add`, single-file storage
    migrate, `--body-file`, `--output jsonl`, usage errors.

## 6. Design-Level Improvements

1. **Japanese full-text search (high priority for the primary user).**
   `note_fts` uses `tokenize='unicode61'`, which does not segment CJK
   — Japanese queries only match whole whitespace-delimited runs, so
   the requirements memo's own use cases (速記メモ, 哲学 tags, book
   OCR in Japanese) are effectively unsearchable by body text. Switch
   to `tokenize='trigram'` (libSQL-compatible) or a dual-column
   tokenization approach **before the schema ossifies**; pair with a
   Japanese-corpus search test.
2. **Driver seam rework.** `NoteDatabaseDriving.withDatabase` exposes
   the concrete `SQLiteDatabase` class, which is what forced the
   libSQL driver into the dual-runtime hazard (§1.2/1.3). Introduce a
   narrow `NoteDatabaseSession` protocol (execute/query/transaction
   over `SQLiteValue`/`SQLiteRow`) that `SQLiteDatabase` and a
   `LibsqlConnectionSession` both conform to — `NoteService` already
   uses only those operations. `BEGIN IMMEDIATE` semantics against a
   remote-forwarding replica connection need an explicit test.
3. **One GraphQL field table** generating schema text, the routable
   set, and executor dispatch (§1.5), plus a minimal real document
   parse (§2.3) so write-vs-read enforcement is structural — this also
   future-proofs the server auth gate.
4. **Durable auto-action outbox.** An outbox table in the note store
   (event, originating action id, dispatch generation, status) fixes
   at-least-once dispatch from short-lived CLI processes, gives the
   loop guard a natural generation counter, and makes failures
   inspectable (`listAutoActions` could surface last-dispatch
   status/diagnostics).
5. **Named S3 storage profiles in note settings.** The app settings
   file now persists named profile definitions, the Note window uses
   them, Note Settings has a single-profile editor that stores only
   credential environment variable names, and app-served note API
   migrations reuse those profiles as the only network-facing migration
   input (§2.3). Remaining work is multi-profile management. CLI keeps
   raw flags for local use.
6. **Aggregated ingest dispatch** for `createNotebookWithNotes`.
   Notebook/page writes are transactional now, but dispatch still emits
   one `note-created` event per page; large PDFs need a single
   notebook-level event or bounded fan-out policy.
7. **Client identity into audit columns.** Authenticated note API
   requests now pass the `NoteAPIAuthenticatedClient.clientId` into
   `GraphQLDocumentRequest`; note mutations use `client:<id>` as the
   fallback `assignedBy`/comment author when the caller omits an
   explicit actor. Remaining work: per-client scopes (read-only
   clients) in `api_clients` while the schema is young.
8. **Streaming-capable UI client protocol** (async stream turn deltas)
   so the Note Agent can move from stub → workflow-backed without a
   second protocol break (§3 B7).
9. **Single token-mint helper.** `makeNoteAPIBearerToken` now mints
   `rn_` tokens from 32 CSPRNG bytes with base64url encoding and is
   shared by QR/challenge registration and explicit local direct
   registration.
10. **Change notification from the single writer.** The UI now has a
    WAL-file watcher for cross-process CLI writes; `NoteService` (D10)
    can still publish in-process change tokens cheaply to reduce
    filesystem churn for same-process writes.

## 7. Prioritized Remediation Plan

| Priority | Items |
| --- | --- |
| **P0 — before any further feature work** | 1.1 FTS payload fix + integrity test; 1.4 fail-closed auth gate; 1.6 stale-draft overwrite; 1.2/1.3 libSQL: disable `.embeddedReplica` (full fix via §6.2 can follow); 2.2 Linux package gating; 2.1 loop guard (`createNote` originating id + suppress-all); 2.4 filter_json kill switch |
| **P0 — UI core value** | Complete; continue hardening with the remaining P1/P2 polish below |
| **P1** | 1.5 schema/executor unification; 2.3 executor real parse + `riela graphql` note documents + serve `--note-api` wiring (with 1.4 landed first); 2.4 outbox dispatch + QR flow wiring (CLI + app, B11); 2.1 S3 streaming + SigV4 path fix; remaining B4–B10 UX items; §6.1 Japanese tokenizer |
| **P2** | B12–B15 polish; §4 minors; §5 remaining coverage; §6.7/6.9 hygiene |

Positive observations worth preserving through remediation: the
single-writer transaction discipline with post-commit dispatch, the
parameterized-SQL-only surface, the gate/executor parser unification
(`noteGraphQLRootFieldName` shared by auth gate and executor), the
sha256-only token storage, provenance-distinct tag chips, the
driver-conformance test switch, and the six example workflows running
against real SQLite/FTS assertions.

## 8. Second-Round Verification (commits `19bc062`, `e3ffd89`)

The remediation commits were re-reviewed against §1–§7 on 2026-07-04.
`swift build` passes; the suite grew to 1179 tests (0 failures, +125).
Verdicts below are code-derived, not claim-derived.

### 8.1 Confirmed fixed (with regression tests)

| Finding | Evidence |
| --- | --- |
| §1.1 FTS payload ordering | Single `ftsPayload` builder with `ORDER BY t.name`; `NoteSearch.swift:285-331`; test `testFTSRefreshUsesStableTagPayloadOrderForUpdateAndDelete` runs `integrity-check` |
| §1.2/1.3 libSQL dual runtime | `libsql-swift` dependency + product removed from `Package.swift`; `.embeddedReplica` throws `embeddedReplicaUnavailable`; one runtime per file |
| §1.4 fail-open gate | 503 `noteAPIUnavailableResponse` unless explicit `allowUnauthenticatedNoteAPI`; test inverted + `testGraphQLRouteRejectsNoteDocumentsWhenAuthenticatorIsMissing` (but see §8.3 C1) |
| §1.5 schema/executor | Names/shapes aligned; parity test asserts `supportedNoteGraphQLFields == query ∪ mutation` (kept in sync by test, not a single table — §8.4) |
| §1.6 stale-draft overwrite | `resetEditingState()` on `onChange(note.noteId)`; `expectedNoteId` guard in `saveSelectedNoteBody`; test `testViewModelRejectsStaleBodySaveAfterSelectionChanges` |
| §2.1 loop guard | `originatingActionId` on all create/update/conversation paths; suppress-all when set; three suppression tests |
| §2.1 conversation triggers, applyTag system/deletable guard, attachFile orphan, SigV4 path encoding | All fixed with tests (`testSystemAndNonDeletableTagAssignmentsCannotBeDemotedByLaterApply`, `testS3StorePercentEncodesKeyForSigV4RequestPath`, orphan-blob assertions) |
| §2.2 Linux gating, secret redaction, error drift | Dependency deleted; `CustomDebugStringConvertible` redacts token/key |
| §2.3 real parser, `riela graphql` note docs, `--append`/stdin/`delete --notebook`, migrate `--all` guard, PDF ingest page images + source doc + transactional `createNotebookWithNotes`, tag-apply provenance clamp, remote-migrate exfiltration (profile-name-only) | All fixed (parser caveats in §8.3 C2) |
| §2.4 token mint/CSPRNG, filter_json per-action isolation + diagnostics recorder | Fixed |
| §4 minors | foreign_keys pragma, schema-version gating + v1→v2 migration, atomic `replaceItemAt`, fractional-second timestamps, `ensureTag` classId validation, kind-tag id collision, capability-probe caching, FTS5 probe leak, readonly exactly-one flag, tag add+remove, `--title`, inline `--output=json`, migrate envelope parity, limit/offset clamping, notebooks `tagFilter`, example workflows — all fixed with tests |
| §6.1 Japanese tokenizer | `note_fts` now `tokenize='trigram'` (`NoteStoreSchema.swift:437-440`) + v2 migration reindex (`ensureNoteFTSUsesTrigram`, `NoteStoreSchema.swift:168-170`) + LIKE fallback in `searchNotesByTextLike` (`NoteSearch.swift:85-94, 162-246`) that fires **whenever the trigram query under-fills the requested limit** (covers <3-char queries *and* rare terms), not only short queries; tests `testSearchFindsJapaneseSubstrings`, `testPrepareRebuildsLegacyUnicodeFTSAsTrigram` |

### 8.2 Partially fixed / still open

- **§2.4 at-least-once dispatch — NOT closed.** An
  `auto_action_dispatches` outbox table now exists, but the production
  CLI dispatcher still launches the workflow in an unstructured
  detached `Task` nothing awaits
  (`NoteAutoActionWorkflowDispatcher.swift:15-23,171-181`); a promptly
  exiting CLI kills the run, and the row is marked `dispatched` =
  "launched", not "completed". No production code calls
  `retryPendingAutoActionDispatches()` /
  `listAutoActionDispatchAttempts()` (tests only), so pending/failed
  rows are never retried or surfaced. The seeded AI-tagging action
  still effectively never completes from CLI writes. Additionally the
  outbox stores full `event_json` (including `noteBodyMarkdown`) per
  matching action and is never pruned — unbounded growth.
- **serve `--note-api` — still no socket.** The flag parses, note root
  resolves, and the route handler is built with executor +
  authenticator, but there is no `bind`/`NWListener`/NIO anywhere in
  `Sources/RielaServer` or `Sources/RielaCLI`. `noteAPIServeResponse`
  routes exactly one in-process request and the process exits; the
  printed `endpoint`/QR URL points at a port nothing listens on. D14
  remains not shippable end-to-end.
- **QR registration — unredeemable end-to-end.** Real CoreImage QR
  rendering (CLI half-block + app sheet) and `createRegistrationChallenge`
  wiring landed, but both the CLI serve process and the app settings
  sheet create a *throwaway* `QRClientRegistrationAuthenticator` whose
  in-memory `pendingCodes` no serving instance shares (app base URL is
  `riela-note://app`). No scan can redeem a code. `pendingCodes` is
  still never pruned, and there is still no rate limiting.
- **S3 streaming — partial.** Migration no longer double-transfers
  (verification GET is opt-in `verifyRemoteRead: false`) and local
  hashing streams in 1 MiB chunks, but S3 upload/read still buffer the
  whole payload in memory; no `uploadTask(withFile:)`, no
  download-to-temp, no `x-amz-checksum-sha256`/HEAD verification. Note
  the default migration flipped from verify-always to verify-never
  before deleting the local copy — weaker than before.
- **PDF ingest fan-out (§6.6) — not done.** Page image/source-doc
  attachment and transactional note creation landed, but each page
  still dispatches its own `note-created`; a 300-page ingest fans out
  300 auto-action dispatches.
- **UI — B4 search (no debounce/highlight/notebook caption), B6 file
  chips (no Quick Look / context menu / cloud badge; whole file into
  memory), B7 Note Agent (still a canned FTS echo — no workflow/LLM/
  streaming), B11 settings (no listener, no host/port), B12 config
  agent (untouched), B13 block markdown (untouched), A3 error-text
  mapping (untouched — 22× `String(describing: error)` shown to
  users).** These match the areas the updated doc marks partial.
- **CLI storage profiles, addon app-profile-context resolution step —
  NOT fixed.**

### 8.3 New defects introduced by the remediation (must fix before ship)

- **C1 (critical) — multi-operation GraphQL bypasses the note-API auth
  gate.** `ServerContracts.swift:197` gates on
  `noteGraphQLRootFieldName(in: envelope.query)`, which reaches
  `NoteGraphQLDocumentExecutor.swift:302-314` and there hardcodes
  `operationName: nil` (line 306 → returns the *first* operation's root
  field), while the executor path runs the operation named by
  `request.operationName`
  (`NoteGraphQLDocumentExecutor.swift:63-74`, calling
  `parseNoteGraphQLRootField(... operationName: request.operationName ...)`).
  A document `query A { workflowSession } mutation Evil { deleteNote(...) }`
  with `operationName: "Evil"` skips auth (gate sees the query field
  `workflowSession`) and executes `deleteNote` unauthenticated —
  re-opening §1.4 through the front door. Confirmed independently by
  two reviewers and a third code-derived verification pass. Fix: pass
  `envelope.operationName` into the gate at `ServerContracts.swift:197`
  (or require auth if *any* operation in the document contains a note
  root field); add a regression test. Root cause is two independent
  hand-rolled GraphQL parsers disagreeing — see the architecture doc's
  "unify the GraphQL front door" item and §9 WP-A below.
- **C2 (critical when networked) — `GET /note/register` is an
  unauthenticated token-minting oracle.** `ServerContracts.swift:115-116`
  routes GET to `routeNoteRegistrationChallenge` →
  `QRClientRegistrationAuthenticator.swift:88-100`, which creates a
  challenge with no auth check (line 93) and returns the code in the
  response body; a POST with that code mints a bearer token. The
  moment a real socket serves this route, any network peer
  self-registers a valid client in two requests, and `pendingCodes`
  grows per GET (memory DoS). Additionally
  `registrationBaseURL(from:)`
  (`QRClientRegistrationAuthenticator.swift:243-251`) builds the QR/
  redirect URL from client-supplied `x-forwarded-proto` (line 248) and
  `host` (line 249) headers with no validation. Fix: challenge
  creation must be operator-privileged (local/authenticated); the
  public route should at most *redeem* a pre-created challenge; pin the
  base URL to configured host/scheme, never client headers.
- **C3 (parser data corruption) — `NoteGraphQLDocumentParsing.swift`.**
  Verified sub-defects, each with a line anchor:
  - Block strings (`"""…"""`) are unhandled — `skipGraphQLStringLiteral`
    (lines 512-531) and `readGraphQLString` (lines 396-431) treat the
    opening `"""` as an empty `""` followed by a stray `"`, desyncing
    the balanced-brace scanner.
  - `\uXXXX` / `\b` / `\f` escapes hit the default branch in
    `readGraphQLString` (line 424) and are appended *literally*, so a
    string carrying them is corrupted into the stored note body/title.
  - Operation variable *default values* are discarded — the variable-
    definition parens are consumed with `skipGraphQLBalanced` without
    reading defaults (lines 66-68).
  - The `missingVariable` recovery `continue` only guards *root-level*
    arguments (`parseGraphQLArguments`, lines 240-242); `parseGraphQLObject`/
    `parseGraphQLArray` have no equivalent guard, so a missing variable
    inside a nested value propagates differently than at top level.
  - Multiple root selections in one operation are not rejected; only
    the first is dispatched (same operation-resolution weakness that
    feeds C1).
  Fix: reject multiple root selections and reject (or correctly
  implement) block strings and `\u`/`\b`/`\f` escapes rather than
  silently corrupting data. Folding this parser into the single shared
  tokenizer (§9 WP-A) is the durable fix.
- **C4 (high, UI) — a saved S3 profile can brick the Notes window.**
  `NoteWindowController.init` (line 24) eagerly calls
  `RielaAppNoteS3ProfileResolver().profiles(...)`, and
  `S3StorageProfile.environmentBacked` throws `missingEnvironmentValue`
  when an env var is unset (`NoteFileStore.swift:94-98`); the settings
  editor validates only that env-var *names* are non-empty. Finder-
  launched GUI apps don't inherit shell env, so saving a plausible
  profile makes `openNotes` fail permanently (status-bar message only)
  until the user finds and clears the profile. Fix: resolve credentials
  lazily at file-resolve time; surface a per-file error, never fail
  window construction.
- **C5 (UI) — QR "Register Client" sheet is unredeemable** (same root
  cause as §8.2; listed here because it is new UI presented as
  working). The app settings window constructs *two separate*
  `QRClientRegistrationAuthenticator` instances — one to mint the code
  (`NoteSettingsWindowController.swift:382`) and a fresh one that would
  redeem it (`:388`) — so the redeeming instance's `pendingCodes` is
  empty; `WorkflowServingController.swift:405` likewise builds a new
  authenticator per generation, and base URLs diverge
  (`riela-note://local` in `NoteCommands.swift:499` vs
  `riela-note://app` at `NoteSettingsWindowController.swift:383,389`).
  Expired codes are also never pruned (only removed on successful
  redeem, `QRClientRegistrationAuthenticator.swift:124`). Persist
  challenges in the note store, or hold one long-lived serving
  authenticator, and add TTL-based pruning.
- **Medium UI races:** incremental search has no debounce/cancellation/
  stale-guard, so a slow response for `"a"` can overwrite results for
  `"ab"` (the adjacent link-target search *does* guard — inconsistent);
  note paging awaits adjacent-image prefetch inline, so Cmd-Right pays
  for next+previous S3 downloads before showing the page; rapid
  selection has no stale guard (image for note A can land on note B);
  `resolvedFileCache`/`decodedSourceImageCache` are unbounded and now
  cache whole *videos* — multi-GB for a large book. Split the 826-line
  `RielaNoteLibraryViewModel` god object and add one shared
  stale-guarded `withLoadState` helper.
- **Minor:** `note edit --append` is read-modify-write with no
  concurrency guard (lost updates); `executeNoteGraphQLDocument` addon
  splices field payload over envelope keys without a `where
  payload[key] == nil` guard; `migrateAllNoteFiles` runs blocking S3
  I/O inline on the async executor path; S3 profile resolution and
  note-root default are now duplicated in 3–4 places each; error
  detail (`String(describing:)`, potential DB paths) is returned to
  unauthenticated clients.

### 8.4 Structural note carried forward

The GraphQL note surface is now maintained as five hand-synchronized
structures (SDL text, `supportedNoteGraphQLFields`,
`noteGraphQLQueryFields`, selection-type table, selection-field table)
plus two independent hand-rolled GraphQL lexers (the server auth gate
and `NoteGraphQLDocumentParsing`). C1 and C3 are both direct
consequences. The single-field-table + single-tokenizer consolidation
recommended in §1.5/§6.3 was not adopted and should be treated as the
structural fix that closes this class of bug — see the companion
architecture review (`design-riela-architecture-review.md`,
"unify the GraphQL front door").

### 8.5 Revised priority for the next pass

1. **C1** auth-gate multi-operation bypass (invalidates §1.4) and
   **C2** `GET /note/register` oracle — both before any real socket.
2. **C3** parser data corruption (multiple root fields, block strings,
   `\u` escapes).
3. **C4** S3-profile-bricks-window and **C5** unredeemable QR — before
   the Note window/API ships to a user.
4. **§2.4** dispatch outbox drain + bounded await (the biggest
   remaining functional gap for the seeded AI-tagging loop) and outbox
   retention.
5. UI polish debt: A3 error mapping, B4 debounce+stale-guard, B7
   workflow-backed agent, B13 block markdown; ViewModel split.
6. Remaining §8.2 partials (S3 streaming, PDF fan-out, CLI storage
   profiles, addon profile-context).

The §8.3/§8.5 list is historical review input. A later verification
pass is recorded in §8.6; use that current-status section before
planning any remediation from C1-C5.

### 8.6 Current-status verification after follow-up fixes

Re-verified on 2026-07-05 against the current working tree:

- **C1 closed for the shipped server gate.** The GraphQL route resolves
  named operations before deciding whether note API authentication is
  required, and regression coverage exists in
  `ServerContractsTests.testGraphQLRouteRejectsAmbiguousMultiOperationNoteDocumentWithoutOperationName`
  and
  `ServerContractsTests.testGraphQLRouteRejectsMultiOperationNoteMutationByResolvedOperationName`.
- **C2 partially closed / still gated by no socket.** Registration
  challenge storage and TTL/cap behavior have been hardened, and no
  production `serve --note-api` socket is currently bound. A real
  listener must still avoid minting challenges from unauthenticated GET
  requests and must not trust request headers for public registration
  URLs.
- **C3 closed for the covered parser defects.**
  `NoteGraphQLParsingRegressionTests` covers block strings, escapes,
  variable defaults, multiple root selection rejection, and nested
  missing-variable handling. Parser size/depth limits are now covered
  as well.
- **C4 residual remains.** Saved malformed endpoints/regions can still
  surface during profile resolution; window construction should stay
  tolerant and defer credential resolution to file access.
- **C5 closed for shared challenge storage, but remote redemption is not
  shipped.** QR/client challenge state no longer depends on two
  unrelated in-memory authenticator instances, but end-to-end remote
  redemption still depends on WP-E's real listener.

Revised priority from this point: keep WP-E (`serve --note-api` socket)
behind parser/auth/registration gates, treat C4 as the remaining C-series
UI hardening item, and use the newer branch review document for
auto-action, projection, data-loss, and UI race findings.

## 9. Detailed Implementation Plan

This section turns §8.5's ordered list into concrete work packages
(WP-A … WP-H). Each WP is independently landable and states: **goal**,
**files**, **change**, new **signatures**, **tests**, **acceptance**,
and **dependencies/sequencing**. WPs are ordered so that no WP depends
on a later one. "LOC" estimates are order-of-magnitude for planning,
not commitments.

Sequencing at a glance:

```
WP-A (GraphQL front door) ─┬─► closes C1, C3, §1.5, §8.4
WP-B (registration security)┤   (independent of A, do in parallel)
WP-C (S3 profile lazy init) ┘   closes C2, C5 / C4
        │
        ▼
WP-D (dispatch outbox drain) ──► closes §2.4
        │
        ▼
WP-E (serve --note-api socket) ─► needs A+B+D landed first (D14)
        │
        ├─► WP-F (S3 streaming)       ┐ parallelizable after E
        ├─► WP-G (PDF ingest fan-out) │ (independent of each other)
        └─► WP-H (UI debt)            ┘
```

### WP-A — Unify the GraphQL front door (closes C1, C3, §1.5, §8.4)

**Goal.** One tokenizer and one operation-resolution path shared by the
server auth gate and the note document executor, plus one field table
driving SDL text, the routable set, and executor dispatch — so auth,
parse, and schema can no longer disagree.

**Files.**
- `Sources/RielaGraphQL/NoteGraphQLDocumentParsing.swift` (the surviving
  tokenizer; ~547 lines today).
- `Sources/RielaServer/ServerContracts.swift:197, 337-416`
  (`graphqlTokens`, the second lexer — delete and re-point).
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift:63-74, 302-315`.
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
  `supportedNoteGraphQLFields`, `noteGraphQLQueryFields`, and the
  selection tables (the five hand-synced structures from §8.4).

**Change (three steps, land in order).**
1. **Operation-aware gate (fixes C1 immediately, minimal diff).** Add a
   parameter to the shared root-field resolver and thread the request's
   operation name through the gate:
   ```swift
   // NoteGraphQLDocumentParsing.swift
   func noteGraphQLRootFields(in document: String,
                              operationName: String?) throws -> [NoteGraphQLRootField]
   // returns ALL root selections of the resolved operation, not just the first
   ```
   At `ServerContracts.swift:197` call it with `envelope.operationName`
   and require auth if **any** returned field is a note mutation (or any
   note field when no authenticator is configured). This step alone
   closes C1 and can ship ahead of the full unification.
2. **Single tokenizer.** Delete `graphqlTokens` in `ServerContracts.swift`
   and have the gate call the `NoteGraphQLDocumentParsing` tokenizer.
   Fix the tokenizer's C3 defects as part of the move: handle `"""…"""`
   block strings in `skipGraphQLStringLiteral`/`readGraphQLString`; map
   `\u{XXXX}`/`\b`/`\f`/`\n`/`\r`/`\t` in the escape switch (replace the
   literal-append default at line 424 with a `throw .invalidEscape`);
   read (or explicitly reject with a diagnostic) variable default values
   at lines 66-68; add the nested `missingVariable` guard in
   `parseGraphQLObject`/`parseGraphQLArray`; and **reject** documents
   with >1 root selection per operation unless multi-field execution is
   deliberately implemented.
3. **One field table.** Introduce a single `NoteGraphQLField` descriptor
   list `{ name, kind: .query|.mutation, args, payloadType }` and derive
   the SDL string, `supportedNoteGraphQLFields`, `noteGraphQLQueryFields`,
   and the executor dispatch switch from it (replaces the ~146-line
   string switch in `executeMutation`, arch review Theme 5).

**Tests.**
- `testMultiOperationDocumentGatedByResolvedOperationName` — the C1 PoC
  (`query A { workflowSession } mutation Evil { deleteNote }` +
  `operationName:"Evil"`) returns 401/503, not a delete.
- `testAuthGateAndExecutorAgreeOnRootField` — property-style: for a
  corpus of documents, `gate.rootFields(op)` and
  `executor.resolvedField(op)` name the same field.
- `testParserHandlesBlockStringsAndUnicodeEscapes`,
  `testParserRejectsMultipleRootSelections`,
  `testParserRejectsUnknownEscape`.
- `testSchemaFieldTableIsSingleSourceOfTruth` — every SDL-published note
  root field is routable and vice versa (replaces the current sync test).

**Acceptance.** No note mutation executes unauthenticated for *any*
`operationName`; a document with block strings / `\u` escapes either
round-trips exactly or is rejected with a diagnostic (never stored
corrupted); `ServerContracts.swift` contains zero GraphQL tokenizing
code.

**Dependencies.** None. Step 1 is the hotfix; steps 2–3 are the durable
structural fix and can follow. Shared with the architecture review's P0
"unify the GraphQL front door" — do it once, reference from both docs.

### WP-B — Registration security (closes C2; prerequisite for C5/D14)

**Goal.** Challenge *creation* becomes operator-privileged; the public
route can only *redeem* a pre-created challenge; the registration base
URL is pinned to configured host/scheme, not client headers; expired
challenges are pruned.

**Files.**
- `Sources/RielaServer/ServerContracts.swift:115-116` (GET route),
  `:250-260`.
- `Sources/RielaServer/QRClientRegistrationAuthenticator.swift:56, 78,
  88-100, 124, 243-251`.

**Change.**
1. Split the route: `GET /note/register` (public) may only *look up /
   redeem* an existing challenge; challenge **creation** moves to an
   operator-only entry point (local CLI/app, or an authenticated admin
   header). Wire the route dispatch in `ServerContracts.swift:115-116`
   accordingly.
2. Replace `registrationBaseURL(from: request)` header trust
   (`:243-251`) with a value pinned from `RielaServerConfiguration`
   (configured public host + scheme); ignore `Host`/`X-Forwarded-Proto`
   unless an explicit `trustedProxy` flag is set.
3. Add TTL pruning: prune expired entries from `pendingCodes` on every
   create/redeem and on a timer; cap the map size and reject creation
   past the cap (anti-DoS). Add per-IP/global rate limiting on redeem +
   bearer auth (the "Minor but worth tracking" item in §2.4).

**Signatures.**
```swift
func createRegistrationChallenge(operator: OperatorContext,
                                 publicBaseURL: URL) throws -> RegistrationChallenge
func redeemRegistrationChallenge(code: String, now: Date) throws -> NoteAPIBearerToken
func pruneExpiredChallenges(now: Date)
```

**Tests.** `testUnauthenticatedGETCannotCreateChallenge`,
`testPublicRouteCanOnlyRedeem`, `testBaseURLIgnoresClientHostHeader`,
`testExpiredChallengesArePruned`, `testChallengeMapIsBounded`.

**Acceptance.** An unauthenticated network peer cannot mint a token or
grow server memory unboundedly; the QR URL always reflects the
operator-configured host.

**Dependencies.** None. Must land before WP-E exposes a real socket.

### WP-C — S3 profile lazy resolution + shared registration instance (closes C4, C5)

**Goal.** Constructing the Notes window never fails on a mis-configured
S3 profile; the QR challenge minted in one place is redeemable in
another.

**Files.**
- `Sources/RielaApp/NoteWindowController.swift:24, 74-84`.
- `Sources/RielaNote/NoteFileStore.swift:83-111` (`environmentBacked`).
- `Sources/RielaApp/NoteSettingsWindowController.swift:382, 388`,
  `Sources/RielaCLI/WorkflowServingController.swift:405`.

**Change.**
1. **C4:** move credential resolution out of `init`. `NoteWindowController.init`
   stores the *profile definitions*; `S3StorageProfile.environmentBacked`
   resolves env vars lazily at first `resolveFile`/`store` call and
   surfaces `missingEnvironmentValue` as a *per-file* error, not a
   constructor throw. The settings editor gains a "Test profile" action
   that resolves eagerly on demand so the user gets feedback without
   bricking the window.
2. **C5:** hold a single long-lived `QRClientRegistrationAuthenticator`
   (or persist `pendingCodes`/challenges in the note store) shared by
   the minting and redeeming code paths; unify the base URL constant
   (drop the `riela-note://local` vs `riela-note://app` split). This
   builds on WP-B's persistence/pruning.

**Tests.** `testNoteWindowOpensWithUnresolvableProfile`,
`testMissingEnvSurfacesPerFileNotAtInit`,
`testChallengeMintedInSettingsIsRedeemable`.

**Acceptance.** Saving a profile whose env vars are unset still lets the
window open and shows a clear per-file error on access; a code shown in
the settings sheet redeems successfully.

**Dependencies.** C5 half depends on WP-B's shared challenge store.

### WP-D — Durable auto-action dispatch (closes §2.4)

**Goal.** The seeded AI-tagging action (and any auto-action) actually
runs to completion from short-lived CLI processes, with retry and
bounded retention.

**Files.**
- `Sources/RielaNote/AutoActionDispatching.swift:170-192, 208-230`.
- `Sources/RielaNote/NoteStoreSchema.swift:408-425`
  (`auto_action_dispatches`).
- `Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift:18-22,
  171-181, 341`.

**Change.**
1. Add a terminal `completed`/`failed` state to the outbox status enum
   (schema currently only allows `pending`/`dispatched`); mark
   `dispatched` only *after* the workflow returns, and record failure +
   last diagnostic on throw.
2. For CLI writes, either (a) **bounded await** the dispatch before the
   process exits (simplest; add a deadline), or (b) a detached child
   process that drains the outbox. Preferred: a `drainAutoActionDispatches()`
   step invoked by `riela note add`/`edit` and at daemon startup that
   calls the already-present `retryPendingAutoActionDispatches()` (today
   it has **zero production callers** — tests only).
3. **Retention:** stop storing the full `event_json` BLOB
   (`AutoActionDispatching.swift:208-230`) verbatim — store only the
   fields the workflow needs (ids + trigger), or prune completed rows on
   a schedule. Add a size/age cap.

**Tests.** `testDispatchMarkedCompletedOnlyAfterWorkflowReturns`,
`testCLIWriteDrainsPendingDispatchesBeforeExit`,
`testFailedDispatchIsRetried`, `testCompletedOutboxRowsArePruned`.

**Acceptance.** After `riela note add` exits, the seeded AI-tag workflow
has run (or is provably queued and drained on next invocation); the
outbox does not grow without bound.

**Dependencies.** Independent of A–C, but should land before WP-E so the
served API's writes also drain.

### WP-E — Real socket for `serve --note-api` (D14)

**Goal.** `riela serve --note-api` binds a real listener and serves the
note GraphQL route with auth (WP-A/B) and dispatch drain (WP-D).

**Files.**
- `Sources/RielaCLI/ScopedParityCommands+Serve.swift:48-81`
  (`noteAPIServeResponse`, today an in-process one-shot handler).
- `Sources/RielaServer` (add the listener type).

**Change.** Add a real `NWListener`/NIO bind behind the flag, routing
requests through the existing `ServerContracts` handler (now
operation-aware), the shared long-lived `QRClientRegistrationAuthenticator`,
and the outbox drain. Print the actual bound host/port and a QR URL that
points at a port something listens on. Enforce request/attachment size
caps (arch review "no request/attachment size limits").

**Tests.** `testNoteAPIListenerServesAuthenticatedMutation` (integration:
bind ephemeral port, register via operator path, redeem, execute a
mutation, assert persisted), `testUnauthenticatedMutationRejectedOverSocket`.

**Acceptance.** D14 is end-to-end demonstrable: a second process can
register (operator-approved) and drive note mutations over the socket;
unauthenticated mutations are rejected for all `operationName`s.

**Dependencies.** WP-A (C1), WP-B (C2), WP-D. Do not ship the socket
before these land — that is the ordering §8.5 items 1–4 encode.

### WP-F — S3 streaming (closes §2.1 S3 / §8.2 S3 partial)

**Goal.** Uploads/reads/migration stop buffering whole video/PDF
payloads in memory; verification uses checksums, not a full GET.

**Files.** `Sources/RielaNote/S3NoteFileStore.swift:22-39, 41-75`,
`Sources/RielaNote/NoteFileMigration.swift:30, 84`.

**Change.** Replace `store(data:)`/`read()` with
`uploadTask(withFile:)`/download-to-temp streaming; send
`x-amz-checksum-sha256` on PUT and verify via that header or a HEAD
instead of the opt-in full GET. Re-evaluate the migration's
verify-never-before-delete default (`NoteFileMigration.swift:30`) — at
minimum verify checksum before deleting the local copy.

**Tests.** `testS3UploadStreamsFromFile`, `testMigrationVerifiesChecksumBeforeLocalDelete`,
`testLargeFileDoesNotBufferWholePayload` (memory-ceiling assertion where
feasible).

**Acceptance.** A multi-hundred-MB file migrates without ~2× peak memory
and is not deleted locally until the remote copy is checksum-verified.

**Dependencies.** None; parallelizable after WP-E.

### WP-G — PDF ingest fan-out bound (closes §6.6)

**Goal.** A 300-page ingest does not fan out 300 auto-action dispatches.

**Files.** `Sources/RielaNote/NoteService.swift:274-283`
(`createNotebookWithNotes` per-note dispatch loop),
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift:291-322`.

**Change.** Emit a single notebook-level `notebook-created` (and/or a
bounded, batched `notes-created`) event for a multi-note ingest instead
of one `note-created` per page, or add an explicit fan-out policy/cap on
the ingest path. Coordinate with WP-D's outbox so batched events drain
once.

**Tests.** `testLargeIngestEmitsBoundedDispatches`.

**Acceptance.** Ingesting N pages produces O(1) (or a configured cap),
not O(N), auto-action dispatches.

**Dependencies.** Best after WP-D (shared dispatch path).

### WP-H — UI debt (B4, B7, B12/B13, error mapping, ViewModel split)

**Goal.** Close the reviewer-flagged UI correctness/UX debt.

**Files.** `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`
(826 lines — split), `RielaNoteUIClient.swift:115-129, 158-189`,
`RielaNoteComponents.swift:65-77`, plus the 22 `String(describing: error)`
call sites.

**Change (independent sub-items, prioritize B7 + error mapping + B4):**
- **B7 Note Agent:** dispatch the packaged note-agent workflow
  (`riela/note-search` retrieval → agent worker) through the same
  execution entry points the event listener uses; move the client
  protocol to `AsyncThrowingStream<TurnDelta, Error>` (§6.8) so streaming
  and Stop work without a second protocol break.
- **B4 search:** add debounce + cancellation + a stale-response guard
  (a slow `"a"` response must not overwrite `"ab"`); reuse the guard the
  link-target search already has. Extract one shared stale-guarded
  `withLoadState` helper.
- **A3 error mapping:** replace `String(describing: error)` (22×) with a
  user-facing error → message mapping; split error state per surface
  (list vs detail vs image).
- **Unbounded caches:** bound `resolvedFileCache`/`decodedSourceImageCache`
  with an LRU (they currently cache whole videos — multi-GB risk).
- **B13 block markdown:** parse blocks into a `LazyVStack`; resolve
  `![...](file-id)` embedded images through `resolveFile`.
- **ViewModel split:** decompose the 826-line god object into
  search/detail/agent/paging responsibilities.

**Tests.** `testSearchDebouncesAndDropsStaleResponses`,
`testNoteAgentDispatchesWorkflowAndStreamsDeltas`,
`testErrorSurfacesHumanReadableMessage`,
`testFileCacheEvictsUnderMemoryPressure`.

**Acceptance.** Note Agent answers via a real workflow with a Stop
button; rapid typing never shows stale results; users never see
`RielaNoteError(...)`-style raw text; caches are bounded.

**Dependencies.** B7 benefits from WP-E's execution wiring but the
streaming-protocol change (§6.8) can land independently.

### Cross-cutting acceptance gate for "Note API ships to a user"

Do not expose the Note API/window to a non-local user until **WP-A step 1,
WP-B, WP-C, and WP-D** are all landed with the tests above green, plus a
Linux `swift build && swift test` job (§2.2) and the libsql CI leg
(§2.2) if the libSQL product is re-introduced.
