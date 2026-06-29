# RielaApp Workflow Instances

Status: reviewed draft

This design replaces the crowded RielaApp workflow instance window with a
single instance-focused screen and an add-instance picker that matches how
users reason about always-on automation.

## Problem

The current window mixes three concepts:

- workflow sources discovered from profiles, projects, packages, and imported
  workflow directories;
- configured daemon preferences, stored as `RielaAppDaemonWorkflowPreference`;
- running or always-on daemon instances.

That mix leaks implementation fields into the UI. A user sees `Enabled
Instances`, `Disabled Instances`, and an `Active` column. This is confusing:
an enabled item with `Active: No` is not acting like an always-on instance, and
a disabled item is not really a disabled instance; it is a selectable workflow
source or an inactive profile preference. Showing that second list beside
instances makes the primary screen feel like a database table instead of a tool
for managing always-on processes.

The window also has too many header actions. The user has to scan a long row of
buttons before understanding the primary task. AeroSpace/tiled layouts make the
problem worse because the header content creates a large effective minimum
width.

## User Mental Model

RielaApp has two user-facing nouns:

- **Workflow Source**: a workflow, package workflow, or project workflow that
  can be selected while creating one or more daemon instances. It is not shown
  as an instance on the main screen.
- **Instance**: a named, profile-scoped, always-on daemon configuration created
  from a workflow source.

An instance is something RielaApp should manage as a daemon configuration. It
stays visible until the user removes it, even when it is currently stopped. A
workflow source is only a selectable template for creating an instance and does
not appear as a main-list row. The user can start, stop, restart, or remove an
instance without deleting the underlying workflow source.

## Goals

- Make the primary list show only real daemon instances.
- Hide workflow sources from the main screen unless the user is creating an
  instance.
- Let the user add a new instance by pressing `+`, selecting a workflow, and
  entering the parameters needed for that instance.
- Remove `Enabled Instances`, `Disabled Instances`, and `Active: Yes/No`
  terminology from the main instance window.
- Replace the separate `Active` and `Status` fields with one user-facing state.
- Remove internal `active`, `enabled`, and `available` vocabulary from all
  RielaApp user-facing summaries, including the status menu.
- Reduce header buttons so the window is stable in tiled window managers.
- Keep existing profile storage compatible with already-created preferences.

## Non-Goals

- Do not remove the existing persisted `available` and `active` fields in this
  change. They remain compatibility fields until a data migration is designed.
- Do not change the workflow viewer tabs in this design.
- Do not remove project/package import support.
- Do not introduce background automation that starts workflows without an
  explicit instance.
- Do not require a data migration before the UI can stop showing the old
  enabled/active split.

## Proposed UI

The window title remains `Riela Workflow Instances`.

The top profile row contains:

- Profile popup

The top area does not show profile summary text such as
`Profile: default | 1 running | 4 stopped`, last-action captions, or selected
instance captions. Those details either belong in the status menu or in the
same-window instance detail view after the user chooses an instance.

The Instances section header contains:

- `+ Add Instance`
- `Refresh`

The `+` action opens an `Add Instance` sheet. It does not expose workflow
sources as a second permanent table.

The sheet has two steps:

1. Select workflow
2. Configure instance parameters

The workflow selection step lists selectable workflow sources with enough
context to choose safely:

- workflow display name
- source kind such as package, imported workflow, or project workflow
- source path or package name
- environment readiness

The sheet also has secondary source-management actions:

- `Import Workflow or Package...`
- `Add Project Source...`

These actions are available while adding an instance because they answer the
user's real question: "the workflow I need is not selectable yet."

The main content has one primary section:

- **Instances**

### Instances Section

The Instances table lists configured daemon instances. A row means "RielaApp has
a named daemon configuration for this workflow." It does not mean the process is
currently running.

Rows come from persisted preferences whose source workflow still exists and
whose record represents configured instance intent. Rows also include
configured preferences whose source workflow is temporarily missing or
unresolved, so saved work does not disappear.

A configured instance row is derived from persisted preference existence. Every
entry in `RielaAppDaemonWorkflowState.preferences` is shown as an instance row
unless the implementation can prove it is an in-memory synthetic source option.
This favors visibility over hiding saved user state.

Additional fields improve the row, but are not required for visibility:

- the preference key exists in `RielaAppDaemonWorkflowState.preferences` and
  resolves to a workflow source;
- `sourceIdentity` is present;
- `displayName` is present;
- environment file, inline environment variables, working directory, default
  variables, or node patches are present;
- legacy `available == true`, regardless of `active`.

Rows do not include synthetic unconfigured preferences created for bare
discovered workflow candidates. Those are workflow sources and appear only in
the Add Instance flow.

If a persisted preference cannot resolve to a workflow source and has no
display metadata, the list uses the preference key as the instance label,
shows workflow/source context as `Missing source`, and uses `Needs Source` as
the trailing state.

