# Three-axis Issue-resolution Review Implementation Plan

**Status**: Implemented
**Design Reference**: `design-docs/specs/design-core-and-addons-review-improvements.md#three-axis-issue-resolution-review-slice-2026-07-07`
**Workflow Mode**: issue-resolution
**Issue Reference**: `tacogips/riela`, baseline `main@ef4dc27`, no issue number or URL
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source**: `design-docs/specs/design-core-and-addons-review-improvements.md:1538`
**User-QA**: `design-docs/user-qa/three-axis-issue-resolution-review.md:1`

### Summary

Run the accepted single-feature review slice across specification consistency,
implementation quality, and UI/CLI behavior. The implementation step must first
produce evidence-backed triage, then make only minimal fixes for confirmed
high-priority defects. The accepted design boundary requires unsupported live
runtime capabilities to fail closed before side effects and to surface through
the same capability-gap diagnostics in live runs, `workflow validate`, and
`workflow inspect`.

### Scope

**Included**:
- Specification consistency review of `README.md`, `design-docs/`, published
  package/workflow claims, and Swift behavior in `Sources/*`.
- Runtime capability diagnostics for fanout, cross-workflow dispatch, and
  resume-step shapes, including `workflow validate` and `workflow inspect`
  surfaces when gaps are confirmed.
- Evidence-backed implementation-quality review of RielaCore runtime/session
  stores, RielaCLI output behavior, agent adapters, RielaAdapters,
  RielaSQLite/RielaNoteLibSQL persistence, RielaGraphQL, RielaNote, and
  `Packages/RielaMemory`.
- UI/CLI review of `Sources/RielaApp`, `Sources/RielaNoteUI`,
  `Sources/RielaViewer`, and `riela` CLI output for broken flows or misleading
  state.
- Minimal code, documentation, or test changes only for confirmed high-priority
  defects.
- A final findings list classifying every reviewed problem as `fixed`,
  `deferred`, or `refuted` with file-and-line evidence.

**Excluded**:
- Multi-feature fanout of this issue-resolution workflow.
- Implementing general fanout runtime support unless a confirmed defect shows a
  narrow missing guard that can be fixed safely in this slice.
- Breaking public compatibility contracts: backend ids `codex-agent`,
  `claude-code-agent`, `cursor-cli-agent`, `riela-package.json` manifest naming,
  or existing CLI JSON field names.
- Patching speculative or unverifiable defects; record them as residual risks.

## Review Decisions Accepted From Step 3

| Decision | Result | Evidence |
| --- | --- | --- |
| `no-high-or-mid-design-findings` | accepted | Step 3 payload `comm-000736` |
| `step4-ready` | accepted | `design-docs/specs/design-core-and-addons-review-improvements.md:1538`, `:1556`, `:1578`, `:1593`; `design-docs/user-qa/three-axis-issue-resolution-review.md:11` |
| `codex-agent-reference-input` | none provided | Repository-local adapter comparison only |

## Task Breakdown

### TASK-001: Establish Evidence Baseline

**Status**: COMPLETED
**Deliverables**:
- Current worktree summary before implementation.
- Reviewed source list with file-and-line references.
- Temporary repro inputs and logs under `tmp/three-axis-issue-resolution-review/`
  only, removed or left gitignored before handoff.

**Work**:
- Record `git status --short` and relevant diffs for design/user-QA files.
- Confirm existing capability behavior in `WorkflowRuntimeCapabilityGap`,
  `DeterministicWorkflowRunner`, `RuntimePublication`, and
  `WorkflowValidateInspectCommands`.
- Identify already-covered behavior in targeted tests before adding new tests.

**Completion criteria**:
- Later tasks have a stable evidence baseline.
- No scratch files exist outside repository `tmp/`.

### TASK-002: Specification Consistency And Capability Surface Triage

**Status**: COMPLETED
**Deliverables**:
- Findings entries for every reviewed spec mismatch, each marked `fixed`,
  `deferred`, or `refuted`.
- Minimal documentation updates only if claims contradict current supported
  behavior.
- Capability-diagnostic tests when `workflow validate` or `workflow inspect`
  does not surface a confirmed live-run gap.

**Work**:
- Compare `README.md`, relevant `design-docs/`, package/workflow examples, and
  Swift capability behavior.
- Verify the known cross-workflow/fanout limitation path: authored schema may
  describe `toWorkflowId` plus `resumeStepId` and fanout, while live execution
  must fail closed unless a callee resolver is wired.
- Check whether mock-only cross-workflow behavior is labeled clearly and cannot
  be mistaken for production live-run support.
- If confirmed, make additive CLI JSON/text changes so `workflow inspect`
  exposes capability-gap diagnostics without removing existing fields.

**Completion criteria**:
- Unsupported live capability claims are either corrected in docs or surfaced
  consistently by runtime, validate, and inspect.
