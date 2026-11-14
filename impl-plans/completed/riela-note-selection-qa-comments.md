# Riela Note Selection Q&A Comments Implementation Plan

**Status**: Completed (Step 8; all TASK-001..TASK-006 DONE, Step 7 accepted)
**Design Reference**: design-docs/specs/design-riela-note-selection-qa-comments.md
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-selection-qa-comments.md
(decisions D1–D6; requirements R1–R4)

### Summary

While editing a note, an "Ask question" affordance on the text
selection dispatches a question about the selected text to a
workflow-backed agent (D1/D2); the answer is auto-persisted as an
agent-authored comment (quoted selection + Q + A) and shown in the
Comments section (D4). Each comment gains a "Create notebook" action
that atomically creates a notebook whose first note carries the comment
content and links the source note to it (D5). Mirrors the shipped
note-edit-rewrite provider/client/view-model patterns throughout.

### Scope

**Included**: `Sources/RielaNoteUI` (detail view selection chip row +
pill question mode, new provider, view-model extension, client protocol
additions, comment-promotion UI), `Sources/RielaNote/NoteService.swift`
promote method, `Sources/RielaApp/NoteWindowController.swift` wiring,
`examples/note-selection-question/`, `Tests/RielaNoteUITests`,
`Tests/RielaNoteTests`.

**Excluded**: Agent tab, read-mode selection, comment edit/delete,
streaming, GraphQL, iOS selection features.

---

## Task Breakdown

