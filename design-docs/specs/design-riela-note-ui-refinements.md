# Riela Note UI Refinements

## Summary

A follow-up UX pass over the shipped Riela Note UI
(`Sources/RielaNoteUI`, hosted by `Sources/RielaApp`). It reworks
navigation (settings entry, three-column library layout), note creation
(title-less, screen-based, floating quick-create), note reading
(newline-preserving block markdown, body-first detail layout), and note
linking (search-popup manual linking with preview, AI-assisted link
extraction). It also answers and closes the file-attachment test
coverage question.

Requirements source: user request 2026-07-06 (Japanese memo, restated
below). Parent design: `design-docs/specs/design-riela-note.md`;
known-issue register: `design-riela-note-review-improvements.md`
(items B2, B3, B12, B13 intersect this work).

## Requirements (restated)

1. **R1 — Settings entry**: reach "riela note config" (the Notes
   Settings window) from inside the Notes UI, not from the status-bar
   menu.
2. **R2 — Title-less creation**: new-note capture has no title field;
   the first markdown `#` header — or, failing that, the first line —
   becomes the title.
3. **R3 — Creation screen**: new note is composed on a dedicated
   screen, not in a popup/sheet.
4. **R4 — Newlines**: the note view must preserve body line breaks.
   Collapsing newlines is correct only for note-list previews.
5. **R5 — Linking**: an AI-driven "extract links" button plus a manual
   "Add link" popup with full-note-text search and per-candidate note
   preview.
6. **R6 — Body prominence**: the note body must be the visually
   dominant element of the note view.
7. **R7 — Layout**: notebook list moves to the right pane; the left
   menu holds list filter conditions — created-at, sort order, tags,
   search, and "also associated to" (include notes linked to/from
   matches).
8. **R8 — Quick create**: a floating new-note button pinned bottom-right
   with hover affordance; creation must feel speedy.
9. **R9 — File attach tests**: confirm whether file attachment is
   test-covered; close gaps.

## Code-Verified Current State

- **Settings entry is menu-only.** The status-bar menu has
  "Notes..." and "Note Settings..." items
  (`Sources/RielaApp/EntryPoint+Menu.swift:19-20`);
  `openNoteSettings()` (`EntryPoint+Notes.swift:38-63`) opens the
  AppKit `NoteSettingsWindowController`
  (`NoteSettingsWindowController.swift:91-154`). The Notes window
  itself (`NoteWindowController.swift:30`, hosting
  `RielaNoteRootView`) has no path to settings. The "Config" tab inside
  the Notes window is the config *agent*
  (`RielaNoteUI/RielaNoteRootView.swift:58-62`), not settings.
- **Creation is a sheet with a title field.** Toolbar actions "New
  memo" (Cmd-N) and "New note" (Cmd-Shift-N)
  (`RielaNoteNotebookListView.swift:61-79`) present
  `RielaNoteCreationSheet` (`RielaNoteNotebookListView.swift:296-332`)
  with a `TextField("Title", ...)` and a `TextEditor`. Saving routes
  through `rielaNoteDraftMarkdown(title:fallbackTitle:body:)`
  (`RielaNoteNotebookListView.swift:979-986`), which force-prefixes a
  `# <title>` heading, then calls
  `createUserMemo` / `createNoteInSelectedNotebook`
  (`RielaNoteLibraryViewModel.swift:408-443`).
- **Title is already body-derived in the store.** `notes.title` is a
  nullable column (`RielaNote/NoteStoreSchema.swift:320`);
  `noteTitle(from:)` (`RielaNote/NoteService+Rows.swift:159-165`)
  extracts the first `# ` heading; `createNote` falls back to it when
  no explicit title is given (`NoteService.swift:120`) and
  `updateNoteBody` re-derives it (`NoteService.swift:424`). There is
  **no first-line fallback** today — a body with no `#` heading yields
  a nil title.
- **Newline loss is in the detail renderer.** `RielaNoteMarkdownText`
  (`RielaNoteUI/RielaNoteComponents.swift:64-76`) renders the whole
  body via `try? AttributedString(markdown:)` with default options:
  full-syntax inline interpretation collapses single newlines to soft
  breaks and flattens paragraphs into one inline run, so the rendered
  note view loses line breaks (review item B13 records the same
  renderer dropping headings/lists/code blocks). List previews collapse
  newlines separately — and correctly, per R4 — on the backend:
  `notebookPreviewText` (`RielaNote/NoteService+NotebookStats.swift:89-91`)
  and search `snippet` (`RielaNote/NoteSearch.swift:351-361`) replace
  `\n` with spaces.
- **Detail layout buries the body.** `RielaNoteDetailView` renders the
  body inside a section stack alongside always-expanded tags, links,
  comments, and files sections (`RielaNoteDetailView.swift:127-148`,
  264-335); the body has no visual priority.
