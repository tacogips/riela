# Riela Note Book-Like Reader Implementation Plan

**Status**: Planning
**Workflow Mode**: issue-resolution
**Issue Reference**: `codex-design-and-implement-review-loop-session-1174` / `comm-000891`
**Design Reference**: `design-docs/specs/design-riela-note-ui-refinements.md:603`
**Created**: 2026-07-20
**Last Updated**: 2026-07-20

---

## Design Document Reference

**Source**: `design-docs/specs/design-riela-note-ui-refinements.md`
(`Book-Like Reader Addendum (2026-07-20)`, decisions D19-D25)

### Summary

Revamp the Riela Note notebook reading path into a vertical, page-snapping
reader over the existing pager order. Opening notebook notes presents one note
per full-container page, selection remains owned by
`RielaNoteLibraryViewModel`, pages render read-first by default, agent/comment
actions stay one visible tap away for the current note, and notes load lazily
through bounded window state instead of eager full-notebook prefetch.

### Scope

**Included**: `Sources/RielaNoteUI` reader, pager snapshot, file-tree notebook
page state, view-model selection/loading bridge, current-note agent/comment
affordance wiring, and tests in `Tests/RielaNoteUITests` plus any minimal
`Tests/RielaNoteTests` service coverage required by compile-time bridge changes.
If implementation does not change `Sources/RielaNote`, the progress log must
explicitly record that no `RielaNoteTests` additions were needed while still
running the full `RielaNoteTests` filter.

**Excluded**: unrelated note workspace redesign, daemon workflow fixes,
translate/web-dashboard code, removal of compose/edit features, origin pushes,
and full-notebook eager fetch behavior.

### References

- Step 1 intake: `comm-000891`, workflow execution
  `codex-design-and-implement-review-loop-session-1174`.
- Step 3 design review: `comm-000895`, accepted with no findings.
- Codex-agent references: none supplied.
- Cursor adapter behavior: not applicable; this is local `RielaNoteUI` reader
  behavior and introduces no CLI or agent-adapter semantics.

---

## Task Breakdown

### TASK-001: Confirm platform/API boundary
**Status**: NOT_STARTED
**Depends On**: -
**Write Scope**: none, unless a comment is needed in this plan's progress log
**Deliverables**:
- Confirm `Package.swift` minimum platforms remain `macOS 14` and `iOS 17`.
- Pick the exact SwiftUI paging API variant for implementation:
  `scrollPosition` + `scrollTargetBehavior(.paging)` +
  `containerRelativeFrame`, or the closest compatible equivalent preserving
  vertical one-page snapping by note id.
- Record any implementation-only conclusion about backward paging: no backward
  fetch unless a reader entry path can start before the accumulated forward
  window.

**Checklist**:
- [ ] Platform/API choice recorded in the progress log.
- [ ] Backward-fetch decision recorded before TASK-004 implementation.

---

### TASK-002: Extend bounded pager/window state
**Status**: NOT_STARTED
**Depends On**: TASK-001
**Write Scope**:
- `Sources/RielaNoteUI/RielaNoteFileTreeNotebookNotesPageState.swift`
- `Sources/RielaNoteUI/RielaNotePagerNoteSnapshot.swift`
- `Tests/RielaNoteUITests/RielaNoteFileTreeNotebookNotesPageStateTests.swift`
- `Tests/RielaNoteUITests/RielaNotePagerNoteSnapshotTests.swift`
**Deliverables**:
- Add a testable near-edge rule to request one additional notebook-notes page
  only when the selected/visible index is within the configured trailing-edge
  threshold.
- Preserve existing `isLoading`, `hasMore`, `didLoad`, offset, and `limit + 1`
  sentinel behavior.
- Refuse duplicate fetch triggers while loading, after `hasMore == false`, or
  before the threshold.
- Keep previous navigation backed by already accumulated notes unless TASK-001
  confirms a supported mid-notebook entry path requiring backward state.
- Extend snapshot/state tests for edge trigger, not-before-edge, loading guard,
  exhausted-window guard, and selected-position tracking.

**Checklist**:
- [ ] Near-edge decision helper is deterministic and unit-tested.
- [ ] No unbounded `while hasMore`-style fetch helper is added.
- [ ] Snapshot continues to expose current index, position text, previous, and
  next behavior over loaded notes.

