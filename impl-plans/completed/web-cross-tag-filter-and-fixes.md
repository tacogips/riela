# Web Notes Cross-Tag Filter and Required Fixes Implementation Plan

**Status**: COMPLETED — accepted implementation, adversarial review,
verification, and documentation refresh; final commit delegated to the
workflow commit step
**Workflow Mode**: `issue-resolution`
**Branch**: `feat/riela-note-web-cross-tag-filter`
**Issue References**: "Web Notes cross-tag (AND) filter via
`tagFilterGroups` + Required-tier web fixes F1-F12 (one work package)";
`comm-001635`; `comm-001637`; `comm-001640`; `comm-001651`; `comm-001654`;
`comm-001657`; `comm-001659`; `comm-001663`; `comm-001664`; `comm-001665`;
`comm-001666`; `comm-001667`; `comm-001668`; `comm-001672`;
`comm-001673`; `comm-001675`; `comm-001676`; `comm-001677`;
`codex-design-and-implement-review-loop-session-638`
**Accepted Design Review**: `comm-001641`;
`accepted_for_implementation_planning`, `needs_revision: false`, findings `[]`
**Codex-Agent References**: none supplied
**Created**: 2026-07-27
**Last Updated**: 2026-07-27

---

## Objective

Implement the accepted design as exactly one issue-resolution work package:

- add an additive `tagFilterGroups` notebook contract with AND between groups
  and descendant-expanded union within each group;
- replace the web Notes single scope with an ordered constraint set and expose
  an explicit multi-chip filter shared by List and Board; and
- resolve required findings F1, F2, F3, F4, F6, F7, F9, F10, F11, and F12.

The accepted design is the source of truth. Implementation discoveries may
refine internal placement but must not change filter semantics, add feature
fanout, weaken stale-response protections, or broaden the authentication and
transport surface.

## References and accepted decisions

- Ground-truth intake brief:
  `design-docs/research/web-cross-tag-filter-and-fixes-brief.md`.
- Accepted design:
  `design-docs/specs/design-web-cross-tag-filter-and-fixes.md`.
- Existing web Notes behavior:
  `design-docs/specs/design-web-tags-and-card-preview.md`.
- Step 3 design review:
  `comm-001641`, decision `accepted_for_implementation_planning`, findings
  `[]`, feedback `[]`.
- Issue/workflow references: "Web Notes cross-tag (AND) filter via
  `tagFilterGroups` + Required-tier web fixes F1-F12 (one work package)",
  `comm-001635`, `comm-001637`, `comm-001640`, and
  `codex-design-and-implement-review-loop-session-638`.
- Codex-agent references: none supplied.
- Cursor adapter boundary: none; no Codex-reference or Cursor-reference input
  was supplied.
- User-QA reference: none required because the accepted design records no
  unresolved user decision.
- Accepted divergence: `NoteService.swift` around the historical second
  `expandedTagFilterNames` call filters notes, not notebooks, so
  `listNotes(tagFilter:)` remains unchanged. Any actual secondary notebook
  list/count path found during implementation must reuse the same normalized
  grouped predicate.
- Accepted verification boundary: this workflow may author mocked Playwright
  coverage but must not launch a browser. Mocked Playwright execution and live
  List, Board, Kanban, and cross-tag checks remain operator-owned.

## Scope

### Included

- `NoteService.listNotebooks` grouped-filter normalization, descendant
  expansion, parameterized AND-of-union predicates, compatibility precedence,
  and fail-closed unknown-group handling.
- Additive GraphQL schema, nested variable validation, executor dispatch, and
  service forwarding for `tagFilterGroups`.
- One shared CLI notebooks document that declares both grouped and legacy flat
  variables while retaining the existing `--tag` behavior and adding no CLI
  option.
- Ordered web filter constraints, per-constraint catalog reconciliation,
  grouped request variables, multi-chip UI, and shared List/Board membership.
- Required fixes F1, F2, F3, F4, F6, F7, F9, F10, F11, and F12.
- Focused Swift, Bun, and authored mocked Playwright regression coverage.
- Directly affected documentation review, independent implementation review,
  improvement, verification evidence, and workflow commit handoff.

### Excluded

- `listNotes(tagFilter:)`, note/search filtering, and unrelated GraphQL
  surfaces.
- macOS Notes UI changes, new progress states, Board column redesign, or List
  removal.
- CORS, alternate authentication, bearer-token changes, or new endpoints.
- A new grouped-filter CLI option.
- Live browser launch or Playwright execution by this workflow.
- Stretch findings F5, F8, and F14 unless a later accepted plan revision makes
  them required. They are not scheduled by this plan.
- Independent sub-features, branches, commits, or work packages;
  `has_feature_fanout` remains false.

## Task breakdown

### T0. Preflight, ownership, and contract baseline

**Status**: COMPLETED
**Write scope**: this plan's progress log and
`tmp/web-cross-tag-filter-and-fixes/` only
**Depends on**: accepted Step 3 review `comm-001641`
**Parallelizable**: no

**Tasks**:

- Confirm the branch and classify every existing worktree change. Preserve the
  accepted untracked design and the pre-existing `web/verify-live.mjs`; do not
  review, modify, stage, or remove `web/verify-live.mjs`.
- Preserve the pre-existing
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
  modification without reviewing, reverting, staging, or including it in the
  feature commit.
- Re-read the accepted design and brief without reopening their scope or
  re-auditing the brief's verified non-issues.
- Trace the current notebook list path through `NoteService`,
  `NoteGraphQLService`, `NoteGraphQLDocumentExecutor`, GraphQL contracts, the
  CLI notebook document, web client, paging, controller, and `NotesView`.
- Confirm the second historical `expandedTagFilterNames` call belongs to
  `listNotes` and record that it is outside this work package. Search for any
  separate notebook list/count filter path and record whether one exists.
- Record baseline focused test names, current page-size ownership, GraphQL
  notebook projections, and mocked `dashboard.spec.ts` request fixtures.

**Deliverables**:

- A dated progress entry with owned/unowned changes, traced data flow, selected
  test targets, and any implementation-blocking discrepancy.

**Verification**:

```bash
git status --short --branch --untracked-files=all
test -s design-docs/specs/design-web-cross-tag-filter-and-fixes.md
test -s design-docs/research/web-cross-tag-filter-and-fixes-brief.md
rg -n "listNotebooks|expandedTagFilterNames|notebooks\\(|NotebookScope|tagFilter|loadNotebookPages" Sources/RielaNote Sources/RielaGraphQL Sources/RielaCLI web/src
rg -n "notebooks|tagFilter|progress|installAPI" web/e2e/dashboard.spec.ts
```

