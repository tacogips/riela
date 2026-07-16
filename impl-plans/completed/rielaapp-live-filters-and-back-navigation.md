# RielaApp Live Filters and Back Navigation — Implementation Plan

**Status**: Completed — Step 7 accepted; Step 8 documentation refreshed
**Workflow Mode**: issue-resolution
**Feature Fanout**: false — F15 is one feature and one work package
**Design Reference**: `design-docs/specs/design-rielaapp-ui-consistency-and-native-ux-review.md#f15-make-list-filters-live-and-back-navigation-truthful`
**Issue Reference**: `RielaApp: fix non-functional instance/workflow list filters and back-arrow visibility + icon distortion` (no GitHub issue URL or repository-plus-number supplied)
**Current Workflow Execution**: `codex-design-and-implement-review-loop-session-1167`
**Originating Plan Execution**: `codex-design-and-implement-review-loop-session-1164`
**Created**: 2026-07-16
**Last Updated**: 2026-07-16

---

## Design References

Primary accepted source of truth:

- `design-docs/specs/design-rielaapp-ui-consistency-and-native-ux-review.md`
  - `Active implementation slice for issue-resolution workflow: F15 only`
  - `F15. Make list filters live and back navigation truthful`
  - `Active F15 acceptance — current issue-resolution work package`

Supporting behavior references:

- `design-docs/specs/design-rielaapp-workflow-instances.md` for the existing
  Source/Instance model and Settings-style AppKit row behavior.
- Step 3 review decision: `accepted-for-step4-implementation-planning` via
  `comm-000830`; findings and revision requests were empty.
- Codex-agent references: none were supplied.
- Cursor CLI behavior mapping: not applicable; F15 changes no CLI or adapter
  behavior.

The accepted F15 text overrides historical R1-F14 material retained in the
same design document. R1-F14 are not implementation obligations for this plan.

## Scope

Included:

- Repair the confirmed break in each live field -> controller dispatch ->
  projection -> visible reload/replacement chain for
  `instanceSearchField`, `workflowSourceSearchField`,
  `inlineAddInstanceSearchField`, and `marketplaceSearchField`.
- Preserve the existing case- and diacritic-insensitive matching predicates
  unless root-cause evidence proves a predicate defect.
- Preserve first responder and stable-identity selection when the selected item
  remains in the filtered projection; clear only excluded selections.
- Distinguish filtered-empty UI from true no-data/onboarding UI.
- Establish one side-effect-free back-navigation availability predicate shared
  by `goBack()` and `updateNavigationState()`.
- Hide and disable the Back control at the Instances overview root; show and
  enable it for every effective `goBack()` branch, including confirmation-
  guarded configuration editors.
- Give the Back symbol proportional scaling and a square, non-stretching
  control layout within the 36-point navigation group.
- Add controller-path and layout regression coverage in
  `Tests/RielaAppSupportTests`.

Excluded:

- R1-F14, broader UI consistency changes, SwiftUI migration, or new navigation
  destinations.
- Workflow, package, profile, runtime, persisted-state, schema, CLI, Cursor CLI,
  Codex-agent, GraphQL, or adapter behavior changes.
- Network fetches, package installation, persistence, daemon lifecycle changes,
  or full controller refreshes caused by typing into a filter.
- Direct pushes to `origin/main`; any optional push must use a feature branch.

## Task Breakdown

### TASK-001 — Reproduce and identify each broken filter stage

**Status**: COMPLETE

**Write Scope**:

- No product-source writes until evidence identifies the broken stage.
- Throwaway logs or experiments, if needed, must live under
  `tmp/rielaapp-f15/` and must not be committed.
- A minimal failing regression may be added under
  `Tests/RielaAppSupportTests/` when it is the clearest reproduction.

**Deliverables**:

- Trace all four live chains through the controller actually displayed by the
  running app: field/delegate or notification delivery, pane-state guards,
  stored query, projection, fingerprint gate, and visible table/list reload or
  replacement.
- Record one evidence-backed root-cause classification per field in this
  plan's Progress Log: delegate/notification delivery, guard-state dispatch,
  fingerprint suppression, non-visible replacement, missing reload, or another
  demonstrated cause.
