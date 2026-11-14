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

It does not show a separate visible `Profile` label. The popup is the only
visible control in that row, retains a non-visible accessibility label of
`Profile`, and the row stays compact so the instance list begins near the top
of the window in tiled layouts. The popup may grow for readable profile names,
but it uses a capped, compressible width rather than a fixed 160px frame.

The profile popup can open `Profiles...`. That sheet is profile
management only; it is not where workflow instances are added. Profile rows are
shown as Settings-style rows with the current profile marked inline. Switching
profiles uses the selected row/action, while creating or removing profiles uses
`Use Profile`, `Add Profile`, and `Remove Profile` rows. The sheet title is `Profiles`,
not implementation-oriented copy such as `Profile Select`. The sheet should not expose a
legacy `+`, `-`, `Open`, and `Cancel` button strip. Profile action rows use the
same platform chevron disclosure marker as instance rows, not a literal `>`
text label.
When `Remove Profile` cannot apply to the selected row, it is visually dimmed
and exposed as disabled to accessibility clients with help text explaining why,
using user-facing reasons such as `Default profile cannot be removed here.`
rather than raw profile ids.
When the selected profile is already current, `Use Profile` is also dimmed and
reported as disabled with `This profile is already current.` so the action list
does not invite a no-op.
Profile list rows use the same padded grouped row treatment as action rows, and
the current profile marker uses a platform checkmark symbol rather than a text
glyph. Non-current profile rows use neutral profile copy rather than internal
availability vocabulary. The Add Profile action opens a `Profile Name` edit
surface with a compact Settings-style field row and `Done` confirmation,
instead of a command-titled `Add Profile` form with a detached text field. Its
accessory view uses a bounded width constraint, so it follows the same compact
prompt sizing rules as Add Instance and environment editors.
The Remove Profile row and confirmation must make the deletion boundary clear:
only the selected profile's workflow sources, packages, and instance state are
removed, and other profiles are unchanged. The confirmation should not use a
single ambiguous sentence like `Remove profile <name> and its workflow sources,
packages, and instance state?`.
The profile list uses a preferred, low-priority height rather than a required
minimum so the sheet can shrink and scroll cleanly in short tiled windows.

The top area does not show profile summary text such as
`Profile: default | 1 running | 4 stopped`, last-action captions, or selected
instance captions. Those details either belong in the status menu or in the
same-window instance detail view after the user chooses an instance.

The main window should open at a compact Settings-like size rather than a wide
table-management size. Its default width should fit comfortably in tiled window
managers, and it should declare a practical minimum size around 420px wide so
row truncation and scrolling handle narrow layouts instead of forcing an
oversized window. The window should not return to the earlier 700px-wide
default that made tiled layouts feel unstable. The instance table uses one
resizable Settings-style column with an approximately 180px minimum; it must
not keep a fixed desktop-width column that is wider than the narrow tiled
viewport. The list's 260pt height is only a preferred height, not a required
minimum, so short tiled windows shrink the list and scroll instead of fighting
Auto Layout.

The Instances section header contains compact icon controls:

- plus, with accessibility label `Add Instance`
- refresh, with accessibility label `Refresh Instances`

The profile popup sits in this same header, capped and compressible, so the
window does not need a separate profile-only toolbar row above the instance
list. The plus action opens an `Add Instance` sheet. It does not expose
workflow sources as a second permanent table. Text labels are kept out of these
toolbar controls so the window can stay stable in narrow tiled layouts.

The sheet has two steps:

1. Choose workflow
2. Configure instance parameters

In AppKit, the first implementation may present these as two sequential
`Add Instance` sheets: a compact `Choose Workflow` sheet where selecting a
workflow row advances to a `Configure Instance` sheet with `Create`. The
user-visible flow must still read as workflow selection first and parameter
entry second; the selected workflow is repeated as a read-only Settings-style row
on the configure step.

The workflow selection step lists selectable workflow sources with enough
context to choose safely:

- workflow display name
- source kind such as package, imported workflow, or project workflow
- source path or package name
- environment readiness

Workflow source selection uses a `Workflow Sources` section with
Settings-style selectable rows, not a compact popup as the primary choice
control. Each source row shows name, source kind, environment readiness, and
location, and selecting the row performs the primary choose/relink action. The
user should not have to select a row and then press a separate `Next` or
`Relink` alert button.
The source row list is constrained to a scrollable area so a profile with many
workflow sources does not create an oversized modal or destabilize tiled
window layouts. Its scroll area uses a low-priority preferred height rather
than a required height, so short tiled windows can shrink the sheet and keep the
rows reachable through scrolling. Its scroll document is top-anchored so the
initially visible source rows match the current selection target.