### T1. Implement the Note service grouped-filter contract

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaNote/NoteService.swift`
- focused grouped-filter tests under `Tests/RielaNoteTests/`

**Depends on**: T0
**Parallelizable**: yes, with T3 and T4 after T0; write scopes are disjoint

**Tasks**:

- Add `tagFilterGroups: [[String]]` to `listNotebooks` while retaining
  `tagFilter: [String]`.
- Normalize once: discard empty inner groups; prefer remaining grouped input;
  otherwise treat non-empty `tagFilter` as one group; otherwise load
  unfiltered notebooks.
- Before database expansion, reject grouped input above 64 outer groups or 256
  input names, canonicalize and deduplicate names/groups, short-circuit on the
  first empty expansion, and reject grouped expansions above 900 total names
  through `NoteServiceError.invalidInput`. Legacy flat `tagFilter` limits and
  behavior remain unchanged.
- Expand every retained group independently with
  `expandedTagFilterNames`. Return `[]` when a requested non-empty group
  expands to no known names.
- Generate one parameterized notebook-tag `EXISTS` predicate per expanded
  group and join the predicates with `AND`; union names only within the group.
- Reuse one normalized expanded-group representation in every actual
  notebook-list/count path. Do not alter the note-list predicate.
- Preserve created-date filtering, sorting, pagination, metadata enrichment,
  parameter binding, and legacy flat-filter behavior.
- Add focused tests for two-class intersection, union within one group, folder
  descendant expansion, unknown-group empty results, empty-only groups as
  unfiltered, grouped precedence over flat input, and flat-filter
  compatibility.

**Deliverables**:

- A backward-compatible Note service API with deterministic AND-of-union
  filtering and focused service regression coverage.

**Verification**:

```bash
swift test --filter NoteServiceTests
swift test --filter NoteHierarchyProgressTests
```

### T2. Expose grouped filters through GraphQL and the shared CLI document

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift`
- `Sources/RielaCLI/NoteCommands.swift`
- focused tests under `Tests/RielaGraphQLTests/`
- `Tests/RielaCLITests/NoteCommandTests.swift`

**Depends on**: T1
**Parallelizable**: yes, with T3 and T4 after T1; its write scope is disjoint
from both web tasks. GraphQL and CLI changes remain serial within T2.

**Tasks**:

- Add the optional `tagFilterGroups: [[String!]!]` notebooks argument without
  changing the existing `tagFilter` argument or response shape.
- Add nested-array decoding in `NoteGraphQLDocumentExecutor`: omitted/null is
  absent; outer and inner containers must be arrays; every member must be a
  string; malformed values use the existing public variable-error path and
  must not call the service.
- Forward both inputs through `NoteGraphQLService.notebooks` into
  `NoteService.listNotebooks`; keep normalization and precedence in the Note
  service.
- Add `NoteCommandGraphQLDocuments.notebooks` with the flat and grouped
  variables, pagination, and existing projection.
- Replace the inline notebook-list operation in `NoteCommands.swift` with the
  shared document. Continue populating only `tagFilter` from `--tag`; omit
  grouped input and add no CLI flag.
- Add GraphQL schema, document parsing, nested-variable validation/dispatch,
  service forwarding, grouped result, and malformed-input tests.
- Add CLI tests proving the list command consumes the shared document and
  legacy `--tag` behavior remains unchanged.

**Deliverables**:

- An additive, validated GraphQL grouped-filter contract and a consumed shared
  CLI document with no CLI behavior change.

**Verification**:

```bash
swift test --filter NoteGraphQLTests
swift test --filter NoteGraphQLHierarchyProgressTests
swift test --filter NoteGraphQLParsingRegressionTests
swift test --filter NoteCommandTests
```

### T3. Refactor the web scope controller to ordered constraints

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/controller.ts`
- `web/src/notes/controller.test.ts`

**Depends on**: T0
**Parallelizable**: yes, with T1 and T4 after T0; write scopes are disjoint

**Tasks**:

- Replace the all/folder/tag union with an ordered constraints array carrying
  `tagId`, canonical `tagName`, `kind`, and optional `classId`.
- Preserve plain activation as single-constraint replacement and add explicit
  append, per-constraint removal, and clear-all transitions.
- Reject duplicate `tagId` additions without changing order.
- Keep one generation boundary. Every effective transition and reconciliation
  change invalidates older snapshots; no-op duplicate additions do not create
  duplicate request groups.
- Expose current constraints, snapshots, `isCurrent`, and
  `tagFilterGroups()` with one `[tagName]` group per active constraint.
- Add a pure per-constraint catalog reconciliation transition that updates
  canonical metadata, drops only missing tags, deduplicates by `tagId`,
  preserves order, and reaches all-notebooks only when none remain.
- Preserve the independent notebook progress controller behavior.
- Test length-zero and length-one parity, ordered append/remove/clear,
  duplicates, grouped variables, generation invalidation, canonical rename,
  reclassification, partial deletion, and full deletion.

**Deliverables**:

- A testable multi-constraint state machine that preserves single-scope
  behavior and stale-response rejection.

**Verification**:

```bash
cd web && bun test src/notes/controller.test.ts
```

Full-project typecheck is deferred to T5 because T3 intentionally changes the
controller interface consumed by the view.

### T4. Thread grouped variables and harden client decoding and paging

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/client.test.ts`
- `web/src/notes/paging.ts`
- `web/src/notes/paging.test.ts`

**Depends on**: T0
**Parallelizable**: yes, with T1 and T3 after T0; write scopes are disjoint

**Tasks**:

- Declare and submit `$tagFilterGroups` in the web `Notebooks` operation while
  retaining the flat compatibility variable in the operation shape.
- Change client and paging inputs to grouped names and pass the complete
  ordered group array unchanged.
- Export one notebook page-size constant with value `200` for client, paging,
  and later view use. Compare page completion against the actual requested
  limit.
- Advance offsets by received length, deduplicate notebooks by ID, retain
  accepted partial data, and stop normally on a short page.
- Treat a full page contributing zero new IDs as retryable partial failure and
  enforce the accepted 1,000-page cap. Check `isCurrent` before emitting page,
  error, and completion effects.
- Normalize every notebook-producing query or mutation response through one
  decoder. Unsupported progress becomes `none` with non-optional
  `progressWasUnknown: true`; supported progress uses `false`.
- Ensure later canonical supported values clear the marker and mutation
  replacement cannot bypass normalization.
- Test GraphQL query and variables, grouped paging, requested-limit behavior,
  deduplication, zero progress, page cap, stale cancellation, partial data,
  valid progress, unknown progress, and marker clearing.

**Deliverables**:

- A grouped web transport with bounded forward progress and a total notebook
  progress partition.

**Verification**:

```bash
cd web && bun test src/notes/client.test.ts src/notes/paging.test.ts
```

Full-project typecheck is deferred to T5 because T4 intentionally changes
client and paging interfaces consumed by the view.

### T5. Integrate filter chips and required view correctness fixes

