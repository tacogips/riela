# Riela Note: Anywhere Capture, Entity Pages, Scoped Ask

- Date: 2026-07-12
- Status: Draft
- Provenance: persona ideation + 3-judge panel; pitches, grounding, and
  scores in `design-docs/references/riela-note-new-feature-selection-2026-07-12.json` (top three of 23
  candidates selected). Original product vision:
  `design-docs/riela-note-design.md`.
- Compatibility: none required. Schema and APIs are changed in place;
  the note DB may be recreated. No migrations, no compat shims.

## Code-Verified Current State (shared)

- `riela serve --note-api` (`Sources/RielaCLI/ScopedParityCommands+Serve.swift`)
  builds an `InProcessWorkflowServeListenerHandle`
  (`Sources/RielaServer/WorkflowServingController.swift:529`) whose
  "endpoint" is only the string `http://host:port` — **no socket is ever
  bound**; the command prints the registration challenge and exits. No
  HTTP transport dependency (SwiftNIO, Network.framework) exists anywhere
  in `Package.swift` or `Sources/`.
- Routing is already transport-agnostic: `ServerRouteHandling.route(
  ServerRequestEnvelope, ServerRequestContext) -> ServerResponseDescriptor`
  (`Sources/RielaServer/ServerContracts.swift`) handles `/graphql`,
  `/healthz`, `/note/register` with bearer extraction from headers.
- QR registration is complete in-process: challenge mint/TTL/redeem
  (`QRClientRegistrationAuthenticator.swift`, TTL ≤ 300 s, ≤ 128 pending),
  sha256 token storage/revocation (`NoteService+APIClients.swift`), CLI
  management (`riela note client register|list|revoke`,
  `NoteCommands.swift:471`).
- Auto-actions enqueued by note creation are **hard-failed** under serve
  (`ServedNoteAPIAutoActionDispatcher`,
  `WorkflowServingController.swift:520`); a real dispatcher exists in
  `Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`.
- Tags: `tags(tag_id, name UNIQUE, class_id, is_system, created_at)`
  (`NoteStoreSchema.swift:341`); no pointer from a tag to a note.
  Tag-scoped retrieval + snippets: `searchNotesInDatabase(...)`
  (`Sources/RielaNote/NoteSearch.swift:11`).
- SelectionQA pattern to clone for F3:
  `RielaNoteLibraryViewModel+SelectionQA.swift` (generation guards),
  `RielaNoteWorkflowSelectionQuestionProvider.swift` (subprocess workflow
  provider), `saveConversation` writing `source-citation` links
  (`NoteService+Relations.swift:159,249`). Filter pane state
  (`RielaNoteFilterPane.swift`: searchText, tag/class selections,
  `RielaNoteListFilter`) is already accepted verbatim by
  `client.searchNotes(query:tagFilter:classFilter:filter:limit:offset:)`.

---

## F1 — Anywhere Capture

Phone-to-Mac quick memo over the QR-registered note API. The judges'
caveat is confirmed by code: registration/auth/routing exist, but the
HTTP server, HTML page serving, capture endpoint, serve run-loop, and
auto-action dispatch are all genuinely new. Effort is **L, not M**.

### User story

Walking to a meeting, an idea hits. The user opens the riela capture
page pinned to their iPhone home screen (registered once by scanning the
QR printed by `riela serve --note-api`), types two lines, hits Send. The
note lands in the single accumulating "Quick Memos" notebook
(`notebook-kind:user-memo`), auto-tagged by the default auto-action
workflow, visible in the Mac Notes window seconds later.

### UX flow

1. Operator: `riela serve --note-api --host <tailscale-ip>` → binds the
   socket, prints endpoint + terminal QR (existing `qrText`), keeps
   running until SIGINT. Typing `r` + Enter mints and prints a fresh
   challenge (codes expire in ≤ 300 s).
2. Phone scans QR → `GET /note/register?code=…` serves a registration
   page: device-name field + Register button → `POST /note/register`
   (existing redeem) → stores `credential.bearerToken` in
   `localStorage["riela-note-token"]` → redirects to `/note/capture`.
3. Capture page: textarea, photo picker (`<input type=file
   accept=image/* capture=environment>`), Send. Send POSTs
   `/note/capture` with the bearer token; success shows a checkmark and
   clears the form (< 2 s round trip). The page carries
   `apple-mobile-web-app-capable` meta + inline manifest so Add to Home
   Screen yields a standalone icon.