- **Linking is inline and manual-only.** The links section embeds a
  target-id `TextField`, a suggestions `Menu`, and a link-kind
  `TextField` (`RielaNoteDetailView.swift:287-328`), backed by
  `linkSelectedNote(to:kind:)` and an isolated cross-notebook search
  (`rielaNoteLinkTargetSuggestions`,
  `RielaNoteDetailView.swift:521-545`). There is no candidate preview
  and no automatic extraction. The store side is ready: directional
  `note_links` with `link_kind` + `provenance`
  (`RielaNote/NoteStoreSchema.swift:415-423`), `linkNotes()` enforcing
  that AI provenance cannot overwrite human/system links
  (`RielaNote/NoteService+Relations.swift:6-47`), `listLinks()`
  returning links in both directions
  (`NoteService+Relations.swift:49-62`), and a `linkNotes` GraphQL
  mutation (`RielaGraphQL/GraphQLNoteSchemaContract.swift`).
- **Library layout is two-column.** Regular width uses a
  `NavigationSplitView` — sidebar = notebook list, detail = note view
  (`RielaNoteRootView.swift:96-102`). Filters (search field, tag/class
  chips) live inside the notebook-list column
  (`RielaNoteNotebookListView.swift:26-35`, 192-238). There is no sort
  control, no created-at filter, and no linked-note search expansion;
  `NoteService.listNotebooks` supports only pagination + tag filter
  with fixed created-desc order (`RielaNote/NoteService.swift:292-330`),
  and `searchNotes` supports query/tag/class/pagination only
  (`NoteService.swift:594-611`, `NoteSearch.swift:11-100`).
- **No floating create button.** All creation entry points are toolbar
  items (`RielaNoteNotebookListView.swift:40-80`).
- **AI-execution precedent exists in RielaApp.** The app assistant
  builds an `AdapterExecutionInput` and executes it through
  vendor-selected adapters (`EntryPoint+Assistant.swift:31-84`,
  112-129); packaged note workflows (`note-auto-tagging` seeded as an
  auto-action, `note-agent`, `note-config-agent`) plus builtin add-ons
  `riela/note-search`, `riela/note-get`
  (`RielaCLI/ProductionNodeAdapter+NoteAddons.swift:9-20`) are the
  precedent for an AI link-extraction action. No link-extraction addon
  or workflow exists yet.
- **File attachments are test-covered (R9 answer: yes, with gaps).**
  `Tests/RielaNoteTests/NoteFileStoreTests.swift` covers attach /
  resolve / list for notes (`:7-28`) and notebooks (`:30-49`),
  missing-note rejection without blob writes (`:51-65`), file survival
  after note deletion (`:83-93`), checksum mismatch detection
  (`:95-121`), local→S3 migration without double transfer (`:153-190`),
  and bulk-migration failure continuation (`:208-222`). Gaps: no
  direct-attach-to-S3 test (only migration), no attachment
  `position` / ordering edge cases, no GraphQL `attachFile` mutation
  round-trip.

## Design Decisions

- **D1 — Settings opens from the Notes window; the menu item moves
  under it.** `RielaNoteRootView` gains a toolbar settings action
  (gear icon) on the Library tab. `RielaNoteUI` must stay AppKit-free
  (parent D15), so the root view takes an optional
  `onOpenSettings: (() -> Void)?` callback;
  `NoteWindowController` injects a closure that invokes the existing
  `openNoteSettings()` path. The status-bar "Note Settings..." item is
  removed; "Notes..." remains the single entry point. On platforms
  where the callback is nil (future iOS), the button is hidden.
- **D2 — Title derivation gains a first-line fallback, and the UI stops
  asking for a title.** `noteTitle(from:)` becomes: first `#` heading
  (any level `#`–`######`, trimmed) → else first non-empty line
  (markdown markers stripped, capped at 120 chars) → else nil. This is
  the single derivation point used by create
  (`NoteService.swift:120`), update (`NoteService.swift:424`), add-ons,
  and GraphQL, so all writers converge. The creation UI drops its
  title field and `rielaNoteDraftMarkdown` heading injection: the body
  is stored verbatim. Existing notes are untouched (titles re-derive on
  next body update). The addon-side fallback title logic
  (`ProductionNodeAdapter+NoteAddons.swift:814-829`) is aligned with
  the same rule.
- **D3 — Composition is a screen, not a sheet.** A new
  `RielaNoteComposeView` (full-height `TextEditor`, live derived-title
  caption, destination caption "New memo" / "New note in <notebook>",
  Save / Cancel, Cmd-Return to save) replaces `RielaNoteCreationSheet`.
  Compact width pushes a `.compose(destination)` case on the existing
  `RielaNoteLibraryRoute` path; regular width presents the composer in
  the detail column. Save calls the existing
  `createUserMemo` / `createNoteInSelectedNotebook` view-model paths,
  then selects the created note.
- **D4 — Detail rendering becomes block-level and newline-preserving;
  list previews keep collapsing.** `RielaNoteMarkdownText` is replaced
  in the detail view by `RielaNoteMarkdownBodyView`: split the body
  into blocks (headings, paragraphs, fenced code, lists, blockquotes,
  thematic breaks) rendered as a `LazyVStack` of styled `Text` views;
  paragraph text is parsed per-block with
  `AttributedString(markdown:options:)` using
  `.inlineOnlyPreservingWhitespace` so intra-paragraph line breaks
  survive. Code blocks render monospaced and un-parsed. This closes R4
  and most of review item B13 (embedded-image resolution stays a
  follow-up). Backend preview collapsing
  (`notebookPreviewText`, search `snippet`) is intentionally unchanged.
