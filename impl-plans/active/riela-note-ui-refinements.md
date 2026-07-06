# Riela Note UI Refinements Implementation Plan

**Status**: Implemented; post-review follow-ups pending (TASK-012–018)
**Design Reference**: design-docs/specs/design-riela-note-ui-refinements.md
**Created**: 2026-07-06
**Last Updated**: 2026-07-06 (post-implementation review)

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-ui-refinements.md
(decisions D1–D11; requirements R1–R9)

### Summary

UX follow-up on the shipped Riela Note UI: settings entry inside the
Notes window (D1), title-less screen-based note creation with
header/first-line title derivation (D2/D3), newline-preserving
block-markdown detail rendering with a body-first layout (D4/D5),
search-popup manual linking with preview plus AI propose-then-confirm
link extraction (D6/D7), a three-column filters | list | detail library
layout backed by new sort/date/linked-search service options (D8/D9), a
floating hover quick-create button (D10), and attachment test-gap
closure (D11).

### Scope

**Included**: `Sources/RielaNoteUI` view/view-model/client changes,
`Sources/RielaApp` menu + window-callback changes,
`Sources/RielaNote` title derivation and list/search option extensions,
GraphQL contract/service updates for new list/search options and link
proposals, a packaged `note-link-extract` workflow with service
fallback, new tests.

**Excluded**: iOS apps, embedded-image markdown rendering (B13
remainder), note-agent streaming rework (B7), settings SwiftUI port,
title backfill migration, multi-hop link expansion.

---

## Task Breakdown

### TASK-001: Title derivation — header or first-line fallback (D2 backend)
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNote/NoteService+Rows.swift` — `noteTitle(from:)`:
  first `#`–`######` heading → first non-empty line (markdown markers
  stripped, 120-char cap) → nil.
- `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift:814-829` —
  align addon fallback-title logic with the same rule (share one
  helper).
- `Tests/RielaNoteTests` — derivation cases: `# h1`, `### h3`,
  no-heading first line, list-marker first line, cap, empty body;
  create + update re-derivation.

**Checklist**:
- [x] First-line fallback in `noteTitle(from:)`
- [x] Single shared helper used by service and addon paths
- [x] Unit tests pass

---

### TASK-002: Compose screen replaces creation sheet (D2 UI / D3)
**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteComposeView.swift` (new) — body-only
  `TextEditor`, live derived-title caption, destination caption,
  Save (Cmd-Return) / Cancel, editor auto-focus.
- `Sources/RielaNoteUI/RielaNoteRootView.swift` — `.compose(...)` route
  case (compact push); regular-width composer in detail column.
- `Sources/RielaNoteUI/RielaNoteNotebookListView.swift` — remove
  `RielaNoteCreationSheet` (`:296-332`), `.sheet` wiring (`:81-93`),
  and `rielaNoteDraftMarkdown` heading injection (`:979-986`); toolbar
  actions route to the compose screen; body saved verbatim.
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` — drop `title:`
  params from `createUserMemo` / `createNoteInSelectedNotebook`
  (`:408-443`); post-create selection preserved.
- UI tests: compose-save round trip, blank-body fallback behavior.

**Checklist**:
- [x] Compose view with derived-title caption
- [x] Compact route + regular detail-column presentation
- [x] Sheet and title field removed; body stored verbatim
- [x] Tests pass

---

### TASK-003: Floating quick-create button (D10)
**Status**: COMPLETED
**Depends On**: TASK-002
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteNotebookListView.swift` (or a small
  `RielaNoteQuickCreateButton.swift`) — bottom-trailing overlay "+"
  button; hover-expanded labels ("New memo", "New note in notebook"
  when a notebook is selected); touch fallback (context menu); opens
  the compose screen focused.
- Keyboard shortcuts unchanged (Cmd-N / Cmd-Shift-N).

**Checklist**:
- [x] Overlay button, hover expansion, AppKit-free
- [x] Routes to compose screen with focus
- [x] Does not obscure list "Load more" row

---

### TASK-004: Block markdown renderer — newline preservation (D4)
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteMarkdownBodyView.swift` (new) — block
  splitter (headings, paragraphs, fenced code, lists, blockquotes,
  thematic breaks) + `LazyVStack` renderer; paragraphs parsed per-block
  with `.inlineOnlyPreservingWhitespace`; monospaced code blocks;
  `textSelection(.enabled)` kept.
