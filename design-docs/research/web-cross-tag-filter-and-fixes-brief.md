# Design Brief: Web Notes cross-tag (AND) filter + web-version fixes

Status: research input for design (2026-07-27). Ground truth for the cross-tag
intersection feature contract and the confirmed repo seams below; the design doc
should build on this rather than re-derive it. **Treat this entire request as
exactly ONE feature / ONE work package; has_feature_fanout must be false.**

## Goal

Improve the riela Note **web version** (`web/`, SolidJS SPA). Two parts, shipped
together as one package:

1. **New feature — cross-tag intersection (AND) filter.** Today the web can scope
   the notebook list/board to a *single* folder or tag only. Add the ability to
   combine multiple tag/folder scopes so the List and Board views show only
   notebooks that carry **all** selected scopes (e.g. folder `Launch` **AND** topic
   `Web`). Verify Kanban, List, and this cross-tag filter behave correctly.
2. **Fixes** — the correctness/UX defects catalogued in "Part B" below (from an
   adversarial review of the web Notes code).

## Confirmed repository seams (ground truth — verified 2026-07-27)

### Server (union today; needs AND-of-union)
- `RielaNote/NoteService.swift` `listNotebooks(limit,offset,tagFilter:[String],sort,…)`
  expands folder names to descendants via `expandedTagFilterNames(...)` (recursive
  CTE) then emits a **single** predicate
  `EXISTS(SELECT 1 FROM notebook_tags nt JOIN tags t … WHERE t.name IN (expandedPool))`.
  Multiple names = **union** (notebook matches ANY). There is no intersection path.
- Empty-guard: `guard tagFilter.isEmpty || !expandedTagFilter.isEmpty else { return [] }`.
- GraphQL: `Sources/RielaGraphQL/NoteGraphQLService.swift` exposes
  `notebooks(limit,offset,sort,tagFilter:[String!])`; contracts in
  `GraphQLContracts.swift`. Note CLI documents in `NoteCommandGraphQLDocuments.swift`.

### Frontend
- `web/src/notes/controller.ts` `NotebookScopeController` holds ONE `NotebookScope`
  (`{kind:'all'} | {kind:'folder',tagId,tagName} | {kind:'tag',tagId,tagName,classId}`)
  and `tagFilter(snapshot)` returns `[]` or `[tagName]` — always ≤1 name.
- `web/src/notes/client.ts` `notebooks(offset,sort,tagFilter:string[])` sends the
  `Notebooks` GraphQL query with `$tagFilter:[String!]`.
- `web/src/notes/paging.ts` `loadNotebookPages(client,sort,tagFilter,isCurrent,onPage)`
  threads the flat `tagFilter` through bounded 200-offset paging + dedup.
- `web/src/views/NotesView.tsx` renders folder tree / tags tab / breadcrumb / list /
  board / detail; `refresh()` uses `scopeController.tagFilter(scopeSnapshot)`.
- Existing browser coverage: `web/e2e/dashboard.spec.ts` (Playwright, **mocked**
  GraphQL) already exercises the Notes view; extend it, don't duplicate.

## Part A — Cross-tag intersection (AND) filter design

### Server contract (recommended: AND-of-union groups)
Introduce a grouped filter that generalizes the current single-EXISTS:
- Add `tagFilterGroups: [[String!]!]` to `notebooks(...)` (GraphQL + `listNotebooks`).
- Semantics: **each inner group is expanded + unioned independently** (reuse
  `expandedTagFilterNames` per group so a folder chip still matches its descendants),
  and **groups are AND-ed** — emit one `EXISTS(… t.name IN (group_i_expanded))`
  predicate per group, joined by `AND`.
- **Back-compat:** keep `tagFilter:[String!]` working as sugar for a single group
  (`tagFilterGroups = tagFilter.isEmpty ? [] : [tagFilter]`). Reject supplying both,
  or define a deterministic precedence (prefer `tagFilterGroups` when non-empty).
- Empty-group guard: if ANY group expands to empty (a real name that resolves to no
  tags), the intersection is empty → return `[]` (mirror the existing guard, per
  group). An all-empty `tagFilterGroups` == unfiltered.
- Apply the identical grouped predicate to the notebook-count/enrich path if it
  filters, and to `listNotes(tagFilter:)` only if the UI needs it (it currently does
  not — scope the change to notebooks to stay minimal).

