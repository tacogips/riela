# RielaApp UX and New-User Onboarding Improvements

Status: issue-resolution design draft, updated from runtime intake `comm-000535`

This design proposes user-facing improvements to RielaApp so that everyday
operations are easier for existing users and the app is understandable to a
first-time user who has never seen Riela concepts before. It is a
specification for other implementers; no implementation ships with this
document.

The scope is the macOS RielaApp targets:

- `Sources/RielaApp` (windows, panes, prompts, status menu)
- `Sources/RielaAppSupport` (runtime, preferences, discovery — only where a UI
  change needs a small support-surface addition)
- `Tests/RielaAppSupportTests` (regression tests)

This design builds on and does not revert
`design-docs/specs/design-rielaapp-workflow-instances.md`. The
Source/Instance mental model, the single instance list, and the ban on
`active`/`enabled`/`available` vocabulary in user-facing text all remain in
force.

## Intake and Workflow Boundary

This design update is the Step 2 design document for
`codex-design-and-implement-review-loop-session-877`. The authoritative intake
is runtime communication `comm-000535`; no GitHub issue URL, repository, issue
number, or issue body was supplied. The issue reference for implementation and
review is therefore the runtime issue reference from
`workflowExecutionId=codex-design-and-implement-review-loop-session-877`,
`communicationId=comm-000534`.

Implementation mode is `issue-resolution`. Feature fanout is intentionally not
used because the current Swift workflow runner does not support fanout
transitions. F1 through F8 are treated as one dependent implementation path
with sequential design, implementation, review, and improvement passes. Later
steps may still stage commits or patches internally, but review should judge
the combined Source/Instance onboarding behavior rather than independent
feature branches.

The Codex-agent reference materials for this issue are:

- `<codex-attachment>/pasted-text-1.txt`
- `design-docs/specs/design-rielaapp-ux-onboarding-improvements.md`
- `design-docs/specs/design-rielaapp-workflow-instances.md`

No Cursor-specific behavior is introduced by this design. Any future Cursor or
Codex-agent integration behavior must remain behind adapter modules and must
not leak adapter-specific vocabulary into RielaApp's Source/Instance UI.

## Problem

Code inspection of the current app shows seven concrete usability failures.
Each item below cites where the behavior lives today.

### P1. Operation results and errors are invisible in the window

Nearly every action handler in `EntryPoint*.swift` reports its outcome by
assigning `self.status` (about 80 assignments across
`EntryPoint+DaemonInstances.swift`, `EntryPoint.swift`,
`EntryPoint+Environment.swift`, and others). That string is rendered only as a
small disabled supplementary item inside the status-bar menu
(`EntryPoint+Menu.swift`), which the user is almost never looking at while
working inside the instances window.

`DaemonWorkflowWindowController.update(...)` receives a `statusMessage:
String` parameter (`DaemonWorkflowWindowController.swift:354`) and never uses
it. Consequences for the user:

- "Instance ID already exists: …" — the Configure Instance prompt closes with
  no visible feedback, and the instance silently does not appear.
- "Failed to import source=…" — the import appears to do nothing.
- "Failed to save instance profile state: …" — edits are silently rolled
  back.

### P2. A failed instance never explains why

`RielaAppDaemonWorkflowRuntime.RuntimeSnapshot` carries a `detail` string with
the failure error, endpoint, and per-event-source statuses
(`Sources/RielaAppSupport/DaemonWorkflowSupport.swift:770`). The window
controller stores snapshots (`DaemonWorkflowWindowController.swift:203`) but
only ever reads `snapshot.status` to compute an `InstanceState`
(`instanceState(identity:hasSource:)`). The list row and the detail pane show
the word `Failed` and nothing else. The user cannot diagnose a failed start
without launching the app from a terminal and reading stderr
(`logDaemon(_:)` writes to `FileHandle.standardError`).

### P3. Removing an instance is one click and unconfirmed

`removeSelectedInstance()` (`DaemonWorkflowWindowController.swift:477`) calls
`onRemoveInstance` immediately. The row is styled destructive (red), but a
single click on "Remove Instance" deletes the saved preference and stops the
running daemon (`EntryPoint+DaemonInstances.swift:140`). Profile removal, by
contrast, has a dedicated in-pane confirmation step
(`buildProfileRemovalConfirmationView` in
`DaemonWorkflowWindowController+SettingsShell.swift`). The asymmetry is a data
-loss hazard and inconsistent.