The sheet also has a `Manage Sources` section with secondary
source-management rows:

- `Import Workflow or Package`
- `Add Project Source`

These actions are available while adding an instance because they answer the
user's real question: "the workflow I need is not selectable yet." They are
selectable Settings-style rows inside the sheet, not extra modal buttons next
to `Create`/`Cancel`.

The Finder panels opened from those rows use direct action titles instead of
product/profile-scoped implementation language:

- `Add Workflow Source`
- `Add Project Source`

The explanatory panel copy starts with `Choose`, not `Select one or more`, so it
matches the tone of macOS Settings and keeps the user focused on the object they
are adding.

Add-instance, relink, profile, environment, rename, and variable prompts should
not impose wide fixed row minimums. Their accessory stacks can keep a reasonable
starting frame, but row content must truncate or compress inside that frame
instead of forcing a wider modal or tiled window.

Manage Sources in the Add Instance flow are source-only operations. Importing a
workflow/package from this sheet must not create an instance preference, mark a
source active, or start a daemon. After the source operation finishes, the
workflow selection step reopens with refreshed selectable sources so the user
can continue into Configure Instance.

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
- `.env File`, environment variables, working directory, workflow variables, or
  node patches are present;
- legacy `available == true`, regardless of `active`.

Rows do not include synthetic unconfigured preferences created for bare
discovered workflow candidates. Those are workflow sources and appear only in
the Add Instance flow.

If a persisted preference cannot resolve to a workflow source and has no
display metadata, the list uses the preference key as the instance label,
shows workflow/source context as `Missing source` plus the saved source
identity, and uses `Needs Source` as the trailing state.

The main list is not a multi-column table. It behaves like a macOS Settings or
iOS Settings list:

- primary text: instance name
- secondary text: workflow name, environment readiness, and source description
- trailing text: one user-facing state
- trailing disclosure marker: selecting the row opens the same-window detail
  view. This marker uses the platform chevron symbol, not a literal `>` text
  label.

The visual row container uses the same shared padded grouped row treatment as
detail and prompt rows. Even though AppKit may still use `NSTableView` for
selection and keyboard behavior, the user-facing presentation should read as a
Settings list row rather than a plain multi-column table cell.
Instance rows are accessibility buttons that open the same-window detail view.
Profile rows are accessibility radio-style choices that update the selected
profile row for the action list. Their accessibility help includes the target
profile name, such as `Use work profile`, rather than repeating a generic
`Choose profile` phrase. The list must not be visually Settings-like while
remaining a plain inaccessible table to keyboard or VoiceOver users.

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

The trailing state appears as an accessory value with a small platform symbol
and state text. It is not a fixed-width table column or a large label chip, so
the instance name and workflow summary keep priority when the window is narrow.

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
The same-window detail action section hides `Start`, `Stop`, and `Restart`
while the row is `Needs Source`, shows `Relink Source`, and keeps
`Remove Instance` available. Relinking chooses an existing workflow source by
selecting its row, updates the saved instance `sourceIdentity`, keeps the
instance stopped, and returns the row to the normal instance action set.
If no workflow source is currently selectable, pressing `Relink Source` must
not silently do nothing. It shows the same Settings-style Manage Sources rows
used by Add Instance, with copy that clearly returns the user to relinking this
instance after importing a workflow, package, or project source.
While the row is `Needs Source`, the detail settings section shows only a
read-only missing-source workflow summary that includes the saved source
identity. It must hide source-dependent clickable setting rows such as workflow
reveal, name, environment, working directory, variables, and event sources,
because those actions cannot produce a useful result until the instance is
relinked.

`Remove Instance` deletes only the daemon preference/configuration and stops
the runtime for that identity. It must not delete imported workflow
directories, package directories, package metadata, or project source
registrations. Deleting or unregistering a workflow/package/project source is a
separate source-management action outside the primary instance list.

Selecting an instance keeps the user in the same window. Choosing a row
replaces the list with an instance detail view and a compact `Instances`
navigation control with a platform back chevron. The control must not render a
literal `<` text marker. The detail header does not repeat state labels such as
`State: Running` or `Runtime: ...`. The list already owns state. The detail
view shows current settings as persistent field/value rows. Editable rows
behave like iOS Settings rows: selecting the row opens the editor, with a
platform chevron disclosure marker instead of an exposed `Edit`, `Rename`, or
`Duplicate` button.