---

### TASK-003: Bridge lazy page loading through the view model
**Status**: NOT_STARTED
**Depends On**: TASK-002
**Write Scope**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`
- `Sources/RielaNoteUI/RielaNoteFileTreePane.swift` if shared state ownership
  requires adjustment
- `Tests/RielaNoteUITests/RielaNoteLibraryNotebookPaginationTests.swift`
- `Tests/RielaNoteUITests/RielaNotePagerNoteSnapshotTests.swift`
**Deliverables**:
- Expose a reader-facing method that accepts the visible note id/index and asks
  the window state whether one next page should be fetched.
- Ensure the method fetches at most one page per trigger and is guarded by
  existing loading/has-more state.
- Keep `RielaNoteLibraryViewModel.pagerNoteSnapshot` as the shared ordering
  source for detail reader, keyboard navigation, and left-pane Notes mode.
- Route page-selection changes through the existing guarded note-selection path
  instead of direct selected-note mutation.

**Checklist**:
- [ ] Visible-page changes update selection through the guarded path.
- [ ] Selection changes keep current-page/snapshot position text consistent.
- [ ] Lazy fetch tests prove one-page trigger behavior and no duplicate load
  while loading.

---

### TASK-004: Replace primary detail body with a vertical snap reader
**Status**: NOT_STARTED
**Depends On**: TASK-001, TASK-003
**Write Scope**:
- `Sources/RielaNoteUI/RielaNoteDetailView.swift`
- Optional small extracted reader view under `Sources/RielaNoteUI/`
- `Tests/RielaNoteUITests/RielaNoteDraftMarkdownTests.swift`
- `Tests/RielaNoteUITests/RielaNoteNavigationGuardTests.swift`
**Deliverables**:
- Render loaded notes as a lazy vertical page stack, one note per full reader
  container, with page ids equal to `noteId`.
- Bind scroll position to the selected note id in both directions while
  guarding no-op repeats and stale async selection.
- Keep existing previous/next buttons and keyboard shortcuts as secondary
  selection controls.
- Disable pager scrolling and previous/next shortcuts while
  `bodyDraft.isEditingBody` is true.
- Ensure default page rendering uses `RielaNoteMarkdownBodyView`, not an
  editable body field.

**Checklist**:
- [ ] Opening note detail is view-first with `isEditingBody == false`.
- [ ] Edit mode requires the explicit existing edit action.
- [ ] Programmatic selection scrolls to the selected note without selection
  loops.
- [ ] Reader approaches the window edge by calling TASK-003 lazy-load bridge.

---

### TASK-005: Add current-note agent and comment affordance wiring
**Status**: NOT_STARTED
**Depends On**: TASK-004
**Write Scope**:
- `Sources/RielaNoteUI/RielaNoteDetailView.swift`
- `Sources/RielaNoteUI/RielaNoteRootView.swift` or existing agent wiring files
  only if needed to focus/expand `RielaNoteAgentBottomBar`
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`
- `Tests/RielaNoteUITests/RielaNoteAgentViewModelTests.swift`
- `Tests/RielaNoteUITests/RielaNoteUITests.swift` or current equivalent
**Deliverables**:
- Keep an agent action visible from the reader for the currently visible note,
  routing through the existing `RielaNoteAgentBottomBar` / agent view-model
  path.
- Keep an add-comment action visible from the reader for the currently visible
  note, routing through `RielaNoteUIClient.addComment`; avoid
  `Sources/RielaNote` changes because `NoteService.addComment` already exists
  unless compile-time wiring proves a missing bridge.
- Refresh only the current selected detail after comment creation.
- Add view-model-level tests for current-note action target selection and
  one-tap affordance wiring.

**Checklist**:
- [ ] Agent action targets the visible/selected note context.
- [ ] Comment action persists through existing comment APIs.
- [ ] No second agent execution path is introduced.

---

### TASK-006: Verification and evidence pass
**Status**: NOT_STARTED
**Depends On**: TASK-002, TASK-003, TASK-004, TASK-005
**Write Scope**:
- changed test files only for fixes driven by verification
- `README.md`, this implementation plan, and directly affected Riela Note
  user-facing docs or workflow skills only when documentation needs updates
