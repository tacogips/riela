# Design Brief: Wrike-Style Web Notebook View for Riela Note

Status: research input for design (2026-07-25). This file is ground truth for the
Wrike UI reference and for the repo integration facts below; the design doc should
build on it rather than re-derive it.

## Goal

Add a Wrike-inspired **web notebook view** to the existing SolidJS web app (`web/`),
backed by Riela Note data served from **both** RielaApp's embedded web server and
`riela serve`. Two content views — **List view** and **Kanban (Board) view** — plus a
**left pane whose default tab is a "Folder" tab** rendering the folder hierarchy as a
file tree. One notebook = one list row = one board card. Notebooks belong to
multiple folders simultaneously (Wrike multi-parenting). Selecting a folder in the
tree scopes the content area to that folder (folder view).

## Wrike UI reference (distilled from help.wrike.com + reviews)

### Left sidebar
- Vertical panel: top utility items (search), then a **pinned items** section, then
  the **folder/project tree** as the central navigation hub.
- Tree rows: expand/collapse **caret (chevron) to the left of the title**, type icon
  (folder icon for folders), name; hover reveals action icons (pin, three-dot menu)
  on the right. Arbitrary nesting depth. Drag-and-drop / menu reordering.
- Selecting a tree node loads that container's content in the main area.

### Multi-parenting (Wrike's signature feature)
- An item lives in **multiple folders simultaneously** — folders behave as
  tags/symlinks over one canonical item, never copies.
- UI affordances: a row of **location chips under the item's title** in the detail
  panel showing every folder it belongs to; a **"+" picker** next to the chips to add
  the item to another folder (additive); removing one location does not delete the
  item or its other locations.

### List view
- Rows one-after-another; per-row: title, status/progress affordance, dates;
  optional grouping; sortable via a toolbar dropdown (name, date, status).
- Clicking a row opens a **detail panel overlaying the right side** (split screen:
  list left, details right). The same detail panel component is reused from every
  view.
- Inline add row ("+ Item") at the bottom.

### Board (Kanban) view
- **Columns = workflow statuses**. Dragging a card between columns updates the
  status; changing status elsewhere moves the card.
- Cards are minimal: title, key metadata (dates), expandable details. Column
  headers show name + count; columns can collapse (incl. "collapse empty columns").
- Toolbar: Filter, Sort (within columns), Group controls shared with list view.

### View switching & folder view
- A **tab strip at the top of the content area** (List | Board | …) switches views;
  each container remembers its own active view and filter/sort state.
- Header above the tabs: breadcrumb of the current container + actions.
- Selecting a folder shows its info (title, description) plus the scoped item views.

### Visual style
- Clean, information-dense, "all business" enterprise feel; restrained color —
  status colors from a fixed palette are the main color accents; compact density.

## Riela mapping (verified against the repo, main @ e45166f)

- **Folder = tag of the seeded `folder` tag class** (`NoteStoreSchema.swift`
  systemTagClasses); hierarchy via `tags.parent_tag_id` self-FK (schema v4).
  `NoteTagHierarchy.expandedTagFilterNames` already expands a tag filter to all
  transitive descendants (recursive CTE) — selecting a folder node in the tree and
  passing its tag name as `tagFilter` yields Wrike's "container shows nested
  content" semantics for free.
- **Multi-parenting = `notebook_tags` many-to-many**: a notebook holding several
  folder-class tags is exactly a Wrike item in several folders. Chips UI maps to
  `Notebook.tags` filtered to the folder class; add = `applyNotebookTags`,
  remove = `removeNotebookTag`.
- **Kanban columns = `NotebookProgress` enum** (`none | progress | done | pending`),
  already on notebooks with `setNotebookProgress` mutation. The native macOS
  Kanban (`RielaNoteTagKanbanSections.swift`) already groups by progress — mirror
  its column semantics.
- **GraphQL surface (unified schema, `Sources/RielaGraphQL/`)**:
  queries `notebooks(limit, offset, tagFilter, sort, createdAfter, createdBefore)`,
  `notebook`, `notes(notebookId, …)`, `searchNotes`, `tags`, `tagClasses`;
  mutations `createNotebook`, `deleteNotebook`, `setNotebookProgress`,
  `applyNotebookTags`, `removeNotebookTag`, `defineNoteTag(input:{name, classId,
  parentTagId})`, `defineNoteTagClass`. `tagFilter` is by tag NAME with hierarchy
  expansion. `limit` max 200 (rejected, not clamped, when out of range).
  Known gaps: no notebook rename mutation; no tag delete; `defineNoteTag` cannot
  null-out a parent (coalesce upsert). Design within these or add the minimal
  mutation(s) needed — do not build a parallel REST content API.