### P4. The Workflow Viewer is unreachable

`openDaemonWorkflowViewer(identity:)`
(`EntryPoint+DaemonWorkflowActions.swift:19`) builds a fully wired viewer
(sessions, logs, node structure, node patches) but no menu item, row, or
button calls it. `openViewer()` (`EntryPoint+Viewer.swift`) is reachable only
through the `initialViewer` launch option. The richest inspection surface in
the app is dead UI for a normal user.

### P5. Advanced editors expect raw JSON and plaintext secrets

- The Event Sources editor
  (`DaemonWorkflowWindowController+ConfigurationEditors.swift:44`) asks the
  user to hand-edit two JSON documents ("Source JSON", "Binding JSON") seeded
  from a hardcoded `telegram-gateway` template. A new user has no way to know
  the valid `kind` values or the binding schema.
- The Environment Variables editor is a free-form `KEY=value` text view, and
  the read-only "Effective Configured Environment" block prints every value in
  plaintext (`effectiveEnvironmentView`), including credentials, on screen.

### P6. First launch teaches nothing

`RielaAppDefaultProfileBootstrapper` installs starter packages into the
default profile, but the instances list a new user sees is an empty table with
one caption: "No instances. Press + to select a workflow and create one."
Nothing explains what a workflow source is, what an instance is, that starter
workflows already exist under Workflow Sources, or what order to do things in
(import → create instance → configure env → start).

### P7. Navigation and input affordance gaps

- `goForward()` is an empty method wired to an always-disabled button
  (`DaemonWorkflowWindowController+Navigation.swift:63`); it occupies toolbar
  space and suggests unimplemented history.
- The instances list has no text filter, while Workflow Sources and the
  add-instance picker both have search fields. Users with many instances
  across profiles scan manually.
- In the Configure Instance prompt (`promptForInstanceParameters`), ".env
  File" and "Working Directory" are free-text fields with no file picker and
  no existence validation; typos surface only later as runtime failures.
- The required-environment warning is a tooltip-only triangle icon on the row
  (`missingEnvironmentWarningIcon`); it names the missing variables but offers
  no path to fix them.
- The manual Refresh button gives no visual feedback even though a 2-second
  timer already refreshes runtime state; users cannot tell whether it did
  anything.

## Goals

- Make every action outcome (success and failure) visible inside the
  instances window without opening the status-bar menu.
- Let a user see why an instance failed and reach its logs from the instance
  detail pane.
- Make destructive instance removal a two-step, in-pane confirmation
  consistent with profile removal.
- Make the Workflow Viewer reachable from instance detail and workflow source
  detail.
- Replace raw-JSON event source registration with a guided form; keep a raw
  JSON escape hatch for advanced users.
- Stop rendering secret values in plaintext in the effective-environment
  view.
- Give the first-run user an in-window guided empty state that teaches the
  Source → Instance → Configure → Start sequence and points at the starter
  workflows.
- Close the small affordance gaps: file pickers for path fields, instance
  filter, actionable missing-env warning, removal of the dead forward button.

## Non-Goals

- No redesign of the sidebar/pane architecture from
  `design-rielaapp-workflow-instances.md`; all changes fit into the existing
  pane host (`showContentPane`) and settings-row idiom
  (`RielaAppSettingsRow`, `rielaAppSettingsSection`).
- No change to persisted `RielaAppDaemonWorkflowPreference` fields, profile
  storage layout, or the compatibility `available`/`active` fields.
- No CLI, GraphQL, or server changes. Where the UI needs more runtime data,
  it is exposed from existing in-process types in `RielaAppSupport` only.
- No localization pass; copy stays English, but this design centralizes new
  copy so a later pass is cheap.
- No new background automation; instances still start only by explicit user
  action or the existing autostart preference path.
- No SwiftUI migration; everything stays AppKit like the surrounding code.

## User Mental Model (unchanged, restated for copy decisions)

- **Workflow Source**: a template imported from a directory, package, or URL.
  Lives in the Workflow Sources pane.
- **Instance**: a named, profile-scoped always-on configuration created from a
  source. Lives in the Instances pane. Start/Stop/Restart/Remove apply to
  instances only.

All new copy in this design uses only these two nouns plus "profile".

## Proposed Changes

