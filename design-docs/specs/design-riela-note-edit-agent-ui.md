# Riela Note Edit Agent UI

## Summary

A rework of the Riela Note detail header and edit flow
(`Sources/RielaNoteUI`, hosted by `Sources/RielaApp`). The note detail
pane gets a top action row: an **Edit** control top-left and
**copy / download / expand** buttons top-right. Pressing Edit enables
the existing manual markdown editing *and* opens an
**"Ask for changes"** agent text box scoped to the note being edited.
While editing, selecting text in the body surfaces a floating
**"Ask for changes" (⌘K)** affordance that scopes the agent request to
the selection. Agent rewrites are applied to the edit draft for user
review; nothing is persisted until the user saves.

The always-present note-query agent (the Agent tab composer,
`RielaNoteAgentView`) is untouched; the edit agent box is a separate,
note-scoped affordance.

Requirements source: user request 2026-07-07 (Japanese memo) plus three
design captures on 2026-07-07
(`Screenshot 2026-07-07 at 11.28.42.png`,
`... 11.29.23.png`, `... 11.34.46.png`). Parent designs:
`design-docs/specs/design-riela-note.md`,
`design-docs/specs/design-riela-note-ui-refinements.md`.

## Requirements (restated)

1. **R1 — Header layout**: the note detail view shows an "edit" button
   at the top-left and copy, download, expand buttons at the top-right.
2. **R2 — Edit activation**: pressing Edit (a) enables manual editing
   of the note body and (b) opens a text box for asking an agent to
   modify the note ("Ask for changes" pill: pencil icon + text field +
   circular ↑ send button, per the 11.28.42/11.29.23 captures).
3. **R3 — Selection-scoped ask**: while editing, the user can select
   text in the body and ask for changes against that selection (per the
   11.34.46 capture: floating toolbar "Ask for changes ⌘K" above the
   selection).
4. **R4 — Separate from query agent**: the bottom/always-available
   note-query agent (Agent tab) remains as-is; the edit agent text box
   is an independent, edit-scoped affordance.

### Design-capture reading

- 11.28.42 / 11.29.23: top-left pill `[✎ | Ask for changes | (↑)]`;
  top-right icon group `[copy] [download] [expand]`.
- 11.34.46: edit mode with a text selection; a floating toolbar sits
  above the selection with `Ask for changes ⌘K` (plus B / I / Text
  formatting controls, which are **out of scope**, see Non-goals); the
  top-left shows a compact `✎ Edit` control; the bottom persistent
  "Ask anything" bar is the existing query agent (out of scope, R4).

## Code-Verified Current State

- **Note detail header** (`Sources/RielaNoteUI/RielaNoteDetailView.swift:92-121`):
  title row with an Edit/Preview toggle button placed at the trailing
  edge (`:104-111`), toggling `RielaNoteBodyDraftState`
  (`:517-550`). No copy, download, or expand affordances exist.
- **Manual editing** exists: `bodyEditor(_:)`
  (`RielaNoteDetailView.swift:264-290`) shows a `TextEditor` bound to
  `bodyDraft.draftBodyMarkdown` with Cancel/Save;
  Save routes through
  `RielaNoteLibraryViewModel.saveSelectedNoteBody(_:expectedNoteId:)`
  (`RielaNoteLibraryViewModel.swift:491-511`) →
  `client.updateNoteBody(noteId:bodyMarkdown:)`
  (`RielaNoteUIClient.swift:99`, impl `:368-371`).
- **No agent-assisted editing exists.** The only AI-backed note
  operation is link extraction:
  `RielaNoteLinkProposalProviding` / macOS
  `RielaWorkflowNoteLinkProposalProvider`
  (`RielaNoteWorkflowLinkProposalProvider.swift`), which shells out to
  `riela workflow run note-link-extract --workflow-definition-dir …
  --variables … --output jsonl`, parses the last JSONL line's
  `result.rootOutput`, and is injected into
  `NoteServiceRielaNoteUIClient` as an optional provider
  (`RielaNoteUIClient.swift:233,239`), wired by
  `NoteWindowController` via
  `RielaWorkflowNoteLinkProposalProvider.defaultProvider(environment:)`
  (`Sources/RielaApp/NoteWindowController.swift:32-36`). Env overrides:
  `RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR`,
  `RIELA_NOTE_LINK_EXTRACT_RIELA_EXECUTABLE`,
  `RIELA_APP_RIELA_EXECUTABLE`; workflow bundle at
  `examples/note-link-extract/` (with `mock-scenario.json` and
  `EXPECTED_RESULTS.md`).
