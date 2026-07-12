# RielaApp UX Onboarding Improvements Implementation Plan

**Status**: Implemented; RielaApp verification passed
**Design Reference**: `design-docs/specs/design-rielaapp-ux-onboarding-improvements.md`
**Created**: 2026-07-02
**Last Updated**: 2026-07-02
**Workflow Mode**: issue-resolution
**Issue Reference**: `workflowExecutionId=codex-design-and-implement-review-loop-session-877`, `communicationId=comm-000534`

---

## Design References

Primary source of truth:

- `design-docs/specs/design-rielaapp-ux-onboarding-improvements.md`

Required supporting references:

- `design-docs/specs/design-rielaapp-workflow-instances.md`
- `design-docs/user-qa/qa-rielaapp-env-file-user-review.md`
- `<codex-attachment>/pasted-text-1.txt`

The accepted design requires F1-F8 to land as one sequential implementation
path. Do not use feature fanout and do not split these items into independent
branches unless a later accepted design revises that runner constraint.

## Scope

Included:

- F1 in-window status banner and typed `RielaAppStatusMessage` flow.
- F2 runtime detail rows, detail status, reachable Workflow Viewer actions,
  and daemon session-store root wiring.
- F3 two-step instance removal confirmation.
- F4 guided first-run and empty states.
- F5 Configure Instance form upgrades.
- F6 guided event source form with JSON advanced mode.
- F7 masked effective environment values.
- F8 navigation, filter, missing-env, refresh, and status-menu polish.

Excluded:

- Persisted preference schema migrations.
- CLI, GraphQL, server, Cursor adapter, or Codex adapter behavior changes.
- SwiftUI migration or replacement of the existing AppKit pane architecture.
- Full workflow viewer redesign beyond the accepted viewer entry points.

## Referenced Behavior And Intentional Divergences

- Preserve the Source/Instance vocabulary and user mental model from
  `design-rielaapp-workflow-instances.md`.
- Keep `active`, `enabled`, `available`, `candidate`, `preference`, and
  `daemon` out of new user-facing RielaApp copy, except where existing storage
  fields remain internal compatibility details.
- Treat `<codex-attachment>/pasted-text-1.txt`
  as the intake summary that motivates F1-F8, but implement the refined design
  document when copy or behavior differs.
- Keep `design-docs/user-qa/qa-rielaapp-env-file-user-review.md` as the
  boundary for advisory `.env` validation and secret rendering claims.
- No Cursor-specific behavior is introduced; future adapter-specific wording
  must stay behind adapter modules.

## Task Breakdown

### 1. F1 Status Banner Foundation

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaAppSupport/RielaAppStatusMessage.swift`
- `Sources/RielaApp/EntryPoint*.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowSettingsRootView.swift`
- `Sources/RielaApp/RielaAppStatusBannerView.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add typed `RielaAppStatusMessage` with `.info` and `.error` severity.
- Preserve `RielaApp.status: String` for the status menu while adding
  sequenced `statusMessage` updates at the same call sites.
- Change the unused window-controller `statusMessage` update argument to carry
  the typed sequenced message.
- Render a non-overlapping banner slot between toolbar and content, with
  transient info behavior and persistent dismissible error behavior.
- Add focused classification and layout tests.

**Depends On**: accepted design only.

**Verification**:

- `swift test --filter RielaAppStatusMessage`
- `swift test --filter RielaAppControllerLayoutTests`
- Screenshot evidence: info banner, error banner, dismissed error not
  resurrected by refresh.