The changes are grouped F1-F8 as one sequential, dependent implementation
path. Implementers should complete and review them in order because later
items intentionally reuse behavior or UI affordances introduced earlier:
F4 depends on F1's banner for bootstrap feedback, F5 depends on the
Source/Instance flow clarified by F4, F6 and F7 build on the configuration
surfaces improved by F5, and F8 polishes the combined window behavior after
the earlier states exist. This is not a feature-fanout plan; Step 4 should
plan one ordered implementation path rather than independent feature branches.

---

### F1. In-window status banner (fixes P1)

#### Behavior

Add a transient status banner to the instances window, displayed inside the
content area above the active pane (below the navigation toolbar, full content
width).

- Success/info messages: standard appearance (secondary label color on a
  rounded `controlBackgroundColor` capsule), auto-dismiss after 5 seconds.
- Error messages: `systemRed` tinted icon (`exclamationmark.circle.fill`) and
  border, persist until the user dismisses via an inline close button or a new
  message replaces it.
- The banner never steals focus and never blocks clicks on content below it
  (it takes its own layout slot; it is not an overlay).

#### Message classification

`status` strings today mix successes ("Created instance x") and failures
("Failed to save …"). Rather than string-sniffing, introduce a typed message:

```swift
// RielaAppSupport (new file RielaAppStatusMessage.swift)
public struct RielaAppStatusMessage: Equatable, Sendable {
  public enum Severity: Equatable, Sendable { case info, error }
  public var severity: Severity
  public var text: String
}
```

- `RielaApp.status: String` remains (the status menu keeps using it), but add
  `RielaApp.statusMessage: RielaAppStatusMessage?` set at the same call
  sites. Mechanical rule for the migration: any assignment whose string starts
  with `"Failed"`, contains `"could not"`, or reports a duplicate/invalid
  input becomes `.error`; everything else `.info`.
- `refreshDaemonWorkflowWindow()` passes it through the existing
  `update(...)` call by changing the currently unused parameter
  `statusMessage: String` to `statusMessage: RielaAppStatusMessage?`.

#### Controller side

- New view `RielaAppStatusBannerView: NSView` (icon + message label + close
  button). Lives in a new file `Sources/RielaApp/RielaAppStatusBannerView.swift`.
- `DaemonWorkflowSettingsRootView.layout()` gains a banner slot between
  `toolbar` and `contentHost`: height 0 when hidden, 36 when visible;
  `contentHost` origin shifts accordingly.
- `DaemonWorkflowWindowController.update(...)` shows the banner only when the
  message changed since the last render (keep the last shown message +
  monotonically increasing sequence number provided by the app delegate so the
  same text twice in a row still re-triggers; simplest: the app delegate
  increments a counter every time it sets `statusMessage` and passes
  `(sequence, message)`).
- Auto-dismiss uses a `Timer` owned by the controller; invalidate on
  replacement and on `windowWillClose`.

#### Acceptance criteria

- Creating an instance with a duplicate ID shows a red banner "Instance ID
  already exists: <id>" in the window, without opening the status menu.
- A successful import shows an info banner that disappears on its own.
- The 2-second refresh timer does not resurrect a dismissed banner (sequence
  comparison, not string comparison).

#### Tests

- `RielaAppStatusMessage` classification unit tests (severity per call-site
  rule) in `Tests/RielaAppSupportTests`.
- Layout test in the spirit of `RielaAppControllerLayoutTests`: banner hidden
  → content host origin unchanged; banner visible → content host shifted by
  banner height; error banner persists across an `update()` with the same
  sequence.

---

### F2. Runtime detail on rows and in instance detail, plus reachable logs (fixes P2, P4)

#### 2a. Show `RuntimeSnapshot.detail`

- `ConfiguredWorkflowInstanceRow` gains `stateDetail: String` populated from
  `snapshots[id]?.detail ?? ""` in `makeInstanceRows()` /
  `profiledInstanceRows()` (`DaemonWorkflowWindowController.swift`). Include
  it in `instanceRowsFingerprint(for:)` so detail changes repaint rows.
- List row (`makeInstanceRowView`): when `state == .failed`, the subtitle line
  becomes `Profile <p> · <workflow> · <stateDetail>` (existing
  `rielaAppMetadataText` composition, middle truncation already applied).
  Other states keep the current subtitle to avoid noise.
