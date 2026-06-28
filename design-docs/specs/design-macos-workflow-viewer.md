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
  sessions, or a disabled `No sessions` placeholder;
- an `Edit` tab with workflow/node details, node patch controls, and prompt
  template file editing when the selected node references a template file;
- a `Variables` tab with current directory, inline environment variables, and
  workflow default variables for the managed workflow instance;
- a `Run Log` tab with a selected-session timeline rendered from
  `WorkflowViewerState.timeline` plus selected-node inbox/outbox details;
- a `Structure` tab rendered from the loaded workflow graph.

Refresh reloads from disk so a running workflow can be inspected as session
state changes. Refresh preserves the selected session when it still exists.