Transient status messages for stale selections use user-facing recovery
language such as `Instance could not be found` or
`Workflow source could not be found`; they do not expose
`available`/`unavailable` storage vocabulary.

Primary row actions:

- list row selection: open the same-window instance detail view
- detail setting row selection:
  - reveal source
  - rename
  - edit environment file
  - edit `Environment Variables`
  - edit working directory
  - edit `Workflow Variables`
- detail action row selection:
  - start
  - stop
  - restart
  - remove instance

Current setting rows shown in the detail view:

- workflow source, selectable to reveal;
- name, selectable to rename;
- environment file, selectable to edit;
- `Environment Variables`, selectable to edit;
- working directory, selectable to edit;
- `Workflow Variables`, selectable to edit;
- event sources, read-only.

The detail view has a `Manage Instance` section for the state-relevant
runtime action and remove. These are selectable Settings-style rows, not a
horizontal button bar. The section should not make the user choose among every
possible runtime verb at once:

- `Stopped` and `Failed` show `Start`.
- `Running` and `Reloading` show `Stop` and `Restart`.
- `Starting` and `Stopping` show `Stop`.
- `Needs Source` shows `Relink Source` and `Remove Instance`.

`Remove Instance` is styled as a destructive row and uses direct copy such as
`Delete only this instance.` The action removes only the instance setting; it
does not remove the workflow source, package, or project.

The detail view is vertically scrollable. A tiled window with reduced height
must not trap instance actions below the visible area.

Follow-on editors opened from detail setting rows keep the same interaction
model. When `.env File` or `Working Directory` already has a value, the prompt
shows the current value and target-specific option sections such as
`.env File Options` or `Directory Options` with selectable rows such as
`Choose File`, `Clear .env File`, `Choose Directory`, or
`Clear Directory Override`. These choices should not be presented as a
horizontal alert button strip, and their disclosure marker is the platform
chevron symbol rather than a literal `>` text label. Prompt and picker copy
uses direct action language such as `Choose .env File` or
`Choose Working Directory`, not passive review-oriented text.
Status messages use the same vocabulary: `Set working directory`,
`Cleared working directory`, `Choose a .env file`, `Set .env file`, and
`Updated environment variables`, `Updated workflow variables`, and
`Invalid workflow variables`, rather
than `instance directory`, `Selected env file`, `Select a different .env file`,
`Set env file`, `Cleared env file for instance`, `Invalid env vars`,
`Updated instance variables`, `Invalid instance variables`, or
`Select the directory used`. The credential confirmation
uses `Use .env File?` and explains that values stay hidden in the app, avoiding
implementation-oriented phrases such as `credential material`.
Environment summaries use `.env file`, `environment variables`, and
`required environment variables`, not `file`, `inline env`, or `required env`.

Selectable setting/action rows use one shared AppKit row treatment: padded row
insets, a subtle grouped background, and an 8px corner radius. Profile,
instance detail, environment, rename, add-instance, relink, and variable rows
should look like members of the same Settings-style list instead of unrelated
labels, bare controls, or button strips. Grouped row backgrounds must resolve
against the current effective AppKit appearance so light/dark mode changes do
not leave stale fixed colors. Selectable rows should visibly respond to pointer
hover, press, and keyboard focus with subtle background emphasis. Rows that
perform an action when selected expose button accessibility semantics with a
clear accessibility label and help text, so the iOS/Settings-style interaction
is available beyond visual styling. They should also execute their configured
action from VoiceOver press and keyboard activation with Space or Return,
instead of relying only on a mouse click gesture. Rows with detail text reuse
that detail for hover tooltip and accessibility help rather than repeating only
the row title. Metadata in row subtitles, tooltips, and workflow-source labels
should be short readable helper text
rather than table-like pipe-delimited captions.
Setting-row title labels may use a preferred maximum width for alignment, but
they must remain compressible. They should not use fixed equal-width
constraints that force add-instance, relink, environment, rename, or variable
prompts wider than their accessory view.

Add-instance and relink input rows use that same row treatment for read-only
workflow rows, text-field rows, and toggle rows. Manage Sources fill the prompt
width as a vertical Settings-style list instead of shrinking to the intrinsic
width of their labels. The prompt accessory uses a compact bounded width around
480px with a `lessThanOrEqual` width constraint, so it does not behave like a
fixed desktop form in tiled window layouts.