- Instance detail pane (`buildInstanceDetailView` /
  `updateInstanceDetail()`): add a read-only settings row `Status` above the
  `Workflow` row, value = `<state> — <stateDetail>` when detail is non-empty,
  else `<state>`. For `.running`, detail already carries the endpoint and
  event-source summary from `snapshot(from:)`
  (`DaemonWorkflowSupport.swift:921`), which answers "what port is it on"
  without any new plumbing.

#### 2b. Open the Workflow Viewer from detail panes

- Instance detail "Manage Instance" section gains a row above "Relink
  Source":
  - Title: `Open in Viewer`
  - Detail: `Inspect sessions, logs, and node structure for this instance.`
  - Action: new `@objc func openSelectedInstanceViewer()` on the controller,
    forwarding to a new `onOpenViewer: (String) -> Void` init closure, wired
    in `EntryPoint.swift` to the existing
    `openDaemonWorkflowViewer(identity:)` — the currently dead method becomes
    the implementation, unchanged.
  - Hidden when `state == .needsSource` (same visibility group as the other
    settings rows in `updateDetailActions(for:)`).
- Workflow source detail (`buildWorkflowSourceDetailView`) gains an
  equivalent action row that opens the viewer for the source's
  `workflowDirectory` via `openViewer`-style direct-directory selection (new
  small entry-point helper `openWorkflowSourceViewer(sourceId:)`).

#### 2c. Session store root correctness

`openDaemonWorkflowViewer` currently passes `sessionStoreRoot: nil` while the
daemon runtime writes sessions under `~/.riela/sessions`
(`defaultSessionStoreRoot()` in `DaemonWorkflowSupport.swift:934`). Expose
that value:

```swift
// RielaAppDaemonWorkflowRuntime
public static var defaultSessionStoreRootPath: String { ... } // same value
```

and pass it so the viewer's session list actually finds the instance's runs.

#### Acceptance criteria

- Start an instance that fails (e.g. invalid workflow dir): the row subtitle
  and the detail Status row show the error text, not just "Failed".
- A running instance's detail Status row shows its endpoint.
- "Open in Viewer" from a running instance opens the viewer listing that
  instance's sessions.

#### Tests

- Row-model test: `ConfiguredWorkflowInstanceRow.stateDetail` populated from
  snapshot; fingerprint changes when detail changes.
- Vocabulary test (extend `RielaAppWorkflowViewerVocabularyTests` pattern):
  Status row copy contains no `active`/`enabled`/`available`.

---

### F3. Confirm instance removal in-pane (fixes P3)

Mirror the profile removal pattern exactly
(`ProfileDetailMode.removalConfirmation`).

- Add `enum InstanceDetailPane` case `removalConfirmation` (alongside
  `.overview`, `.inlineEnvironment`, …).
- Clicking "Remove Instance" switches the detail pane to a confirmation view
  built with the existing section idiom:
  - Scope row: `Removes only this instance from profile <p>. The workflow
    source is not deleted.` If `state` is running/starting/reloading, append
    a second row: `This instance is running and will be stopped.`
  - Actions: `Cancel` (returns to `.overview`) and destructive
    `Remove Instance` (calls `onRemoveInstance` then `showInstancesList()`).
- `goBack()` from the confirmation returns to `.overview` (add the case ahead
  of the generic `isShowingInstanceDetail` branch in
  `DaemonWorkflowWindowController+Navigation.swift:32`).

#### Acceptance criteria

- One click on "Remove Instance" never deletes anything.
- Escape/back returns to detail overview with the instance intact.
- Copy matches the Source/Instance vocabulary (explicitly says the source
  survives — this is the fact users are most unsure about).

#### Tests

- Navigation test in the style of `RielaAppSettingsEditorNavigationTests`:
  remove → confirmation pane shown → back → overview; remove → confirm →
  instances list shown and callback fired exactly once.

---

### F4. Guided first-run and empty states (fixes P6)

#### 4a. Instances empty state becomes a guided card

Replace the single `emptyInstancesLabel` with an empty-state view shown in the
same position only when the unfiltered/raw instance count is zero:

```
Set up your first instance

1  Riela ships with starter workflows — find them under
   Workflow Sources, or import your own.
2  Press + to create an instance from a source.
3  Give it a name, point it at a .env file if the workflow
   needs credentials, and start it.

[View Workflow Sources]   [Create Instance]
```

