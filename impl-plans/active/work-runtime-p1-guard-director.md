# Work Runtime P1: Guard, director and decision application

**Status**: Step 4 revised; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `issueCommunicationId:comm-000002`, `intakeExecutionId:step1-issue-intake-attempt-1-exec-2`, `communicationId:comm-000004`, `designStepId:step2-design-doc-update`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Updated**: 2026-09-22

```json
{
  "planId": "p1-lifecycle",
  "planPath": "impl-plans/active/work-runtime-p1-guard-director.md",
  "dependsOn": [
    "p1-reservation"
  ],
  "writePaths": [
    "Sources/RielaWork/WorkGuard.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/DeterministicDirector.swift",
    "Sources/RielaWork/DecisionApplier.swift",
    "Sources/RielaWork/CompletionEvaluator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkDecision.swift",
    "Sources/RielaWork/WorkEvidence.swift",
    "Tests/RielaWorkTests/WorkGuardTests.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "Tests/RielaWorkTests/DeterministicDirectorTests.swift",
    "Tests/RielaWorkTests/DecisionApplierTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/CompletionEvaluatorTests.swift",
    "impl-plans/progress/p1-lifecycle.md"
  ],
  "sharedPaths": [
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift"
  ],
  "progressLog": "impl-plans/progress/p1-lifecycle.md",
  "taskIds": [
    "P1-2",
    "P1-3"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-lifecycle",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-lifecycle --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|CompletionEvaluatorTests'",
    "git diff --check",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-lifecycle/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache"
  ],
  "dependencyMode": "native-accepted-predecessor-DAG",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-lifecycle/"
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intent, context, non-goals and invariants

User intent is deterministic evidence-backed decisions, durable replay and
safe cancellation without false completion. Current director input ordering,
caller-authoritative completion and replay/causality storage are material gaps.
Consume accepted reservation signatures and storage seams first. This plan
implements those repairs before dispatch can be admitted. Non-goals: schema,
WorkModels, WorkStore.swift, Package.swift or capability/CLI edits; agent child
orchestration; new policy framework; unrelated detector refactoring.

| Exact file | Smallest intended change / acceptance |
| --- | --- |
| `Sources/RielaWork/WorkGuard.swift`, `WorkEvidence.swift` | Adapt existing observations into complete typed batches with stable identity and correct equality boundaries; preserve SDK exemption. |
| `Sources/RielaWork/TaskGuardCoordinator.swift` | Persist full batch before any dependent decision, deduplicate replay/cumulative accounting, invoke shared applier with evidence references. |
| `Sources/RielaWork/DeterministicDirector.swift` | Total stable priority/order and remaining-attempt check on every recovery/rerun. |
| `Sources/RielaWork/CompletionEvaluator.swift` | Latest accepting-attempt required gates/verification, applicable blocking findings, acceptance payload and separate human requirement. |
| `Sources/RielaWork/DecisionApplier.swift`, `WorkDecision.swift` | One typed principal/action validation path for human/policy/agent; stable intent identity. |
| `Sources/RielaWork/WorkStore+Decisions.swift` | Transaction-authoritative causal scope/completion; persist/return original replay outcome; atomic pending request and all-live-action cancellation using predecessor primitives. |
| Six `Tests/RielaWorkTests/` files named in writePaths | Guard/coordination, policy, pure/store applier and completion suites prove each acceptance row, including rollback and crash windows. |
| `impl-plans/progress/p1-lifecycle.md` | Publish accepted applier/coordinator signatures and semantic handoff for dispatch. |

Invariants: no policy/human/agent bypass of budget or completion checks; full
batch durability before action; deterministic priority regardless of input
order; original replay outcome after later state changes; no duplicate request;
terminal acknowledgment before reconciliation. If an accepted storage seam
is missing, return it to reservation for serial repair and renewed acceptance,
not defer this plan's correctness to dispatch or concurrently edit schema.

## Intended changes and acceptance (§5–7, §17.2–17.3)

- [ ] **P1-2** Complete retained snapshot/event adaptation. Keep pure guard
  evaluation and existing runner budget/convergence detectors; adapt their
  events and lift CLI inactivity monitoring. Persist the complete typed guard
  batch before any dependent policy or human decision. Failed persistence
  blocks decisions. Replay deduplicates observations and cumulative token
  accounting; repeated findings use existing fingerprints. Gate visits use
  `> limit`; repeated rounds, token/wall time, and inactivity use `>= limit`.
  Attempt budget gates the next reservation and does not stop the last admitted
  attempt. Keep official/*-sdk heartbeat exemption and configured backend
  eligibility. Test simultaneous violations and equality boundaries.
- [ ] **P1-3a** Implement the total ordered director: actionable budget,
  convergence, inactivity, recoverable terminal failure/gate rejection,
  completion, then wait(.human). Use stable dimension and gate/step ordering.
  `warn` records nonbudget evidence without a forced action; `fail` stops;
  `askDirector` uses policy and bounded configured escalation. No policy, human
  or agent action bypasses budget; rerun/recover requires remaining attempts.
- [ ] **P1-3b** Apply human/policy/agent decisions through one store-backed
  applier. Validate current task/attempt and existing same-task, relevant-attempt
  `causedBy` evidence. Completion is independently reconstructed from latest
  accepting-attempt gates/verification, applicable open blocking findings, and
  affirmative acceptance payload when criteria exist. Caller verdicts and old
  successes cannot waive newer failure. Human accept satisfies only the human
  requirement, not failed gates/verification/findings.
- [ ] **P1-3c** Stable decisionId replay returns the recorded outcome without
  version/evidence/attempt duplication. Changed task/attempt, principal, action,
  reason or causal payload conflicts; fresh stale-version decisions reject.
  Retain original server timestamps. Rerun/recover durably queues one request
  using the predecessor's primitives. Cancel/stop/reject/inactivity-rerun
  persists cancellation, keeps the fence, and requires durable runner terminal
  acknowledgment before terminal task state/replacement. Uncertain
  acknowledgment is exposed for explicit decision, not store-only reconciliation.

Deliverables: integrated guard/director/applier with tests for every ordered
row, precedence, causal failure, replay conflict field, pending request crash
window, and cancellation acknowledgment state. Test-double runner callbacks
are appropriate here; the integration plan must also prove these invariants
through the real runner path. The bounded agent-director child orchestration
belongs to that plan and uses this same applier.

This wave may run beside capabilities: do not edit WorkModels, WorkStore.swift,
WorkStore+Schema, Package.swift, or capability/CLI files here. If a missing
shared contract is discovered, record it and stop the dependent edit for the
serial reconciliation owner; do not silently expand concurrent write scope.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-lifecycle
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-lifecycle --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|CompletionEvaluatorTests'
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

## Reservation-to-lifecycle handoff (§17.6)

Acquire `Tests/RielaWorkTests/DecisionApplierStoreTests.swift` only after
p1-reservation's accepted hash and current cancellation tests are available.
Preserve the root's cancellation-provenance assertions while adding causal,
completion, replay and atomic enqueue tests. Cover successive distinct rerun
requests after consumption/reconciliation; consumed history cannot prohibit
future decisions. Test cancellation acknowledgment against durable matching
cancelled snapshots, including created/non-cancelled/mismatched rejection.
The transaction-scoped enqueue seam must run inside applyDecision's transaction;
injected failure must roll back decision, outcome, request and task version.
