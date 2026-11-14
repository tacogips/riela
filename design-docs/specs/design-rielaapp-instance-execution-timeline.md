# RielaApp Instance Execution Timeline

Status: reviewed draft

Add a Jaeger-style execution timeline to RielaApp so an operator can see, for one workflow instance session, every node execution as a Gantt bar (nodes on the vertical axis, time on the horizontal axis) and open a per-execution popup that shows its log, inbox, and outbox.

## Problem

RielaApp can start/stop daemon workflow instances and open a Workflow Viewer window, but execution history is only visible as flat text: `WorkflowViewerWindowController+Rendering.swift` renders `renderTimeline(_:)` output as lines inside an `NSTextView`. Operators cannot see at a glance:

- which node ran when, for how long, and in what order;
- where time was spent (long-running agent nodes vs. instant routing steps);
- retries (`attempt > 1`) and where a session failed or stalled;
- what a node received (inbox) and produced (outbox) without dropping to `riela session status` / `session export` in a terminal.

The runtime already persists everything needed: `WorkflowStepExecution` records per-node start/end timestamps, status, attempt, backend, failure reason, and recent backend events; `WorkflowMessageRecord` records the inbox/outbox message flow between steps. Only the visualization is missing.

## User Mental Model

"Like the Jaeger trace view: each node is a row, time flows left to right, each execution is a colored bar. I click a bar to see what that node logged, what it consumed, and what it emitted."

## Goals

- A graphical **Timeline pane** in the Workflow Viewer window that renders one session's node executions as a Gantt chart: step rows on the Y axis, wall-clock time on the X axis.
- Each `WorkflowStepExecution` renders as one bar (start = `createdAt`, end = `updatedAt`, still-running bars extend to "now"), colored by status, labeled with attempt number when `attempt > 1`.
- Transition connectors between bars so the execution flow (which step handed off to which) is readable, derived from persisted `WorkflowMessageRecord` routing (`fromStepId` → `toStepId`).
- Clicking a bar opens a popup (NSPopover) with three sections: **Log** (backend events), **Inbox** (messages delivered to the step), **Outbox** (messages published by that execution), plus an overview header (status, backend, duration, failure reason).
- Entry point from the instance UI: the instance detail pane in `DaemonWorkflowWindowController` gains a "View Execution Log" action that opens the Workflow Viewer focused on the Timeline pane for that instance's workflow.
- Works for both finished and running sessions; running sessions refresh periodically.
- Session selection reuses the existing viewer session selector; switching sessions redraws the timeline.

## Non-Goals

- No OpenTelemetry/OTLP export or Jaeger integration; this is a local visualization of Riela's own persisted records (`design-workflow-progress-observability` covers exporter concerns).
- No live push streaming from the runtime (`WorkflowRunEvent` is ephemeral and not persisted); refresh is poll-based reload through `WorkflowViewerLoader`.
- No editing/replay actions from the timeline (retry-step, replay-communication remain GraphQL/CLI concerns).
- No nested/called-workflow flattening in the first slice: the timeline shows the selected session's own executions only.
- No SwiftUI migration; the pane follows the existing AppKit custom-drawing patterns (`DaemonWorkflowGraphCanvasView`).

## Data Sources (existing, verified)

| Need | Source | Notes |
| ---- | ------ | ----- |
| Bar start/end | `WorkflowStepExecution.createdAt` / `.updatedAt` (`Sources/RielaCore/RuntimeSession.swift`) | `updatedAt` is the end proxy; for `status == .running` the bar extends to now |
| Bar row / label | `WorkflowStepExecution.stepId`, `nodeId`, `attempt` | one Y row per `stepId` |
| Bar color | `WorkflowStepExecutionStatus` (running/completed/skipped/failed) | |
| Log popup | `WorkflowStepExecution.recentBackendEvents: [WorkflowBackendEventRecord]?`, `backendEventCount`, `lastBackendEventAt/Type`, `failureReason` | recent events may be truncated — popup must show "recent N of M" when `backendEventCount > recentBackendEvents.count` |
| Inbox | `WorkflowMessageRecord` where `toStepId == stepId`, ordered by `createdOrder` | payload JSON + lifecycle status |
| Outbox | `WorkflowMessageRecord` where `sourceStepExecutionId == executionId` (fallback `fromStepId == stepId`) | |
| Transitions | outbox record's `fromStepId` → `toStepId` pairs matched to the next execution of the target step | fallback: consecutive execution order when no message correlates |
| Persistence | `SQLiteWorkflowRuntimePersistenceStore` (`session_json` snapshot) + `workflow_messages` table (`SQLiteWorkflowMessageLog`) under `.riela/sessions/runtime-message-log.sqlite` | `WorkflowViewerLoader` already opens the runtime store; it must additionally load messages |

The viewer layer (`Sources/RielaViewer/WorkflowViewer.swift`) already exposes `WorkflowViewerTimelineEntry` (`stepId`, `nodeId`, `attempt`, `status`, `startedAt`, `endedAt`, `duration`, `failureReason`) built from `WorkflowSession.executions`. It lacks the `executionId`, backend events, and any message data — those are the data-layer gaps this design closes.

