# Riela Note Workspace Hardening Implementation Plan

**Status**: Implemented
**Design Reference**: `design-docs/specs/design-riela-note-ui-refinements.md#workspace-hardening-addendum-2026-07-19`
**Issue Reference**: `codex-design-and-implement-review-loop-session-1171` / `comm-000851`
**Workflow Mode**: issue-resolution
**Created**: 2026-07-19
**Last Updated**: 2026-07-19

---

## Source Of Truth

Accepted design: Workspace Hardening Addendum decisions D12-D18 in
`design-docs/specs/design-riela-note-ui-refinements.md`.

Scope is one work package on branch `feat/riela-note-workspace-revamp`.
Primary write scope is `Sources/RielaNoteUI` and `Tests/RielaNoteUITests`.
`Sources/RielaApp/NoteWindowController.swift` may change only if host compile
integration requires it. Do not touch translate code, web dashboard code, or
daemon workflow code.

## Reference Paths

- `Sources/RielaNoteUI/RielaNoteAgentBottomBar.swift` - bottom agent send
  button and folded state.
- `Sources/RielaNoteUI/RielaNoteAgentView.swift` - full agent send button.
- `Sources/RielaNoteUI/RielaNoteComposeView.swift` - existing Cmd-Return save
  shortcut that must remain separate from agent send.
- `Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift` - search-result
  selection from the popup.
- `Sources/RielaNoteUI/RielaNoteRootView.swift` - pending-selection dialog,
  left/right pane chrome, file-tree host, search-popup presentation, store
  watcher hookup.
- `Sources/RielaNoteUI/RielaNoteFileTreePane.swift` - notebook note cache and
  file-tree note loading.
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` - pending selection,
  selected note/notebook state, previous/next note actions.
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` - detail pager consumers.
- `Sources/RielaNoteUI/RielaNoteMetadataPane.swift` - custom panel and chip
  color audit scope.
- `Tests/RielaNoteUITests/RielaNoteLibraryNotebookPaginationTests.swift` -
  pagination test precedent.
- `Tests/RielaNoteUITests/RielaNoteLibraryRefreshTests.swift` - store-change
  watcher and refresh test precedent.
- `Tests/RielaNoteUITests/RielaNoteNavigationGuardTests.swift` -
  pending-selection guard test precedent.

No external Codex reference repository or Cursor adapter reference is part of
this intake. The Codex-agent references are workflow/session provenance only:
`step2-design-self-review`, `step3-design-review`, and
`codex-design-and-implement-review-loop-session-1171`.

---

## Task Breakdown

### TASK-001: Baseline and ownership check

**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- Confirm current branch is `feat/riela-note-workspace-revamp`.
- Record pre-change `git status --short`.
- Run baseline verification commands if practical:
  `swift build`, `swift test --filter RielaNoteUITests`, and
  `swift test --filter RielaAppNotesIntegrationTests`.
- Record known unrelated failures without fixing them, especially
  `DaemonWorkflowNodePatchTests/testRuntimeRestartsWorkflowWhenEventSourceExits`
  if it appears outside targeted suites.

**Completion criteria**:
- Baseline state and any pre-existing failures are captured in this plan's
  Progress Log before implementation edits begin.

---

### TASK-002: Return-key send safety

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteAgentBottomBar.swift` - remove the bare
  `.keyboardShortcut(.return, modifiers: [])` from the send button.
- `Sources/RielaNoteUI/RielaNoteAgentView.swift` - remove the bare
  `.keyboardShortcut(.return, modifiers: [])` from the send button.
- Leave `Sources/RielaNoteUI/RielaNoteComposeView.swift` Cmd-Return save
  behavior unchanged.
- Confirm the agent composer still sends through its focused submit path.

**Completion criteria**:
- Plain Return in note body, comment, tag, rewrite, link/search, or other text
  inputs has no global agent-send registration.
- Composer submit remains reachable through the existing input submit handling.

---

### TASK-003: Shared pager-order data source

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` - introduce a
  testable ordered-note snapshot for the selected notebook, exposing ordered
  notes, current index, total count, previous note, and next note.
- Update `.previousNote` and `.nextNote` handling to consume that snapshot
  instead of maintaining separate ordering logic.
- `Tests/RielaNoteUITests` - add focused tests for ordering parity, current
  index, total count, previous/next values, and no-selection edge cases.

**Completion criteria**:
- Detail pager behavior and Notes-tab behavior can derive from the same
  snapshot without duplicate order rules.

---

### TASK-004: Left-pane Tree/Notes modes

