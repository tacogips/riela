# Riela Note New Features Implementation Plan

**Status**: Planning
**Design Reference**: design-docs/specs/design-riela-note-new-features-2026-07-12.md
**Created**: 2026-07-12
**Last Updated**: 2026-07-12

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-new-features-2026-07-12.md
(F1 Anywhere Capture, F2 Entity Pages, F3 Scoped Ask; provenance in
`design-docs/references/riela-note-new-feature-selection-2026-07-12.json`)

### Summary

Three features on the shipped Riela Note stack: **F1** binds
`riela serve --note-api` to a real HTTP socket (Network.framework) with
registration/capture pages and an authenticated `/note/capture` endpoint
feeding one accumulating "Quick Memos" notebook with live auto-actions;
**F2** makes every tag a destination — an aggregation Entity Page
(notes grouped by notebook, co-tags) plus promote-to-canonical-note,
backed by `tags.entity_note_id`; **F3** generalizes SelectionQA to the
live filter scope — ask a question over the filtered corpus, cited
answer, save as an agent-conversation note with `source-citation` links.

### Scope

**Included**: `Sources/RielaServer` HTTP transport + capture handler +
route/auth changes, `Sources/RielaCLI` serve run-loop + dispatcher
wiring, `Sources/RielaNote` schema/service entity-page additions,
`Sources/RielaGraphQL` entity-page parity, `Sources/RielaNoteUI` entity
page + scoped-ask UI/provider, `examples/note-scoped-ask` bundle, tests.

**Excluded** (design-doc non-goals): TLS / external auth,
capture-scoped tokens, offline queue / share sheet / native iOS app,
HTTP keep-alive/chunked/HTTP/2, phone browsing UI, entity
merge/rename/aliasing, auto-promotion, timeline views, vector
retrieval, streaming answers, GraphQL exposure of scoped ask.

**Compatibility**: none. Schema and APIs change in place; the note DB
may be recreated. No migrations, no compat shims, no deprecated paths.

---

## Task Breakdown

### F1 — Anywhere Capture

### TASK-001: HTTP transport + envelope extensions
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `Sources/RielaServer/NWListenerHTTPTransport.swift` (new) —
  Network.framework listener under `#if canImport(Network)`:
  ```swift
  public final class NWListenerHTTPTransport: WorkflowServeListenerHandle {
    public init(host: String, port: Int, routeHandler: any ServerRouteHandling,
                context: ServerRequestContext) throws
    public var endpoint: String { get }   // resolved http://host:port
    public func shutdown() async throws
  }
  ```
  HTTP/1.1 subset: request line + headers + `Content-Length` body only,
  `Connection: close` per response, 12 MiB body cap, 30 s per-request
  deadline. Parses into `ServerRequestEnvelope`, serializes
  `ServerResponseDescriptor`. Failure responses are fixed bodies —
  `400 {"error":"malformed request"}`, `413 {"error":"request body too
  large"}`, `408` on deadline; the transport never interpolates
  exception text.
- `Sources/RielaServer/ServerContracts.swift` —
  `ServerRequestEnvelope` gains `public var query: [String: String]`
  (default `[:]`); transport splits the request target at the first
  `?`, percent-decodes pairs into `query`, keeps `path` query-free.
  `ServerResponseDescriptor` gains `public var htmlBody: String?`
  (default `nil`); when set the transport writes it verbatim with
  `contentType` instead of encoding the JSON `body`.
- Tests — `Tests/RielaServerTests/NWListenerHTTPTransportTests.swift`
  (new): request-line/header/body parsing, query-string split into
  `envelope.query`, percent-decoding, body-cap 413, malformed 400,
  deadline 408, htmlBody serialization; integration round trip on a
  real socket at an ephemeral port (`/healthz` 200).

**Checklist**:
- [ ] Transport binds/parses/serializes with fixed error bodies
- [ ] `query` + `htmlBody` contract fields; in-process consumers unaffected
- [ ] Unit + ephemeral-port integration tests pass

---

