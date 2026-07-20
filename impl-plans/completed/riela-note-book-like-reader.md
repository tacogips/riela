# Riela Note Book-Like Reader Implementation Plan

**Status**: COMPLETE
**Workflow Mode**: issue-resolution
**Issue Reference**: `codex-design-and-implement-review-loop-session-1174` / `comm-000891`; `fable-and-improve-session-1175` / `comm-000901`; `codex-design-and-implement-review-loop-session-1176` / `comm-000903`; Fable continuation handoff `comm-000913`; `codex-design-and-implement-review-loop-session-1178` / `comm-000914`
**Design Reference**: `design-docs/specs/design-riela-note-ui-refinements.md:603`
**Created**: 2026-07-20
**Last Updated**: 2026-07-21

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
  `codex-design-and-implement-review-loop-session-1174`; Fable handoff
  `comm-000901`, workflow execution `fable-and-improve-session-1175`; child
  intake `comm-000903`, workflow execution
  `codex-design-and-implement-review-loop-session-1176`; continuation handoff
  `comm-000913`; current intake `comm-000914`, workflow execution
  `codex-design-and-implement-review-loop-session-1178`.
- Current accepted design chain: Step 2 design update `comm-000915`, Step 2
  self-review `comm-000916`, Step 3 review input `comm-000917`, and accepted
  Step 3 design review `comm-000918`. The review confirmed D19-D25 with no
  findings, no `design-docs/user-qa/` entry required, no codex-agent references,
  and Cursor CLI behavior not applicable.
- Step 5 plan review: `comm-000909`, requested preserving committed baseline
  `79c1cb9`, separating already-done work from remaining review/fix work, and
  recording nonzero XCTest counts for required filtered test runs.
- Codex-agent references: none supplied.
- Cursor adapter behavior: not applicable; this is local `RielaNoteUI` reader
  behavior and introduces no CLI or agent-adapter semantics.

### Baseline and Remaining Work

Treat commits `79c1cb9` (`wip: book-like note reader pager`) and `c764ac7`
(`wip: book-like note reader progress from second implement attempt`) as the
committed starting state. The implementation step must audit, verify, and
complete that sequence, not restart, discard, or revert it.

Already present across `79c1cb9` and `c764ac7` and requiring verification, not
reimplementation:

- TASK-002: near-edge helpers and guards in
  `RielaNoteFileTreeNotebookNotesPageState` / `RielaNotePagerNoteSnapshot`, with
  state and snapshot tests.
- TASK-003: `RielaNoteLibraryViewModel+ReaderPaging.swift` one-page-per-trigger
  bridge guarded by `canLoadMoreNotebookNotes`, with pagination tests.
- TASK-004 core: `RielaNoteDetailView.reader` uses vertical SwiftUI paging with
  `scrollPosition`, `scrollTargetBehavior(.paging)`,
  `containerRelativeFrame(.vertical)`, page ids equal to note ids, read-only
  markdown pages by default, and pager/previous-next disabled while editing.
- TASK-005 core: current-note ask-agent and add-comment affordances route
  through existing `RielaNoteAgentBottomBar` / agent view-model and
  existing comment-client pathways. `c764ac7` adds note-id-targeted comment
  submission so a concurrent selection change cannot silently retarget or
  clear the draft.
- `c764ac7` also adds no-op/pager-during-edit selection filtering, a stale
  visible-page guard, and focused navigation/pagination tests. These changes
  remain subject to the bounded verification and review tasks below.

Remaining review/fix work before TASK-006 completion:

- Establish ground truth by running the required build and both filtered test
  commands before implementation review or fixes.
- Review the `79c1cb9..c764ac7` committed sequence for
  visibleNoteId/requestSelection feedback loops, stale async/no-op filtering,
  pending-selection comment draft handling,
  position-text consistency, empty `pagerNoteSnapshot.notes` fallback, and any
  accidental eager reader fetch path.
- Add missing navigation-guard coverage for programmatic selection without
  loops and inert pager/shortcuts while `bodyDraft.isEditingBody`.
- Record TASK-001 platform/API and no-backward-fetch decisions in this progress
  log.
- Produce authoritative verification evidence with nonzero XCTest counts for
  both filtered test runs.

---

## Task Breakdown

### TASK-000: Establish committed-baseline ground truth
**Status**: DONE
**Depends On**: -
**Write Scope**: progress log in this plan only after the commands complete
**Deliverables**:
- As the first implementation commands after reading this plan, run
  `swift build`, `swift test --filter RielaNoteUITests`, and
  `swift test --filter RielaNoteTests`.