- `Sources/RielaNoteUI/RielaNoteDetailView.swift:127-148` — detail body
  uses the new renderer. `RielaNoteMarkdownText`
  (`RielaNoteComponents.swift:64-76`) retained for chat/agent bubbles
  only.
- Backend preview collapsing untouched
  (`NoteService+NotebookStats.swift:89-91`, `NoteSearch.swift:351-361`).
- Unit tests on the block model: newline preservation, heading levels,
  fence boundaries, mixed content.

**Checklist**:
- [x] Block splitter + renderer
- [x] Detail view newlines preserved; list previews still collapsed
- [x] Unit tests pass

---

### TASK-005: Body-first detail layout (D5)
**Status**: COMPLETED
**Depends On**: TASK-004
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` — reorder: title
  header → full-width body (larger type, line spacing) → collapsible
  Tags / Links / Comments / Files sections with counts in headers;
  edit controls stay in header; read-only lock unchanged.

**Checklist**:
- [x] Body visually dominant
- [x] Metadata collapsible with counts, no functionality lost

---

### TASK-006: Manual add-link popup with search + preview (D6)
**Status**: COMPLETED
**Depends On**: TASK-004
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteLinkSearchSheet.swift` (new) — search
  field → `searchNotes` client API; result list; preview pane via
  `noteDetail(noteId:)` + `RielaNoteMarkdownBodyView`; excludes current
  note and existing links (reuse `rielaNoteLinkTargetSuggestions`
  rules, `RielaNoteDetailView.swift:521-545`); link-kind advanced
  disclosure (default `related`); confirm → `linkSelectedNote` with
  human provenance.
- `Sources/RielaNoteUI/RielaNoteDetailView.swift:287-333` — replace
  inline composer with "Add link" button opening the sheet.
- UI tests: exclusion rules, confirm path.

**Checklist**:
- [x] Sheet with FTS search + preview
- [x] Inline composer removed
- [x] Tests pass

---

### TASK-007: AI link extraction — propose then confirm (D7)
**Status**: COMPLETED
**Depends On**: TASK-006
**Deliverables**:
- `Sources/RielaNote/NoteService+Relations.swift` — deterministic
  fallback candidate proposer (FTS term-overlap, excludes existing
  links/self), returning `{targetNoteId, linkKind, reason}`.
- Packaged `note-link-extract` example workflow —
  `riela/note-get` → `riela/note-search` → agent-worker selection step
  (follows `note-auto-tagging` / `note-agent` packaging precedent).
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` —
  `proposeNoteLinks(noteId:)` protocol + service implementation
  (workflow when adapter configured, fallback otherwise, result
  labeled).
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` — "Extract links
  (AI)" button; proposal confirmation list (title, reason, preview);
  accepted → `linkNote(..., provenance: .ai)`.
- GraphQL: `proposeNoteLinks` query/mutation in
  `GraphQLNoteSchemaContract.swift` + `NoteGraphQLService.swift` so CLI
  and served API stay at parity.
- Tests: fallback proposer unit tests; mock-scenario workflow test;
  provenance rule regression (AI cannot overwrite human link,
  `NoteService+Relations.swift:6-47`).

**Checklist**:
- [x] Fallback proposer + packaged workflow
- [x] Client protocol + UI confirm flow with `.ai` provenance
- [x] GraphQL parity
- [x] Tests pass

---