**Status**: COMPLETED
**Depends On**: TASK-003
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteRootView.swift` - add a Tree/Notes tab
  switcher at the top of the left pane while preserving compact
  `NavigationStack` behavior and keeping macOS-only split view code behind
  `#if os(macOS)`.
- Add the Notes mode UI using the TASK-003 ordered snapshot. It lists the
  selected notebook's notes in pager order, highlights the selected note, and
  displays row position such as `3/12`.
- Route row clicks through the existing guarded selection path; do not mutate
  selected note id directly from the row.
- `Tests/RielaNoteUITests` - cover tab-selection logic and guarded row
  selection behavior that is testable without GUI automation.

**Completion criteria**:
- Tree and Notes modes coexist in the left pane, and Notes rows cannot bypass
  pending-selection protection for unsaved body edits.

---

### TASK-005: Search-popup pending-selection reachability

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift` and/or
  `Sources/RielaNoteUI/RielaNoteRootView.swift` - when search-popup result
  selection creates `viewModel.pendingSelection`, dismiss the popup or host
  the same confirmation so Discard and Keep Editing are reachable.
- Preserve root dialog ownership: the binding that hides the dialog must not
  clear `pendingSelection`; only explicit Discard or Keep Editing resolves it.
- Extend `Tests/RielaNoteUITests/RielaNoteNavigationGuardTests.swift` or add a
  sibling test for pending-selection preservation and discard/keep routing.

**Completion criteria**:
- Selecting a popup result during an active body edit always surfaces a
  reachable confirmation; Discard navigates, Keep Editing preserves the draft.

---

### TASK-006: File-tree invalidation and pagination

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteFileTreePane.swift` - replace load-once
  notebook note caching with an invalidatable paged model.
- Add a small testable helper or view-model type for page state, note-id merge,
  ordering preservation, next-page detection, and reset.
- Use `client.listNotes(notebookId:limit:offset:)` for offset-based load more.
- Invalidate/refetch on explicit `viewModel.refresh()` and
  `RielaNoteStoreChangeWatcher` note-store changes. If root-view plumbing is
  required, coordinate with TASK-004/TASK-007 before editing
  `RielaNoteRootView.swift`.
- `Tests/RielaNoteUITests` - cover first page, load-more page, duplicate note
  id merge, reset after refresh, and reset after store-change notification.

**Completion criteria**:
- Newly created/deleted notes appear after refresh or store change, and
  notebooks beyond the first page expose and load additional notes.

---

### TASK-007: Workspace chrome persistence