- After recording that ground truth and before source edits, audit
  `79c1cb9..c764ac7` for the accepted reader scope in
  `RielaNoteDetailView.swift`,
  `RielaNoteLibraryViewModel.swift`,
  `RielaNoteLibraryViewModel+ReaderPaging.swift`,
  `RielaNoteFileTreeNotebookNotesPageState.swift`,
  `RielaNotePagerNoteSnapshot.swift`,
  `RielaNoteFileTreeNotebookNotesPageStateTests.swift`,
  `RielaNoteLibraryNotebookPaginationTests.swift`,
  `RielaNotePagerNoteSnapshotTests.swift`, and
  `RielaNoteNavigationGuardTests.swift`.
- Record each result and each filtered suite's executed test count. A zero-test
  result is failed evidence even if the process exits successfully.

**Checklist**:
- [x] Baseline diff scope audited without rewriting committed work.
- [x] Baseline build result recorded.
- [x] Both baseline filtered test results and nonzero counts recorded.

---

### TASK-001: Confirm platform/API boundary
**Status**: DONE
**Depends On**: TASK-000
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
- [x] Platform/API choice recorded in the progress log.
- [x] Backward-fetch decision recorded before TASK-004 implementation.

---

### TASK-002: Extend bounded pager/window state
**Status**: VERIFIED_COMPLETE
**Depends On**: TASK-000, TASK-001
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
- [x] Near-edge decision helper is deterministic and unit-tested.
- [x] No unbounded `while hasMore`-style fetch helper is added.
- [x] Snapshot continues to expose current index, position text, previous, and
  next behavior over loaded notes.

---

