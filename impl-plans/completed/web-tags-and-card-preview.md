# Web Notes Classed Tags and Card Preview Implementation Plan

**Status**: COMPLETED — accepted implementation, review, verification, and
documentation refresh; final commit delegated to the workflow commit step
**Workflow Mode**: `issue-resolution`
**Branch**: `feat/riela-note-web-tags-and-card-preview`
**Issue Reference**: `design-docs/research/web-tags-and-card-preview-brief.md`
at `ea9426f`
**Design Reference**:
`design-docs/specs/design-web-tags-and-card-preview.md`
**Base Design Reference**:
`design-docs/specs/design-wrike-web-notebook-view.md`
**Accepted Design Review**: `comm-000006`;
`accepted_for_implementation_planning`, `needs_revision: false`, findings `[]`
**Codex-Agent References**: none supplied
**Created**: 2026-07-26
**Last Updated**: 2026-07-26

---

## Objective

Implement one accepted web Notes work package with three connected additions:

- display the existing first-note preview and note count in notebook List and
  Board surfaces;
- expose every notebook tag assignment in class-ordered detail sections and
  allow catalog-only add/remove operations; and
- add a Tags navigation tab whose class-scoped hierarchies use the same
  descendant-aware notebook filtering and stale-request protections as Folder
  navigation.

The accepted extension design is the source of truth. The base Wrike-style web
notebook design remains authoritative for existing Folder, List, Board, detail,
transport, authentication, and failure behavior. Implementation discoveries
must not broaden the accepted scope or weaken the generation guards.

## References and accepted decisions

- Ground-truth brief:
  `design-docs/research/web-tags-and-card-preview-brief.md` at `ea9426f`.
- Accepted extension design:
  `design-docs/specs/design-web-tags-and-card-preview.md`.
- Existing behavior:
  `design-docs/specs/design-wrike-web-notebook-view.md`.
- Step 3 review:
  `comm-000006`, decision `accepted_for_implementation_planning`, findings
  `[]`, feedback `[]`.
- Codex-agent references: none supplied.
- Cursor adapter boundaries: none required.
- User-QA references: none; the accepted design records no unresolved user
  decision.
- Accepted intentional boundaries:
  descendant expansion remains server-side; classless navigation stays flat;
  detail additions are selected from the current catalog only; and optional
  Tags-pane classed-tag creation is not required. This plan does not schedule
  that optional creation flow.

## Scope

### Included

- Additive web GraphQL selections and nullable-tolerant display normalization
  for `Notebook.firstNotePreview` and `Notebook.noteCount`.
- Plain-text, clamped preview/count presentation in Board cards and List rows,
  with no empty-preview placeholder.
- Class-aware tag grouping, deterministic ordering, hierarchy, breadcrumb, and
  fallback behavior.
- Detail-panel chips for Folder, named classes, unknown named-class fallbacks,
  and classless Tags; protected assignment handling; catalog-only add/remove.
- `Folder | Tags` navigation with one mutually exclusive active scope shared by
  List and Board.
- Generation-safe folder/tag/all scope transitions using one invalidation
  boundary for load, pagination, catch, and finally completions.
- Focused client, helper, controller, and Playwright regression coverage.
- Full Bun and accepted Swift regression verification, directly affected
  documentation refresh, review handoff, and one local commit.

### Excluded

- Tag or class rename, delete, reparenting, or editing.
- Combined folder-and-tag filters, multi-select filters, or client-side
  descendant expansion.
- Free-text tag names sent to `applyNotebookTags`.
- Required Tags-pane tag creation; `defineNoteTag` is not needed for acceptance.
- Markdown/HTML rendering of previews, note editing, native macOS UI changes,
  CORS/authentication changes, or new REST endpoints.
- Unrelated source, tests, documentation, branch operations, pushes, or pull
  requests.

## Task breakdown

### T1. Preflight and backend list-enrichment verification

**Status**: COMPLETED
**Write scope**: this plan's progress log and evidence under
`tmp/web-tags-and-card-preview/` only
**Depends on**: accepted Step 3 review `comm-000006`
**Parallelizable**: no; this establishes the implementation baseline

**Tasks**:

- Confirm the current branch and identify ownership of every existing
  worktree change. Preserve the accepted uncommitted design and plan artifacts;
  stop on unrelated changes that overlap the planned source files.