- Establish baseline assertions for visible narrowing, clearing, filtered-empty
  behavior, first-responder retention, and stable selection where the pane has
  selection.
- Confirm whether existing predicate helpers are correct before changing them.

**Dependencies**: accepted F15 design and current clean implementation baseline.

**Verification**:

- Run the narrowest existing tests that exercise each field's real
  `controlTextDidChange`/action path and record pass/fail evidence.
- Inspect the displayed view identity before and after the edit so a rebuilt but
  hidden view cannot count as success.

### TASK-002 — Repair all four live-filter chains

**Status**: COMPLETE

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+InstanceRows.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+SourcesPane.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift` only if
  TASK-001 proves field configuration is part of the break
- Focused files under `Tests/RielaAppSupportTests/`

**Deliverables**:

- Make `instanceSearchField` update `instanceFilterText`, rebuild
  `instanceRows`, reload `instanceTable` when its visible projection changes,
  update filtered-empty state, and restore stable selection/focus.
- Make `workflowSourceSearchField` update `workflowSourceFilterText` and replace
  the list in the currently visible `DaemonWorkflowSourcesPaneView`; ensure the
  active query participates in `sourcesOverviewFingerprint`.
- Make `inlineAddInstanceSearchField` rebuild the visible Add Instance selection
  from the already-loaded options, preserve focus and a surviving stable
  selection, and restore every option when cleared.
- Make `marketplaceSearchField` update `marketplaceFilterText` and replace the
  visible listing while retaining repository loading, error, empty-catalog, and
  progress rows; ensure the active query participates in the marketplace
  fingerprint.
- Ensure a trimmed empty query restores the complete already-loaded collection
  and a non-empty zero-match query shows filter-specific empty copy rather than
  onboarding/no-data copy.
- Do not add persistence, network, package, daemon, or full-state-refresh side
  effects to filter edits.
- Add/extend runtime controller tests that construct
  `NSControl.textDidChangeNotification` and verify narrowing, clearing, visible
  reload/replacement, focus, selection, and empty-state distinction for all
  four fields.

**Dependencies**: TASK-001 root-cause evidence.

**Verification**:

- `swift test --filter RielaAppAddInstanceLayoutTests`
- `swift test --filter RielaAppMarketplaceLayoutTests`
- `swift test --filter RielaAppSettingsSectionLayoutTests`
- Focused instance-filter regression test added or extended by this task.

### TASK-003 — Unify Back reachability and presentation

**Status**: COMPLETE

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift`
- Transition call sites in:
  - `Sources/RielaApp/DaemonWorkflowWindowController.swift`
  - `Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift`
  - `Sources/RielaApp/DaemonWorkflowWindowController+SourcesPane.swift`
  - `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift`
  - `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift`
  - `Sources/RielaApp/DaemonWorkflowWindowController+ConfigurationEditors.swift`
- Focused navigation files under `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add one side-effect-free `isBackNavigationAvailable` predicate (or
  equivalently named computed property/function) whose branches match
  `goBack()` exactly.
- Cover Add Instance; instance detail overview, removal confirmation, and every
  configuration sub-pane; workflow-source detail; marketplace-workflow detail;
  profile detail overview/removal confirmation; and Sources, Marketplace,
  Profiles, and Assistant roots.
- Return false only at the Instances overview root with no detail, selection,
  or configuration sub-pane active.
- Use the same predicate value for
  `navigationBackButton.isEnabled` and inverse `isHidden` state.
- Preserve configuration-editor discard confirmation semantics: availability
  means Back can initiate a navigation attempt even when a later confirmation
  can veto it.
- Audit every state-mutating pane transition and call `updateNavigationState()`
  only after all relevant pane/detail flags reach their final values.
- Add a table-driven navigation test matrix comparing the predicate, button
  visibility, button enablement, and expected `goBack()` destination across all
  listed states.

**Dependencies**: TASK-001 baseline; implement after TASK-002 because the two
tasks share `DaemonWorkflowWindowController.swift`, `+Prompts.swift`, and test
fixtures.

**Verification**:

- `swift test --filter RielaAppSettingsEditorNavigationTests`
- `swift test --filter RielaAppBehaviorRegressionTests`
- Focused F15 navigation matrix test added by this task.

### TASK-004 — Constrain the Back chevron without distortion

**Status**: COMPLETE

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift`
- `Tests/RielaAppSupportTests/RielaAppControllerLayoutTests.swift` or one new
  narrowly scoped F15 layout test file