- **Query agent**: `RielaNoteAgentView` (composer at the bottom of the
  Agent tab) → `RielaNoteAgentViewModel.submitDraft()` →
  `client.answerNoteAgentTurn(message:limit:)`. Untouched by this
  design (R4).
- **Layout host**: `RielaNoteRootView.swift:135-158` builds the regular
  three-column `NavigationSplitView` (filters | list | detail) without
  a `columnVisibility` binding; compact uses `NavigationStack`.
- **Read-only notes**: `note.readOnly` hides the Edit button today
  (`RielaNoteDetailView.swift:104`).
- **Platforms**: package targets macOS 14 / iOS 17
  (`Package.swift:16-19`). SwiftUI `TextEditor(selection:)` requires
  macOS 15/iOS 18, so selection tracking needs an
  `NSViewRepresentable` on macOS 14.
- **View-model async-state conventions**: generation counters +
  note-id guards, e.g. link proposals
  (`RielaNoteLibraryViewModel+LinkProposals.swift:4-37`).

## Design Decisions

### D1 — Header action row

Add a dedicated action row at the top of the detail pane, above the
title row, inside `header(_:)`:

- **Leading**: edit control (D2). Hidden for `readOnly` notes.
- **Trailing**: icon buttons, in order: **Copy** (`doc.on.doc` or
  `square.on.square`), **Download** (`square.and.arrow.down`),
  **Expand** (`arrow.up.left.and.arrow.down.right` /
  `arrow.down.right.and.arrow.up.left` when expanded). Always visible,
  `.help()` tooltips, `.buttonStyle(.borderless)` compact icons.

The existing trailing Edit/Preview toggle in the title row is removed
(replaced by the leading edit control). The title row, note-number row,
and pager stay below the action row.

### D2 — Edit control states

- **Idle**: a compact bordered button `[✎ Edit]` at top-left. Pressing
  it enters edit mode: `bodyDraft.toggle(...)` (existing) **and**
  reveals the agent pill.
- **Editing**: the top-left control becomes the **"Ask for changes"
  pill**: pencil icon + single-line `TextField("Ask for changes")` +
  circular ↑ submit button (disabled while empty or while a rewrite is
  in flight; shows `ProgressView` when loading). Submitting dispatches
  an agent rewrite (D4). A separate small `[Preview]`-style exit is not
  added; leaving edit mode stays on the existing Cancel / Save buttons
  under the editor.
- Editing keeps the existing draft semantics
  (`RielaNoteBodyDraftState`); the pill never writes to the store
  directly.

### D3 — Selection-scoped ask (edit mode, macOS)

- Replace the edit-mode `TextEditor` with
  `RielaNoteSelectableTextEditor`, an `NSViewRepresentable` wrapping
  `NSTextView` (macOS) binding `text: String` and
  `selectedRange: NSRange`. On iOS, fall back to the plain
  `TextEditor` without selection features (compact hosts don't get
  R3 in this pass).
- When the selection is non-empty, show a floating chip
  `[✎ Ask for changes ⌘K]` overlaid near the top of the editor
  (anchored via the text view's
  `firstRect(forCharacterRange:)`-derived offset when cheaply
  available; a top-of-editor anchor is an acceptable v1). Pressing the
  chip — or `⌘K` while editing with a non-empty selection — focuses
  the pill and arms **selection scope**: the pill shows a removable
  `Selection` badge with the selected-character count.
- Scope resolution at submit time: if selection scope is armed and the
  stored range is still valid for the current draft, the agent request
  targets that range; otherwise it falls back to whole-note scope.

### D4 — Agent rewrite dispatch pathway

