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
- Active/completed/failed/idle node status derivation.
- Per-node inbox/outbox message classification.
- Menu bar app `Open Viewer` action.
- AppKit viewer window with outline tree, session selector, status/overview,
  refresh, and detail pane.
- Unit tests for tree/runtime state, inbox/outbox, and explicit session
  selection.

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