- Existing CLI JSON field names remain compatible.

### TASK-003: Runtime And Persistence Implementation-quality Triage

**Status**: COMPLETED
**Deliverables**:
- Findings entries for reviewed runtime/persistence issues with evidence.
- Focused fixes and tests for confirmed high-priority defects only.

**Work**:
- Review workflow engine state transitions, resume/rerun/replay paths,
  publication error handling, and session/runtime-store persistence.
- Review RielaSQLite, RielaNoteLibSQL, RielaGraphQL, RielaNote, and
  `Packages/RielaMemory` for swallowed errors, data-loss paths, unsafe
  assumptions, and public contract mismatches.
- Reproduce candidates with deterministic unit tests before applying code fixes.

**Completion criteria**:
- Any high-priority correctness defect that can silently lose results, misroute
  execution, corrupt state, or hide errors has a minimal fix and targeted test.
- Lower-priority or unproven candidates are documented as deferred or residual
  risk.

### TASK-004: Agent Adapter And CLI Contract Triage

**Status**: COMPLETED
**Deliverables**:
- Findings entries for adapter and CLI-output issues with evidence.
- Focused compatibility tests for changed adapter or CLI behavior.

**Work**:
- Review ClaudeCodeAgent, CodexAgent, CursorCLIAgent, RielaAdapters, and
  RielaCLI output surfaces for swallowed errors, unsafe decoding, misleading
  status, and spec mismatches.
- Preserve backend ids `codex-agent`, `claude-code-agent`, and
  `cursor-cli-agent`.
- Keep CLI JSON output additive-only for compatibility.

**Completion criteria**:
- Confirmed adapter/CLI high-priority defects have focused fixes and tests.
- No public backend id or JSON-field compatibility break is introduced.

### TASK-005: UI State And Output Triage

**Status**: COMPLETED
**Deliverables**:
- Findings entries for reviewed UI problems with evidence.
- Minimal UI fixes only for confirmed misleading or broken flows.
- Screenshots or deterministic UI tests when a UI fix is made.

**Work**:
- Review `Sources/RielaApp`, `Sources/RielaNoteUI`, and `Sources/RielaViewer`
  for stale state, misleading capability display, and broken transitions.
- Check whether workflow graph/inspection UI hides cross-workflow or fanout
  state in a way that contradicts CLI/runtime diagnostics.

**Completion criteria**:
- Confirmed UI defects are fixed or classified with evidence.
- Visual or AppKit verification is recorded for any UI change.

### TASK-006: Verification, Findings Ledger, And Handoff

**Status**: COMPLETED
**Deliverables**:
- Final findings ledger in the implementation/review handoff.
- Updated progress log in this plan after each implementation slice.
- Verification command log with pass/fail results and residual risks.

**Work**:
- Run `swift build` after fixes.
- Run targeted `swift test --filter <ChangedModuleTests>` for each changed
  module.
- Attempt full `swift test` when feasible and report if omitted or interrupted.
- Run representative `riela workflow validate` and `riela workflow inspect`
  commands for workflow-schema or capability-diagnostic changes.

**Completion criteria**:
- Every reviewed problem is classified as `fixed`, `deferred`, or `refuted`
  with file-and-line evidence.
- All confirmed high-priority defects are fixed with focused diffs and verified.
- The handoff lists commands run, changed files, residual risks, and any tests
  not run.

## Dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-002 | TASK-001 | Spec/capability review needs baseline source evidence. |
| TASK-003 | TASK-001 | Runtime/persistence fixes need reproducible evidence first. |
| TASK-004 | TASK-001 | Adapter/CLI contract review must preserve baseline compatibility. |
| TASK-005 | TASK-001 | UI findings need current source and output-state evidence. |
| TASK-006 | TASK-002, TASK-003, TASK-004, TASK-005 | Final verification and findings ledger depend on all review slices. |

TASK-002 through TASK-005 are conceptually sequential for this single-feature
issue-resolution workflow. Implementation subwork may be parallelized only when
the later implementation step assigns disjoint write scopes and preserves a
single findings ledger.

## Parallelizable Tasks

| Task group | Parallelizable | Conditions |
| --- | --- | --- |
| TASK-002 spec/capability and TASK-003 runtime/persistence | conditional | Read-only triage may run in parallel; writes are not parallel unless files are disjoint. |
| TASK-003 runtime/persistence and TASK-004 adapters/CLI | conditional | Tests and fixes may parallelize only when changed modules and files do not overlap. |
| TASK-005 UI | conditional | UI fixes may proceed separately from core fixes if no shared CLI/model files are changed. |
| TASK-006 verification | no | Must run after changed modules are known. |

## Verification Plan

