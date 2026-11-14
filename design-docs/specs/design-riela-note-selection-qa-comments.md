# Riela Note Selection Q&A Comments

## Summary

A follow-up to the shipped note edit agent UI
(`design-riela-note-edit-agent-ui.md`, commits `31f07fc`..`d6d702a`).
While editing a note, the user can select body text and **ask the agent
a question about the selection** (distinct from the existing
"Ask for changes" rewrite). The answer is **persisted as a comment** on
the note. Any comment can then be **promoted into a new notebook**; the
promotion creates the notebook with the comment content as its first
note and **links the source note to that new note**, so the note and
the new notebook are connected through the existing note-link
machinery.

The Agent tab / bottom query agent remains untouched.

Requirements source: user request 2026-07-07 (Japanese memo):
「textを範囲選択して、そこについてagentに質問することもできるように
せよ。質問結果はcommentとして残る。このコメントは新しいnotebookとして
作成することができる。この場合このnoteと新しいnotebookの(ノートが
リンクされる)」

## Requirements (restated)

1. **R1 — Selection question**: with body text selected (edit mode),
   the user can ask the agent a question scoped to that selection.
2. **R2 — Answer as comment**: a successful answer is automatically
   saved as a comment on the note (quoted selection + Q + A), with
   agent authorship, and shown in the Comments section.
3. **R3 — Promote comment to notebook**: any comment offers a
   "Create notebook" action. It creates a new notebook whose first note
   carries the comment content, and links the source note to that new
   note (`related`), connecting note and notebook.
4. **R4 — Non-goals**: the Agent tab query pathway; read-mode
   selection (selection exists only in the edit-mode
   `RielaNoteSelectableTextEditor`); moving/deleting comments.

## Code-Verified Current State

- **Selection machinery exists (edit mode)**:
  `RielaNoteSelectableTextEditor(text:selectedRange:)`
  (`RielaNoteDetailView.swift:392`, editor in
  `Sources/RielaNoteUI/RielaNoteSelectableTextEditor.swift`), with a
  floating chip `Ask for changes Cmd-K` (`:398-400`) that calls
  `armSelectionScope()` (`:659`) to scope the top rewrite pill
  (`rewritePill(_:)` `:188-246`, submit `submitRewrite(for:)` `:668`).
- **Rewrite dispatch pattern** (to be mirrored):
  `RielaNoteEditRewriteProviding` / macOS
  `RielaWorkflowNoteEditRewriteProvider`
  (`RielaNoteWorkflowEditRewriteProvider.swift`), shared subprocess
  helpers in `RielaNoteWorkflowProviderSupport.swift`, client method
  `proposeNoteBodyRewrite(...)` with a protocol-extension default
  throwing not-configured, optional provider injected into
  `NoteServiceRielaNoteUIClient`, wired in
  `Sources/RielaApp/NoteWindowController.swift`, example bundle
  `examples/note-edit-rewrite/` with `mock-scenario.json`.
- **View-model extension pattern**:
  `RielaNoteLibraryViewModel+EditRewrite.swift`
  (`proposeBodyRewrite`, generation + note-id guards,
  `clearEditRewriteState`).
- **Comments**: `NoteService.addComment(noteId:bodyMarkdown:author:)`
  (`Sources/RielaNote/NoteService.swift:584`, author defaults to
  `"user"`); `note_comments` schema has `comment_id`, `author`
  (`NoteStoreSchema.swift:425-432`). The UI client protocol only
  exposes `addComment(noteId:bodyMarkdown:)` (no author). Comments
  render with author + markdown in `comments(_:)`
  (`RielaNoteDetailView.swift:515`).
- **Notebooks**: `NoteService.createNotebookWithNotes(title:pages:...)`
  (`NoteService.swift:185`) creates a notebook plus notes in one
  transaction (`NotePageDraft` pages).
- **Links are note-to-note only** (`note_links`,
  `NoteStoreSchema.swift:415-422`); notebooks are connected through
  their notes. `NoteService.linkNotes` enforces provenance.

## Design Decisions

### D1 — Ask-question affordance (edit mode)

- The floating selection chip row in `bodyEditor(_:)` becomes two
  actions: the existing `[✎ Ask for changes ⌘K]` plus
  `[? Ask question ⇧⌘K]` (`questionmark.circle`).
- Pressing "Ask question" (or `⇧⌘K` with a non-empty selection) arms
  **question mode** on the top pill: placeholder switches to
  "Ask about selection", the armed-selection badge appears (same
  UTF-16-length badge as rewrite scope), and submit routes to the
  question pathway (D2) instead of the rewrite pathway. A mode
  indicator on the pill (icon swap pencil → question mark) makes the
  active mode visible; clearing the badge or submitting returns the
  pill to rewrite mode.
