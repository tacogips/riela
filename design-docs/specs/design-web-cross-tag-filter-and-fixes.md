# Design: Web Notes Cross-Tag Filter and Required Fixes

Status: accepted for implementation planning

Workflow mode: `issue-resolution`

Issue reference: no GitHub issue URL, repository, or issue number was supplied.
The authoritative issue title is "Web Notes cross-tag (AND) filter via
tagFilterGroups + Required-tier web fixes F1–F12 (one work package)".
Current intake references are `comm-001635` and
`codex-design-and-implement-review-loop-session-638`. The accepted design was
produced by `comm-001623`,
`codex-design-and-implement-review-loop-session-636`, and source workflow
`fable-and-improve-session-635`. The design ground truth is
`design-docs/research/web-cross-tag-filter-and-fixes-brief.md`.

Codex-agent references: none supplied.

Review mode: `standard`; adversarial review remains required by the workflow.
The implementation-review decision is pending.

## Goal

Extend the accepted web Notes behavior in
`design-docs/specs/design-web-tags-and-card-preview.md` as one indivisible work
package:

1. add an additive grouped notebook filter whose groups are intersected while
   names within each group are unioned after descendant expansion;
2. let the SolidJS List and Board share an ordered, multi-chip filter; and
3. resolve required findings F1, F2, F3, F4, F6, F7, F9, F10, F11, and F12.

Findings F5, F8, and F14 are stretch work and must be skipped if they threaten
convergence. The fixed four-state progress palette and List view remain.

## Scope and boundaries

### In scope

- `Sources/RielaNote/NoteService.swift`: grouped notebook filtering for every
  notebook-list/count path that currently uses descendant-expanded tag filters.
- `Sources/RielaGraphQL/GraphQLContracts.swift`: additive
  `tagFilterGroups: [[String!]!]` schema declaration.
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` and
  `Sources/RielaGraphQL/NoteGraphQLService.swift`: nested-variable validation,
  request dispatch, and service forwarding.
- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift` and
  `Sources/RielaCLI/NoteCommands.swift`: one consumed notebook-list document
  with compatible flat and grouped variables.
- `web/src/notes/controller.ts`: ordered multi-constraint filter state,
  reconciliation, snapshots, and generation guards.
- `web/src/notes/types.ts`: typed unknown-progress presentation metadata.
- `web/src/notes/client.ts` and `web/src/notes/paging.ts`: grouped variables,
  one page-size contract, bounded paging, deduplication, and forward-progress
  failure.
- `web/src/views/NotesView.tsx`: filter chips, shared List/Board membership,
  mutation and preview race fixes, focus recovery, and unknown-progress
  presentation.
- `web/src/styles.css`: filter-chip, add-action, retained-loading, focus, and
  unknown-progress presentation states.