- **Existing web app**: `web/` — SolidJS ^1.9, Vite 7, Tailwind v4, Bun, Playwright.
  Views shell in `web/src/App.tsx` (Instances / Logs / Workflows / Settings), REST
  client `web/src/api.ts` (`/api/v1/*`, CSRF header `X-Riela-CSRF`,
  same-origin). `web/scripts/audit-source.ts` bans fixtures/mocks/fetch-overrides in
  production source. Built via `bun run build` → `web/dist`, copied into
  RielaApp bundle by `scripts/build-riela-menu-bar-app.sh`.
- **Serving today**:
  - RielaApp embedded server (`RielaLocalHTTPServer.swift`, `RielaAppWebRouter.swift`)
    serves the SPA + REST; its `/graphql` is wired **without** an executor (schema
    echo only) — no Note data reachable from the browser.
  - `riela serve` (`ServeHTTPCommand.swift`, default `127.0.0.1:8787`) with
    `--note-api` wires `NoteGraphQLDocumentExecutor` over a real
    `NoteService(SQLiteNoteDatabaseDriver(noteRoot:))` at `POST /graphql`, with
    bearer-token auth minted via `/note/register`
    (`noteGraphQLRequiresAuthentication`, `ServerContracts.swift`). It serves **no
    static assets** and there is **no CORS support anywhere** — browser access must
    be same-origin. (README's claim that the note transport "is not shipped" is
    stale; the code binds and serves.)

## Architecture direction

Make both servers symmetric, same-origin hosts of the notebook UI:

1. **RielaApp path**: wire the existing `NoteGraphQLDocumentExecutor` (in-process
   `NoteService` with the app's note root) into `RielaAppWebRouter`'s `/graphql`,
   protected consistently with the existing REST auth/CSRF conventions. The SPA is
   already served from the app bundle.
2. **`riela serve` path**: add static SPA hosting (serve `web/dist`, path
   configurable/discoverable) so the browser is same-origin with the existing
   `--note-api` GraphQL endpoint; provide a workable browser auth story reusing the
   existing `/note/register` bearer flow (e.g. a lightweight registration/bootstrap
   the SPA can perform, or a localhost session bootstrap) — do NOT invent a second
   auth system.
3. **Frontend**: a new "Notes" view in the `web/` shell with: left pane (tabbed;
   default **Folder** tab = folder-class tag tree built from `tags` +
   `parentTagId`), content header (breadcrumb + List|Board tab strip + sort/filter),
   **List view** and **Board view** of notebooks, folder scoping via `tagFilter`,
   notebook detail panel (right overlay) showing title, progress, folder chips with
   add/remove, timestamps, and the notebook's notes (read-only preview is enough).
   Board drag-and-drop between progress columns calls `setNotebookProgress`
   (optimistic update, newer-wins reconciliation as in the native VM's K1 lesson:
   DB convergence must not be gated on board context).

## Scope

IN: the above — folder tree (create folder = `defineNoteTag` with folder class +
parentTagId; rename/delete out), list view, board view, folder scoping, multi-folder
chips add/remove, progress drag, detail panel with read-only notes preview, both
serving paths, tests (bun + swift), Playwright coverage for the new view where the
existing e2e harness allows.

OUT (do not build): Gantt/Table/Calendar views, note editing from the web, custom
fields, pinned items, spaces, dashboards, tag rename/delete mutations, WIP limits,
swimlanes, drag-and-drop of tree nodes, offline support, CORS (stay same-origin),
any parallel REST content API for notes.

## Quality bars

- Respect `web/scripts/audit-source.ts` (no fixtures/mocks in production source).
- Swift: follow existing RielaServer/RielaGraphQL patterns; additive GraphQL only.
- All existing suites stay green; add tests for new Swift routing/auth and new
  frontend logic (bun test), e2e for view switching + folder scoping if feasible.
