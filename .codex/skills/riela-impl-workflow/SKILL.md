---
name: riela-impl-workflow
description: Use when running or documenting the codex-design-and-implement-review-loop for Riela issue-resolution work packages, including accepted design, implementation plan, implementation, review, documentation refresh, verification, and final commit handoff.
metadata:
  short-description: Riela implementation workflow contract
---

# Riela Implementation Workflow

Use this skill when a Riela task is handled through
`codex-design-and-implement-review-loop` or another implementation workflow that
expects a design, plan, implementation, review, documentation refresh, and
commit handoff.

## Workflow Contract

- Treat `workflowMode: "issue-resolution"` as one accepted work package unless
  the workflow explicitly fans out.
- Preserve issue references, communication ids, codex-agent step references,
  reviewed file paths, review decisions, findings, verification commands, and
  verification gaps in handoffs.
- Do not reopen accepted design or implementation scope during the documentation
  refresh step. Align user-facing docs with the accepted behavior, review
  decision, and verification evidence.
- Refresh repository-facing documentation before commit generation. Review
  `README.md` and this skill, and update any directly affected user-facing
  workflow skill or README section.
- Keep final workflow responses machine-readable when requested by the runtime.

## Riela Note Workspace Behavior

Accepted Riela Note workspace hardening on
`feat/riela-note-workspace-revamp` ships these user-facing contracts:

- Agent send buttons do not register a bare Return shortcut. Plain Return in
  note body, comment, tag, rewrite, search, or link text inputs must not send an
  agent message; focused agent composer submit remains the plain-Enter send
  path.
- Search-popup result selection during an unsaved body edit must yield to the
  root pending-selection confirmation. Discard navigates to the chosen note;
  Keep Editing preserves the draft.
- The regular-width left pane has Tree and Notes modes. Tree mode invalidates
  lazily loaded notebook children on refresh or note-store change and supports
  paginated load-more for large notebooks. Notes mode uses the shared detail
  pager order, highlights the current note, shows row position, and routes row
  selection through the unsaved-edit guard.
- Left pane expansion, right pane expansion, selected Tree/Notes mode, and
  bottom-agent folded state persist across app relaunches.
- Changed note-workspace panels use semantic SwiftUI color roles so custom agent
  panels, attachment chips, pane backgrounds, and selected rows remain legible
  in dark and light appearances.

## Verification Evidence

For this work package, accepted verification included:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppNotesIntegrationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet
```

Manual GUI verification should record Return routing, search-popup confirmation
reachability, relaunch persistence, and dark/light rendering for the changed
workspace surfaces.