**Status**: COMPLETED
**Depends On**: TASK-004
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteRootView.swift` - persist left pane expanded,
  right pane expanded, and selected left-pane mode with `AppStorage` or an
  equivalent scene-persistent mechanism scoped to Riela Note workspace keys.
- `Sources/RielaNoteUI/RielaNoteAgentBottomBar.swift` - persist folded state
  through the same workspace-state approach.
- Keep persisted chrome state out of note-store data and out of direct
  `RielaNoteLibraryViewModel` tests.

**Completion criteria**:
- Pane expansion, selected Tree/Notes mode, and agent folded state survive app
  relaunch without altering note content or service state.

---

### TASK-008: Dark/light semantic color audit

**Status**: COMPLETED
**Depends On**: TASK-002, TASK-004, TASK-005, TASK-006, TASK-007
**Deliverables**:
- Sweep changed note-workspace panels plus existing custom panels in:
  `RielaNoteAgentBottomBar.swift`, `RielaNoteAgentView.swift`,
  `RielaNoteRootView.swift`, `RielaNoteFileTreePane.swift`,
  `RielaNoteDetailView.swift`, and `RielaNoteMetadataPane.swift`.
- Replace hard-coded theme assumptions with semantic SwiftUI/system roles for
  backgrounds, borders, selected rows, disabled controls, chips, and secondary
  text.
- Keep opacity overlays only where legibility is documented by manual visual
  checks in both light and dark appearance.

**Completion criteria**:
- Custom note-workspace surfaces remain legible and visually coherent in dark
  and light appearance.

---

### TASK-009: Verification, review notes, and commit

**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003, TASK-004, TASK-005, TASK-006, TASK-007, TASK-008
**Deliverables**:
- Run:
  - `swift build`
  - `swift test --filter RielaNoteUITests`
  - `swift test --filter RielaAppNotesIntegrationTests`
- Record precise manual GUI verification steps for:
  - Return routing in body editor, comment editor, tag field, rewrite input,
    and composer submit.
  - Search-popup discard and keep-editing paths.
  - Relaunch persistence for panes, Tree/Notes mode, and agent fold.
  - Dark/light appearance pass for custom panels.
- Confirm `git status --short` contains only intended files before commit.
- Commit all work on `feat/riela-note-workspace-revamp`; do not push.

**Completion criteria**:
- Build and targeted tests pass or any failure is explicitly documented as
  unrelated and pre-existing.
- One branch-local commit contains the design update, implementation plan,
  code/tests, and review notes; no push is performed.

---

## Dependencies

- TASK-001 precedes all edits.
- TASK-003 precedes TASK-004 because Notes mode depends on the shared pager
  snapshot.
- TASK-004 precedes TASK-007 because selected left-pane mode must exist before
  persistence can be wired.
- TASK-008 follows functional UI edits so the color audit covers the final
  custom panels.
- TASK-009 follows all implementation and audit tasks.

## Parallelization Notes

Parallel work is optional and should be conservative because several tasks
touch `RielaNoteRootView.swift`.

- TASK-002 and TASK-003 are parallelizable after TASK-001; write scopes are
  disjoint (`RielaNoteAgentBottomBar.swift`/`RielaNoteAgentView.swift` versus
  `RielaNoteLibraryViewModel.swift` and pager tests).
- TASK-006 helper/test work is parallelizable with TASK-003 only until it needs
  root-view invalidation wiring. Once `RielaNoteRootView.swift` is edited,
  coordinate with TASK-004/TASK-007.
- TASK-005 is not marked parallelizable with TASK-004 or TASK-007 because it
  may also touch root presentation state.

## Verification

- Baseline and final: `swift build`.
- Final targeted suites:
  `swift test --filter RielaNoteUITests` and
  `swift test --filter RielaAppNotesIntegrationTests`.
- Targeted unit coverage must include pager-order snapshot behavior, file-tree
  pagination/invalidation helper behavior, and guarded Notes-tab row selection.
- Manual GUI evidence must be written into the Progress Log or final review
  notes because Return routing, dialog reachability, relaunch persistence, and
  appearance checks are GUI-only in this plan.

## Progress Log Expectations

Implementation steps must append concise dated entries below with:

- task ids completed or changed,
- files touched,
- verification commands run and results,
- manual GUI checks performed or intentionally deferred with reason,
- known unrelated failures, if any,
- final commit hash once committed.

### Progress Log

- 2026-07-19: Plan created from accepted Step 3 design review; no
  implementation code written in this step.
- 2026-07-19: TASK-001 completed. Confirmed branch
  `feat/riela-note-workspace-revamp`; pre-change status contained only the
  Step 2/4 planning artifacts:
  `design-docs/specs/design-riela-note-ui-refinements.md` and
  `impl-plans/active/riela-note-workspace-hardening.md`. Baseline
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  printed `Build complete!`. Baseline unprefixed `swift test --filter
  RielaNoteUITests` and `swift test --filter RielaAppNotesIntegrationTests`
  hit the local x86_64/arm64 XCTest loader mismatch, so final verification used
  `/usr/bin/arch -arm64`.
- 2026-07-19: TASK-002 completed. Removed bare Return send shortcuts from
  `Sources/RielaNoteUI/RielaNoteAgentBottomBar.swift` and
  `Sources/RielaNoteUI/RielaNoteAgentView.swift`; composer `onSubmit`
  handlers remain in place.
- 2026-07-19: TASK-003/TASK-004 completed. Added shared pager-order snapshot
  `Sources/RielaNoteUI/RielaNotePagerNoteSnapshot.swift`, routed previous/next
  selection through it in
  `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`, and added regular-width
  Tree/Notes left-pane modes in
  `Sources/RielaNoteUI/RielaNoteRootView.swift`. Notes mode lists pager-order
  notes, highlights the current note, shows `index/total`, supports load-more,
  and routes row clicks through `requestSelection`.
- 2026-07-19: TASK-005 completed. Updated
  `Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift` and root presentation
  handling so popup selection yields to the root pending-selection dialog instead
  of leaving the confirmation hidden behind the sheet.
- 2026-07-19: TASK-006 completed. Replaced the file-tree load-once cache with
  `Sources/RielaNoteUI/RielaNoteFileTreeNotebookNotesPageState.swift`, using
  offset-based pages, id merging, load-more, and cache invalidation from
  `RielaNoteLibraryViewModel.fileTreeInvalidationRevision` on refresh/store
  watcher refresh.
- 2026-07-19: TASK-007/TASK-008 completed. Persisted left pane expansion, right
  pane expansion, selected Tree/Notes mode, and bottom agent fold state with
  Riela Note workspace `AppStorage` keys. Audited changed custom panels for
  semantic colors; changed surfaces use SwiftUI background/separator/secondary
  roles and selection tint instead of fixed theme backgrounds.
- 2026-07-19: TASK-009 completed. Added tests in
  `Tests/RielaNoteUITests/RielaNotePagerNoteSnapshotTests.swift`,
  `Tests/RielaNoteUITests/RielaNoteFileTreeNotebookNotesPageStateTests.swift`,
  `Tests/RielaNoteUITests/RielaNoteLibraryRefreshTests.swift`, and
  `Tests/RielaNoteUITests/RielaNoteNavigationGuardTests.swift`. Verification:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  printed `Build complete!`; `/usr/bin/arch -arm64
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  test --filter RielaNoteUITests` passed 173 tests; `/usr/bin/arch -arm64
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  test --filter RielaAppNotesIntegrationTests` passed 18 tests; `/usr/bin/arch
  -arm64 /usr/bin/xcrun swiftlint --quiet` reported only pre-existing warnings
  in unrelated files plus existing `RielaNoteLibraryViewModel.swift` length/body
  warnings and no serious violations. Manual GUI verification steps to record during review:
  confirm plain Return in body/comment/tag/rewrite inputs does not send agent
  messages, Enter in focused agent composer still submits, search popup result
  selection during body edit surfaces Discard/Keep Editing after sheet dismissal,
  Discard navigates and Keep Editing preserves the draft, relaunch preserves pane
  expansion/left mode/agent fold, and dark/light appearances keep agent panels,
  attachment chips, pane backgrounds, and selected rows legible.
- 2026-07-19: Step 6 self-review found and fixed a stale in-flight file-tree
  page race: `Sources/RielaNoteUI/RielaNoteFileTreePane.swift` now uses a cache
  generation so pages fetched before refresh/store-change invalidation cannot
  repopulate the reset cache. Re-ran `/usr/bin/arch -arm64
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  build`, `/usr/bin/arch -arm64
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  test --filter RielaNoteUITests`, `/usr/bin/arch -arm64
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  test --filter RielaAppNotesIntegrationTests`, and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
  PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
  /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet`; build and targeted
  tests passed, and SwiftLint reported the same pre-existing warnings.