4. On the Mac, the note appears in the Quick Memos notebook; the
   `note-created` auto-actions (e.g. AI tagging) run via the real
   dispatcher.

### Data & API design

**No schema changes.** All persistence reuses `api_clients`, notes,
tags, files.

**HTTP transport** — new `Sources/RielaServer/NWListenerHTTPTransport.swift`
(Network.framework, `#if canImport(Network)`; serve --note-api is
macOS-only and errors on other platforms):

```swift
public final class NWListenerHTTPTransport: WorkflowServeListenerHandle {
  public init(host: String, port: Int, routeHandler: any ServerRouteHandling,
              context: ServerRequestContext) throws
  public var endpoint: String { get }   // resolved http://host:port
  public func shutdown() async throws   // cancels listener + connections
}
```

Minimal HTTP/1.1: request line + headers + `Content-Length` body only
(no chunked encoding, no keep-alive — `Connection: close` per response),
12 MiB body cap (base64 of the 8 MiB `maxAttachmentBytes` file limit),
30 s per-request deadline. Parses into `ServerRequestEnvelope`,
serializes `ServerResponseDescriptor`. Parse/limit/timeout failures
produce fixed-body responses (`400 {"error":"malformed request"}`,
`413 {"error":"request body too large"}`, `408` on deadline) — the
transport never interpolates exception text into a response.

**Query strings** — `DeterministicServerRouteHandler.route`
(`ServerContracts.swift:96`) matches exact path strings in a switch, so
a raw `/note/register?code=…` path would fall through to 404.
`ServerRequestEnvelope` therefore gains
`public var query: [String: String]` (default `[:]`); the transport
splits the request target at the first `?`, percent-decodes the pairs
into `query`, and sets `path` to the query-free path. The switch keeps
matching exact paths unchanged, and the registration page handler reads
the code as `request.query["code"]`.

**HTML responses** — `ServerResponseDescriptor` gains
`public var htmlBody: String?` (default `nil`); when set, the transport
writes it verbatim with `contentType` (`text/html; charset=utf-8`)
instead of encoding the JSON `body`. In-process consumers ignore it.

**Routes** (`DeterministicServerRouteHandler`):

- `GET /note/register` (code in `request.query["code"]`) → registration
  page HTML. This replaces the current challenge-mint route
  (`routeNoteRegistrationChallenge`, `ServerContracts.swift:116`), which
  is deleted together with the routed protocol method
  `createRegistrationChallenge(request:context:)` (no compat needed).
  HTTP challenge-minting therefore has **no route at all**: there is no
  `/note/register/challenge` path, and any request to one falls through
  to the default case and gets the standard 404, like every unknown
  path.
- `POST /note/register` → existing redeem logic, with its catch-all 500
  body sanitized (see Security model / error sanitization).
- `GET /note/capture` → capture page HTML (static shell, no data).
- `POST /note/capture` → authenticated capture (below).

**Capture endpoint** — new `Sources/RielaServer/NoteCaptureHandler.swift`:

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

**Notebook policy — one accumulating capture notebook.** This
deliberately diverges from `examples/note-quick-memo/workflow.json`,
whose addon path creates a *new* `notebook-kind:user-memo` notebook per
memo (`createNotebook(kindTagName:)` then `createNote(notebookId:)`,
`ProductionNodeAdapter+NoteAddons.swift:148`): a phone inbox is one
stream, not a notebook per thought. Note that a bare
`createNote(notebookId: nil, notebookTitle: "Quick Memos", …)`
(`NoteService.swift:84`) would be wrong either way — its nil-notebook
branch inserts a fresh notebook with **no kind tag**. The handler runs,
per capture:

1. Find: `service.listNotebooks(limit: 1, tagFilter:
   ["notebook-kind:user-memo"], sort: .createdAtAsc)` → the oldest
   existing capture notebook, if any.
2. Create if absent: `service.createNotebook(title: "Quick Memos",
   kindTagName: "notebook-kind:user-memo")` — the same call the
   quick-memo addon uses, which applies the kind tag with system
   provenance, non-deletable.
3. `service.createNote(notebookId: notebook.notebookId,
   bodyMarkdown: …, readOnly: false, tags: [NoteTagInput(name: "ノート",
   classId: "content-kind")], provenance: .human,
   assignedBy: "capture:<clientId>")`.