- `git status --short`
- `git diff --check`
- `swift build`
- `swift test --filter WorkflowRunnerCapabilityPreflightTests` when capability
  preflight behavior changes.
- `swift test --filter WorkflowCommandInspectionTests` when validate/inspect
  CLI output changes.
- `swift test --filter RuntimePublicationTests` when publication routing or
  unsupported-transition behavior changes.
- `swift test --filter <ChangedModuleTests>` for every changed module.
- `swift test` when feasible.
- Representative `riela workflow validate <workflow> --output json` and
  `riela workflow inspect <workflow> --output json` commands for workflows with
  fanout or cross-workflow dispatch when diagnostic surfaces change.
- UI/AppKit screenshot or layout verification for any RielaApp, RielaNoteUI, or
  RielaViewer change.

## Progress Log Expectations

- Add a dated session entry after each implementation slice.
- Record tasks completed, files changed, findings classified, tests added,
  verification commands run, blockers, and residual risks.
- Keep findings identifiers stable once introduced.
- Do not mark a task complete until its verification evidence is recorded.

## Progress Log

### Session: 2026-07-07 Step 4

**Tasks Completed**: Created implementation plan from accepted Step 3 design
review.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Step 3 accepted the design with no high or mid design findings and
no codex-agent reference input. Implementation must stay in one sequential
single-feature issue-resolution path.

### Session: 2026-07-07 Step 6

**Tasks Completed**: TASK-001 through TASK-006.
**Files Changed**:
- `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`
- `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`

**Findings Classified**:
- `TIR-001` fixed: live cross-workflow dispatch with a wired resolver could
  still discover an absent callee or missing callee entry step after the parent
  step produced accepted output. `DeterministicWorkflowRunner.run` now resolves
  reachable cross-workflow dispatch targets before session creation; regression
  coverage asserts no parent session exists on missing callee or callee-entry
  failures.
- `TIR-002` fixed: `workflow inspect --output json` did not expose runtime
  capability diagnostics even though `workflow validate` and live preflight
  enforced them. Inspection now adds `runtimeCapabilityGaps` and text output
  diagnostic lines; validation and inspection share callee-resolution
  diagnostics.
- `TIR-003` refuted: repository-local cross-workflow examples with resolvable
  callees remain supported; `WorkflowCommandCrossWorkflowDispatchTests` confirms
  `workflow-call-live-echo` runs and validates without capability gaps.
- `TIR-004` deferred: broader UI graph rendering for cross-workflow edges in
  `Sources/RielaApp` and `Sources/RielaViewer` was reviewed as lower priority
  because no UI files were required to fix the confirmed fail-closed/runtime
  diagnostic defect in this slice.