### 2. F2 Runtime Detail And Viewer Access

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+*.swift`
- `Sources/RielaApp/EntryPoint+DaemonWorkflowActions.swift`
- `Sources/RielaApp/EntryPoint+Viewer.swift`
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add `ConfiguredWorkflowInstanceRow.stateDetail` from
  `RuntimeSnapshot.detail` and include it in row fingerprints.
- Show failed detail in list subtitles and a detail-pane `Status` row.
- Add `Open in Viewer` rows for instances and workflow sources using existing
  viewer construction paths.
- Expose and pass daemon `defaultSessionStoreRootPath` so instance sessions
  are discoverable in the viewer.
- Add row-model, fingerprint, and vocabulary tests.

**Depends On**: F1 typed/status refresh plumbing.

**Verification**:

- `swift test --filter RielaAppWorkflowViewer`
- `swift test --filter RielaAppWorkflowViewerVocabularyTests`
- Screenshot evidence: failed row detail, failed/running detail status,
  instance viewer opened with session list.

### 3. F3 Instance Removal Confirmation

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add an instance detail removal-confirmation pane following the existing
  profile removal idiom.
- Make the first `Remove Instance` click navigate to confirmation only.
- Confirmed removal calls `onRemoveInstance` exactly once and returns to the
  instances list.
- Back/Escape/cancel return to detail overview without deletion.
- Copy states that only the instance is removed and the workflow source stays.

**Depends On**: F2 detail-pane state and action-row visibility.

**Verification**:

- `swift test --filter RielaAppSettingsEditorNavigationTests`
- Screenshot evidence: removal confirmation for stopped and running instance.

### 4. F4 Guided Empty States

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+*.swift`
- `Sources/RielaApp/DaemonWorkflowEmptyStateView.swift`
- `Sources/RielaApp/EntryPoint.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Replace the raw zero-instance label with a guided empty-state view that
  explains Source -> Instance -> Configure -> Start.
- Wire `View Workflow Sources` and `Create Instance` buttons to existing pane
  navigation.
- Update sources-empty copy.
- Emit F1 info message when starter workflows are bootstrapped.
- Keep guided empty state keyed to raw instance count only, not filtered count.

**Depends On**: F1 banner; Source/Instance navigation from existing instances
design.

**Verification**:

- `swift test --filter RielaAppWorkflowViewerEmptyStateTests`
- Screenshot evidence: fresh-profile instances pane and source empty copy.

### 5. F5 Configure Instance Form Upgrades

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift`
- `Sources/RielaApp/EntryPoint+DaemonInstances.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add controller closure for generated default instance id preview.
- Show helper text for empty ID behavior.
- Add `.env File` and `Working Directory` Browse controls with advisory
  existence captions.
- Add required-environment preview row.
- Give the start checkbox visible `Start immediately` copy.
- Keep creation allowed when advisory path validation fails.

**Depends On**: F4 clarified Source -> Instance -> Configure flow.

**Verification**:

- `swift test --filter RielaAppAddInstanceLayoutTests`
- `swift test --filter RielaAppPromptAccessoryTests`
- Screenshot evidence: Configure Instance with generated id, required env,
  Browse controls, and advisory file-not-found caption.

### 6. F6 Guided Event Source Registration

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+ConfigurationEditors.swift`
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Add `RielaAppDaemonWorkflowRuntime.daemonSourceKinds()` or equivalent
  support accessor beside daemon source-kind validation.
- Convert the event-source editor to default `Form` mode with `JSON` advanced
  mode.
- Build current source and binding JSON from form values, preserving today's
  template shape and registration callback.
- Keep validation and error reporting through existing editor paths.
- Add tests that returned kinds satisfy daemon validation and generated JSON
  round-trips through the existing parser.

**Depends On**: F5 prompt/editor affordance patterns.

**Verification**:

- `swift test --filter DaemonWorkflowSupportTests`
- Focused event-source editor JSON round-trip test.
- Screenshot evidence: Form mode and JSON advanced mode.

### 7. F7 Masked Effective Environment Display

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+ConfigurationEditors.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Mask all effective environment values by default with capped bullet output.
- Add unpersisted `Show Values` toggle for plaintext opt-in.
- Add inline-environment caption explaining profile instance-state storage.
- Extract and unit-test the masking formatter.

**Depends On**: F5 and F6 final configuration surface shape.

**Verification**:

- Masking formatter unit test.
- `swift test --filter RielaAppEnvironmentFileStoreTests`
- Screenshot evidence: masked and opt-in unmasked effective environment using
  non-secret fixture values.

### 8. F8 Navigation And Affordance Polish

