# Installed Package Workflow Resolution Implementation Plan

**Status**: Implemented
**Design Reference**: `design-docs/specs/design-installed-package-workflow-resolution.md`
**Feature ID**: `installed-package-workflow-resolution`
**Review Mode**: adversarial, high risk
**Created**: 2026-06-19

## Summary

Make installed workflow packages first-class local workflow sources for
ordinary `riela workflow` commands while preserving package provenance and
discouraging direct edits to package-owned contents.

## Tasks

### TASK-001: Resolver Package Fallback

**Status**: DONE
**Files**:

- `Sources/RielaCLI/WorkflowResolution.swift`

**Work**:

- Keep direct and `.riela/workflows` precedence.
- Add `.riela/packages` package candidate resolution for safe package names.
- Validate package manifests and package-relative workflow directories.
- Attach package manifest and package directory to `ResolvedWorkflowBundle`.

### TASK-002: Provenance DTOs

**Status**: DONE
**Files**:

- `Sources/RielaCLI/WorkflowCommands.swift`

**Work**:

- Add typed `WorkflowSourceKind` enum.
- Include `sourceKind`, package identity, package directory, and `mutable` in
  list, validate, and inspect outputs.
- Render `SOURCE` in text/table workflow catalog output.

### TASK-003: Parser Safety

**Status**: DONE
**Files**:

- `Sources/RielaCLI/RielaCommand.swift`

**Work**:

- Permit safe package names, including scoped package names, as local workflow
  targets.
- Keep unsafe path-like targets rejected.

### TASK-004: Tests And Review

**Status**: DONE
**Files**:

- `Tests/RielaCLITests/WorkflowCommandTests.swift`

**Work**:

- Add package-derived normal workflow list/validate/inspect/run coverage.
- Add scoped package local workflow coverage.
- Update dry-run test to assert no new runtime records rather than no
  pre-existing runtime record root.
- Run targeted and full relevant Swift tests.
- Verify real CLI behavior against installed `~/.riela/packages`.
- Document installed package workflow behavior in the README.

## Completion Criteria

- [x] `workflow list` includes installed package workflow entries.
- [x] `workflow validate <package>` works without `--from-registry`.
- [x] `workflow inspect <package>` works without `--from-registry`.
- [x] `workflow run <package>` works without `--from-registry`.
- [x] package provenance is explicit and typed.
- [x] targeted CLI tests pass.
- [x] real installed package CLI smoke checks pass.
- [x] full relevant Swift CLI tests pass.
- [x] lint passes.
- [x] flake checks pass.
- [x] user-facing review finds no confusing command behavior.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter WorkflowCommandTests/testScopedWorkflowNamesRejectTraversalAndSlashTargets`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter RielaCLITests`
- `nix develop -c zsh -lc 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk; export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH; swiftlint lint --strict'`
- `nix flake check`
- `.build/debug/riela workflow list --scope user --output json`
- `.build/debug/riela workflow validate codex-goal --scope user --output json`
- `.build/debug/riela workflow inspect codex-goal --scope user --output json`
- `.build/debug/riela workflow status codex-goal --scope user --output json`

`swift test` across the whole suite was also run. It completed with only the
known deletion-readiness reviewed-tree evidence gate failing because the current
working tree digest differs from `packaging/swift-deletion-readiness-evidence.json`.
The relevant CLI/package workflow coverage passed.