- `View Workflow Sources` → `showSourcesPane()`.
- `Create Instance` → `showAddInstanceSelectionPane()`.
- Implementation: new `DaemonWorkflowEmptyStateView` (title label, three
  numbered rows, horizontal button stack), placed and sized by
  `DaemonWorkflowInstanceListView.layout()` where `emptyLabel` sits today
  (widen the reserved empty frame from 44pt to fitting height).
- The view renders from static copy; no per-profile state. It appears when
  there are no configured instances in the current raw list before applying
  the F8 search filter (new profile, "All Profiles" with none configured).
  It does not appear for a zero-result search/filter when instances still
  exist; F8 owns that filtered-empty message.

#### 4b. Sources empty state

`DaemonWorkflowSourcesPaneView` empty label ("No workflow sources.") becomes:
`No workflow sources in this profile. Import a folder, package, or GitHub URL
with the buttons above.` (pure copy change).

#### 4c. Bootstrap visibility

When `RielaAppDefaultProfileBootstrapper` installs starter packages
(`EntryPoint.swift:796` reports via `status` today), also emit an `.info`
`RielaAppStatusMessage` (F1): `Added starter workflows to Workflow Sources.`
so the very first window open explains why sources are already populated.

#### Acceptance criteria

- Fresh profile or "All Profiles" with zero raw instances: instances pane
  shows the guided card; both buttons navigate correctly.
- Card disappears as soon as one raw instance exists and reappears if all are
  removed.
- If the raw instance count is non-zero but the F8 search filter matches zero
  rows, the guided card stays hidden and the filtered-empty message appears
  instead.

#### Tests

- Empty-state test in the style of `RielaAppWorkflowViewerEmptyStateTests`:
  guided view hidden/shown against raw row counts, not filtered row counts;
  button actions call the navigation selectors (verifiable via pane state
  flags `activeSidebarPane`/`isShowingAddInstanceSelection`).
- Filter-empty test: one or more raw instances plus a search with zero matches
  shows `No instances match the current filter.` and keeps the guided card
  hidden.

---

### F5. Configure Instance form upgrades (fixes P7 input gaps)

All changes inside `promptForInstanceParameters(sourceOption:)`
(`DaemonWorkflowWindowController+Prompts.swift:435`).

- **Instance ID**: placeholder becomes the actual generated default (call a
  new controller-provided closure `defaultInstanceId(for sourceIdentity:)`
  backed by `uniqueDaemonInstanceId(for:)` in
  `EntryPoint+DaemonInstances.swift`), and helper text under the field:
  `Leave empty to use <generated-id>.` This removes the current mystery of
  what an empty ID does.
- **.env File**: append a `Browse…` button (`NSOpenPanel`,
  `canChooseFiles = true`, directories false). After manual edit or pick, if
  the trimmed path is non-empty and the file does not exist, show an inline
  `systemRed` caption `File not found` under the row. Creation stays allowed
  (the runtime tolerates configuring before the file exists) — validation is
  advisory, consistent with the advisory environment-readiness policy noted in
  `design-docs/user-qa/qa-rielaapp-env-file-user-review.md`.
- **Working Directory**: same `Browse…` treatment with
  `canChooseDirectories = true`.
- **Required environment preview**: when
  `option.candidate.requiredEnvironment` is non-empty, insert a read-only row
  after the Workflow row: title `Required Env`, value = comma-separated
  variable names with middle truncation, tooltip = full list. This tells the
  user at creation time that the instance will need a `.env` file, before the
  warning triangle ever appears.
- **Start checkbox**: title the checkbox itself `Start immediately` (today
  the title string is empty with only an accessibility label, so sighted
  users see an unlabeled checkbox next to the row title "Start").

#### Acceptance criteria

- Browse buttons populate the fields; a nonexistent typed path shows the
  inline caption but Create still works.
- A source with required env shows the names in the form.
- Empty ID creates the instance with the id shown in the helper text.

#### Tests

- Extend `RielaAppAddInstanceLayoutTests` / `RielaAppPromptAccessoryTests`:
  rows present in order, browse buttons wired, required-env row hidden for
  sources without requirements, checkbox has a visible title.

---

### F6. Guided event source registration (fixes P5, JSON half)

Keep the current editor as "Advanced (JSON)" and put a form in front.

#### Form

`showEventSourceEditor()` becomes a two-mode editor (segmented control at the
top: `Form | JSON`; form is default):