- Confirm the brief at `ea9426f` and the accepted design have not changed.
- Read-only trace the `notebooks` GraphQL list path through
  `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
  `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`, and
  `Sources/RielaNote/NoteService+NotebookStats.swift`.
- Prove that list results selected through GraphQL receive batch-enriched
  `firstNotePreview` and `noteCount`. Record the exact service/executor path.
- Keep Swift source outside the implementation write scope unless this trace
  proves a list path skips enrichment. If it does, record the evidence before
  adding the smallest contract-preserving Swift contingency task.
- Inspect current web client projections, tree helpers, scope generations,
  membership operations, view markup, styles, tests, and the Playwright
  `installAPI` operation fixtures.

**Deliverables**:

- A dated baseline log identifying owned changes, inspected modules, the
  backend-enrichment decision, and exact frontend/test files selected.

**Verification**:

```bash
git status --short --branch
git diff --exit-code ea9426f -- design-docs/research/web-tags-and-card-preview-brief.md
test -s design-docs/specs/design-web-tags-and-card-preview.md
rg -n "firstNotePreview|noteCount|enrichNotebookListMetadata" Sources/RielaGraphQL Sources/RielaNote
rg -n "loadGeneration|folderScopeGeneration|beginFolderScope|membershipBusy|installAPI" web/src web/e2e/dashboard.spec.ts
```

### T2. Extend web notebook types and GraphQL client projections

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/client.test.ts`

**Depends on**: T1
**Parallelizable**: yes, with T3 and T4 after T1; write scopes are disjoint

**Tasks**:

- Represent `firstNotePreview` and `noteCount` in the web `Notebook` contract
  with the accepted tolerance for absent/null transport values.
- Add both scalar fields to the `Notebooks` list selection.
- Keep notebook replacement coherent after progress and membership mutations:
  either select the metadata in every notebook projection that can replace a
  visible list item or preserve normalized list metadata explicitly when
  adopting a mutation result. Do not allow a successful mutation to erase a
  previously rendered preview/count.
- Retain the existing `tags` fields `classId` and `parentTagId` and
  `tagClasses` fields `classId`, `label`, and `description`.
- Generalize folder-named membership client methods only as needed so the
  detail panel can apply and remove an existing tag from any class while
  preserving `provenance: "human"` and `assignedBy: "riela-web"`.
- Keep mutation inputs name-based and accept tag names only from validated
  caller selections; do not add a free-text creation path.
- Add client tests for query selections, replacement projections, tag
  catalog/class selections, mutation operation names, variables, and
  provenance.

**Deliverables**:

- A typed, additive web client contract that preserves preview/count metadata
  across list reads and canonical notebook replacements.

**Verification**:

```bash
cd web && bun test src/notes/client.test.ts
cd web && bun run typecheck
```

### T3. Generalize class-scoped tag trees, groups, and breadcrumbs

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/tree.ts`
- `web/src/notes/tree.test.ts`

**Depends on**: T1
**Parallelizable**: yes, with T2 and T4 after T1; write scopes are disjoint

**Tasks**:

- Generalize `buildFolderTree` into a class-scoped hierarchy builder while
  retaining a Folder entry point whose output and ordering remain unchanged.
- Follow a parent only when it belongs to the same selected class. Make
  missing, self, or cross-class parents roots; keep malformed cycles reachable
  without unbounded recursion.
- Sort siblings by localized case-insensitive name with stable `tagId`
  tie-breaking.
- Build named non-folder class groups ordered by class label with stable
  `classId` tie-breaking and put classless Tags last as a flat group.
- Provide deterministic grouping for detail assignments: Folder first, known
  named classes next, unknown non-null class IDs under stable fallback labels,
  and classless assignments under `Tags`.
- Derive named-class breadcrumbs from class label plus reachable tag ancestors;
  derive classless breadcrumbs from `Tags` plus the selected tag. Never parse
  hierarchy from tag names.
- Add unit coverage for multiple classes, parent/child/grandchild trees,
  cross-class/missing parents, cycles, deterministic ordering, Folder parity,
  classless-last grouping, unknown class IDs, and breadcrumbs.

**Deliverables**:

- Pure, deterministic helpers shared by Folder navigation, Tags navigation,
  breadcrumbs, and detail grouping.

**Verification**:

```bash
cd web && bun test src/notes/tree.test.ts
cd web && bun run typecheck
```

### T4. Add one generation-safe folder/tag scope controller

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/controller.ts`
- `web/src/notes/controller.test.ts`