- A question **requires** a non-empty, still-valid selection: if the
  armed range no longer fits the draft at submit time, show the
  existing stale-selection error path (no whole-note fallback —
  whole-note questions belong to the Agent tab, R4).

### D2 — Question dispatch pathway

Mirror the rewrite provider end to end:

- **Draft type**: `RielaNoteSelectionAnswerDraft { answerMarkdown:
  String, summary: String? }` (`Codable`, `Equatable`, `Sendable`).
- **Provider protocol**: `RielaNoteSelectionQuestionProviding` with
  `answerQuestion(noteId:noteRoot:question:bodyMarkdown:selectedText:
  selectionStart:selectionEnd:) async throws ->
  RielaNoteSelectionAnswerDraft` (selection fields required, not
  optional — D1).
- **Workflow provider** (macOS):
  `RielaWorkflowNoteSelectionQuestionProvider` running
  `riela workflow run note-selection-question
  --workflow-definition-dir … --variables … --output jsonl`, reusing
  the shared helpers in `RielaNoteWorkflowProviderSupport.swift`
  (process box, pipe drains, executable resolution, JSONL parsing,
  env sanitization with the model-auth allowlist). Env overrides:
  `RIELA_NOTE_SELECTION_QUESTION_WORKFLOW_DIR`,
  `RIELA_NOTE_SELECTION_QUESTION_RIELA_EXECUTABLE`; same default
  workflow-dir candidates; deadline 120 s. Errors reuse
  `RielaNoteEditRewriteError`-style cases via a shared or parallel
  enum (`notConfigured`, `workflowFailed`, `invalidOutput`,
  `timedOut`).
- **Example bundle** `examples/note-selection-question/`: mirror the
  two-node structure of `examples/note-edit-rewrite/` — an
  `answer-selection-question` worker node (`executionBackend`
  `codex-agent`, `model` `gpt-5.5`, `promptTemplateFile` under
  `prompts/`; prompt receives note id, full body for context, the
  selected text, and the question; instructed to answer about the
  selection concisely in markdown, returning `{answerMarkdown,
  summary}`) plus a `workflow-output` node (`kind` `output`,
  `latest-input-payload` projection). Ship `workflow.json`, `nodes/`,
  `prompts/`, `mock-scenario.json`, and `EXPECTED_RESULTS.md`
  (validate + mock dry-run recorded).

### D3 — Client surface

- `RielaNoteUIClient` gains:
  - `answerNoteSelectionQuestion(noteId:question:bodyMarkdown:
    selectedText:selectionStart:selectionEnd:) async throws ->
    RielaNoteSelectionAnswerDraft` — protocol-extension default throws
    not-configured.
  - `addComment(noteId:bodyMarkdown:author:)` overload — default
    extension forwards to the existing author-less `addComment` so
    current conformances/stubs keep compiling;
    `NoteServiceRielaNoteUIClient` passes the author through to
    `service.addComment`.
  - `promoteCommentToNotebook(noteId:commentId:) async throws ->
    RielaNoteDetail` (D5).
- `NoteServiceRielaNoteUIClient` gains optional
  `selectionQuestionProvider` (init default `nil`, throws
  not-configured when absent), wired in `NoteWindowController` via
  `RielaWorkflowNoteSelectionQuestionProvider.defaultProvider(
  environment:)`.

### D4 — Answer persistence as comment (R2)

- View-model extension `RielaNoteLibraryViewModel+SelectionQA.swift`:
  `isSelectionQuestionLoading`, `selectionQuestionError`, generation
  counter, `clearSelectionQAState()` (called from note switches), and
  `askSelectionQuestion(question:draftBodyMarkdown:selectedText:
  selectionStart:selectionEnd:) async -> Bool`:
  1. calls `client.answerNoteSelectionQuestion(...)`;
  2. composes the comment via the pure helper
     `rielaNoteSelectionQACommentMarkdown(selectedText:question:
     answerMarkdown:)`:
     selection quoted as a markdown blockquote (per-line `> `,
     truncated to 400 characters with an ellipsis marker), then
     `**Q:** …`, then `**A:** …`;
  3. persists via `client.addComment(noteId:bodyMarkdown:author:
     "note-agent")` and replaces `selectedDetail` with the returned
     detail (new comment visible immediately);
  4. guards with generation + selected-note-id as in the rewrite
     pathway; on any failure sets `selectionQuestionError` and
     persists nothing.
- The detail view auto-expands the Comments disclosure after a
  successful question, and the pill shows a transient "Saved as
  comment" caption (mirrors the rewrite summary caption).
