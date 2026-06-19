# macOS Workflow Viewer

This design adds a Riela workflow viewer that opens from the existing macOS
menu bar client. The viewer is a local inspection surface for selected
workflows, persisted runtime sessions, active nodes, and per-node inbox/outbox
messages.

## Goals

- Open the viewer from `RielaMenuBarApp`.
- Render workflow nodes as a tree using authored `workflow.json` transitions.
- Show persisted workflow sessions for the selected workflow, including running
  sessions and active step ids.
- Highlight active, completed, failed, and idle nodes distinctly.
- Show node details plus inbox and outbox messages for the selected node.
- Keep the runtime/session reader testable outside AppKit.

## Boundaries

`RielaViewer` owns typed viewer state and filesystem loading. It depends only on
`RielaCore`, because persisted sessions and messages are core runtime
contracts.

`RielaMenuBarApp` owns AppKit UI: the menu item, viewer window, outline tree,
session selector, and detail pane. It must not parse runtime JSON directly.

The first implementation reads local persisted state from the selected
workflow's session store. It does not add remote GraphQL inspection, live
streaming, timeline animation, editing, or workflow mutation.

## Data Model

`WorkflowViewerLoader` loads:

- `workflow.json` from the selected workflow directory.
- runtime snapshots from `<sessionStoreRoot>/runtime-records`.
- legacy session-only records from `<sessionStoreRoot>/*.json` as a fallback
  without message details.

The loader filters sessions to the selected workflow id, sorts by update time,
and builds tree nodes from the entry step plus transition edges. Runtime state
is derived from the selected session:

- `active`: current step or running execution.
- `failed`: any failed execution for the step.
- `completed`: any completed execution for the step.
- `idle`: no selected-session execution evidence.

Inbox messages are `WorkflowMessageRecord` values whose `toStepId` matches the
selected node. Outbox messages are records whose `fromStepId` matches the
selected node.

## UI

The menu bar app adds `Open Viewer`. The viewer window contains:

- an `NSOutlineView` workflow tree with active nodes emphasized;
- a session selector listing persisted running/completed/failed sessions;
- a workflow overview;
- per-node inbox and outbox details rendered from persisted messages.

Refresh reloads from disk so a running workflow can be inspected as session
state changes.