### TASK-001: Selection-question provider + example bundle (D2)
**Status**: DONE
**Depends On**: —
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteWorkflowSelectionQuestionProvider.swift`:
  `RielaNoteSelectionAnswerDraft { answerMarkdown, summary? }`,
  `RielaNoteSelectionQuestionProviding`, error cases (`notConfigured`,
  `workflowFailed`, `invalidOutput`, `timedOut`), macOS
  `RielaWorkflowNoteSelectionQuestionProvider` (workflow id
  `note-selection-question`, env
  `RIELA_NOTE_SELECTION_QUESTION_WORKFLOW_DIR` /
  `RIELA_NOTE_SELECTION_QUESTION_RIELA_EXECUTABLE`, 120 s deadline,
  `defaultProvider(environment:fileManager:allowEnvironmentOverrides:)`
  matching the shipped rewrite provider), reusing
  `RielaNoteWorkflowProviderSupport.swift` helpers (incl. env
  sanitization with model-auth allowlist).
- `examples/note-selection-question/`: mirror `note-edit-rewrite`'s
  two-node shape — a `codex-agent`/`gpt-5.5` worker node
  (`promptTemplateFile`, answer about the selection in concise
  markdown, output `{answerMarkdown, summary}`) plus a `workflow-output`
  `kind: output` node (`latest-input-payload` projection). Ship
  workflow.json, nodes/, prompts/, mock-scenario.json,
  EXPECTED_RESULTS.md.

**Checklist**:
- [x] Provider passes noteRoot + workflowInput (noteId, question,
      bodyMarkdown, selectedText, selectionStart, selectionEnd)
- [x] `riela workflow validate note-selection-question
      --workflow-definition-dir examples` passes
- [x] No duplicated subprocess logic

### TASK-002: Service promote-comment-to-notebook (D5)
**Status**: DONE
**Depends On**: —
**Deliverables**:

**Step 1 — Extract a `in database:`-scoped insert helper (extend, do
NOT fork `createNotebookWithNotes`)** in
`Sources/RielaNote/NoteService.swift`. Resolves SR-001: today the whole
notebook/note insert body lives *inside* `createNotebookWithNotes`'s
own `driver.withDatabase { database.transaction { db in … } }`
(`NoteService.swift:198-286`), and `linkNotes` opens a *second*
transaction (`NoteService+Relations.swift:11-13`); composing the two
public methods yields **two** transactions and the named
partial-failure window.
- Move the body of `createNotebookWithNotes`'s `database.transaction`
  closure (lines ~200-285: notebook INSERT, optional kind-tag,
  per-page note INSERT + tags + FTS refresh, `NotebookIngestResult`
  build, `enqueueAutoActions`) into a new private helper
  `insertNotebookWithNotes(title:kindTagName:metaJSON:pages:provenance:
  assignedBy:originatingActionId:in db:) throws ->
  (ingestResult: NotebookIngestResult, dispatches: [<dispatch type>])`.
- `createNotebookWithNotes` keeps its public signature/defaults and its
  own `driver.withDatabase { database.transaction { db in
  try insertNotebookWithNotes(…, in: db) } }` wrapper, then still calls
  `dispatchQueuedAutoActions(result.dispatches)` after commit. This is
  a pure refactor of `createNotebookWithNotes` (byte-for-byte behavior
  preserved) so note-edit-rewrite and existing ingest tests stay green.

**Step 2 — `promoteCommentToNotebook`** in the same file:
`promoteCommentToNotebook(noteId:commentId:notebookTitle:linkKind:
provenance:assignedBy:)` opening **one**
`driver.withDatabase { database.transaction { db in … } }` and, against
that single `db`:
  1. validate the comment belongs to `noteId` (comment fetch scoped by
     `noteId` / `requireNote(noteId, in: db)`), else
     `NoteServiceError.invalidInput`;
  2. derive the title (explicit `notebookTitle` else
     `noteTitle(from:)` / `NoteTitleDerivation.title(from:)` on the
     comment `body_markdown`, 120-char cap, fallback
     "Comment notebook") and call `insertNotebookWithNotes(…, in: db)`
     with a single page carrying the comment `body_markdown`, capturing
     `(ingestResult, dispatches)`;
  3. **inline** the `note_links` INSERT within the *same* `db`
     (copy the `linkNotes` upsert SQL/bindings verbatim, source
     `noteId` → `ingestResult.notes.first`, so the row is written in
     the same transaction — do **not** call the self-transacting
     `linkNotes`);
  4. return `(notebook: ingestResult.notebook,
     note: ingestResult.notes.first)` from the in-transaction inserts —
     no separate re-fetch inside the transaction.
- After the transaction commits, call
  `dispatchQueuedAutoActions(dispatches)` (mirroring
  `createNotebookWithNotes`) so promote-created notebook/note
  auto-actions still fire.

**Provenance / `assignedBy` threading (resolves D5 residual ambiguity)**:
the single `provenance` param threads to **both** the notebook/note
insert path (via `insertNotebookWithNotes`) **and** the inlined
`note_links` row, so a promote is uniformly attributed (design default
`.human`). `assignedBy` threads **only** to `insertNotebookWithNotes`
(tag assignment) — the `note_links` schema has no `assignedBy` column,
matching `linkNotes`, which takes no `assignedBy` param.

**Checklist**:
- [x] `insertNotebookWithNotes(…, in db:)` extracted; existing
      `createNotebookWithNotes` refactored to call it (extended, not
      forked) with identical observable behavior
- [x] Wrong-note comment id → `invalidInput` (checked before any insert)
- [x] All inserts + link (notebook + first note + related/human link)
      run in **one** `db` transaction — no composition of the two
      self-transacting public methods
- [x] `note_links` INSERT inlined from `linkNotes` SQL against the same
      `db`; source note → first new note, `linkKind` `related`
- [x] `provenance` applied to both notebook/note inserts and the link;
      `assignedBy` applied only to the notebook/note path
- [x] Title derivation shared with existing helpers (no fork)
- [x] Return maps from `insertNotebookWithNotes` result (`notebook`,
      `notes.first`) — no separate re-fetch inside the transaction
- [x] `dispatchQueuedAutoActions` invoked after commit

### TASK-003: Client protocol + service client (D3)
**Status**: DONE
**Depends On**: TASK-001, TASK-002
**Deliverables**:
- `RielaNoteUIClient` additions with compatible protocol-extension
  defaults: `answerNoteSelectionQuestion(...)` (throws not-configured),
  `addComment(noteId:bodyMarkdown:author:)` (forwards to author-less),
  `promoteCommentToNotebook(noteId:commentId:) -> RielaNoteDetail`.
- `NoteServiceRielaNoteUIClient`: optional `selectionQuestionProvider`
  init param; author passthrough to `service.addComment`; promote
  calls service then re-fetches detail.
- `Sources/RielaApp/NoteWindowController.swift`: wire
  `RielaWorkflowNoteSelectionQuestionProvider.defaultProvider`.

**Checklist**:
- [x] Existing conformances/stubs compile unchanged
- [x] Nil provider → not-configured error surfaced

### TASK-004: View-model selection QA state (D4, D6)
**Status**: DONE
**Depends On**: TASK-003
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+SelectionQA.swift`:
  `isSelectionQuestionLoading`, `selectionQuestionError`,
  `isCommentPromotionLoading`, `commentPromotionError`, generation
  guards, `clearSelectionQAState()`;
  `askSelectionQuestion(question:draftBodyMarkdown:selectedText:
  selectionStart:selectionEnd:) async -> Bool` (answer → compose
  comment → persist with author "note-agent" → refresh detail);
  `promoteCommentToNotebook(commentId:) async`.
