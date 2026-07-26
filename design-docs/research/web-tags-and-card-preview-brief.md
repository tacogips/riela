# Design Brief: Web Notes — Classed-Tag Surfaces + Card Head-Note Preview

Status: research input for design (2026-07-26). Ground truth for the verified repo
facts below; the design doc should build on it rather than re-derive it. Extends
the merged Wrike-style web notebook view (PR #66, main @ 2c80fe6); see
`design-docs/research/wrike-web-notebook-view-brief.md` and
`design-docs/specs/design-wrike-web-notebook-view.md` for the base feature.

## Goal

Three additions to the existing web Notes view (`web/src/views/NotesView.tsx` and
`web/src/notes/`), all against the SAME GraphQL surface served by RielaApp and
`riela serve`:

1. **Board-card (and list-row) head-note preview**: each notebook card shows an
   excerpt of the notebook's first note (its "head contents") plus the note
   count, matching the Wrike card feel of content-bearing cards.
2. **Detail panel: all-class tag chips grouped by class, with add/remove.** Today
   the panel shows only `folder`-class chips; person/year/topic/etc. tags on a
   notebook are invisible in the web UI.
3. **Left pane "Tags" tab**: a second tab beside the default Folder tab, listing
   non-folder tag classes as groups with their tags (hierarchical where
   `parentTagId` is set); selecting a tag scopes List/Board to that tag with
   server-side descendant expansion — exactly like folder scoping.

## Verified repo facts (main @ 2c80fe6 — do NOT re-derive, they are checked)

- **Tag model is kind+value**: `tags(tag_id, name UNIQUE, class_id, parent_tag_id)`
  + `tag_classes(class_id, label, description)` (`NoteStoreSchema.swift`). Nine
  seeded system classes: `content-kind`, `person`, `year`, `event`,
  `document-kind`, `topic`, `folder`, `source`, `workflow`. Custom classes via
  `defineNoteTagClass`.
- **`tags.name` is globally UNIQUE across classes** → all name-based mutations
  (`applyNotebookTags`, `removeNotebookTag`, `tagFilter`) are unambiguous.
- **`applyNotebookTags` auto-creates a CLASSLESS tag for unknown names**
  (`ensureTag`, `NoteService.swift:933` — `ON CONFLICT(name) DO UPDATE SET
  class_id = coalesce(...)`). Therefore the web add-tag flow must only apply
  EXISTING tags picked from the `tags` query, or create classed tags explicitly
  via `defineNoteTag(input:{name, classId, parentTagId})` BEFORE applying.
  Never send a free-text name straight to `applyNotebookTags`.
- **`removeNotebookTag` guards**: `deletable=false` assignments and
  ai-removing-human throw `protectedTag`. The existing chips UI already renders
  the remove button only when `assignment.deletable` — keep that pattern for all
  classes.
- **Hierarchy expansion is class-independent**: `expandedTagFilterNames`
  (`NoteTagHierarchy.swift`) is a pure name→descendants recursive CTE over
  `tags.parent_tag_id`, no class filter. Any classed tag with children scopes to
  its whole subtree via `tagFilter: [name]` for free.
- **`firstNotePreview` and `noteCount` ALREADY EXIST end-to-end on the backend**:
  `Notebook` model fields (`NoteModels.swift:46-47`), batch-enriched for lists by
  `enrichNotebookListMetadata` (`NoteService+NotebookStats.swift` — single
  grouped queries, no N+1), and present in the GraphQL contract
  (`GraphQLNoteSchemaContract.swift:13` `type Notebook { ... firstNotePreview:
  String, noteCount: Int }`). The web client simply does not request these
  fields. Confirm the executor returns them for the `notebooks` list query (the
  type map in `NoteGraphQLDocumentExecutor.swift` lists both as scalar leaves);
  if any list path skips enrichment, wire it — but expect this to be
  query-selection work only.
- **Web client**: `web/src/notes/client.ts` builds the GraphQL documents; types
  in `web/src/notes/types.ts` (`Notebook` has no preview/count fields yet).
  `tags` query already returns ALL classes (`classId`, `parentTagId` included);
  `tagClasses` returns `{classId, label, description}`. The folder tree is
  client-filtered (`folderTags`/`buildFolderTree` in `web/src/notes/tree.ts`).
- **e2e harness**: `web/e2e/dashboard.spec.ts` `installAPI` fixture intercepts
  `**/graphql` by operationName; extend fixtures for new fields/operations and
  keep `fixture.assertClean()` passing.

## UI design direction

Keep the existing visual language (folder pane, chips, pills). Wrike reference:
location chips under the item name; this extension generalizes chips to
"class-grouped attribute chips".

### 1. Card / row preview
- Board card: under the title, render `firstNotePreview` clamped to ~3 lines
  (CSS line-clamp; plain text — the excerpt is markdown source, render as text,
  do not parse markdown), and a subtle `noteCount` badge (e.g. "12 notes").
- List row: optional one-line clamped preview under the title (keep rows
  compact); include noteCount with the date metadata.
- Empty preview (no notes) → omit the block, no placeholder text.

### 2. Detail panel: class-grouped tag chips
- Replace the single "Folders" section with sections per class that has
  assignments, ordered: Folder first (unchanged behavior), then other classes
  alphabetically by class label, then classless tags last under "Tags".
- Chips show tag name; remove button only when `deletable` (existing rule).
- "Add tag" affordance: class picker (from `tagClasses`) + tag picker filtered
  to that class's unassigned tags (from `tags`), applying via existing
  `applyNotebookTags` by name. Folder keeps its existing dedicated picker.
  No free-text creation in the detail panel (creation lives in the tree panes).
- ~~Do NOT allow removing/adding on another notebook mid-flight races~~ — reuse
  the existing `membershipBusy` + staleness patterns already in NotesView.

### 3. Left pane Tags tab
- The left pane header becomes a real 2-tab strip: **Folder** (default,
  unchanged) | **Tags**.
- Tags tab content: non-folder classes as collapsible groups (class label +
  tag count), each group listing its tags; tags with `parentTagId` render as a
  tree (reuse/generalize `buildFolderTree` to a class-scoped tree builder).
  Classless tags group last.
- Selecting a tag scopes the content area exactly like a folder:
  `tagFilter: [tagName]` (server expands descendants). Single active scope
  shared with the folder tab — selecting a tag clears folder selection and vice
  versa; breadcrumb shows "ClassLabel / TagName" (with tag ancestors when
  hierarchical). "All notebooks" clears any scope.
- Optional (nice-to-have, in scope only if cheap): create a classed tag from the
  Tags tab via `defineNoteTag` with the group's classId, mirroring folder
  creation incl. the name-collision guard (names are GLOBAL — reuse
  `folderNameCollision` generalized across classes).

## Scope

IN: the three additions above; web client GraphQL selection updates
(`firstNotePreview`, `noteCount`); tree/chips/type/controller updates + bun unit
tests; Playwright e2e for tag-tab scoping, class-grouped chips add/remove, and
card preview rendering; any minimal Swift/GraphQL fix ONLY if a list path turns
out not to enrich preview/count (verify first).

OUT (do not build): tag rename/delete, tag class editing UI, multi-select
combined scopes (folder AND tag), free-text tag creation in the detail panel,
markdown rendering of previews, note editing, changes to native macOS UI,
CORS/auth changes, new REST endpoints.

## Quality bars

- Respect `web/scripts/audit-source.ts` (no fixtures/mocks in production source).
- Preserve all existing race guards (loadGeneration/folderScopeGeneration,
  staleness checks in catch/finally) and extend them to tag-scope switches —
  tag scoping MUST reuse the same `beginFolderScope`-style generation bump.
- All existing suites stay green: `cd web && bun run lint && bun run typecheck
  && bun run test && bun run build && bun run test:e2e`; `swift build` +
  RielaServerTests / RielaGraphQLTests / RielaNoteTests / RielaAppSupportTests
  (known-flaky: DaemonWorkflowNodePatchTests event-source restart — pre-existing,
  ignore).
- Additive GraphQL only; no breaking contract changes.