Follow the link-proposal provider pattern:

- **Draft type** (`RielaNoteUI`):
  `RielaNoteEditRewriteDraft { rewrittenMarkdown: String,
  summary: String? }` (`Codable`, `Equatable`, `Sendable`).
- **Provider protocol**: `RielaNoteEditRewriteProviding` with
  `proposeRewrite(noteId:noteRoot:instruction:bodyMarkdown:
  selectedText:selectionStart:selectionEnd:) async throws ->
  RielaNoteEditRewriteDraft`. Selection fields are `nil` for
  whole-note scope. `bodyMarkdown` is the **current draft**, not the
  persisted body, so manual edits are respected.
- **Workflow provider** (macOS only, mirroring
  `RielaWorkflowNoteLinkProposalProvider`):
  `RielaWorkflowNoteEditRewriteProvider` runs
  `riela workflow run note-edit-rewrite --workflow-definition-dir …
  --variables {"noteRoot":…,"workflowInput":{…}} --output jsonl`,
  parses the last decodable JSONL line's
  `result.rootOutput.{rewrittenMarkdown,summary}`. Env overrides:
  `RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR`,
  `RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE`, shared
  `RIELA_APP_RIELA_EXECUTABLE`; default workflow-dir candidates are the
  same as link extraction (bundle `Resources/examples`, cwd
  `examples`). Default deadline 120 s (rewrites are longer than link
  picks). Process cancellation/termination handling identical to the
  link provider (shared `ProcessBox`/pipe-drain helpers may be
  extracted rather than duplicated).
- **Client**: add
  `proposeNoteBodyRewrite(noteId:instruction:bodyMarkdown:
  selectedText:selectionStart:selectionEnd:) async throws ->
  RielaNoteEditRewriteDraft` to `RielaNoteUIClient`, with a protocol
  extension default that throws
  `RielaNoteEditRewriteError.notConfigured` (keeps existing
  conformances compiling). `NoteServiceRielaNoteUIClient` gains an
  optional `editRewriteProvider` (init default `nil`); it forwards to
  the provider or throws `.notConfigured`. **No deterministic
  fallback**: unlike link extraction there is no meaningful heuristic
  rewrite, so absence of a provider surfaces an inline error in the
  pill area ("Edit agent is not configured").
- **Wiring**: `NoteWindowController` passes
  `RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment:)`
  (nil when no `note-edit-rewrite/workflow.json` is found — the UI then
  shows the not-configured error on submit).

### D5 — Applying agent results (review-before-save)

- Whole-note scope: the returned `rewrittenMarkdown` replaces
  `bodyDraft.draftBodyMarkdown`.
- Selection scope: `rewrittenMarkdown` is the **replacement for the
  selected range only**; the view splices it into the draft via a pure
  helper `rielaNoteApplyingRewrite(draft:range:replacement:)` and
  selects the inserted text.
- The result is never persisted automatically; the user reviews in the
  editor and presses the existing Save (which already routes through
  `saveSelectedNoteBody` with the expected-note-id guard). A returned
  `summary` is shown as a caption under the pill until the next
  action.
- View-model state (on `RielaNoteLibraryViewModel`, following the
  link-proposal conventions): `isEditRewriteLoading`,
  `editRewriteError`, `editRewriteSummary`, private
  `editRewriteGeneration`; method
  `proposeBodyRewrite(instruction:draftBodyMarkdown:selectedText:
  selectionStart:selectionEnd:) async -> RielaNoteEditRewriteDraft?`
  guarded by generation + selected-note-id. Note switches
  (`resetEditingState`) clear rewrite state.

### D6 — Copy

Copies the currently displayed body markdown — the draft when editing,
otherwise `note.bodyMarkdown` — to the general pasteboard
(`NSPasteboard` on macOS, `UIPasteboard` on iOS). Brief
checkmark feedback on the button (icon swap for ~1.5 s).

### D7 — Download

