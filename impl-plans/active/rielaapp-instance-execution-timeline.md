# RielaApp Instance Execution Timeline — Implementation Plan

**Status**: Planning
**Design Reference**: `design-docs/specs/design-rielaapp-instance-execution-timeline.md`
**Created**: 2026-07-06
**Last Updated**: 2026-07-06

## Design Document Reference

- Source: `design-docs/specs/design-rielaapp-instance-execution-timeline.md`

### Summary

Add a Jaeger-style Gantt timeline to the RielaApp Workflow Viewer: step rows on the Y axis, wall-clock time on the X axis, one bar per `WorkflowStepExecution`, transition connectors from workflow message routing, and a per-bar NSPopover with Log / Inbox / Outbox tabs. Entry point from the instance detail pane ("View Execution Log").

### Scope

**Included**:

- RielaViewer data enrichment: `executionId` + backend events on `WorkflowViewerTimelineEntry`, new `WorkflowViewerMessage`, `WorkflowViewerState.messages`, loader message loading with graceful degradation.
- Pure layout model `WorkflowExecutionTimelineLayout` (rows, normalized bars, connectors, axis ticks) in RielaViewer with unit tests.
- AppKit pane `WorkflowExecutionTimelinePaneView` (canvas drawing, pinned step gutter, time axis, zoom, hit-testing, keyboard selection).
- Execution detail popover (header + Log / Inbox / Outbox tabs, truncation footer, copy-JSON).
- Viewer window integration (Outline/Timeline mode switch, 2 s live refresh for running sessions).
- Instance detail "View Execution Log" action.

**Excluded**:

- OTLP/Jaeger export, runtime event push streaming, called-workflow flattening, retry/replay actions from the timeline, SwiftUI migration (see design Non-Goals).

## Modules

### 1. Viewer Data Enrichment (RielaViewer)

**Status**: NOT_STARTED

**Write Scope**:

- `Sources/RielaViewer/WorkflowViewer.swift` (extend `WorkflowViewerTimelineEntry`, `WorkflowViewerState`, `WorkflowViewerLoader`)
- New: `Sources/RielaViewer/WorkflowViewerMessages.swift` (`WorkflowViewerMessage`, `WorkflowViewerBackendEvent`, mapping from `WorkflowMessageRecord` / `WorkflowBackendEventRecord`)
- `Tests/RielaViewerTests/` (new fixtures + tests)

**Deliverables**:

- `WorkflowViewerTimelineEntry` carries `executionId`, `backendEvents`, `backendEventTotalCount`.
- `WorkflowViewerState.messages: [WorkflowViewerMessage]` populated from `WorkflowRuntimePersistenceSnapshot.workflowMessages` / `workflow_messages` SQLite table for the selected session.
- Message-load failure appends a diagnostic and yields empty `messages` (never throws out of `load`).
- Payload JSON pretty-printed once at load time.

**Depends On**: —

**Verification**:

- `swift test --filter RielaViewerTests` — snapshot fixture with messages loads; missing store produces diagnostic + empty messages; `executionId` propagates.

### 2. Timeline Layout Model (RielaViewer, pure)

**Status**: NOT_STARTED

**Write Scope**:

- New: `Sources/RielaViewer/WorkflowExecutionTimelineLayout.swift`
- New: `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`

**Deliverables**:

- `WorkflowExecutionTimelineLayout` per design §2: rows (unique stepIds ordered by first start), bars with `[0,1]` fractions, `now` injected for running executions, span clamped ≥ 1 s, connectors from message routing with execution-order fallback, 4–8 nice axis ticks (s/min/h).

**Depends On**: Module 1 (entry `executionId` for connector correlation)

**Verification**:

- `swift test --filter WorkflowExecutionTimelineLayoutTests` — row ordering, fraction math, running-end handling, min-span clamp, connectors with/without messages, tick generation.

### 3. Timeline Pane View (RielaApp, AppKit)

**Status**: NOT_STARTED

**Write Scope**:

- New: `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` (container + canvas, follows `DaemonWorkflowGraphPaneView` / `DaemonWorkflowGraphCanvasView` patterns)

**Deliverables**:

- Pinned left step gutter (~180 pt), scrollable canvas, time-axis header with tick grid.
- Status-colored rounded bars (running blue / completed green / failed red / skipped gray), attempt badge, min 3 pt bar width, duration labels when space allows.
- Bezier connectors with arrowheads (lighter alpha than graph edges).
- Zoom controls (+/−/fit, horizontal), hover tooltips, mouse + keyboard (arrows/Return) bar selection, accessibility labels per bar.
- Renders solely from `WorkflowExecutionTimelineLayout` + lookup tables; no data loading.

**Depends On**: Module 2

**Verification**:

- `swift build`; manual: open viewer against a completed multi-node session, confirm rows/bars/connectors/zoom; loop-heavy session renders without visible lag (design risk item).

### 4. Execution Detail Popover

**Status**: NOT_STARTED

**Write Scope**:

- New: `Sources/RielaApp/WorkflowExecutionDetailPopover.swift` (or extension on the pane view)

**Deliverables**:

- Transient NSPopover (~480×420) per design §4: header (step, node, status dot, attempt, backend, times, duration, failureReason), segmented Log / Inbox / Outbox tabs.
- Log tab: backend event table + "recent N of M" footer with `riela session export` hint when truncated.
- Inbox tab: messages `toStepId == stepId` ordered by `createdOrder`, pre-execution ones highlighted; Outbox tab: `sourceStepExecutionId == executionId`, root-output labeling.
- Empty-state placeholders per tab; per-message "Copy JSON".

**Depends On**: Modules 1, 3

**Verification**:

- `swift build`; manual: click bars → verify log content, inbox/outbox payloads against `riela session export <id>` output for the same session; verify truncation footer on a session with > recent-event-cap backend events; verify "Message log unavailable" degradation on a legacy JSON-only session.

### 5. Viewer Window Integration + Live Refresh

**Status**: NOT_STARTED

**Write Scope**:

- `Sources/RielaApp/WorkflowViewerWindowController.swift`
- `Sources/RielaApp/WorkflowViewerWindowController+Rendering.swift` (mode switch wiring; keep text outline mode intact)

**Deliverables**:

- Outline/Timeline segmented view-mode control; session selector drives both modes.
- 2 s reload timer while selected session is `running` and Timeline pane visible; preserves selection, zoom, and scroll; stops on completion/window close.
- Loader diagnostics surfaced in existing diagnostics area.

**Depends On**: Modules 3, 4

**Verification**:

- Manual: start a real workflow run, open Timeline, watch bars extend/appear live; confirm timer stops after completion (no CPU churn); switch sessions and modes without stale state.

### 6. Instance Detail Entry Point

**Status**: NOT_STARTED

**Write Scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController+DetailView.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift` (action wiring, if needed)

**Deliverables**:

- "View Execution Log" action row on instance detail; opens Workflow Viewer with Timeline pane pre-selected and latest session for the instance's workflow selected.
- Empty-state handling for `needsSource` / no-session instances ("No executions recorded yet for this instance.").

**Depends On**: Module 5

**Verification**:

- Manual: from a running and a stopped instance, invoke the action; correct workflow + latest session shown; empty state for a never-run instance.

## Module Status

| Module | File(s) | Status | Test Coverage |
| ------ | ------- | ------ | ------------- |
| 1. Viewer data enrichment | `Sources/RielaViewer/WorkflowViewer.swift`, `Sources/RielaViewer/WorkflowViewerMessages.swift` | NOT_STARTED | RielaViewerTests (loader/messages) |
| 2. Timeline layout model | `Sources/RielaViewer/WorkflowExecutionTimelineLayout.swift` | NOT_STARTED | WorkflowExecutionTimelineLayoutTests |
| 3. Timeline pane view | `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` | NOT_STARTED | manual (AppKit) |
| 4. Detail popover | `Sources/RielaApp/WorkflowExecutionDetailPopover.swift` | NOT_STARTED | manual (AppKit) |
| 5. Viewer integration | `Sources/RielaApp/WorkflowViewerWindowController*.swift` | NOT_STARTED | manual |
| 6. Instance entry point | `Sources/RielaApp/DaemonWorkflowWindowController+DetailView.swift` | NOT_STARTED | manual |

## Dependencies

| Feature | Depends On | Status |
| ------- | ---------- | ------ |
| Layout model (2) | Data enrichment (1) | pending |
| Pane view (3) | Layout model (2) | pending |
| Popover (4) | Data enrichment (1), Pane view (3) | pending |
| Viewer integration (5) | Pane view (3), Popover (4) | pending |
| Instance entry point (6) | Viewer integration (5) | pending |

Modules 1–2 are library-only and can land independently of app UI work.

## Completion Criteria

- [ ] All acceptance criteria in `design-rielaapp-instance-execution-timeline.md` checked off.
- [ ] `swift build` and `swift test --filter RielaViewerTests` pass (plus full `swift test` before completion).
- [ ] Manual verification on: (a) completed multi-node session, (b) live running session, (c) loop-heavy session (performance), (d) legacy session without message log (degradation), (e) never-run instance (empty state).
- [ ] No direct SQLite access from RielaApp for timeline data (all through `WorkflowViewerLoader`).
- [ ] `impl-plans/README.md` Active Plans row kept up to date; plan moved to `completed/` when done.

## Progress Log

### Session: 2026-07-06 23:59

- Tasks Completed: Design doc + implementation plan authored from verified codebase exploration (runtime record types, viewer loader shape, AppKit patterns).
- Tasks In Progress: —
- Blockers: —
- Notes: `WorkflowStepExecution.updatedAt` is the end-time proxy; watch the design risk item about late post-completion updates stretching bars.

## Related Plans

- Previous: `active/macos-workflow-viewer.md` (viewer foundation this builds on)
- Related: `active/workflow-progress-observability.md` (CLI/exporter-side observability)
