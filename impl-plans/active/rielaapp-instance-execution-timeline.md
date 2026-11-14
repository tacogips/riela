# RielaApp Instance Execution Timeline — Implementation Plan

**Status**: Implemented (visual verification deferred to interactive RielaApp session)
**Design Reference**: `design-docs/specs/design-rielaapp-instance-execution-timeline.md`
**Created**: 2026-07-06
**Last Updated**: 2026-07-12

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

**Status**: DONE — `WorkflowViewerTimelineEntry` carries `executionId`/`backendEvents`/`backendEventTotalCount`; `WorkflowViewerState.messages` + `messageLogAvailable` populated by `WorkflowViewerLoader.load` from the runtime snapshot; message-load rides the same store as the snapshot (graceful — empty messages on a loaded session, `showUnavailable` on load failure). Tested by `WorkflowViewerTests` (`testViewerLoadsWorkflowTreeRunningStateAndNodeMessages`, `testViewerLoadsSessionWithoutMessagesKeepsMessageLogAvailable`).

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

**Status**: DONE — `WorkflowExecutionTimelineLayout` (rows ordered by first start with declaration-order tiebreak, `[0,1]` bar fractions, injected `now` for running, span clamped ≥ 1 s, message-routed connectors with execution-order fallback, nice s/min/h axis ticks). Tested by `WorkflowExecutionTimelineLayoutTests` (6 tests, all passing).

**Write Scope**:

- New: `Sources/RielaViewer/WorkflowExecutionTimelineLayout.swift`
- New: `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`

**Deliverables**:

- `WorkflowExecutionTimelineLayout` per design §2: rows (unique stepIds ordered by first start), bars with `[0,1]` fractions, `now` injected for running executions, span clamped ≥ 1 s, connectors from message routing with execution-order fallback, 4–8 nice axis ticks (s/min/h).

**Depends On**: Module 1 (entry `executionId` for connector correlation)

**Verification**:

- `swift test --filter WorkflowExecutionTimelineLayoutTests` — row ordering, fraction math, running-end handling, min-span clamp, connectors with/without messages, tick generation.

### 3. Timeline Pane View (RielaApp, AppKit)

**Status**: IMPLEMENTED (visual verification deferred) — `WorkflowExecutionTimelinePaneView` with pinned `WorkflowExecutionTimelineGutterView`, scrollable `WorkflowExecutionTimelineCanvasView` (status-colored bars, min bar width, attempt/duration labels, axis grid), zoom in/out/fit, mouse + keyboard (arrows/Return) selection, and per-bar `NSAccessibilityElement` labels. Compiles (`swift build --target RielaApp`). Pixel-level rendering DEFERRED (accepted): interactive RielaApp session; owner: next interactive session; trigger: rielaapp-ui-verification workflow.

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

**Status**: IMPLEMENTED (visual verification deferred) — `WorkflowExecutionDetailPopover.make` + `DetailView` (transient NSPopover, header with status dot/node/attempt/backend/times/duration/failureReason, segmented Log/Inbox/Outbox). Log tab shows "recent N of M" footer + `riela session export` hint; Inbox filters `toStepId`, Outbox filters `sourceStepExecutionId`; Inbox/Outbox show "Message log unavailable for this session." when `messageLogAvailable` is false; empty-state placeholders per tab. Compiles. Visual/interaction confirmation DEFERRED (accepted): interactive RielaApp session; owner: next interactive session; trigger: rielaapp-ui-verification workflow.

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

**Status**: IMPLEMENTED (visual verification deferred) — `viewerModeControl` (Outline/Timeline) + `viewerModeChanged`/`selectTimelineMode`; `updateTimelinePane`; 2 s `startLiveRefreshTimer` gated on `selectedSession.status == .running` (stops on completion via `updateLiveRefreshTimer` and on `windowWillClose`); `refresh()` preserves `selectedSessionId`, canvas preserves selection + zoom; loader diagnostics flow to the existing diagnostics area. Compiles. NOTE (accepted deviation): the refresh timer gates on session status, not on which pane is visible — it reloads both Outline and Timeline panes, which is harmless. Live-extension visual confirmation DEFERRED (accepted): interactive RielaApp session; owner: next interactive session; trigger: rielaapp-ui-verification workflow.

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

**Status**: IMPLEMENTED (visual verification deferred) — "View Execution Log" action row in `DaemonWorkflowWindowController+DetailView.swift` opens the viewer with `openTimeline: true` (Timeline pane pre-selected) and the latest session resolved through `WorkflowViewerLoader`. Empty-state message ("No executions recorded yet for this instance.") handled in the pane's `update`. Compiles. Visual/navigation confirmation DEFERRED (accepted): interactive RielaApp session; owner: next interactive session; trigger: rielaapp-ui-verification workflow.

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
| 1. Viewer data enrichment | `Sources/RielaViewer/WorkflowViewer.swift`, `Sources/RielaViewer/WorkflowViewerTimelineModels.swift` | DONE | RielaViewerTests (loader/messages) |
| 2. Timeline layout model | `Sources/RielaViewer/WorkflowExecutionTimelineLayout.swift` | DONE | WorkflowExecutionTimelineLayoutTests (6 passing) |
| 3. Timeline pane view | `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` | IMPLEMENTED (visual deferred) | compile + logic; visual DEFERRED |
| 4. Detail popover | `Sources/RielaApp/WorkflowExecutionDetailPopover.swift` | IMPLEMENTED (visual deferred) | compile + logic; visual DEFERRED |
| 5. Viewer integration | `Sources/RielaApp/WorkflowViewerWindowController*.swift` | IMPLEMENTED (visual deferred) | compile + logic; visual DEFERRED |
| 6. Instance entry point | `Sources/RielaApp/DaemonWorkflowWindowController+DetailView.swift` | IMPLEMENTED (visual deferred) | compile + logic; visual DEFERRED |