**Depends on**: T1
**Parallelizable**: yes, with T2 and T3 after T1; write scopes are disjoint

**Tasks**:

- Add a typed active-scope model for all notebooks, one folder tag, or one
  non-folder/classless tag. Selecting one tag kind replaces the other.
- Centralize the generation bump currently represented by
  `beginFolderScope` so folder-to-tag, tag-to-folder, tag-to-tag, and
  scope-to-all transitions all invalidate prior work.
- Expose the current generation/token needed by the view loader to reject
  stale list, pagination, catch, and finally completions.
- Keep the request contract as either `tagFilter: []` or exactly
  `tagFilter: [selectedTag.name]`; never expand descendants in the client.
- Preserve the existing notebook progress controller and its tests.
- Add tests for mutual exclusion, tab-independent scope retention, filter
  variables, all-scope clearing, and rapid transitions whose older
  completions cannot update newer data/loading/error state.

**Deliverables**:

- One testable scope transition boundary that Folder and Tags UI can share
  without weakening existing race protection.

**Verification**:

```bash
cd web && bun test src/notes/controller.test.ts
cd web && bun run typecheck
```

### T5. Integrate previews, classed detail membership, and Tags navigation

**Status**: COMPLETED
**Write scope**:

- `web/src/views/NotesView.tsx`
- `web/src/styles.css`
- focused view tests under `web/src/` only if the existing unit harness supports
  them without production fixtures

**Depends on**: T2, T3, and T4
**Parallelizable**: no; all additions share Notes view state, markup, and styles

**Tasks**:

- Normalize preview text for presence checks without parsing Markdown or HTML.
  Render Board excerpts below the title with an approximately three-line CSS
  clamp and List excerpts with a one-line clamp; omit null, empty, and
  whitespace-only preview blocks.
- Render note counts using accessible singular/plural text. Keep Board count
  metadata visible independently of preview presence and place List counts with
  date metadata without expanding row density unnecessarily.
- Replace the folder-only detail chip surface with assignment sections from the
  T3 grouping helpers. Render only sections with assignments and show remove
  actions only for `deletable: true`.
- Preserve the dedicated Folder picker. Add a general class/group picker and
  existing-tag picker for named non-folder classes and classless Tags,
  excluding already assigned tags. When the selected group has no assignable
  tags, disable submission and explain that no existing tag is available.
- Immediately before calling `applyNotebookTags`, validate that the selected
  name still exists in the current catalog, remains in the selected class/group,
  and is unassigned. On stale selection, refresh/reject without mutation.
- Reuse `membershipBusy`, notebook-selection checks, and canonical mutation
  replacement. Preserve current detail state on failure; after success refresh
  scoped membership and close the detail panel non-destructively if the
  notebook leaves the active folder or tag scope.
- Add an accessible `Folder | Tags` tab strip with Folder as the initial tab.
  Switching tabs alone must not change the active scope.
- Render named non-folder classes as labeled, counted, collapsible trees and
  classless Tags last as a flat group. Keep tree items and disclosure controls
  keyboard reachable and correctly labeled.
- Route Folder and Tags selection through the T4 scope boundary. Feed List and
  Board from the same scoped resource and render the T3 breadcrumb.
- If a catalog refresh removes the selected tag, clear through the same
  generation boundary and reload all notebooks.
- Do not implement the optional classed-tag creation affordance unless the
  accepted plan is explicitly revised before source work begins.

**Deliverables**:

- One accessible Notes surface implementing all three accepted additions while
  retaining Folder behavior and canonical failure handling.