- Focused tests in `Tests/RielaNoteTests/`,
  `Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
  `Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift`,
  `Tests/RielaGraphQLTests/NoteGraphQLDocumentParsingRegressionTests.swift`,
  `Tests/RielaCLITests/NoteCommandTests.swift`,
  `web/src/notes/*.test.ts`, and the existing mocked
  `web/e2e/dashboard.spec.ts`.

### Out of scope

- Changes to note filtering, search filtering, macOS Notes UI, or unrelated
  GraphQL surfaces.
- CORS, alternate authentication, or changes to the same-origin bearer model.
- Live-browser automation or browser launch in this workflow.
- New progress states, removal of List view, or redesign of the fixed Board
  columns.
- Independent branches for the server, GraphQL, frontend, or required
  findings; `has_feature_fanout` remains false.

## Grouped notebook-filter contract

`listNotebooks` and the GraphQL `notebooks` field add
`tagFilterGroups: [[String!]!]` while retaining `tagFilter: [String!]`.
Normalization is deterministic:

1. discard empty inner arrays from `tagFilterGroups`;
2. when at least one non-empty group remains, use those groups and ignore
   `tagFilter`;
3. otherwise, use non-empty `tagFilter` as one group; and
4. when neither input contributes a group, return the unfiltered notebook set.

Each non-empty group is expanded independently through the existing
`expandedTagFilterNames` hierarchy rule. Names within one expanded group are a
union. A notebook must satisfy one parameterized `EXISTS` membership predicate
for every expanded group, so groups are joined with logical `AND`.

If any non-empty input group expands to no known tag names, the result is
immediately `[]`. This fail-closed rule distinguishes an unknown requested tag
from the absence of a filter.

The primary notebook query and any secondary notebook count/enrichment query
must consume the same normalized expanded-group representation. They must not
independently reinterpret precedence, empty groups, descendant expansion, or
predicate joining.

The change is additive. Existing callers that only send `tagFilter` retain
single-group union behavior, including descendant expansion. Clients may send
more than one name in an inner group; the web client sends exactly one tag name
per chip.

The grouped boundary is resource-bounded before hierarchy expansion: at most
64 outer groups and 256 total input names. Names and equivalent groups are
canonicalized and deduplicated, expansion returns immediately when the first
requested group is unknown, and grouped expansions above 900 total names are
rejected. Bound failures use `NoteServiceError.invalidInput`, which GraphQL
projects as a controlled `invalid_request`; legacy flat `tagFilter` behavior
and limits remain unchanged.

## GraphQL and CLI boundary

`Sources/RielaGraphQL/GraphQLContracts.swift` declares the additive grouped
argument without changing the existing argument or response shape. It does not
decode variables.

`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` owns executable
variable handling. Its `notebooks` dispatch must:

1. distinguish an omitted or null `tagFilterGroups` from a supplied array;
2. accept only an outer array whose values are inner arrays containing only
   strings;
3. reject scalar outer values, scalar inner values, and non-string members
   through the existing public GraphQL variable-error path; and
4. forward the decoded `[[String]]` with the existing flat `tagFilter` to
   `NoteGraphQLService.notebooks`.

`NoteGraphQLService.notebooks` forwards both inputs to
`NoteService.listNotebooks`, where precedence, empty-array normalization,
descendant expansion, and AND-of-union semantics are applied once. Neither the
document executor nor service wrapper may silently convert a malformed grouped
value into an unfiltered request.

The web `Notebooks` operation declares and submits `$tagFilterGroups` alongside
the existing `$tagFilter` compatibility variable. New web requests use grouped
variables; legacy documents remain valid.

The notebook-list operation currently embedded in
`Sources/RielaCLI/NoteCommands.swift` moves to one
`NoteCommandGraphQLDocuments.notebooks` document. That document declares
optional `$tagFilterGroups: [[String!]!]` and forwards it to
`notebooks(tagFilterGroups:)` with the existing `$tagFilter`, pagination, and
projection.

`NoteCommands.swift` must execute that shared document instead of retaining an
inline copy. Existing `riela note notebook list --tag ...` behavior continues
to populate only `tagFilter`; `tagFilterGroups` is omitted and no new CLI
option is added. This exercises the additive grouped document shape without
changing CLI filtering semantics or producing an unused document. Focused CLI
tests verify both that the command consumes the shared document and that
legacy `--tag` results remain unchanged. No Cursor CLI or Codex-agent adapter
behavior is involved.

## Web filter state and reconciliation

The active filter is an ordered set of constraints. Each constraint carries
`tagId`, canonical `tagName`, `kind` (`folder` or `tag`), and optional
`classId`. No constraints means `All notebooks`.

The controller provides these transitions:

- plain folder/tag activation replaces all constraints with that one item;
- every folder/tag navigation row has a separately focusable `Add to filter`
  action whose accessible name includes the tag name; activating it appends a
  constraint without triggering the row's plain-click replacement;
- the add action remains visible but disabled when that `tagId` is already an
  active constraint;
- removing a chip removes only that constraint;
- clear-all removes every constraint; and
- adding an already active tag is a no-op rather than a duplicate group.

Each state change bumps one filter generation. A snapshot contains the full
ordered constraint set and generation. List loading, partial pages, errors, and
final loading state may update the view only while that snapshot remains
current. `tagFilterGroups()` maps the snapshot to one `[tagName]` group per
constraint.

Catalog refresh reconciles constraints independently by stable `tagId`:

- update names, class IDs, and folder/tag classification from canonical catalog
  data;
- retain the existing order;
- remove only constraints whose tags no longer exist;
- deduplicate by `tagId`; and
- become `All notebooks` only when no constraints remain.

A sole constraint retains the existing ancestry breadcrumb. With multiple
constraints, the header reads `Filtered notebooks`; the chip bar is the
authoritative expression and each chip identifies its folder/tag. Left-pane
rows indicate every active constraint, while keyboard focus remains singular.
This avoids presenting multiple unrelated hierarchies as one false breadcrumb.

The chip bar appears above both List and Board, exposes a labeled remove action
per chip, and exposes clear-all whenever at least one chip exists. List and
Board read the same retained `notebooks()` signal and never implement separate
membership rules.

## Required finding resolutions

### F1: retain Board state during refresh

Board columns remain mounted while refresh, sort, paging, or membership
reconciliation runs. They render the last accepted `notebooks()` state and show
a non-destructive `Counts updating…` status until the current generation
finishes. A refresh must not cancel an in-progress drag by unmounting the
Board.

### F2 and F3: membership mutation correctness

Removing a tag clears retained membership before re-page only when the removal
can affect an active constraint:

- it exactly matches an active non-folder tag constraint; or
- the removed assignment belongs to the folder class while any folder
  constraint is active, because descendant membership may change.

Other removals keep the current List/Board visible during canonical refresh.

Only one membership add or removal may run at a time across the detail panel.
`membershipBusy` retains the affected tag key for spinner placement, while all
add and remove controls are disabled until the operation settles. A stale
completion cannot update a newly selected notebook or filter generation.

### F4: preview generation

Notebook selection and detail close each bump a preview generation. Initial
preview loads and load-more operations capture both notebook ID and generation
and check them after every await before replacing, appending, advancing offset,
or changing loading/error state. Closing and reopening the same notebook
therefore rejects the older completion.

### F6 and F7: deterministic focus and activator lifetime

If a successful removal ejects the selected notebook, the detail closes and
focus moves to the first surviving notebook activator. If none remains, focus
moves to clear-all when present, otherwise to the focusable content heading.

Notebook activator references are removed when their row/card is disposed and
are pruned against the accepted notebook IDs after refresh. Detached DOM nodes
must not remain in `notebookActivators`.

### F9 and F10: bounded paging

One exported notebook page-size constant, value `200`, is shared by
`web/src/notes/client.ts`, `web/src/notes/paging.ts`, and
`web/src/views/NotesView.tsx`. Completion compares the received page length
with the actual requested limit.

Paging advances by the received page length, deduplicates by notebook ID, and
stops normally on a short page. A full page that contributes zero new IDs is a
forward-progress failure. A hard cap of 1,000 pages prevents an endlessly
changing or offset-ignoring server from running forever. Either guard retains
accepted partial data, stops requesting pages, and exposes a retryable partial
load error.

### F11: unknown progress

At the `web/src/notes/client.ts` decode boundary, any progress value outside
`none`, `progress`, `done`, and `pending` is normalized to `none` for Board
partitioning. `web/src/notes/types.ts` adds the non-optional presentation field
`progressWasUnknown: boolean` to `Notebook`. A valid decoded progress sets it
to `false`; an unknown value sets `progress: 'none'` and
`progressWasUnknown: true`.

Every notebook-producing query or mutation response passes through the same
normalizer. A later canonical read or mutation clears the marker only when its
returned progress is one of the four supported values. List rows and Board
cards show `Unknown status · shown in None` while the marker is true. No
notebook disappears from Board columns because of an unrecognized server
value.

### F12: folder creation scope

Creating a child folder auto-enters it only when the pre-mutation filter has
exactly one constraint, that constraint is the parent folder, and its `tagId`
equals `parentTagId`. Root creation, All notebooks, tag scope, and
multi-constraint filters retain their current filter.

## Validation and failure behavior

- Constraint identity uses `tagId`; query values use reconciled `tagName`.
- Empty inner groups are not emitted by the web client.
- Unknown non-empty server groups fail closed with `[]`.
- GraphQL nested-array type errors return the existing document-executor
  variable-error response and do not call `NoteGraphQLService.notebooks`.
- Group predicates remain parameterized; tag names are never interpolated into
  SQL.
- A grouped-filter failure preserves the last accepted List/Board state and
  exposes retryable feedback for the current generation.
- Generation checks cover success, catch, and finally paths.
- Same-origin Host, Origin, CSRF, JSON, and bearer protections are unchanged.

## Verification and rollout

Required web verification:

```bash
cd web && bun test src
cd web && bun run typecheck
cd web && bun run lint
cd web && bun run build
```

Required focused backend verification:

```bash
swift build
swift test --filter NoteServiceTests
swift test --filter NoteHierarchyProgressTests
swift test --filter NoteGraphQLTests
swift test --filter NoteGraphQLHierarchyProgressTests
swift test --filter NoteGraphQLParsingRegressionTests
swift test --filter NoteCommandTests
```

The focused Swift set may be narrowed after new grouped-filter test names are
known, but must retain coverage for AND across classes, folder descendant
expansion, unknown-group empty results, legacy `tagFilter`, nested GraphQL
variables, and schema text.

`web/src/notes/controller.test.ts`, `web/src/notes/client.test.ts`, and
`web/src/notes/paging.test.ts` cover controller transitions, query variables,
generation safety, page-size ownership, zero-progress termination, and the
page cap. Client tests also cover valid and unknown progress normalization and
marker clearing. Extend, rather than duplicate, `web/e2e/dashboard.spec.ts`
with a mocked grouped-filter scenario that asserts request variables, the
keyboard-accessible add action, and that both List and Board show only the
intersection.

No browser may be launched by this workflow. Because mocked Playwright still
starts a browser process, authoring `web/e2e/dashboard.spec.ts` is in scope but
its execution remains an explicit operator-owned verification gap. The
operator runs:

```bash
cd web && bun run test:e2e -- dashboard.spec.ts
```

Operator verification also remains required out of band for live List
behavior, Board/Kanban rendering, drag-and-drop persistence, cross-tag widening
after one-chip removal, and clear-all.

Before implementation handoff:

```bash
git diff --check
git status --short --branch
```

Implementation, review, documentation refresh, and any workflow-authorized
commit/push behavior remain on `feat/riela-note-web-cross-tag-filter`.

## Issue-to-design mapping

| Intake acceptance signal or finding | Design section |
|---|---|
| AND across groups; union and descendant expansion within groups | Grouped notebook-filter contract |
| `tagFilter` compatibility, precedence, and empty-group rules | Grouped notebook-filter contract |
| Nested GraphQL schema, executor validation/dispatch, and consumed CLI document shape | GraphQL and CLI boundary |
| Multi-chip List/Board filter and clear-all | Web filter state and reconciliation |
| Partial catalog deletion and single-scope parity | Web filter state and reconciliation |
| F1 | Required finding resolutions: retain Board state |
| F2, F3 | Required finding resolutions: membership mutation correctness |
| F4 | Required finding resolutions: preview generation |
| F6, F7 | Required finding resolutions: focus and activator lifetime |
| F9, F10 | Required finding resolutions: bounded paging |
| F11 and typed marker ownership in `web/src/notes/types.ts` | Required finding resolutions: unknown progress |
| F12 | Required finding resolutions: folder creation scope |
| Bun, Swift, and mocked Playwright evidence | Verification and rollout |
| Operator-only live UX evidence | Verification and rollout |

## Intentional divergences

- No Codex-agent or Cursor CLI behavior mapping exists because no reference
  input was supplied.
- The workflow constraint prohibiting browser launch supersedes the research
  brief's live-browser verification paragraph; that evidence is assigned to
  the operator.
- Multi-constraint state uses `Filtered notebooks` plus authoritative chips
  instead of fabricating one breadcrumb from unrelated tag hierarchies.
- Unknown progress is visibly placed in `none` rather than silently omitted.
- `listNotes(tagFilter:)` is unchanged because this feature filters notebooks,
  not the detail preview.

## Design decision record

Decision: `accepted_for_implementation_planning`.

- Step 2 reuse validation for `comm-001635` confirmed the accepted design
  against branch tip `eaac1c7`; the current service, GraphQL, CLI, controller,
  paging, and Notes view seams still match the documented baseline, so no
  behavioral redesign or user-QA document is required.
- The work remains one issue-resolution package with no feature fanout.
- The accepted research contract is preserved without re-auditing its verified
  non-issues.
- Required findings F1, F2, F3, F4, F6, F7, F9, F10, F11, and F12 have explicit
  behavioral resolutions.
- Self-review findings D1 and D2 are resolved by assigning nested-variable
  decoding to `NoteGraphQLDocumentExecutor.swift` and defining the typed
  `progressWasUnknown` contract in `web/src/notes/types.ts`.
- Self-review finding D3 is resolved by moving the executable notebook-list
  query into `NoteCommandGraphQLDocuments.swift`, consuming it from
  `NoteCommands.swift`, preserving legacy `--tag`, and adding no grouped CLI
  option.
- Step 3 review finding from `comm-001638` is resolved by correcting the
  GraphQL parsing regression verification command to
  `swift test --filter NoteGraphQLParsingRegressionTests`, matching the current
  test class while retaining nested-variable and schema coverage.
- The low-severity self-review feedback is resolved by specifying a labeled,
  keyboard-focusable, disabled-when-active add-to-filter action per navigation
  row and recording mocked Playwright execution as operator-owned.
- Stretch findings F5, F8, and F14 are deferred unless implementation proves
  them convergence-safe.
- No unresolved user decision blocks planning.

## Step 6 implementation evidence

Implementation completed on
`feat/riela-note-web-cross-tag-filter` for review under
`codex-design-and-implement-review-loop-session-638`.

- The Note service, GraphQL executor/service/schema, and shared CLI document
  implement the accepted grouped-filter and legacy compatibility contract.
- The web controller, transport, paging, List/Board UI, and mocked Playwright
  fixture implement ordered constraints and required findings F1, F2, F3, F4,
  F6, F7, F9, F10, F11, and F12. Stretch findings remain deferred.
- Web unit tests (27), typecheck, browser-free e2e typecheck, scoped lint/source
  audit, and production build passed. Focused Note, GraphQL, parsing, and CLI
  suites reported zero failures; Swift build passed.
- The exact repository-wide web lint command remains blocked solely by
  pre-existing excluded `web/verify-live.mjs` global-name diagnostics. The
  helper and the pre-existing `.riela` workflow modification remain untouched.
- No browser was launched. Mocked Playwright execution plus live List, Board,
  drag-and-drop, cross-tag widening, and clear-all QA remain operator-owned.
- Step 6 self-review `comm-001648` found the first F1 implementation published
  partial pages and unmounted an empty Board. The corrected implementation
  retains the last accepted array until final current-generation completion,
  defers final publication while a drag is active, and keeps all Board columns
  mounted during fail-closed membership reconciliation. Mocked delayed-refresh
  and clear-membership regression scenarios were added and browser-free
  typechecked.
- Step 6 test-integrity review `comm-001651` identified an obsolete F12 browser
  expectation, a weakened schema assertion, and missing required-tier and
  boundary regression evidence. The revision restores the complete additive
  schema signature assertion; covers grouped-variable rejection/optionality,
  controller reclassification/deletion, activator cleanup, and mutation
  normalization; and authors deterministic browser scenarios for F3, F4, F6,
  F11, F12, and keyboard-operated filter controls.
- Independent implementation review and the workflow commit decision remain
  pending.