- Pure helper `rielaNoteSelectionQACommentMarkdown(selectedText:
  question:answerMarkdown:)` in `RielaNoteEditHelpers.swift`
  (blockquoted selection, 400-char cap, Q/A sections).

**Checklist**:
- [x] Failure persists nothing; stale results dropped
- [x] Note switches clear QA state

### TASK-005: Detail view UI (D1, D4, D5, D6)
**Status**: DONE
**Depends On**: TASK-004
**Deliverables**:
- `RielaNoteDetailView`: selection chip row gains
  `[? Ask question ⇧⌘K]`; pill question mode (placeholder
  "Ask about selection", icon swap, selection badge required, submit →
  `askSelectionQuestion`, stale selection → error, no whole-note
  fallback); "Saved as comment" caption; auto-expand Comments on
  success; per-comment `Create notebook` action (book icon) with
  loading/disabled state and error caption; Links disclosure expands
  after promotion.

**Checklist**:
- [x] Rewrite flow behavior unchanged
- [x] ⇧⌘K only in edit mode with non-empty selection
- [x] Body/draft never modified by questions

### TASK-006: Tests (design Test Plan)
**Status**: DONE
**Depends On**: TASK-005
**Deliverables**:
- `Tests/RielaNoteUITests`: QA comment markdown helper (multi-line,
  truncation, emoji); view-model question lifecycle
  (success-persists-one-comment / failure / stale / not-configured);
  client round-trips (provider stub, author passthrough, promote
  detail+link); workflow provider args/JSONL/env tests.
- `Tests/RielaNoteTests`: service promote transaction, validation,
  title derivation/fallback, provenance. Include a regression that a
  failing link/insert leaves **nothing** persisted (no orphan notebook
  without its link — the SR-001 partial-failure window), and that
  existing `createNotebookWithNotes` ingest tests remain green after the
  `insertNotebookWithNotes` extraction.

**Checklist**:
- [x] `swift build` green
- [x] `swift test --filter RielaNoteUITests` and
      `--filter RielaNoteTests` green
- [x] Example bundle validate + mock dry run recorded

---

## Verification

- `swift build`
- `swift test --filter RielaNoteUITests`
- `swift test --filter RielaNoteTests`
- `riela workflow validate note-selection-question
  --workflow-definition-dir examples`
- Manual: edit note → select text → Ask question → answer appears as
  agent comment → Create notebook from comment → link visible in
  Links, notebook lists the new note.

## Notes

- Do not modify the Agent tab pathway
  (`RielaNoteAgentView`/`RielaNoteAgentViewModel`).
- Keep the rewrite (Ask for changes) pathway behavior identical;
  **extend, do not fork** `RielaNoteWorkflowProviderSupport` so the
  note-edit-rewrite pill pathway stays green.
- Follow existing 2-space style; no macOS 15-only APIs
  (platforms macOS 14 / iOS 17).

## Staging Discipline (Step 3 residual-risk guardrails)

- Stage **only** the two accepted docs
  (`design-docs/specs/design-riela-note-selection-qa-comments.md`,
  `impl-plans/active/riela-note-selection-qa-comments.md`) plus the new
  feature files listed per task; commit exactly those as
  `committedFiles`.
- Do **not** modify or stage unrelated working-tree changes
  (apple-gateway / apple-notes files, Seatbelt sandbox files, session
  command files, WorkflowExecutionTimeline files) — other sessions run
  concurrently in this repo.
- Keep `promoteCommentToNotebook` atomic: notebook + first note +
  related/human source-note link in **one** `db` transaction (TASK-002)
  via the shared `insertNotebookWithNotes(…, in db:)` helper + inlined
  `note_links` INSERT — never by composing the self-transacting
  `createNotebookWithNotes` and `linkNotes` (that is two transactions;
  SR-001).