`NoteCaptureHandler` is an actor so steps 1–2 cannot race two
concurrent first-captures into duplicate notebooks. Photo attached via
`service.attachFile(noteId:data:role:.related,
mediaType:originalFilename:position:0)`. Photo-only memos get body
`# Photo memo <timestamp>`. Responses:

- `200 {noteId, notebookId, title}` on success.
- `400 {"error": "<fixed reason>"}` on empty payload / oversize / bad
  base64 / missing `photoMediaType` (fixed strings, no echo of input).
- `500 {"error": "note capture failed"}` when `createNote` or
  `attachFile` throws — the caught error is logged via
  `context.telemetry` only and never appears in the body. If
  `createNote` succeeded but `attachFile` failed, the handler deletes
  the just-created note before returning 500 (no half-captured memos).

**Serve wiring** — `InProcessWorkflowServeListenerFactory` gains
`autoActionDispatcher: any AutoActionDispatching` (default remains the
failing stub for embedded use). The CLI serve path passes
`NoteAutoActionWorkflowDispatcher` so `enqueueAutoActions` →
`dispatchQueuedAutoActions` actually runs workflows.
`ScopedParityCommands+Serve.swift` changes from print-and-return to:
start `NWListenerHTTPTransport` with the factory's route handler, print
endpoint + QR, run a stdin loop (`r` = new challenge, Ctrl-C = shutdown).

### Security model

- **Error sanitization (in-scope prerequisite)**: F1 is the change that
  first exposes these handlers to a network socket, and two known leaks
  sit directly on its paths (findings F24/F25,
  `design-riela-note-adversarial-review-2026-07-12.md`):
  `QRClientRegistrationAuthenticator.swift:123` returns redeem 500
  bodies interpolating the raw internal error, and `:160` returns 401
  bodies interpolating raw `SQLiteError` text (DB paths, SQL). Fixing
  both is part of F1: the redeem catch-all becomes
  `500 {"error": "registration failed"}` and the authenticate
  catch-all becomes
  `noteAPIUnauthorizedResponse("note API authentication failed")`, with
  the underlying error logged via telemetry only. Blanket rule for all
  F1 surfaces (transport, capture handler, registration pages): every
  4xx/5xx body carries a fixed public-diagnostic string; interpolating
  a caught error (`"\(error)"`, `localizedDescription`) into any
  `ServerResponseDescriptor` is forbidden.
- **Transport**: plain HTTP. Confidentiality/integrity come from the
  tailnet (WireGuard); this is an explicit precondition. Default bind
  stays `127.0.0.1`; exposing requires an explicit `--host` (tailscale
  IP). Serve startup prints a warning when binding a non-loopback host.
  TLS is a non-goal.
- **Unauthenticated client can**: fetch static page shells
  (`GET /note/register`, `GET /note/capture` — no note data in either),
  `GET /healthz`/`/overview`, and redeem a valid registration code
  within its ≤ 300 s TTL (single-use, ≤ 128 pending, scope-bound to the
  note root). Nothing else; `/graphql` note fields and `/note/capture`
  POST return 401 without a valid bearer.
- **Registered client can**: everything the note GraphQL surface allows
  (full read/write of the note store) plus `POST /note/capture`.
  Capture-only scoped tokens are a non-goal — a registered device is
  the user's own device.
- **Tokens**: 32-byte random `rn_…` bearer, stored as sha256
  (`api_clients.token_hash`), shown once at redemption, held in the
  phone's localStorage. `last_seen_at` updates on every auth. Revoke:
  `riela note client revoke <clientId>`; revoked tokens 401 immediately.
- **Challenge minting**: only from the serving terminal (stdin `r`) or
  `riela note client register` on the Mac, via
  `createRegistrationChallenge(publicBaseURL:)`. No HTTP route mints
  challenges — the routed method
  `createRegistrationChallenge(request:context:)` is deleted (see
  Routes), so any mint attempt over HTTP hits an unknown path and
  returns the default 404.
- **Limits**: 12 MiB request cap, 8 MiB decoded attachment cap
  (existing `maxAttachmentBytes`), 30 s deadline, existing GraphQL
  document size limits.

### Acceptance criteria

1. `riela serve --note-api --host 0.0.0.0 --port 8787` binds a real
   socket; `curl http://<host>:8787/healthz` returns 200 from another
   machine; the process stays up until SIGINT.
2. Scanning the printed QR on a phone completes registration end-to-end
   in a mobile browser and lands on the capture page; the code is
   single-use and expires per TTL.