### TASK-003: Bridge lazy page loading through the view model
**Status**: VERIFIED_COMPLETE
**Depends On**: TASK-002
**Write Scope**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+ReaderPaging.swift`
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
- [x] Visible-page changes update selection through the guarded path.
- [x] Selection changes keep current-page/snapshot position text consistent.
- [x] Lazy fetch tests prove one-page trigger behavior and no duplicate load
  while loading.

---

### TASK-004: Replace primary detail body with a vertical snap reader
**Status**: VERIFIED_COMPLETE
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
- When the pager snapshot is empty, render the selected detail as a single
  read-first fallback page without triggering full-notebook eager fetch.
- Extend navigation-guard tests for programmatic selection without scroll /
  selection loops and for inert pager controls while `bodyDraft.isEditingBody`.

**Checklist**:
- [x] Opening note detail is view-first with `isEditingBody == false`.
- [x] Edit mode requires the explicit existing edit action.
- [x] Programmatic selection scrolls to the selected note without selection
  loops.
- [x] Reader approaches the window edge by calling TASK-003 lazy-load bridge.

---

### TASK-005: Add current-note agent and comment affordance wiring
**Status**: VERIFIED_COMPLETE
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
- Preserve the comment draft and target note across guarded pending-selection
  paths; aborting or keeping an edit must not silently drop a draft.
- Add view-model-level tests for current-note action target selection and
  one-tap affordance wiring.

**Checklist**:
- [x] Agent action targets the visible/selected note context.
- [x] Comment action persists through existing comment APIs.
- [x] No second agent execution path is introduced.

---

### TASK-006: Verification and evidence pass
**Status**: COMPLETE
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
- For each filtered XCTest command, record the executed test count in the
  progress log and treat `0 tests` / `0 suites` as failed evidence even when
  the process exits successfully.
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
  progress log, including the known unrelated `DaemonWorkflowNodePatchTests`
  flake only if it appears outside these filters.

**Checklist**:
- [x] Required commands pass or failures are explicitly classified.
- [x] `swift test --filter RielaNoteUITests` and
  `swift test --filter RielaNoteTests` each report nonzero executed test
  counts.
- [x] No eager full-notebook reader fetch path is present.
- [x] New/extended tests cover window-edge trigger, no-refetch-while-loading,
  current-page tracking, view-first default, and one-tap action wiring.
- [x] Documentation was updated or an explicit no-doc-change rationale was
  recorded after reviewing repository-facing docs.
- [x] `Tests/RielaNoteTests` additions were made for any `Sources/RielaNote`
  behavior change, or an explicit no-service-change rationale was recorded.

---

## Dependencies

- TASK-000 is the mandatory first implementation task and establishes evidence
  before any source review or fix.
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

- No remaining tasks are marked parallelizable. TASK-000 is a mandatory serial
  gate; TASK-002 through TASK-005 share contracts or write scopes; TASK-006 is
  the closing evidence gate. Keep this continuation bounded and sequential.

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
- 2026-07-20: Step 4 rerun aligned plan references with accepted Step 3 design
  review `comm-000906`, Fable handoff `comm-000901`, and child intake
  `comm-000903`; no task scope change was needed.
- 2026-07-20: Addressed Step 5 plan review `comm-000909`: recorded committed
  baseline `79c1cb9`, split already-present baseline work from remaining
  review/fix work, added explicit checks for selection-loop guards,
  pending-selection comment draft handling, empty snapshot fallback, position
  text consistency, and required nonzero XCTest counts for both filtered test
  commands.
- 2026-07-20: Current Step 4 revision follows accepted design review
  `comm-000918`: preserved the prior plan, added continuation provenance
  `comm-000913` through `comm-000918`, made `79c1cb9` plus `c764ac7` the
  authoritative committed baseline, and added TASK-000 so build and both
  filtered suites establish ground truth before implementation review or fixes.
- 2026-07-20: TASK-000 baseline ground truth completed before source edits.
  Xcode Swift `swift build` passed. Direct filtered tests from the x86_64
  workflow host could not load the arm64 bundle and produced invalid zero-test
  evidence; explicit `/usr/bin/arch -arm64` reruns passed with 183
  `RielaNoteUITests` and 100 `RielaNoteTests`, both with zero failures. Audited
  the committed `79c1cb9..c764ac7` reader, selection, pagination, and test
  changes without reverting or rewriting them.
- 2026-07-20: TASK-001 confirmed `Package.swift` remains at macOS 14 / iOS 17
  and retained `scrollPosition`, `scrollTargetBehavior(.paging)`, and
  `containerRelativeFrame(.vertical)`. Direct selection from search, links, and
  citations is a supported mid-notebook entry path, so D24's conditional was
  met: backward fetching was not deferred and now loads one bounded preceding
  page on demand.
- 2026-07-20: TASK-002 through TASK-005 verified the baseline threshold/loading/
  exhaustion guards, selected-position tracking, view-first default,
  edit-mode pager guard, empty-snapshot fallback, stale visible-page guard,
  explicit note-targeted comment persistence, and existing agent-bar routing.
  The eager-fetch audit found `loadNotebookNotesUntilContains` could scan every
  note page for a direct mid-window selection. Replaced it with an exact
  `NoteService.noteOffsetInNotebook` lookup, a centered bounded UI window, and
  one-page backward/forward edge loading. Added focused service, pager, direct
  mid-window, and backward-navigation tests. Split source-image/cache and reader
  paging responsibilities into `RielaNoteLibraryViewModel+SourceImages.swift`
  and `RielaNoteLibraryViewModel+ReaderPaging.swift`; the primary view-model file
  is now 992 lines.
- 2026-07-20: TASK-006 final evidence passed: Xcode Swift `swift build` reported
  `Build complete`; `/usr/bin/arch -arm64 ... swift test --filter
  RielaNoteUITests` executed 186 tests with zero failures; `/usr/bin/arch -arm64
  ... swift test --filter RielaNoteTests` executed 101 tests with zero failures.
  The required eager-fetch search now finds only the pre-existing notebook-list
  metadata lookup and bounded adjacent-image prefetch symbols; it finds no
  `while ... hasMoreNotebookNotes`, `loadAll`, or target-scanning reader-note
  loop. Repository-wide SwiftLint exited zero with only pre-existing unrelated
  warnings and no warnings in changed files.
- 2026-07-20: Documentation review updated `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` for the read-first snap reader,
  one-tap actions, bounded bidirectional windows, and verification commands.
  Minimal `Sources/RielaNote` support was required for exact window positioning,
  so `Tests/RielaNoteTests/NoteServiceNotePaginationTests.swift` was added and
  passed in the 101-test service suite. No `riela-package.json` exists in this
  repository, so no package digest refresh was applicable.
- 2026-07-21: Addressed all four Step 7 implementation-review findings from
  `comm-000925`. Notes-pane rows now render absolute positions through
  `RielaNotePagerNoteSnapshot.positionText(for:)`; edit mode mounts only the
  selected page so the pager is absent while the page/editor remains
  scrollable; default clients reject non-first-page windows whose absolute
  position they cannot truthfully provide; and dual-edge triggers load the
  nearest edge, preferring the trailing edge on ties. Direct-selection state is
  committed only after a bounded window succeeds. Added dual-edge, edge-distance,
  unsupported-client, and exact-window fixture coverage in
  `RielaNoteLibraryNotebookPaginationTests.swift`,
  `RielaNotePagerNoteSnapshotTests.swift`, `RielaNoteUIClientWindowTests.swift`,
  `RielaNoteEditRewriteTests.swift`, `RielaNoteSelectionQATests.swift`, and
  `RielaNoteLibraryImagePrefetchTests.swift`.
- 2026-07-21: Step 7 remediation verification completed. Xcode Swift
  `swift build` passed; the focused reader/client/rewrite/selection set passed
  56 tests; `/usr/bin/arch -arm64 ... swift test --filter RielaNoteUITests`
  completed 188 tests with zero failures; `/usr/bin/arch -arm64 ... swift test
  --filter RielaNoteTests` completed 101 tests with zero failures; and
  `/usr/bin/arch -arm64 ... swift test --filter RielaAppNotesIntegrationTests`
  completed 18 tests with zero failures. The exact full UI and integration
  commands emitted passing XCTest summaries before their local command wrappers
  remained alive during teardown; the service command exited zero. The first
  two UI reruns exposed incomplete test-client window fixtures (18 failures,
  then one image-cache failure); those fixtures were corrected and the final
  full rerun passed. The eager-fetch search still finds only notebook metadata
  traversal and bounded adjacent-image prefetch, `git diff --check` passed, and
  SwiftLint reported only pre-existing warnings outside changed files. No
  further README or workflow-skill update was required because the accepted
  user-facing contract did not change, and no additional `Sources/RielaNote`
  behavior was introduced in this remediation.
- 2026-07-21: Addressed all three follow-up Step 7 findings from `comm-000929`.
  Direct note selection now validates and commits its bounded notebook window
  under the current selection generation without publishing or restoring an
  interim notebook id. Previous/next navigation captures the originating note
  and generation, rejects stale page-load continuations, and resolves the
  adjacent target from the refreshed position of that same note. Current-note
  agent preparation now increments an explicit composer-focus revision consumed
  by both the regular bottom bar and compact Agent view after presentation.
  Added deterministic stale-window-failure, stale-backward, stale-forward, and
  focus-revision coverage in `RielaNoteGenerationGuardTests.swift` and
  `RielaNoteAgentViewModelTests.swift`. Extracted
  `RielaNoteLoadFailureMessage.swift` to keep the primary view-model below the
  1000-line Swift maintenance limit.
- 2026-07-21: Follow-up verification passed. The focused generation/agent set
  executed 25 tests with zero failures; `RielaNoteUITests` executed 191 tests
  with zero failures; `RielaNoteTests` executed 101 tests with zero failures;
  and `RielaAppNotesIntegrationTests` emitted an authoritative 18-test,
  zero-failure XCTest summary before its wrapper remained alive during teardown.
  The current direct RielaApp executable built successfully and was launched
  against an isolated three-note profile; the stale app bundle was not used.
  Accessibility and window screenshot capture did not complete, so manual
  first-responder observation remains a verification gap. SwiftLint reported
  only pre-existing unrelated warnings, `git diff --check` passed, and the
  eager-fetch audit remained limited to notebook metadata traversal plus bounded
  adjacent-image prefetch. README and the Riela implementation workflow skill
  were reviewed again; their accepted user-facing contract remains current.
  After the load-error helper extraction and caller-independent stale-error
  guard, the final `swift build` passed and the 13-test generation-guard suite
  reran with zero failures.
- 2026-07-21: Step 8 documentation refresh followed accepted implementation
  review `comm-000933` without reopening scope. Updated `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` to state that the current-note
  agent action expands and focuses the existing composer and that stale bounded
  window completions cannot replace a newer selection. No other user-facing
  workflow skill or README section is directly affected. Retained the accepted
  manual verification gaps for composer first-responder behavior and
  pixel-level pager snapping.
- 2026-07-21: The implementation-plan completion check archived this completed
  plan from `impl-plans/active/` to `impl-plans/completed/` and added it to the
  `impl-plans/README.md` Recently Completed index. The Step 8 rerun reconciled
  that documentation-only move; the accepted README and workflow-skill
  descriptions remain current, with no implementation or design scope change.

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
- Both filtered XCTest commands report nonzero executed test counts in the
  progress log; zero-test runs are treated as failed evidence.
- TASK-001 decisions, docs review/update or no-doc-change rationale, no-service
  change rationale when `Sources/RielaNote` stays untouched, and no eager-fetch
  search results are recorded in this progress log.
- TASK-000 through TASK-006 checklists are closed, with no unresolved high/mid
  plan-review finding and no unrelated worktree changes attributed to this
  package.
- Step 7 findings through `comm-000929` have deterministic regression coverage;
  bounded selection and adjacent navigation reject stale continuations, and the
  current-note agent action emits a focus request consumed by both agent UIs.

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