## Progress Log

### 2026-07-07 — Step 6 implementation (all tasks DONE)

- **TASK-001**: Added
  `Sources/RielaNoteUI/RielaNoteWorkflowSelectionQuestionProvider.swift`
  (`RielaNoteSelectionAnswerDraft`, `RielaNoteSelectionQuestionProviding`,
  `RielaNoteSelectionQuestionError`, macOS
  `RielaWorkflowNoteSelectionQuestionProvider` with the
  `RIELA_NOTE_SELECTION_QUESTION_*` env overrides + 120 s deadline,
  reusing all `RielaNoteWorkflowProviderSupport.swift` helpers — no
  duplicated subprocess/pipe/env-sanitization logic). Shipped
  `examples/note-selection-question/` (workflow.json, two nodes, prompt,
  mock-scenario.json, EXPECTED_RESULTS.md). Validate + mock dry run
  recorded (status `completed`, root output `{answerMarkdown, summary}`).
- **TASK-002**: Refactored `createNotebookWithNotes` into a private
  `insertNotebookWithNotes(…, in db:)` helper (byte-for-byte behavior
  preserved; existing ingest tests stay green) and added
  `promoteCommentToNotebook` in the same file — one transaction that
  validates the comment belongs to the note (`invalidInput` before any
  insert), inserts notebook + first note via the shared helper, and
  **inlines** the `note_links` upsert against the same `db`.
  `provenance` threads to both paths; `assignedBy` only to the
  notebook/note path. Title via `promoteCommentNotebookTitle` (explicit →
  `noteTitle(from:)` → "Comment notebook", 120-char cap).
- **TASK-003**: `RielaNoteUIClient` gained `answerNoteSelectionQuestion`
  (default throws `.notConfigured`), `addComment(…author:)` (default
  forwards to author-less; `NoteServiceRielaNoteUIClient` passes author
  through), and `promoteCommentToNotebook` (default throws
  `RielaNoteUIClientCapabilityError.commentPromotionUnsupported`; concrete
  client re-fetches detail). Optional `selectionQuestionProvider` init
  param wired in `NoteWindowController`.
- **TASK-004**: Added
  `RielaNoteLibraryViewModel+SelectionQA.swift` (`askSelectionQuestion`
  → answer → compose comment → persist author `note-agent` → refresh;
  `promoteCommentToNotebook`; generation + note-id guards;
  `clearSelectionQAState`; `markSelectionQuestionSelectionStale`) plus new
  published QA/promotion state, cleared on note switch. Pure helper
  `rielaNoteSelectionQACommentMarkdown` (blockquote, 400-char cap, Q/A).
- **TASK-005**: `RielaNoteDetailView` selection chip row now offers
  `[? Ask question ⇧⌘K]`; the top pill has a question mode (icon swap,
  "Ask about selection" placeholder, required selection badge, stale-
  selection error, no whole-note fallback, "Saved as comment" caption,
  auto-expand Comments on success). Body/draft is never mutated by a
  question. Each comment row has a `Create notebook` (book) action with
  loading/disabled state + error caption; Links expands after promotion.
- **TASK-006**: Added `Tests/RielaNoteTests/NoteServicePromoteCommentTests.swift`
  (7 tests: one-transaction link, explicit/derived/fallback title,
  provenance + link kind, wrong-note rejection persists nothing, title
  helper cap) and `Tests/RielaNoteUITests/RielaNoteSelectionQATests.swift`
  (15 tests: comment-markdown helper multi-line/truncation/emoji;
  view-model success-persists-one/failure/stale/not-configured; promote
  refresh + error; client provider round-trip / not-configured / author
  passthrough / promote detail+link; workflow arg + JSONL parse).

### Verification results (2026-07-07)

- `swift build` — Build complete.
- `swift test --filter RielaNoteTests` — 81 tests, 0 failures
  (incl. 7 new `NoteServicePromoteCommentTests`).
- `swift test --filter RielaNoteUITests` — 104 tests, 0 failures
  (incl. 15 new `RielaNoteSelectionQATests`).
- `riela workflow validate note-selection-question
  --workflow-definition-dir examples` — `valid: true`.
- Mock dry run of `note-selection-question` — status `completed`,
  root output `{answerMarkdown, summary}`.