**Status**: COMPLETED
**Write scope**:

- `web/src/views/NotesView.tsx`
- `web/src/styles.css`
- focused view tests under `web/src/` if supported by the existing unit harness

**Depends on**: T2, T3, and T4
**Parallelizable**: no; filter, loading, detail, focus, and mutation behavior
share one view state

**Tasks**:

- Reconcile the full constraint set after catalog refresh and update view state
  through the controller generation boundary.
- Keep a sole constraint's existing breadcrumb. For multiple constraints use
  `Filtered notebooks` and treat the chip bar as authoritative.
- Show active state for every constrained left-pane tag while maintaining one
  keyboard focus target.
- Add a separately focusable, tag-named `Add to filter` action to every
  folder/tag row. Prevent it from triggering the row's replacement action and
  disable it when the tag is already constrained.
- Render a filter bar above both List and Board with labeled per-chip removal
  and clear-all. Route plain click, append, remove, and clear through the T3
  controller and one guarded refresh path.
- Use the shared T4 page-size constant and grouped paging request. List and
  Board must consume the same retained `notebooks()` signal.
- Resolve F1 by keeping Board columns mounted during current-generation
  loading and showing non-destructive counts-updating status.
- Resolve F2 by clearing retained membership before re-page only when the
  removed assignment can intersect an active tag constraint or a folder-class
  assignment can affect an active folder constraint.
- Resolve F3 by allowing one membership mutation globally; keep the affected
  tag key for spinner placement while disabling every add/remove control.
- Resolve F4 by bumping a preview generation on selection and close and
  checking notebook ID plus generation after every preview await.
- Resolve F6 by focusing the first surviving notebook activator after
  scope-ejecting removal, then clear-all, then the focusable content heading.
- Resolve F7 by removing disposed activator references and pruning the map to
  accepted notebook IDs.
- Resolve F11 by showing `Unknown status · shown in None` on affected List rows
  and Board cards while retaining those notebooks in the `none` column.
- Resolve F12 by auto-entering a new child folder only when the pre-mutation
  filter is exactly the matching parent-folder constraint.
- Preserve generation checks across success, partial page, error, and finally
  paths. A failed grouped refresh retains the last accepted List/Board and
  exposes retryable current-generation feedback.

**Deliverables**:

- One accessible multi-chip List/Board surface with all required view-level
  findings resolved and single-chip behavior retained.

**Verification**:

```bash
cd web && bun test src
cd web && bun run typecheck
cd web && bun run lint
cd web && bun run build
```

### T6. Author deterministic mocked browser coverage

**Status**: COMPLETED
**Write scope**:

- `web/e2e/dashboard.spec.ts`

**Depends on**: T5
**Parallelizable**: no; this validates the integrated request and view contract

**Tasks**:

- Extend the existing mocked GraphQL fixture instead of adding a duplicate
  suite.
- Assert that explicit add-to-filter produces ordered
  `tagFilterGroups`, that a plain click replaces the filter, and that duplicate
  additions remain disabled/no-op.
- Use non-trivial fixture membership so List and Board both show only the
  intersection; verify one-chip removal widens results and clear-all restores
  the unscoped set.
- Cover keyboard reachability and accessible names for add, per-chip remove,
  and clear-all actions.
- Cover retained Board content while a delayed refresh is pending, unknown
  progress visibility in the None column, and at least one stale grouped
  response rejected after a newer filter generation.
- Keep fixture accounting deterministic and call the existing cleanliness
  assertion after each affected scenario.
- Typecheck `web/e2e/dashboard.spec.ts` directly with TypeScript because the
  repository's main `web/tsconfig.json` intentionally excludes `web/e2e/`.
- Do not execute this test in the workflow because Playwright launches a
  browser. Record the operator command and this verification gap.

**Deliverables**:

- Authored and browser-free-typechecked deterministic integration coverage for
  grouped request shape and shared intersection rendering, pending operator
  execution.

**Required browser-free verification**:

```bash
cd web && bunx tsc --noEmit --target ES2022 --module ESNext --moduleResolution bundler --strict --skipLibCheck e2e/dashboard.spec.ts
```

**Operator verification command**:

```bash
cd web && bun run test:e2e -- dashboard.spec.ts
```

### T7. Integrated verification, review, documentation, and handoff

**Status**: COMPLETED
**Write scope**:

- this plan's task statuses and progress log
- `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` only when review
  shows their user-facing web Notes contracts require factual extension
- directly affected design documentation only for evidence-backed factual
  alignment without reopening accepted scope
- final workflow commit metadata

**Depends on**: T1 through T6
**Parallelizable**: no; this is the integrated completion gate

**Tasks**:

- Run focused verification after each task, then run every required integrated
  command separately and record exact result, test count, failure, and
  duration where available.
- Confirm `listNotes(tagFilter:)`, unrelated GraphQL surfaces, macOS UI,
  CORS/auth, `web/verify-live.mjs`, and the pre-existing
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
  modification remain outside feature changes and staging.
- Review `README.md` and the Riela implementation-workflow skill. Update only
  directly affected user-facing contracts; otherwise record an explicit
  no-change decision.
- Run implementation self-review, independent implementation review, and any
  improvement pass. Resolve every high/mid finding before completion; retain
  low findings and verification gaps as residual risks.
- Run the repository precommit safety check before staging or committing.
  Preserve issue, communication, review, file, finding, verification, and
  operator-gap evidence in the handoff.
- Leave commit and push behavior to the workflow's authorized commit step.
  Do not push to `main` or open a pull request.

**Deliverables**:

- Reviewed, verified, documented implementation with no unresolved high/mid
  finding and explicit operator-owned browser gaps.

**Required verification**:

```bash
cd web && bun test src
cd web && bun run typecheck
cd web && bunx tsc --noEmit --target ES2022 --module ESNext --moduleResolution bundler --strict --skipLibCheck e2e/dashboard.spec.ts
cd web && bun run lint
cd web && bun run build
swift build
swift test --filter NoteServiceTests
swift test --filter NoteHierarchyProgressTests
swift test --filter NoteGraphQLTests
swift test --filter NoteGraphQLHierarchyProgressTests
swift test --filter NoteGraphQLParsingRegressionTests
swift test --filter NoteCommandTests
git diff --check
git status --short --branch --untracked-files=all
```

## Dependency graph

```text
Accepted Step 3 review (comm-001641)
                  |
                 T0
          +-------+-------+
          |       |       |
         T1      T3      T4
          |       |       |
         T2      |       |
          +-------+-------+
                  |
                 T5
                  |
                 T6
                  |
                 T7
```

T1, T3, and T4 may start after T0 because their declared write scopes are
disjoint. T2 waits for T1, then may run alongside any unfinished T3 or T4 work
because its Swift/CLI write scope is disjoint. T5 owns shared view integration
and waits for T2, T3, and T4. T6 and T7 are serial gates.