The `Name` editor opened from the detail view also uses Settings-style
label/control rows for `Instance ID` and `Display Name`; it should not fall
back to a detached vertical label/input form. Name and variable editors use
`Done` as their confirmation action, matching a Settings edit surface, rather
than a document-style `Save` action.

The `Environment Variables` and `Workflow Variables` editors keep their
multiline text editor, but the prompt still uses Settings-style structure: show
a `Variable Settings` section, a `Current Lines` summary row, and an `Editor`
row containing the text editor. The editor should remain usable for several
lines without forcing a wide desktop-sized alert; compact tiled-window layouts
should see a bounded editor accessory rather than a 520px-wide fixed panel. The
editor may prefer a readable height, but that height is low priority so the
prompt can shrink and scroll in short tiled windows.

The workflow viewer's `Variables` tab follows the same pattern for instance
configuration. `Current Directory`, `Environment Variables`, and
`Workflow Variables` are field/value rows with platform chevron disclosure
markers. Selecting a row opens the editor. The tab should not show separate
`Instance Dir...`, `Instance Env...`, or `Instance Variables...` buttons beside
duplicate status labels. Node model/backend/effort overrides remain a separate
`Node Overrides` section because they apply to the selected workflow node rather
than the
instance as a whole.

### Add Instance Sheet

Creating an instance prompts for:

- instance id
- display name
- required environment readiness or a path to configure it
- working directory, defaulting to the workflow source's natural directory
- workflow variables, when the workflow declares or benefits from them
- whether to start immediately, default on

The parameter step uses Settings-style field rows. `Workflow`, `Instance ID`,
`Display Name`, `.env File`, and `Working Directory` appear as label/control
rows. `Start` is a binary row with a trailing checkbox; it does not repeat a
second visible `Start now` label inside the control. The sheet should not read
as a vertical form with detached labels above every field. The parameter rows
sit inside a bounded vertical scroll area with a low-priority preferred height,
so a short tiled window can still reach every setting instead of clipping or
forcing a taller alert.

The saved preference should use:

- `sourceIdentity = selectedSource.id`
- `available = true`
- `active = true` when start-now is selected
- `active = false` when start-now is not selected; the row still appears as
  `Stopped`

Add Instance contract:

- Step 1, Choose Workflow:
  - lists discoverable workflow sources;
  - filters out no-source legacy rows;
  - shows env readiness using the same `Env` vocabulary as the instance list;
  - has secondary action rows to import workflow/package sources or add
    project sources, then refreshes the source list without making workflow
    source management a permanent main-window table.
- Step 2, Configure Instance:
  - presents fields as Settings-style label/control rows;
  - presents the start-immediately option as a `Start` row with a trailing
    checkbox and no duplicate visible `Start now` control title;
  - validates instance id with the same sanitizer as managed duplicate/rename;
  - rejects duplicate ids unless the user explicitly chooses an existing
    stopped instance to update;
  - defaults display name from workflow name;
  - defaults working directory from the selected source;
  - lets the user choose or clear a `.env File`;
  - lets the user enter environment variables and workflow variables using the
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

Replace table-like strings such as:

- `Instances: 2 active / 3 enabled`
- `Status: Ready`
- `Profile: default`

with one compact state-vocabulary summary, for example:

- `Instances 2 running / 1 stopped, Profile default`
- `Instances 1 failed / 2 running, Profile work`
- `Instances none, Profile default`

The status menu remains a compact summary and entry point; detailed workflow
source management stays in the Add Instance sheet.
The compact instance/profile summary line is a disabled secondary menu item
with matching tooltip text, so it reads as status information rather than an
available command.
Any fallback workflow picker opened for the viewer uses direct action language
that names the real action, such as `Choose Workflow to View`, and avoids old
serve-instance language or single-word status messages like `Selected`.

The Launch on Login menu item uses the native checked menu state for ordinary
On/Off state. It should not add a second `Launch on Login: ...` caption row;
only exceptional states such as approval required or unavailable may show a
short supplemental line. That line is disabled, styled as secondary menu text,
and uses the same copy as its tooltip.

## Empty States

Instances empty state:

> No instances. Press + to select a workflow and create one.

Add Instance workflow selection empty state:

> No workflows. Import a workflow, package, or project source.

