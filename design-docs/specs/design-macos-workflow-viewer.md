# macOS Workflow Viewer
This design adds a Riela workflow viewer that opens from the existing macOS
menu bar client. The viewer is a local inspection and managed-editing surface
for selected workflows, persisted runtime sessions, active nodes, per-node
inbox/outbox messages, node patch overrides, prompt template files, and managed
workflow runtime variables.

## Goals

- Open the viewer from `RielaApp`.
- Render workflow nodes as a tree using authored `workflow.json` transitions.
- Show persisted workflow sessions for the selected workflow, including running
  sessions and active step ids.
- Discover the relevant local session store for workflows opened from nested
  directories such as `examples/<workflow>`.
- Highlight active, completed, failed, and idle nodes distinctly.
- Show node details plus inbox and outbox messages for the selected node.
- Let RielaApp-managed workflows edit node patch overrides, current directory,
  inline environment variables, workflow default variables, and prompt template
  files from the same window.
- Keep the runtime/session reader testable outside AppKit.

## Boundaries

`RielaViewer` owns typed viewer state and filesystem loading. It depends only on
`RielaCore`, because persisted sessions and messages are core runtime
contracts.

`RielaApp` owns AppKit UI: the menu item, viewer window, outline tree, session
selector, tabbed detail panes, node patch controls, variable controls, and
prompt-template editor. It must not parse runtime JSON directly.

The first implementation reads local persisted state from the selected
workflow's session store. It does not add remote GraphQL inspection, live
streaming, or timeline animation. Editing remains limited to explicit managed
surfaces: node patch preferences, current directory and variable preferences,
and the selected prompt template file. It does not mutate `workflow.json` graph
structure or persisted runtime session records.

## Data Model

`WorkflowViewerLoader` loads:

- `workflow.json` from the selected workflow directory.
- runtime snapshots from `<sessionStoreRoot>/runtime-records`.
- legacy session-only records from `<sessionStoreRoot>/*.json` as a fallback
  without message details.

When no explicit session store is supplied, the loader walks ancestor
directories from the selected workflow's parent and searches each
`.riela/sessions` candidate. It selects the first readable candidate containing
sessions for the workflow id. Unreadable implicit candidates are reported as
diagnostics but do not block later ancestor candidates. Explicit session stores
remain pinned.

The loader filters sessions to the selected workflow id, sorts by update time,
and builds tree nodes from the entry step plus transition edges. Runtime state
is derived from the selected session:

- `active`: current step or running execution.
- `failed`: any failed execution for the step.
- `completed`: any completed execution for the step.
- `idle`: no selected-session execution evidence.

The typed viewer state always includes a `timeline` array. The loader builds it
from persisted step execution records for the selected session, sorted in
runtime order, with status, backend, attempt, start/end timestamps, latest
backend event metadata, failure reason, and derived duration. A selected
workflow with no selected session returns an empty array. Encoded viewer state
must include `timeline`; only older optional fields such as
`sessionStoreCandidates` and `diagnostics` may be absent when decoding legacy
payloads.

Inbox messages are `WorkflowMessageRecord` values whose `toStepId` matches the
selected node. Outbox messages are records whose `fromStepId` matches the
selected node.

## UI

The menu bar app opens the viewer from the Workflows window. The viewer window
contains:

- an `NSOutlineView` workflow tree with active nodes emphasized;
- a bounded-width session selector listing persisted running/completed/failed
  sessions, or a disabled `No Runs` placeholder;
- an `Edit` tab with workflow/node details, node patch controls, and prompt
  template file editing when the selected node references a template file;
- a `Variables` tab with current directory, inline environment variables, and
  workflow default variables for the managed workflow instance;
- a `Run Log` tab with a selected-session timeline rendered from
  `WorkflowViewerState.timeline` plus selected-node inbox/outbox details;
- a `Structure` tab rendered from the loaded workflow graph.

The viewer should use a compact Settings-like default size and tolerate tiled
window widths. Its default width should be about 640px, with a practical
minimum around 420px and a narrow initial sidebar around 180px, so detail panes
scroll instead of forcing a wide minimum. Long session/template/model values
truncate in bounded popups, and toolbar commands use SF Symbol icon buttons
with accessibility labels instead of text-heavy button strips. Detail,
template, and tab content areas may have preferred heights for a comfortable
default layout, but those heights must be low-priority preferences rather than
required minimums so short tiled windows can shrink the content areas and rely
on scrolling.

The header should present the selected workflow as the title and a short session
summary as supporting text. It should not render database-like captions such as
`Workflow: ... | Sessions: ... | Selected: ...`; users should be able to scan
the window like a Settings pane instead of parsing key/value telemetry.

The workflow tree should show node runtime state with small SF Symbol status
icons and accessibility labels. It should not prefix node titles with
console-like bracket text such as `[Running]` or `[Failed]`.

Session selection, prompt-template selection, and node override editing use
grouped Settings-style rows with compressible title labels. Node overrides are
separate rows for model, backend, effort, and actions so controls remain
legible when the window is tiled to a narrow width.
The popup controls inside these rows expose the row title as their
accessibility label, so VoiceOver users hear `Session`, `Template`, `Model`,
`Backend`, and `Effort` rather than an unlabeled popup.