## Completion criteria

- [x] The work remains one `issue-resolution` package with
  `has_feature_fanout: false`.
- [x] `listNotebooks(tagFilterGroups:)` matches every group, unions and expands
  names within each group, fails closed for unknown requested groups, treats
  all-empty grouped input as unfiltered, and preserves legacy `tagFilter`.
- [x] Grouped notebook filters are bounded before database work, deduplicated,
  short-circuit on the first empty expansion, and return controlled
  `invalid_request` GraphQL results when input or expanded-name limits are
  exceeded.
- [x] GraphQL schema, nested-variable decoding, service forwarding, and
  malformed-input rejection are covered without changing response shape.
- [x] The CLI consumes one shared notebook document; legacy `--tag` behavior
  is unchanged and no grouped CLI option exists.
- [x] Zero/one constraints preserve current behavior; ordered multi-constraint
  add, remove, clear, reconciliation, and generation semantics are covered.
- [x] List and Board send grouped variables, show the same intersection, and
  clear-all restores the unscoped view.
- [x] Required findings F1, F2, F3, F4, F6, F7, F9, F10, F11, and F12 have
  implementation and regression evidence.
- [x] F2 regression coverage proves an unrelated non-folder removal under an
  active folder constraint retains both Board and List membership when the
  canonical refresh fails.
- [x] F9 preview paging uses the shared `notebookPageLimit` in the transport,
  view completion check, client assertion, and request-derived browser fixture.
- [x] F10 forward-progress and page-cap failures carry accepted partial
  notebooks through `NotebookPartialLoadError`; the current view generation
  publishes that partial result atomically and exposes a retryable error.
- [x] F6 authored browser coverage asserts both no-survivor clear-all focus and
  first-surviving-notebook focus after scope ejection.
- [x] Full catalog reconciliation to All notebooks clears stale detail,
  preview/loading state, picker state, retained membership, and activators
  before loading the unfiltered result.
- [x] A successful intersecting tag removal followed by fail-closed refresh
  failure restores focus to Clear all after removing the stale detail surface.
- [x] Successful membership mutations whose original detail or scope snapshot
  becomes stale trigger a canonical refresh of the current filter instead of
  silently leaving pre-mutation membership visible.
- [x] A stale successful removal that clears membership restores focus to a
  still-valid newer detail activator, or clears that detail and applies the
  deterministic fallback when canonical refresh fails or removes it.
- [x] Removal impact follows tag ancestry for every tag class, so removing a
  non-folder descendant of an active parent constraint fails closed when
  canonical refresh cannot complete.
- [x] Web unit tests, typecheck, scoped source/e2e ESLint, production source
  audit, and build pass.
- [x] The repository-wide web lint gap is explicitly accepted and remains
  isolated to the excluded pre-existing `web/verify-live.mjs`.
- [x] `swift build` and focused Note, GraphQL, document, and CLI suites pass.
- [x] Mocked Playwright coverage is authored and passes the dedicated
  browser-free TypeScript check but is not executed by this workflow; operator
  execution and live List/Board/Kanban/cross-tag verification remain explicit
  gaps.
- [x] No unrelated source, native UI, auth/CORS, note-filter, stretch-finding,
  `web/verify-live.mjs`, or pre-existing `.riela` workflow change enters feature
  staging or the feature commit.
- [x] Directly affected documentation is refreshed or an evidence-backed
  no-change decision is recorded.
- [x] Independent implementation review has no unresolved high/mid finding.
- [x] Final handoff records changed files, review decisions, exact verification
  results, residual risks, and workflow-authorized commit state.

## Progress-log expectations

After each task, review correction, or verification pass, append a dated entry
containing:

- task IDs and status transitions;
- files added or changed and concrete deliverables;
- dependencies unblocked, blockers, and deviations from the plan;
- exact commands with pass/fail results, test counts, and relevant durations;
- issue, communication, workflow, and codex-agent references;
- review decisions, finding severities, dispositions, and residual risks;
- documentation decisions and operator-owned verification gaps; and
- commit hash and push state only when the authorized commit step completes.

Do not mark a task complete from code presence alone. Completion requires its
deliverables, focused verification, and a progress-log entry. Write all
throwaway logs and evidence under
`tmp/web-cross-tag-filter-and-fixes/`; never add them to Git.

## Progress log

### 2026-07-27 — Step 4 implementation-plan creation, session 636

- **Status**: T0-T7 `NOT_STARTED`; plan ready for Step 5 review.
- **Review input**: Step 3 `comm-001631` accepted
  `design-docs/specs/design-web-cross-tag-filter-and-fixes.md` with decision
  `accepted_for_implementation_planning`, findings `[]`, feedback `[]`, and
  `needs_revision: false`.
- **Issue reference**: `comm-001623`,
  `codex-design-and-implement-review-loop-session-636`.
- **Codex-agent references**: none; no Cursor adapter task applies.
- **Plan decision**: T1, T3, and T4 may start after T0; T2 may join T3/T4 only
  after T1. These parallel paths have disjoint write scopes. All integration
  and verification gates are serial.
- **Accepted boundary**: `listNotes(tagFilter:)` and
  `web/verify-live.mjs` remain outside scope; Playwright and live browser
  execution remain operator-owned.
- **Addressed feedback**: none; Step 3 reported no findings or feedback.
- **Plan self-review**: kept T1, T3, and T4 disjoint after T0; allowed T2 to
  overlap only unfinished web work after T1; deferred full-project typecheck
  from interface-changing T3/T4 to the T5 integration gate.
- **Plan verification**: the trailing-whitespace `awk` check reported
  `plan whitespace: clean`; task-count and required-section `grep` checks found
  T0-T7 and every required reference; `git diff --check` passed.
- **Worktree verification**: `git status --short --branch
  --untracked-files=all` confirmed branch
  `feat/riela-note-web-cross-tag-filter` with only the accepted design, this
  plan, and pre-existing `web/verify-live.mjs` untracked.
- **Blockers**: none.

### 2026-07-27 — Step 4 plan reuse and revision, session 638

- **Status**: T0-T7 remain `NOT_STARTED`; the revised plan is ready for Step 4
  self-review and Step 5 independent implementation-plan review.
- **Review input**: Step 3 `comm-001641` accepted
  `design-docs/specs/design-web-cross-tag-filter-and-fixes.md` with decision
  `accepted_for_implementation_planning`, findings `[]`, feedback `[]`, and
  `needs_revision: false`.
- **Issue references**: "Web Notes cross-tag (AND) filter via
  `tagFilterGroups` + Required-tier web fixes F1-F12 (one work package)",
  `comm-001635`, `comm-001637`, `comm-001640`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none; no Codex-reference trace or Cursor adapter
  task applies.