**Deliverables**:

- Keep the platform `chevron.left` symbol and existing Back accessibility
  label, tooltip, focus, target, and action behavior.
- Apply `.scaleProportionallyDown` image scaling, optionally with a stable
  symbol point-size configuration consistent with existing AppKit style.
- Add square/non-stretching width and height constraints or equivalent required
  hugging/compression rules bounded by the 36-point navigation group.
- Avoid changing unrelated toolbar buttons unless the shared helper can be
  changed without distorting their established layout.
- Add layout assertions for proportional scaling, a square Back control, active
  constraints, and retained accessibility metadata.

**Dependencies**: TASK-003 transition audit; sequence after it because both may
touch `+SettingsShell.swift` and navigation fixtures.

**Verification**:

- `swift test --filter RielaAppControllerLayoutTests`
- Code-level constraint assertions must pass without relying only on a visual
  screenshot.

### TASK-005 — Integrate, verify, review, and close the work package

**Status**: COMPLETE — implementation accepted and documentation refreshed

**Write Scope**:

- F15 source/test files listed above.
- This implementation plan's status and Progress Log.
- `impl-plans/README.md` for status indexing.
- The accepted design document only if implementation evidence requires a
  factual clarification; do not broaden scope.

**Deliverables**:

- Review the combined diff for one-feature scope, matching predicate/binding
  logic, transition completeness, focus/selection behavior, and accidental
  side effects.
- Record the confirmed filter root cause and concise before/after predicate or
  binding evidence in the Progress Log for the implementation-review handoff.
- Run all required and directly affected verification commands and record exact
  command, status, and failure evidence if any.
- Resolve every high/mid implementation-review finding before completion; no
  Step 5 findings exist at plan creation time.
- Mark tasks complete only with evidence, update the plan/index status, and move
  the plan to `impl-plans/completed/` only after all completion criteria pass.

**Dependencies**: TASK-002, TASK-003, and TASK-004 complete.

## Dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-001 | Accepted Step 3 design | Establish evidence before product changes |
| TASK-002 | TASK-001 | Repair the demonstrated chain break, not an assumed predicate defect |
| TASK-003 | TASK-001, TASK-002 | Shared controller extensions and fixtures require ordered writes |
| TASK-004 | TASK-003 | Shared `+SettingsShell.swift` and Back-control assertions |
| TASK-005 | TASK-002, TASK-003, TASK-004 | Integrated review and final verification |

External prerequisites are limited to the macOS AppKit build environment and
the existing SwiftPM `RielaAppSupportTests` target. No service, network, CLI
adapter, GitHub issue, or external repository dependency is required.

## Parallelizable Tasks

None. Although filter logic and chevron layout are conceptually independent,
the accepted work package shares `DaemonWorkflowWindowController` extensions,
`+SettingsShell.swift`, and controller-construction test fixtures. Sequential
execution avoids conflicting writes and makes the root-cause evidence auditable.

## Verification

Run in this order from the repository root:

```bash
swift build
swift test --filter RielaAppAddInstanceLayoutTests
swift test --filter RielaAppMarketplaceLayoutTests
swift test --filter RielaAppSettingsSectionLayoutTests
swift test --filter RielaAppSettingsEditorNavigationTests
swift test --filter RielaAppControllerLayoutTests
swift test --filter RielaAppBehaviorRegressionTests
swift test --filter RielaAppSupportTests
git diff --check -- Sources/RielaApp Tests/RielaAppSupportTests impl-plans/completed/rielaapp-live-filters-and-back-navigation.md design-docs/specs/design-rielaapp-ui-consistency-and-native-ux-review.md
```

Code-level UI verification must prove:

- each actual field-change path narrows and clears the visible collection;
- filter-specific empty states differ from true no-data states;
- focus and any surviving stable selection are preserved;
- the single Back predicate agrees with every effective `goBack()` branch;
- the Back button's hidden/enabled state mirrors that predicate after every
  pane transition; and
- the Back image uses proportional scaling inside an active square,
  non-stretching layout.

## Completion Criteria

- [x] TASK-001 records an evidence-backed root-cause classification for all
  four fields; no predicate rewrite is accepted as root-cause evidence alone.
- [x] All four search fields narrow the visible already-loaded list live and
  restore it when cleared without persistence, network, package, daemon, or
  full-refresh side effects.
- [x] Filter edits preserve first responder and stable selection when possible,
  clear excluded selection only, and show correct filtered-empty copy.
- [x] One side-effect-free predicate governs both every effective `goBack()`
  branch and Back button visibility/enablement.
- [x] Instances overview root hides and disables Back; all specified roots,
  details, confirmations, and configuration sub-panes expose a reachable Back
  navigation attempt.
- [x] Every pane/detail transition updates navigation state after completing
  its state mutation.
- [x] Back chevron is proportional, square/non-stretching, accessible, and uses
  normal AppKit focus and hit behavior.
- [x] `swift build`, every focused command above, and
  `swift test --filter RielaAppSupportTests` pass.
- [x] Combined diff contains only F15 product/test/plan evidence and preserves
  unrelated user changes.
- [x] Progress Log contains task status, changed paths, confirmed root cause,
  review decisions/findings, exact verification commands/results, and any
  intentional divergence approved by a later design review.

## Addressed Feedback

- Resolved high finding
  `codex-design-and-implement-review-loop-session-1164-step3-design-review-attempt-1-finding-1`:
  the design's active implementation-slice section now names only F15 and
  explicitly forbids using historical R1-F14 material to justify unrelated
  implementation or test work.
- Resolved mid finding
  `codex-design-and-implement-review-loop-session-1164-step3-design-review-attempt-1-finding-2`:
  acceptance is now split into an active F15 section and an explicitly
  historical/deferred R1-F14 section that is not a current regression-test
  obligation.
- This plan keeps the accepted design's investigation-first rule explicit,
  covers all four filter chains, mirrors every `goBack()` branch including
  confirmation-backed editors, and includes code-level layout verification.
- Codex-agent references: none supplied. Prior Fable follow-up TODOs: none
  supplied.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Guard conditions route an action to the wrong search field | Test each concrete field's target/action path and remove only evidence-proven fallback routing |
| Fingerprint gating leaves stale content or causes excess rebuilds | Include active query in visible-content fingerprints and assert visible view identity/replacement behavior |
| Rebuilding a pane drops focus or stable selection | Restore first responder and selection by stable item identity after the visible projection changes |
| Marketplace filtering hides fetch/error/progress context | Filter workflow rows only; retain repository sections and operational message rows |
| Back predicate diverges from future `goBack()` changes | Keep one predicate adjacent to navigation dispatch and verify all branches in one table-driven matrix |
| Dirty-editor confirmation becomes unreachable | Treat an attempted, vetoable transition as Back-available and test the confirmation branch |
| Shared toolbar helper distorts unrelated icons | Prefer Back-specific square constraints or verify every shared-helper consumer affected by a change |
| Concurrent/unrelated worktree edits appear | Stop on overlap, preserve user changes, and never revert or clobber unrelated files |

## Progress Log Expectations

Each implementation session must append a dated entry containing:

- tasks completed/in progress and changed paths;
- confirmed root-cause stage for each of the four filters with concrete evidence;
- review decision plus high/mid/low findings and their resolution status;
- exact verification commands, pass/fail status, and concise failure evidence;
- blockers, dirty-worktree overlap decisions, and owner/trigger for any accepted
  deferral; and
- approved intentional divergences from the accepted F15 design, if any.

### Session: 2026-07-16

- Tasks Completed: implementation plan created after Step 3 acceptance.
- Tasks In Progress: none; implementation has not started.
- Review Decision: `accepted-for-step4-implementation-planning`.
- Findings: none.
- Verification: plan formatting and design-reference diff checks only; product
  build/tests are reserved for the implementation step.
