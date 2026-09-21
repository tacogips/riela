# Work Runtime P1: Guard, director and decision application

**Status**: Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.5 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted_for_step4_implementation_planning`; no findings or revision request.
**Codex-agent references**: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-21

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
    "Sources/RielaWork/WorkStore+Decisions.swift"
  ],
  "progressLog": "impl-plans/progress/p1-lifecycle.md",
  "taskIds": [
    "P1-2",
    "P1-3"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-lifecycle",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-lifecycle --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|CompletionEvaluatorTests'",
    "git diff --check"
  ]
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


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