- **Addressed feedback**: no Step 3 finding required a plan change. Reuse
  validation refreshed stale prior-session references, aligned the GraphQL
  parsing regression command with the accepted design, and recorded the
  pre-existing `.riela` workflow modification as excluded from feature staging
  and commit.
- **Accepted boundaries**: `listNotes(tagFilter:)`, `web/verify-live.mjs`, and
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` remain
  outside feature changes; mocked Playwright execution and live browser
  verification remain operator-owned.
- **Plan verification**: the trailing-whitespace check passed; reference and
  task searches confirmed T0-T7, `comm-001641`, session 638, both corrected
  `NoteGraphQLParsingRegressionTests` commands, and the `.riela` exclusion;
  `git diff --check` passed. `git status --short --branch
  --untracked-files=all` confirmed only the accepted pre-existing workflow
  modification plus the accepted design, this plan, and `web/verify-live.mjs`.
- **Blockers**: none.

### 2026-07-27 — Step 4 self-review correction, session 638

- **Status**: T0-T7 remain `NOT_STARTED`; the plan-only mid finding from
  `comm-001643` is resolved and the plan is ready for another self-review.
- **Finding disposition**: added the required browser-free
  `web/e2e/dashboard.spec.ts` TypeScript command to T6, the T7 integrated gate,
  and completion criteria. No accepted design or dependency change was needed.
- **Verification command**:
  `cd web && bunx tsc --noEmit --target ES2022 --module ESNext
  --moduleResolution bundler --strict --skipLibCheck e2e/dashboard.spec.ts`
  was baseline-validated successfully without launching a browser.
- **Issue references**: `comm-001641`, `comm-001642`, `comm-001643`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none.
- **Residual boundaries**: mocked Playwright execution and live browser checks
  remain operator-owned; `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
  and `web/verify-live.mjs` remain excluded from feature staging and commit.
- **Blockers**: none.

### 2026-07-27 — Step 6 implementation, session 638

- **Status**: T0-T6 `COMPLETED`; T7 `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 5 `comm-001646` accepted this plan for implementation
  with findings `[]`, feedback `[]`, and both revision flags false.
- **Issue references**: `comm-001635`, `comm-001637`, `comm-001640`,
  `comm-001641`, `comm-001642`, `comm-001643`, `comm-001644`, `comm-001645`,
  `comm-001646`, and `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Server and GraphQL**: implemented independently expanded AND-of-union
  notebook groups, fail-closed unknown groups, grouped-over-flat precedence,
  additive schema and service forwarding, strict nested-array decoding, and
  nullable omitted root-variable handling without weakening missing variables
  inside input objects or arrays.
- **CLI**: moved notebook listing to
  `NoteCommandGraphQLDocuments.notebooks`; legacy `--tag` continues to send the
  flat filter and omits grouped values.
- **Web**: implemented ordered filter constraints, per-constraint catalog
  reconciliation, accessible add/remove/clear controls shared by List and
  Board, retained Board refresh state, global membership single-flight,
  preview generations, deterministic focus recovery and activator pruning,
  shared page size, zero-progress and 1,000-page guards, visible unknown
  progress normalization, and parent-only child-folder auto-entry.
- **Tests**: added grouped Swift service/GraphQL/CLI coverage, controller/client/
  paging Bun regressions, and a mocked Playwright intersection scenario. The
  Playwright file was browser-free typechecked and was not executed.
- **Verification passed**: `cd web && bun test src` (26 tests), `cd web && bun
  run typecheck`, browser-free `bunx tsc ... e2e/dashboard.spec.ts`, scoped
  `bunx eslint src e2e/dashboard.spec.ts`, `bun run audit`, `bun run build`,
  explicit Xcode `swift build`, `swift build --build-tests`, focused direct
  XCTest execution equivalent to the required Note/GraphQL/CLI filters (84
  tests total across recorded runs, zero failures), `git diff --check`, and
  Xcode-toolchain `swiftlint --quiet --no-cache` with warning-only pre-existing
  findings.
- **Verification gap**: exact `cd web && bun run lint` reaches ESLint and fails
  only on the excluded pre-existing `web/verify-live.mjs` (`process` and
  `console` `no-undef`). That file was not modified. Mocked Playwright execution
  and live List/Board/Kanban/cross-tag QA remain operator-owned.
- **Documentation decision**: updated the accepted design with Step 6 evidence
  and this plan with status/results. `README.md` and the implementation-workflow
  skill need no change before independent review because their existing web
  Notes contract remains accurate and this feature is not yet review-accepted.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain excluded from feature staging and commit.
- **Blockers**: no implementation blocker; independent review and the exact
  repository-wide lint gap remain open T7 gates.

### 2026-07-27 — Step 6 retained-Board revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 6 self-review `comm-001648` returned one mid F1
  finding against `web/src/views/NotesView.tsx` and required revision before
  independent review.
- **Issue references**: `comm-001635`, `comm-001637`, `comm-001640`,
  `comm-001641`, `comm-001642`, `comm-001643`, `comm-001644`, `comm-001645`,
  `comm-001646`, `comm-001647`, `comm-001648`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding resolution**: ordinary refresh, sort, and paging now retain the
  last accepted notebook array and publish the complete current-generation
  replacement atomically. A completed refresh defers that replacement while a
  Board drag is active, then publishes it on drag end. Board columns remain
  mounted whenever Board view is selected, including fail-closed empty
  membership reconciliation.
- **Regression evidence**: `web/e2e/dashboard.spec.ts` now records DOM identity
  for the Board and dragged card across a delayed refresh and asserts all four
  columns remain mounted while `clearMembership` has emptied the cards. The
  mocked scenarios were authored and browser-free typechecked only; no browser
  was launched.
- **Verification passed**: `cd web && bun test src` (26 tests), direct
  repository TypeScript typecheck (`./node_modules/.bin/tsc --noEmit`), direct
  browser-free e2e typecheck (`./node_modules/.bin/tsc --noEmit --target ES2022
  --module ESNext --moduleResolution bundler --strict --skipLibCheck
  e2e/dashboard.spec.ts`), scoped ESLint for
  `src/views/NotesView.tsx e2e/dashboard.spec.ts`, `bun run audit`, `bun run
  build`, and `git diff --check`.
- **Verification gap**: the exact `bunx tsc ... e2e/dashboard.spec.ts` wrapper
  timed out after 60 seconds without diagnostics, while its repository-local
  TypeScript binary completed successfully. Exact `cd web && bun run lint`
  still fails only on the excluded pre-existing `web/verify-live.mjs`
  `process`/`console` `no-undef` diagnostics.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no remaining implementation blocker from `comm-001648`;
  independent review, operator-owned browser QA, and the excluded-helper lint
  gap remain T7 gates.

