# Work Runtime P1: Canonical authoring ownership

**Status**: Step 4 revised; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `issueCommunicationId:comm-000002`, `intakeExecutionId:step1-issue-intake-attempt-1-exec-2`, `communicationId:comm-000004`, `designStepId:step2-design-doc-update`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Updated**: 2026-09-22

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
    "git diff --check",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-sandbox/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run --scratch-path tmp/work-runtime-p1/build/p1-sandbox riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json"
  ],
  "dependencyMode": "native-accepted-predecessor-DAG",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-sandbox/"
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intent, context, non-goals and invariants

User intent is to let implementation/documentation nodes perform accepted
writes while review/intake stays read-only. The checkpoint already contains
the Step 6/8 correction and real-payload regression. Fresh behavioral evidence,
not a new edit for its own sake, determines whether repair is needed. This is
P1-0 of the six-plan DAG, independent of reservation. Do not modify installed
packages, prompts, review access, workflow engine or unrelated nodes.

| Exact file | Smallest intended change / acceptance |
| --- | --- |
| `.riela/workflows/codex-design-and-implement-review-loop/nodes/node-step6-implement.json` | Retain/repair only workspace-write for accepted implementation. |
| `.riela/workflows/codex-design-and-implement-review-loop/nodes/node-step8-docs-refresh.json` | Retain/repair only workspace-write for documentation refresh. |
| `Tests/RielaCLITests/ImplementationWorkflowSandboxTests.swift` | Read actual payloads; assert the two write grants, surrounding read-only nodes and unchanged accepted-plan/review prompt boundaries. |
| `impl-plans/progress/p1-sandbox.md` | Append this session's hashes, tests and acceptance; retain historical entries. |

Invariant: validating this canonical artifact never executes it or substitutes
it for the immutable user-scope runtime. Independent acceptance transfers the
canonical payload hashes/test evidence to p1-dispatch; node execution access
is separately proven by the runtime's actual granted scope.

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

## Evidence-producing command contract

Run each metadata verificationCommands entry in the foreground from repository
root, one command per immutable log under the evidenceDirectory above; retain
handles and poll through exit. Build establishes compile/typecheck. Focused
filters must exercise every named suite with positive executed counts and the
acceptance cases in this plan; missing/zero-test suites, timeout or incomplete
logs block acceptance. Diff checks establish patch hygiene, not behavior.
Strict lint uses the NUL manifest of surviving touched AND new Swift files from
intent/change evidence. Capture repository lint before edits and after the final
plan tree; compare diagnostics and fail new attributable issues while recording
unrelated baseline findings. Do not run xargs on an empty manifest; record why
no Swift file changed. Finalization lints the union of all accepted write sets.

Record exact command, start/end, finalExitStatus, completeLogPath, per-suite
testCount (null for non-tests), source hashes and review decision in
`verification-evidence.json` in this plan's evidenceDirectory and its progressLog.
Use numbered attempt subdirectories for reruns; retain logs through handoff.
All common per-edit fresh-read/pre/post SHA-256, immutable intent, drift-stop,
join/changeTracking and serial repair rules in the dispatcher contract apply.
Only this plan's implementation owner appends to its progressLog; it may not
mark another plan or shared index complete. Documentation refresh and final
checkbox/index reconciliation belong to p1-finalize after independent acceptance.

The retained `ImplementationWorkflowSandboxTests.swift` modification belongs
to this root. Record its fresh hash and executed cases rather than relying on
checkpoint logs. A correct unchanged artifact still needs current behavioral
evidence and independent acceptance; report any runtime admission blocker.