**Verification Commands**:
- `git diff --check`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowRunnerCapabilityPreflightTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowCommandTests/testWorkflowValidateReportsRuntimeCapabilityGaps|WorkflowCommandTests/testValidateAndInspectReportMissingCrossWorkflowCallee|WorkflowCommandTests/testInspectReportsCallableInputAndOutputContracts'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandCrossWorkflowDispatchTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
- `.build/debug/riela workflow validate design-and-implement-review-loop --workflow-definition-dir examples --output json`
- `.build/debug/riela workflow inspect design-and-implement-review-loop --workflow-definition-dir examples --output json`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`

**Verification Result**: All build and test commands passed. SwiftLint completed
with 11 warnings and 0 serious violations; the warnings are pre-existing
repository-wide style/size warnings or warnings in files already over local
thresholds.
**Blockers**: None.
**Residual Risks**: UI graph rendering can still be improved to show
cross-workflow boundaries more explicitly, but no broken UI flow was confirmed
at high priority in this implementation slice.

### Session: 2026-07-07 Step 6 Rerun After Step 7 Review

**Tasks Completed**: Addressed Step 7 high and mid findings for missing caller
`resumeStepId` target validation in live cross-workflow dispatch and CLI
runtime capability diagnostics.
**Files Changed**:
- `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`
- `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`
- `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift`

**Findings Classified**:
- `TIR-005` fixed: live cross-workflow dispatch now rejects a
  `toWorkflowId` + `resumeStepId` transition when `resumeStepId` is absent from
  the caller workflow before parent or callee session creation.
- `TIR-006` fixed: `workflow validate` and `workflow inspect --output json`
  now report the same missing caller `resumeStepId` shape under
  `runtimeCapabilityGaps` diagnostics.

**Verification Commands**:
- `git diff --check`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowRunnerCapabilityPreflightTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowCommandTests/testValidateAndInspectReportMissingCallerResumeStepForCrossWorkflowDispatch|WorkflowCommandTests/testValidateAndInspectReportMissingCrossWorkflowCallee|WorkflowCommandTests/testWorkflowValidateReportsRuntimeCapabilityGaps'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
- `.build/debug/riela workflow validate missing-resume --workflow-definition-dir tmp/three-axis-issue-resolution-review/missing-resume --output json`
- `.build/debug/riela workflow inspect missing-resume --workflow-definition-dir tmp/three-axis-issue-resolution-review/missing-resume --output json`
- `.build/debug/riela workflow validate workflow-call-live-echo --workflow-definition-dir examples --output json`
- `.build/debug/riela workflow inspect workflow-call-live-echo --workflow-definition-dir examples --output json`

**Verification Result**: `git diff --check`, `swift build`, focused runtime
tests, focused CLI diagnostics tests, SwiftLint, and representative
validate/inspect JSON commands completed. SwiftLint reported 11 warnings and 0
serious violations. Full `swift test` ran 1524 tests with 1 unrelated failure in
`RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift`
because tracked example `apple-notifications` appears in the actual examples
list but not the expected list.
**Blockers**: None.
**Residual Risks**: The unrelated `apple-notifications` example parity fixture
needs a separate owner decision; it was not changed in this targeted Step 7
corrective pass.

### Session: 2026-07-07 Step 6 Self-review Correction

**Tasks Completed**: Addressed `SELF-001` from Step 6 self-review by treating a
live cross-workflow `resumeStepId` as a reachable caller edge for subsequent
capability diagnostics and preflight validation.
**Files Changed**:
- `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`
- `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift`
- `impl-plans/active/three-axis-issue-resolution-review.md`

**Findings Classified**:
- `TIR-007` fixed: a caller step reachable only after a live callee return is
  now included in `crossWorkflowDispatchReferences`, so missing callees, missing
  callee entry steps, fanout gaps, or missing caller resume targets under that
  resume path are reported before live session side effects.

**Verification Commands**:
- `git diff --check`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowRunnerCapabilityPreflightTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowCommandTests/testValidateAndInspectReportMissingCallerResumeStepForCrossWorkflowDispatch|WorkflowCommandTests/testValidateAndInspectReportMissingCrossWorkflowCallee|WorkflowCommandTests/testWorkflowValidateReportsRuntimeCapabilityGaps|WorkflowCommandTests/testValidateAndInspectReportCrossWorkflowDispatchReachableOnlyThroughResumeStep'`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
- `.build/debug/riela workflow validate missing-resume --workflow-definition-dir tmp/three-axis-issue-resolution-review/missing-resume --output json`
- `.build/debug/riela workflow inspect missing-resume --workflow-definition-dir tmp/three-axis-issue-resolution-review/missing-resume --output json`
- `.build/debug/riela workflow validate workflow-call-live-echo --workflow-definition-dir examples --output json`
- `.build/debug/riela workflow inspect workflow-call-live-echo --workflow-definition-dir examples --output json`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`

**Verification Result**: `git diff --check`, `swift build`, focused runtime and
CLI diagnostics tests, `WorkflowRunnerCapabilityPreflightTests`, SwiftLint, and
representative validate/inspect JSON commands completed. SwiftLint reported 11
warnings and 0 serious violations. Full `swift test` ran 1526 tests with 1
unrelated failure in
`RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift`
because tracked example `apple-notifications` appears in the actual examples
list but not the expected list.
**Blockers**: None.
**Residual Risks**: The unrelated `apple-notifications` example parity fixture
still needs a separate owner decision; it was not changed in this scoped
self-review correction.

### Session: 2026-07-07 Step 6 Adversarial Review Correction

**Tasks Completed**: Addressed Step 7 adversarial mid-severity finding from
`comm-000750` by preserving terminal resume idempotency before live
cross-workflow target preflight.
**Files Changed**:
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`
- `impl-plans/active/three-axis-issue-resolution-review.md`

**Findings Classified**:
- `TIR-008` fixed: resuming an already completed caller session now returns the
  terminal result before resolving current live cross-workflow callees, so a
  removed or renamed callee cannot turn an idempotent terminal resume into an
  `invalidWorkflow` failure. Non-terminal resume, rerun, and new sessions still
  preflight cross-workflow targets before execution or session creation.

**Verification Commands**:
- `git diff --check --exit-code`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests/testTerminalResumeDoesNotPreflightMissingCallee`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`

**Verification Result**: `swift build` completed and
`swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests`
passed all 13 tests including
`testTerminalResumeDoesNotPreflightMissingCallee` (run 2026-07-07 20:11 after
the corrective-pass changes landed on `main` via `2b1d404`/`58420c1`).
**Blockers**: None.
**Residual Risks**: Full `swift test` still has the known unrelated
`apple-notifications` example parity failure reported in the previous Step 6
handoff unless separately fixed.

## Related Plans

- **Depends On**: `design-docs/specs/design-core-and-addons-review-improvements.md`
- **Depends On**: `design-docs/user-qa/three-axis-issue-resolution-review.md`