### TASK-008: Service/GraphQL list & search options (D9)
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNote/NoteService.swift` (`listNotebooks:292-330`,
  `searchNotes:594-611`) + `NoteSearch.swift` — `sort`
  (createdAtDesc default / createdAtAsc / updatedAtDesc / title),
  `createdAfter`/`createdBefore`, and search `includeLinked` (one-hop
  `note_links` join both directions, deduped, linked hits ranked after
  direct hits, flagged in result rows).
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` — pass-through of new
  options; search result gains `isLinkedNeighbor`.
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift` +
  `NoteGraphQLService.swift` — schema args + executor parity.
- Tests: sort orders, date-range bounds, linked-expansion dedup and
  ranking, GraphQL round trip.

**Checklist**:
- [x] Service options + SQL
- [x] Client + GraphQL parity
- [x] Tests pass

---

### TASK-009: Three-column library layout with left filter pane (D8)
**Status**: COMPLETED
**Depends On**: TASK-008
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteFilterPane.swift` (new) — search field,
  sort picker, created-at presets + custom range, tag/class chips
  (moved from `RielaNoteNotebookListView.swift:192-238`),
  "include linked notes" toggle, clear-filters.
- `Sources/RielaNoteUI/RielaNoteRootView.swift:96-102` —
  `NavigationSplitView(sidebar: filters, content: notebook/note list,
  detail: note view/composer)`; compact width keeps list root with a
  toolbar filter button presenting the pane as a sheet.
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` — unified
  `RielaNoteListFilter` state driving list + search reloads; existing
  pagination/refresh behavior preserved.
- UI tests: filter state → query mapping; compact filter sheet.

**Checklist**:
- [x] Filter pane (search, sort, created-at, tags, associated-to)
- [x] Notebook list in middle/right column per R7
- [x] Compact fallback; pagination/refresh regressions none
- [x] Tests pass

---

### TASK-010: Settings entry inside Notes window (D1)
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteRootView.swift` — toolbar gear on
  Library tab, shown only when `onOpenSettings` callback is non-nil.
- `Sources/RielaApp/NoteWindowController.swift:30` — inject callback
  invoking the `openNoteSettings()` path
  (`EntryPoint+Notes.swift:38-63`).
- `Sources/RielaApp/EntryPoint+Menu.swift:20` — remove
  "Note Settings..." menu item.

**Checklist**:
- [x] Gear opens Notes Settings window
- [x] Menu item removed; "Notes..." remains
- [x] RielaNoteUI stays AppKit-free

---

### TASK-011: Attachment test-gap closure (D11, R9)
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Tests/RielaNoteTests/NoteFileStoreTests.swift` — direct S3 attach
  (no migration), multi-file `position` ordering within one role.
- GraphQL `attachFile` → `noteFile` round-trip test alongside existing
  note GraphQL tests.

**Checklist**:
- [x] Direct S3 attach test
- [x] Position/ordering test
- [x] GraphQL attach round-trip test

---

## Post-Review Follow-up Tasks (2026-07-06 review)

Source: design doc "Post-Implementation Review (2026-07-06)" section
(findings F-C1, F-M1–F-M9, minors). Build and all 176 note-related
tests pass; the items below are the review's required fixes.

### TASK-012: Single `type Query` in published SDL + execution tests (F-C1)
**Status**: NOT_STARTED
**Depends On**: —
**Priority**: Critical — the current published SDL is invalid GraphQL.
**Deliverables**:
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift:87-97` — remove
  the note-side `type Query` block; note query fields live only in the
  merged `type Query` in `GraphQLContracts.swift` (which currently
  disagrees with the note block — reconcile field lists there).
- Regression test asserting the published contract contains exactly one
  `type Query` and one `type Mutation` (substring counting is enough to
  catch recurrence).
- Execution-level GraphQL tests (not substring checks) for
  `searchNotes(sort:, createdAfter:, includeLinked:)`,
  `notebooks(sort:)`, `proposeNoteLinks`, and invalid-`sort` rejection.
- Publish `enum NoteListSort` in SDL (camelCase raw values) or document
  accepted `sort` values on the args.

**Checklist**:
- [ ] One `type Query` in emitted SDL (`riela graphql schema`)
- [ ] One-Query/one-Mutation regression test
- [ ] Execution tests for new args + proposeNoteLinks
- [ ] Sort values discoverable in SDL