### 2026-07-27 — Step 6 test-integrity revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 6 test-integrity review `comm-001651` returned three
  mid findings and one low finding with decision
  `revision_required_for_test_integrity`.
- **Issue references**: `comm-001635`, `comm-001637`, `comm-001640`,
  `comm-001641`, `comm-001642`, `comm-001643`, `comm-001644`, `comm-001645`,
  `comm-001646`, `comm-001647`, `comm-001648`, `comm-001649`, `comm-001650`,
  `comm-001651`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding dispositions**:
  - `test-integrity-001` resolved by replacing the obsolete All-notebooks
    root-creation expectation and adding the matching parent-folder auto-entry
    scenario in `web/e2e/dashboard.spec.ts`.
  - `test-integrity-002` resolved with deterministic authored coverage for
    global membership single-flight, same-notebook preview reselection,
    post-ejection focus, visible unknown progress in List and Board,
    keyboard activation of add/remove/clear, and activator cleanup.
  - `test-integrity-003` resolved by restoring a normalized full-signature
    assertion for the additive GraphQL `notebooks` field in
    `Tests/RielaGraphQLTests/NoteGraphQLTests.swift`.
  - `test-integrity-004` resolved with scalar-outer, non-string-member,
    omitted, and null GraphQL grouped-variable cases; controller
    reclassification/full-deletion cases; and mutation-response progress
    normalization coverage.
- **Implementation detail**: activator pruning moved to the generic production
  helper `pruneNotebookActivatorEntries` in
  `web/src/notes/controller.ts`, used by `NotesView.tsx` and covered without
  exposing test-only behavior.
- **Verification passed**: `cd web && bun test src` (27 tests, zero failures),
  `cd web && bun run typecheck`, direct browser-free e2e TypeScript checking,
  scoped ESLint over every changed TypeScript/TSX test and source file,
  `cd web && bun run audit`, `cd web && bun run build`, explicit Xcode
  `swift build`, `swift test --filter NoteServiceTests` (38 tests),
  `swift test --filter NoteHierarchyProgressTests` (6 tests),
  `swift test --filter NoteGraphQLTests` (15 tests),
  `swift test --filter NoteGraphQLHierarchyProgressTests` (4 tests),
  `swift test --filter NoteGraphQLParsingRegressionTests` (9 tests),
  `swift test --filter NoteCommandTests` (12 tests), Xcode-toolchain
  `swiftlint --quiet --no-cache`, and `git diff --check`.
- **Verification gaps**: exact `cd web && bun run lint` still fails only on the
  excluded pre-existing `web/verify-live.mjs` `process`/`console` diagnostics.
  No browser was launched; mocked Playwright execution and live List, Board,
  drag-and-drop, cross-tag, clear-all, focus, and unknown-progress QA remain
  operator-owned.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no remaining implementation or test-integrity blocker from
  `comm-001648` or `comm-001651`; independent review, operator-owned browser
  QA, and the excluded-helper lint gap remain T7 gates.

### 2026-07-27 — Step 6 second test-integrity revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 6 test-integrity review `comm-001654` returned
  `test-integrity-005` at mid severity and `test-integrity-006` at low severity,
  with decision `revision_required_for_test_integrity`.
- **Issue references**: `comm-001646`, `comm-001648`, `comm-001651`,
  `comm-001652`, `comm-001653`, `comm-001654`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding dispositions**:
  - `test-integrity-005` resolved by adding a deterministic mocked browser
    scenario that scopes to `Work`, removes unrelated classless tag `Personal`,
    forces the canonical refresh to fail, and asserts retained Board columns,
    Board membership, detail state, and List membership.
  - `test-integrity-006` resolved by using `notebookPageLimit` for note-preview
    requests, asserting the emitted GraphQL limit in `client.test.ts`, and
    deriving exact-page fixture length from the request limit instead of a
    duplicate literal.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Verification passed**: `cd web && bun test src` (28 tests, zero failures),
  direct repository TypeScript typecheck, direct browser-free e2e TypeScript
  check, scoped ESLint for `src/notes/client.ts`,
  `src/notes/client.test.ts`, and `e2e/dashboard.spec.ts`, direct production
  source audit, `cd web && bun run build`, and `git diff --check`.
- **Verification gap**: exact `cd web && bun run lint` remains blocked only by
  four `process`/`console` `no-undef` diagnostics in excluded pre-existing
  `web/verify-live.mjs`. Mocked Playwright and live browser execution remain
  operator-owned and were not run.
- **Blockers**: no remaining implementation blocker from `comm-001654`;
  independent review, operator-owned browser QA, and the excluded-helper lint
  gap remain T7 gates.

### 2026-07-27 — Step 6 third test-integrity revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 6 test-integrity review `comm-001657` returned
  `test-integrity-007` and `test-integrity-008` at mid severity with decision
  `revision_required_for_test_integrity`.
- **Issue references**: `comm-001646`, `comm-001648`, `comm-001651`,
  `comm-001654`, `comm-001657`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding dispositions**:
  - `test-integrity-007` resolved by making paging guard failures carry their
    accepted partial notebooks in `NotebookPartialLoadError`, publishing that
    partial result through the current-generation view path, asserting partial
    payloads for both duplicate-page and page-cap failures, and authoring a
    mocked browser scenario that keeps the partial List visible with the
    retryable error.
  - `test-integrity-008` resolved by authoring a two-notebook filtered scenario
    that ejects the selected notebook and asserts focus moves to the first
    surviving notebook activator.
- **Verification passed**: `cd web && bun test src` (28 tests, zero failures),
  `cd web && ./node_modules/.bin/tsc --noEmit`, direct browser-free e2e
  TypeScript checking, scoped ESLint for the four revision files, production
  source audit, Vite production build, and `git diff --check`. The focused
  paging suite passed 5 tests with zero failures. Swift verification remains
  carried forward because this revision changes only web TypeScript/tests and
  this implementation plan.
- **Verification gap**: exact `cd web && bun run lint` remains blocked only by
  four `process`/`console` `no-undef` diagnostics in excluded pre-existing
  `web/verify-live.mjs`. Mocked Playwright and live browser execution remain
  operator-owned and were not run.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no remaining implementation blocker from `comm-001657`;
  independent review, operator-owned browser QA, and the excluded-helper lint
  gap remain T7 gates.

### 2026-07-27 — Step 6 self-review locator revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation review and the later workflow commit gate.
- **Review input**: Step 6 self-review `comm-001659` returned
  `self-review-009` at mid severity because the new F10 mocked browser
  assertion used a non-unique regular-expression locator.
- **Issue references**: `comm-001657`, `comm-001658`, `comm-001659`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding disposition**: `self-review-009` resolved by selecting the exact
  `Paged notebook 1` title text, which is unique among the 200 request-derived
  fixture rows and avoids Playwright strict-locator ambiguity.