- **Kind popup**: entries from the daemon-supported event source kinds. Add a
  support-surface accessor so the UI never hardcodes the list:

  ```swift
  // RielaAppSupport (DaemonWorkflowSupport.swift, next to isDaemonSourceKind)
  public static func daemonSourceKinds() -> [String]  // EventSourceKind cases where supportsLiveEventServe
  ```

- **Source ID field**: prefilled with `defaultEventSourceId(for:)` (existing
  helper).
- **Kind-specific hint label** under the popup: one sentence per kind stating
  what it does and what env it typically needs (static copy table in the
  controller extension, keyed by kind raw value; unknown kinds get a generic
  sentence). Example: `telegram-gateway — receives Telegram messages;
  requires TELEGRAM_BOT_TOKEN in this instance's environment.`
- **Binding**: the form always creates one binding
  `{ id: <sourceId>-to-workflow, sourceId, workflowName: <workflowId>,
  inputMapping: { mode: "event-input" } }` — exactly today's template. A
  caption says `The event's payload is passed to the workflow as event
  input.` Users needing custom `inputMapping` switch to JSON mode, which
  shows the two text views exactly as today, seeded from the current form
  values.
- Register action builds the same `(sourceJSON, bindingJSON)` strings and
  calls the existing `onRegisterEventSource` — no entry-point change, no new
  persistence path, validation errors keep surfacing through
  `showEditorError`.

#### Acceptance criteria

- A user can register a telegram-gateway source without typing any JSON.
- Switching Form → JSON carries over the chosen kind/id; JSON mode is byte-
  compatible with today's behavior.
- Kinds list matches `isDaemonSourceKind` acceptance (no kind that the serve
  process will reject).

#### Tests

- `daemonSourceKinds()` unit test: every returned kind satisfies
  `isDaemonSourceKind`; list non-empty.
- Editor test: form-mode register produces JSON that round-trips through the
  same decoder the entry point uses (reuse whatever
  `registerDaemonWorkflowEventSource` parses).

---

### F7. Secret-safe environment display (fixes P5, plaintext half)

In `effectiveEnvironmentView(values:)`
(`DaemonWorkflowWindowController+ConfigurationEditors.swift:246`):

- Render values masked by default: `NAME=•••••••• (source)`. Mask everything;
  do not attempt to classify which names are secrets.
- Add a `Show Values` toggle checkbox above the read-only text view that
  re-renders with plaintext while checked. State is not persisted; every
  editor open starts masked.
- The masked variant shows `value.count` bullets capped at 8 so length leaks
  are bounded.
- The editable "Inline Environment" text view is unchanged (users must be
  able to edit real values), but gains a caption: `Values entered here are
  stored in this profile's instance state on disk.` — the honest statement of
  where the data goes (`daemon-workflows.json`).

#### Acceptance criteria

- Opening the Environment Variables editor never shows configured values
  until the user opts in.
- QA doc `qa-rielaapp-env-file-user-review.md` claim "Credential values are
  not rendered in UI" becomes true for this surface again.

#### Tests

- Unit test the masking formatter (pure function: `[ConfiguredValue] → String`
  masked/unmasked).

---

### F8. Navigation and small-affordance cleanup (fixes rest of P7)

- **Remove the forward button**: delete `navigationForwardButton`, its
  separator, and empty `goForward()`; the nav group becomes a single back
  button. (If real history is ever wanted, it should be a separate design;
  today's button is permanently disabled and misleading.)
- **Instance filter**: add an `NSSearchField` to the instances list header
  (right of the title, left of the profile popup), filtering
  `cachedInstanceRows` by instance name, workflow name, profile, and state
  string — same matching options as `filteredWorkflowSources`
  (case/diacritic-insensitive substring). Filter text is part of the rows
  fingerprint. The renderer must keep two counts: raw instances before
  filtering and visible rows after filtering. When raw count is zero, F4's
  guided card is shown. When raw count is non-zero and visible row count is
  zero, the filtered-empty state shows `No instances match the current
  filter.` and the F4 guided card remains hidden.
- **Actionable missing-env warning**: the warning triangle in
  `makeInstanceRowView` remains, and the instance detail `.env File` row
  additionally gets a leading warning icon and its value label shows
  `Missing: <names>` (from `environmentColumnStatus`) when
  `hasMissingRequiredEnvironment`. Clicking the row already opens the env
  file picker, so the fix path becomes: see red text → click that row.
- **Refresh feedback**: after a manual refresh completes, emit an `.info`
  status message `Refreshed.` through F1's banner (cheap, honest feedback; no
  spinner needed since refresh is synchronous today).
