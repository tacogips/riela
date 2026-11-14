# Design: Wrike-Style Web Notebook View

Status: accepted for implementation

Workflow mode: `issue-resolution`

Issue reference: no GitHub issue URL or repository/number was supplied. The
authoritative issue title is "Wrike-style web notebook view for Riela Note
(folder tree + list/board views + dual-server Note GraphQL)" and the design
ground truth is `design-docs/research/wrike-web-notebook-view-brief.md` at
commit `7006afa`.

Codex-agent references: none supplied.

## Goal

Add one Notes feature to the existing SolidJS web application. The feature
presents notebooks as either a sortable list or a four-column progress board,
uses folder-class tags as an arbitrary-depth navigation tree, and opens a shared
read-only detail panel. The same built SPA must use Note GraphQL from either:

1. RielaApp's existing authenticated, CSRF-protected local web server; or
2. `riela serve --note-api`, hosted on the same origin and authenticated through
   the existing one-time `/note/register` bearer-registration flow.

The feature is one work package. Its frontend, RielaApp routing, CLI serving,
tests, documentation refresh, and commit are not independent feature branches.

## Scope and boundaries

### In scope

- A `Notes` item in `web/src/App.tsx`.
- A left Notes pane whose default and only required tab is `Folder`.
- An arbitrary-depth folder tree built from `tags` and `parentTagId`.
- Root and child folder creation through `defineNoteTag`.
- Folder-scoped notebook reads using the selected folder name as `tagFilter`;
  the service remains responsible for descendant expansion.
- List and Board tabs, supported notebook sorting, and folder-scoped content in
  both views.
- A shared notebook detail panel with folder membership controls and paged,
  read-only note previews.
- Optimistic progress drag with per-notebook newer-wins persistence.
- Real Note GraphQL execution through RielaApp and `riela serve`.
- Configurable static hosting for the built SPA in `riela serve`, including safe
  MIME handling and SPA navigation fallback.
- Unit, integration, and existing-harness browser coverage.

### Out of scope

- Gantt, Table, Calendar, custom fields, pinned items, spaces, dashboards, WIP
  limits, swimlanes, or folder-tree drag/reordering.
- Creating, editing, or deleting notes in the web application.
- Creating, renaming, deleting, reparenting, or clearing the parent of existing
  tags. The only folder mutation is creation with an optional initial parent.
- Notebook rename/delete UI, offline behavior, CORS, or a parallel REST API for
  note content.
- Replacing either server's existing authentication model.

## Existing contracts retained

The implementation consumes the additive schema in `Sources/RielaGraphQL/`:

| Web behavior | GraphQL contract |
|---|---|
| Folder tree | `tags`, `tagClasses`, `NoteTag.classId`, `NoteTag.parentTagId` |
| Folder scope | `notebooks(tagFilter: [folderName])` |
| Sort | `NoteListSort`: `updatedAtDesc`, `title`, `createdAtDesc`, `createdAtAsc` |
| Notebook detail | `notebook(notebookId:)` |
| Read-only preview | `notes(notebookId:, limit:, offset:)` |
| Create folder | `defineNoteTag(input:{name,classId,parentTagId,createOnly:true})` |
| Add folder chip | `applyNotebookTags(input:{notebookId,tags})` |
| Remove folder chip | `removeNotebookTag(notebookId:tagName:)` |
| Move board card | `setNotebookProgress(notebookId:progress:)` |

Every `notebooks` and `notes` request uses a `limit` in `0...200`; the client
never depends on server clamping. List and preview pagination use `limit: 200`
and explicit offsets. Board data is assembled from successive bounded pages
before final column counts are presented; a loading count remains visible while
more pages are being read.

`folder` remains a tag class, not filesystem containment or ownership. A
notebook with several folder-class assignments is one canonical notebook shown
in several folder scopes.

Folder creation additively extends `DefineNoteTagInput` with optional
`createOnly: Boolean`. Omitting it or passing `false` preserves the existing
upsert contract for all current callers. When `true`, `NoteService.defineTag`
checks for an existing normalized name inside the same database transaction and
returns `result.accepted: false`, status `invalid_request`, without changing the
existing row. The check applies to system and non-system tags and runs before
class or parent updates. This is a precondition on the existing mutation, not a
new rename/delete API.

## Frontend behavior

### Host-mode bootstrap

The SPA has one typed transport layer with two explicit modes:

- **RielaApp mode:** `GET /api/v1/bootstrap` succeeds. Existing application
  navigation remains available, and Note GraphQL POSTs include
  `Content-Type: application/json`, `X-Riela-CSRF` from bootstrap, same-origin
  credentials, and the existing exact Origin/Host behavior.
- **CLI serve mode:** `/api/v1/bootstrap` returns 404 while the static SPA and
  `/overview` are available. The shell presents Notes as the available product
  surface. GraphQL POSTs include `Content-Type: application/json` and
  `Authorization: Bearer <registered-token>`.

Mode discovery is same-origin and does not infer mode from port numbers. A
network failure is not treated as CLI mode; it remains a connection error.

In CLI mode, the operator opens the registration URL printed by `riela serve`.
When static hosting is enabled, `GET /note/register?code=...` loads the SPA
bootstrap surface; `POST /note/register` remains the existing credential
redemption endpoint. The client reads the one-time code, removes it from the
visible URL with `history.replaceState`, redeems it with display name
`Riela Web`, and stores the bearer only in `sessionStorage`. It does not use a
cookie or persistent `localStorage`. A missing credential shows instructions to
open the current process's registration URL. A 401 clears the session
credential and returns to that state.

### Folder pane

The client finds the seeded tag class whose `classId` is `folder`, then keeps
only tags assigned to that class. Tree construction is deterministic:

- siblings sort by localized, case-insensitive name and then stable `tagId`;
- a missing/non-folder parent makes the node a root so corrupted legacy data
  remains reachable;
- a visited set prevents malformed cycles from recursing forever even though
  service validation rejects new self/ancestor cycles;
- expanded node IDs and selected folder ID are client UI state.

Each row has a chevron only when it has children, a folder icon, name, and
selected state. Chevron activation does not select the folder. Keyboard focus,
expanded state, and the tree/treeitem roles remain explicit.

Selecting a folder passes exactly its tag name as the sole `tagFilter`. Because
the service expands descendants, the result includes notebooks tagged with the
selected folder or any transitive child. Selecting the pane root clears the
filter and shows all notebooks. The breadcrumb follows parent IDs, not string
path parsing.

Folder creation collects a trimmed, non-empty name and an optional selected
parent. Before enabling submit, the client compares the candidate with every
tag's exact trimmed name. A known collision is rejected locally, including an
existing folder at the same parent, and identifies whether the existing name
belongs to a folder or another tag class.

Creation calls `defineNoteTag` with the seeded folder `classId`, the parent's
`tagId`, and `createOnly: true`; a root folder omits `parentTagId`. The atomic
create-only precondition remains authoritative if another process creates the
same name after the client check. A collision returns a rejected mutation,
changes no existing tag, refreshes the tags query, and asks the user for another
name. On success the returned tag must have the requested folder class and
parent, parent nodes expand to reveal it, and the new node may be selected.
Other server validation errors are shown inline. There are no rename, delete,
move, or clear-parent affordances.

### Content header and sorting

The content header contains the breadcrumb, `List | Board` tab strip, refresh,
and the sort control. The supported sort choices map directly to
`updatedAtDesc` (default), `title`, `createdAtDesc`, and `createdAtAsc`.
Progress/status sorting is intentionally absent because `NoteListSort` does not
provide it; Board groups by progress instead.

The selected view and sort are retained while navigating folders during the
current SPA session. Both feed the same scoped notebook resource so switching
views does not silently change membership.

### List view

Each row shows title, progress, folder-class chips, and `updatedAt`. A row click
opens the detail panel; keyboard activation has the same behavior. Empty,
loading, partial-page, error, and retry states are distinct. Paging never
requests more than 200 records.

### Board view

The Board always renders columns in this order:
`none`, `progress`, `done`, `pending`. Headers show labels and counts. Cards show
title, folder chips, and updated time. Empty columns remain visible.

Native HTML drag events provide pointer drag behavior. Each card is also
keyboard movable through an accessible progress control so drag is not the only
way to change progress. Dropping in the current column is a no-op.

### Detail panel and folder membership

The same right-side panel opens from List and Board. It shows title, current
progress, timestamps, folder chips, an add-folder picker, and read-only notes.
The picker excludes folders already assigned. Because these are direct user
actions, applying a folder sends its tag name through `applyNotebookTags` with
`provenance: "human"` and `assignedBy: "riela-web"`. Removing a chip sends its
tag name through `removeNotebookTag` with `provenance: "human"`. The client must
not rely on `applyNotebookTags`'s `"ai"` default. A remove control appears only
for an assignment the schema marks deletable.