Exports the same markdown via SwiftUI `.fileExporter` with a small
`FileDocument` wrapper (`RielaNoteMarkdownFileDocument`), content type
`UTType(filenameExtension: "md", conformingTo: .plainText) ??
.plainText`, default filename from a pure helper
`rielaNoteExportFilename(title:noteId:)` (title slugged to a safe
filename, fallback to note id, `.md` appended by the exporter).

### D8 — Expand

Toggles a focused, detail-only presentation:

- `RielaNoteLibraryViewModel` gains `@Published var isDetailExpanded:
  Bool` (pure UI state).
- Regular layout: `RielaNoteRootView` passes a
  `columnVisibility` binding (`NavigationSplitViewVisibility`) to the
  `NavigationSplitView`, derived from `isDetailExpanded`
  (`.detailOnly` ↔ `.all`), synced both ways so the user can also
  restore columns via the standard sidebar controls.
- Compact layout: the detail is already full-screen; the expand button
  is hidden.

### D9 — Example workflow bundle `examples/note-edit-rewrite/`

Mirrors `examples/note-link-extract/`:

- `workflow.json`: single LLM worker node `rewrite-note-body`
  (prompt gets `workflowInput.noteId`, `bodyMarkdown`, `instruction`,
  optional `selectedText`) → `workflow-output` projection
  (`latest-input-payload`). Output contract:
  `{"rewrittenMarkdown": "...", "summary": "..."}` — for selection
  scope the model is instructed to return only the replacement for
  `selectedText`.
- The bundle uses the sequential workflow path only: one worker step
  followed by one output step. It must not use fanout, branch joins, or
  multiple parallel rewrite candidates.
- `prompts/rewrite-note-body.md`, `nodes/*.json`,
  `mock-scenario.json` (deterministic payload for tests/dry runs),
  `EXPECTED_RESULTS.md`.

### D10 — Read-only and error behavior

- `readOnly` notes: no edit control (as today); copy/download/expand
  remain available.
- Rewrite failures (`workflowFailed`, `timedOut`, `invalidOutput`,
  `notConfigured`) render as a caption-sized error under the pill;
  the draft is left untouched. In-flight requests are superseded by
  generation bumps on note switch or repeated submits (repeat submits
  are disabled while loading).

## Non-goals

- The bottom note-query agent (Agent tab) — unchanged (R4).
- B / I / Text formatting buttons from the 11.34.46 capture.
- Streaming rewrite output; diff-style review UI.
- iOS selection-scoped ask (macOS-first; iOS keeps whole-note pill).
- Version history / undo stacks beyond the draft-replace behavior.
- GraphQL exposure of the rewrite pathway.

## Risks

- `NSTextView` representable must preserve existing editor behavior
  (font, background, min height, live binding) — regression risk to
  manual editing; covered by keeping `RielaNoteBodyDraftState`
  semantics and UI tests on the splice/scope helpers.
- Selection ranges are `NSRange` (UTF-16) while drafts are Swift
  `String` — the splice helper must convert via `Range(_:in:)` and
  reject invalid ranges (fall back to whole-note scope).
- Workflow latency: rewrites block only the pill (loading spinner);
  the editor stays usable; superseded results are dropped by the
  generation guard.

## Test Plan

- `Tests/RielaNoteUITests`:
  - view-model rewrite: success applies loading→loaded transitions and
    returns the draft; failure sets `editRewriteError`; stale
    generation / note-switch results are dropped; not-configured error
    surfaces.
  - client: stub provider round-trip incl. selection fields;
    provider-less client throws `.notConfigured`.
  - pure helpers: `rielaNoteApplyingRewrite` (valid range, invalid
    range → nil, UTF-16 boundary cases, emoji), export filename
    derivation, copy-source selection (draft vs persisted).
  - workflow provider: argument construction and JSONL parsing
    (internal visibility, mirroring link-provider coverage).
- Workflow bundle: `riela workflow validate note-edit-rewrite
  --workflow-definition-dir examples` and a mock-scenario dry run;
  `EXPECTED_RESULTS.md` records the deterministic output.
- Manual verification: build RielaApp, open Notes window, confirm
  header layout, edit flow, pill submit against the mock workflow,
  selection chip + ⌘K, copy/download/expand.