- **Status menu**: append one supplementary line per failed instance (max 3,
  then `+N more failing`) under the existing summary line in
  `rebuildMenu()`, e.g. `⚠ tg-bot: Failed`. Selecting the existing
  `Instances...` item remains the way to act on it. This makes the menu bar
  icon useful as a health glance without building menu-level controls.

#### Tests

- Filter test: rows filtered by each searchable component; fingerprint
  changes with filter text.
- Filter-empty test: raw count non-zero plus zero visible rows shows only the
  filtered-empty message, while raw count zero shows only the F4 guided card.
- Layout tests updated for the removed forward button (adjust
  `RielaAppControllerLayoutTests` expectations).
- Menu test: failed instances appear in the status menu summary lines,
  capped.

## Copy Inventory (new user-visible strings)

Centralize all strings introduced by this design in one enum per window
controller extension (pattern already used by `ImportSourceCopy` in
`DaemonWorkflowWindowController.swift:76`), e.g. `InstancesEmptyStateCopy`,
`EventSourceFormCopy`, `RemovalConfirmationCopy`, `EnvironmentEditorCopy`.
Vocabulary rules:

- Allowed nouns: workflow source, instance, profile, workflow, event source.
- Forbidden in user-facing text: `active`, `enabled`, `available`,
  `candidate`, `preference`, `daemon` (test-enforced today by the vocabulary
  test pattern; extend those tests to the new copy enums).

## Implementation Phasing

| Phase | Items | Rationale |
|-------|-------|-----------|
| 1 | F1 | Establish the typed in-window feedback channel that later bootstrap, refresh, and error surfaces reuse. |
| 2 | F2 | Add runtime detail and viewer access after F1 so failed-start diagnostics have a visible feedback path. |
| 3 | F3 | Add the destructive-action confirmation once the detail pane can reliably explain instance state. |
| 4 | F4 | Add the guided empty state after the base Source/Instance and feedback behavior is stable. |
| 5 | F5 | Improve Configure Instance after F4 defines the Source -> Instance -> Configure -> Start path. |
| 6 | F6 | Add guided event-source registration on top of the upgraded configuration patterns from F5. |
| 7 | F7 | Mask effective environment values after the environment/configuration surfaces are in their final shape. |
| 8 | F8 | Remove dead navigation and add filter, refresh, missing-env, and status-menu polish after all earlier states exist. |

None of the phases migrates data. Rollback should treat this as one ordered
path: if a later phase needs to be reverted, preserve or adjust the earlier
phase contracts it depends on rather than treating F1-F8 as parallel feature
work. F1 introduces the only cross-cutting type
(`RielaAppStatusMessage`) and must land first since F4c and F8 reference it.

## Compatibility

- `RielaAppDaemonWorkflowPreference`, profile stores, and
  `daemon-workflows.json` are untouched.
- `DaemonWorkflowWindowController.init` gains two closures (`onOpenViewer`,
  `defaultInstanceId`) and `update(...)` changes the type of its already-
  unused `statusMessage` parameter — both are internal to the RielaApp target
  and mirrored in the single construction site (`openDaemonInstances()` in
  `EntryPoint.swift`).
- `RielaAppSupport` additions (`RielaAppStatusMessage`,
  `daemonSourceKinds()`, `defaultSessionStoreRootPath`) are additive public
  API; no existing signature changes.
- The event source form emits the identical JSON shape the current editor
  produced, so `.riela-events` artifacts are unchanged.

## Open Questions

- Should the F4 guided card include a "Don't show again" preference? This
  design says no (it only appears when the list is empty, which is already
  self-limiting), but if user feedback disagrees, the toggle would need a new
  per-profile UI-state field — flagging it now because that would touch the
  preference store this design otherwise avoids.
- F8's status-menu failure lines poll from `rebuildMenu()`, which is called
  on every refresh tick; if menu rebuild cost becomes visible with many
  instances, cap the summary computation with the existing fingerprint
  technique.

## Issue-to-Design Mapping