- Blockers: GitHub issue URL/repository-plus-number was not supplied; this does
  not block local implementation.
- Notes: The accepted design document is already modified in the worktree and
  is preserved as user/workflow-owned input. F15 remains one work package with
  no feature fanout and no parallel write tasks.

### Session: 2026-07-16 — Step 6 implementation

- Tasks Completed: TASK-001 through TASK-004. TASK-005 implementation,
  integration, code review, lint, build, focused tests, full support tests, and
  current-executable screenshot verification are complete; Step 7 review is
  pending.
- Changed Paths: `Sources/RielaApp/DaemonWorkflowWindowController.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+ConfigurationEditors.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift`,
  `Sources/RielaApp/DaemonWorkflowWindowController+SourcesPane.swift`,
  `Tests/RielaAppSupportTests/RielaAppAddInstanceLayoutTests.swift`,
  `Tests/RielaAppSupportTests/RielaAppLiveFilterAndNavigationTests.swift`,
  `Tests/RielaAppSupportTests/RielaAppMarketplaceLayoutTests.swift`, and
  `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`.
- Confirmed Filter Root Cause: `workflowSourceSearchField`,
  `inlineAddInstanceSearchField`, and `marketplaceSearchField` set a target and
  `sendsSearchStringImmediately` but no action selector, so native live action
  delivery had no pane-specific endpoint. All four filter paths also forced
  `makeFirstResponder(searchField)` after every edit, interrupting the active
  AppKit field editor even when the field itself was not replaced. Explicit
  per-field actions now call the existing projections; search-field delegate
  dispatch and the unsafe any-search-field fallback were removed, while
  `controlTextDidChange` remains only for the event-source form. Focus
  restoration is limited to actual pane replacement.
- Filter Evidence: the existing case/diacritic-insensitive predicates and
  query-bearing fingerprints were correct and unchanged. Target/action tests
  now narrow and clear the instance, source, inline-add, and marketplace
  collections; inline-add selection is restored by candidate ID when it
  survives the new projection.
- Navigation Evidence: `isBackNavigationAvailable` is the single predicate
  used by both `goBack()` and `updateNavigationState()`. The latter hides and
  disables the button and its navigation group at the Instances root, while a
  table-driven matrix covers Add Instance, every instance sub-pane, source and
  marketplace detail, both profile states, and every non-Instances root.
- Layout Evidence: Back uses a 13-point medium SF Symbol,
  `.scaleProportionallyDown`, and active 20-by-20 square constraints inside the
  36-point navigation group. Accessibility label and tooltip remain `Back`.
- Review Decision: implementation-ready for Step 7 review. High/mid/low Step 5
  findings: none. Step 6 self-review found and removed the broad hidden-field
  fallback; no unresolved implementation findings remain.
- Verification: Xcode arm64 `swift build --product RielaApp` passed;
  focused RielaApp filter/navigation/layout/behavior suites passed 54 tests
  with 0 failures; `swift test --filter RielaAppSupportTests` passed 209 tests
  with 0 failures; Nix SwiftLint exited 0 with unrelated pre-existing warnings.
  `/usr/bin/xcrun swiftlint` was attempted first and crashed with signal 4 in
  the Rosetta-hosted shell. The current executable
  `.build/arm64-apple-macosx/debug/RielaApp` was launched directly with isolated
  roots; `tmp/rielaapp-f15/final-current-window.png` verified the Instances root
  has no disabled Back control. `.build/debug/RielaApp.app` was not used.
- Blockers: none. Computer Use accessibility inspection did not return state,
  so UI verification used the RielaApp skill's CGWindow-ID screenshot fallback;
  Back-visible geometry is covered by passing AppKit constraint tests.
- Intentional Divergence: none from accepted F15 behavior. The plan remains in
  `active/` until Step 7 review completes TASK-005.

### Session: 2026-07-16 — Step 6 rerun (`codex-design-and-implement-review-loop-session-1167`)

- Workflow Mode: `issue-resolution`; feature fanout remains false and F15
  remains exactly one work package.
- Tasks Completed: revalidated TASK-001 through TASK-004 and TASK-005's
  implementation/verification portion against the accepted plan; Step 7 review
  remains the only pending completion gate.