## Proposed Design

### 1. Viewer data layer (RielaViewer)

Extend the loader output so the app never touches SQLite directly:

- `WorkflowViewerTimelineEntry` gains `executionId: String`, `backendEvents: [WorkflowViewerBackendEvent]`, `backendEventTotalCount: Int?`, and `backend` stays as-is. `WorkflowViewerBackendEvent` mirrors `WorkflowBackendEventRecord` (`sequence`, `at`, `eventType`, `channel`, `content`, `toolName`).
- New `WorkflowViewerMessage` value type mirroring `WorkflowMessageRecord`: `communicationId`, `fromStepId`, `toStepId`, `sourceStepExecutionId`, `payloadJSON` (pretty-printed string), `artifactRefs`, `lifecycleStatus`, `deliveryKind`, `createdOrder`, `createdAt`.
- `WorkflowViewerState` gains `messages: [WorkflowViewerMessage]` for the selected session, loaded from the runtime persistence snapshot (`WorkflowRuntimePersistenceSnapshot.workflowMessages`) or the `workflow_messages` table when only SQLite is present.
- Loading messages must not fail the whole viewer load: message-load errors append to `diagnostics` and produce an empty `messages` array.

### 2. Timeline geometry model (pure, testable)

A new pure-Swift layout type in RielaViewer (so it is testable without AppKit):

```
struct WorkflowExecutionTimelineLayout {
    struct Row { let stepId: String; let nodeId: String; let index: Int }
    struct Bar { let entryId: String; let rowIndex: Int; let startFraction: Double; let endFraction: Double; let status: ... ; let attempt: Int }
    struct Connector { let fromEntryId: String; let toEntryId: String }
    let rows: [Row]
    let bars: [Bar]
    let connectors: [Connector]
    let timeOrigin: Date
    let timeSpan: TimeInterval   // clamped to >= 1s to avoid zero-width scales
    let axisTicks: [(fraction: Double, label: String)]
}
```

Rules:

- Rows are unique `stepId`s ordered by first execution start time (stable; ties broken by step declaration order in the workflow when available).
- Bars are normalized to `[0, 1]` fractions of `[timeOrigin, timeOrigin + timeSpan]`; running executions use `now` (injected as a parameter, never `Date()` inside layout code) as their end.
- Sub-second executions get a minimum visual width at render time (layout keeps true fractions; the view enforces a minimum pixel width, e.g. 3 pt).
- Connectors: for each outbox message with a `toStepId`, connect the producing execution's bar to the earliest execution of the target step whose `createdAt >= message.createdAt` (tolerance for clock equality). If no message data exists, fall back to linking consecutive executions in `createdAt` order.
- Axis ticks: 4–8 "nice" ticks (s / min / h units) computed from the span.

### 3. Timeline pane (AppKit)

New `WorkflowExecutionTimelinePaneView` in `Sources/RielaApp/`, following the `DaemonWorkflowGraphPaneView` pattern:

- Container view with zoom controls (+ / − / fit, horizontal zoom only) and an `NSScrollView` hosting a canvas `NSView` that draws with `NSBezierPath`/`NSAttributedString`, consistent with `DaemonWorkflowGraphCanvasView`.
- Fixed left gutter (~180 pt) listing step rows (`stepId`, secondary line `nodeId`); gutter stays pinned while the chart scrolls horizontally.
- Time axis header row with tick labels; light vertical grid lines at ticks (same grid styling as the graph canvas).
- Bars: rounded rects, status colors — running: `systemBlue`, completed: `systemGreen`, failed: `systemRed`, skipped: `systemGray` — with `attempt` badge ("×2") when attempt > 1, and a duration label inside/right of the bar when space allows.
- Connectors: thin quadratic bezier from bar end to target bar start with a small arrowhead, matching graph-pane edge styling but lighter alpha.
- Hit-testing on `mouseDown` selects a bar and opens the execution popup; hover shows a tooltip (`stepId · status · duration`). Keyboard: arrow keys move selection between bars, Return opens the popup (matches the app's accessibility conventions).
- The view renders from an immutable `WorkflowExecutionTimelineLayout` + entry/message lookup tables; no data loading inside the view.

### 4. Execution detail popup

`NSPopover` (`behavior = .transient`, resizable content ~480×420) anchored to the clicked bar, mirroring the graph pane's `showPopover(for:relativeTo:)` pattern:

- **Header (always visible):** step ID, node ID, status with color dot, attempt, backend, `startedAt → endedAt` (localized), duration, and `failureReason` (red, wrapped) when present.
- **Segmented control with three tabs:**
  - **Log** — table of `backendEvents`: time (HH:mm:ss.SSS), event type, channel, tool name, and content (monospaced, truncated with expand-on-select). When `backendEventTotalCount > backendEvents.count`, show a footer: "Showing most recent N of M events — run `riela session export <sessionId>` for the full log."
  - **Inbox** — messages with `toStepId == stepId`, ordered by `createdOrder`: from-step, lifecycle status, created time, and pretty-printed payload JSON in an expandable monospaced text area. Messages consumed by *this* execution cannot be distinguished today (no consuming-execution link in `WorkflowMessageRecord`), so the tab shows all inbox messages for the step and highlights those created before this execution started.
  - **Outbox** — messages with `sourceStepExecutionId == executionId`: to-step (or "root output" for `deliveryKind == root-output`), transition condition, created time, payload JSON.
- Empty tabs show a quiet placeholder ("No backend events recorded", "Inbox is empty", ...).
- A "Copy JSON" button per message copies the raw payload to the pasteboard.

### 5. Viewer window integration

- `WorkflowViewerWindowController` gains a view-mode segmented control: **Outline** (existing tree + text) and **Timeline** (new pane). The existing session selector popup drives both; changing sessions rebuilds the layout.
- While the selected session status is `running`, the controller reloads via `WorkflowViewerLoader` on a 2 s timer (paused when the window is not visible or the pane is not the Timeline). Reload preserves selection and horizontal zoom/scroll position; the time span grows to the right.
- Load diagnostics (e.g. message-log unavailable) surface in the existing diagnostics area, not as modal alerts.

### 6. Instance entry point

- The instance detail pane (`DaemonWorkflowWindowController+DetailView.swift`) gains a **"View Execution Log"** action row next to "Open in Viewer". It opens the Workflow Viewer for the instance's workflow directory/session store with the Timeline pane pre-selected and the most recent session for that workflow selected (via existing `WorkflowViewerLoader` session-candidate resolution).
- Instances with state `needsSource` or with no sessions show the viewer's existing empty state plus a timeline-specific message: "No executions recorded yet for this instance."

## Empty States

- No session selected / session has zero executions → centered placeholder text in the pane ("No node executions recorded").
- Session store missing → existing viewer diagnostics; Timeline pane shows placeholder.
- Messages unavailable (legacy JSON-only session, SQLite open failure) → timeline still renders bars from executions; popup Inbox/Outbox tabs show "Message log unavailable for this session" and connectors fall back to execution order.

## Risk Review Questions

- `updatedAt` as end time: any runtime path that touches an execution after completion (e.g. late backend event flush) would stretch bars. If observed, prefer `lastBackendEventAt` capping for completed executions.
- Large sessions (hundreds of executions, loop workflows): drawing must stay O(visible); use row virtualization only if profiling shows need — first slice renders all bars but must be validated against a loop-heavy session (e.g. loop-engineering workflows) before acceptance.
- Long-running sessions (hours): time-axis zoom must make second-scale nodes findable; "fit" zoom plus max zoom-in to ~1 px = 100 ms is the target range.
- Clock skew is not a concern (single host, single writer), but identical timestamps for instant steps are; minimum-width rendering covers it.
- `recentBackendEvents` truncation: acceptable for the popup, but the "N of M" footer and CLI hint are required so operators are never silently shown a partial log.

## Acceptance Criteria

- [ ] Workflow Viewer window offers Outline and Timeline view modes; Timeline renders step rows (Y), time axis (X), and one bar per `WorkflowStepExecution` of the selected session.
- [ ] Bar geometry: start = `createdAt`, end = `updatedAt` (or now for running), minimum visible width for instant executions, status colors for running/completed/failed/skipped, attempt badge for retries.
- [ ] Left step gutter stays pinned during horizontal scroll; time axis shows readable tick labels for spans from seconds to hours; zoom in/out/fit works.
- [ ] Transition connectors are drawn from producing bars to consuming bars using workflow message routing, with execution-order fallback when messages are absent.
- [ ] Clicking a bar (or pressing Return on a keyboard-selected bar) opens a popover with header (status, backend, times, duration, failure reason) and Log / Inbox / Outbox tabs.
- [ ] Log tab lists backend events with timestamps and content and shows the "recent N of M" footer when the event stream is truncated.
- [ ] Inbox tab lists messages addressed to the step (payload JSON, from-step, lifecycle status); Outbox tab lists messages published by that exact execution (`sourceStepExecutionId` match).
- [ ] `WorkflowViewerState` exposes messages and per-entry `executionId`/backend events; RielaApp performs no direct SQLite access for the timeline.
- [ ] Message-load failure degrades gracefully: bars still render, diagnostics note the failure, Inbox/Outbox tabs show an unavailable notice.
- [ ] Running sessions refresh automatically (~2 s) without losing bar selection or zoom; refresh stops when the session completes or the window closes.
- [ ] Instance detail pane has a "View Execution Log" action that opens the viewer on the Timeline pane with the instance's latest session selected.
- [ ] Sessions with zero executions and instances without a session store show the specified empty states instead of a blank canvas.
- [ ] Layout logic (`WorkflowExecutionTimelineLayout`) is covered by unit tests in `RielaViewerTests`: row ordering, fraction math, running-execution end handling, minimum span clamping, connector derivation with and without message data, tick generation.
- [ ] Loader message enrichment is covered by tests: messages loaded from a snapshot fixture, diagnostics on missing store, executionId propagation into timeline entries.
- [ ] VoiceOver: bars expose accessibility labels ("<stepId>, <status>, started <time>, duration <d>"); popup controls are keyboard-navigable.