- **D5 — Body-first detail layout.** The detail view reorders to:
  title header (derived title + read-only lock) → body at full width,
  `.body`-plus type size with comfortable line spacing → a metadata
  area demoted below the body as collapsible sections (Tags, Links,
  Comments, Files), collapsed by default except when non-empty counts
  are small; section headers show counts so collapsed state stays
  informative. Editing controls stay in the header. No information is
  removed — only visual priority changes.
- **D6 — Manual linking moves to a search popup with preview.** The
  inline link composer is replaced by an "Add link" button opening a
  sheet: search field wired to the existing full-text
  `searchNotes(query:...)` client API, result list (title + collapsed
  snippet), and a preview pane rendering the selected candidate's body
  with `RielaNoteMarkdownBodyView` (fetched via `noteDetail(noteId:)`).
  Confirming creates the link with `provenance: .human` and link kind
  `related` (kind remains editable in an advanced disclosure). The
  popup excludes the current note and already-linked targets, reusing
  the `rielaNoteLinkTargetSuggestions` filtering rules.
- **D7 — AI link extraction is a propose-then-confirm action.** The
  links section gains an "Extract links (AI)" button. Flow: the UI
  client's new `proposeNoteLinks(noteId:)` runs a packaged
  `note-link-extract` workflow — `riela/note-get` (subject body) →
  `riela/note-search` over salient terms → an agent-worker step that
  selects genuinely related candidate notes and returns
  `{targetNoteId, linkKind, reason}` proposals. Proposals appear in a
  confirmation list (title, reason, preview access); accepted items are
  created via `linkNotes(..., provenance: .ai)`, so store-side
  provenance rules (AI never overwrites human/system links) apply
  unchanged. Propose-then-confirm follows the config-agent proposal
  precedent and keeps AI writes reviewable. A service-level
  deterministic fallback (FTS term-overlap candidates, clearly labeled)
  is used when no agent adapter is configured, mirroring how the note
  agent degrades today.