The empty source state still uses the same sheet context (`Choose Workflow` for
new instances, `Relink Source` for missing-source recovery) and shows the empty
copy as secondary accessory content above Settings-style `Manage Sources` rows.
It should not fall back to a plain alert body with only a Cancel button.

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
- Profile switch status messages use compact metadata-style copy such as
  `Profile work`, not colon captions such as `Profile: work`.
- Import and project-import status messages use sentence-style segments such
  as `Imported demo` and `Failed bad.rielapkg`, not label-like fragments such
  as `imported: demo`, `failed: ...`, or `auto-start off: ...`.
- The profile row contains only profile selection, with no separate visible
  `Profile` label or tall fixed toolbar gap above the instance list. The popup
  still exposes `Profile` as its accessibility label and uses a capped,
  compressible width instead of a fixed 160px frame.
- `Profiles...` is separate from instance creation and uses
  Settings-style selectable/action rows rather than a `+`, `-`, `Open`,
  `Cancel` button strip. Its action rows use platform chevrons, not literal
  `>` text labels.
- Disabled profile actions, especially `Remove Profile` for the default/current
  profile, are dimmed and reported as disabled to accessibility clients.
- `Use Profile` is disabled for the current profile and becomes enabled only
  after selecting a different profile.
- `Remove Profile` row help, tooltip, and confirmation copy make clear that
  only the selected profile is removed and other profiles are unchanged.
- Profile list rows share the padded grouped row styling, and the current
  profile is marked with a platform checkmark symbol.
- The Add Profile prompt opens a `Profile Name` edit surface with a
  Settings-style field row, a compressible label, bounded accessory width, and
  `Done` confirmation instead of a command-titled form with a detached alert
  text field.
- The `Profiles...` sheet list has a low-priority preferred height, no required
  `greaterThanOrEqual` list-height constraint, and can shrink in short tiled
  windows while preserving scrolling.
- The main list top area does not show profile summary, last-action, or
  selected-instance caption rows.
- The empty instance list shows secondary empty-state copy,
  `No instances. Press + to select a workflow and create one.`, instead of a
  blank table.
- The Instances section header contains compact plus and refresh icon controls
  with accessibility labels; row actions live in the same-window instance
  detail view.
- The Instances list has no `Workflow`, `Env`, or `State` table headers; those
  values are folded into a Settings-style row with a trailing state and
  platform chevron disclosure marker rather than a literal `>` text label.
- The trailing state uses a small platform symbol plus text and must not reserve
  a fixed 88px-or-wider state label that causes narrow-window pressure.
- Instance list rows use the shared padded grouped row styling, so the main
  list does not visually regress to plain table cells.
- Instance details open in the same window with a compact `Instances` back
  control that uses a platform chevron-left symbol, not in a separate
  instance-editing window and not with a literal `<` text marker.
- Instance list rows expose same-window navigation as `Show instance details`,
  not `Open instance settings`, so assistive copy matches the in-place detail
  transition.
- The detail view shows current settings as selectable rows instead of
  header/caption labels for state or runtime.
- The detail view's setting and action rows fill the available scroll width
  like a grouped Settings list; they do not shrink to their intrinsic label
  widths and look like detached controls.
- Detail setting rows expose their current value as the row accessibility value,
  so VoiceOver users hear the setting and value together instead of only the
  row title.
- The detail view does not expose standalone `Rename`, `Duplicate`, or `Edit`
  buttons; editable settings are opened by selecting their rows.
- The detail view exposes only state-relevant runtime rows in `Instance
  Actions`: `Start` for stopped or failed rows, `Stop` plus `Restart` for
  running or reloading rows, `Stop` for transitional rows, and relink/remove
  recovery for `Needs Source`.
- `Manage Instance` rows are selectable rows, not a horizontal button bar.
- The detail view scrolls vertically so settings and action rows remain
  reachable in short tiled windows.
- Follow-on prompts for `.env File` and working directory show current values and
  selectable action rows instead of `Choose`/`Clear` alert button strips.
  Their disclosure markers use platform chevrons, not literal `>` text labels.
  Their accessory width is bounded around 440px and rows remain compressible.
- Selectable setting/action rows share padded grouped row styling instead of
  appearing as unrelated labels, bare controls, or horizontal button strips.
- Add-instance and relink field/value/toggle rows use the same padded grouped
  row styling, and Manage Sources fill the prompt width.
- The detail `Name` editor presents instance id and display name as
  Settings-style field rows and uses `Instance Name` copy rather than a
  standalone rename command title.