The main list is not a multi-column table. It behaves like a macOS Settings or
iOS Settings list:

- primary text: instance name
- secondary text: workflow name, environment readiness, and source description
- trailing text: one user-facing state
- trailing disclosure marker: selecting the row opens the same-window detail
  view

There are no separate `Active` and `Status` columns. The single trailing state
combines configured daemon intent and runtime status into user-facing states:

- `Running`
- `Starting`
- `Reloading`
- `Stopped`
- `Failed`
- `Stopping`
- `Needs Source`

The main list only contains intended daemon instances, so the state display
does not need to say whether the row is active. If a row exists here, it is a saved
instance RielaApp can manage.

State mapping:

- Runtime `running` -> `Running`
- Runtime `starting` -> `Starting`
- Runtime `reloading` -> `Reloading`
- Runtime `stopping` -> `Stopping`
- Runtime `failed` -> `Failed`
- No running snapshot and saved instance preference -> `Stopped`
- Saved instance preference whose workflow source cannot be resolved ->
  `Needs Source`

`Stop` means "stop this instance and keep it visible as `Stopped` until the
user presses `Start` or removes it." It also persists the instance as not
started on next app launch. `Start` means "start this instance and mark it for
future app-launch autostart." This replaces the old `Active` toggle with
action-oriented verbs and one visible state.

`Needs Source` rows offer `Relink Source...` and `Remove Instance`. They do not
offer `Start` until the source is resolved.

`Remove Instance` deletes only the daemon preference/configuration and stops
the runtime for that identity. It must not delete imported workflow
directories, package directories, package metadata, or project source
registrations. Deleting or unregistering a workflow/package/project source is a
separate source-management action outside the primary instance list.

Selecting an instance keeps the user in the same window. Choosing a row
replaces the list with an instance detail view and a compact `< Instances`
navigation control. The detail header does not repeat state labels such as
`State: Running` or `Runtime: ...`. The list already owns state. The detail
view shows current settings as persistent field/value rows. Editable rows
behave like iOS Settings rows: selecting the row opens the editor, with a
disclosure marker instead of an exposed `Edit`, `Rename`, or `Duplicate`
button.

Primary row actions:

- list row selection: open the same-window instance detail view
- detail setting row selection:
  - reveal source
  - rename
  - edit environment file
  - edit inline environment variables
  - edit working directory
  - edit default variables
- detail action row selection:
  - start
  - stop
  - restart
  - remove instance

Current setting rows shown in the detail view:

- workflow source, selectable to reveal;
- name, selectable to rename;
- environment file, selectable to edit;
- inline environment variables, selectable to edit;
- working directory, selectable to edit;
- default variables, selectable to edit;
- event sources, read-only.

The detail view has an `Instance Actions` section for start, stop, restart, and
remove. These are selectable Settings-style rows, not a horizontal button bar.
`Remove Instance` is styled as a destructive row and deletes only the daemon
preference/configuration.

The detail view is vertically scrollable. A tiled window with reduced height
must not trap instance actions below the visible area.

### Add Instance Sheet

Creating an instance prompts for:

- instance id
- display name
- required environment readiness or a path to configure it
- working directory, defaulting to the workflow source's natural directory
- default variables, when the workflow declares or benefits from them
- whether to start immediately, default on

The saved preference should use:

- `sourceIdentity = selectedSource.id`
- `available = true`
- `active = true` when start-now is selected
- `active = false` when start-now is not selected; the row still appears as
  `Stopped`

Add Instance contract:

- Step 1, Select Workflow:
  - lists discoverable workflow sources;
  - filters out no-source legacy rows;
  - shows env readiness using the same `Env` vocabulary as the instance list;
  - has secondary actions to import workflow/package sources or add project
    sources, then refreshes the source list without closing the sheet.
- Step 2, Configure Instance:
  - validates instance id with the same sanitizer as managed duplicate/rename;
  - rejects duplicate ids unless the user explicitly chooses an existing
    stopped instance to update;
  - defaults display name from workflow name;
  - defaults working directory from the selected source;
  - lets the user choose or clear an env file;
  - lets the user enter inline env variables and default variables using the
    existing parsers;
  - leaves node patches out of the first sheet version; node patches remain in
    the viewer/editor;
  - shows unknown required parameters as warnings, not blockers, when workflow
    metadata cannot expose a machine-readable schema;
  - saves the preference before starting;
  - if start-now is on, starts the instance and shows the row immediately;
  - if start-now is off, shows the row immediately as `Stopped`.

If start-now is off, the row still appears as an instance because the user just
created it as one. Its `State` is `Stopped`, and the row offers `Start`.
This is different from the old `Enabled + Active: No` presentation because the
row is explicitly an instance, and `Stopped` is a runtime/actionable state.

## Compatibility Mapping

Existing preferences are mapped as follows:

- saved preference with resolved source and `active == true`: show in Instances
  using runtime-derived state.