- The note body/draft is never modified by a question.

### D5 — Promote comment to notebook (R3)

- **Service** (`Sources/RielaNote/NoteService.swift`):
  `promoteCommentToNotebook(noteId:commentId:notebookTitle:linkKind:
  provenance:assignedBy:)` — one transaction that:
  1. loads the comment (must belong to `noteId`, else
     `invalidInput`);
  2. creates the notebook + one note whose body is the comment's
     `body_markdown` (reusing the `createNotebookWithNotes` insert
     path — which returns `NotebookIngestResult { notebook: Notebook,
     notes: [Note] }` (`NoteModels.swift:121`); map its `notebook` and
     `notes.first` for the return; title = explicit `notebookTitle` or
     derived from the comment body via the existing `noteTitle(from:)` /
     `NoteTitleDerivation.title(from:)` heuristic, 120-char cap,
     fallback "Comment notebook"); the method's `assignedBy` flows to
     `createNotebookWithNotes` (which accepts `assignedBy`), not to
     the link;
  3. links source note → new note via
     `NoteService+Relations.swift` `linkNotes(from:to:linkKind:
     provenance:)` (`linkKind` default `related`, `provenance`
     default `.human`) — note `linkNotes` takes **no** `assignedBy`
     parameter, so the promote signature's `assignedBy` is scoped to
     the notebook/note creation only;
  returns `(notebook: Notebook, note: Note)`, mapped from the
  `NotebookIngestResult` above (`result.notebook`, `result.notes.first`).
  - **Atomicity mechanism (single transaction)**: to keep steps 2–3 in
    one transaction, the notebook/note insert body of
    `createNotebookWithNotes` is extracted into a shared
    `in database:`-scoped helper (`insertNotebookWithNotes(…, in db:)`)
    that `createNotebookWithNotes` is refactored to reuse (extended, not
    forked), and `promoteCommentToNotebook` calls that helper plus an
    **inlined** `note_links` INSERT against the *same* `db`. The two
    self-transacting public methods (`createNotebookWithNotes`,
    `linkNotes`) are **not** composed, which would open two
    transactions and leave the named partial-failure window.
  - **Provenance / `assignedBy`**: the single `provenance` param threads
    to both the notebook/note inserts and the inlined `note_links` row
    (uniform attribution, default `.human`); `assignedBy` threads only
    to the notebook/note path (`note_links` has no `assignedBy` column).
- **Client**: `promoteCommentToNotebook(noteId:commentId:)` calls the
  service then re-fetches and returns `RielaNoteDetail` (the new link
  shows up in Links).
- **UI**: each comment row in `comments(_:)` gains a borderless
  `Create notebook` action (`book` icon, `.help()` tooltip). On
  success the detail refreshes and the Links disclosure expands; the
  action is disabled while a promotion is in flight
  (`isCommentPromotionLoading`, `commentPromotionError` on the view
  model). Promotion is additive (never destructive), so no
  confirmation dialog.

### D6 — Availability and errors

- Question affordances appear only in edit mode with a non-empty
  selection (read-only notes never enter edit mode, so they get no
  question affordance in this pass — documented limitation under R4).
- Provider errors surface as a caption under the pill (same slot as
  rewrite errors); promotion errors surface as a caption in the
  Comments section. In-flight requests are superseded by generation
  bumps; repeat submits disabled while loading.

## Non-goals

- Read-mode selection questions; whole-note questions (Agent tab).
- Editing/deleting comments; moving the new notebook's note.
- Streaming answers; conversation threading on comments.
- GraphQL exposure of the question/promotion pathways.
- iOS selection features (unchanged from the edit-agent design).

## Test Plan

- `Tests/RielaNoteUITests`:
  - helper: QA comment markdown composition (multi-line selection
    quoting, 400-char truncation, emoji/UTF-16 boundaries).
  - view-model: question success persists exactly one comment and
    refreshes detail; provider failure persists nothing and sets
    `selectionQuestionError`; stale generation/note-switch drops the
    result; not-configured surfaces.
  - client: stub selection-question provider round-trip; nil provider
    throws not-configured; `addComment` author passthrough; promote
    returns detail containing the new link.
  - workflow provider: argument construction + JSONL parsing
    (mirroring the rewrite provider tests, incl. env allowlist).
- `Tests/RielaNoteTests`:
  - service promote: creates notebook + note + link in one
    transaction; wrong-note comment id rejected; title derivation and
    fallback; provenance recorded.
- Workflow bundle: `riela workflow validate note-selection-question
  --workflow-definition-dir examples`; mock dry run recorded in
  `EXPECTED_RESULTS.md`.