- **Verification passed**: the browser-free e2e TypeScript check, scoped ESLint
  for `web/e2e/dashboard.spec.ts`, the full 28-test web unit suite, production
  source audit, Vite production build, and `git diff --check`.
- **Verification gap**: exact `cd web && bun run lint` remains blocked only by
  four `process`/`console` `no-undef` diagnostics in excluded pre-existing
  `web/verify-live.mjs`. Mocked Playwright and live browser execution remain
  operator-owned and were not run.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no remaining implementation blocker from `comm-001659`;
  independent review, operator-owned browser QA, and the excluded-helper lint
  gap remain T7 gates.

### 2026-07-27 — Step 6 independent-review revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation re-review and the later workflow commit gate.
- **Review input**: Step 7 implementation review `comm-001663` returned two
  mid-severity findings against `web/src/views/NotesView.tsx` with decision
  `revision_required_for_implementation_review`.
- **Issue references**: `comm-001646`, `comm-001648`, `comm-001651`,
  `comm-001654`, `comm-001657`, `comm-001659`, `comm-001663`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding dispositions**:
  - The catalog-reconciliation finding is resolved by recording whether the
    accepted snapshot had constraints before reconciliation, detecting when
    reconciliation removes the final constraint, and clearing selected detail,
    preview offset/loading state, picker state, retained notebooks, and
    activators before the unfiltered request is published.
  - The F6 failure-path finding is resolved by invoking the same deterministic
    surviving-notebook, Clear-all, or content-heading focus fallback after a
    successful intersecting removal closes detail during fail-closed refresh.
- **Regression evidence**: the catalog-disappearance mocked scenario now
  proves loaded preview content is removed with stale detail; the failed
  scoped-removal scenario now asserts Clear all receives focus.
- **Verification passed**: `cd web && bun test src` (28 tests, zero
  failures), `cd web && ./node_modules/.bin/tsc --noEmit`, browser-free
  `cd web && ./node_modules/.bin/tsc --noEmit --target ES2022 --module ESNext
  --moduleResolution bundler --strict --skipLibCheck e2e/dashboard.spec.ts`,
  scoped ESLint for `src/views/NotesView.tsx` and `e2e/dashboard.spec.ts`,
  `cd web && bun scripts/audit-source.ts`, and `cd web && bun run build`.
- **Final repository checks**: `git diff --check` passed. `git status --short
  --branch --untracked-files=all` reported the expected feature worktree plus
  the excluded pre-existing `.riela` workflow change and `web/verify-live.mjs`;
  its wrapper timed out after emitting the complete status.
- **Verification gaps**: exact repository-wide web lint remains blocked by the
  excluded pre-existing `web/verify-live.mjs`; mocked Playwright execution and
  live browser QA remain operator-owned and are not run.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no known implementation blocker remains from `comm-001663`;
  independent re-review, operator-owned browser QA, and the excluded-helper
  lint gap remain T7 gates.

### 2026-07-27 — Step 6 adversarial-review revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation re-review and the later workflow commit gate.
- **Review traceability**: test-integrity communications `comm-001664`,
  `comm-001665`, and `comm-001666` recorded
  `accepted_test_integrity`; ordinary implementation review `comm-001667`
  recorded `accepted_requires_adversarial_review`; adversarial review
  `comm-001668` returned two mid findings and one low finding with decision
  `revision_required_for_adversarial_review`.
- **Codex-agent references**: none supplied.
- **Finding dispositions**:
  - The stale successful-mutation finding is resolved by treating a changed
    detail or filter snapshot as a canonical-membership refresh trigger.
    Removal reruns fail closed when the removed tag can affect the current
    filter; additions rerun the current filter without applying stale detail
    state.
  - The non-folder descendant finding is resolved by walking tag ancestry
    against every active constraint, independent of tag class. Exact and
    descendant removals now share the same fail-closed membership path.
  - The low traceability finding is resolved by adding `comm-001664` through
    `comm-001668` and their review decisions to this plan.
- **Changed files**: `web/src/notes/controller.ts`,
  `web/src/notes/controller.test.ts`, `web/src/views/NotesView.tsx`,
  `web/e2e/dashboard.spec.ts`, and this implementation plan.
- **Regression evidence**: the controller suite covers non-folder
  parent/child ancestry and unrelated removals. Authored mocked-browser
  scenarios cover delayed add plus filter change, delayed descendant removal
  plus filter change, and non-folder descendant removal followed by canonical
  refresh failure. Per workflow constraints, those Playwright scenarios were
  typechecked but not launched.
- **Verification passed**: `cd web && bun test src` (29 tests, zero failures,
  95 assertions); `cd web && ./node_modules/.bin/tsc --noEmit`; browser-free
  `cd web && ./node_modules/.bin/tsc --noEmit --target ES2022 --module ESNext
  --moduleResolution bundler --strict --skipLibCheck e2e/dashboard.spec.ts`;
  scoped ESLint for `src/notes/controller.ts`,
  `src/notes/controller.test.ts`, `src/views/NotesView.tsx`, and
  `e2e/dashboard.spec.ts`; `cd web && bun scripts/audit-source.ts`;
  `cd web && bun run build`; and `git diff --check`.
- **Verification gap**: exact `cd web && bun run lint` still fails only on the
  four pre-existing `process`/`console` `no-undef` diagnostics in excluded
  `web/verify-live.mjs`. Mocked Playwright execution and live List, Board,
  drag-and-drop, cross-tag, mutation-race, and focus QA remain operator-owned.
- **Carried-forward Swift evidence**: the latest focused
  `NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|
  NoteGraphQLParsingRegressionTests|NoteCommandTests` run passed 31 tests with
  zero failures; this revision changes no Swift source or tests.
- **Documentation decision**: the accepted design remains unchanged. `README.md`
  and `.codex/skills/riela-impl-workflow/SKILL.md` were reviewed and require no
  user-facing change for this narrow race/ancestry correction.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no known implementation blocker remains from `comm-001668`;
  independent re-review, operator-owned browser QA, and the excluded-helper
  lint gap remain T7 gates.

### 2026-07-27 — Step 6 stale-removal focus revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation re-review and the later workflow commit gate.
- **Review input**: Step 7 implementation review `comm-001672` returned one
  mid-severity F6 finding with decision
  `revision_required_for_implementation_review`.
- **Issue references**: `comm-001663`, `comm-001668`, `comm-001672`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding disposition**: when a successful delayed removal belongs to a
  stale detail or scope snapshot, the current detail ID is now captured before
  fail-closed membership clearing. After the canonical refresh, a still-valid
  detail restores focus to its own notebook activator; a failed refresh or
  absent notebook clears detail/preview state and uses the established
  surviving-notebook, Clear-all, or content-heading fallback.
- **Changed files**: `web/src/views/NotesView.tsx`,
  `web/e2e/dashboard.spec.ts`, and this implementation plan.