---

### TASK-013: Link-proposal provider hardening and re-home (F-M1, F-M2, F-M6)
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- Move the `Process`-backed
  `RielaNoteWorkflowLinkProposalProvider` implementation out of
  `RielaNoteUI` into `RielaApp` (protocol + draft types stay), or gate
  it `#if os(macOS)`; RielaNoteUI must build for iOS again.
- Concurrent stdout/stderr draining (started before `waitUntilExit`),
  overall deadline that terminates the process, and
  `withTaskCancellationHandler` so cancelling the Task kills the child.
- `proposeNoteLinks` client path
  (`RielaNoteUIClient.swift:383-390`): resolve proposal drafts
  per-item (skip unresolvable `targetNoteId`s instead of discarding
  all); fall back to the deterministic proposer only when no provider
  is configured; propagate provider errors to the sheet; an empty
  successful workflow result returns `[]`, not fallback output.
- Proposal sheet: render `proposal.source` badge
  (workflow vs deterministic), add candidate preview (reuse
  `RielaNoteMarkdownBodyView` + `noteDetail`), sheet-local error text.
- Allowlist `linkKind` on accept (`related` / `source-citation`);
  respect the `limit` parameter (currently hardcoded 8); document the
  `/usr/bin/env riela` PATH caveat or resolve via settings.

**Checklist**:
- [ ] RielaNoteUI iOS-compilable again (no unconditional `Process`)
- [ ] No pipe deadlock; timeout + cancellation enforced
- [ ] Per-draft resolution; errors surfaced; fallback only when
      unconfigured; source badge + preview in sheet
- [ ] linkKind allowlist on accept

---

### TASK-014: note-link-extract workflow correctness (F-M3, F-M4)
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `examples/note-link-extract/workflow.json` — fan-in
  `get-subject-note → select-link-proposals` (or inject
  `{{workflowInput.noteId}}` + subject body into the prompt) so the
  selection agent actually sees the subject note it is told to review.
- `mock-scenario.json` rewritten to the loader's
  `{nodeId: MockNodeResponse}` format (mock `select-link-proposals`
  and `workflow-output`); inputs documented as a `--variables`
  invocation.
- `EXPECTED_RESULTS.md` made executable like
  `examples/note-auto-tagging`'s (exact validate/run commands + stable
  assertions); wire into the mock-scenario test that TASK-007 claimed.

**Checklist**:
- [ ] Subject note id/body reaches the selection agent
- [ ] Mock scenario actually mocks the agent nodes
- [ ] Deterministic run documented and asserted

---

### TASK-015: UI async-state correctness (F-M5, F-M7, F-M9 + UI minors)
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `RielaNoteLibraryViewModel.proposeLinksForSelectedNote` (`:920-934`):
  note-id/generation guard so stale proposals can never be shown for —
  or accepted on — a different note; serialize overlapping runs.
- `RielaNoteLinkSearchSheet` (`:84-144`): single cancel-and-replace
  search task, post-`await` currency guards for query and selected
  note, no double-fire on Return, auto-select only when nothing
  selected, preview errors surfaced.
- Post-create filter reset includes `createdRange` (mirror
  `clearSearchFilters`) so the created note is visible and selected
  (`RielaNoteLibraryViewModel.swift:410-468`).
- `hasSearchFilters` accounts for `includeLinked` (`:104-106`).
- Compose Save in-flight guard (no double-create on double
  Cmd-Return); regular-width note selection dismisses an open
  composer (`RielaNoteRootView.swift:141-193`).
- Single debounced search entry point (drop the duplicate
  list-view `onChange`); created-at custom fields validated
  (`DatePicker` or ISO validation) and reload on commit only.
- Sheet-local error presentation for propose/accept; gate "No Results"
  overlay on `state == .loaded`.