**Verification**:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
```

### T6. Extend deterministic browser coverage

**Status**: COMPLETED
**Write scope**:

- `web/e2e/dashboard.spec.ts`

**Depends on**: T5
**Parallelizable**: no; this validates the integrated frontend and shares the
Playwright fixture file

**Tasks**:

- Extend the existing `installAPI` operation-name fixtures for additive
  notebook fields and generalized membership operations. Keep fixture
  accounting strict; do not add fixtures or request overrides to production
  source.
- Cover Board preview and note-count rendering, List count/preview rendering,
  and omission of whitespace/empty previews without placeholder content.
- Cover class-ordered detail sections, classless-last chips, protected
  assignments without remove controls, empty assignable-group feedback,
  catalog-only addition, removal, and canonical updates.
- Cover Tags-tab class groups and hierarchy, tag selection variables,
  descendant delegation through a single tag name, shared List/Board scope,
  breadcrumb ancestors, `All notebooks`, and mutual replacement with Folder
  scope.
- Include at least one delayed/out-of-order folder-to-tag or tag-to-folder
  scenario proving stale completion rejection at the rendered surface.
- Call `fixture.assertClean()` after every affected scenario.

**Deliverables**:

- Deterministic Playwright evidence for the three additions and their shared
  scope/mutation contracts.

**Verification**:

```bash
cd web && bun run test:e2e
cd web && bun run lint
```

### T7. Documentation, full verification, review handoff, and commit

**Status**: COMPLETED — implementation, independent review, documentation, and
verification accepted; final local commit remains the next workflow step
**Write scope**:

- this plan's task statuses and progress log
- `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` only when their
  user-facing Notes contracts require extension
- directly affected accepted design wording only when implementation evidence
  requires factual alignment without reopening scope
- final commit metadata

**Depends on**: T1 through T6
**Parallelizable**: no; this is the integrated completion gate

**Tasks**:

- Review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`; update
  directly affected web Notes behavior and verification contracts before
  commit generation.
- Run each required Bun and Swift command separately and record exact outcomes,
  counts, durations, and failures.
- Treat `DaemonWorkflowNodePatchTests` event-source restart and agent-VM
  interleaved-submit failures as unrelated only when evidence matches the known
  signatures. Do not hide feature failures behind those exclusions.
- Confirm no production fixture/mock violation, free-text tag mutation,
  client-side descendant expansion, native UI change, breaking GraphQL change,
  CORS/auth change, new REST endpoint, or unrelated file edit entered the diff.
- Run implementation self-review, independent implementation review, and
  improvement steps. Resolve every high/mid finding and record all low findings
  or residual risks before the commit gate.
- Run the repository's precommit safety check, inspect the complete staged diff,
  and commit only scoped work on
  `feat/riela-note-web-tags-and-card-preview`.
- Confirm the final commit and clean worktree. Do not push to `main`, push the
  feature branch, or open a pull request.

**Deliverables**:

- Reviewed, verified, documented, locally committed implementation with
  explicit evidence and no unresolved high/mid finding.

**Verification**:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
cd web && bun run test:e2e
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaAppSupportTests
git diff --check
git status --short --branch
git log -1 --oneline
```

## Dependency graph

```text
Accepted Step 3 review (comm-000006)
                  |
                 T1
          +-------+-------+
          |       |       |
         T2      T3      T4
          |       |       |
          +-------+-------+
                  |
                 T5
                  |
                 T6
                  |
                 T7
