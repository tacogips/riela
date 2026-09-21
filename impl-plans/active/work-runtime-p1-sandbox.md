# Work Runtime P1: Canonical authoring ownership

**Status**: Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.5 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted_for_step4_implementation_planning`; no findings or revision request.
**Codex-agent references**: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-21

```json
{
  "planId": "p1-sandbox",
  "planPath": "impl-plans/active/work-runtime-p1-sandbox.md",
  "dependsOn": [],
  "writePaths": [
    ".riela/workflows/codex-design-and-implement-review-loop/nodes/node-step6-implement.json",
    ".riela/workflows/codex-design-and-implement-review-loop/nodes/node-step8-docs-refresh.json",
    "Tests/RielaCLITests/ImplementationWorkflowSandboxTests.swift",
    "impl-plans/progress/p1-sandbox.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/p1-sandbox.md",
  "taskIds": [
    "P1-0"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-sandbox",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-sandbox --filter 'ImplementationWorkflowSandboxTests'",
    "git diff --check"
  ]
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intended changes and acceptance (§17.1)

- [ ] **P1-0** Fresh-read the retained sandbox changes and regression. Keep or
  repair only the canonical Step 6/Step 8 `agentSandbox: workspace-write`
  correction. Assert all surrounding intake/review nodes retain read-only
  access and prompts retain accepted-plan/review boundaries.
- Validate the canonical bundle as an artifact with the command below; never
  execute it. It is not a prerequisite for installed user-scope execution.
- Inventory any owning package manifest for these two files and hand its exact
  path to serial finalization for digest refresh. If absent, record the audit;
  do not manufacture a manifest or edit the installed package.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run --scratch-path tmp/work-runtime-p1/build/p1-sandbox riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json
```

Deliverable: the two narrowly scoped payload fixes and a regression that loads
real canonical node definitions. Existing uncommitted content is unverified
input, not an already completed checkbox. This branch is independent of the
reservation branch; no Package.swift, index, or digest writes occur here.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-sandbox
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-sandbox --filter 'ImplementationWorkflowSandboxTests'
git diff --check
```

Also run the changed-file strict SwiftLint gate defined in the root plan for
this plan's actual Swift write set, including new untracked files. Retain P0
assertions affected by these changes. Each unchecked task below requires its
specified acceptance assertions, passing build/typecheck, focused tests and
lint, complete evidence, and independent review with no unresolved high/mid
finding. Passing this plan alone does not close P1. Report blocked commands
explicitly; never substitute source-text assertions for behavioral tests.