### Frontend
- **Refactor `NotebookScope` to carry `constraints: Array<{tagId,tagName,kind,classId?}>`**
  (review finding F13): the UI starts limited to length ≤ 1 == today's behavior, then
  the chip bar lets it grow. Generalize the `refresh()` catalog-reconciliation block
  (NotesView.tsx:162-182: rename fixup + deleted-tag reset) into a **per-constraint
  reconcile loop** with partial-deletion semantics (drop just the deleted constraint;
  reset to 'all' only when no constraints remain). `selectedFolderId`/`selectedTagId`/
  breadcrumbs/`removeTag` left-scope messaging all read singular scope today and must
  become constraint-aware. Doing this refactor first makes the feature a UI+query
  change rather than a scope-model rewrite.
- Model an **active filter = ordered set of scope chips** (each chip = one folder or
  one tag, carrying `tagId`,`tagName`,`classId?`,`kind`). Single-chip == today's
  behavior. `{kind:'all'}` == no chips.
- `NotebookScopeController` (or a new `NotebookFilterController`) exposes
  `tagFilterGroups()` → `string[][]` (one `[tagName]` per chip; the server expands
  folders). Preserve the generation/staleness guards (`select`/`snapshot`/`isCurrent`)
  and extend them to the multi-chip state so a scope change still rejects stale
  responses. Update `client.notebooks` + `paging.loadNotebookPages` to pass
  `tagFilterGroups`.
- UI: a **filter chip bar** above the List/Board content showing active chips with a
  remove `×` each and a "clear all". Adding a chip: selecting a folder/tag in the
  left pane should ADD to the filter when a modifier/explicit "add to filter"
  affordance is used, while a plain click keeps the familiar single-scope replace
  (choose the least surprising interaction and document it). Breadcrumb must stay
  coherent with multi-chip state.
- Keep Kanban and List both honoring the intersection identically (both read the same
  `notebooks()` signal, so they will if paging passes the grouped filter).

### Tests (server + web unit + e2e)
- Swift: `listNotebooks` with `tagFilterGroups` — AND across two classes returns only
  notebooks having both; folder-group still expands to descendants; empty group →
  `[]`; back-compat `tagFilter` single-group unchanged. GraphQL service test for the
  new argument.
- Web unit (bun): controller `tagFilterGroups()` transitions; paging threads groups;
  client query shape includes `$tagFilterGroups`.
- Playwright e2e (`dashboard.spec.ts`): add a mocked scenario asserting the request
  carries the grouped filter and the list/board render the intersection; keep it
  deterministic.

## Part B — Web-version fixes (from adversarial review, CONFIRMED unless noted)

Fix the following in the same package. All line refs are `web/src/...`. **Required**
tier must ship; **Stretch** tier only if it does not threaten convergence.

### Required

- **F1 (high) — Board unmounts on every refresh.** `NotesView.tsx:483` gates the board
  on `!loading() && !partialLoading()` while the list (`:470`) is not, and `refresh()`
  sets `loading=true` at entry (`:153`). So Refresh/Sort, and detail-pane tag add/remove
  (which call `refresh()`), blank the entire board and cancel in-progress drags. Fix:
  render the board from the retained `notebooks()` like the list, overlaying a
  non-destructive "counts updating…" indicator; if final-counts-only is required, freeze
  and render the last-complete snapshot instead of unmounting.
- **F2 (high) — `removeTag` wipes the list even when the removed tag can't affect scope.**
  `NotesView.tsx:354-355`: `clearMembership` fires for ANY scoped removal → `setNotebooks([])`
  flash + full re-page, and on refresh failure leaves an empty list for a no-op removal.
  Fix: clear membership only when the tag can change membership — `tag.tagId===scope.tagId`
  (tag scope) or `tag.classId==='folder'` (folder scope, descendant expansion). Generalize
  to the constraints model (clear only if the removed tag intersects an active constraint).
- **F3 (medium) — Membership mutations not single-flight.** `:574`/`:514` disable only the
  exact tag/add control, so overlapping add/remove races overwrite `membershipBusy`,
  waste page-loads, and cross messages. Fix: disable all chip-remove + add controls
  whenever `membershipBusy() !== ''` (keep per-tag key for spinner placement only).