- Inline env/default variable editors show a current-lines summary row and an
  editor row instead of a bare text view. The editor row uses a low-priority
  preferred height rather than a required minimum height.
- The workflow viewer `Variables` tab shows instance configuration as
  Settings-style rows and keeps selected-node overrides visually separate.
- The Add Instance sheet exposes source-management as `Manage Sources` rows,
  not as extra alert buttons beside `Create` and `Cancel`.
- The `Choose Workflow` step advances by selecting a workflow source row; it does
  not require a separate `Next` alert button after row selection.
- The Add Instance flow uses step-specific sheet titles, `Choose Workflow` and
  `Configure Instance`, rather than reusing a generic `Add Instance` title for
  both steps.
- The Add Instance parameter step uses Settings-style field rows rather than a
  detached vertical label/input form, and its start-immediately control is a
  trailing checkbox in the `Start` row rather than a duplicated `Start now`
  label. Its parameter rows are in a bounded scroll view with a low-priority
  preferred height.
- Add-instance, relink, profile, environment, rename, and variable prompts avoid
  wide fixed row minimums; labels and values truncate or compress inside the
  prompt instead of forcing an oversized window.
- Multiline variable editor prompts use the shared borderless grouped text
  surface with rounded corners, not AppKit's bezel-bordered text panel.
- Workflow sources are selected from the `+` add-instance sheet rather than
  shown as a permanent disabled-instance list.
- Add/relink source selection shows Settings-style selectable source rows with
  name, source kind, location, environment readiness, and a selected-row
  checkmark, not a compressed popup label.
- Add/relink source rows expose row-specific accessibility help such as
  `Choose <workflow name>` instead of repeating the same generic help text for
  every workflow.
- Add/relink source rows are inside a bounded vertical scroll area, so many
  selectable workflows do not make the modal taller than the screen or tiled
  window space. That scroll area's height is a low-priority preference, not a
  required fixed height.
- A user can create an always-on instance by selecting a workflow and entering
  instance parameters.
- `Active` and runtime `Status` are unified into one user-facing `State`.
- `Stopped` instances remain visible until removed; stopping never makes a row
  disappear.
- `Needs Source` instances remain visible with relink/remove recovery.
- `Needs Source` detail actions show `Relink Source` and `Remove Instance`, and
  do not show `Start`, `Stop`, or `Restart` until relink succeeds.
- If no source is available, `Relink Source` opens Manage Sources instead of
  doing nothing.
- Empty Add Instance and Relink Source sheets show the shared secondary
  `No workflows. Import a workflow, package, or project source.` state above
  Settings-style `Manage Sources` rows.
- `Needs Source` detail settings show only a read-only missing-source workflow
  summary and do not expose source-dependent edit/reveal rows before relink.
- Runtime AppKit tests instantiate the workflow instances controller and verify
  compact window sizing, accessible icon controls, profile popup compression,
  `Needs Source` detail visibility, and selectable detail-row button semantics
  instead of relying only on source-string assertions.
- Runtime AppKit tests also instantiate the name and variable prompt view
  factory to verify Settings-style rows, bounded accessory widths, and
  compressible row labels.
- Runtime AppKit tests instantiate the add/relink and environment prompt
  accessory factories to verify bounded widths and `lessThanOrEqual` width
  constraints without relying only on source-string assertions.
- Runtime AppKit tests verify workflow-source row target selection updates the
  selected index and platform checkmark visibility, including out-of-range
  clamping.
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
  `Workflow = Missing source, <saved source identity>`, and
  `State = Needs Source`.
- `Start`, `Stop`, and `Remove Instance` update the legacy `available` and
  `active` fields only as compatibility storage; those field names are never
  shown to users.
- The window remains stable under AeroSpace when tiled narrower than the old
  1180px layout.
- The main instance window uses a compact default width and an explicit minimum
  size instead of keeping the old wide table-style default, with tight
  Settings-style content insets around the list and detail views. The list
  header should not appear detached by a large top gap.
- The instance table column resizes with the table and has a narrow minimum, so
  row labels truncate inside the viewport instead of forcing horizontal
  overflow.
- The instance list scroll area does not keep a required 260pt-or-taller height
  constraint; it may prefer that height at low priority but must shrink in
  short tiled windows.
- Instance, profile, and workflow-tree tables use the grouped Settings row
  background for selection instead of AppKit's full-width blue table highlight,
  so selection feels like the rest of the row-based iOS/macOS Settings UI.