```

T2, T3, and T4 may run in parallel only after T1 because their declared write
scopes are disjoint. T5 owns the shared view integration and waits for all
three. T6 and T7 are serial integration gates.

## Completion criteria

- [x] Read-only evidence confirms the current notebooks-list path enriches
  `firstNotePreview` and `noteCount`, or a proven minimal Swift contingency is
  documented, implemented, and covered.
- [x] Board cards show a plain-text, approximately three-line preview when
  non-empty and accessible note count metadata; empty previews have no block or
  placeholder.
- [x] List rows show note count with date metadata and an optional one-line
  plain-text preview while retaining compact layout.
- [x] Detail assignments render Folder first, named classes by deterministic
  label order, unknown non-null classes visibly, and classless Tags last.
- [x] Remove actions appear only for deletable assignments; add operations use
  only current, existing, unassigned catalog tags and preserve human
  provenance.
- [x] Folder remains the default navigation tab; Tags groups are collapsible,
  counted, class-scoped hierarchies with classless Tags last.
- [x] Folder, tag, and all-notebooks selections share one mutually exclusive
  scope, one-name `tagFilter`, and one generation boundary across List and
  Board.
- [x] Breadcrumbs use class labels and tag ancestry; missing/cyclic metadata
  terminates safely; catalog removal clears scope through the guarded reload.
- [x] Client, tree, controller, and Playwright tests cover selections,
  hierarchy/grouping, mutation protection, rendered previews, scope
  replacement, and stale completion rejection.
- [x] `fixture.assertClean()` passes and `web/scripts/audit-source.ts` reports no
  production fixture/mock/request-override violation.
- [x] Web lint, typecheck, unit tests, build, and e2e tests pass.
- [x] `swift build` plus RielaServerTests, RielaGraphQLTests, RielaNoteTests,
  and RielaAppSupportTests pass, with only evidence-backed known flakes
  excluded.
- [x] Directly affected repository documentation reflects the shipped behavior.
- [x] Independent implementation review has no unresolved high/mid finding.
- [ ] All scoped changes are committed on
  `feat/riela-note-web-tags-and-card-preview`; the worktree is clean; nothing is
  pushed and no pull request is opened.

## Progress-log expectations

After every task, review correction, or verification pass, append a dated entry
containing:

- task IDs and status transitions;
- files added/changed and concrete behavior delivered;
- backend-enrichment evidence and whether Swift remained untouched;
- dependencies unblocked or blockers introduced;
- tests added and exact commands run with pass/fail counts;
- review communication IDs, finding severities, decisions, and dispositions;
- Playwright scenarios and `fixture.assertClean()` evidence;
- known unrelated failures separated from feature failures;
- documentation decisions and residual risks; and
- commit hash when T7 completes.

Do not mark a task complete from code presence alone. Completion requires its
deliverables, focused verification, and a progress-log entry.

## Progress log

### 2026-07-26 — Step 4 plan creation

- **Status**: T1-T7 `NOT STARTED`; plan ready for Step 5 review.
- **Review input**: Step 3 `comm-000006` accepted
  `design-docs/specs/design-web-tags-and-card-preview.md` with decision
  `accepted_for_implementation_planning`, findings `[]`, feedback `[]`, and
  `needs_revision: false`.
- **Codex-agent references**: none; no Cursor adapter boundary is required.
- **Plan decision**: optional Tags-pane classed-tag creation is not scheduled
  because it is not an acceptance criterion; catalog-only detail membership is
  required.
- **Parallelism**: only T2, T3, and T4 are parallelizable after T1; their write
  scopes are disjoint.
- **Verification**: passed non-empty-file and trailing-whitespace checks,
  required-section/task/reference `rg` checks, and `git diff --check` for the
  accepted design and this plan; `git status --short --branch` confirmed the
  expected untracked design and plan on the target branch.
- **Blockers**: none.

### 2026-07-26 — Step 4 implementation-plan self-review

- **Decision**: accepted for independent implementation-plan review;
  `needs_design_revision: false`, `needs_revision: false`.
- **Design review**: no defect found; T1-T7 map to the accepted extension and
  base designs without adding an unsupported backend, authentication, or
  adapter architecture.
- **Plan corrections**: changed the pre-review status so it does not imply Step
  5 acceptance, and made assignment-section omission plus disabled/explained
  empty tag-picker behavior explicit in T5/T6.
- **Coverage review**: deliverables, dependencies, disjoint-write parallelism,
  completion criteria, progress logging, client/tree/controller/Playwright
  tests, typecheck, documentation review, full Bun/Swift gates, review, and
  commit handoff are explicit.
- **Codex-agent references**: none supplied; no Cursor adapter work applies.
- **Residual risks**: backend enrichment proof, metadata preservation across
  canonical mutation replacement, generation-guard integration, and
  evidence-based known-flake attribution remain implementation gates.

### 2026-07-26 — Step 6 implementation

- **Status**: T1-T6 `COMPLETED`; T7 implementation, documentation, and
  verification work completed; independent implementation review and commit
  remain.
- **Review input**: Step 5 `comm-000009` accepted this plan for implementation
  with findings `[]`, feedback `[]`, `needs_design_revision: false`, and
  `needs_revision: false`.
- **Backend enrichment evidence**: the GraphQL `notebooks` field in
  `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` delegates through
  `NoteGraphQLService.notebooks` to `NoteService.listNotebooks`; that list path
  calls the batch `enrichNotebookListMetadata` implementation in
  `Sources/RielaNote/NoteService.swift` and
  `Sources/RielaNote/NoteService+NotebookStats.swift`. Swift source remained
  unchanged.
- **Implementation**: added nullable-tolerant preview/count selections and
  metadata-preserving mutation projections; deterministic class-scoped tag
  trees, breadcrumbs, catalog and assignment groups; one folder/tag/all scope
  controller; List/Board previews and counts; all-class detail chips with
  protected removal and catalog-only addition; and Folder/Tags navigation with
  descendant delegation and stale-completion rejection.
- **Files changed**: `web/src/notes/types.ts`, `web/src/notes/client.ts`,
  `web/src/notes/client.test.ts`, `web/src/notes/tree.ts`,
  `web/src/notes/tree.test.ts`, `web/src/notes/controller.ts`,
  `web/src/notes/controller.test.ts`, `web/src/views/NotesView.tsx`,
  `web/src/styles.css`, `web/e2e/dashboard.spec.ts`, `README.md`,
  `.codex/skills/riela-impl-workflow/SKILL.md`, and this plan.
- **Web verification**: `bun run lint` passed ESLint and the production-source
  audit; `bun run typecheck` passed; `bun run test` passed 22 tests with 0
  failures; `bun run build` completed; and `bun run test:e2e` passed 18
  Playwright scenarios with `fixture.assertClean()` coverage.
- **Swift verification**: `swift build` passed; RielaServerTests passed 43,
  RielaGraphQLTests passed 104, and RielaNoteTests passed 123 tests with zero
  failures. The unfiltered RielaAppSupportTests run reproduced only the known
  `DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits`
  restart flake; rerunning with that accepted exclusion passed 222 tests with
  zero failures.
- **Documentation**: refreshed `README.md` and the Riela implementation-workflow
  skill with the shipped preview, classed membership, and shared tag-scope
  contracts.
- **Implementation corrections**: Playwright exposed and verified two
  integration corrections: delayed removal now updates the old notebook's
  scoped membership without replacing a newer detail selection, and
  failure-path feedback is recorded before closing the removed notebook detail.
  Step 6 self-review additionally cleared stale detail state when catalog
  removal resets a tag scope and restored a valid per-tree keyboard tab stop
  when switching from Folder to Tags navigation.
- **Codex-agent references**: none supplied.
- **Residual work**: independent implementation review, any resulting
  improvement pass, precommit safety inspection, and the final local commit.

### 2026-07-26 — Step 6 implementation self-review

- **Decision**: accepted for independent implementation review;
  `needs_revision: false`, findings `[]`.
- **Review input**: Step 6 `comm-000010`, the accepted extension/base designs,
  the active plan, the complete repository diff, and recorded verification.
- **Corrections**: catalog-removal scope reset now clears selected notebook,
  preview, and picker state so stale detail cannot reopen after the unfiltered
  reload. Folder and each Tags tree now retain an appropriate roving tab stop;
  Playwright covers disclosure, tree-item, and arrow-key reachability after a
  Folder-to-Tags switch.
- **Focused verification**:
  `bun run lint`, `bun run typecheck`, and `bun run test` passed; focused
  Playwright coverage passed 2 scenarios; the full `bun run test:e2e` passed 18
  scenarios with zero failures.
- **Scope review**: no Swift source, native UI, tag/class editing, combined
  scope, client descendant expansion, free-text tag mutation, CORS/auth, REST,
  or unrelated implementation entered the diff.
- **Verification review**: required web and Swift evidence is present; the only
  excluded Swift failure is the accepted
  `DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits`
  flake, and the remaining 222 RielaAppSupportTests passed.
- **Residual risks**: independent review and final commit remain; no high or
  mid implementation finding remains.

### 2026-07-26 — Step 7 acceptance, documentation refresh, and completion gate

- **Decision**: `accepted_adversarial_review_with_low_findings`; no unresolved
  high- or mid-severity finding remains. Review source: `comm-000014`.
- **Documentation refresh**: `comm-000015` updated `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md`; targeted
  `git diff --check -- README.md .codex/skills/riela-impl-workflow/SKILL.md`
  passed.
- **Verification accepted**: `cd web && bun run lint`, `typecheck`, `test`,
  `build`, and `test:e2e`; `swift build`; filtered `RielaServerTests`,
  `RielaGraphQLTests`, `RielaNoteTests`, and `RielaAppSupportTests` with the
  accepted `DaemonWorkflowNodePatchTests` exclusion; and `git diff --check`.
- **Codex-agent references**: none supplied.
- **Completion state**: accepted implementation work is complete. The plan is
  archived under `impl-plans/completed/` before commit-message generation; the
  final local commit and clean-worktree confirmation remain owned by the next
  workflow step.
- **Accepted low residual risks**: a catalog refresh can leave a stale add-tag
  selection enabled as a silent no-op; a scoped tag reclassified between
  folder and non-folder can stay hidden or mislabeled until scope clearing; and
  an explicitly null mutation preview can preserve older list metadata until
  refresh.