3. Captures accumulate in a single notebook: starting from a fresh note
   DB, two text-memo POSTs yield exactly one notebook — titled
   "Quick Memos" and carrying the `notebook-kind:user-memo` tag — with
   two notes, each tagged `ノート` (class `content-kind`); a photo memo
   attaches the image as a related file retrievable via the existing
   file surface.
4. With a default tagging auto-action configured, a captured memo gets
   AI tags without manual intervention (dispatcher no longer stubbed).
5. Requests without/with revoked bearer get 401; oversize body gets 400
   without service-layer side effects.
6. No internal error text crosses the socket: with forced service-layer
   failures on redeem, authenticate, and capture (e.g. note store
   unwritable), the response bodies are exactly the fixed
   public-diagnostic strings — a test asserts none contains the thrown
   error's description (no SQLite text, DB paths, or SQL). Covers
   F24/F25.
7. Unit tests: HTTP parser (request line/headers/body/limits,
   query-string split into `envelope.query`), capture handler
   happy/edge/500 paths, route-handler HTML paths, challenge stdin
   re-mint. An integration test drives a real socket round trip on an
   ephemeral port, including `GET /note/register?code=…` reaching the
   registration page handler.

### Non-goals

- TLS, Google/Auth0 auth (design-doc "auth switchable later" stays
  later), capture-scoped tokens.
- Offline queue / service worker; share-sheet target; native iOS app.
- HTTP keep-alive, chunked encoding, HTTP/2.
- Serving the full Notes browsing UI to the phone (capture + register
  pages only).

---

## F2 — Entity Pages

Tag-as-destination: every tag (person, year, event, …) opens an
aggregation page; a tag can be promoted to a canonical entity note.

### User story

Reading an OCR'd history book, the user taps the AI-assigned "Bismarck"
(class: person) tag chip. An Entity Page opens: 23 notes across 4
notebooks, grouped by notebook with FTS-style snippets, plus co-occurring
tags ("1871", "Franco-Prussian War"). They hit "Promote to entity note",
write a two-line summary; from then on the entity page pins that
canonical note at the top and every Bismarck chip is one tap away
from it.

### UX flow

1. Tag chips (`RielaNoteTagChip`, rendered in detail view and list rows)
   become tappable and navigate to the entity page for that tag.
2. Entity page (detail-column destination): header = tag name + class
   label + note count; a pinned entity-note card when promoted
   (tap → opens the canonical note), otherwise a "Promote to entity
   note" button; body = notebook groups (notebook title, member notes
   with snippet, tap opens note; "show all" per group); footer = co-tag
   chips with counts, tap → that tag's entity page.
3. Promote: sheet with body editor prefilled `# <tag name>\n\n`; save
   creates the canonical note and navigates to it.

### Data & API design

**Schema** (`NoteStoreSchema.swift`, DB recreated — edit in place):

- `tags` gains `entity_note_id TEXT REFERENCES notes(note_id)`.
- New seeded system tag `notebook-kind:entity` alongside the existing
  notebook-kind tags; a single "Entities" notebook (created on first
  promotion) carries it.
- `deleteNote` additionally clears any `tags.entity_note_id` pointing at
  the deleted note.

**Service** — new `Sources/RielaNote/NoteService+EntityPages.swift`:

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
    public var noteCount: Int          // total in this notebook
    public var notes: [NoteSearchResult] // capped, snippet vs tag name
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

- Member notes: one query joining `note_tags`/`tags` on name, ordered
  `created_at DESC`; grouped by `notebook_id` in Swift with the per-group
  cap; snippets via the existing `snippet(from:query:)` with the tag name
  as query. `totalNoteCount`/per-notebook counts via `COUNT` queries.
- Co-tags: self-join on `note_tags` (`nt2.tag_id != nt1.tag_id`) grouped
  by tag, `ORDER BY count DESC LIMIT ?`.
- `promoteTagToEntityNote` — one transaction: reject if
  `entity_note_id` already set (`invalidInput`); find-or-create the
  Entities notebook (`notebook-kind:entity`); insert note with body
  `# <tag name>` + summary, apply the tag itself (system provenance,
  `assignedBy` default `"entity-promotion"`); set `entity_note_id`;
  `refreshFTS`. Enqueues the standard `noteCreated` auto-actions.

**GraphQL** (`GraphQLNoteGraphQLService` + document executor +
`supportedNoteGraphQLFields`):