- **Regression evidence**: the existing delayed-removal/newer-detail scenario
  now asserts focus returns to the newer notebook. A second authored scenario
  forces the canonical refresh to fail and asserts the newer detail is cleared
  and Clear all receives focus. Per workflow constraints, these Playwright
  scenarios were typechecked but not launched.
- **Verification passed**: `cd web && bun test src` (29 tests, zero failures,
  95 assertions); `cd web && ./node_modules/.bin/tsc --noEmit`;
  browser-free `cd web && ./node_modules/.bin/tsc --noEmit --target ES2022
  --module ESNext --moduleResolution bundler --strict --skipLibCheck
  e2e/dashboard.spec.ts`; `cd web && ./node_modules/.bin/eslint
  src/views/NotesView.tsx e2e/dashboard.spec.ts`; `cd web && bun
  scripts/audit-source.ts`; `cd web && bun run build`; and
  `git diff --check`.
- **Carried-forward Swift evidence**: the latest focused
  `NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|
  NoteGraphQLParsingRegressionTests|NoteCommandTests` run passed 31 tests with
  zero failures; this revision changes no Swift source or tests.
- **Verification gaps**: exact `cd web && bun run lint` remains blocked by the
  excluded pre-existing `web/verify-live.mjs`; mocked Playwright execution and
  live List, Board, drag-and-drop, cross-tag, mutation-race, and focus QA
  remain operator-owned.
- **Documentation decision**: the accepted design, `README.md`, and
  `.codex/skills/riela-impl-workflow/SKILL.md` require no user-facing change
  for this narrow focus correction.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Blockers**: no known implementation blocker remains from `comm-001672`;
  independent re-review, operator-owned browser QA, and the excluded-helper
  lint gap remain T7 gates.

### 2026-07-27 — Step 6 grouped-filter resource-bound revision, session 638

- **Status**: T0-T6 `COMPLETED`; T7 remains `IN_PROGRESS` pending independent
  implementation and adversarial re-review and the later workflow commit gate.
- **Review input**: Step 7 adversarial review `comm-001677` returned one
  mid-severity availability finding with decision
  `revision_required_for_adversarial_review`.
- **Issue references**: `comm-001663`, `comm-001668`, `comm-001672`,
  `comm-001673`, `comm-001675`, `comm-001676`, `comm-001677`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Finding disposition**: `NoteService.listNotebooks` now rejects more than 64
  grouped filters or 256 grouped input names before hierarchy queries,
  canonicalizes and deduplicates names and equivalent groups, returns
  immediately on the first empty expansion, and rejects more than 900 expanded
  names with `NoteServiceError.invalidInput`. Legacy flat `tagFilter` behavior
  remains unchanged. GraphQL maps the service rejection to a controlled
  `invalid_request` result.
- **Changed files**: `Sources/RielaNote/NoteService.swift`,
  `Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`,
  `Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift`,
  `design-docs/specs/design-web-cross-tag-filter-and-fixes.md`, and this
  implementation plan.
- **Regression evidence**: service tests cover duplicate groups/names,
  empty-first fail-closed behavior, outer-group and input-name bounds, and an
  oversized descendant expansion. The GraphQL executor test proves an
  oversized grouped request returns `accepted: false`, `invalid_request`, a
  bounded diagnostic, and null value rather than a database failure.
- **Verification passed**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests'`
  (12 tests, zero failures);
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests|NoteCommandTests'`
  (33 tests, zero failures);
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  passed; `git diff --check` passed; and
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
  PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
  /usr/bin/xcrun swiftlint --quiet --no-cache` exited zero with only existing
  warnings outside this revision.
- **Carried-forward web evidence**: `cd web && bun test src` (29 tests, zero
  failures, 95 assertions); `cd web && ./node_modules/.bin/tsc --noEmit`;
  scoped source/e2e ESLint; `cd web && bun scripts/audit-source.ts`; and
  `cd web && bun run build` remain valid because this revision changes no
  TypeScript, JavaScript, CSS, or web test file.
- **Verification gaps**: exact `cd web && bun run lint` remains blocked by the
  excluded pre-existing `web/verify-live.mjs`; mocked Playwright execution and
  live List, Board, drag-and-drop, cross-tag, mutation-race, and focus QA
  remain operator-owned and were not run.
- **Documentation decision**: the accepted design and active implementation
  contract now record the resource bounds and controlled rejection behavior.
  `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` require no
  user-facing change for this defensive boundary correction.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain untouched and excluded from feature staging and
  commit.
- **Commit state**: no commit or push was performed.
- **Blockers**: no known implementation blocker remains from `comm-001677`;
  independent re-review, operator-owned browser QA, and the excluded-helper
  lint gap remain T7 gates.

### 2026-07-27 — Step 7 acceptance and Step 8 completion gate, session 638

- **Status**: T0-T7 `COMPLETED`; the plan is archived under
  `impl-plans/completed`.
- **Workflow mode**: `issue-resolution`; this remains exactly one work package
  with `has_feature_fanout: false`.
- **Issue references**: `comm-001663`, `comm-001668`, `comm-001672`,
  `comm-001673`, `comm-001675`, `comm-001676`, `comm-001677`,
  `comm-001678`, `comm-001679`, `comm-001680`, `comm-001681`,
  `comm-001682`, `comm-001683`, and
  `codex-design-and-implement-review-loop-session-638`.
- **Codex-agent references**: none supplied.
- **Review decision**:
  `accepted_adversarial_review_with_residual_low_risks`; no unresolved high-
  or mid-severity finding remains.
- **Documentation refresh**: `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` were updated with the accepted
  grouped-filter, multi-chip List/Board, resource-bound, retained-state,
  mutation, paging, focus, and progress-normalization contracts.
- **Accepted verification**: `cd web && bun test src`; `cd web &&
  ./node_modules/.bin/tsc --noEmit`; scoped ESLint over the changed Notes
  source, tests, and `e2e/dashboard.spec.ts`; `cd web && bun
  scripts/audit-source.ts`; `cd web && bun run build`; the Xcode toolchain
  `swift build`; the filtered
  `NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|
  NoteGraphQLParsingRegressionTests|NoteCommandTests` suite; and `git diff
  --check`.
- **Residual risks**: grouped-filter extraction remains a maintenance
  candidate in `Sources/RielaNote/NoteService.swift`; mocked Playwright
  execution and live List/Board/cross-tag/drag/race/partial-failure/focus
  checks remain operator-owned; repository-wide `cd web && bun run lint`
  remains blocked only by excluded pre-existing `web/verify-live.mjs`.
- **Dirty-worktree safety**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and
  `web/verify-live.mjs` remain excluded from feature commit scope.
- **Commit state**: no commit or push was performed; commit-message creation
  remains delegated to the next workflow step.