| Intake signal | Design location | Required review evidence |
|---------------|-----------------|--------------------------|
| F1 status banner shows info/error outcomes in-window; errors persist until dismissed; refresh timer does not resurrect dismissed messages. | F1 in-window status banner; `RielaAppStatusMessage`; controller sequence handling. | `swift test --filter RielaAppStatusMessage`, layout coverage for banner hidden/visible/persistent states, and RielaApp screenshot of duplicate-ID error. |
| F2 failed instance rows/detail panes show `RuntimeSnapshot.detail`; Open in Viewer is reachable; session-store root behavior is corrected. | F2 runtime detail rows, detail Status row, `onOpenViewer`, `defaultSessionStoreRootPath`. | `swift test --filter RielaAppWorkflowViewer`, row/fingerprint tests, and screenshot showing failed detail text plus Open in Viewer. |
| F3 removing an instance requires a two-step confirmation consistent with profile removal. | F3 `InstanceDetailPane.removalConfirmation`; back/cancel/confirm behavior. | `swift test --filter RielaAppSettingsEditorNavigationTests` or successor instance-navigation test, plus screenshot of confirmation pane. |
| F4 empty states guide Source -> Instance -> Configure -> Start and expose useful navigation actions. | F4 guided instances empty state and sources empty copy. | `swift test --filter RielaAppWorkflowViewerEmptyStateTests` or successor empty-state tests, plus screenshot of fresh-profile instances pane. |
| F5 Configure Instance form has Browse controls, generated ID preview, and required environment visibility/validation. | F5 Configure Instance form upgrades. | `swift test --filter RielaAppAddInstanceLayoutTests` and `swift test --filter RielaAppPromptAccessoryTests`, plus screenshot of Configure Instance with required env and Browse controls. |
| F6 event source setup provides guided kind-specific forms and preserves raw JSON as advanced mode. | F6 segmented Form/JSON event-source editor and `daemonSourceKinds()`. | `swift test --filter DaemonWorkflowSupportTests` or focused `daemonSourceKinds` test, editor JSON round-trip test, plus screenshot of Form and JSON modes. |
| F7 effective environment values are masked by default with explicit Show Values opt-in. | F7 masked effective environment display and unpersisted Show Values toggle. | Masking formatter unit test, `swift test --filter RielaAppEnvironmentFileStoreTests` where relevant, and screenshot of masked and opt-in unmasked states using non-secret fixture values. |
| F8 forward navigation dead control is removed; instance filtering, missing-env actions, refresh feedback, and status-menu failure visibility are polished. | F8 navigation cleanup, filter, missing-env row action, refresh banner, status-menu failed-instance lines. | `swift test --filter RielaAppControllerLayoutTests`, status menu tests, filter tests, and screenshots of filtered empty result and failed-instance menu summary. |

## Verification Plan

Implementation review should run the narrow tests for changed support and
AppKit surfaces first, then the broader Swift suite if the changes compile
cleanly:

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

RielaApp UI verification must capture screenshots for every changed window or
sheet: the instances window with an info banner, an error banner, failed row
detail, removal confirmation, guided empty state, Configure Instance, event
source Form mode, event source JSON mode, masked environment values, filtered
instances, and status-menu failed-instance visibility. Screenshots are review
evidence only; scratch outputs must stay under repository-root `tmp/` and must
not be added to git.

## Review Feedback Status

Step 2 self-review feedback `comm-000537` reported one mid-severity ambiguity:
F4 described the guided empty state as appearing whenever the filtered instance
list is empty, while F8 reserved filtered zero-result states for `No instances
match the current filter.` This update resolves that finding by defining raw
instance count zero as the only condition for the F4 guided card and raw count
non-zero plus visible filtered count zero as the F8 filtered-empty condition.
F4 and F8 acceptance criteria and tests now require those separate states.

Step 2 self-review feedback `comm-000539` reported one mid-severity conflict:
the intake boundary said F1-F8 are one dependent sequential implementation
path with no feature fanout, while Proposed Changes and Implementation Phasing
still described later items as parallelizable. This update resolves that
finding by making Proposed Changes and Implementation Phasing explicitly
sequential from F1 through F8 and by removing parallel-implementation
language.

No Step 3 design-review or Step 5 implementation-plan-review feedback for
`codex-design-and-implement-review-loop-session-877` was present in the local
runtime records inspected during this Step 2 update. If later review feedback
arrives, high and mid findings must be resolved in this document before
implementation proceeds.
