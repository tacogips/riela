---
name: riela-impl-workflow
description: Use when running or documenting the codex-design-and-implement-review-loop for Riela issue-resolution work packages, including accepted design, implementation plan, implementation, review, documentation refresh, verification, and final commit handoff.
metadata:
  short-description: Riela implementation workflow contract
---

# Riela Implementation Workflow

Use this skill when a Riela task is handled through
`codex-design-and-implement-review-loop` or another implementation workflow that
expects a design, plan, implementation, review, documentation refresh, and
commit handoff.

## Workflow Contract

- Treat `workflowMode: "issue-resolution"` as one accepted work package unless
  the workflow explicitly fans out.
- Preserve issue references, communication ids, codex-agent step references,
  reviewed file paths, review decisions, findings, verification commands, and
  verification gaps in handoffs.
- Do not reopen accepted design or implementation scope during the documentation
  refresh step. Align user-facing docs with the accepted behavior, review
  decision, and verification evidence.
- Refresh repository-facing documentation before commit generation. Review
  `README.md` and this skill, and update any directly affected user-facing
  workflow skill or README section.
- Keep final workflow responses machine-readable when requested by the runtime.

## Riela Note Workspace Behavior

Accepted Riela Note workspace hardening on
`feat/riela-note-workspace-revamp` ships these user-facing contracts:

- Agent send buttons do not register a bare Return shortcut. Plain Return in
  note body, comment, tag, rewrite, search, or link text inputs must not send an
  agent message; focused agent composer submit remains the plain-Enter send
  path.
- Search-popup result selection during an unsaved body edit must yield to the
  root pending-selection confirmation. Discard navigates to the chosen note;
  Keep Editing preserves the draft.
- The regular-width left pane has Tree and Notes modes. Tree mode invalidates
  lazily loaded notebook children on refresh or note-store change and supports
  paginated load-more for large notebooks. Notes mode uses the shared detail
  pager order, highlights the current note, shows row position, and routes row
  selection through the unsaved-edit guard.
- The detail surface is a read-first vertical snap reader with one note per
  page. Current-note agent and comment actions remain one tap away; the agent
  action expands and focuses the existing composer with the current note as
  context. Editing is explicit and makes pager controls inert. Notebook notes
  load through bounded forward/backward windows without target-scanning fetch
  loops, and stale window completions cannot override a newer selection.
- Left pane expansion, right pane expansion, selected Tree/Notes mode, and
  bottom-agent folded state persist across app relaunches.
- Changed note-workspace panels use semantic SwiftUI color roles so custom agent
  panels, attachment chips, pane backgrounds, and selected rows remain legible
  in dark and light appearances.

## Verification Evidence

For this work package, accepted verification included:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppNotesIntegrationTests
rg -n "while .*hasMore|hasMore.*while|loadAll|prefetch" Sources/RielaNoteUI
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet
```

Manual GUI verification should record Return routing, search-popup confirmation
reachability, reader snapping and edit-mode pager blocking, current-note action
routing, relaunch persistence, and dark/light rendering for the changed
workspace surfaces.

## Hierarchical Tags and Per-Tag Kanban Behavior

Accepted Riela Note hierarchy and Kanban work on
`feat/riela-note-hierarchical-tags-kanban` ships these user-facing contracts as
one issue-resolution work package:

- Tags support one optional parent. Parent-tag filters include the parent and
  all transitive descendants across notebook lists, note lists, text and
  filter-only search, LIKE fallback, and linked-note expansion. Leaf filters
  remain exact, unknown filters return no matches, and self/ancestor parent
  cycles are rejected.
- The `folder` system tag class can classify tags applied to notebooks. It does
  not add filesystem folder, containment, or notebook-ownership semantics.
- Notebook progress is the typed four-state value `none`, `progress`, `done`,
  or `pending`. Schema-v4 migration and fresh databases default notebooks to
  `none` and enforce the allowed values.
- The GraphQL surface additively exposes `NoteTag.parentTagId`,
  `Notebook.progress`, `DefineNoteTagInput.parentTagId`,
  `NotebookProgress`, and `setNotebookProgress(notebookId:progress)`.
  Existing `tagFilter` fields inherit the service's descendant expansion.
- An active tag filter renders notebooks in fixed `none`, `progress`, `done`,
  and `pending` groups in both compact and regular-width macOS Notes surfaces.
  Progress changes are persisted through the shared service.
- Filtered loads fail closed. Generation and board-context guards prevent stale
  refresh, pagination, and progress-mutation completions from replacing newer
  membership or progress state. Current mutation failures retain the matching
  board, reconcile canonical state, and remain visible to the user.

The Step 7 decision was
`accepted_adversarial_review_with_low_coverage_gaps`: no high- or mid-severity
production failure remained. The accepted focused verification was:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|RielaNoteKanbanRaceTests'
git diff --check && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
```

The focused test run passed 15 tests with zero failures. `git diff --check`
passed; SwiftLint reported existing warning-only findings before its wrapper
timed out. Keep these accepted residual gaps explicit in handoffs:

- a current-executable active-filter window-ID screenshot is unavailable;
  inspected AppKit-host rendering is the available visual evidence;
- fresh-schema v4 foreign-key metadata and progress-CHECK enforcement lack
  dedicated assertions independent of migration coverage;
- the GraphQL document test does not yet exercise a parent/child/grandchild
  projection and assert the nested `parentTagId`.