- Query `tagEntityPage(tagName: String!, notesPerNotebook: Int,
  coTagLimit: Int) -> GraphQLTagEntityPageDTO` (nested notebook-group /
  co-tag DTOs mirroring the service struct).
- Mutation `promoteTagToEntityNote(tagName: String!,
  summaryMarkdown: String!, assignedBy: String) -> noteMutation` result
  carrying the created note.
- `GraphQLNoteTagDTO` gains `entityNoteId: String?` so chips can render
  a promoted indicator.

**UI** (`RielaNoteUI`):

- `RielaNoteUIClient` gains `tagEntityPage(tagName:) async throws ->
  TagEntityPage` and `promoteTagToEntityNote(tagName:summaryMarkdown:)
  async throws -> RielaNoteDetail` (returns the canonical note's
  detail); `NoteServiceRielaNoteUIClient` forwards to the service.
- New `RielaNoteEntityPageView.swift`; navigation via
  `RielaNoteLibraryViewModel.openEntityPage(tagName:)` pushing an
  entity-page destination in the detail column (stack allows co-tag →
  co-tag chaining, standard back). Generation-guarded load state
  mirrors the SelectionQA extension pattern
  (`+EntityPage.swift` view-model extension).
- `RielaNoteTagChip` gains an optional tap action; all existing render
  sites pass `openEntityPage`.

### Workflow/agent integration

None required at design time; the note agent can already reach the
aggregation through GraphQL (`tagEntityPage`) once registered, which is
sufficient for prompts like "summarize what I know about X".

### Acceptance criteria

1. Tapping any tag chip opens its entity page listing all tagged notes
   across notebooks, grouped, with snippets and correct counts;
   co-tag chips navigate onward; note rows open the note.
2. Promote creates exactly one canonical note in the Entities notebook,
   tagged with the entity tag (system provenance), and sets
   `tags.entity_note_id`; a second promote is rejected; the page then
   pins the entity note.
3. Deleting the canonical note clears the pointer and restores the
   Promote button.
4. `tagEntityPage`/`promoteTagToEntityNote` round-trip through the
   GraphQL document executor (service tests + executor field tests).
5. A tag with a single note and a tag with 100+ notes both render
   within the per-notebook cap without pathological queries (one member
   query + counts, one co-tag query).

### Non-goals

- Entity merge/rename/aliasing; auto-promotion by AI; timeline views.
- Mass-linking the entity note to all member notes (the page aggregates
  dynamically; links stay curated).
- Entity pages for notebook-kind system tags (chips for
  `notebook-kind:*` stay non-navigating).

---

## F3 — Scoped Ask

Question the current filter scope; cited answer; save as note. A direct
generalization of SelectionQA — same provider/subprocess/generation
patterns, new retrieval payload.

### User story

Taco filters the library to tag `事業アイデア`, last 90 days, hits
"Ask this view": "which of these ideas overlap and which contradict
each other?". The answer cites 7 notes across 4 notebooks. "Save as
note" creates a synthesis note with source-citation links back to all 7.

### UX flow

1. Filter pane gains an "Ask this view" button (enabled when the current
   scope yields ≥ 1 result). It opens an ask sheet showing a one-line
   scope summary ("tag 事業アイデア · last 90 days · 31 notes"),
   a question field, and Submit.
2. Loading → answer rendered as markdown with citation chips
   `[n] <note title>`; tapping a chip opens that note. Errors surface
   in-sheet (not-configured, timeout, workflow failure).
3. "Save as note" persists the Q/A as an agent-conversation notebook
   with source-citation links and shows "Saved" with a jump-to-note
   affordance. Dismissing without saving persists nothing.

### Data & API design

**No schema changes** — `saveConversation` +
`NoteConversationTurn.sourceNoteIds` already write `source-citation`
links (`NoteService+Relations.swift:249`).

**Scope + corpus** (new `Sources/RielaNoteUI/RielaNoteScopedAsk.swift`):

```swift
public struct RielaNoteScopedAskScope: Codable, Equatable, Sendable {
  public var searchText: String
  public var tagNames: [String]
  public var classIds: [String]
  public var filter: RielaNoteListFilter
  public var summary: String   // human-readable, reused as scope caption
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
```

Corpus assembly runs in the view model via the existing
`client.searchNotes(query:tagFilter:classFilter:filter:limit:24,
offset:0)` (rank order); no new retrieval infrastructure.