**Checklist**:
- [ ] Proposal race fixed (guarded by note id/generation)
- [ ] Link sheet stale-async bugs fixed
- [ ] Post-create visibility with active date filter
- [ ] includeLinked in hasSearchFilters; debounced single search path
- [ ] Compose double-save guard; composer dismissal
- [ ] Sheet-local errors; no "No Results" flash while loading

---

### TASK-016: Title derivation robustness (F-M8 + minors)
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `Sources/RielaNote/NoteTitleDerivation.swift` — fence-aware scanning
  (skip ``` ```/~~~ ``` fenced regions in both heading scan and
  first-line fallback); ≤3 leading spaces rule for headings per
  CommonMark; strip ATX closing hash runs (`# Title ##` → "Title");
  replace the blanket trailing `#*_`[]()` `CharacterSet` trim with
  targeted leading-marker stripping so `**Bold**`/`[Link](url)`
  first lines aren't mangled and fence info lines are never titles.
- Tests: fenced `#` comment not a title; indented code line not a
  title; closing-hash strip; bold/link first-line; CRLF; Japanese
  text.
- Document (CLI/GraphQL doc comments) that `updateNoteBody`
  re-derivation overwrites explicitly-set titles.

**Checklist**:
- [ ] Fence-aware derivation + CommonMark heading rules
- [ ] Marker-stripping fixes with tests
- [ ] Title-overwrite behavior documented

---

### TASK-017: Search semantics — decide, tighten, document (backend minors)
**Status**: NOT_STARTED
**Depends On**: TASK-012 (SDL doc placement)
**Deliverables**:
- Decide rank-vs-sort precedence on the FTS path
  (`NoteSearch.swift:85`; recommendation: rank-first, documented) and
  make the three search paths consistent with the decision.
- Neighbor query (`NoteSearch.swift:302-350`): exclude direct hits
  inside the SQL `LIMIT`; apply created-at predicates (and the
  requested sort) to neighbors, or explicitly document that neighbors
  bypass filters; keep one-hop semantics.
- Normalize date-only `createdAfter`/`createdBefore` inputs to
  start/end-of-day (or document the full-timestamp requirement on the
  SDL args).
- Optionally extend `riela/note-search` addon with
  sort/date/includeLinked for workflow parity.
- Tests covering the decided semantics (distinct-rank FTS sort case,
  neighbor undercount regression, date-only bounds).

**Checklist**:
- [ ] Rank/sort precedence decided, consistent, documented
- [ ] Neighbor LIMIT/filter/sort tightened or documented
- [ ] Date-bound normalization or documentation
- [ ] Tests for the above

---

### TASK-018: Renderer & detail polish, dead code, missing tests (UI minors)
**Status**: NOT_STARTED
**Depends On**: —
**Deliverables**:
- `RielaNoteMarkdownBodyView.swift` — closing fence must not accept an
  info string (`:93`); stop rendering `>`/list markers literally
  inside styled quote/list blocks; unit tests for the block parser
  (headings, fences incl. unclosed, lists, quotes, newline
  preservation).
- `RielaNoteDetailView.swift` — comments render through the block
  renderer (`:375`); count-based default collapse per D5 (`:12`);
  remove the redundant "Comments" inner header (`:361`).
- Quick-create FAB via `safeAreaInset` (no overlap with "Load more"),
  `withAnimation` on hover expansion, accessibility label.
- Remove dead code: inline link-composer plumbing
  (`linkTargetSearchNotes`, `updateLinkTargetSearchText`,
  `rielaNoteLinkTargetSuggestions`) and vestigial `title:` parameters
  on `createUserMemo`/`createNoteInSelectedNotebook`; migrate their
  tests.
- Flexible sheet sizing for compact widths (replace hard-coded
  760×520 / 520×420 frames).

**Checklist**:
- [ ] Fence/quote/list rendering fixes + block parser tests
- [ ] Comments newline-preserving; D5 count-based collapse
- [ ] FAB inset/animation/accessibility
- [ ] Dead code removed; tests migrated
- [ ] Sheets fit compact widths

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Title derivation fallback | `Sources/RielaNote/NoteService+Rows.swift` | COMPLETED | - |
| Compose screen | `Sources/RielaNoteUI/RielaNoteComposeView.swift` | COMPLETED | - |
| Quick-create FAB | `Sources/RielaNoteUI/RielaNoteNotebookListView.swift` | COMPLETED | - |
| Block markdown renderer | `Sources/RielaNoteUI/RielaNoteMarkdownBodyView.swift` | COMPLETED | - |
| Body-first detail layout | `Sources/RielaNoteUI/RielaNoteDetailView.swift` | COMPLETED | - |
| Link search sheet | `Sources/RielaNoteUI/RielaNoteLinkSearchSheet.swift` | COMPLETED | - |
| AI link extraction | `NoteService+Relations.swift`, packaged workflow, client, GraphQL | COMPLETED | - |
| List/search options | `NoteService.swift`, `NoteSearch.swift`, GraphQL | COMPLETED | - |
| Filter pane + 3-column layout | `Sources/RielaNoteUI/RielaNoteFilterPane.swift`, `RielaNoteRootView.swift` | COMPLETED | - |
| Settings entry re-home | `EntryPoint+Menu.swift`, `NoteWindowController.swift`, `RielaNoteRootView.swift` | COMPLETED | - |
| Attachment test gaps | `Tests/RielaNoteTests/NoteFileStoreTests.swift` | COMPLETED | - |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| TASK-002 compose screen | TASK-001 title derivation | Completed |
| TASK-003 FAB | TASK-002 | Completed |
| TASK-005 detail layout | TASK-004 renderer | Completed |
| TASK-006 link sheet | TASK-004 renderer (preview) | Completed |
| TASK-007 AI extraction | TASK-006 (shared confirm/preview UI) | Completed |
| TASK-009 filter pane | TASK-008 service options | Completed |
| TASK-001/004/008/010/011 | — (parallelizable) | Completed |

## Completion Criteria

- [x] All tasks implemented; `swift build` and `swift test` pass
- [x] R1–R8 verified by the design doc's manual macOS pass
- [x] R9 gaps closed (direct S3 attach, ordering, GraphQL round-trip)
- [x] `RielaNoteUI` compiles without AppKit imports
- [x] GraphQL/CLI parity maintained for new options and proposals
- [ ] Post-review follow-ups TASK-012–018 closed (F-C1 SDL validity,
      provider hardening/re-home, workflow correctness, UI async
      races, title-derivation fences, search semantics, polish)
- [ ] Published SDL parses as valid GraphQL (single `type Query`)
- [ ] `RielaNoteUI` compiles for iOS (no unconditional `Process`)

## Progress Log

### Session: 2026-07-06 (post-implementation review)
**Tasks Completed**: Three-dimension review (backend / UI / GraphQL+
workflow parity) of the uncommitted implementation; build + 176
note-related tests pass; `riela workflow validate note-link-extract`
passes.
**Tasks In Progress**: —
**Blockers**: F-C1 — published SDL currently contains two `type Query`
definitions (invalid GraphQL); fix via TASK-012 before commit/ship.
**Notes**: Findings recorded in the design doc's
"Post-Implementation Review (2026-07-06)" section; follow-ups filed as
TASK-012–TASK-018 (1 critical, 9 major, minors condensed).

### Session: 2026-07-06
**Tasks Completed**: TASK-001 through TASK-011 implemented; Riela review findings addressed.
**Tasks In Progress**: Final verification and completion audit
**Blockers**: None
**Notes**: Implemented title-less compose, body-first detail rendering, link search and workflow-backed proposals with fallback, service/GraphQL filters, settings relocation, and attachment coverage. Riela review found and this session addressed full-text link filtering, configurable workflow-backed proposal execution, and stale plan status. Original plan created from
design-docs/specs/design-riela-note-ui-refinements.md.

## Related Plans

- **Depends On**: `impl-plans/active/riela-note.md` (base feature)
- **Related**:
  `design-docs/specs/design-riela-note-review-improvements.md`
  (B2/B3/B12/B13 overlap; B13 embedded images remain there)
