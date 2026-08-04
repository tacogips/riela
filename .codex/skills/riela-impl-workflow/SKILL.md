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

## Wrike-style web notebook view

`feat/riela-note-web-notebook-view` adds one issue-resolution work package on
top of the hierarchical-tag and progress contracts:

- The SolidJS dashboard exposes Notes with an arbitrary-depth folder tree,
  descendant-scoped List and Board views, a shared detail panel, folder chip
  mutation, and a bounded read-only notes preview.
- `DefineNoteTagInput.createOnly` is additive and defaults to `false`.
  Web-created folders set it to `true`, making name collisions fail atomically
  without changing the existing tag's class or parent.
- Progress writes live in a notebook-keyed controller outside mounted view
  state. Optimistic values are serialized and converge to the newest requested
  database value across view and folder changes.
- RielaApp composes its Note GraphQL executor at request time from the active
  profile note root, behind the existing Host, Origin, CSRF, and JSON policy.
- `riela serve --note-api --web-root web/dist` serves the SPA same-origin.
  GET `/note/register` bootstraps the SPA while POST registration and GraphQL
  retain service precedence. Static resolution rejects NUL, traversal, and
  symlink escape attempts.
- Browser authentication reuses the single-use registration code and keeps the
  resulting bearer token in session storage; no CORS or alternate auth system
  is added.

The `feat/riela-note-web-tags-and-card-preview` extension retains those
contracts and adds:

- first-note plain-text excerpts and note counts to Board cards and List rows,
  omitting empty preview blocks;
- deterministic Folder-first, named-class, and classless tag-assignment
  sections with deletable-only removal and existing-catalog-only addition; and
- a Folder/Tags navigation switch whose class-scoped trees, breadcrumbs, and
  one-name descendant filters share one generation-safe active scope.

Its additional implementation gate is:

```bash
cd web && bun run lint && bun run typecheck && bun run test && bun run build
cd web && bun run test:e2e
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaAppSupportTests --skip 'DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits'
git diff --check
```

The Step 7 decision was `accepted_adversarial_review_with_low_findings`: no
high- or mid-severity production failure remained. Keep the accepted low risks
explicit in handoffs: a refreshed catalog can leave a stale add-tag selection
enabled as a silent no-op; a scoped tag reclassified between folder and
non-folder can remain hidden or mislabeled until the scope is cleared; and an
explicitly null mutation preview can preserve older list metadata until
refresh.

The implementation gate is:

```bash
cd web && bun run lint && bun run typecheck && bun run test && bun run build
cd web && bun run test:e2e
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
/usr/bin/xcrun swiftlint --quiet --no-cache
```

## Web Cross-Tag Grouped Filtering

Accepted work on `feat/riela-note-web-cross-tag-filter` extends the web Notes
contracts as one issue-resolution package:

- `NoteService.listNotebooks` and GraphQL `notebooks` accept additive
  `tagFilterGroups`. Each group unions descendant-expanded names and the
  service intersects groups. Empty groups are ignored, any unknown non-empty
  group fails closed to an empty result, and non-empty grouped input takes
  precedence over legacy `tagFilter`.
- Grouped requests are bounded to 64 groups, 256 input names, and 900 expanded
  names. Equivalent groups and names are canonicalized and deduplicated;
  oversized requests produce a controlled `invalid_request`. Legacy flat
  `tagFilter` limits and behavior remain unchanged.
- The web Folder and Tags trees use plain selection to replace the filter and
  a labeled, keyboard-focusable add action to append a constraint. Ordered
  chips support individual removal and clear-all. List and Board consume the
  same intersection, and catalog reconciliation removes only missing
  constraints.
- Board membership is retained until a current bounded load completes.
  Membership mutations are globally serialized, drag-time refresh commits are
  deferred, preview loads use generations, scope-ejecting tag removal restores
  focus deterministically, and stale activators are pruned.
- Notebook paging shares a 200-item page size, stops on duplicate-only pages,
  and caps loads at 1,000 pages. Unknown progress values normalize visibly to
  `none`. New folders are entered automatically only from their exact
  single-parent-folder scope.

The Step 7 decision was
`accepted_adversarial_review_with_residual_low_risks`: no high- or mid-severity
finding remained. Accepted verification was:

```bash
cd web && bun test src
cd web && ./node_modules/.bin/tsc --noEmit
cd web && ./node_modules/.bin/eslint src/views/NotesView.tsx src/notes/controller.ts src/notes/controller.test.ts src/notes/client.ts src/notes/client.test.ts src/notes/paging.ts src/notes/paging.test.ts e2e/dashboard.spec.ts
cd web && bun scripts/audit-source.ts
cd web && bun run build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests|NoteCommandTests'
git diff --check
```

The focused Swift run passed 33 tests with zero failures; the carried-forward
web unit run passed 29 tests with zero failures and 95 assertions. Keep these
accepted residual risks and verification gaps explicit in handoffs:

- `Sources/RielaNote/NoteService.swift` remains large; grouped-filter
  normalization and predicate construction are later-maintenance extraction
  candidates;
- mocked Playwright execution and live List, Board, cross-tag, drag,
  mutation-race, partial-failure, and focus checks remain operator-owned; and
- repository-wide `cd web && bun run lint` remains blocked by diagnostics in
  excluded pre-existing `web/verify-live.mjs`.

## Parent-Scoped Riela Note Folder Identity

Riela Note schema v7 keeps `tag_id` as canonical identity while scoping folder
display-name uniqueness to the parent. Root folders reject duplicate root
names, nested folders reject duplicate sibling names, and non-folder names
remain globally unique. A folder and non-folder may share a display name, so
legacy generic name lookups must fail closed when more than one tag matches.

- Folder paths resolve each component by exact parent ID plus name. Notebook
  assignment/removal, grouped filtering, and folder-scoped Kanban operations
  use tag IDs; name-based fields remain compatibility paths only when the
  complete candidate set is unambiguous.
- GraphQL exposes `ApplyNotebookTagIdsInput`, `applyNotebookTagIds`,
  `removeNotebookTagById`, `tagFilterIdGroups`,
  `effectiveKanbanStatusesByTagId`, and `assignKanbanStatusSetByTagId` as the
  canonical additive surface.
- Web folder and tag selection surfaces render path-qualified labels such as
  `Workflow A / history-2026-08-03`. Missing, cyclic, or over-depth ancestry
  remains visibly incomplete instead of falling back to a global-name match.
- Private workflow-run notebooks use
  `<workflow-id>/history-YYYY-MM-DD`, reusing the leaf only beneath the same
  workflow parent.
- Existing-store migration must preserve tag and assignment IDs, restore and
  verify foreign keys on every exit, leave post-commit failures as recoverable
  markerless-v7 stores, and evict any database handle whose operation throws.

Use these focused gates when this contract changes:

```bash
swift test --filter NoteStoreSchemaTests
swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests'
swift test --filter 'NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'
swift test --filter NoteCommandTests
swift test --filter RielaAppSupportTests
(cd web && bun test src && ./node_modules/.bin/tsc --noEmit && bun run lint && bun run build && bun run test:e2e)
```

The Step 7 decision was
`accepted_adversarial_review_with_low_finding`: no blocking high- or
mid-severity production finding remained. The final browser gate was:

```bash
(cd web && CI=1 bun run test:e2e)
```

It passed 49 tests in 27.6 seconds. Keep these accepted residual risks explicit
in handoffs:

- folder-removal success, active-filter ejection, and partial-refresh messages
  still use an unqualified display name, so duplicate branches can make the
  feedback ambiguous; and
- those duplicate-branch removal outcomes do not yet have complete browser
  coverage.