Instance configuration rows in the Variables tab use the same shared padded,
subtly grouped Settings-style row treatment as the instance window. They should
read as selectable setting rows, not as inline text labels plus separate action
buttons. The shared grouped row background resolves against the current AppKit
appearance so light/dark mode changes do not leave stale fixed colors.
The stack containing those rows lays them out at the available group width, so
the grouped rows fill the Variables tab like a Settings list instead of
shrinking to their intrinsic label width.
Selectable rows visibly respond to pointer hover, press, and keyboard focus
with subtle background emphasis. They expose button accessibility semantics
with clear labels and help text, and they execute through VoiceOver press and
Space/Return keyboard activation as well as pointer clicks. Their title labels
may use a preferred maximum width for alignment, but they must stay
compressible rather than enforcing a fixed 150px label column in narrow tiled
windows.

Refresh reloads from disk so a running workflow can be inspected as session
state changes. Refresh preserves the selected session when it still exists, and
the visible session selector must continue to point at the same session as the
reloaded details. If the selected session disappears between selection and
reload, the viewer falls back to the loader-selected session and rebuilds the
session selector so the popup never displays a stale session label.

Acceptance:

- The viewer must not force a 980px-wide initial window.
- The viewer must not return to the earlier 760px-wide or 700px-wide default,
  nor the 560px-wide or 500px-wide minimum; tiled window managers should be able
  to shrink it to about 420px.
- The initial workflow-tree sidebar should be around 180px, not the older 220px
  layout that left too little width for Settings rows in tiled windows.
- Detail tabs and Settings-style rows must not require 520px+ fixed minimum
  widths just to render.
- Detail, template, and tab content heights must not use required
  `greaterThanOrEqual` constraints; preferred heights should be low priority so
  the viewer can shrink in short tiled layouts.
- Detail, log, structure, and template text surfaces should use borderless
  grouped surfaces with rounded corners and system colors, not dark
  bezel-bordered utility panels.
- Refresh, save, reload, and clear actions in the viewer toolbar should be icon
  controls with accessibility labels.
- Instance configuration rows in the Variables tab should share the grouped
  Settings-style row treatment used by the instance window.
- Instance configuration row groups in the Variables tab should lay out each row
  at the available group width.
- Instance configuration rows that cannot be edited from the current viewer
  context should be visibly disabled and inaccessible to row activation instead
  of accepting a click and then reporting that editing is unavailable.
- Instance configuration row labels should use compressible maximum widths, not
  fixed equal-width constraints.
- Session, template, and node override controls should be grouped rows rather
  than bare horizontal label/control toolbars.
- The node patch save/clear icon controls should sit in a grouped `Node Patch`
  row, not a generic `Actions` row.
- Node override rows that cannot currently be edited should be dimmed as a row
  and expose a plain-language help string, rather than leaving only the inner
  popup or icon control disabled.
- Session, template, and node override row labels should use compressible
  maximum widths rather than fixed equal-width constraints.
- Session, template, model, backend, and effort popups should expose matching
  accessibility labels from their visible Settings row titles.
- The top-of-window workflow/session state should avoid `Workflow:`, `Sessions:`,
  and `Selected:` caption strings.
- Run Log and selected-node detail headers should use compact metadata text such
  as `Session ..., State ..., Updated ...` and `State ..., Node ...`; they
  should not lead with `Status:` or `Runtime:` caption rows.
- Run Log timeline rows, message rows, and Structure rows should use the same
  compact metadata style instead of bracketed status markers such as `[Running]`
  or `[Failed]`.
- The selected step message section should be titled `Step Messages`, not
  `Selected Step Messages`; selection is already implied by the sidebar focus.
- Workflow overview and template rows in the Structure tab should also use
  compact metadata text such as `Workflow ...`, `Entry ...`, `Step ...`, and
  `Used by Step Yes`; they should not show raw developer captions like `id:`,
  `sessionStore:`, `step:`, or `active:`.
- Session picker summaries should use `Current Step ...` for the selected
  runtime step rather than `Active ...`, because active is a storage/runtime
  term that reads like a second status field.
- Selected-node template details should use the same compact metadata text,
  including `Field ...`, instead of bracketed field labels such as
  `worker.md [promptTemplateFile]`.
- Disabled edit affordances should explain the action in plain user language,
  such as `Current directory cannot be edited here`, instead of implementation
  phrasing like `editing is unavailable for this viewer`.
- Empty Run Log searches should use readable metadata-like section text such
  as `Searched Session Stores`, not a raw `Searched:` caption.
- The viewer's initial empty header should use direct action language such as
  `Choose Workflow`, not implementation state such as `No workflow loaded`.
- Session-empty run logs and diagnostics should describe user-visible runs,
  such as `No runs recorded`, not persistence internals such as `No persisted
  sessions found`.
- The empty session picker should show `No Runs`, not `No sessions`, so the
  selector uses the same user-facing vocabulary as the Run Log tab.
- The workflow tree should use symbolic state markers, not bracket-prefixed
  state text in the node title.
- Workflow tree rows should be accessibility buttons with state exposed as an
  accessibility value; VoiceOver press should select the node and update the
  same-window detail view.
- Workflow tree selection should use the shared grouped Settings row background
  instead of AppKit's full-width blue table highlight.
- Session switching should rebuild and reselect the session popup after reload,
  including the fallback path when the previously selected session disappears.