- saved preference with resolved source and `active == false`: show in
  Instances as `Stopped`.
- saved preference with unresolved source:
  show in Instances as `Needs Source`.
- bare discovered workflow source without a saved preference: show only in the
  Add Instance source picker.

Start/Stop/Remove persistence mapping:

- `Start`: set legacy `available = true`, set legacy `active = true`, then
  start runtime.
- `Stop`: keep legacy `available = true`, set legacy `active = false`, then
  stop runtime. The row remains visible as `Stopped`.
- `Remove Instance`: stop runtime and remove the preference entry. Do not touch
  workflow/package/project source files or registrations.

The first implementation must not create a visible `Disabled Instances`
section. If an old disabled preference conflicts with a new instance for the
same source, the add-instance workflow can offer:

- `Use existing stopped instance`
- `Create another instance`
- `Delete old disabled configuration`

## View Model Split

Implementation should not drive the UI directly from
`RielaAppDaemonWorkflowState.workflowInstances(from:)`, because that helper
currently merges configured preferences and unconfigured source candidates.

The app window should derive two separate view models:

- `ConfiguredWorkflowInstanceRow`: saved preference plus resolved workflow
  source plus runtime snapshot, or saved preference plus unresolved source
  metadata, shown in the main Instances table.
- `WorkflowSourceOption`: resolved workflow source plus env readiness, shown
  only inside the Add Instance sheet.

The old internal fields remain storage details:

- `available` is a legacy storage flag, not a user concept.
- `active` is a legacy autostart flag, not a user concept.

Neither label appears in main-window columns, summaries, tooltips, or tests.

## Status Menu

The status item menu should summarize instance state without exposing
`active`, `enabled`, or `available`.

Replace strings like:

- `Instances: 2 active / 3 enabled`

with state vocabulary, for example:

- `Instances: 2 running / 1 stopped`
- `Instances: 1 failed / 2 running`
- `Instances: none`

The status menu remains a compact summary and entry point; detailed workflow
source management stays in the Add Instance sheet.

## Empty States

Instances empty state:

> No instances. Press + to select a workflow and create one.

Add Instance workflow selection empty state:

> No selectable workflows. Import a workflow, package, or project source.

## Risk Review Questions

- Can a source have multiple instances without making selection ambiguous?
- Should instance configuration move entirely into the viewer to keep the
  instance window simple?
- Does source management need a separate advanced screen later, beyond the
  import/add-source shortcuts in the Add Instance sheet?

## Acceptance Criteria

- The main window no longer contains `Enabled Instances`, `Disabled Instances`,
  or an `Active` column.
- The status menu no longer contains active/enabled/available summaries.
- The profile row contains only profile selection.
- The main list top area does not show profile summary, last-action, or
  selected-instance caption rows.
- The Instances section header contains `+ Add Instance` and `Refresh`; row
  actions live in the same-window instance detail view.
- The Instances list has no `Workflow`, `Env`, or `State` table headers; those
  values are folded into a Settings-style row with a trailing state and
  disclosure marker.
- Instance details open in the same window with a compact `< Instances` control,
  not in a separate instance-editing window.
- The detail view shows current settings as selectable rows instead of
  header/caption labels for state or runtime.
- The detail view does not expose standalone `Rename`, `Duplicate`, or `Edit`
  buttons; editable settings are opened by selecting their rows.
- The detail view exposes `Start`, `Stop`, `Restart`, and `Remove Instance` as
  selectable `Instance Actions` rows, not as a horizontal button bar.
- The detail view scrolls vertically so settings and action rows remain
  reachable in short tiled windows.
- Workflow sources are selected from the `+` add-instance sheet rather than
  shown as a permanent disabled-instance list.
- A user can create an always-on instance by selecting a workflow and entering
  instance parameters.
- `Active` and runtime `Status` are unified into one user-facing `State`.
- `Stopped` instances remain visible until removed; stopping never makes a row
  disappear.
- `Needs Source` instances remain visible with relink/remove recovery.
- Existing persisted state still loads without data loss.
- Tests fail if main-window source contains `Enabled Instances`,
  `Disabled Instances`, `title: "Active"`, or active/enabled summary copy.
- Existing interface tests must be updated in the same implementation slice to
  assert absence of old vocabulary rather than preserving it.
- Removing an instance preserves workflow/package/project sources unless the
  user takes an explicit source-management delete action.
- Every persisted daemon preference row remains visible as an instance unless
  the implementation can prove it is only a synthetic discovered-source option.
- Unresolved persisted preferences render with a stable fallback label,
  `Workflow = Missing source`, and `State = Needs Source`.
- `Start`, `Stop`, and `Remove Instance` update the legacy `available` and
  `active` fields only as compatibility storage; those field names are never
  shown to users.
- The window remains stable under AeroSpace when tiled narrower than the old
  1180px layout.