- progress log in this plan
**Deliverables**:
- Run required verification commands:
  - `swift build`
  - `swift test --filter RielaNoteUITests`
  - `swift test --filter RielaNoteTests`
- Run code search over the reader path to confirm no eager full-notebook fetch:
  - `rg -n "while .*hasMore|hasMore.*while|loadAll|prefetch" Sources/RielaNoteUI`
- Review repository-facing documentation before handoff: `README.md`, this
  implementation plan, and any directly affected Riela Note user-facing docs or
  workflow skills. Update them when behavior changes are user-facing; otherwise
  record an explicit no-doc-change rationale in the progress log.
- If `Sources/RielaNote` changes are required for comment or paging bridges,
  add concrete `Tests/RielaNoteTests` service coverage. If no
  `Sources/RielaNote` behavior changes, record that rationale in the progress
  log while still running `swift test --filter RielaNoteTests`.
- Record command outcomes, failures, and any accepted unrelated gaps in the
  progress log.

**Checklist**:
- [ ] Required commands pass or failures are explicitly classified.
- [ ] No eager full-notebook reader fetch path is present.
- [ ] New/extended tests cover window-edge trigger, no-refetch-while-loading,
  current-page tracking, view-first default, and one-tap action wiring.
- [ ] Documentation was updated or an explicit no-doc-change rationale was
  recorded after reviewing repository-facing docs.
- [ ] `Tests/RielaNoteTests` additions were made for any `Sources/RielaNote`
  behavior change, or an explicit no-service-change rationale was recorded.

---

## Dependencies

- TASK-001 must finish before selecting the pager API in `RielaNoteDetailView`
  or deciding whether backward page state is needed.
- TASK-002 precedes TASK-003 because the view-model bridge should call a stable
  state helper.
- TASK-003 precedes TASK-004 because the reader's page-appearance hook needs a
  view-model method to trigger bounded lazy loading.
- TASK-004 precedes TASK-005 because current-note actions must attach to the
  visible reader page/selection behavior.
- TASK-006 closes the work package after all implementation tasks land.

## Parallelization

- TASK-002 and TASK-004 are not parallelizable once writing starts because both
  affect pager contracts consumed by `RielaNoteDetailView`.
- TASK-005 is not parallelizable with TASK-004 because both write
  `RielaNoteDetailView.swift`.
- Test-only additions for TASK-002 can be drafted in parallel with TASK-003
  only after the state helper signatures are agreed, because write scopes are
  then disjoint.

## Progress Log Expectations

- Append dated entries under this section during implementation.
- Each entry should list task ids touched, files changed, verification commands
  run, and any deviations from the accepted design.
- Do not mark a task checklist complete until its deliverables and related tests
  have been updated or an accepted deferral is recorded.

### Progress Log

- 2026-07-20: Plan created from accepted Step 2 design addendum and Step 3
  review.
- 2026-07-20: Addressed Step 4 self-review `comm-000897`: TASK-006 now
  requires documentation review/update or no-doc-change rationale, and clarifies
  the `Tests/RielaNoteTests` obligation when `Sources/RielaNote` does or does
  not change.

## Completion Criteria

- Opening a notebook's notes shows a vertical one-note-per-page snap reader.
- Selection remains owned by `RielaNoteLibraryViewModel` and synchronized with
  pager scroll position, previous/next controls, keyboard shortcuts, and
  left-pane Notes selection.
- Reader pages are read-only by default; body editing requires the existing
  explicit edit affordance and disables pager movement while active.
- Agent request and add-comment actions for the current note are each one
  visible tap away from the reader.
- Notes load lazily through bounded page-window triggers; the reader does not
  eagerly fetch or loop through the whole notebook.
- Required verification commands pass:
  `swift build`, `swift test --filter RielaNoteUITests`, and
  `swift test --filter RielaNoteTests`.

## Risks

- SwiftUI scroll-position APIs on `macOS 14` / `iOS 17` may require a small
  compatibility wrapper to preserve the accepted paging contract.
- Scroll-position changes and guarded note selection can form loops unless
  no-op and stale async updates are explicitly filtered.
- The current branch's forward-offset paging may be insufficient only if
  implementation confirms a mid-notebook entry path without accumulated
  previous pages.
- One-tap current-note actions must reuse existing agent/comment pathways; a
  parallel agent or comment route would violate the accepted design boundary.