## Follow-up Documentation Reconciliation Plan

**Issue Reference**: `codex-design-and-implement-review-loop-session-1172` /
`comm-000873`
**Workflow Mode**: issue-resolution

This follow-up owns only the post-implementation documentation/archive commit
for TODO-DOC-COMMIT-001. The accepted design remains
`design-docs/specs/design-riela-note-ui-refinements.md`; no design-doc,
source-code, or test edits are in scope.

### TASK-DOC-001: Verify docs-only worktree scope

**Depends On**: Step 3 design review acceptance.
**Deliverables**:
- Confirm branch `feat/riela-note-workspace-revamp`.
- Confirm `git status --short` lists only:
  `README.md`, `impl-plans/README.md`,
  `impl-plans/active/riela-note-workspace-hardening.md`,
  `impl-plans/completed/riela-note-workspace-hardening.md`, and
  `.codex/skills/riela-impl-workflow/`.
- Confirm `git diff --name-status -- design-docs Sources Tests` is empty.

**Completion criteria**:
- No unrelated worktree paths are staged or modified by this follow-up.

### TASK-DOC-002: Commit exactly the accepted documentation/archive paths

**Depends On**: TASK-DOC-001.
**Deliverables**:
- Stage only the five accepted paths.
- Commit once with message:
  `docs: archive riela-note-workspace-hardening plan and update workflow docs`.
- Do not push, amend, rewrite history, or touch commit `07f481f`.

**Completion criteria**:
- `git status --porcelain` is empty after commit.
- `git show --stat --name-status HEAD` shows exactly the accepted five paths.
- `git rev-parse HEAD^` prints
  `07f481f1ee48567a357714da6cf582de9d88b1ef`.
- `git cherry -v origin/feat/riela-note-workspace-revamp` shows only the new
  docs commit as unpushed.

### Follow-up Progress Log Expectations

The implementation step must record the branch, staged paths, commit hash,
verification command results, and explicit no-push confirmation.

### Follow-up Progress Log

- 2026-07-19: TASK-DOC-001 completed on branch
  `feat/riela-note-workspace-revamp`. Verified the dirty worktree is limited to
  `README.md`, `impl-plans/README.md`, deletion of
  `impl-plans/active/riela-note-workspace-hardening.md`, addition of
  `impl-plans/completed/riela-note-workspace-hardening.md`, and addition of
  `.codex/skills/riela-impl-workflow/`; `git diff --name-status -- design-docs
  Sources Tests` was empty. TASK-DOC-002 will stage only those accepted paths
  and create the single docs/archive commit; the resulting commit hash and
  no-push verification are recorded in the Step 6 implementation result because
  the hash is not knowable before commit creation without amending.