Successful mutations replace the affected notebook with the canonical mutation
result, refresh scoped membership, and refresh the picker. If removing a folder
makes the notebook leave the selected scope, the row/card disappears and the
panel closes with a non-destructive status message. Mutation failure preserves
the last canonical membership and exposes retryable feedback.

Notes are fetched by `notebookId`, displayed as sanitized text/Markdown output,
and never expose edit controls. Preview paging is explicit and bounded to 200
items per request.

## Optimistic progress convergence

Progress mutation state lives in a Notes data controller keyed by `notebookId`,
not in a Board component instance. It therefore survives a change of folder,
view, selection, or panel state.

For each notebook the controller records:

- the latest desired progress;
- a monotonically increasing local generation;
- whether a write is in flight; and
- the last canonical notebook returned by the service.

A drag updates the visible desired progress immediately and increments the
generation. Writes for one notebook are serialized. When a write finishes, the
controller compares the completed value with the latest desired value:

- if they match and the generation is current, the canonical response becomes
  visible;
- if a newer desired value exists, the stale completion cannot overwrite the
  UI and the controller sends the newest value, even when Board is no longer
  mounted or the notebook is outside the current folder;
- if the current write fails, the controller reads the canonical notebook,
  preserves any newer intent that arrived during reconciliation, and either
  replays that intent or shows the canonical value with an error.

Scoped refreshes and pagination results carry resource generations and cannot
replace newer membership or per-notebook optimistic progress. This is the
required newer-wins database convergence rule, not only a visual optimism rule.

## RielaApp GraphQL composition

`Sources/RielaApp/RielaAppWebRouter.swift` continues to own the outer web
security gate. POST `/graphql` must pass its existing exact Host, Origin, CSRF,
and JSON content-type checks before GraphQL parsing or execution.

The RielaApp composition root creates a
`NoteService(SQLiteNoteDatabaseDriver(noteRoot:))` for the same active-profile
root returned by `noteRootURL(profileName:)`, wraps it in
`NoteGraphQLDocumentExecutor`, and injects the executor into the deterministic
GraphQL route. The inner deterministic handler may allow note operations
without its bearer authenticator only for this RielaApp composition, because
the outer router has already authenticated the local web session with CSRF.
This exception is not enabled in `riela serve`.

Changing the active RielaApp profile must rebuild or refresh the executor before
serving the new profile's Notes data. The router must never mix the web
bootstrap profile with a different note root. Executor construction failure
leaves non-Note web routes available and returns a sanitized Note GraphQL
service error without revealing filesystem or SQLite details.

The old schema-echo response is retained only for GraphQL operations not handled
by an injected executor; Note operations must execute against the real service.

## `riela serve` static hosting and authentication

`Sources/RielaCLI/ServeHTTPCommand.swift` adds an optional `--web-root <path>`.
When supplied, the path must resolve to a readable directory containing
`index.html`; invalid roots fail startup before listener readiness. A
repository-development invocation may use `web/dist` explicitly. Omitting
`--web-root` preserves the current headless server behavior.

The CLI composes the existing deterministic routes and
`RielaStaticAssetResolver` so that:

- `/graphql`, `/healthz`, `/overview`, and POST `/note/register` retain service
  precedence;
- GET `/note/register` is an SPA bootstrap navigation only when static hosting
  is enabled;
- exact static files use the resolver's MIME mapping;
- missing files with extensions return 404;
- extensionless frontend routes may fall back to `index.html`;
- API/service prefixes never fall through to HTML, except the explicit GET
  registration bootstrap;
- standardized paths, encoded traversal, NULs, and symlink escapes cannot leave
  the configured root.

The existing `--note-api`, `--note-root`, one-time registration challenge,
bearer authentication, token redaction, and loopback defaults remain
authoritative. Static hosting adds no CORS headers and no alternative
credential. Startup output continues to print the registration URL and also
reports the effective web root when enabled.

## Failure and accessibility behavior

- GraphQL network, HTTP, GraphQL-envelope, and `result.accepted == false`
  failures are distinguishable and displayed without discarding the last
  successful content.
