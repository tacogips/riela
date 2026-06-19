# macOS Workflow Viewer Implementation Plan

**Status**: Implemented
**Design Reference**: `design-docs/specs/design-macos-workflow-viewer.md`
**Feature ID**: `macos-workflow-viewer`
**Branch**: `feature/macos-workflow-viewer`

## Scope

Implemented:

- `RielaViewer` library product and target.
- Workflow tree view state built from `workflow.json` transitions.
- Persisted runtime/session discovery for selected workflow sessions.
- Ancestor session-store discovery when the viewer is opened from nested
  workflow directories.
- Active/completed/failed/idle node status derivation.
- Per-node inbox/outbox message classification.
- Menu bar app `Open Viewer` action.
- AppKit viewer window with outline tree, session selector, status/overview,
  refresh, and detail pane.
- UI hardening for dark-mode detail text, stable split-view width, clearer
  status labels, empty-session diagnostics, and refresh session preservation.
- Unit tests for tree/runtime state, inbox/outbox, explicit session selection,
  implicit ancestor session discovery, unreadable implicit store fallback, empty
  session diagnostics, and legacy `WorkflowViewerState` decoding.

Deferred:

- Remote GraphQL viewer transport.
- Live streaming updates without manual refresh.
- Workflow graph editing or mutation.
- Multi-workflow dashboard beyond the selected workflow.

## Verification

- `swift test --filter RielaViewerTests`
- `swift build --product RielaMenuBarApp`
- `swift test --filter RielaServerTests`
- `nix flake check`

## Review Notes

The first pass keeps AppKit code as a renderer over `RielaViewer` instead of
parsing runtime files in the UI. This keeps the user-facing viewer behavior
testable and protects the menu bar client from duplicating runtime/session
contracts.

Adversarial UI review found and fixed three blocking usability issues: the
detail pane could render unreadably in dark mode, long session titles could
collapse the workflow tree, and nested example workflows could miss project
root sessions. The loader now reports searched session stores when no matching
session exists and skips unreadable implicit candidates while continuing to
search ancestors.