## Dependencies

| Feature | Depends On | Status |
| ------- | ---------- | ------ |
| Layout model (2) | Data enrichment (1) | done |
| Pane view (3) | Layout model (2) | done |
| Popover (4) | Data enrichment (1), Pane view (3) | done |
| Viewer integration (5) | Pane view (3), Popover (4) | done |
| Instance entry point (6) | Viewer integration (5) | done |

Modules 1–2 are library-only and can land independently of app UI work.

## Completion Criteria

- [x] All acceptance criteria in `design-rielaapp-instance-execution-timeline.md` checked off (with per-criterion evidence; UI-visual portions annotated DEFERRED to an interactive session).
- [x] `swift build` (per-target: `RielaViewer`, `RielaApp`) and `swift test --filter RielaViewerTests` pass — RielaViewerTests: 16 tests, 0 failures (2026-07-12). NOTE: whole-package `swift build`/`swift test` is intermittently blocked by concurrent in-progress CLI work in `Sources/RielaCLI/*` (unrelated to this feature); the RielaViewer + RielaApp targets and RielaViewerTests build and pass in isolation. Re-run full `swift test` once the CLI work lands.
- [ ] Manual verification on: (a) completed multi-node session, (b) live running session, (c) loop-heavy session (performance), (d) legacy session without message log (degradation), (e) never-run instance (empty state). DEFERRED (accepted): visual verification requires an interactive RielaApp session; owner: next interactive session; trigger: RielaApp launched with the rielaapp-ui-verification workflow. Degradation (d) and empty-state (e) logic is unit-tested at the loader/pane layer.
- [x] No direct SQLite access from RielaApp for timeline data (all through `WorkflowViewerLoader`). Verified: timeline data flows through `WorkflowViewerState`; the only `SQLiteWorkflowRuntimePersistenceStore` use in RielaApp is the pre-existing manager-message write in `EntryPoint+Viewer.swift`.
- [ ] `impl-plans/README.md` Active Plans row kept up to date; plan moved to `completed/` when done. (Plan remains in `active/` pending the deferred interactive visual verification; README row updated to reflect Implemented status.)

## Progress Log

### Session: 2026-07-12

- Tasks Completed: Verified all six modules are implemented + compiling (`swift build --target RielaViewer`/`RielaApp`). Closed two real gaps against the design: (1) message-log-unavailable degradation — added `WorkflowViewerState.messageLogAvailable`, threaded it through the pane/canvas/popover so Inbox/Outbox show "Message log unavailable for this session." on the `showUnavailable` path; (2) per-bar VoiceOver — added `refreshAccessibilityChildren()` building one labeled `NSAccessibilityElement` per bar (`"<stepId>, <status>, started <time>, duration <d>"`). Added `testViewerLoadsSessionWithoutMessagesKeepsMessageLogAvailable` and a `messageLogAvailable` assertion to the existing loader test. RielaViewerTests: 16 tests, 0 failures. `swiftlint --strict` clean on all touched files. Checked all 15 design acceptance criteria and 6 module statuses with evidence.
- Tasks In Progress: —
- Blockers: Whole-package `swift test` intermittently blocked by concurrent in-progress `Sources/RielaCLI/*` compile errors (W5 package tooling, another engineer); RielaViewer/RielaApp targets + RielaViewerTests build/pass in isolation.
- Notes: Message data rides the same runtime-records SQLite store as the session snapshot, so an independent "message log unavailable" state cannot arise separately from a whole-session load failure — the degradation notice is wired to `showUnavailable`, and a loaded session with zero messages is a true empty state (not "unavailable"). Interactive UI-visual verification (bar/connector rendering, zoom, live refresh, popover interaction, VoiceOver audio) deferred to a RielaApp session with the rielaapp-ui-verification workflow.

### Session: 2026-07-06 23:59

- Tasks Completed: Design doc + implementation plan authored from verified codebase exploration (runtime record types, viewer loader shape, AppKit patterns).
- Tasks In Progress: —
- Blockers: —
- Notes: `WorkflowStepExecution.updatedAt` is the end-time proxy; watch the design risk item about late post-completion updates stretching bars.

## Related Plans

- Previous: `active/macos-workflow-viewer.md` (viewer foundation this builds on)
- Related: `active/workflow-progress-observability.md` (CLI/exporter-side observability)