- Review Decision: ready for Step 7 implementation review with no unresolved
  high or mid findings.
- Addressed Findings: the high finding ending `finding-1` is resolved by the
  F15-only active implementation-slice section at the start of Design; the mid
  finding ending `finding-2` is resolved by the separate active-F15 and
  historical/deferred-R1-F14 acceptance headings. No code scope was broadened.
- Test Maintenance: replaced the new navigation matrix's three-member tuple
  with `BackStateCase`, eliminating the only SwiftLint warning introduced by
  F15. Added explicit surviving instance-selection assertions and
  filtered-empty copy assertions for Add Instance and Marketplace.
- Verification:
  - Xcode-toolchain `swift build --product RielaApp`: passed.
  - Native arm64 Xcode-toolchain
    `swift test --filter RielaAppSupportTests`: 209 tests passed, 0 failures.
  - Native arm64 Xcode-toolchain
    `swift test --filter 'RielaApp(AddInstanceLayoutTests|MarketplaceLayoutTests|LiveFilterAndNavigationTests)'`:
    8 tests passed, 0 failures after the final assertion hardening.
  - Native arm64 `/usr/bin/xcrun swiftlint`: exited 0; the first full run found
    16 warnings, including the new matrix tuple warning. After the fix,
    targeted lint across the three changed filter/navigation test files found
    0 violations; the remaining 15 full-repository warnings are pre-existing
    and outside F15 scope.
  - Initial non-arm64 `swift test --filter RielaAppSupportTests`: invalid
    verification attempt because the Rosetta x86_64 host could not load the
    arm64 test bundle; rerunning under `/usr/bin/arch -arm64` passed 209/209.
  - `git diff --check` over the F15 source, tests, plan, index, and design:
    passed.
  - Launched `.build/arm64-apple-macosx/debug/RielaApp` directly with isolated
    roots and captured `tmp/rielaapp-f15/final-current-window.png` by CGWindow
    ID. Visual inspection confirms the Instances root does not display a
    disabled Back control. `.build/debug/RielaApp.app` was not used; the
    visible Back geometry is covered by the passing AppKit layout test.
- Changed Paths: unchanged from the preceding Step 6 implementation, plus the
  test-only `BackStateCase` lint cleanup and this plan-log update.
- Blockers: none.
- Intentional Divergence: none.

### Session: 2026-07-16 — Step 7 acceptance and Step 8 documentation refresh

- Workflow Mode: `issue-resolution`; feature fanout remains false.
- Tasks Completed: TASK-005. Step 7 accepted the implementation with decision
  `accepted-implementation`; Step 8 aligned user-facing documentation with the
  shipped F15 behavior.
- Documentation Files: `README.md`, this implementation plan, and
  `impl-plans/README.md`.
- Mandatory Skill Review: `.codex/skills/riela-impl-workflow/SKILL.md` is not
  present in this checkout, so no repository-local skill text could be updated.
  The existing `.codex/skills/riela-workflow/SKILL.md` authors workflow bundles
  and is not affected by these RielaApp-only UI changes.
- User-Facing Documentation: the root README now states that the Instances,
  Workflow Sources, Add Instance, and Marketplace searches filter live and
  that Back appears only where navigation history is available.
- Review Decision: `accepted-implementation`; findings: none; revision and
  adversarial review were not required.
- Resolved Issue References:
  `codex-design-and-implement-review-loop-session-1164-step3-design-review-attempt-1-finding-1`
  and
  `codex-design-and-implement-review-loop-session-1164-step3-design-review-attempt-1-finding-2`.
- Codex-Agent References: none supplied.
- Verification: the accepted Step 7 evidence records native arm64 `swift
  build`, `swift test --filter RielaAppLiveFilterAndNavigationTests` (3 tests,
  0 failures), `swift test --filter RielaAppSupportTests` (209 tests, 0
  failures), and scoped `git diff --check` as passed. Step 8 reruns
  documentation-focused `git diff --check` and reference checks only because it
  changes no product source.
- Residual Risk: 15 pre-existing full-repository SwiftLint warnings remain
  outside F15 scope; risk level low.