**Provider** — mirrors `RielaNoteSelectionQuestionProviding` end to end:

```swift
public protocol RielaNoteScopedAskProviding: Sendable {
  func answerScopedQuestion(
    question: String,
    scope: RielaNoteScopedAskScope,
    corpus: [RielaNoteScopedAskCorpusEntry],
    noteRoot: String
  ) async throws -> RielaNoteScopedAnswerDraft
}
```

`RielaWorkflowNoteScopedAskProvider` (macOS) reuses the shared
subprocess helpers in `RielaNoteWorkflowProviderSupport.swift`; because
a 24-note corpus exceeds comfortable argv size, the corpus is written to
a temp JSON file whose path is passed via `--variables` (deleted in
`defer`). Env overrides `RIELA_NOTE_SCOPED_ASK_WORKFLOW_DIR` /
`RIELA_NOTE_SCOPED_ASK_RIELA_EXECUTABLE`; 180 s deadline; error enum
mirrors the rewrite/question providers (`notConfigured`,
`workflowFailed`, `invalidOutput`, `timedOut`).

**Example bundle** `examples/note-scoped-ask/`: two nodes like
`examples/note-selection-question/` — a `codex-agent` worker whose
prompt receives the question + scope summary + corpus file path and is
instructed to answer only from the corpus, returning
`{answerMarkdown, citedNoteIds, summary}` with `citedNoteIds` drawn from
corpus ids; plus a `latest-input-payload` output node. Ships
`mock-scenario.json` + `EXPECTED_RESULTS.md`.

**Client & save**:

- `RielaNoteUIClient` gains
  `answerScopedQuestion(question:scope:corpus:) async throws ->
  RielaNoteScopedAnswerDraft` (protocol-extension default throws
  not-configured) and
  `saveScopedAnswerNote(question:scopeSummary:answerMarkdown:
  citedNoteIds:) async throws -> SavedConversation`.
- Save maps to `service.saveConversation(title: <question-derived,
  120-char cap via NoteTitleDerivation>, transcript:
  [NoteConversationTurn(userMarkdown: question + "\n\n_Scope: …_",
  assistantMarkdown: answerMarkdown, sourceNoteIds: citedNoteIds)],
  assignedBy: "note-scoped-ask")` — one notebook
  (`notebook-kind:agent-conversation`), one note, `source-citation`
  links, auto-actions enqueued, all existing behavior.
- View-model extension `RielaNoteLibraryViewModel+ScopedAsk.swift`
  clones the SelectionQA generation-guard structure
  (`isScopedAskLoading`, `scopedAskError`, `scopedAskAnswer`,
  `scopedAskGeneration`, `clearScopedAskState()`); the scope is
  snapshotted at submit, so filter changes mid-flight neither cancel
  nor retarget the request. `citedNoteIds` returned by the provider are
  filtered to corpus membership before display/save; an answer with
  zero surviving citations renders with a "no citations" caption and
  Save disabled.

### Workflow/agent integration

The answering agent is the `note-scoped-ask` workflow (codex-agent
node), resolved exactly like the selection-question workflow (default
workflow-dir candidates + env overrides). No GraphQL exposure; this is
an app-local pathway like SelectionQA (its spec's non-goal list applies
identically).

### Acceptance criteria

1. With any non-empty filter scope, Ask this view produces an answer
   whose citation chips open the cited notes; citations not present in
   the corpus are dropped.
2. Save as note creates one agent-conversation notebook whose note
   carries `source-citation` links to every surviving cited note;
   dismissing without saving persists nothing.
3. Not-configured (no provider), workflow failure, invalid output, and
   timeout each surface as in-sheet errors with no persistence; stale
   generations are dropped without mutating state.
4. Corpus assembly respects the live filter exactly (same results the
   list shows) and caps at 24 entries × 1500 chars.
5. Bundle passes `riela workflow validate note-scoped-ask
   --workflow-definition-dir examples` and a recorded mock dry-run;
   provider tests cover variable construction, temp-file lifecycle, and
   JSONL parsing (mirroring the selection-question provider tests).

### Non-goals

- Vector/semantic retrieval (separate ranked candidate); FTS-ranked
  top-k is the corpus.
- Streaming answers; multi-turn follow-ups in the sheet (the Agent tab
  owns conversations).
- GraphQL/HTTP exposure of scoped ask; phone access (F1's page has no
  ask affordance).
- Answer quality enforcement beyond citation-id validation.