- **F4 (medium) — `loadPreview` same-notebook reselection race.** `:258-273` guards only on
  `selectedNotebookId() !== notebookId`; closing+reopening the same notebook lets a stale
  "load more" append into the fresh preview (dup/phantom notes, corrupted offset). Fix:
  add a preview generation counter bumped in `selectNotebook`/`closeDetail`, checked after
  each await (mirror `loadGeneration`).
- **F11 (medium, suspected) — Unknown `progress` value silently drops notebooks from the
  board** and renders a blank pill in the list (`:486`,`:478`; closed union in `types.ts`).
  This repo has prior closed-enum decode breakage. Fix: normalize unknown progress to
  `'none'` at the client decode boundary (`client.ts`) with a visible "unknown status"
  affordance so board columns always partition the full list.
- **F12 (medium, suspected) — Creating a root folder while scoped to a tag/All silently
  yanks the user into the new folder.** `:297-300` guard `selectedFolderId()===parentTagId`
  is true when both are `undefined`. Fix: auto-enter only when previous scope WAS the
  parent folder (`scope.kind==='folder' && scope.tagId===parentTagId`); never from a tag
  scope.
- **F6 (medium) — Focus dropped to `<body>` when a removal ejects the notebook from scope.**
  `:359,:366` pass `closeDetail(false)` and the originating row/card is gone. Fix: move
  focus deterministically to the list container / nearest surviving row / breadcrumb.
- **F9 (low) — Page-size 200 duplicated in 3 places** (`client.ts:88,110`, `paging.ts:3`,
  `NotesView.tsx:265`); drift silently truncates lists. Fix: single shared exported
  constant; compare `page.length === requestedLimit`.
- **F7 (low) — `notebookActivators` map leaks detached DOM nodes** (`:74,:472,:493`, never
  deleted). Fix: delete via Solid `onCleanup` in the ref callback, or prune to current ids
  on refresh/scope change.
- **F10 (low) — `loadNotebookPages` has no forward-progress guard** (`paging.ts:19-31`): a
  server ignoring `offset` loops forever. Fix: terminate + surface partial state when a
  page contributes zero new ids, plus a max-page cap.

### Stretch (only if convergence is not at risk)
- **F8 (low)** — attribute the progress-reconciliation error to the notebook (title) and
  don't let a new `moveProgress` clear an unacknowledged reconciliation error
  (`:83-86`, `controller.ts:112,123`).
- **F5 (medium) / F14 (low) — tree & tab ARIA/keyboard pattern.** Toggle buttons need
  `tabIndex={-1}`; treeitem role/aria-state belong on the focusable element; tablists
  need roving-tabindex + arrow-key switching or should drop `role=tab` for `aria-pressed`
  toggles. These are larger reworks — do them only if they don't destabilize the core
  feature + Required fixes.

### Verified non-issues (do NOT spend budget re-checking)
- beginScope/scopeController generation cannot desync (every select is followed by a
  refresh snapshotting after the bump).
- NotebookProgressController rollback/generation bookkeeping is correct (unit-tested),
  including the read-fail conditional `bumpStateVersion`.
- Board `onDrop` reads fresh `notebooks()`, no-ops on foreign payloads, skips same-column.

## Verification requirements (acceptance)

- `cd web && bun test src` (unit) green; `bun run typecheck` clean; `bun run lint`
  (eslint + audit) clean; `bun run build` succeeds.
- Swift: `swift build` + the Note-focused suites relevant to `listNotebooks`/GraphQL
  green (filtered, not the whole slow matrix).
- **Browser 動作確認 (codex computer-use / real Chrome):** against a live
  `riela serve --note-api --web-root web/dist --note-root <seed>` with a seeded store
  containing notebooks whose tag combinations make the intersection non-trivial:
  1. **List view** renders scoped notebooks, previews, counts, progress pills.
  2. **Kanban/Board** columns partition by progress; drag-and-drop (or the per-card
     select) moves a card between columns and persists (optimistic + server confirm).
  3. **Cross-tag filter**: selecting folder `Launch` + topic `Web` shows only
     notebooks carrying BOTH; removing one chip widens the result; "clear all"
     restores the scope.

## Constraints
- ONE feature / ONE work package; `has_feature_fanout` = false.
- Do not modify unrelated files or subsystems outside `web/` and the Note
  server/GraphQL surface needed for the grouped filter.
- Preserve same-origin/bearer security model; no CORS; no new auth.
- Keep the deliberate simplifications from prior Notes work (fixed 4-state progress
  palette, List view retained).
