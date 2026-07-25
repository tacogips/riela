# Design: Web Notes Classed Tags and Card Preview

Status: accepted for implementation planning

Workflow mode: `issue-resolution`

Issue reference:
`design-docs/research/web-tags-and-card-preview-brief.md` at commit `ea9426f`.
No GitHub issue URL or repository/number was supplied.

Codex-agent references: none supplied.

## Goal

Extend the Wrike-style web notebook view with one cohesive feature:

1. show the existing notebook head-note excerpt and note count in List and
   Board;
2. expose notebook tag assignments from every tag class in the detail panel;
   and
3. add tag-class navigation and descendant-aware tag scoping beside the
   existing folder navigation.

The base contracts in
`design-docs/specs/design-wrike-web-notebook-view.md` remain authoritative.
This extension is web-only unless read-only verification proves that a
notebooks-list service path does not enrich `firstNotePreview` and `noteCount`.

## Scope and boundaries

### In scope

- Additive web GraphQL selections for `Notebook.firstNotePreview` and
  `Notebook.noteCount`.
- Plain-text preview and note-count metadata in Board cards and List rows.
- Detail-panel tag assignment groups for Folder, named non-folder classes, and
  classless tags.
- Existing-tag selection and notebook membership mutation for non-folder
  classes.
- A `Folder | Tags` left-pane tab strip with class groups, class-scoped tag
  trees, one active folder-or-tag scope, and scope breadcrumbs.
- Unit and browser regression coverage for selections, grouping, hierarchy,
  scope races, rendering, and mutations.

### Out of scope

- Tag rename, delete, reparenting, or tag-class editing.
- Combined folder-and-tag filters or multi-select filters.
- Free-text tag creation in the notebook detail panel.
- Markdown parsing for notebook-card or list-row previews.
- Note editing, native macOS UI changes, CORS or authentication changes, and
  new REST endpoints.
- Changes to existing GraphQL field meaning or other breaking schema changes.

Classed-tag creation from the Tags pane is optional. If implemented, it must use
`defineNoteTag` with the selected explicit `classId` and the existing
global-name collision protection. Its absence does not prevent acceptance.

## Existing contracts retained

The design relies on verified contracts from the research brief:

| Behavior | Existing contract |
|---|---|
| Notebook excerpt and count | `Notebook.firstNotePreview` and `Notebook.noteCount`, batch-enriched by notebook-list reads |
| Tag catalog | `tags` supplies `tagId`, `name`, `classId`, and `parentTagId` |
| Class catalog | `tagClasses` supplies `classId`, `label`, and `description` |
| Descendant scope | `notebooks(tagFilter:[tagName])`; the service expands descendants |
| Add assignment | `applyNotebookTags(input:{notebookId,tags,provenance,assignedBy})` |
| Remove assignment | `removeNotebookTag(notebookId:tagName:)` and assignment `deletable` |
| Optional classed creation | `defineNoteTag(input:{name,classId,parentTagId,...})` |

Tag names are globally unique. `applyNotebookTags` creates an unknown name as a
classless tag, so the detail panel must submit only a name selected from the
current `tags` result. It must never accept or forward a free-text tag name.
Direct membership additions preserve the base design's explicit
`provenance: "human"` and `assignedBy: "riela-web"` values.

Before changing Swift, implementation must verify the existing notebooks-list
path against `GraphQLNoteSchemaContract.swift`,
`NoteGraphQLDocumentExecutor.swift`, and
`NoteService+NotebookStats.swift`. Swift changes are permitted only if this
check proves a list path skips metadata enrichment.

## Notebook preview behavior

The notebooks query additively selects `firstNotePreview` and `noteCount`.
Clients tolerate an absent or null preview and a nullable transport value for
the count while normalizing the display count safely.

Board cards place the preview below the title as plain text and clamp it to
approximately three lines. A subtle count label uses singular/plural wording
and remains visible when the preview is empty if count metadata is present.

List rows keep their compact layout. The count appears with date metadata, and
the optional preview appears beneath the title with a one-line clamp.

Null, empty, or whitespace-only preview content produces no preview block and
no placeholder. The preview is never interpreted as Markdown or HTML.

## Detail-panel classed assignments

The detail panel groups canonical notebook assignments using the current class
catalog:

1. the `folder` class, labeled `Folder`;
2. named non-folder classes ordered by localized, case-insensitive class label
   with stable `classId` tie-breaking; and
3. classless assignments under `Tags`.

Only groups with assignments render as chip sections. Tags within a group use
the deterministic name ordering already used for tag navigation. Each chip
shows the tag name. A remove control renders only when the assignment's
`deletable` value is true; the server remains authoritative and mutation
rejection preserves the last canonical membership.

Folder membership keeps its existing dedicated picker. The general add-tag
flow first chooses a non-folder named class or the classless Tags group, then
chooses an existing unassigned tag from that group. An empty group disables the
tag picker and explains that no assignable tags are available. The chosen name
must still exist in the current tag catalog and match the selected class at
submit time; otherwise the client refreshes the catalog and rejects the stale
selection without calling `applyNotebookTags`.

Membership operations reuse `membershipBusy` and the existing notebook
selection/generation checks. A completion for a previously selected notebook
cannot replace the current detail state. Success replaces membership with the
canonical mutation result and refreshes scoped membership; failure leaves the
last canonical result visible and exposes retryable feedback.

## Folder and Tags navigation

The left pane begins on the existing `Folder` tab. The `Tags` tab excludes the
folder class and renders:

- each named non-folder class as a collapsible group labeled with its class
  label and tag count; and
- classless tags as a final `Tags` group.

Named class groups are ordered by localized, case-insensitive label and stable
`classId`. The classless group is always last. Empty named classes may be
omitted from navigation; the class catalog remains available to the detail
picker.

For each named class, tree construction considers only tags with that
`classId`. Parent links are followed only when the parent is in the same class.
A missing or cross-class parent makes the tag a root, and cycle protection
keeps malformed legacy data reachable without unbounded recursion. Siblings use
deterministic name and `tagId` ordering. Classless tags render as a flat group;
their parent links do not imply a cross-class navigation tree.

The generalized tree builder must preserve the existing Folder tree behavior
when invoked for the folder class.

## Scope state and data flow

Folder and tag navigation share one active scope:

- selecting a folder stores that folder and clears any selected non-folder tag;
- selecting a tag stores that tag and clears any selected folder;
- selecting `All notebooks` clears both; and
- switching tabs alone does not silently change the active scope.

Both List and Board read the same scoped notebook resource. A selected tag sends
exactly `tagFilter: [tagName]`; the client does not expand descendants. Folder
selection keeps the same one-name request contract.

Tag scope changes must use the same generation-bump boundary as
`beginFolderScope`. Every folder-to-tag, tag-to-folder, tag-to-tag, and
scope-to-all transition invalidates older list, pagination, catch, and finally
completions. A stale request cannot replace data, loading state, or error state
for a newer scope.

The breadcrumb is derived from tag IDs and parent IDs rather than parsing tag
names. Folder scope keeps its current breadcrumb. Named-class tag scope begins
with the class label followed by reachable ancestors and the selected tag.
Classless scope begins with `Tags` followed by the selected tag. Missing or
cyclic ancestors terminate safely. If a catalog refresh removes the selected
tag, the active scope clears and notebooks reload unfiltered.

## Validation and failure behavior

- An add-tag mutation is unavailable until a class/group and an existing,
  unassigned tag are selected.
- A tag selected from stale catalog state is rejected before mutation.
- `deletable: false` assignments never expose a remove action.
- GraphQL transport, envelope, and rejected-result errors remain distinguishable
  and do not discard the last successful notebook or membership state.
- Missing tag-class metadata places an assignment in the classless fallback
  only when its `classId` is absent; an unknown non-null `classId` remains
  visibly grouped under a stable fallback label rather than being silently
  treated as classless.
- Tabs, collapsible groups, trees, chips, pickers, cards, and rows remain
  keyboard reachable and labeled.
- Production source must satisfy `web/scripts/audit-source.ts`; browser fixtures
  stay in `web/e2e/dashboard.spec.ts`.

## Verification and rollout

Required web verification:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
cd web && bun run test:e2e
```

Coverage must include:

- additive notebook query selections;
- class-scoped hierarchy construction, cross-class parent fallback,
  deterministic class ordering, and classless-last grouping;
- folder/tag mutual exclusion and stale-completion rejection across rapid
  scope switches;
- Board and List preview/count rendering, including preview omission;
- grouped detail chips, protected assignments, existing-tag add, and removal;
- Tags-tab scope variables, breadcrumb, descendant delegation, and clearing or
  replacing folder scope; and
- `fixture.assertClean()` after each affected Playwright scenario.

Required backend regression verification:

```bash
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaAppSupportTests
```

Before handoff:

```bash
git diff --check
git status --short --branch
git log -1 --oneline
```

The pre-existing `DaemonWorkflowNodePatchTests` event-source-restart flake is
excluded. An occasional agent-VM interleaved-submit failure is also unrelated
unless evidence ties it to this change. Record any observed failure rather than
misattributing it.

Implementation and documentation must be committed on
`feat/riela-note-web-tags-and-card-preview`. Nothing is pushed to `main`.

## Issue-to-design mapping

| Intake acceptance signal | Design section |
|---|---|
| Card and row preview/count; empty omission | Notebook preview behavior |
| Grouped all-class chips; protected removal; existing-tag add | Detail-panel classed assignments |
| Folder/Tags tabs; hierarchy; descendant scope; breadcrumb | Folder and Tags navigation; Scope state and data flow |
| Selection and request race safety | Scope state and data flow; Validation and failure behavior |
| Unit/e2e coverage and clean fixture accounting | Verification and rollout |
| Bun and filtered Swift suites | Verification and rollout |
| One committed work package; no unrelated changes or push | Scope and boundaries; Verification and rollout |

## Intentional divergences

- No Codex-agent or Cursor CLI behavior is mapped because no reference input was
  supplied.
- Classless tags are flat in the Tags pane to avoid inventing cross-class tree
  semantics; named class trees remain class-scoped.
- The client delegates descendant expansion to the existing service rather than
  reproducing hierarchy expansion.
- The detail panel permits only catalog selection, not free-text tag creation,
  because `applyNotebookTags` would otherwise create a classless tag.
- Optional classed-tag creation is not required for acceptance.

## Design decision record

Decision: `accepted_for_implementation_planning`.

- The request remains one issue-resolution work package with no feature fanout.
- A dedicated extension spec keeps the accepted base web-notebook design stable
  while making the new grouping, validation, and scope-race contracts explicit.
- No unresolved user decision blocks planning or implementation.
- Adversarial review remains required by intake because the workflow includes
  implementation, external verification commands, and commit behavior, despite
  the supplied `standard` review mode and `normal` risk level.
- No Step 3 or Step 5 feedback was present for this first design pass.