- **D8 — Library becomes three columns: filters | notebook list |
  detail.** Regular width uses
  `NavigationSplitView(sidebar:content:detail:)` — sidebar: a new
  `RielaNoteFilterPane` (search field; sort picker: created desc /
  created asc / updated desc / title; created-at range presets (any,
  today, 7 days, 30 days, custom range); tag & tag-class chips; an
  "include linked notes" toggle for R7's "also associated to"); content:
  the notebook/note list (this is R7's "right pane" relative to the
  filter menu); detail: note view / composer. Compact width keeps the
  list as root, with the filter pane reachable via a toolbar filter
  button (sheet). Filter state lives in `RielaNoteLibraryViewModel`
  as a single `RielaNoteListFilter` value.
- **D9 — Backend list/search options grow to match D8.**
  `NoteService.listNotebooks` and `searchNotes` (service → UI-client
  protocol → GraphQL contract) gain: `sort` (createdAtDesc default,
  createdAtAsc, updatedAtDesc, title), `createdAfter`/`createdBefore`,
  and — for search — `includeLinked: Bool`. `includeLinked` expands the
  matched note-id set one hop through `note_links` in both directions
  (single SQL join against the FTS hit set, deduplicated, linked hits
  ranked after direct hits and badged "linked" in results). One hop
  only; no transitive closure in v1.
- **D10 — Quick create is a floating hover button.** The library
  content column overlays a bottom-trailing circular "+" button
  (`safeAreaInset`/`overlay(alignment: .bottomTrailing)`). On hover it
  expands to labeled actions ("New memo", "New note in notebook" —
  the latter shown only when a notebook is selected); click (or Cmd-N)
  goes straight to the D3 compose screen with the editor focused, so
  capture is: click → type → Cmd-Return. Hover behavior degrades to
  long-press context menu on touch platforms. Toolbar items and
  keyboard shortcuts remain.
- **D11 — Attachment test gaps get closed, not just answered.** Add
  tests for direct S3 attach (attach with an S3-backed store profile,
  no migration), attachment `position` ordering across multiple files
  of one role, and a GraphQL `attachFile` → `noteFile` round-trip.

## Non-Goals / Boundaries

- No iPhone/iPad app work; `RielaNoteUI` stays iOS-compilable and
  AppKit-free (parent D15). Hover affordances must degrade.
- No embedded-image markdown rendering (`![...](file-id)`) — tracked
  separately by review item B13's remainder.
- No note-agent/streaming rework (review item B7) — the link-extract
  workflow reuses existing execution seams as they are today.
- No transitive "associated to" expansion beyond one link hop.
- No settings-window SwiftUI port; D1 only re-homes the entry point.
- No migration/backfill of stored titles for existing notes.

## Acceptance Traceability

| Requirement | Design owner |
| --- | --- |
| R1 settings from inside Notes UI | D1 |
| R2 title from `#` header or first line, no title field | D2 |
| R3 creation on a dedicated screen | D3 |
| R4 note view preserves newlines; list previews collapse | D4 |
| R5 AI link extraction + manual add-link popup with search & preview | D6, D7 |
| R6 body prominence in note view | D4, D5 |
| R7 notebook list right, filter menu left (created-at, sort, tag, search, associated-to) | D8, D9 |
| R8 bottom-right hover create button, speedy capture | D3, D10 |
| R9 file-attach test coverage | Current State (answer: covered with gaps), D11 |

## Verification

- `swift build` / `swift test` (RielaNoteTests, RielaNoteUI tests,
  RielaCLITests note workflow tests).
- Title derivation unit tests: `#`-heading, deep heading, no-heading
  first-line fallback, marker stripping, 120-char cap, empty body.
- Renderer unit tests: paragraph newline preservation, heading/list/
  code-block splitting; snapshot-free (assert block model, not pixels).
- Search expansion tests: `includeLinked` returns one-hop neighbors in
  both directions, deduplicated, direct hits ranked first.
- Sort/date-filter tests at service and GraphQL layers.
- Link-extract workflow test with mock agent scenario: proposals
  produced, `.ai` provenance stored, human link not overwritten.
- Manual pass on macOS: menu no longer shows "Note Settings...", gear
  opens settings; compose screen flow; hover FAB; three-column layout;
  newline rendering of a multi-paragraph OCR note.

Implementation plan: `impl-plans/active/riela-note-ui-refinements.md`.

## Post-Implementation Review (2026-07-06)

The uncommitted implementation was reviewed against D1–D11 across three
dimensions (RielaNote backend, RielaNoteUI/RielaApp, GraphQL/workflow
parity). `swift build` passes; all note-related tests pass (176 across
RielaNoteTests / RielaNoteUITests / NoteGraphQLTests);
`riela workflow validate note-link-extract` passes.

**Verdict**: R1–R9 are all functionally landed and the core decisions
(shared `NoteTitleDerivation`, block renderer with
`.inlineOnlyPreservingWhitespace`, three-column split view, parameter-
bound SQL for the new sort/date/linked options, propose-then-confirm AI
links with `.ai` provenance, direct-S3/position/GraphQL attach tests)
check out. The findings below are required follow-ups before this
ships; they are tracked as TASK-012–TASK-018 in the impl plan.

### Critical

- **F-C1 — Published SDL contains two `type Query` definitions.**
  `graphQLNoteSchemaContract` now embeds its own `type Query` block
  (`GraphQLNoteSchemaContract.swift:87-97`), and it is interpolated
  into `GraphQLContractProjector.schemaContract`
  (`GraphQLContracts.swift:665`) which already defines `type Query`
  (`GraphQLContracts.swift:800`). Verified via
  `riela graphql schema`: the emitted SDL contains both, and they
  disagree (the note-side block omits `workflowSession`,
  `workflowSessions`, `loopEvidence`, `managerSession`). Duplicate
  type names are invalid SDL — `buildSchema`/codegen consumers reject
  the whole document. This is the review-improvements §1.5 failure
  class recurring; the existing substring-based schema tests cannot
  catch it. **Fix**: keep note query fields only in the single merged
  `type Query`; add a regression test asserting the published contract
  contains exactly one `type Query` (and one `type Mutation`).

### Major

- **F-M1 — `Process` in RielaNoteUI breaks iOS portability (D15).**
  `RielaNoteWorkflowLinkProposalProvider.swift:98` uses `Process`
  unconditionally; the package declares `.iOS(.v17)` and the parent
  design requires RielaNoteUI to compile for iOS. **Fix**: move the
  subprocess-backed provider into RielaApp (only
  `NoteWindowController` constructs it), leaving the protocol + draft
  types in RielaNoteUI, or gate the implementation with
  `#if os(macOS)`.
- **F-M2 — Provider pipe deadlock, no timeout, no cancellation.**
  stdout/stderr are read only after `waitUntilExit()`
  (`RielaNoteWorkflowLinkProposalProvider.swift:121-131`); a JSONL
  workflow run larger than the ~64KB pipe buffer blocks the child and
  hangs the detached task forever (proposal sheet spinner never
  resolves). Task cancellation does not terminate the process.
  **Fix**: drain both pipes concurrently before/while waiting, enforce
  an overall deadline that `terminate()`s the process, and hook
  `withTaskCancellationHandler`.
- **F-M3 — The packaged workflow never gives the agent the subject
  note.** Step inputs only merge messages addressed to the step;
  `select-link-proposals` receives only `riela/note-search` output
  (`results/resultCount/noteIds`) while its prompt says "Review the
  subject note from `get-subject-note`" and "Exclude the subject
  note" — impossible with the current transitions
  (`examples/note-link-extract/workflow.json`). D7 requires selection
  against the subject body. **Fix**: fan-in
  `get-subject-note → select-link-proposals`, or inject
  `{{workflowInput.noteId}}` and the subject body into the prompt.
- **F-M4 — `mock-scenario.json` is in the wrong format and silently
  useless.** The scenario loader expects `{nodeId: MockNodeResponse}`
  (cf. `examples/note-auto-tagging/mock-scenario.json`); this file's
  `{"input":..., "expected":...}` keys match no node, so the
  codex-agent nodes are never mocked and no deterministic run exists.
  `EXPECTED_RESULTS.md` has no runnable commands/assertions, unlike
  siblings. **Fix**: key mocks on `select-link-proposals` /
  `workflow-output`, document the `--variables` invocation, and make
  `EXPECTED_RESULTS.md` executable like `note-auto-tagging`'s.
- **F-M5 — Link-proposal race can attach note A's proposals to note
  B.** `proposeLinksForSelectedNote()`
  (`RielaNoteLibraryViewModel.swift:920-934`) has no note-id or
  generation guard; a slow workflow started on note A can populate
  `linkProposals` after navigation to note B, and accepting then
  creates B→(A's targets) links silently under `.ai` provenance.
  Overlapping runs also fight over `isLinkProposalLoading`. **Fix**:
  capture the note id at start and guard it (or reuse the existing
  selection-generation token) before assigning proposals and inside
  accept.
- **F-M6 — Workflow-path proposal handling is fragile and unlabeled.**
  In `proposeNoteLinks` (`RielaNoteUIClient.swift:383-390`): one
  unresolvable `targetNoteId` (agent hallucination / prompt injection
  via untrusted note bodies) throws inside `try?` and discards *all*
  workflow proposals; every provider error silently degrades to the
  deterministic fallback; an empty-but-successful agent result also
  falls through to fallback (mislabeling "AI found nothing"); and the
  sheet never renders `proposal.source`, so D7's "clearly labeled"
  fallback and "preview access" are unmet. **Fix**: resolve drafts
  per-item (`continue` on failure), fall back only when no provider is
  configured, surface provider errors in the sheet, show a
  workflow/deterministic badge, add candidate preview, and allowlist
  `linkKind` values (`related`/`source-citation`) on accept.
- **F-M7 — Link search sheet has stale-async state bugs.**
  `RielaNoteLinkSearchSheet.swift:120-144, 84-92`: per-keystroke
  unstructured `Task`s without cancellation (last-finished response
  wins), `onSubmit` + `onChange` double-fire, each response
  force-selects the first result (stomping manual selection and
  re-fetching previews), and the preview fetch has no
  "still selected?" guard after `await` (wrong preview possible;
  `try?` swallows errors). **Fix**: single cancel-and-replace search
  task, post-`await` currency guards, auto-select only when nothing is
  selected.
- **F-M8 — Title derivation reads inside code fences.**
  `NoteTitleDerivation.swift:7-11` scans every line for headings with
  no fence awareness, so a body like
  ```` intro\n```bash\n# install deps\n``` ```` derives the title
  "install deps" — and `updateNoteBody` re-derives on every save, so
  real notes with code snippets get their titles rewritten. The
  trimmed scan also matches indented code lines the old code ignored.
  **Fix**: skip lines inside ``` ```/~~~ ``` fences in both the heading
  scan and the first-line fallback; allow ≤3 leading spaces per
  CommonMark.
- **F-M9 — Post-create leaves the new note invisible when a
  created-range filter is active.** `createUserMemo` /
  `createNoteInSelectedNotebook`
  (`RielaNoteLibraryViewModel.swift:410-468`) clear text/tag/class
  filters but not `filter.createdRange`; `hasSearchFilters` stays
  true, the list keeps rendering the emptied `searchResults` with a
  "No Results" overlay, and the selected new note is not visible —
  breaking D3's post-create promise. **Fix**: reset the whole filter
  (preserving sort) on create, mirroring `clearSearchFilters`.

### Minor (condensed)

- *Title derivation*: ATX closing hashes not stripped
  (`# Title ##` → "Title ##"); the first-line fallback's blanket
  trailing/leading `CharacterSet` trim mangles `**Bold**`,
  `[Link](url)`, and turns a fence info line into the title "swift"
  (`NoteTitleDerivation.swift:32,56`).
- *Search semantics to decide and document* (currently implicit):
  FTS-path `sort` is only a rank tiebreaker while non-FTS paths sort
  primarily (`NoteSearch.swift:85`) — the UI sort picker barely
  affects FTS results; linked neighbors bypass tag/class/date filters
  and are ordered by `note_id` not the requested sort; the neighbor
  SQL `LIMIT` is consumed by rows that are already direct hits, so
  neighbor pages can undercount (`NoteSearch.swift:302-350`);
  `createdAfter`/`createdBefore` compare lexicographically, so
  date-only values like `2026-07-06` exclude that whole day.
  Recommendation: keep rank-first FTS but document it in the SDL arg
  docs; apply created-at predicates and the requested sort to
  neighbors; exclude direct hits inside the neighbor SQL; normalize
  date-only bounds to start/end-of-day.
- *Intentional behavior worth documenting*: `updateNoteBody` now
  overwrites explicitly-set titles whenever the new body derives any
  title (`NoteService.swift:438`) — CLI/addon callers that set
  `title:` lose it on the next body edit; matches D2 but must be
  stated in CLI/GraphQL docs.
- *GraphQL surface*: `sort` accepted values are undiscoverable
  (publish a `NoteListSort` enum in SDL with the camelCase raw
  values); no execution-level GraphQL tests for the new args /
  `proposeNoteLinks` (substring tests are what let F-C1 through);
  `riela/note-search` addon still lacks sort/date/includeLinked args
  (workflows must use `note-graphql-document`).
- *UI polish*: `includeLinked` missing from `hasSearchFilters` (the
  toggle no-ops without a query and hides "Clear filters"); FAB is an
  `overlay` that covers the "Load more" row (use `safeAreaInset`,
  design D10 said so) and lacks hover animation/accessibility label;
  sidebar filter field + list `onChange` double-fire searches per
  keystroke; created-at custom TextFields reload per keystroke with
  unvalidated partial dates (use `DatePicker`/validation); closing
  code fence incorrectly accepted with an info string
  (`RielaNoteMarkdownBodyView.swift:93`); blockquote/list markers
  render literally inside styled blocks; comments still render through
  the newline-collapsing `RielaNoteMarkdownText`
  (`RielaNoteDetailView.swift:375`); `isLinksExpanded` is a static
  default instead of D5's count-based collapse; compose Save has no
  in-flight guard (double Cmd-Return → two notes); regular-width note
  selection doesn't dismiss an open composer; link/proposal sheet
  errors surface to the library overlay behind the sheet, and the
  "No Results" overlay flashes during `.loading`; hard-coded sheet
  frames (760×520) won't fit compact widths; provider hardcodes
  `limit: 8` and falls back to `/usr/bin/env riela` (fails under GUI
  PATH); dead code: old inline link-composer plumbing
  (`linkTargetSearchNotes`, `updateLinkTargetSearchText`,
  `rielaNoteLinkTargetSuggestions`) and vestigial `title:` parameters
  on the create APIs survive with only test callers.
- *Missing tests promised by Verification*: no unit tests for the
  markdown block parser, compose derivation caption, filter-driven
  reload mapping, or quick-create button.

### Security posture (link extraction)

Note bodies are untrusted input to the agent prompt by design.
Mitigations in place: propose-then-confirm (D7), `.ai` provenance with
store-side human-link protection, target ids resolved against the
store, self/duplicate exclusion, alphanumeric-tokenized FTS terms.
Residual (folded into F-M6): a prompt-injected note can currently
disable the whole workflow path silently (one bad id) and `linkKind`
is an arbitrary agent-controlled string persisted on accept — clamp to
an allowlist; `reason` is attacker-influenceable display text (plain
`Text`, display-safe; social-engineering vector only).

Follow-up tasks: TASK-012–TASK-018 in
`impl-plans/active/riela-note-ui-refinements.md`.

## Workspace Hardening Addendum (2026-07-19)

Issue source: workflow intake
`codex-design-and-implement-review-loop-session-1171` / `comm-000847`.
Scope is one work package on branch `feat/riela-note-workspace-revamp`
covering only `Sources/RielaNoteUI` and `Tests/RielaNoteUITests`
unless a compile fix requires a direct RielaApp host update.

### Requirements

1. Return pressed inside note text inputs must never trigger the agent
   send action. The agent composer remains the only plain-Enter send
   owner through its own submit handling; the compose screen's
   Cmd-Return save shortcut remains separate.
2. Selecting a search-popup result while a body edit has unsaved changes
   must always expose the existing discard confirmation. Discard
   selects the picked note; keep-editing preserves the draft.
3. The file tree must reflect note-store changes and explicit refreshes,
   and notebooks with more than one note page must expose a load-more
   path instead of stopping at the first fixed-size fetch.
4. The left pane must offer Tree and Notes modes. Notes mode lists notes
   for the selected notebook in the same order as the detail pager,
   highlights the current note, shows current position, and selects rows
   through the same pending-selection edit guard used elsewhere.
5. Left pane expansion, right pane expansion, selected left-pane tab,
   and the note-agent folded state must survive app relaunch.
6. Custom note-workspace panels must render correctly in dark and light
   appearance by using semantic colors instead of hard-coded theme
   assumptions.

### Design Decisions

- **D12 - Plain Return ownership stays local to the composer.** Agent
  send buttons in `RielaNoteAgentBottomBar` and `RielaNoteAgentView`
  must not register a global bare-Return shortcut. Text inputs such as
  the note body editor, comment editor, tag field, rewrite pill, and
  link/search fields keep their local Return behavior. The composer
  send affordance is still available through its focused submit path.
- **D13 - Pending selection remains root-owned.** Search-popup result
  selection may set `RielaNoteLibraryViewModel.pendingSelection`, but
  the popup must then yield presentation control so the root
  confirmation dialog can appear. The binding that hides the dialog
  must not clear `pendingSelection`; only explicit Discard or Keep
  Editing resolves it.
- **D14 - File-tree loading is an invalidatable paged model.** The file
  tree treats `notesByNotebook` as a page cache with explicit freshness
  state, not as permanent data. `viewModel.refresh()` and
  `RielaNoteStoreChangeWatcher` note-store changes invalidate affected
  notebook pages. Loading merges pages by note id, preserves service
  ordering, and exposes whether another page is available.
- **D15 - Pager order is a shared data source.** The detail pager and
  the left-pane Notes tab consume one ordered-note snapshot from
  `RielaNoteLibraryViewModel`. Previous/next navigation, row order,
  current index, and position text are derived from that snapshot so the
  two surfaces cannot diverge.
- **D16 - Left-pane mode is workspace chrome.** Tree/Notes selection
  belongs to the root workspace layout, not to notebook data. Compact
  navigation keeps the existing `NavigationStack` behavior; macOS
  split-view behavior remains behind `#if os(macOS)`.
- **D17 - Workspace chrome persistence is view state, not model data.**
  Pane expansion, selected left-pane tab, and agent folded state may use
  `AppStorage` or equivalent scene-persistent storage. Keys must be
  scoped to Riela Note workspace UI state and must not affect note-store
  content or tests that instantiate view models directly.
- **D18 - Color semantics follow platform appearance.** Agent bottom
  bar panels, attachment chips, pane backgrounds, and similar custom
  surfaces use semantic SwiftUI/system colors for background, border,
  selection, disabled, and secondary text roles. Hard-coded opacity
  overlays are acceptable only when they remain legible in both light
  and dark appearances.

### Data Flow And Validation

- `RielaNoteRootView` owns workspace chrome state, presents the
  Tree/Notes switcher, hosts pending-selection confirmation, and
  connects search-popup dismissal to pending-selection creation.
- `RielaNoteLibraryViewModel` owns note ordering for pager and Notes tab
  consumers. A testable ordered snapshot exposes ordered notes,
  current index, total count, previous note, and next note.
- `RielaNoteFileTreePane` delegates page merge/invalidation rules to a
  testable helper or view-model type. Validation covers first page,
  load-more page, duplicate note id merge, reset after refresh, and
  reset after note-store change notification.
- Notes-tab row selection must call the existing guarded selection path
  so unsaved body edits produce the same confirmation as tree/list
  selection. Direct mutation of selected note id from a row is out of
  bounds.
- Verification commands for this work package are:
  `swift build`,
  `swift test --filter RielaNoteUITests`, and
  `swift test --filter RielaAppNotesIntegrationTests`.

### Rollout Constraints

- No fanout: all six behavior changes land as one branch-local commit
  with focused tests and review notes.
- Do not touch translate-related code, web dashboard code, or daemon
  workflow code.
- Keep `RielaNoteUI` iOS-compilable and keep RielaApp
  `NoteWindowController` compiling.
- Known unrelated local failure
  `DaemonWorkflowNodePatchTests/testRuntimeRestartsWorkflowWhenEventSourceExits`
  must not be fixed or attributed to this work.

### Manual GUI Checks

Manual verification must record exact steps for: Return routing in body
editor/comment/tag/rewrite inputs versus composer submit; search-popup
pending-selection discard and keep-editing paths; relaunch persistence
for left/right panes, Tree/Notes mode, and agent fold; and dark/light
appearance checks for the custom workspace panels.

## Book-Like Reader Addendum (2026-07-20)

Issue source: workflow intake
`codex-design-and-implement-review-loop-session-1174` / `comm-000891`,
continued by Fable handoff `fable-and-improve-session-1175` /
`comm-000901` and child intake
`codex-design-and-implement-review-loop-session-1176` / `comm-000903`, then
resumed without reopening design by
`codex-design-and-implement-review-loop-session-1178` / `comm-000914`.
Scope is one work package on branch `feat/riela-note-workspace-revamp`
starting from committed baseline `79c1cb9` and covering the note workspace
reader in `Sources/RielaNoteUI`, minimal `Sources/RielaNote` comment/paging
support only if the UI client cannot already perform the write, and tests in
`Tests/RielaNoteUITests` and `Tests/RielaNoteTests`.

### Requirements

1. Opening a notebook's notes presents a book-like reader: one note per
   full-container page, vertically sliding with page snapping, and able
   to advance through consecutive notes without relying on button-only
   previous/next navigation.
2. Reader selection remains model-owned. The visible page is bound to
   the selected note id, and `RielaNoteLibraryViewModel` remains the
   source of truth for selected detail, pager order, keyboard
   navigation, and left-pane Notes row selection.
3. Reading is primary. Reader pages render body content in read mode by
   default with `RielaNoteMarkdownBodyView`; editable text controls are
   entered only through the existing explicit `isEditingBody` action.
4. Each reader page keeps current-note agent and comment actions one
   visible tap away. Agent requests route through the existing
   `RielaNoteAgentBottomBar` / agent view-model path; comments route
   through the existing note comment client/service path.
5. Notes load lazily in a bounded page window. Approaching the loaded
   window edge triggers the next page fetch only when guarded by
   loading and `hasMore` state; no code path may prefetch the whole
   notebook or loop until `hasMore` is false.
6. Verification must include `swift build`,
   `swift test --filter RielaNoteUITests`, and
   `swift test --filter RielaNoteTests`, each with nonzero executed test
   counts, plus focused pager/windowing tests and a reader-path search for
   eager loading patterns:
   `rg -n "while .*hasMore|hasMore.*while|loadAll|prefetch" Sources/RielaNoteUI`.

### Design Decisions

- **D19 - The detail body becomes a vertical snap pager.**
  `RielaNoteDetailView` replaces its single-note primary `ScrollView`
  with a vertically scrolling, lazy page container over the shared
  `RielaNotePagerNoteSnapshot`. Each page uses the full reader
  container height and an id equal to its `noteId`. On the supported
  platforms declared by `Package.swift` (`macOS 14`, `iOS 17`), the
  preferred implementation is SwiftUI scroll-position paging
  (`scrollPosition` / `scrollTargetBehavior(.paging)` with
  `containerRelativeFrame` or the closest equivalent that preserves the
  same contract). The old previous/next buttons and Cmd-left/Cmd-right
  shortcuts remain secondary controls over the same selection model.
- **D20 - Page identity and selection are one-way guarded.** The pager
  publishes visible-page changes as note-id selection requests through
  the existing guarded selection path. Programmatic selection changes
  scroll the pager to the selected note id. Both directions must guard
  against no-op repeats and stale async selection so scroll-position
  updates do not create a selection loop or resurrect an older note.
- **D21 - Read mode owns the default page surface.** A reader page uses
  `RielaNoteMarkdownBodyView` unless the selected note is explicitly in
  `bodyDraft.isEditingBody`. The editor is mounted only for the current
  selected note and only after the edit affordance is activated.
  Swiping/page scrolling, previous/next buttons, and keyboard pager
  shortcuts are disabled while editing so unsaved draft handling remains
  root-owned and explicit.
- **D22 - Current-note actions stay page-local and persistent.** The
  reader surface exposes an agent action and a comment action for the
  currently visible note without opening another navigation layer first.
  The agent action focuses/expands the existing `RielaNoteAgentBottomBar`
  with the current note as context rather than introducing a second
  agent execution path. The comment action opens a compact current-note
  comment composer and persists through `RielaNoteUIClient.addComment`;
  `NoteService.addComment(noteId:bodyMarkdown:author:)` already exists,
  so service changes are out of scope unless compile-time wiring proves
  a missing bridge.
- **D23 - Windowed note loading is explicit state, not a loop.**
  `RielaNoteFileTreeNotebookNotesPageState` (or a sibling window state
  used by `RielaNoteLibraryViewModel`) owns loaded notes, next offset,
  `hasMore`, `didLoad`, and `isLoading`. It gains a testable threshold
  rule such as "within N pages of the loaded trailing edge" that returns
  whether to request another page. Fetching may request only one next
  page per trigger, uses the existing `limit + 1` sentinel pattern, and
  refuses to fire while loading or when `hasMore` is false.
- **D24 - Backward paging is deferred unless the selection can open
  before the accumulated window.** The current branch's groundwork is
  forward-offset paging. Previous navigation is covered by notes already
  accumulated in the loaded window. If implementation discovers a
  supported mid-notebook entry that can start without prior pages, the
  window state may grow a backward fetch boundary; otherwise the design
  documents forward-accumulated previous pages as the v1 behavior.
- **D25 - Pager tests target state and wiring, not pixels.** Unit tests
  cover threshold firing near the edge and not before it, no refetch
  while loading, no fetch after `hasMore` is false, selected-position
  tracking as selection changes, and view-model wiring for one-tap
  agent/comment affordances. View-first behavior is asserted through
  state defaults (`isEditingBody == false`, no editor-focused default)
  rather than screenshot snapshots.

### Data Flow And Validation

- `RielaNoteLibraryViewModel.pagerNoteSnapshot` remains the shared
  ordering source for `RielaNoteDetailView`, `RielaNoteFileTreePane`,
  keyboard navigation, and the left-pane Notes mode.
- `RielaNoteDetailView` binds the vertical pager's scroll position to
  the selected note id. A visible-page change calls
  `viewModel.requestSelection(.note(noteId))`; button/keyboard
  navigation continues to call `.previousNote` / `.nextNote`.
- Near-edge page appearance asks the view model to load one additional
  notebook-notes page only when the window state says it is eligible.
  The implementation must not contain a `while hasMore` or equivalent
  full-notebook prefetch path in the reader.
- Comment creation refreshes only the current selected detail. Agent
  focus/expansion changes workspace UI state only; note content changes
  still go through explicit note/comment service methods.
- Validation includes code search for eager-fetch patterns in the
  reader path and tests in `RielaNoteFileTreeNotebookNotesPageStateTests`
  / `RielaNotePagerNoteSnapshotTests` or their current equivalents.

### Rollout Constraints

- No fanout: vertical pager, view-first pages, current-note actions, and
  lazy loading land as one issue-resolution work package.
- Do not remove compose/edit functionality; demote editing to an
  explicit action in the reader.
- Keep the change inside `Sources/RielaNoteUI` unless minimal
  `Sources/RielaNote` support is required for comment/paging bridges.
- Keep `RielaNoteUI` compatible with `macOS 14` and `iOS 17`.
- Do not push to origin. Do not chase the known unrelated
  `DaemonWorkflowNodePatchTests` local flake.

### Open Questions

- No unresolved user decisions are open for this continuation. The following
  implementation checks remain bounded by the accepted design.
- Backward page fetch is required only if implementation confirms a
  reader entry path that can start before the accumulated forward
  window. Otherwise forward-accumulated previous pages remain the v1
  contract.
- The implementation plan must record the SwiftUI scroll-position API choice
  after confirming the package's `macOS 14` / `iOS 17` availability
  constraints; the behavioral contract is vertical, one-page snapping bound to
  note ids.

### Reference Mapping

- Codex-agent references: none supplied for this work package.
- Cursor CLI behavior: not applicable. The reader is local
  `RielaNoteUI` behavior and introduces no agent-adapter or CLI
  execution semantics.