### TASK-002: Routes, registration/capture pages, error sanitization
**Status**: NOT_STARTED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaServer/ServerContracts.swift`
  (`DeterministicServerRouteHandler.route`, currently `:96`) — route
  changes:
  - `GET /note/register` (code from `request.query["code"]`) → serves
    the registration page HTML. **Delete** the challenge-mint route
    `routeNoteRegistrationChallenge` (`:116`) and the routed protocol
    method `createRegistrationChallenge(request:context:)`; no HTTP
    path mints challenges (unknown paths get the default 404).
  - `POST /note/register` → existing redeem logic unchanged.
  - `GET /note/capture` → capture page HTML (static shell, no data).
  - `POST /note/capture` → forwards to `NoteCaptureHandler` (TASK-003)
    after bearer auth.
- New `Sources/RielaServer/NoteCapturePages.swift` — inline HTML string
  constants: registration page (device-name field + Register button →
  `POST /note/register`, stores `credential.bearerToken` in
  `localStorage["riela-note-token"]`, redirects to `/note/capture`) and
  capture page (textarea, `<input type=file accept=image/*
  capture=environment>`, Send → authenticated `POST /note/capture`,
  checkmark + clear on success; `apple-mobile-web-app-capable` meta +
  inline manifest). No external assets.
- `Sources/RielaServer/QRClientRegistrationAuthenticator.swift` —
  sanitize the two known leaks (design-doc F24/F25): redeem catch-all
  (`:123`) becomes `500 {"error": "registration failed"}`; authenticate
  catch-all (`:160`) becomes
  `noteAPIUnauthorizedResponse("note API authentication failed")`;
  underlying errors logged via `context.telemetry` only. Blanket rule
  for every F1 surface: no `"\(error)"` / `localizedDescription` in any
  `ServerResponseDescriptor` body.
- Tests — extend `Tests/RielaServerTests/ServerContractsTests.swift`
  and `NoteAPIAuthTests.swift`: `GET /note/register?code=…` returns the
  page via `envelope.query`; former challenge path 404s; forced
  service-layer failures on redeem/authenticate return exactly the
  fixed strings and never contain the thrown error's description.

**Checklist**:
- [ ] Register/capture page routes; challenge-mint route deleted
- [ ] Redeem/auth 4xx/5xx bodies sanitized (F24/F25)
- [ ] Sanitization + routing tests pass

---

### TASK-003: Capture endpoint + single-notebook policy
**Status**: NOT_STARTED
**Depends On**: TASK-002
**Deliverables**:
- `Sources/RielaServer/NoteCaptureHandler.swift` (new):
  ```swift
  struct NoteCaptureRequest: Decodable {
    var text: String?           // markdown body; required unless photo present
    var photoBase64: String?    // decoded ≤ maxAttachmentBytes (8 MiB)
    var photoMediaType: String? // required with photoBase64
  }

  public actor NoteCaptureHandler {
    public let service: NoteService
    public func capture(_ request: ServerRequestEnvelope,
                        client: NoteAPIAuthenticatedClient) async -> ServerResponseDescriptor
  }
  ```
  Per capture: (1) `service.listNotebooks(limit: 1, tagFilter:
  ["notebook-kind:user-memo"], sort: .createdAtAsc)`; (2) if absent,
  `service.createNotebook(title: "Quick Memos", kindTagName:
  "notebook-kind:user-memo")`; (3) `service.createNote(notebookId:…,
  bodyMarkdown:…, readOnly: false, tags: [NoteTagInput(name: "ノート",
  classId: "content-kind")], provenance: .human, assignedBy:
  "capture:<clientId>")`. Actor serialization prevents duplicate
  first-capture notebooks. Photo via `service.attachFile(noteId:data:
  role:.related, mediaType:originalFilename:position:0)`; photo-only
  body `# Photo memo <timestamp>`. Responses: `200 {noteId, notebookId,
  title}`; `400 {"error":"<fixed reason>"}` (empty / oversize / bad
  base64 / missing `photoMediaType` — fixed strings); `500
  {"error":"note capture failed"}` with the caught error telemetry-only;
  on `attachFile` failure after `createNote`, delete the note before
  returning 500.
- Tests — `Tests/RielaServerTests/NoteCaptureHandlerTests.swift` (new):
  two text POSTs on a fresh DB yield exactly one `Quick Memos` notebook
  (kind-tagged) with two `ノート`-tagged notes; photo attach round trip;
  each 400 branch; 500 path deletes the half-captured note and leaks no
  error text; concurrent first captures create one notebook.

**Checklist**:
- [ ] Handler with find-or-create accumulating notebook (actor-guarded)
- [ ] Photo attach + rollback-on-attach-failure
- [ ] Fixed-body error responses; handler tests pass

---

### TASK-004: Serve run-loop, dispatcher wiring, end-to-end
**Status**: NOT_STARTED
**Depends On**: TASK-001, TASK-002, TASK-003
**Deliverables**:
- `Sources/RielaServer/WorkflowServingController.swift` —
  `InProcessWorkflowServeListenerFactory` gains
  `autoActionDispatcher: any AutoActionDispatching` (default remains
  the hard-failing `ServedNoteAPIAutoActionDispatcher` stub, `:520`,
  for embedded use).
- `Sources/RielaCLI/ScopedParityCommands+Serve.swift` — replace
  print-and-exit with: build factory passing
  `NoteAutoActionWorkflowDispatcher`
  (`Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`), start
  `NWListenerHTTPTransport` with the factory's route handler, print
  endpoint + terminal QR (existing `qrText`), warn when binding a
  non-loopback `--host` (default stays `127.0.0.1`), then run a stdin
  loop: `r` + Enter mints and prints a fresh challenge via
  `createRegistrationChallenge(publicBaseURL:)`; SIGINT/Ctrl-C →
  `shutdown()`. Non-macOS platforms error out
  (`#if canImport(Network)` guard).
- Tests — extend
  `Tests/RielaServerTests/WorkflowServingControllerTests.swift`:
  dispatcher injection reaches `enqueueAutoActions` →
  `dispatchQueuedAutoActions` (spy dispatcher; embedded default still
  fails hard). Socket integration test (with TASK-001's harness):
  register-redeem → bearer → `POST /note/capture` 200; missing/revoked
  bearer 401; oversize body 413/400 with no service side effects;
  `GET /note/register?code=…` reaches the registration page handler.

**Checklist**:
- [ ] Factory dispatcher injection (CLI real, embedded stub)
- [ ] Serve binds, prints QR, stdin `r` re-mint, clean SIGINT shutdown
- [ ] Full-socket auth/capture integration tests pass

---

### F2 — Entity Pages

### TASK-005: Entity schema, service aggregation, GraphQL parity
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNote/NoteStoreSchema.swift` — edit in place (DB
  recreated): `tags` gains
  `entity_note_id TEXT REFERENCES notes(note_id)`; seed system tag
  `notebook-kind:entity` alongside the existing notebook-kind tags.
- `Sources/RielaNote/NoteService.swift` — `deleteNote` additionally
  clears any `tags.entity_note_id` pointing at the deleted note.
- `Sources/RielaNote/NoteService+EntityPages.swift` (new):
  ```swift
  public struct TagEntityPage: Equatable, Sendable {
    public var tag: Tag
    public var tagClass: TagClass?
    public var entityNote: Note?
    public var totalNoteCount: Int
    public var groups: [NotebookGroup]   // latest member note desc
    public var coTags: [CoTag]           // count desc
    public struct NotebookGroup: Equatable, Sendable {
      public var notebook: Notebook
      public var noteCount: Int
      public var notes: [NoteSearchResult] // capped per notebook
    }
    public struct CoTag: Equatable, Sendable {
      public var tag: Tag
      public var count: Int
    }
  }

  public extension NoteService {
    func tagEntityPage(tagName: String, notesPerNotebook: Int = 5,
                       coTagLimit: Int = 12) throws -> TagEntityPage
    @discardableResult
    func promoteTagToEntityNote(tagName: String, summaryMarkdown: String,
                                assignedBy: String? = nil) throws -> Note
  }
  ```
  Members: one `note_tags`/`tags` join ordered `created_at DESC`,
  grouped by `notebook_id` in Swift with the per-group cap; snippets
  via existing `snippet(from:query:)` with the tag name; counts via
  `COUNT` queries. Co-tags: `note_tags` self-join grouped by tag,
  `ORDER BY count DESC LIMIT ?`. `promoteTagToEntityNote` in one
  transaction: reject if `entity_note_id` set (`invalidInput`);
  find-or-create the Entities notebook (`notebook-kind:entity`);
  insert note `# <tag name>` + summary, apply the tag itself (system
  provenance, `assignedBy` default `"entity-promotion"`); set
  `entity_note_id`; `refreshFTS`; enqueue standard `noteCreated`
  auto-actions.
- GraphQL (`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
  `NoteGraphQLService.swift`, `NoteGraphQLDocumentExecutor.swift` +
  `supportedNoteGraphQLFields`): query `tagEntityPage(tagName: String!,
  notesPerNotebook: Int, coTagLimit: Int) -> GraphQLTagEntityPageDTO`
  (nested group/co-tag DTOs mirroring the struct); mutation
  `promoteTagToEntityNote(tagName: String!, summaryMarkdown: String!,
  assignedBy: String)` returning the created note;
  `GraphQLNoteTagDTO` gains `entityNoteId: String?`.
- Tests — `Tests/RielaNoteTests/NoteEntityPageTests.swift` (new):
  aggregation grouping/caps/counts/co-tag ordering, single-note and
  100+-note tags stay within the fixed query shape (one member query +
  counts + one co-tag query), promote happy path, double-promote
  rejected, `deleteNote` clears the pointer;
  `Tests/RielaGraphQLTests/NoteGraphQLEntityPageTests.swift` (new):
  executor round trips for both fields + `entityNoteId` projection.

**Checklist**:
- [ ] Schema column + seeded `notebook-kind:entity` tag
- [ ] `tagEntityPage` / `promoteTagToEntityNote` with transaction rules
- [ ] `deleteNote` pointer clearing
- [ ] GraphQL parity + DTO field; service and executor tests pass

---

### TASK-006: Entity page UI + tappable tag chips
**Status**: NOT_STARTED
**Depends On**: TASK-005
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` — protocol gains
  `tagEntityPage(tagName:) async throws -> TagEntityPage` and
  `promoteTagToEntityNote(tagName:summaryMarkdown:) async throws ->
  RielaNoteDetail` (canonical note's detail);
  `NoteServiceRielaNoteUIClient` forwards to the service.
- `Sources/RielaNoteUI/RielaNoteEntityPageView.swift` (new) — header
  (tag name, class label, note count); pinned entity-note card when
  promoted (tap opens the canonical note) else "Promote to entity
  note" button; notebook groups (title, member rows with snippet, tap
  opens note, per-group "show all"); footer co-tag chips with counts
  navigating onward. Promote sheet prefilled `# <tag name>\n\n`; save
  → promote → navigate to the note.
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+EntityPage.swift`
  (new) — `openEntityPage(tagName:)` pushing a detail-column
  destination (stack supports co-tag chaining, standard back);
  generation-guarded load/error state mirroring
  `RielaNoteLibraryViewModel+SelectionQA.swift`.
- `Sources/RielaNoteUI/RielaNoteComponents.swift` +
  `RielaNoteDetailView.swift` / list-row render sites —
  `RielaNoteTagChip` gains an optional tap action; all existing sites
  pass `openEntityPage`; chips for `notebook-kind:*` system tags stay
  non-navigating; promoted-indicator rendered from `entityNoteId`.
- Tests — `Tests/RielaNoteUITests/RielaNoteEntityPageTests.swift`
  (new): client forwarding, load-state generation guards (stale loads
  dropped), promote flow updates page state, notebook-kind chips do
  not navigate.

**Checklist**:
- [ ] Client methods + forwarding
- [ ] Entity page view with groups/co-tags/promote; detail-column stack
- [ ] Tappable chips everywhere except `notebook-kind:*`
- [ ] View-model + navigation tests pass

---

### F3 — Scoped Ask

### TASK-007: Scoped-ask types, workflow provider, example bundle
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteScopedAsk.swift` (new):
  ```swift
  public struct RielaNoteScopedAskScope: Codable, Equatable, Sendable {
    public var searchText: String
    public var tagNames: [String]
    public var classIds: [String]
    public var filter: RielaNoteListFilter
    public var summary: String   // human-readable scope caption
  }
  public struct RielaNoteScopedAskCorpusEntry: Codable, Equatable, Sendable {
    public var noteId: String
    public var notebookId: String
    public var title: String?
    public var tagNames: [String]
    public var excerpt: String   // body prefix, ≤ 1500 chars
  }
  public struct RielaNoteScopedAnswerDraft: Codable, Equatable, Sendable {
    public var answerMarkdown: String
    public var citedNoteIds: [String]
    public var summary: String?
  }
  public protocol RielaNoteScopedAskProviding: Sendable {
    func answerScopedQuestion(question: String, scope: RielaNoteScopedAskScope,
                              corpus: [RielaNoteScopedAskCorpusEntry],
                              noteRoot: String) async throws -> RielaNoteScopedAnswerDraft
  }
  ```
- `Sources/RielaNoteUI/RielaNoteWorkflowScopedAskProvider.swift` (new,
  macOS-gated like the other workflow providers) — reuses subprocess
  helpers in `RielaNoteWorkflowProviderSupport.swift`; corpus written
  to a temp JSON file whose path is passed via `--variables` (deleted
  in `defer`); env overrides `RIELA_NOTE_SCOPED_ASK_WORKFLOW_DIR` /
  `RIELA_NOTE_SCOPED_ASK_RIELA_EXECUTABLE`; 180 s deadline; error enum
  mirroring the rewrite/question providers (`notConfigured`,
  `workflowFailed`, `invalidOutput`, `timedOut`).
- `examples/note-scoped-ask/` (new bundle) — two nodes like
  `examples/note-selection-question/`: a `codex-agent` worker prompted
  with question + scope summary + corpus file path, answering only
  from the corpus, returning `{answerMarkdown, citedNoteIds, summary}`
  with `citedNoteIds` drawn from corpus ids; plus a
  `latest-input-payload` output node. Ships `mock-scenario.json` (in
  the loader's `{nodeId: MockNodeResponse}` format) +
  `EXPECTED_RESULTS.md` with exact validate/run commands.
- Tests — `Tests/RielaNoteUITests/RielaNoteScopedAskProviderTests.swift`
  (new): variable construction, temp-file lifecycle (written, path in
  `--variables`, deleted), JSONL output parsing, each error case —
  mirroring the selection-question provider tests. Bundle passes
  `riela workflow validate note-scoped-ask
  --workflow-definition-dir examples` + recorded mock dry-run.

**Checklist**:
- [ ] Scope/corpus/draft types + provider protocol
- [ ] Subprocess provider with temp-file corpus handoff + deadline
- [ ] Example bundle with mock scenario; validate + dry-run pass
- [ ] Provider tests pass

---

### TASK-008: Ask-this-view UI, corpus assembly, save-as-note
**Status**: NOT_STARTED
**Depends On**: TASK-007
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` — protocol gains
  `answerScopedQuestion(question:scope:corpus:) async throws ->
  RielaNoteScopedAnswerDraft` (protocol-extension default throws
  not-configured) and `saveScopedAnswerNote(question:scopeSummary:
  answerMarkdown:citedNoteIds:) async throws -> SavedConversation`.
  Save maps to `service.saveConversation(title: <question-derived,
  120-char cap via NoteTitleDerivation>, transcript:
  [NoteConversationTurn(userMarkdown: question + "\n\n_Scope: …_",
  assistantMarkdown: answerMarkdown, sourceNoteIds: citedNoteIds)],
  assignedBy: "note-scoped-ask")` — one
  `notebook-kind:agent-conversation` notebook, `source-citation`
  links, auto-actions enqueued (all existing behavior; no schema
  change).
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+ScopedAsk.swift`
  (new) — clones the SelectionQA generation-guard structure
  (`isScopedAskLoading`, `scopedAskError`, `scopedAskAnswer`,
  `scopedAskGeneration`, `clearScopedAskState()`). Corpus assembly via
  existing `client.searchNotes(query:tagFilter:classFilter:filter:
  limit:24, offset:0)` (rank order, excerpts capped 1500 chars); scope
  snapshotted at submit so mid-flight filter changes neither cancel
  nor retarget; provider `citedNoteIds` filtered to corpus membership
  before display/save; zero surviving citations → "no citations"
  caption with Save disabled.
- `Sources/RielaNoteUI/RielaNoteScopedAskSheet.swift` (new) +
  `RielaNoteFilterPane.swift` — "Ask this view" button (enabled when
  the scope yields ≥ 1 result) opening a sheet: scope summary line,
  question field, Submit; answer as markdown with citation chips
  `[n] <note title>` opening the note; in-sheet errors
  (not-configured, timeout, workflow failure, invalid output);
  "Save as note" → saved confirmation with jump-to-note; dismiss
  without save persists nothing.
- Tests — `Tests/RielaNoteUITests/RielaNoteScopedAskTests.swift`
  (new): corpus matches the live filter results exactly (limit/order),
  citation filtering to corpus membership, stale-generation drop,
  each error path persists nothing, save produces one conversation
  with `source-citation` links to every surviving cited note.

**Checklist**:
- [ ] Client answer + save methods (saveConversation mapping)
- [ ] View-model extension with snapshot scope + generation guards
- [ ] Ask sheet with citation chips, in-sheet errors, save flow
- [ ] Corpus/citation/save tests pass

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| HTTP transport | `Sources/RielaServer/NWListenerHTTPTransport.swift` | NOT_STARTED | `Tests/RielaServerTests/NWListenerHTTPTransportTests.swift` |
| Envelope query / htmlBody | `Sources/RielaServer/ServerContracts.swift` | NOT_STARTED | `Tests/RielaServerTests/ServerContractsTests.swift` |
| Routes + pages + sanitization | `Sources/RielaServer/ServerContracts.swift`, `NoteCapturePages.swift`, `QRClientRegistrationAuthenticator.swift` | NOT_STARTED | `Tests/RielaServerTests/NoteAPIAuthTests.swift` |
| Capture handler | `Sources/RielaServer/NoteCaptureHandler.swift` | NOT_STARTED | `Tests/RielaServerTests/NoteCaptureHandlerTests.swift` |
| Serve wiring + dispatcher | `Sources/RielaCLI/ScopedParityCommands+Serve.swift`, `Sources/RielaServer/WorkflowServingController.swift` | NOT_STARTED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| Entity schema + service | `Sources/RielaNote/NoteStoreSchema.swift`, `NoteService.swift`, `NoteService+EntityPages.swift` | NOT_STARTED | `Tests/RielaNoteTests/NoteEntityPageTests.swift` |
| Entity GraphQL | `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`, `NoteGraphQLService.swift`, `NoteGraphQLDocumentExecutor.swift` | NOT_STARTED | `Tests/RielaGraphQLTests/NoteGraphQLEntityPageTests.swift` |
| Entity page UI | `Sources/RielaNoteUI/RielaNoteEntityPageView.swift`, `RielaNoteLibraryViewModel+EntityPage.swift`, `RielaNoteUIClient.swift`, `RielaNoteComponents.swift` | NOT_STARTED | `Tests/RielaNoteUITests/RielaNoteEntityPageTests.swift` |
| Scoped-ask types + provider | `Sources/RielaNoteUI/RielaNoteScopedAsk.swift`, `RielaNoteWorkflowScopedAskProvider.swift` | NOT_STARTED | `Tests/RielaNoteUITests/RielaNoteScopedAskProviderTests.swift` |
| Scoped-ask workflow bundle | `examples/note-scoped-ask/` | NOT_STARTED | mock dry-run + `EXPECTED_RESULTS.md` |
| Scoped-ask UI + save | `Sources/RielaNoteUI/RielaNoteScopedAskSheet.swift`, `RielaNoteLibraryViewModel+ScopedAsk.swift`, `RielaNoteFilterPane.swift`, `RielaNoteUIClient.swift` | NOT_STARTED | `Tests/RielaNoteUITests/RielaNoteScopedAskTests.swift` |

## Dependencies

| Task | Depends On | Why |
|------|------------|-----|
| TASK-002 routes/pages | TASK-001 | pages need `envelope.query` + `htmlBody`; sanitization tested through the transport |
| TASK-003 capture handler | TASK-002 | route dispatch + bearer auth path in place |
| TASK-004 serve wiring | TASK-001, TASK-002, TASK-003 | run-loop binds the transport and serves all routes end-to-end |
| TASK-006 entity UI | TASK-005 | client forwards to the new service/GraphQL surface |
| TASK-008 ask UI/save | TASK-007 | sheet submits through the provider; save consumes the draft types |
| TASK-001, TASK-005, TASK-007 | — | independent starting points (F1/F2/F3 parallelizable) |

## Completion Criteria

- [ ] `swift build` and `swift test` pass; SwiftLint clean
- [ ] F1 acceptance 1–7 (design doc): real socket + cross-machine
      `/healthz`, QR registration end-to-end, single accumulating
      Quick Memos notebook, live auto-actions, 401/400 limits, no
      internal error text across the socket (F24/F25 covered by test)
- [ ] F2 acceptance 1–5: chip → entity page with groups/snippets/
      co-tags, promote-once semantics, delete clears pointer, GraphQL
      round trip, bounded query shape at 100+ notes
- [ ] F3 acceptance 1–5: cited answer with corpus-validated citations,
      save-with-links, error paths persist nothing, corpus mirrors the
      live filter, bundle validates + mock dry-run passes
- [ ] `RielaNoteUI` still compiles for iOS (subprocess provider
      macOS-gated)

## Progress Log

### Session: 2026-07-12
**Tasks Completed**: None yet
**Tasks In Progress**: Plan authored from the design doc
**Blockers**: None
**Notes**: No backward compatibility anywhere — schema and route
changes are made in place and the note DB is recreated.

## Related Plans

- **Depends On**: `impl-plans/active/riela-note.md` (base feature),
  `impl-plans/active/riela-note-ui-refinements.md` (filter pane,
  SelectionQA patterns this plan clones)