**Status**: IMPLEMENTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+ConfigurationEditors.swift`
- `Sources/RielaApp/EntryPoint+DaemonInstances.swift`
- `Sources/RielaApp/EntryPoint+Menu.swift`
- `Tests/RielaAppSupportTests/`

**Deliverables**:

- Remove the dead forward button and empty `goForward()` path.
- Add instance search filter with raw-count versus filtered-count empty-state
  handling.
- Make missing required environment visible and actionable in instance detail.
- Emit F1 `Refreshed.` info message after manual refresh.
- Add capped failed-instance lines to the status menu.
- Update layout, filter, empty-state, and menu tests.

**Depends On**: F1 banner, F4 raw/filtered empty-state split, F7 final
environment display.

**Verification**:

- `swift test --filter RielaAppControllerLayoutTests`
- Filter and filtered-empty focused tests.
- Status menu failed-instance summary test.
- Screenshot evidence: filtered empty state, missing-env action row, status
  menu failed-instance summary.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| F1 | accepted Step 3 design | Establishes typed feedback used by F4 and F8. |
| F2 | F1 | Runtime diagnostics should reuse the new status update path and stable refresh behavior. |
| F3 | F2 | Confirmation copy and actions depend on stable detail-pane state. |
| F4 | F1 | Bootstrap visibility uses the banner; navigation copy relies on Source/Instance flow. |
| F5 | F4 | Configure Instance follows the guided Source -> Instance -> Configure path. |
| F6 | F5 | Event-source form uses the upgraded prompt/editor idioms. |
| F7 | F5, F6 | Environment display is finalized after configuration surfaces settle. |
| F8 | F1, F4, F7 | Filter, refresh, missing-env, and menu polish depend on earlier UI states. |

## Parallelizable Tasks

None for implementation. The accepted design explicitly keeps F1-F8 as one
sequential dependent path because the current Swift workflow runner does not
support fanout transitions, and the write scopes overlap heavily in
`DaemonWorkflowWindowController*`, `EntryPoint*`, and `RielaAppSupport`.

Review and evidence collection can be batched after implementation, but code
changes should land and be reviewed in F1 -> F8 order.

## Verification

Required commands:

```bash
swift test --filter RielaAppSupportTests
swift test --filter RielaAppControllerLayoutTests
swift test --filter RielaAppAddInstanceLayoutTests
swift test --filter RielaAppPromptAccessoryTests
swift test --filter RielaAppWorkflowViewerEmptyStateTests
swift test --filter RielaAppWorkflowViewerVocabularyTests
swift test
git diff --check
```

Required UI evidence under repository-root `tmp/` only:

- Instances window with info banner.
- Instances window with persistent error banner.
- Failed instance row and failed detail status.
- Running instance detail with endpoint.
- Open in Viewer from instance.
- Instance removal confirmation.
- Fresh-profile guided empty state.
- Configure Instance form with required env and Browse controls.
- Event source Form mode.
- Event source JSON mode.
- Masked effective environment values.
- Unmasked opt-in effective environment values with non-secret fixtures.
- Filtered instance zero-result state.
- Missing-env detail row.
- Status menu failed-instance summary.

## Completion Criteria

- F1-F8 deliverables are implemented in sequential order.
- No new user-facing copy violates Source/Instance vocabulary rules.
- Existing persisted daemon workflow preferences remain compatible without
  migration.
- All required narrow tests pass; if a named test target no longer exists, the
  implementer records the successor test command in the progress log.
- Full `swift test` and `git diff --check` pass before review handoff, or
  failures are documented with exact command output and rationale.
- Screenshot evidence for every changed AppKit window/sheet/menu is captured
  under `tmp/` and referenced in the progress log.
- Unrelated current worktree changes, especially agent response streaming
  changes, are not reverted.
- No commit or push is made unless explicitly requested.

## Progress Log Expectations

Implementation must append a dated session entry to this section after each
work pass. Each entry must include completed task ids, in-progress task ids,
verification commands run, screenshot/evidence paths under `tmp/`, blockers,
and any intentional divergence from the accepted design.

### Session: 2026-07-02 Step 4 Plan Creation

**Tasks Completed**: Created actionable implementation plan from accepted Step
3 design.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Step 3 accepted the design with no high or mid findings. No Step 5
feedback exists for this first plan creation pass.

### Session: 2026-07-02 Implementation And Verification

**Tasks Completed**: F1-F8 implemented in the AppKit RielaApp path.

**Tasks In Progress**: None for this plan.

**Verification Commands**:

- `swift build --product RielaApp` passed.
- `swiftlint lint --quiet` passed.
- `git diff --check` passed.
- `swift test --filter RielaAppUXOnboardingControllerTests` passed 5 tests.
- `swift test --filter 'RielaAppUXOnboardingControllerTests|RielaAppStatusMessageTests|RielaAppEnvironmentValueFormatterTests|RielaAppControllerLayoutTests|RielaAppAddInstanceLayoutTests|RielaAppPromptAccessoryTests|RielaAppWorkflowViewerEmptyStateTests|RielaAppWorkflowViewerVocabularyTests|RielaAppSettingsEditorNavigationTests|DaemonWorkflowSupportTests'` passed 76 tests.
- `swift test` ran 882 tests with one unrelated failure in
  `AgentAdapterTests.testCursorThinkingDeltasAreCoalescedBeforeBackendEventHandler`;
  all RielaApp-related suites passed in that full run.

**Screenshot Evidence**:

- `tmp/rielaapp-ux-onboarding-ui/screenshots/instances-window-id.png`
- `tmp/rielaapp-ux-onboarding-ui/screenshots/instances-refresh-banner.png`
- `tmp/rielaapp-ux-onboarding-ui/screenshots/add-instance-choose-workflow.png`

**Blockers**: The original Riela workflow session failed during implementation
because the Swift in-memory publisher does not support fanout transitions, so
the final implementation and verification were completed manually in the same
sequential F1-F8 order.

**Notes**: The Configure Instance modal row action could not be reliably driven
through macOS Accessibility in the scratch UI session because workflow rows are
custom views without stable button labels. The deterministic prompt behavior is
covered by `RielaAppAddInstanceLayoutTests`, `RielaAppPromptAccessoryTests`, and
the generated source-selection screenshot.

## Addressed Feedback

- Step 3 `comm-000542` accepted the design for Step 4 with no findings.
- Step 2 feedback about F4/F8 empty-state ambiguity is carried forward as the
  raw-count versus filtered-count dependency and verification requirement.
- Step 2 feedback about avoiding feature fanout is carried forward as an
  explicit no-parallel-implementation rule.

## Risks

- AppKit layout changes touch shared row, prompt, and pane surfaces; regressions
  are most likely in narrow/tiled window sizes and should be screenshot-tested.
- Status-message migration touches many existing call sites; missing one can
  leave actions visible only in the status menu.
- Event source guided form must stay byte-compatible with the current JSON
  registration path; parser round-trip tests are required before UI review.
- Masked environment display reduces accidental exposure but does not change
  storage semantics; copy must not imply encryption or new secret storage.
- Status-menu failed-instance summaries run during refresh/menu rebuild; keep
  capped output and avoid expensive per-row work.