- Unauthorized CLI GraphQL clears only the browser session credential; it does
  not revoke other registered clients.
- A missing folder class disables creation and shows a repair-oriented message;
  it does not create another class automatically.
- A missing/deleted selected folder clears the selection after a tag refresh.
- Detail and folder mutations disable only the affected control, not the entire
  view.
- Tree rows, tabs, list rows, progress controls, picker, chips, close action,
  loading states, and mutation messages are keyboard reachable and labeled.
- The panel traps no focus permanently; closing it returns focus to the
  activating row/card when that item remains in scope.

## Verification and rollout

Required frontend verification:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
```

Frontend tests cover tree construction, orphan/cycle tolerance, folder scope
variables, supported sorting, bounded paging, duplicate folder-name rejection
without a `defineNoteTag` call, `createOnly: true` mutation variables, atomic
collision feedback, returned-folder validation, explicit `human` provenance for
folder add/remove, folder picker/chip mutations, host-mode authentication
headers, and per-notebook newer-wins progress convergence after view/folder
changes. Existing Playwright infrastructure is used for Notes navigation,
List/Board switching, folder scoping, detail opening, and accessible progress
movement when it can do so without new production fixtures or fetch overrides.

Required Swift verification:

```bash
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
```

Swift tests cover default `defineNoteTag` upsert compatibility, atomic
`createOnly: true` rejection with the existing tag class/parent unchanged,
GraphQL input decoding/projection for the optional field, authenticated and
rejected RielaApp GraphQL requests, active note-root execution, CLI option
parsing, invalid web roots, static MIME and index behavior, traversal/symlink
rejection, GET registration bootstrap versus POST redemption precedence,
bearer-protected GraphQL, and unchanged headless serve behavior.

Before handoff:

```bash
git diff --check
git status --short --branch
```

All implementation and documentation changes are committed on
`feat/riela-note-web-notebook-view`. Nothing is pushed and no pull request is
opened. Known unrelated flakes remain
`DaemonWorkflowNodePatchTests` event-source restart and the agent-VM
interleaved-submit test; any observed failure must be recorded with evidence
rather than silently ignored.

## Issue-to-design mapping

| Intake acceptance signal | Design section |
|---|---|
| Folder tree, descendant scope, create folder | Frontend behavior / Folder pane |
| List rows, sort, detail, chips, preview | Content header, List view, Detail panel |
| Board columns/counts and newer-wins drag | Board view, Optimistic progress convergence |
| List/Board preserved under folder scope | Content header and sorting |
| Authenticated RielaApp Note GraphQL | RielaApp GraphQL composition |
| Same-origin CLI SPA and bearer registration | Host-mode bootstrap, `riela serve` static hosting |
| Bun and Swift verification | Verification and rollout |
| One committed work package, no push/PR | Scope and boundaries, Verification and rollout |

## Intentional divergences

- No Codex-agent behavior is mapped because no Codex-agent reference was
  supplied.
- The Wrike reference's status sort is not exposed because the accepted
  `NoteListSort` contract has no status sort. Board progress grouping covers
  that organization without adding schema scope.
- The Wrike reference's folder reorder, rename, delete, and multi-view set are
  omitted by the accepted OUT list.
- `DefineNoteTagInput.createOnly` is an additive safety precondition used by the
  web create affordance; existing callers retain upsert behavior when it is
  omitted.
- CLI browser credentials are session-scoped instead of persistently stored;
  this minimizes bearer exposure while reusing the existing registration
  protocol.

## Design decision record

Decision: accepted for implementation planning.

- The authoritative research brief was preserved unchanged and promoted into
  an executable behavioral contract here.
- One dedicated spec is warranted because the feature crosses frontend state,
  two server compositions, authentication, static serving, and race
  convergence.
- No unresolved user decision remains. Exact type/module placement and test
  file selection are implementation-plan concerns.
- Step 2 self-review mid finding, corrected: duplicate folder names are rejected
  in the client and atomically by `DefineNoteTagInput.createOnly`, so neither a
  known collision nor a cross-process race can reclassify or reparent an
  existing tag. The optional field preserves current upsert callers.
- Step 2 self-review mid finding, corrected: direct folder membership actions
  explicitly use `human` provenance, and additions record
  `assignedBy: "riela-web"` rather than accepting the mutation's `"ai"` default.
- No Step 3 or Step 5 review feedback was present for this pass.
